#!/usr/bin/env bash
# Phase I: agent/provider distribution.
# Verifies the scheduler (a) divides tasks across agents (LRU + provider-spread),
# (b) enforces a within-task provider gap so the same API is not hit back-to-back,
# (c) assigns distinct agents to concurrent parallel tasks, and (d) still exhausts
# every combo before failing.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "I agent/provider distribution"

sandbox_on

# Shared trace of every stub invocation: agent|model_id|epoch
TRACE="$(mktemp)"
export STUB_TRACE="${TRACE}"

provider_of() { echo "$1" | cut -d'/' -f1; }

# Reset distribution state so each scenario starts from a clean slate (the agent
# scheduler's history otherwise carries across scenarios within this suite).
fresh_state() { reset_state baseline; }

# T1: 3 tasks, all agents available, every combo succeeds -> assigned agents
# should be spread across all 3 agents (not all on one).
write_t1() {
  jq -n '{
    generated_at:"x",
    rankings:{ researcher:{ research:[
      {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
      {agent:"kilo",    model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null},
      {agent:"hermes",  model_id:"openrouter/m3", provider:"openrouter", score:0.93, attempts:0, successes:0, last_used:null}
    ]}}
  }' > "${ORCH_DIR}/rankings.json"
  jq -n '{
    info:{name:"test-project", path:"/tmp/test-project"},
    description:"",
    plan:{phases:[{name:"p", description:"", tasks:[
      {id:"task-a", role:"researcher", task_type:"research", description:"a", files:[], priority:"high", dependencies:[]},
      {id:"task-b", role:"researcher", task_type:"research", description:"b", files:[], priority:"high", dependencies:[]},
      {id:"task-c", role:"researcher", task_type:"research", description:"c", files:[], priority:"high", dependencies:[]}
    ]}]},
    tasks:[], status:"planning", created_at:"x", updated_at:"x"
  }' > "${ORCH_DIR}/project.json"
}
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
: > "${TRACE}"
fresh_state
write_t1
bash "${LEGACY_DIR}/runner.sh" >/dev/null 2>&1
agents=$(cut -d'|' -f1 "${TRACE}" | sort -u | wc -l)
assert_eq "T1 tasks divided across all 3 agents" "${agents}" "3"

# T2: single task, ONE agent (opencode) with alternating providers across its
# combos. All rate-limit except the LAST (kilo/m5). Provider gap must produce
# openrouter, kilo, openrouter, kilo -- never the same provider twice in a row.
write_t2() {
  jq -n '{
    generated_at:"x",
    rankings:{ researcher:{ research:[
      {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"openrouter/m4", provider:"openrouter", score:0.92, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"kilo/m5",       provider:"kilo",       score:0.91, attempts:0, successes:0, last_used:null}
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
}
clear_modes; mode_for opencode ratelimit; mode_for kilo ratelimit; mode_for hermes ratelimit
export GOOD_MODEL="kilo/m5"
: > "${TRACE}"
fresh_state
write_t2
bash "${LEGACY_DIR}/runner.sh" task-002 >/dev/null 2>&1
status=$(jq -r '.status' "${ORCH_DIR}/tasks/task-002.json" 2>/dev/null || echo none)
assert_eq "T2 task succeeds on last combo" "$status" "done"
# Verify no two consecutive attempts share a provider.
provs=$(cut -d'|' -f2 "${TRACE}" | while read -r m; do provider_of "$m"; done)
prev=""; gap_ok=1
while read -r p; do
  [[ -n "$prev" && "$p" == "$prev" ]] && gap_ok=0
  prev="$p"
done < <(echo "$provs")
assert_eq "T2 no two consecutive attempts share a provider" "$gap_ok" "1"
unset GOOD_MODEL

# T3: 3 independent tasks run in parallel with --parallel 3 and a 'slow' stub so
# they overlap; each must be assigned a DISTINCT agent.
clear_modes; mode_for opencode slow; mode_for kilo slow; mode_for hermes slow
: > "${TRACE}"
fresh_state
write_t1
bash "${LEGACY_DIR}/runner.sh" --parallel 3 >/dev/null 2>&1
par_agents=$(cut -d'|' -f1 "${TRACE}" | sort -u | wc -l)
assert_eq "T3 parallel tasks assigned distinct agents" "${par_agents}" "3"

# T4: exhaustion preserved -- single agent, 5 alternating-provider combos, all
# rate-limited. Must try all 5 AND still alternate providers (no early stop).
write_t4() {
  jq -n '{
    generated_at:"x",
    rankings:{ researcher:{ research:[
      {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"openrouter/m4", provider:"openrouter", score:0.92, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"kilo/m5",       provider:"kilo",       score:0.91, attempts:0, successes:0, last_used:null},
      {agent:"opencode", model_id:"openrouter/m7", provider:"openrouter", score:0.90, attempts:0, successes:0, last_used:null}
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
}
clear_modes; mode_for opencode ratelimit; mode_for kilo ratelimit; mode_for hermes ratelimit
: > "${TRACE}"
fresh_state
write_t4
: > "${ORCH_DIR}/runner.log"
bash "${LEGACY_DIR}/runner.sh" task-002 >/dev/null 2>&1
status=$(jq -r '.status' "${ORCH_DIR}/tasks/task-002.json" 2>/dev/null || echo none)
attempts=$(grep -c "Attempt " "${ORCH_DIR}/runner.log")
assert_eq "T4 task fails when all combos rate-limited" "$status" "failed"
assert_eq "T4 exhausted all 5 combos" "$attempts" "5"
provs=$(cut -d'|' -f2 "${TRACE}" | while read -r m; do provider_of "$m"; done)
prev=""; gap_ok=1
while read -r p; do
  [[ -n "$prev" && "$p" == "$prev" ]] && gap_ok=0
  prev="$p"
done < <(echo "$provs")
assert_eq "T4 provider gap held while exhausting" "$gap_ok" "1"

rm -f "${TRACE}"
end_suite
final_report
