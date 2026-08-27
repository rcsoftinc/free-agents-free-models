#!/usr/bin/env bash
# Phase J: backoff between attempts after a rate_limited result.
# Unit-tests the pure helpers via debug hooks (no real sleeps), plus one
# integration test that actually applies a short backoff during a real run.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "J backoff on rate-limit"

# Use real (non-zero) backoff constants for the unit tests; the harness exports 0.
export BACKOFF_BASE=5 BACKOFF_CAP=60 BACKOFF_FACTOR=2
RUNNER="${REPO_DIR}/runner.sh"

# --- Unit: next_backoff via --backoff hook ---
assert_eq "backoff attempt1 = base (5)"        "$(bash "$RUNNER" --backoff 1)" "5"
assert_eq "backoff attempt2 = base*factor (10)" "$(bash "$RUNNER" --backoff 2)" "10"
assert_eq "backoff attempt3 = base*factor^2 (20)" "$(bash "$RUNNER" --backoff 3)" "20"
assert_eq "backoff attempt6 capped at CAP (60)"  "$(bash "$RUNNER" --backoff 6)" "60"
assert_eq "backoff honors Retry-After (30)"      "$(bash "$RUNNER" --backoff 1 30)" "30"
assert_eq "backoff Retry-After capped (200->60)" "$(bash "$RUNNER" --backoff 1 200)" "60"

# --- Unit: retry_after_from via --retry-after hook ---
assert_eq "retry-after parsed" "$(printf 'x Retry-After: 30 y' | bash "$RUNNER" --retry-after)" "30"
assert_eq "retry-after none -> empty" "$(printf 'no header' | bash "$RUNNER" --retry-after)" ""

# --- Integration: a real backoff actually delays the run ---
sandbox_on
reset_state baseline
export BACKOFF_BASE=1 BACKOFF_CAP=2 BACKOFF_FACTOR=2
jq -n '{
  generated_at:"x",
  rankings:{ researcher:{ research:[
    {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
    {agent:"opencode", model_id:"openrouter/m2", provider:"openrouter", score:0.94, attempts:0, successes:0, last_used:null}
  ]}}
}' > "${ORCH_DIR}/rankings.json"
jq -n '{
  info:{name:"test-project", path:"/tmp/test-project"},
  description:"",
  plan:{phases:[{name:"p", description:"", tasks:[
    {id:"task-002", role:"researcher", task_type:"research", description:"x", files:[], priority:"high", dependencies:[]}
  ]}]},
  tasks:[], status:"planning", created_at:"x", updated_at:"x"
}' > "${ORCH_DIR}/project.json"
clear_modes; mode_for opencode ratelimit; mode_for kilo ratelimit; mode_for hermes ratelimit
export GOOD_MODEL="openrouter/m2"
: > "${ORCH_DIR}/runner.log"
t0=$(date +%s)
bash "${REPO_DIR}/runner.sh" task-002 >/dev/null 2>&1
t1=$(date +%s)
elapsed=$((t1 - t0))
status=$(jq -r '.status' "${ORCH_DIR}/tasks/task-002.json" 2>/dev/null || echo none)
assert_eq "integration: task still succeeds after backoff" "$status" "done"
assert_true "integration: backoff added >=1s (elapsed=${elapsed}s)" '[[ $elapsed -ge 1 ]]'
assert_contains "integration: backoff logged" "$(cat "${ORCH_DIR}/runner.log")" "backing off"
unset GOOD_MODEL

end_suite
final_report
