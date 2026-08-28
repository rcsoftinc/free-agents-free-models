#!/usr/bin/env bash
# Phase A3: handoff.sh capture / get / compress / full (pure local JSON ops).
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "A3 handoff"

sandbox_on
reset_state baseline

# baseline has tasks/task-001.json (done) and handoffs/task-001.json.
assert_eq "task-001.json present" "$(jq -r '.status' "${ORCH_DIR}/tasks/task-001.json")" "done"

# capture idempotent
out=$(bash "${LEGACY_DIR}/handoff.sh" task-001 capture 2>&1); assert_eq "capture exits 0" "$?" "0"
assert_json_valid "handoff task-001 valid" "${ORCH_DIR}/handoffs/task-001.json"
assert_contains "handoff summarizes route" "$(jq -r '.summary' "${ORCH_DIR}/handoffs/task-001.json")" "GET"

# get with no deps -> fresh start message
out=$(bash "${LEGACY_DIR}/handoff.sh" task-001 get 2>&1); assert_contains "get reports no deps" "$out" "No dependencies"

# compress --force reduces stored summary to <=500 chars and sets flags
orig_len=$(jq -r '.summary' "${ORCH_DIR}/handoffs/task-001.json" | wc -c)
bash "${LEGACY_DIR}/handoff.sh" task-001 compress --force >/dev/null 2>&1
assert_eq "compress sets compressed=true" "$(jq -r '.compressed' "${ORCH_DIR}/handoffs/task-001.json")" "true"
clen=$(jq -r '.summary' "${ORCH_DIR}/handoffs/task-001.json" | wc -c)
assert_true "compressed summary <=500 chars (was $orig_len, now $clen)" '[[ $clen -le 500 ]]'

# full context for a dependent task (create a dummy task file with a dep)
jq -n '{id:"task-X", role:"coder", task_type:"implementation", description:"x", files:[], dependencies:["task-001"]}' \
  > "${ORCH_DIR}/tasks/task-X.json"
out=$(bash "${LEGACY_DIR}/handoff.sh" task-X full 2>&1)
assert_contains "full context includes dependency task-001" "$out" "task-001"

end_suite
final_report
