#!/usr/bin/env bash
# Proves a probe keeps what the provider said, and that a setting at the provider
# refusing a wallet's free models is named as such, not "unresponsive".
#
# opencode's free gateway answered every probe for ten days with "Free models
# may train on request data. Turn on 'Allow free endpoints that train on request
# data' at <url> to use them." The registry said dead, three times, then
# unresponsive, and the only way to learn why was to run the CLI by hand. The
# line a person acts on is now kept beside the state, printed by probe, repeated
# by lanes -v and doctor; and the state says what kind of fault it is: the
# wallet's, held until a probe answers, with no cooldown - a setting nobody has
# turned on does not wear off.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "buckets.sh: what a probe keeps, and opt_in_required"
fixture_registry 3 || exit 1
sandbox_on
REG="$FREE_AGENTS_STATE/buckets.json"
BK="$REPO/bin/buckets.sh"
export ATTEMPT_TIMEOUT=2

state()   { jq -r --arg b "$1" '.buckets[$b].health.state' "$REG"; }
reason()  { jq -r --arg b "$1" '.buckets[$b].health.reason // ""' "$REG"; }
cool()    { jq -r --arg b "$1" '.buckets[$b].health.cooldown_until // 0' "$REG"; }
mprobe()  { jq -r --arg b "$1" --arg m "$2" '[.buckets[$b].models[] | select(.upstream==$m) | .probe.state][0]' "$REG"; }
mreason() { jq -r --arg b "$1" --arg m "$2" '[.buckets[$b].models[] | select(.upstream==$m) | .probe.reason // ""][0]' "$REG"; }
reset_wallets() {
  jq '.buckets[].health = {state:"unknown", consecutive_failures:0, cooldown_until:null}
      | .buckets[].models[].probe = {state:"unprobed", at:null, ms:null}' \
    "$REG" > "$REG.t" && mv "$REG.t" "$REG"
}
# What the stub prints in optin mode: opencode's real refusal, colour codes and
# a banner line included (see test/stubs/opencode).
OPTIN='Free models may train on request data. Turn on "Allow free endpoints that train on request data"'

# b0 runs on opencode (fixture_registry), two models: m0-a, m0-b.
# --- 1. the probe prints what the model said, and keeps it -------------------
reset_wallets
stub_log_new
out="$(opencode_STUB_MODE=optin timeout 60 "$BK" probe --bucket b0:fp0 2>&1)"
assert_contains "the probe names the state" "$out" "opt_in_required"
assert_contains "and prints the provider's own line under the model" "$out" "says: Error: ${OPTIN}"
assert_not_contains "without its colour codes" "$out" $'\033'
assert_eq "the wallet is out for that reason" "$(state b0:fp0)" "opt_in_required"
assert_contains "the line is kept with the wallet" "$(reason b0:fp0)" "$OPTIN"
assert_contains "and with the model that said it" "$(mreason b0:fp0 m0-a)" "$OPTIN"
assert_not_contains "stored without colour codes" "$(reason b0:fp0)" $'\033'
assert_eq "a refusal that spends nothing is walked past: both models were asked" "$(stub_log_lines)" "2"

# --- 2. a free model the setting does not cover proves the wallet ------------
reset_wallets
GOOD_MODEL=m0-b opencode_STUB_MODE=optin timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "one answer puts the wallet back" "$(state b0:fp0)" "ok"
assert_eq "and drops the line" "$(reason b0:fp0)" ""
assert_eq "the model that answered is remembered as such" "$(mprobe b0:fp0 m0-b)" "ok"
assert_eq "the one that was refused keeps its own result" "$(mprobe b0:fp0 m0-a)" "opt_in_required"

# --- 3. not a lane, and lanes -v, doctor and the exclusion trace say why -----
reset_wallets
opencode_STUB_MODE=optin timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "it is not counted as a lane" "$("$BK" lanes)" "2"
out="$("$BK" lanes -v 2>&1)"
assert_contains "lanes -v names the state" "$out" "health=opt_in_required"
assert_contains "says what kind of fault it is" "$out" "a setting at the provider refuses its free models"
assert_contains "repeats the provider's line" "$out" "says: Error: ${OPTIN}"
assert_contains "and how to recheck once it is on" "$out" "fa probe --bucket b0:fp0"
out="$(timeout 90 "$REPO/bin/fa" doctor 2>&1)"
assert_contains "doctor names the wallet that is out, and the kind of fault" "$out" "b0:fp0 is out: a setting at the provider"
assert_contains "quotes the provider" "$out" "It says: Error: ${OPTIN}"
assert_contains "and gives the recheck command" "$out" "fa probe --bucket b0:fp0"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "the exclusion trace names the reason" "$out" "refused by a setting at its provider"
assert_not_contains "and no route is offered through it" \
  "$(timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null | grep -v excluded)" "m0-a"

# --- 4. no cooldown: held until a probe answers, then back at once -----------
assert_eq "nothing to wait out" "$(cool b0:fp0)" "0"
clear_modes
timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "the setting turned on, one answer restores the wallet" "$(state b0:fp0)" "ok"
assert_eq "and it counts again" "$("$BK" lanes)" "3"
assert_not_contains "and doctor stops mentioning it" "$(timeout 90 "$REPO/bin/fa" doctor 2>&1)" "is out"

# --- 5. met mid-run: the wallet's fault, skipped for the run, scored on nobody
reset_wallets
# One refusal already on the wallet's count, so this one trips the breaker -
# which holds by state here, since there is no timer to trip.
jq '.buckets[].health = {state:"ok", consecutive_failures:1, cooldown_until:0, last_used:0}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
stub_log_new
mode_for opencode optin
out="$(timeout 60 "$REPO/bin/run.sh" -b b0:fp0 --max-attempts 3 "task" 2>&1 >/dev/null)"
assert_contains "the run reads it as the wallet's fault" "$out" "b0:fp0 is at fault (opt_in_required)"
assert_eq "and does not walk the wallet's other model" "$(stub_log_lines)" "1"
assert_eq "the wallet is out" "$(state b0:fp0)" "opt_in_required"
assert_eq "the breaker tripped, to no timer: held by state" "$(cool b0:fp0)" "0"
assert_contains "with the provider's line" "$(reason b0:fp0)" "$OPTIN"
assert_eq "not scored against the model" \
  "$(jq -r '[.buckets["b0:fp0"].models[] | select(.upstream=="m0-a") | .stats.fail // 0][0]' "$REG")" "0"
assert_eq "nor against the harness" "$(jq -r '.agent_stats.opencode.stats.fail // 0' "$REG")" "0"
clear_modes

# --- 6. a wallet no model answered keeps the last thing one said -------------
reset_wallets
opencode_STUB_MODE=error timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "every model dead still makes the wallet unresponsive" "$(state b0:fp0)" "unresponsive"
assert_eq "with the last model's words" "$(reason b0:fp0)" "generic failure: something went wrong"
assert_contains "lanes -v repeats them" "$("$BK" lanes -v 2>&1)" "says: generic failure: something went wrong"
assert_contains "doctor too" "$(timeout 90 "$REPO/bin/fa" doctor 2>&1)" \
  "The last one said: generic failure: something went wrong."

# --- 7. a model that said nothing leaves nothing, and clears an old line -----
# Straight from 6: the wallet still holds the words above.
opencode_STUB_MODE=hang ATTEMPT_TIMEOUT=1 timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "all timeouts: unresponsive" "$(state b0:fp0)" "unresponsive"
assert_eq "and no line to show, the old one gone" "$(reason b0:fp0)" ""
assert_not_contains "so lanes -v shows none" "$("$BK" lanes -v 2>&1)" "says:"

# --- 8. a key echoed back is redacted before it is kept ----------------------
FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
printf '#!/usr/bin/env bash\necho "HTTP 401 Unauthorized: invalid api key sk-or-v1-abcd1234efgh5678ijkl"\nexit 1\n' > "$FAKE/opencode"
chmod +x "$FAKE/opencode"
reset_wallets
PATH="$FAKE:$PATH" timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "a credential fault is the wallet's" "$(state b0:fp0)" "auth_error"
assert_contains "its line is kept" "$(reason b0:fp0)" "invalid api key sk-or"
assert_not_contains "but never the key" "$(cat "$REG")" "abcd1234efgh5678ijkl"

end_suite
final_report
