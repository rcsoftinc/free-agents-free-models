#!/usr/bin/env bash
# Phase C: runner.sh fallback must try EVERY distinct agent+model combo
# (best-untried each time) and only fail after all are exhausted. Rate-limits
# are classified as rate_limited (mild penalty), not hard failures.
# Attempts are counted from runner.log (reliable), not stub stdout.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "C fallback exhaustion"

sandbox_on

write_fixture() {
  # 5 researcher/research combos, descending score, so attempt order is m1..m5.
  jq -n '{
    generated_at:"x",
    rankings:{ researcher:{ research:[
      {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
      {agent:"kilo",    model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null},
      {agent:"hermes",  model_id:"openrouter/m3", provider:"openrouter", score:0.93, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"openrouter/m4", provider:"openrouter", score:0.92, attempts:0, successes:0, last_used:null},
      {agent:"kilo",    model_id:"kilo/m5",       provider:"kilo",       score:0.91, attempts:0, successes:0, last_used:null}
    ]}}
  }' > "${ORCH_DIR}/rankings.json"

  jq -n '{
    info:{name:"test-project", path:"/tmp/test-project"},
    description:"",
    plan:{phases:[{name:"p", description:"", tasks:[
      {id:"task-002", role:"researcher", task_type:"research",
       description:"Research JWT auth in Express", files:[], priority:"high", dependencies:["task-001"]}
    ]}]},
    tasks:[], status:"planning", created_at:"x", updated_at:"x"
  }' > "${ORCH_DIR}/project.json"
}

run_task() {
  # $1 = stub mode for all agents, $2 = optional GOOD_MODEL
  clear_modes
  mode_for opencode "$1"; mode_for kilo "$1"; mode_for hermes "$1"
  [[ -n "${2:-}" ]] && export GOOD_MODEL="$2"
  : > "${ORCH_DIR}/runner.log"          # clear so we count only this run
  bash "${LEGACY_DIR}/runner.sh" task-002 >/dev/null 2>&1
  echo "$(jq -r '.status' "${ORCH_DIR}/tasks/task-002.json" 2>/dev/null || echo none)"
}

attempts() { grep -c "Attempt " "${ORCH_DIR}/runner.log"; }
rl_count() { grep -c "rate_limited" "${ORCH_DIR}/runner.log"; }

# C1: all rate-limit except the LAST combo succeeds -> done on attempt 5
write_fixture
status=$(run_task ratelimit "kilo/m5")
assert_eq "C1 task succeeds when last combo works" "$status" "done"
assert_true "C1 fell through failed combos before succeeding (>=2 attempts)" '[[ $(attempts) -ge 2 ]]'

# C2: ALL rate-limit -> must exhaust all 5 then fail (proves > old cap of 3)
write_fixture
status=$(run_task ratelimit "")
assert_eq "C2 task fails when everything is rate-limited" "$status" "failed"
assert_eq "C2 exhausted all 5 combos (no early stop)" "$(attempts)" "5"
assert_eq "C2 every attempt recorded rate_limited (5)" "$(rl_count)" "5"

# C3: all HARD fail except last -> done, first 4 recorded as failure (0.8)
write_fixture
status=$(run_task error "kilo/m5")
assert_eq "C3 task succeeds when last combo works" "$status" "done"
assert_true "C3 fell through failed combos before succeeding (>=2 attempts)" '[[ $(attempts) -ge 2 ]]'
first_id=$(grep "Attempt 1/5" "${ORCH_DIR}/runner.log" | sed -E 's/.*: [a-z]+ ([^ ]+) .*/\1/')
first_score=$(jq -r --arg m "$first_id" '.rankings.researcher.research[] | select(.model_id==$m) | .score' "${ORCH_DIR}/rankings.json")
assert_true "C3 first attempted combo penalized as failure (<0.8)" "awk \"BEGIN{exit !(${first_score} < 0.8)}\""

# C4 (soak): 10 combos all rate-limited -> must exhaust ALL 10 then fail.
# Mirrors the production shape (rankings.researcher.research has 10 entries).
make_rankings() {
  local n="$1"
  jq -n --argjson n "$n" '
    [range(0; $n)] as $idx
    | [ $idx[] | {
        agent: (["opencode","kilo","hermes"][. % 3]),
        model_id: ("combo/m" + ((.+1)|tostring)),
        provider: "p",
        score: (0.95 - .*0.01),
        attempts:0, successes:0, last_used:null
      } ] as $combos
    | { generated_at:"x",
        rankings:{ researcher:{ research: $combos } } }
  ' > "${ORCH_DIR}/rankings.json"
  jq -n '{
    info:{name:"test-project", path:"/tmp/test-project"},
    description:"",
    plan:{phases:[{name:"p", description:"", tasks:[
      {id:"task-002", role:"researcher", task_type:"research",
       description:"x", files:[], priority:"high", dependencies:["task-001"]}
    ]}]},
    tasks:[], status:"planning", created_at:"x", updated_at:"x"
  }' > "${ORCH_DIR}/project.json"
}
make_rankings 10
status=$(run_task ratelimit "")
assert_eq "C4 soak: task fails when all 10 combos rate-limited" "$status" "failed"
assert_eq "C4 soak: exhausted all 10 combos (no early stop at 3)" "$(attempts)" "10"
assert_eq "C4 soak: all 10 attempts recorded rate_limited" "$(rl_count)" "10"

# C5 (timeout guard): every combo hangs; ATTEMPT_TIMEOUT must kill each and the
# run must finish in bounded time (not 10*60s) and still exhaust all combos.
make_rankings 5
export ATTEMPT_TIMEOUT=2
export TASK_TIMEOUT=60
t0=$(date +%s)
status=$(run_task hang "")
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_eq "C5 timeout: task fails when all combos hang" "$status" "failed"
assert_eq "C5 timeout: all 5 hung combos were attempted" "$(attempts)" "5"
assert_true "C5 timeout: run finished in bounded time (${elapsed}s < 40s, not 5*60s)" '[[ $elapsed -lt 40 ]]'
unset ATTEMPT_TIMEOUT TASK_TIMEOUT

end_suite
final_report
