#!/usr/bin/env bash
# Phase I: compress.sh compresses a handoff using a stub agent (AI path).
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "I compress.sh AI path"

sandbox_on
reset_state baseline

# Ensure a handoff exists, not yet compressed, and a summarizer model is ranked.
bash "${REPO_DIR}/handoff.sh" task-001 capture >/dev/null 2>&1
jq '.compressed = false' "${ORCH_DIR}/handoffs/task-001.json" > "${ORCH_DIR}/handoffs/task-001.json.tmp" \
  && mv "${ORCH_DIR}/handoffs/task-001.json.tmp" "${ORCH_DIR}/handoffs/task-001.json"
jq -n '{generated_at:"x",rankings:{researcher:{analysis:[{agent:"opencode",model_id:"openrouter/m1",provider:"openrouter",score:0.9,attempts:0,successes:0,last_used:null}]}}}' > "${ORCH_DIR}/rankings.json"

clear_modes; mode_for opencode success; mode_for kilo success; mode_for hermes success
bash "${REPO_DIR}/compress.sh" task-001 >/dev/null 2>&1
assert_eq "compress.sh exits 0" "$?" "0"
assert_eq "handoff marked compressed" "$(jq -r '.compressed' "${ORCH_DIR}/handoffs/task-001.json")" "true"
summary=$(jq -r '.summary' "${ORCH_DIR}/handoffs/task-001.json")
assert_not_contains "compressed summary is free of ANSI codes" "$summary" $'\x1b'
assert_true "compressed summary non-empty" '[[ -n "$summary" ]]'

end_suite
final_report
