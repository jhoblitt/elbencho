#!/bin/bash
#
# Per-phase S3 error counts in the phase results.
#
# Runs phases with "--s3ignoreerrors" against a bucket that does not exist and
# with wrong credentials, so that every object operation fails with a known
# http status, and verifies that the json, csv and txt results report the
# failed operations per status code. A run without errors verifies that the
# error fields stay absent. Also covers a partial failure (some objects were
# never written), multipart uploads (a successful one against a real bucket
# and one whose "CreateMultipartUpload" itself fails against a missing
# bucket), and "--stat" (HeadObject) against a missing bucket.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1
source "$ELBENCHO_TEST_LIB/minio.sh" || exit 1

NUM_THREADS=2
NUM_DIRS=1      # per thread
NUM_FILES=4     # per thread and dir
OBJ_SIZE=4096

EXPECTED_OBJECTS=$((NUM_THREADS * NUM_DIRS * NUM_FILES))

require_build_feature s3
require_cmd aws
require_minio

test_init
tap_plan 43

BUCKET="$(bucket_name)"
MISSING_BUCKET="$BUCKET-missing"
READ_OPSLOG="$TEST_DIR/read404.opslog"

start_minio
if [ $? -ne 0 ]; then
    tap_bail "Unable to start a minio S3 server instance."
fi

################## A run without errors has no error fields ##################

run_elbencho write \
    "${S3_OPTS[@]}" \
    -d -w \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://$BUCKET"
assert_ok $? "bucket creation and upload of $EXPECTED_OBJECTS objects succeed"

assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS I/O operations"
assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done errors)" "false" \
    "write phase without errors has no \"errors\" subtree in the json result"
assert_eq "$(csv_value "$ELB_CSV" WRITE "errors total")" "" \
    "write phase without errors has an empty \"errors total\" csv cell"
assert_eq "$(res_row_count "$ELB_RES" "Errors")" "0" \
    "write phase without errors prints no \"Errors\" row"

################## Every download from a missing bucket is a 404 ##################

run_elbencho read404 \
    "${S3_OPTS[@]}" \
    -r --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    --opslog "$READ_OPSLOG" \
    "s3://$MISSING_BUCKET"
assert_ok $? "read phase from a missing bucket completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" READ total)" "$EXPECTED_OBJECTS" \
    "read phase reports $EXPECTED_OBJECTS failed operations in total"
assert_eq "$(json_error_count "$ELB_JSON" READ http_404)" "$EXPECTED_OBJECTS" \
    "read phase reports $EXPECTED_OBJECTS operations failed with http status 404"
assert_eq "$(json_error_count "$ELB_JSON" READ timeout)" "0" \
    "read phase reports no timeouts"
assert_eq "$(json_error_count "$ELB_JSON" READ conn_fail)" "0" \
    "read phase reports no connection failures"
assert_eq "$(json_value "$ELB_JSON" READ last_done ios)" "$EXPECTED_OBJECTS" \
    "read phase reports $EXPECTED_OBJECTS attempted I/O operations as the denominator"
assert_eq "$(opslog_error_count "$READ_OPSLOG")" "$EXPECTED_OBJECTS" \
    "operations log agrees on the number of failed operations"

assert_eq "$(csv_value "$ELB_CSV" READ "IOs [last]")" "$EXPECTED_OBJECTS" \
    "csv \"IOs [last]\" column holds the number of attempted operations"
assert_eq "$(csv_value "$ELB_CSV" READ "errors total")" "$EXPECTED_OBJECTS" \
    "csv \"errors total\" column holds the number of failed operations"
assert_eq "$(csv_value "$ELB_CSV" READ "errors timeout")" "0" \
    "csv \"errors timeout\" column is 0"
assert_eq "$(csv_value "$ELB_CSV" READ "errors conn fail")" "0" \
    "csv \"errors conn fail\" column is 0"
assert_eq "$(csv_value "$ELB_CSV" READ "errors conn reset")" "0" \
    "csv \"errors conn reset\" column is 0"
assert_eq "$(csv_value "$ELB_CSV" READ "errors http 4xx")" "$EXPECTED_OBJECTS" \
    "csv \"errors http 4xx\" column holds the number of 404s"
assert_eq "$(csv_value "$ELB_CSV" READ "errors http 5xx")" "0" \
    "csv \"errors http 5xx\" column is 0"
assert_eq "$(csv_value "$ELB_CSV" READ "errors by kind")" "http_404=$EXPECTED_OBJECTS" \
    "csv \"errors by kind\" column lists the 404s"

assert_eq "$(res_row_count "$ELB_RES" "Errors")" "1" \
    "txt result contains one \"Errors\" row"
assert_match "$(grep -E '^ +Errors +:' "$ELB_RES")" \
    "total=$EXPECTED_OBJECTS http_404=$EXPECTED_OBJECTS" \
    "\"Errors\" row shows the total and the 404 count"

################## Every upload with a wrong secret is a 403 ##################

run_elbencho write403 \
    --s3endpoints "$S3_ENDPOINT" --s3key "$S3_KEY" --s3secret "wrong$S3_SECRET" \
    --s3region "$S3_REGION" \
    -w --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://$BUCKET"
assert_ok $? "write phase with a wrong secret completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" WRITE http_403)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS operations failed with http status 403"
assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS failed operations in total"
assert_eq "$(s3_object_count "$BUCKET")" "$EXPECTED_OBJECTS" \
    "the bucket still holds only the $EXPECTED_OBJECTS objects of the first upload"

################## Partial failure: half the requested objects don't exist ##################

# Reads twice the number of objects each thread actually wrote, so the second
# half of every thread's range is a 404 and the phase fails exactly half of its
# attempted operations. Threads process their objects in order, so the thread
# that finishes first has already hit its own share of misses, and even the
# "first_done" snapshot (taken when that thread finishes) already carries a
# non-zero error count.
PARTIAL_NUM_FILES=$((NUM_FILES * 2))

run_elbencho partial \
    "${S3_OPTS[@]}" \
    -r --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $PARTIAL_NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://$BUCKET"
assert_ok $? "reading a bucket that only has half the requested objects completes with \"--s3ignoreerrors\""

partial_ios="$(json_value "$ELB_JSON" READ last_done ios)"
assert_eq "$(json_error_count "$ELB_JSON" READ total)" "$((partial_ios / 2))" \
    "read phase fails exactly half of its attempted I/O operations"
assert_gt "$(json_error_count "$ELB_JSON" READ total first_done)" "0" \
    "the first finished thread already reports failed operations of its own"

################## Multipart upload against a real bucket ##################

# A real S3 server enforces the standard multipart minimum part size (5MiB) on
# every part but the last, unlike the missing-bucket case below where no part
# is ever uploaded at all - hence the much larger object here, one per thread
# instead of NUM_FILES of them, to keep the uploaded data small.
MP_OBJ_SIZE=10m
MP_BLOCK_SIZE=5m
MP_EXPECTED_OBJECTS=$NUM_THREADS

run_elbencho multipart \
    "${S3_OPTS[@]}" \
    -w \
    -t $NUM_THREADS -n $NUM_DIRS -N 1 -s $MP_OBJ_SIZE -b $MP_BLOCK_SIZE \
    "s3://$BUCKET"
assert_ok $? "multipart upload to an existing bucket succeeds"

assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "$((MP_EXPECTED_OBJECTS * 2))" \
    "write phase reports two uploaded parts (two 5MiB blocks of a 10MiB object) per object"
assert_eq "$(json_has_key "$ELB_JSON" WRITE last_done errors)" "false" \
    "successful multipart write phase has no \"errors\" subtree"

################## Multipart upload against a missing bucket ##################

# CreateMultipartUpload itself fails with a 404, so no part is ever uploaded and
# no upload ID exists to abort - the object is simply skipped.
MULTIPART_OPSLOG="$TEST_DIR/multipart-missing.opslog"

run_elbencho multipartmissing \
    "${S3_OPTS[@]}" \
    -w --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s 8k -b 4k \
    --opslog "$MULTIPART_OPSLOG" \
    "s3://$MISSING_BUCKET"
assert_ok $? "multipart upload to a missing bucket completes with \"--s3ignoreerrors\""

assert_eq "$(json_error_count "$ELB_JSON" WRITE total)" "$EXPECTED_OBJECTS" \
    "write phase reports $EXPECTED_OBJECTS failed operations, one per object"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done ios)" "0" \
    "write phase reports no completed I/O operations, because CreateMultipartUpload failed before any part was uploaded"
assert_eq "$(json_value "$ELB_JSON" WRITE last_done entries)" "$EXPECTED_OBJECTS" \
    "write phase still reports $EXPECTED_OBJECTS processed entries"
assert_eq "$(opslog_count "$MULTIPART_OPSLOG" S3UploadPart)" "0" \
    "the operations log has no completed S3UploadPart entries"

################## HeadObject (--stat) and download both fail against a missing bucket ##################

run_elbencho statread404 \
    "${S3_OPTS[@]}" \
    -r --stat --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://$MISSING_BUCKET"
assert_ok $? "stat and read phases against a missing bucket both complete with \"--s3ignoreerrors\""

assert_eq "$(json_phases "$ELB_JSON")" "HEADOBJ READ" \
    "the stat phase (HEADOBJ) ran before the read phase"
assert_eq "$(json_error_count "$ELB_JSON" HEADOBJ http_404)" "$EXPECTED_OBJECTS" \
    "stat phase reports $EXPECTED_OBJECTS operations failed with http status 404"
assert_eq "$(json_error_count "$ELB_JSON" READ http_404)" "$EXPECTED_OBJECTS" \
    "read phase reports $EXPECTED_OBJECTS operations failed with http status 404"

################## Clean up ##################

run_elbencho delete \
    "${S3_OPTS[@]}" \
    -F -D --nodelerr \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES \
    "s3://$BUCKET"
assert_ok $? "delete phase of the objects and the bucket succeeds"
assert_eq "$(json_has_key "$ELB_JSON" RMOBJECTS last_done errors)" "false" \
    "delete phase without errors has no \"errors\" subtree"
