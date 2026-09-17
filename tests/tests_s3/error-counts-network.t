#!/bin/bash
#
# Per-phase S3 error counts for connection failures, timeouts and resets.
#
# Uploads with "--s3ignoreerrors" to a loopback port on which nothing listens,
# so that every request fails to connect, to a stall server that accepts
# connections but never answers, so that every request runs into the timeout
# of "--s3reqtimeout", and downloads from a server that announces a body it
# never fully delivers, so that every request sees its connection reset.
# Verifies that the results classify the failures as "conn_fail", "timeout"
# and "conn_reset". No S3 server is needed.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1

NUM_THREADS=2
NUM_DIRS=1      # per thread
NUM_FILES=2     # per thread and dir
OBJ_SIZE=4096
REQ_TIMEOUT_MS=2000

EXPECTED_OBJECTS=$((NUM_THREADS * NUM_DIRS * NUM_FILES))

require_build_feature s3
require_cmd python3

test_init
tap_plan 16

# The AWS SDK retries failed requests with exponential backoff by default,
# which would make each failed operation take almost half a minute. One
# attempt per operation keeps the test fast and the expected counts exact.
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=1

# Any credentials will do, no request ever reaches an S3 server.
S3_AUTH_OPTS=( --s3key elbenchotest --s3secret elbenchotestsecret --s3region us-east-1 )

################## Nothing listens on the port ##################

CLOSED_PORT=$(find_free_port)
if [ -z "$CLOSED_PORT" ]; then
    tap_bail "Unable to find a free TCP port."
fi

run_elbencho connfail \
    --s3endpoints "http://127.0.0.1:$CLOSED_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase against a closed port completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS failed operations in total"
assert_eq "$(json_error_count "$ELB_JSON" WRITE conn_fail)" "$EXPECTED_OBJECTS" \
    "all failed operations are connection failures"
assert_eq "$(json_error_count "$ELB_JSON" WRITE timeout)" "0" \
    "no failed operation is a timeout"
assert_eq "$(csv_value "$ELB_CSV" WRITE "errors conn fail")" "$EXPECTED_OBJECTS" \
    "csv \"errors conn fail\" column holds the number of failed operations"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS attempted I/O operations"

################## The server accepts connections but never answers ##################

# stall_server PORT
# Accepts every connection and keeps it open without ever sending a byte, so
# that a client with a request timeout gives up. Runs until killed. "exec" hands
# the pid of this function's subshell to the python process itself, so that
# "register_pid"/"kill_registered" terminate the server directly instead of an
# orphaned python3 left behind by a killed wrapper shell.
stall_server()
{
    exec python3 - "$1" <<'EOF'
import socket, sys
port = int(sys.argv[1])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(128)
conns = []
while True:
    conn, _ = srv.accept()
    conns.append(conn) # keep open, never answer
EOF
}

# short_body_server PORT
# Accepts every connection, reads the request head (up to the blank line that
# ends it, or until the peer closes first), then answers with a header that
# announces a 4096 byte body but only ever delivers 100 bytes before closing
# the connection - so a client that trusts "Content-Length" sees the transfer
# break instead of a clean end of response. Runs until killed. See "stall_server"
# above for why "exec" matters here.
short_body_server()
{
    exec python3 - "$1" <<'EOF'
import socket, sys
port = int(sys.argv[1])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(128)
while True:
    conn, _ = srv.accept()
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = conn.recv(4096)
            if not chunk:
                break
            head += chunk
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n")
        conn.sendall(b"x" * 100)
    except OSError:
        pass # client already gone (e.g. broken pipe): move on to the next connection
    finally:
        conn.close()
EOF
}

STALL_PORT=""
STALL_PID=""
tries=0
while [ $tries -lt 5 ]; do
    tries=$((tries+1))
    STALL_PORT=$(find_free_port)
    [ -n "$STALL_PORT" ] || break

    # stdout/stderr must go to a file: prove reads the test's stdout until EOF.
    stall_server "$STALL_PORT" > "$TEST_DIR/stall-server.log" 2>&1 &
    STALL_PID=$!
    register_pid "$STALL_PID"

    trace_cmd "stall server start on port $STALL_PORT (attempt $tries)" \
        stall_server "$STALL_PORT"
    trace_add_log "$TEST_DIR/stall-server.log"

    if wait_for_port 127.0.0.1 "$STALL_PORT" 10; then
        break
    fi

    tap_diag "Stall server did not come up on port $STALL_PORT, retrying..."
    kill -KILL "$STALL_PID" >/dev/null 2>&1
    wait "$STALL_PID" 2>/dev/null
    STALL_PID=""
done

if [ -z "$STALL_PID" ] || ! kill -0 "$STALL_PID" 2>/dev/null; then
    tap_bail "Unable to start the stall server."
fi

started="$(trace_now_ms)"

run_elbencho timeout \
    --s3endpoints "http://127.0.0.1:$STALL_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors --s3reqtimeout $REQ_TIMEOUT_MS \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase against a stall server completes with \"--s3ignoreerrors\""

elapsed_ms=$(( $(trace_now_ms) - started ))

assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS failed operations in total"
assert_eq "$(json_error_count "$ELB_JSON" WRITE timeout)" "$EXPECTED_OBJECTS" \
    "all failed operations are timeouts"
assert_eq "$(json_error_count "$ELB_JSON" WRITE conn_fail)" "0" \
    "no failed operation is a connection failure"
# Each thread waits once per object, so the run takes at least objects per
# thread times the timeout. This proves that "--s3reqtimeout" and not some
# other limit ended the requests.
assert_ge "$elapsed_ms" "$(( NUM_DIRS * NUM_FILES * REQ_TIMEOUT_MS ))" \
    "the run took at least one request timeout per object of a thread"
# Upper bound on the same run: the lower bound above is the actual proof that
# "--s3reqtimeout" fired; this only catches a timeout that runs far longer than
# configured. curl checks the transfer speed over a window of a few seconds
# rather than enforcing "--s3reqtimeout" to the millisecond, the AWS SDK and
# process startup add their own overhead on top, and a loaded host adds further
# seconds per request, so the wait per request is bounded but not exact.
assert_le "$elapsed_ms" "$(( NUM_DIRS * NUM_FILES * (REQ_TIMEOUT_MS + 25000) ))" \
    "the run did not take dramatically longer than one request timeout per object of a thread"

################## The server announces a body it never fully delivers ##################

SHORT_BODY_PORT=""
SHORT_BODY_PID=""
tries=0
while [ $tries -lt 5 ]; do
    tries=$((tries+1))
    SHORT_BODY_PORT=$(find_free_port)
    [ -n "$SHORT_BODY_PORT" ] || break

    # stdout/stderr must go to a file: prove reads the test's stdout until EOF.
    short_body_server "$SHORT_BODY_PORT" > "$TEST_DIR/short-body-server.log" 2>&1 &
    SHORT_BODY_PID=$!
    register_pid "$SHORT_BODY_PID"

    trace_cmd "short body server start on port $SHORT_BODY_PORT (attempt $tries)" \
        short_body_server "$SHORT_BODY_PORT"
    trace_add_log "$TEST_DIR/short-body-server.log"

    if wait_for_port 127.0.0.1 "$SHORT_BODY_PORT" 10; then
        break
    fi

    tap_diag "Short body server did not come up on port $SHORT_BODY_PORT, retrying..."
    kill -KILL "$SHORT_BODY_PID" >/dev/null 2>&1
    wait "$SHORT_BODY_PID" 2>/dev/null
    SHORT_BODY_PID=""
done

if [ -z "$SHORT_BODY_PID" ] || ! kill -0 "$SHORT_BODY_PID" 2>/dev/null; then
    tap_bail "Unable to start the short body server."
fi

run_elbencho shortbody \
    --s3endpoints "http://127.0.0.1:$SHORT_BODY_PORT" "${S3_AUTH_OPTS[@]}" \
    -r --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "read phase against a short body server completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" READ total)" "$EXPECTED_OBJECTS" \
    "read phase reports $EXPECTED_OBJECTS failed operations in total"
assert_eq "$(json_error_count "$ELB_JSON" READ conn_reset)" "$EXPECTED_OBJECTS" \
    "all failed operations are connection resets"
assert_eq "$(json_error_count "$ELB_JSON" READ conn_fail)" "0" \
    "no failed operation is a connection failure"
