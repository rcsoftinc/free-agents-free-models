#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "no_lane vs exhaustion"
fixture_registry 3 || exit 1
sandbox_on

# Phase 1: All lanes busy (exit 5)
# Put all three stubs in `hang` mode so runs hold their lease.
mode_for opencode hang
mode_for kilo hang
mode_for hermes hang

# Start three background runs, one pinned to each of b0:fp0, b1:fp1, b2:fp2
"$REPO/bin/run.sh" -b b0:fp0 "do a thing" </dev/null 2>/dev/null &
pid0=$!
"$REPO/bin/run.sh" -b b1:fp1 "do a thing" </dev/null 2>/dev/null &
pid1=$!
"$REPO/bin/run.sh" -b b2:fp2 "do a thing" </dev/null 2>/dev/null &
pid2=$!

# Wait for the processes to acquire their leases (~2s)
sleep 2

# Run one more UNPINNED task with a short --max-attempts
# Should exit 5 (no lane available) because all buckets are held
out=$("$REPO/bin/run.sh" --max-attempts 1 "unpinned task" 2>&1)
rc=$?
stderr_out=$(echo "$out" | tail -1)

assert_eq "all lanes busy: exit code 5" "$rc" "5"
assert_contains "all lanes busy: stderr contains 'no lane available'" "$out" "no lane available"

# Kill the background jobs
kill "$pid0" "$pid1" "$pid2" 2>/dev/null || true
wait "$pid0" "$pid1" "$pid2" 2>/dev/null || true

# Phase 2: Exhausted (exit 2)
# With all three stubs in `error` mode and NO lane held,
# run should exit 2 (exhausted) because all attempts fail
mode_for opencode error
mode_for kilo error
mode_for hermes error

out=$("$REPO/bin/run.sh" --max-attempts 3 "do a thing" 2>&1)
rc=$?
stderr_out=$(echo "$out" | tail -1)

assert_eq "all failed: exit code 2" "$rc" "2"
assert_contains "all failed: stderr contains 'exhausted'" "$stderr_out" "exhausted"

# Phase 3: Verify the two exit codes differ (5 vs 2)
assert_ne "exit codes differ: 5 vs 2" "5" "2"

# Clean up modes
clear_modes

end_suite
final_report