#!/bin/bash
#
# Per-phase S3 error counts for a multipart upload that fails partway through.
#
# Uploads an object with "--s3ignoreerrors" to an embedded fake S3 server that
# accepts "CreateMultipartUpload" and the first part, then answers every later
# "UploadPart" with a 503 SlowDown, once in sync mode and once with
# "--iodepth" for the async completion path. Verifies that the failed part
# still counts as an attempted I/O, that the multipart upload is aborted
# exactly once and never completed, and that the operations log agrees. No
# minio is needed.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1

OBJ_SIZE=8k
BLOCK_SIZE=4k
FAIL_FROM_PART=2 # part 1 succeeds, part 2 and up fail

require_build_feature s3
require_cmd python3

test_init
tap_plan 16

# The AWS SDK retries failed requests with exponential backoff by default,
# which would make each failed operation take almost half a minute. One
# attempt per operation keeps the test fast and the expected counts exact.
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=1

# Any credentials will do, no request ever reaches a real S3 server.
S3_AUTH_OPTS=( --s3key a --s3secret b --s3region us-east-1 )

# fake_s3_server PORT FAIL_FROM_PART
# Answers CreateMultipartUpload with an upload ID, UploadPart with 200 and an
# ETag for part numbers below FAIL_FROM_PART and a 503 SlowDown from there on,
# AbortMultipartUpload with 204 and CompleteMultipartUpload with 200. Prints
# one line per request ("CREATE_MPU", "UPLOAD_PART n -> code", "ABORT_MPU",
# "COMPLETE_MPU") so the test can check which requests the client actually
# sent. Runs until killed. "exec" hands the pid of this function's subshell to
# the python process itself, so that "register_pid"/"kill_registered"
# terminate the server directly instead of an orphaned python3 left behind by
# a killed wrapper shell.
fake_s3_server()
{
    exec python3 - "$1" "$2" <<'EOF'
import http.server, sys

port = int(sys.argv[1])
fail_from_part = int(sys.argv[2])


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

    def do_POST(self):
        self._drain_body()
        if "uploads" in self.path:
            self._note("CREATE_MPU")
            body = (b'<?xml version="1.0" encoding="UTF-8"?>'
                    b'<InitiateMultipartUploadResult><Bucket>elbencho-test-bucket</Bucket>'
                    b'<Key>k</Key><UploadId>fake-upload-id</UploadId>'
                    b'</InitiateMultipartUploadResult>')
            self._send(200, body)
            return

        # CompleteMultipartUpload
        self._note("COMPLETE_MPU")
        body = (b'<?xml version="1.0" encoding="UTF-8"?>'
                b'<CompleteMultipartUploadResult><ETag>&quot;deadbeef&quot;</ETag>'
                b'</CompleteMultipartUploadResult>')
        self._send(200, body)

    def do_PUT(self):
        self._drain_body()

        part = int(self.path.split("partNumber=")[1].split("&")[0])
        if part >= fail_from_part:
            self._note("UPLOAD_PART %d -> 503" % part)
            body = (b'<?xml version="1.0" encoding="UTF-8"?><Error><Code>SlowDown</Code>'
                    b'<Message>slow down</Message></Error>')
            self._send(503, body)
        else:
            self._note("UPLOAD_PART %d -> 200" % part)
            self._send(200, b"", {"ETag": '"part%d"' % part})

    def do_DELETE(self):
        self._drain_body()
        self._note("ABORT_MPU")
        self._send(204)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
srv.serve_forever()
EOF
}

################## Sync multipart upload fails on the second part ##################

SYNC_LOG="$TEST_DIR/fakes3-sync.log"
SYNC_PORT=""
SYNC_PID=""
tries=0
while [ $tries -lt 5 ]; do
    tries=$((tries+1))
    SYNC_PORT=$(find_free_port)
    [ -n "$SYNC_PORT" ] || break

    # stdout/stderr must go to a file: prove reads the test's stdout until EOF.
    fake_s3_server "$SYNC_PORT" "$FAIL_FROM_PART" > "$SYNC_LOG" 2>&1 &
    SYNC_PID=$!
    register_pid "$SYNC_PID"

    trace_cmd "fake S3 server start on port $SYNC_PORT (attempt $tries)" \
        fake_s3_server "$SYNC_PORT" "$FAIL_FROM_PART"
    trace_add_log "$SYNC_LOG"

    if wait_for_port 127.0.0.1 "$SYNC_PORT" 10; then
        break
    fi

    tap_diag "Fake S3 server did not come up on port $SYNC_PORT, retrying..."
    kill -KILL "$SYNC_PID" >/dev/null 2>&1
    wait "$SYNC_PID" 2>/dev/null
    SYNC_PID=""
done

if [ -z "$SYNC_PID" ] || ! kill -0 "$SYNC_PID" 2>/dev/null; then
    tap_bail "Unable to start the fake S3 server for the sync run."
fi

SYNC_OPSLOG="$TEST_DIR/mpu-sync.opslog"

run_elbencho mpu-sync \
    --s3endpoints "http://127.0.0.1:$SYNC_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors \
    -t 1 -n 1 -N 1 -s $OBJ_SIZE -b $BLOCK_SIZE \
    --opslog "$SYNC_OPSLOG" \
    "s3://elbencho-test-bucket"
assert_ok $? "sync multipart upload completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "1" \
    "write phase reports 1 failed operation"
assert_eq "$(json_error_count "$ELB_JSON" WRITE http_503)" "1" \
    "the failed operation is a http 503"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "2" \
    "write phase reports 2 attempted I/O operations (both parts were attempted)"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done entries)" "1" \
    "write phase reports 1 processed entry"
assert_eq "$(grep -c '^ABORT_MPU$' "$SYNC_LOG")" "1" \
    "the sync server log has exactly one ABORT_MPU line"
assert_eq "$(grep -c '^COMPLETE_MPU$' "$SYNC_LOG")" "0" \
    "the sync server log has no COMPLETE_MPU line"
assert_eq "$(opslog_count "$SYNC_OPSLOG" S3UploadPart)" "2" \
    "the operations log has 2 completed S3UploadPart entries"
assert_eq "$(opslog_error_count "$SYNC_OPSLOG")" "1" \
    "the operations log has 1 failed entry"

################## Async multipart upload fails on the second part ##################

ASYNC_LOG="$TEST_DIR/fakes3-async.log"
ASYNC_PORT=""
ASYNC_PID=""
tries=0
while [ $tries -lt 5 ]; do
    tries=$((tries+1))
    ASYNC_PORT=$(find_free_port)
    [ -n "$ASYNC_PORT" ] || break

    # stdout/stderr must go to a file: prove reads the test's stdout until EOF.
    fake_s3_server "$ASYNC_PORT" "$FAIL_FROM_PART" > "$ASYNC_LOG" 2>&1 &
    ASYNC_PID=$!
    register_pid "$ASYNC_PID"

    trace_cmd "fake S3 server start on port $ASYNC_PORT (attempt $tries)" \
        fake_s3_server "$ASYNC_PORT" "$FAIL_FROM_PART"
    trace_add_log "$ASYNC_LOG"

    if wait_for_port 127.0.0.1 "$ASYNC_PORT" 10; then
        break
    fi

    tap_diag "Fake S3 server did not come up on port $ASYNC_PORT, retrying..."
    kill -KILL "$ASYNC_PID" >/dev/null 2>&1
    wait "$ASYNC_PID" 2>/dev/null
    ASYNC_PID=""
done

if [ -z "$ASYNC_PID" ] || ! kill -0 "$ASYNC_PID" 2>/dev/null; then
    tap_bail "Unable to start the fake S3 server for the async run."
fi

ASYNC_OPSLOG="$TEST_DIR/mpu-async.opslog"

run_elbencho mpu-async \
    --s3endpoints "http://127.0.0.1:$ASYNC_PORT" "${S3_AUTH_OPTS[@]}" \
    -w --s3ignoreerrors --iodepth 2 \
    -t 1 -n 1 -N 1 -s $OBJ_SIZE -b $BLOCK_SIZE \
    --opslog "$ASYNC_OPSLOG" \
    "s3://elbencho-test-bucket"
assert_ok $? "async multipart upload completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "1" \
    "write phase reports 1 failed operation"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "2" \
    "write phase reports 2 attempted I/O operations (both parts were attempted)"
assert_eq "$(grep -c '^ABORT_MPU$' "$ASYNC_LOG")" "1" \
    "the async server log has exactly one ABORT_MPU line"
assert_eq "$(grep -c '^COMPLETE_MPU$' "$ASYNC_LOG")" "0" \
    "the async server log has no COMPLETE_MPU line"
assert_eq "$(opslog_count "$ASYNC_OPSLOG" S3UploadPartAsync)" "2" \
    "the operations log has 2 completed S3UploadPartAsync entries"
assert_eq "$(opslog_error_count "$ASYNC_OPSLOG")" "1" \
    "the operations log has 1 failed entry"
