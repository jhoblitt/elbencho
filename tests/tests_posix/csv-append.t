#!/bin/bash
#
# Appending a second run's result row to an existing csv result file.
#
# elbencho refuses to append a row to a csv file whose header was written with
# a different number of columns than the running binary expects
# ("CSVFILE_EXPECTED_COMMAS" in ProgArgs.cpp), which is the only thing that
# protects an existing csv file from getting a row of the wrong shape. This
# test guards that constant: two runs write to the same "--csvfile", and if the
# per-phase error columns and the constant ever drift apart again, the second
# run aborts instead of appending.
#
# "run_elbencho" cannot be used here because it puts every run's csv file at a
# different path, but both runs here must write to the SAME one, so the binary
# is invoked directly, the same way "run_elbencho" does internally.

source "$(dirname "$(readlink -f "$0")")/../lib/testlib.sh" || exit 1

test_init
tap_plan 4

DATA_DIR="$TEST_DIR/data"
DATA_FILE="$DATA_DIR/file"
CSVFILE="$TEST_DIR/append.csv"

mkdir -p "$DATA_DIR"

# run_direct TAG
# One tiny write phase, appending to the shared $CSVFILE. Sets $rc to its exit
# code.
run_direct()
{
    local tag="$1"
    local out="$TEST_DIR/$tag.out"

    trace_cmd "elbencho run \"$tag\"" \
        "$ELBENCHO_TEST_BIN" \
        --nolive --no0usecerr \
        --resfile /dev/null --csvfile "$CSVFILE" --jsonfile /dev/null \
        -w -t 1 -s 4k -b 4k \
        "$DATA_FILE"

    timeout --kill-after=5s --signal=TERM "$ELBENCHO_TEST_CMD_TIMEOUT" \
        "$ELBENCHO_TEST_BIN" \
        --nolive --no0usecerr \
        --resfile /dev/null --csvfile "$CSVFILE" --jsonfile /dev/null \
        -w -t 1 -s 4k -b 4k \
        "$DATA_FILE" > "$out" 2>&1
    rc=$?

    trace_result "elbencho run \"$tag\"" "$rc" "" "$out"

    if [ $rc -ne 0 ]; then
        tap_diag "Output of failed elbencho run \"$tag\":"
        tap_diag_file "$out"
    fi
}

################## First run creates the csv file ##################

run_direct first
assert_ok "$rc" "the first run creates the csv file"

################## Second run appends to the same csv file ##################

run_direct second
assert_ok "$rc" "the second run appends to the existing csv file instead of aborting"

assert_eq "$(wc -l < "$CSVFILE" | tr -d ' ')" "3" \
    "the csv file has one header row plus one result row per run"
assert_eq "$(awk -F, '{print NF}' "$CSVFILE" | sort -u | wc -l | tr -d ' ')" "1" \
    "every row has the same number of comma separated fields as the header"
