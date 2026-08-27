#!/usr/bin/env bash
# Phase A4: promote.sh result classification (success / failure / rate_limited).
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "A4 promote"

sandbox_on
reset_state baseline

write_fixture() {
  # Single known model at score 0.80
  jq -n '{
    generated_at:"x",
    rankings:{
      researcher:{ research:[{agent:"opencode", model_id:"opencode/x", provider:"opencode", score:0.80, attempts:1, successes:0, last_used:null}] }
    }
  }' > "${ORCH_DIR}/rankings.json"
}
read_score() { jq -r '.rankings.researcher.research[0].score' "${ORCH_DIR}/rankings.json"; }
read_att()  { jq -r '.rankings.researcher.research[0].attempts' "${ORCH_DIR}/rankings.json"; }
read_succ() { jq -r '.rankings.researcher.research[0].successes' "${ORCH_DIR}/rankings.json"; }

# success: 0.80 -> 0.80 + (1-0.80)*0.2 = 0.84
write_fixture
bash "${REPO_DIR}/promote.sh" researcher research opencode/x opencode success >/dev/null 2>&1
assert_eq "success raises score to 0.84" "$(read_score)" "0.84"
assert_eq "success increments attempts" "$(read_att)" "2"
assert_eq "success increments successes" "$(read_succ)" "1"

# failure: 0.80 -> 0.80*0.8 = 0.64
write_fixture
bash "${REPO_DIR}/promote.sh" researcher research opencode/x opencode failure >/dev/null 2>&1
assert_eq "failure lowers score to 0.64" "$(read_score)" "0.64"
assert_eq "failure does not increment successes" "$(read_succ)" "0"

# rate_limited: 0.80 -> 0.80*0.9 = 0.72 (milder than failure 0.64)
write_fixture
bash "${REPO_DIR}/promote.sh" researcher research opencode/x opencode rate_limited >/dev/null 2>&1
assert_eq "rate_limited lowers score to 0.72" "$(read_score)" "0.72"
assert_true "rate_limited penalty (0.72) milder than failure (0.64)" '[[ $(read_score) > 0.64 ]]'

# unknown model gets added
write_fixture
bash "${REPO_DIR}/promote.sh" researcher research kilo/new kilo success >/dev/null 2>&1
assert_eq "unknown model added" "$(jq -r '[.rankings.researcher.research[] | select(.model_id=="kilo/new")] | length' "${ORCH_DIR}/rankings.json")" "1"

end_suite
final_report
