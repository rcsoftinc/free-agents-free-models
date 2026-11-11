#!/usr/bin/env bash
# The error taxonomy's own self-test (bin/lib/classify.sh --self-test), as a
# suite: every rule's attribution and precedence, the real messages seen in the
# wild, retry windows, cooldown escalation. `fa doctor` runs it too, but a
# regression there only shows when someone reads doctor's output; here it
# fails CI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "the error taxonomy's self-test"
out="$(bash "$REPO/bin/lib/classify.sh" --self-test 2>&1)"; rc=$?
assert_eq "classify.sh --self-test exits 0" "$rc" "0"
assert_contains "  ...and says PASS" "$out" "^PASS$"
assert_not_contains "  ...with no failing case" "$out" "^  FAIL"
end_suite
final_report
