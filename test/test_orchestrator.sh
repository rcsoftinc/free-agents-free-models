#!/usr/bin/env bash
# Phase F: orchestrator.sh generates a valid plan via a stub agent.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "F orchestrator plan generation"

sandbox_on
reset_state baseline

# A minimal project for orchestrator.sh to analyze.
mkdir -p /tmp/test-project
printf '{"name":"test-project","version":"1.0.0"}\n' > /tmp/test-project/package.json
printf 'const http=require("http");\n' > /tmp/test-project/index.js
printf '# Test Project\n' > /tmp/test-project/README.md

# All stub agents return a valid plan JSON.
clear_modes; mode_for opencode plan; mode_for kilo plan; mode_for hermes plan

bash "${REPO_DIR}/orchestrator.sh" /tmp/test-project >/dev/null 2>&1
assert_eq "orchestrator.sh exits 0" "$?" "0"
assert_json_valid "project.json valid" "${ORCH_DIR}/project.json"

n_tasks=$(jq -r '[.plan.phases[].tasks | length] | add' "${ORCH_DIR}/project.json")
assert_true "project.json has at least one planned task (got $n_tasks)" '[[ $n_tasks -gt 0 ]]'

# The generated plan uses the schema fields the runner depends on.
first_role=$(jq -r '.plan.phases[0].tasks[0].role' "${ORCH_DIR}/project.json")
first_tt=$(jq -r '.plan.phases[0].tasks[0].task_type' "${ORCH_DIR}/project.json")
assert_true "plan task has role ($first_role) and task_type ($first_tt)" \
  '[[ -n "$first_role" && -n "$first_tt" ]]'

end_suite
final_report
