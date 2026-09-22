#!/bin/bash
#
# Per-phase S3 retry counts for requests that the AWS SDK retries on its own.
#
# Runs writes against an embedded fake S3 server that answers PUT with a 429
# TooManyRequests for a configurable number of leading attempts of each key
# and 200 afterwards, and verifies that the retried attempts are reported
# under "retries" in the json, csv and txt results, separately from "errors".
# Covers the SDK's default retry behavior (shared client included), retries
# that get exhausted, retries disabled via AWS_MAX_ATTEMPTS=1, and the summed
# counts of a distributed run through two elbencho service instances. No
# minio is needed.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1

OBJ_SIZE=4k
BLOCK_SIZE=4k

PORT1=""
PORT2=""
HOSTS=""
SERVICE_PIDS=""

require_build_feature s3
require_cmd python3

test_init
tap_plan 38

# The default AWS SDK retry mode is in effect for (a), (b) and (e) below.
# "AWS_MAX_ATTEMPTS" only takes effect together with "AWS_RETRY_MODE=standard"
# or "adaptive", so both are unset here and exported again just for (c)/(d).
unset AWS_RETRY_MODE AWS_MAX_ATTEMPTS

# Any credentials will do, no request ever reaches a real S3 server.
S3_AUTH_OPTS=( --s3key a --s3secret b --s3region us-east-1 )

# fake_s3_server PORT FAIL_ATTEMPTS
# Answers PUT with a 429 TooManyRequests for the first FAIL_ATTEMPTS attempts
# of the request's path (i.e. per object key, counted independently for each
# one) and with 200 from there on; FAIL_ATTEMPTS -1 means always 429. GET and
# HEAD always answer 404, since nothing ever reads an object back here. Prints
# one line per request ("PUT <key> -> <code>", "GET <key> -> 404",
# "HEAD <key> -> 404") so the test can count the attempts the client actually
# made. Runs until killed. "exec" hands the pid of this function's subshell to
# the python process itself, so that "register_pid"/"kill_registered"
# terminate the server directly instead of an orphaned python3 left behind by
# a killed wrapper shell.
fake_s3_server()
{
    exec python3 - "$1" "$2" <<'EOF'
import http.server, sys, threading

port = int(sys.argv[1])
fail_attempts = int(sys.argv[2])

attempts_lock = threading.Lock()
attempts_by_key = {}

THROTTLE_BODY = (b'<?xml version="1.0" encoding="UTF-8"?>'
                  b'<Error><Code>TooManyRequests</Code>'
                  b'<Message>Please reduce your request rate.</Message></Error>')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _note(self, what):
        print(what, flush=True)

    def _drain_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/xml")
        if headers:
            for name, value in headers.items():
                self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_PUT(self):
        self._drain_body()

        with attempts_lock:
            attempts_by_key[self.path] = attempts_by_key.get(self.path, 0) + 1
            attempt = attempts_by_key[self.path]

        if fail_attempts < 0 or attempt <= fail_attempts:
            self._note("PUT %s -> 429" % self.path)
            self._send(429, THROTTLE_BODY)
            return

        self._note("PUT %s -> 200" % self.path)
        self._send(200, b"", {"ETag": '"fake-etag"'})

    def do_GET(self):
        self._drain_body()
        self._note("GET %s -> 404" % self.path)
        self._send(404, b'<?xml version="1.0" encoding="UTF-8"?>'
                        b'<Error><Code>NoSuchKey</Code></Error>')

    def do_HEAD(self):
        self._note("HEAD %s -> 404" % self.path)
        self._send(404)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
srv.serve_forever()
EOF
}

# start_fake_server TAG FAIL_ATTEMPTS
# Starts a fresh fake_s3_server instance on its own free port, retrying the
# whole start-and-wait sequence if the port turns out to be taken in the
# meantime. Sets the globals FAKE_PORT, FAKE_PID and FAKE_LOG. Bails out the
# whole test if the server never comes up.
start_fake_server()
{
    local tag="$1"
    local fail_attempts="$2"
    local tries=0

    FAKE_PORT=""
    FAKE_PID=""
    FAKE_LOG="$TEST_DIR/fakes3-$tag.log"

    while [ $tries -lt 5 ]; do
        tries=$((tries+1))
        FAKE_PORT=$(find_free_port)
        [ -n "$FAKE_PORT" ] || break

        # stdout/stderr must go to a file: prove reads the test's stdout until EOF.
        fake_s3_server "$FAKE_PORT" "$fail_attempts" > "$FAKE_LOG" 2>&1 &
        FAKE_PID=$!
        register_pid "$FAKE_PID"

        trace_cmd "fake S3 server start on port $FAKE_PORT (attempt $tries)" \
            fake_s3_server "$FAKE_PORT" "$fail_attempts"
        trace_add_log "$FAKE_LOG"

        if wait_for_port 127.0.0.1 "$FAKE_PORT" 10; then
            return 0
        fi

        tap_diag "Fake S3 server did not come up on port $FAKE_PORT, retrying..."
        kill -KILL "$FAKE_PID" >/dev/null 2>&1
        wait "$FAKE_PID" 2>/dev/null
        FAKE_PID=""
    done

    tap_bail "Unable to start the fake S3 server for \"$tag\"."
}

# stop_fake_server
# Terminates the fake server started by start_fake_server, so that the next
# section's server starts with fresh per-key attempt counters.
stop_fake_server()
{
    [ -n "$FAKE_PID" ] || return 0

    kill -TERM "$FAKE_PID" >/dev/null 2>&1
    wait "$FAKE_PID" 2>/dev/null
    FAKE_PID=""
}

################## (a) default AWS SDK retries ##################

start_fake_server default 2

run_elbencho retry-default \
    --s3endpoints "http://127.0.0.1:$FAKE_PORT" "${S3_AUTH_OPTS[@]}" \
    -w -t 2 -n 1 -N 2 -s $OBJ_SIZE -b $BLOCK_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase completes with the SDK's default retries"

assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done errors)" "false" \
    "write phase reports no errors: every throttled request eventually succeeded"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE total)" "8" \
    "write phase reports 8 retried attempts (4 objects x 2 throttled attempts each)"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE http_429)" "8" \
    "all retried attempts are counted as http status 429"
# The SDK's default retry strategy waits 0 ms before a request's first retry and 25 ms x 2^n
# before the n-th retry after that (50 ms before the second), with no jitter, so each of
# these 4 keys (2 retries apiece) waits 0 ms + 50 ms = 50 ms: 4 x 50 = 200.
assert_eq "$(json_retry_count "$ELB_JSON" WRITE wait_ms)" "200" \
    "write phase reports the summed backoff wait for the retries: 4 keys x (0 ms + 50 ms)"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "4" \
    "write phase reports 4 attempted I/O operations (retries are not counted as ios)"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done entries)" "4" \
    "write phase reports 4 processed entries"
assert_eq "$(grep -c '^PUT ' "$FAKE_LOG")" "12" \
    "the fake server log has exactly 12 PUT lines (4 keys x 3 attempts each)"
assert_eq "$(csv_value "$ELB_CSV" WRITE "retries total")" "8" \
    "csv \"retries total\" column reports the 8 retried attempts"
assert_eq "$(csv_value "$ELB_CSV" WRITE "retries by kind")" "http_429=8" \
    "csv \"retries by kind\" column lists the 8 http_429 retries"
assert_eq "$(res_row_count "$ELB_RES" "Retries")" "1" \
    "txt result contains one \"Retries\" row"

stop_fake_server

################## (b) default AWS SDK retries with a shared client ##################

start_fake_server single 2

run_elbencho retry-single \
    --s3endpoints "http://127.0.0.1:$FAKE_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3single -t 2 -n 1 -N 2 -s $OBJ_SIZE -b $BLOCK_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase with a shared S3 client (\"--s3single\") completes with the SDK's default retries"

assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done errors)" "false" \
    "write phase with a shared client reports no errors"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE total)" "8" \
    "write phase with a shared client reports 8 retried attempts"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE http_429)" "8" \
    "all retried attempts of the shared client are counted as http status 429"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE wait_ms)" "200" \
    "write phase with a shared client reports the summed backoff wait: 4 keys x (0 ms + 50 ms)"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "4" \
    "write phase with a shared client reports 4 attempted I/O operations"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done entries)" "4" \
    "write phase with a shared client reports 4 processed entries"
assert_eq "$(grep -c '^PUT ' "$FAKE_LOG")" "12" \
    "the fake server log has exactly 12 PUT lines with the shared client too"
assert_eq "$(csv_value "$ELB_CSV" WRITE "retries total")" "8" \
    "csv \"retries total\" column reports the 8 retried attempts of the shared client"
assert_eq "$(csv_value "$ELB_CSV" WRITE "retries by kind")" "http_429=8" \
    "csv \"retries by kind\" column lists the 8 http_429 retries of the shared client"
assert_eq "$(res_row_count "$ELB_RES" "Retries")" "1" \
    "txt result contains one \"Retries\" row with a shared client"

stop_fake_server

################## (c) retries get exhausted ##################

export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=2

start_fake_server exhausted -1

run_elbencho retry-exhausted \
    --s3endpoints "http://127.0.0.1:$FAKE_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors -t 2 -n 1 -N 2 -s $OBJ_SIZE -b $BLOCK_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase completes with \"--s3ignoreerrors\" once retries are exhausted"

assert_eq "$(json_retry_count "$ELB_JSON" WRITE total)" "4" \
    "write phase reports 4 retried attempts (1 retry per key before the 2nd attempt fails for good)"
assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "4" \
    "write phase reports 4 failed operations, one per key, once AWS_MAX_ATTEMPTS is exhausted"
assert_eq "$(json_error_count "$ELB_JSON" WRITE http_429)" "4" \
    "all 4 failed operations are counted as http status 429"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "4" \
    "write phase reports 4 attempted I/O operations"

stop_fake_server

################## (d) retries disabled ##################

export AWS_MAX_ATTEMPTS=1

start_fake_server disabled -1

run_elbencho retry-disabled \
    --s3endpoints "http://127.0.0.1:$FAKE_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors -t 2 -n 1 -N 2 -s $OBJ_SIZE -b $BLOCK_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "write phase completes with \"--s3ignoreerrors\" and AWS_MAX_ATTEMPTS=1"

assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done retries)" "false" \
    "write phase has no \"retries\" subtree: AWS_MAX_ATTEMPTS=1 disables SDK-side retries"
assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "4" \
    "write phase reports 4 failed operations, one immediate failure per key"

stop_fake_server

################## (e) service mode sums the retries of both services ##################

unset AWS_RETRY_MODE AWS_MAX_ATTEMPTS

start_service_pair
if [ $? -ne 0 ]; then
    tap_bail "Unable to start two elbencho service instances on consecutive ports."
fi

# The SDK's default retry strategy retries the first attempt without any delay, so a single
# retry per key would report a wait_ms of 0; two retries per key are needed here to also prove
# that the summed wait crosses the wire from both services.
start_fake_server service 2

run_elbencho retry-svc \
    --hosts "$HOSTS" \
    --s3endpoints "http://127.0.0.1:$FAKE_PORT" "${S3_AUTH_OPTS[@]}" \
    -w -t 2 -n 1 -N 2 -s $OBJ_SIZE -b $BLOCK_SIZE \
    "s3://elbencho-test-bucket"
assert_ok $? "distributed write phase completes with the SDK's default retries"

assert_eq "$(json_retry_count "$ELB_JSON" WRITE total)" "16" \
    "coordinator reports the 16 retried attempts summed over both services (2 services x 2 threads x 2 objects x 2 retries)"
assert_eq "$(json_retry_count "$ELB_JSON" WRITE http_429)" "16" \
    "all retried attempts of both services are counted as http status 429"
# 8 keys (2 services x 2 threads x 2 objects), each waiting 0 ms + 50 ms across its two retries:
# 8 x 50 = 400; the exact match proves both services' waits actually crossed the wire to the
# coordinator, not just that each service saw a non-zero wait locally.
assert_eq "$(json_retry_count "$ELB_JSON" WRITE wait_ms)" "400" \
    "coordinator reports the summed backoff wait for the retries of both services: 8 keys x (0 ms + 50 ms)"
assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done errors)" "false" \
    "distributed write phase reports no errors: every throttled request eventually succeeded"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "8" \
    "coordinator reports the 8 attempted I/O operations of both services"
assert_eq "$(res_row_count "$ELB_RES" "Retries")" "1" \
    "txt result contains one \"Retries\" row for the distributed run"

stop_fake_server

run_elbencho quit --hosts "$HOSTS" --quit
assert_ok $? "\"--quit\" is accepted by both services"
