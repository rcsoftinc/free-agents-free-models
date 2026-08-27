#!/usr/bin/env bash
# Phase G: runner.sh --resume re-runs only FAILED tasks until done.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "G resume engine"

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
      {id:"task-002", role:"researcher", task_type:"research", description:"x", files:[], priority:"high", dependencies:[]}
    ]}]},
    tasks:[],
    status:"planning", created_at:"x", updated_at:"x"
  }' > "${ORCH_DIR}/project.json"
}

# G1: a previously FAILED task is retried and completes on resume.
write_fixture
# Seed a failed prior attempt.
jq '.tasks += [{id:"task-002", status:"failed", result:{summary:"boom"}, updated_at:"x"}]' \
  "${ORCH_DIR}/project.json" > "${ORCH_DIR}/project.json.tmp" \
  && mv "${ORCH_DIR}/project.json.tmp" "${ORCH_DIR}/project.json"
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
: > "${ORCH_DIR}/runner.log"
bash "${REPO_DIR}/runner.sh" --resume >/dev/null 2>&1
status=$(jq -r '.tasks[] | select(.id=="task-002") | .status' "${ORCH_DIR}/project.json")
assert_eq "G1 --resume retries a failed task to done" "$status" "done"
assert_contains "G1 resume re-ran the task" "$(cat "${ORCH_DIR}/runner.log")" "Attempt 1/2"

# G2: a project with NO failed tasks does nothing on --resume.
write_fixture
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
: > "${ORCH_DIR}/runner.log"
bash "${REPO_DIR}/runner.sh" --resume >/dev/null 2>&1
executed=$(grep -c "Attempt " "${ORCH_DIR}/runner.log")
assert_eq "G2 --resume with no failed tasks executes nothing" "$executed" "0"

end_suite
final_report
