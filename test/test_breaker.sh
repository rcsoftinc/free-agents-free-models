#!/usr/bin/env bash
# Proves the bucket circuit breaker: a WALLET-attributable failure cools the whole
# wallet, a MODEL-level failure does not, and a first failure is short-lived.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "bucket circuit breaker"
fixture_registry 3 || exit 1
sandbox_on

REG="$FREE_AGENTS_STATE/buckets.json"
bstate() { jq -r --arg b "$1" '.buckets[$b].health.state' "$REG"; }
bfails() { jq -r --arg b "$1" '.buckets[$b].health.consecutive_failures // 0' "$REG"; }
bcool()  { jq -r --arg b "$1" '.buckets[$b].health.cooldown_until // 0' "$REG"; }
mfail()  { jq -r --arg b "$1" --arg m "$2" \
             '[.buckets[$b].models[] | select(.upstream==$m) | .stats.fail // 0][0] // 0' "$REG"; }

# --- 1. a wallet-attributable failure condemns the WALLET -------------------
mode_for opencode ratelimit
timeout 60 "$REPO/bin/run.sh" -b b0:fp0 --max-attempts 1 "task" >/dev/null 2>&1
assert_eq "rate limit sets bucket state" "$(bstate b0:fp0)" "rate_limited"
assert_true "rate limit increments the wallet's failure count" '[[ $(bfails b0:fp0) -ge 1 ]]'
assert_eq "wallet fault is NOT scored against the model" "$(mfail b0:fp0 m0-a)" "0"

# --- 2. the breaker trips on the second consecutive wallet fault ------------
assert_eq "one failure has not cooled the wallet yet" "$(bcool b0:fp0)" "0"
BREAKER_TRIP=2 timeout 60 "$REPO/bin/run.sh" -b b0:fp0 --max-attempts 1 "task" >/dev/null 2>&1
assert_true "second consecutive fault trips the breaker" '[[ $(bcool b0:fp0) -gt 0 ]]'

# A first cooldown must be SHORT. A single transient 401 once benched a healthy
# wallet for 24h; escalation exists so a blip costs minutes, not a day.
now=$(date +%s); until_ts=$(bcool b0:fp0); span=$(( until_ts - now ))
assert_true "early cooldown is short (<=1h), not a full day (got ${span}s)" \
            '[[ $span -le 3600 ]]'

# --- 3. a cooled wallet is skipped by the scheduler -------------------------
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_not_contains "cooled wallet is absent from the candidate chain" "$out" "b0:fp0"
assert_contains "healthy wallets are still offered" "$out" "b1:fp1"

# --- 4. a MODEL timeout must not condemn its wallet ------------------------
clear_modes
jq '.buckets["b1:fp1"].health = {state:"ok",consecutive_failures:0,cooldown_until:0,last_used:0}' \
   "$REG" > "$REG.t" && mv "$REG.t" "$REG"
mode_for kilo hang
ATTEMPT_TIMEOUT=3 timeout 60 "$REPO/bin/run.sh" -b b1:fp1 --max-attempts 1 "task" >/dev/null 2>&1
assert_ne "a hang does not mark the wallet rate_limited" "$(bstate b1:fp1)" "rate_limited"
assert_eq "a hang leaves the wallet uncooled" "$(bcool b1:fp1)" "0"

# --- 5. success clears the wallet's failure count ---------------------------
clear_modes
jq '.buckets["b2:fp2"].health = {state:"rate_limited",consecutive_failures:1,cooldown_until:0,last_used:0}' \
   "$REG" > "$REG.t" && mv "$REG.t" "$REG"
timeout 60 "$REPO/bin/run.sh" -b b2:fp2 "task" >/dev/null 2>&1
assert_eq "a success resets the wallet to ok" "$(bstate b2:fp2)" "ok"
assert_eq "a success clears the failure count" "$(bfails b2:fp2)" "0"

end_suite
final_report
