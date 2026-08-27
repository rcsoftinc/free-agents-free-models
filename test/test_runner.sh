#!/usr/bin/env bash
# Phase D: ONE live run against the real opencode/kilo/hermes agents.
# Credit limits are expected; we assert the runner now (a) walks MORE than the
# old 3-combo cap (exhaustive), and (b) classifies credit errors as rate_limited.
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "D live run (real agents)"

# Use REAL agents: no stub sandbox.
sandbox_off
reset_state baseline

log "Starting live run of task-002 (this may take a few minutes)..."
timeout 220 bash "${REPO_DIR}/runner.sh" task-002 >/dev/null 2>&1
rc=$?

attempts=$(grep -c "Attempt" "${ORCH_DIR}/runner.log" || true)
status=$(jq -r '.tasks[] | select(.id=="task-002") | .status' "${ORCH_DIR}/project.json" 2>/dev/null || echo "none")
rl_seen=$(grep -c "rate_limited" "${ORCH_DIR}/runner.log" || true)

log "live run rc=$rc attempts=$attempts status=$status rate_limited_observed=$rl_seen"

if [[ "$status" == "done" ]]; then
  pass "D live run succeeded (credits available)"
else
  assert_true "D live run attempted >3 combos (exhaustive, old cap was 3; got $attempts)" '[[ $attempts -gt 3 ]]'
  assert_true "D live run observed rate_limited classification ($rl_seen)" '[[ $rl_seen -gt 0 ]]'
fi

# Restore baseline so the suite leaves the repo unchanged.
reset_state baseline
end_suite
final_report
