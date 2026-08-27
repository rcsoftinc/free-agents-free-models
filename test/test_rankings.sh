#!/usr/bin/env bash
# Phase A2: rankings.sh builds rankings.json from a catalog with free models.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "A2 rankings"

sandbox_on
reset_state baseline

# Write a controlled catalog with 3 free, large-context models.
jq -n '{
  agents: {opencode:{installed:true,version:"x"}, kilo:{installed:true,version:"x"}, hermes:{installed:true,version:"x"}},
  models: [
    {agent:"opencode", model_id:"opencode/a", provider:"opencode", context_window:1000000, cost_input:0, free:true, status:"active", capabilities:[]},
    {agent:"kilo", model_id:"kilo/b", provider:"kilo", context_window:300000, cost_input:0, free:true, status:"active", capabilities:[]},
    {agent:"hermes", model_id:"openrouter/c", provider:"openrouter", context_window:200000, cost_input:0, free:true, status:"active", capabilities:[]}
  ],
  filters:{min_context_window:200000, excluded_models:["opencode/big-pickle"]},
  discovered_at:"x"
}' > "${ORCH_DIR}/catalog.json"

bash "${REPO_DIR}/rankings.sh" >/dev/null 2>&1
assert_eq "rankings.sh exits 0" "$?" "0"
assert_json_valid "rankings.json valid" "${ORCH_DIR}/rankings.json"

n=$(jq -r '.rankings.researcher.research | length' "${ORCH_DIR}/rankings.json")
assert_eq "researcher.research has 3 combos" "$n" "3"

top=$(jq -r '.rankings.researcher.research[0].model_id' "${ORCH_DIR}/rankings.json")
assert_eq "top researcher.research combo is highest context (opencode/a)" "$top" "opencode/a"

# All required roles/task_types present
for rt in "orchestrator/orchestration" "researcher/analysis" "coder/implementation" "debugger/bug_fix" "reviewer/code_review" "planner/planning"; do
  role="${rt%%/*}"; tt="${rt##*/}"
  cnt=$(jq -r --arg r "$role" --arg t "$tt" '(.rankings[$r][$t] // []) | length' "${ORCH_DIR}/rankings.json")
  assert_true "rankings has $rt ($cnt entries)" '[[ $cnt -gt 0 ]]'
done

end_suite
final_report
