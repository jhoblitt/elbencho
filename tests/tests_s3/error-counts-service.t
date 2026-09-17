#!/bin/bash
#
# Per-phase S3 error counts in distributed mode.
#
# Runs a read phase with "--s3ignoreerrors" from a bucket that does not exist
# through two local elbencho service instances, so that every download on
# every service fails with a 404, and verifies that the coordinator's result
# holds the error counts summed up over both services.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1
source "$ELBENCHO_TEST_LIB/minio.sh" || exit 1

NUM_SERVICES=2
NUM_THREADS=2   # per service
NUM_DIRS=1      # per thread
NUM_FILES=3     # per thread and dir
OBJ_SIZE=4096

EXPECTED_OBJECTS=$((NUM_SERVICES * NUM_THREADS * NUM_DIRS * NUM_FILES))

PORT1=""
PORT2=""
HOSTS=""
SERVICE_PIDS=""

require_build_feature s3
require_minio

test_init
tap_plan 10

start_minio
if [ $? -ne 0 ]; then
    tap_bail "Unable to start a minio S3 server instance."
fi

start_service_pair
if [ $? -ne 0 ]; then
    tap_bail "Unable to start two elbencho service instances on consecutive ports."
fi

tap_ok "two elbencho service instances are listening on ports $PORT1 and $PORT2"

################## Every download on every service is a 404 ##################

run_elbencho read404 \
    --hosts "$HOSTS" \
    "${S3_OPTS[@]}" \
    -r --s3ignoreerrors \
    -t $NUM_THREADS -n $NUM_DIRS -N $NUM_FILES -s $OBJ_SIZE -b $OBJ_SIZE \
    "s3://$(bucket_name)-missing"
assert_ok $? "distributed read phase from a missing bucket completes with \"--s3ignoreerrors\""

assert_eq "$(json_config "$ELB_JSON" READ hosts)" "$NUM_SERVICES" \
    "the port range in the host list expanded to $NUM_SERVICES hosts"
assert_eq "$(json_error_count "$ELB_JSON" READ total)" "$EXPECTED_OBJECTS" \
    "coordinator reports the $EXPECTED_OBJECTS failed operations of both services"
assert_eq "$(json_error_count "$ELB_JSON" READ http_404)" "$EXPECTED_OBJECTS" \
    "all failed operations are counted as http status 404"
assert_eq "$(json_value "$ELB_JSON" READ last_done ios)" "$EXPECTED_OBJECTS" \
    "coordinator reports the $EXPECTED_OBJECTS attempted I/O operations of both services"
assert_eq "$(csv_value "$ELB_CSV" READ "errors by kind")" "http_404=$EXPECTED_OBJECTS" \
    "csv \"errors by kind\" column lists the summed up 404s"
assert_eq "$(res_row_count "$ELB_RES" "Errors")" "1" \
    "txt result contains one \"Errors\" row"
assert_eq "$(res_row_count "$ELB_RES" "Svc errors")" "1" \
    "txt result contains one \"Svc errors\" row with the per-service breakdown"

################## Terminate the services ##################

run_elbencho quit --hosts "$HOSTS" --quit
assert_ok $? "\"--quit\" is accepted by both services"
