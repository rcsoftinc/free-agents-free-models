#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "bucket lease exclusivity"
fixture_registry 3 || exit 1     # 3 fake credential buckets; sets FREE_AGENTS_STATE
sandbox_on                       # puts stub opencode/kilo/hermes on PATH

# --- Test 1: Pin two concurrent runs to the SAME bucket (-b b0:fp0) ---
echo "=== Test 1: Same bucket concurrency ==="

mode_for opencode hang
mode_for kilo success
mode_for hermes success

# Start first run in background with hang mode to hold the lease
bin/run.sh -b b0:fp0 "test prompt" > first_out.txt 2> first_err.txt &
FIRST_PID=$!

# Wait for first to acquire the lease
sleep 1

# Second run pinned to same bucket should fail with exit 5 (no lane available)
timeout 30 bin/run.sh -b b0:fp0 "test prompt2" > second_out.txt 2> second_err.txt
SECOND_EXIT=$?

# Clean up first process
kill "$FIRST_PID" 2>/dev/null || true
wait "$FIRST_PID" 2>/dev/null || true

assert_eq "Test 1a: Second run should exit 5 (no lane)" "$SECOND_EXIT" "5"
assert_contains "Test 1b: stderr should contain 'lane busy'" "$(cat second_err.txt)" "lane busy"

rm -f first_out.txt first_err.txt second_out.txt second_err.txt

# --- Test 2: Two concurrent runs with NO pin must land on DIFFERENT buckets ---
echo "=== Test 2: Different buckets with no pin ==="

mode_for opencode slow
mode_for kilo slow
mode_for hermes slow

# Start both runs in background simultaneously
bin/run.sh "test prompt 1" > run1_out.txt 2> run1_err.txt &
PID1=$!
bin/run.sh "test prompt 2" > run2_out.txt 2> run2_err.txt &
PID2=$!

wait "$PID1"
EXIT1=$?
wait "$PID2"
EXIT2=$?

assert_eq "Test 2a: First unpinned run should succeed" "$EXIT1" "0"
assert_eq "Test 2b: Second unpinned run should succeed" "$EXIT2" "0"

# Extract bucket values from RUN-META lines
BUCKET1=$(grep -e '---RUN-META---' run1_err.txt | sed 's/^---RUN-META--- //' | jq -r '.bucket')
BUCKET2=$(grep -e '---RUN-META---' run2_err.txt | sed 's/^---RUN-META--- //' | jq -r '.bucket')

assert_ne "Test 2c: Concurrent unpinned runs should land on different buckets" "$BUCKET1" "$BUCKET2"

rm -f run1_out.txt run1_err.txt run2_out.txt run2_err.txt

# --- Test 3: A run pinned to a bucket that is free must succeed (exit 0) ---
echo "=== Test 3: Free bucket pin succeeds ==="

mode_for kilo success

timeout 30 bin/run.sh -b b1:fp1 "test prompt" > third_out.txt 2> third_err.txt
THIRD_EXIT=$?

assert_eq "Test 3a: Pinned run on free bucket should succeed" "$THIRD_EXIT" "0"
assert_contains "Test 3b: Should contain RUN-META success" "$(cat third_err.txt)" "---RUN-META---"

rm -f third_out.txt third_err.txt

echo "=== All lease exclusivity tests passed ==="
end_suite
final_report