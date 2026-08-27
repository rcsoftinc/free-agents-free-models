#!/usr/bin/env bash
# Phase B: classify_result() (exposed via runner.sh --classify) correctly
# distinguishes rate_limited (exit 0 + credit text) from success/failure.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "B classify_result"

classify() {
  local text="$1" code="${2:-0}"
  CLASSIFY_EXIT_CODE="$code" bash "${REPO_DIR}/runner.sh" --classify <<< "$text"
}

CREDIT='Error: This request would exceed your available credits given your in-flight requests. Retry after in-flight requests settle, or add credits.'
RATELIMIT='HTTP 429 Too Many Requests - rate limit exceeded, try again later'
UPSTREAM='HTTP 503 Service Unavailable: upstream rate limit reached'
OK='{"ok":true,"summary":"stub success"}'
ERR='generic failure: something went wrong'
EMPTY=''
FALSEPOS='You get credit for the work done on this task.'
PAYMENT='Payment processed; your available credits were updated.'

assert_eq "credit error + exit0 -> rate_limited" "$(classify "$CREDIT" 0)" "rate_limited"
assert_eq "429 + exit0 -> rate_limited" "$(classify "$RATELIMIT" 0)" "rate_limited"
assert_eq "503 upstream + exit0 -> rate_limited (no false negative)" "$(classify "$UPSTREAM" 0)" "rate_limited"
assert_eq "valid result + exit0 -> success" "$(classify "$OK" 0)" "success"
assert_eq "generic error + exit1 -> failure" "$(classify "$ERR" 1)" "failure"
assert_eq "empty result + exit0 -> failure (not success)" "$(classify "$EMPTY" 0)" "failure"
# False-positive guards: 'credit' / 'available credits' alone must NOT trip.
assert_eq "benign 'credit' text -> success (no false positive)" "$(classify "$FALSEPOS" 0)" "success"
assert_eq "benign 'available credits' text -> success (no false positive)" "$(classify "$PAYMENT" 0)" "success"

end_suite
final_report
