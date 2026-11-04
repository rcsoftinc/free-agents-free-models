#!/usr/bin/env bash
# Proves a wallet where no model answered its liveness probe is not a lane.
#
# A timeout or a dead model blames only that model, so such a wallet used to stay
# at health "unknown" and count as healthy. opencode:zen did exactly that after
# its free tier ended: every model timed out, and `fa lanes` still said 9 where 7
# worked. Only a wallet with nothing but timeouts and dead models is benched; any
# other result says the provider answered or that the fault was ours.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "buckets.sh: unresponsive wallets"
fixture_registry 3 || exit 1
sandbox_on
REG="$FREE_AGENTS_STATE/buckets.json"
BK="$REPO/bin/buckets.sh"
export ATTEMPT_TIMEOUT=1

state() { jq -r --arg b "$1" '.buckets[$b].health.state' "$REG"; }
set_unknown() {
  jq '.buckets[].health = {state:"unknown", consecutive_failures:0, cooldown_until:null}
      | .buckets[].models[].probe = {state:"unprobed", at:null, ms:null}' \
    "$REG" > "$REG.t" && mv "$REG.t" "$REG"
}

# b0 runs on opencode, b1 on kilo, b2 on hermes (fixture_registry).
# --- 1. all timeouts: benched. The others keep what they earned ---------------
set_unknown
opencode_STUB_MODE=hang hermes_STUB_MODE=ratelimit timeout 60 "$BK" probe >/dev/null 2>&1
assert_eq "every model timing out makes the wallet unresponsive" "$(state b0:fp0)" "unresponsive"
assert_eq "a wallet that answered is ok" "$(state b1:fp1)" "ok"
assert_eq "a wallet fault keeps its own state" "$(state b2:fp2)" "rate_limited"

# --- 2. it stops counting and stops being scheduled ---------------------------
assert_eq "it is not counted as a lane" "$("$BK" lanes)" "2"
out="$("$BK" lanes -v 2>&1)"
assert_contains "lanes -v says what happened" "$out" "no model answered"
assert_contains "and how to recheck it" "$out" "fa probe --bucket b0:fp0"
# The coordinator reads doctor at the start of a session, which is how the user
# hears about it. No expiry means nothing else would ever say so.
out="$(timeout 90 "$REPO/bin/fa" doctor 2>&1)"
assert_contains "doctor names the wallet that is out" "$out" "b0:fp0 is out"
assert_contains "and gives the recheck command" "$out" "Recheck: fa probe --bucket b0:fp0"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "the exclusion trace names the reason" "$out" "bucket did not answer its probe"
assert_not_contains "and no route is offered through it" \
  "$(timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null | grep -v excluded)" "m0-a"

# --- 3. one good answer brings it straight back -------------------------------
timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "a later answer restores the wallet" "$(state b0:fp0)" "ok"
assert_eq "and it counts again" "$("$BK" lanes)" "3"
assert_not_contains "and doctor stops mentioning it" "$(timeout 90 "$REPO/bin/fa" doctor 2>&1)" "is out"

# --- 4. dead models bench it too ----------------------------------------------
set_unknown
opencode_STUB_MODE=error timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "every model dead makes the wallet unresponsive" "$(state b0:fp0)" "unresponsive"

# --- 5. a failure that is not evidence about the wallet never benches it ------
# Real provider text, from classify.sh's own self-test, through a one-line agent.
fake_agent_says() {
  mkdir -p "$FAKE"
  printf '#!/usr/bin/env bash\necho "%s"\nexit 1\n' "$1" > "$FAKE/opencode"
  chmod +x "$FAKE/opencode"
}
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
fake_agent_says "curl: (6) Could not resolve host: openrouter.ai"
set_unknown
PATH="$FAKE:$PATH" timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "our own network failing blames nobody" "$(state b0:fp0)" "unknown"

fake_agent_says "Service temporarily down, try again later"
set_unknown
PATH="$FAKE:$PATH" timeout 60 "$BK" probe --bucket b0:fp0 >/dev/null 2>&1
assert_eq "a provider outage is not treated as a dead wallet" "$(state b0:fp0)" "unknown"
assert_eq "so that wallet still counts" "$("$BK" lanes)" "3"

end_suite
final_report
