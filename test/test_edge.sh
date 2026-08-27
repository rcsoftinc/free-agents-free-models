#!/usr/bin/env bash
# Phase E: edge cases - dedupe, compress idempotency, empty-files prompt, dep gating.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "E edge cases"

sandbox_on

write_fixture() {
  jq -n '{
    generated_at:"x",
    rankings:{
      researcher:{ analysis:[
        {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null}
      ], research:[
        {agent:"opencode", model_id:"openrouter/m1", provider:"openrouter", score:0.95, attempts:0, successes:0, last_used:null},
        {agent:"kilo",    model_id:"kilo/m2",       provider:"kilo",       score:0.94, attempts:0, successes:0, last_used:null},
        {agent:"hermes",  model_id:"openrouter/m3", provider:"openrouter", score:0.93, attempts:0, successes:0, last_used:null}
      ]}
    }
  }' > "${ORCH_DIR}/rankings.json"
  jq -n '{
    info:{name:"test-project", path:"/tmp/test-project"},
    description:"",
    plan:{phases:[{name:"p", description:"", tasks:[
      {id:"task-001", role:"researcher", task_type:"analysis", description:"analyze", files:["/tmp/test-project/index.js"], priority:"high", dependencies:[]},
      {id:"task-002", role:"researcher", task_type:"research", description:"Research JWT auth in Express", files:[], priority:"high", dependencies:["task-001"]}
    ]}]},
    tasks:[], status:"planning", created_at:"x", updated_at:"x"
  }' > "${ORCH_DIR}/project.json"
}

# E1: dedupe - running the same task twice yields exactly ONE .tasks entry.
write_fixture
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
stub_log_new
bash "${REPO_DIR}/runner.sh" task-002 >/dev/null 2>&1
bash "${REPO_DIR}/runner.sh" task-002 >/dev/null 2>&1
cnt=$(jq -r '[.tasks[] | select(.id=="task-002")] | length' "${ORCH_DIR}/project.json")
assert_eq "E1 re-run does not duplicate .tasks entry (got $cnt)" "$cnt" "1"

# E3: empty files[] research task builds a valid prompt and completes.
write_fixture
clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
bash "${REPO_DIR}/runner.sh" task-002 >/dev/null 2>&1
status=$(jq -r '.tasks[] | select(.id=="task-002") | .status' "${ORCH_DIR}/project.json")
assert_eq "E3 empty-files research task completes" "$status" "done"
summary=$(jq -r '.tasks[] | select(.id=="task-002") | .result.summary' "${ORCH_DIR}/project.json")
assert_not_contains "E3 saved summary is free of ANSI codes" "$summary" $'\x1b'

# E2: compress.sh without --force on an already-compressed handoff exits 0 & warns.
write_fixture
# Ensure a handoff exists and is NOT yet compressed.
bash "${REPO_DIR}/handoff.sh" task-001 capture >/dev/null 2>&1
jq '.compressed = false' "${ORCH_DIR}/handoffs/task-001.json" > "${ORCH_DIR}/handoffs/task-001.json.tmp" \
  && mv "${ORCH_DIR}/handoffs/task-001.json.tmp" "${ORCH_DIR}/handoffs/task-001.json"
bash "${REPO_DIR}/compress.sh" task-001 >/dev/null 2>&1   # first compress (marks compressed)
out=$(bash "${REPO_DIR}/compress.sh" task-001 2>&1); rc=$?
assert_eq "E2 re-compress without --force exits 0" "$rc" "0"
assert_contains "E2 re-compress reports already compressed" "$out" "already compressed"

# E4: a dependency still 'running' must block the dependent task.
write_fixture
# Mark task-001 as running (not done) so task-002 (depends on it) stays blocked.
jq '.tasks += [{id:"task-001", status:"running", result:{summary:"x"}, updated_at:"x"}]' \
  "${ORCH_DIR}/project.json" > "${ORCH_DIR}/project.json.tmp" \
  && mv "${ORCH_DIR}/project.json.tmp" "${ORCH_DIR}/project.json"
rm -f "${ORCH_DIR}/tasks/task-002.json"
: > "${ORCH_DIR}/runner.log"
bash "${REPO_DIR}/runner.sh" >/dev/null 2>&1   # run_all_tasks: nothing should be available
executed=$(grep -c "Attempt " "${ORCH_DIR}/runner.log")
assert_eq "E4 no task executed while dep is running" "$executed" "0"
assert_true "E4 task-002 result file not created" '[[ ! -f "${ORCH_DIR}/tasks/task-002.json" ]]'

end_suite
final_report
