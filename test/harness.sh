#!/usr/bin/env bash
# harness.sh - shared test library for the orchestrator test suite.
# Source this file from each test_*.sh script.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
# Layer B was retired to legacy/ (see legacy/README.md). Its suites still run
# there, so a superseded engine cannot rot silently while it remains on disk.
BIN_DIR="${REPO_DIR}/bin"
STUBS_DIR="${HARNESS_DIR}/stubs"
ROOT_LOG="${HARNESS_DIR}/test.log"

# SAFETY BY DEFAULT, not by remembering. State went machine-wide, so any suite
# that simply does not set FREE_AGENTS_STATE now points at the developer's real
# registry - and one did, bootstrapping fabricated credentials over a live
# 419-model registry. Sourcing this file redirects state to a throwaway directory
# immediately, before any suite body runs. fixture_registry then overrides it
# with its own; a suite that sets it explicitly wins over both.
#
# This is placed here rather than in begin_suite because suites call
# begin_suite BEFORE fixture_registry - a guard at that point fires before the
# fixture exists and aborts everything.
export FREE_AGENTS_STATE="${FREE_AGENTS_STATE:-$(mktemp -d)/state}"
mkdir -p "$FREE_AGENTS_STATE"

# Offline test settings: stub agents only, short timeouts, no real credentials.
export BACKOFF_BASE=0 BACKOFF_CAP=0 RUNNER_SKIP_PREFLIGHT=1
export ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-10}" PROBE_TIMEOUT=10

# Build a throwaway credential registry and point the engine at it.
# Every test gets its own, so tests cannot contaminate each other or the
# developer's real registry - which lives in <repo>/state and must never be
# touched by a test run.
#
#   fixture_registry [nbuckets]    sets FREE_AGENTS_STATE and FIXTURE_DIR
#
# Call it PLAINLY, never as `d=$(fixture_registry)`: command substitution runs in
# a subshell, the export dies with it, and the test then runs against the
# developer's REAL registry - mutating live credential state. The guard below
# refuses to proceed if that happens.
#
# Bucket i is reachable through a stub agent, so behaviour is deterministic:
#   b0 -> opencode   b1 -> kilo   b2 -> hermes
fixture_registry() {
  local n="${1:-3}" dir agents=(opencode kilo hermes)
  dir="$(mktemp -d)"
  mkdir -p "$dir"
  {
    printf '{"schema":1,"generated_at":"2026-01-01T00:00:00Z","phantom_routes":[],"buckets":{'
    local i sep=""
    for ((i=0; i<n; i++)); do
      local a="${agents[$((i % 3))]}"
      printf '%s"b%d:fp%d":{"id":"b%d:fp%d","provider":"p%d","credential_fp":"fp%d",' \
        "$sep" "$i" "$i" "$i" "$i" "$i" "$i"
      printf '"credential_sources":["fixture"],"reachable_via":["%s"],"preferred_agent":"%s",' "$a" "$a"
      printf '"limits":{},"health":{"state":"ok","consecutive_failures":0,"cooldown_until":0,"last_used":0},'
      printf '"models":[{"upstream":"m%d-a","free":true,"routes":[{"agent":"%s","model_arg":"m%d-a","provider":"p%d"}],"probe":{"state":"ok","at":null,"ms":1}},' "$i" "$a" "$i" "$i"
      printf '{"upstream":"m%d-b","free":true,"routes":[{"agent":"%s","model_arg":"m%d-b","provider":"p%d"}],"probe":{"state":"unprobed","at":null,"ms":null}}]}' "$i" "$a" "$i" "$i"
      sep=","
    done
    printf '},"counts":{"buckets":%d,"free_models":%d,"phantom":0}}' "$n" "$((n*2))"
  } > "${dir}/buckets.json"
  jq -e . "${dir}/buckets.json" >/dev/null || { echo "fixture_registry: bad JSON" >&2; return 1; }
  export FREE_AGENTS_STATE="$dir"
  FIXTURE_DIR="$dir"

  # Refuse to run if the engine would still read the real registry.
  local seen
  seen="$(FREE_AGENTS_STATE="$dir" bash -c '. '"${REPO_DIR}"'/bin/lib/common.sh; printf "%s" "$STATE_DIR"')"
  if [[ "$seen" != "$dir" ]]; then
    echo "fixture_registry: engine resolved state to '$seen', not the fixture." >&2
    echo "  Did you call this inside \$( )? The export cannot escape a subshell." >&2
    return 1
  fi
  return 0
}

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
# Layer B's snapshot/reset helpers were removed with it. Tests now build their
# own registry fixture instead (see fixture_registry below), which is faster and
# does not depend on a live machine's credentials.

# ---- reporting ----
# A test must never be able to write the developer's real registry. This became
# possible the moment state defaulted to a machine-wide path: any suite that
# simply does not set FREE_AGENTS_STATE now points at live state, and
# test_bootstrap.sh did exactly that - bootstrapping FABRICATED credentials over
# a real 419-model registry.
#
# fixture_registry already guards its own path; this guards every suite,
# including the ones that never call it. It resolves STATE_DIR the way the engine
# does and refuses to run if the answer is not disposable.
assert_state_is_disposable() {
  local resolved
  resolved="$(bash -c '. '"${REPO_DIR}"'/bin/lib/common.sh; printf "%s" "$STATE_DIR"' 2>/dev/null)"
  case "$resolved" in
    /tmp/*|/var/tmp/*) return 0 ;;
    *)
      echo "REFUSING TO RUN: this suite would use real state at" >&2
      echo "  $resolved" >&2
      echo "Set FREE_AGENTS_STATE to a temp dir, or call fixture_registry first." >&2
      exit 3 ;;
  esac
}

begin_suite() { assert_state_is_disposable; TT_CURRENT="$1"; echo "========================================"; echo "SUITE: $1"; echo "========================================"; }
end_suite() { echo "----------------------------------------"; echo "SUITE $TT_CURRENT: passed=$TT_PASSED failed=$TT_FAILED"; echo; }
final_report() {
  echo "========================================"
  echo "TOTAL: passed=$TT_PASSED failed=$TT_FAILED"
  echo "========================================"
  if [[ $TT_FAILED -gt 0 ]]; then return 1; else return 0; fi
}
