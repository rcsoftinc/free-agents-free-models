#!/usr/bin/env bash
# ============================================================================
# classify-error.sh — shared error classification for oc.sh
#
# Usage (source this file):
#   source "$SCRIPT_DIR/classify-error.sh"
#   status="$(classify "$error_text")"
#
# Or standalone:
#   bash classify-error.sh "error text here"
#
# Output (stdout): one of:
#   rate_limited | no_credits | context_overflow | auth_error | dead
# ============================================================================
classify() { # arg: text -> echoes status
  local t
  if [[ $# -gt 0 ]]; then
    t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  else
    t="$(cat | tr '[:upper:]' '[:lower:]')"
  fi
  if   printf '%s' "$t" | grep -Eq 'rate.?limit|429|temporarily rate'; then echo "rate_limited"
  elif printf '%s' "$t" | grep -Eq 'insufficient balance|quota|billing'; then echo "no_credits"
  elif printf '%s' "$t" | grep -Eq 'context length|too large|too long'; then echo "context_overflow"
  elif printf '%s' "$t" | grep -Eq 'unauthorized|invalid api key|401'; then echo "auth_error"
  else echo "dead"; fi
}

# when executed directly (not sourced), classify the first argument or stdin
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--self-test" ]]; then
    pass=0; fail=0
    run_test() {
      local label="$1" input="$2" expected="$3"
      local got
      got="$(classify "$input")"
      if [[ "$got" == "$expected" ]]; then pass=$((pass+1))
      else fail=$((fail+1)); echo "FAIL: $label (got '$got', expected '$expected')" >&2; fi
    }
    run_test "rate_limited"   "temporarily rate-limited upstream 429" "rate_limited"
    run_test "rate_limited 2" "Rate limit exceeded"                  "rate_limited"
    run_test "no_credits"     "Unauthorized: Insufficient balance"   "no_credits"
    run_test "no_credits 2"   "quota exceeded"                       "no_credits"
    run_test "no_credits 3"   "billing error"                        "no_credits"
    run_test "context"        "context length exceeded"              "context_overflow"
    run_test "context 2"      "request too long"                     "context_overflow"
    run_test "auth_error"     "unauthorized"                         "auth_error"
    run_test "auth_error 2"   "invalid api key"                      "auth_error"
    run_test "auth_error 3"   "HTTP 401"                             "auth_error"
    run_test "dead"           "UnknownError"                         "dead"
    run_test "dead 2"         "something broke"                      "dead"
    run_test "empty"          ""                                     "dead"
    echo "classify-error self-test: $pass passed, $fail failed"
    [[ $fail -eq 0 ]] && exit 0 || exit 1
  elif [[ $# -gt 0 ]]; then
    classify "$1"
  else
    classify
  fi
fi
