#!/usr/bin/env bash
# Phase H: runner.sh --parallel executes independent tasks concurrently.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "H parallel execution"

sandbox_on

write_fixture() {
  jq -n '{
    generated_at:"x",
    rankings:{ researcher:{ research:[
      {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
      {agent:"kilo",    model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null}
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

# 3 independent tasks, each succeeds on its best combo. Run with parallelism 2.
write_fixture
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
: > "${ORCH_DIR}/runner.log"
bash "${LEGACY_DIR}/runner.sh" --parallel 2 >/dev/null 2>&1

for t in task-a task-b task-c; do
  st=$(jq -r --arg id "$t" '.tasks[] | select(.id==$id) | .status' "${ORCH_DIR}/project.json")
  assert_eq "H parallel: $t completed" "$st" "done"
done
assert_eq "H parallel: 3 tasks executed" "$(grep -c "Attempt " "${ORCH_DIR}/runner.log")" "3"

end_suite
final_report
