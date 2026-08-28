#!/usr/bin/env bash
# harness.sh - shared test library for the orchestrator test suite.
# Source this file from each test_*.sh script.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
# Layer B was retired to legacy/ (see legacy/README.md). Its suites still run
# there, so a superseded engine cannot rot silently while it remains on disk.
LEGACY_DIR="${REPO_DIR}/legacy"
ORCH_DIR="${LEGACY_DIR}/.orchestrator"
STUBS_DIR="${HARNESS_DIR}/stubs"
ROOT_LOG="${HARNESS_DIR}/test.log"

# Offline test settings: no real API keys, no backoff sleeps, skip pre-flight.
export BACKOFF_BASE=0 BACKOFF_CAP=0 RUNNER_SKIP_PREFLIGHT=1

# ---- counters ----
TT_PASSED=0
TT_FAILED=0
TT_CURRENT=""

# Stub sandboxing is opt-in so Phase D can use the real agents.
_SAVED_PATH="${PATH}"
sandbox_on() { export PATH="${STUBS_DIR}:${_SAVED_PATH}"; }
sandbox_off() { export PATH="${_SAVED_PATH}"; }

# ---- logging ----
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "${ROOT_LOG}"; }
pass() { TT_PASSED=$((TT_PASSED+1)); echo "  PASS: $*"; }
fail() { TT_FAILED=$((TT_FAILED+1)); echo "  FAIL: $*" >&2; }

# ---- assertions ----
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$desc (got: $got)"; else fail "$desc | expected '$want' got '$got'"; fi
}
assert_ne() {
  local desc="$1" got="$2" notwant="$3"
  if [[ "$got" != "$notwant" ]]; then pass "$desc (got: $got)"; else fail "$desc | expected != '$notwant' but got '$got'"; fi
}
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  if echo "$hay" | grep -q -- "$needle"; then pass "$desc"; else fail "$desc | '$needle' not found in: $hay"; fi
}
assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  if echo "$hay" | grep -q -- "$needle"; then fail "$desc | '$needle' unexpectedly present in: $hay"; else pass "$desc"; fi
}
assert_json_valid() {
  local desc="$1" file="$2"
  if jq empty "$file" >/dev/null 2>&1; then pass "$desc (valid JSON)"; else fail "$desc | invalid JSON: $(cat "$file" 2>/dev/null | head -c 200)"; fi
}
assert_true() {
  local desc="$1"
  if eval "$2"; then pass "$desc"; else fail "$desc"; fi
}

# ---- stub control ----
# mode_for agent success|ratelimit|error
mode_for() { export "${1}_STUB_MODE=$2"; }
clear_modes() { unset OPENCODE_STUB_MODE KILO_STUB_MODE HERMES_STUB_MODE GOOD_MODEL; }
stub_log_new() { STUB_LOG_FILE="$(mktemp)"; export STUB_LOG="$STUB_LOG_FILE"; }
stub_log_lines() { [[ -n "${STUB_LOG_FILE:-}" ]] && wc -l < "$STUB_LOG_FILE" || echo 0; }
stub_log_cat() { [[ -n "${STUB_LOG_FILE:-}" ]] && cat "$STUB_LOG_FILE"; }

# ---- state ----
reset_state() { bash "${HARNESS_DIR}/reset.sh" "${1:-baseline}" >/dev/null; }
snapshot_state() { bash "${HARNESS_DIR}/snapshot.sh" "$1" >/dev/null; }

# ---- reporting ----
begin_suite() { TT_CURRENT="$1"; echo "========================================"; echo "SUITE: $1"; echo "========================================"; }
end_suite() { echo "----------------------------------------"; echo "SUITE $TT_CURRENT: passed=$TT_PASSED failed=$TT_FAILED"; echo; }
final_report() {
  echo "========================================"
  echo "TOTAL: passed=$TT_PASSED failed=$TT_FAILED"
  echo "========================================"
  if [[ $TT_FAILED -gt 0 ]]; then return 1; else return 0; fi
}
