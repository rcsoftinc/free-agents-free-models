#!/usr/bin/env bash
# test_agent_ranking.sh - the agent/harness ranking axis: candidates() used to
# hard-filter every model to its bucket's preferred_agent (whichever adapter
# happened to enumerate first at discover time), so a wallet reachable
# through two harnesses could only ever be dispatched through one of them,
# forever. This is the concrete gap behind "pick the ranked best model/agent/
# harness, fall back to the next-best on failure" being only half-built:
# model ranking existed and was tested, agent/harness ranking did not exist
# at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "agent/harness ranking axis"
fixture_registry 3 || exit 1
sandbox_on

REG="$FREE_AGENTS_STATE/buckets.json"

# Give b0:fp0's first model a SECOND route, via kilo - the same upstream
# model, reachable through two different harnesses on one wallet. This is
# exactly the shape the feature exists for (routes[] already carried this
# data; only the select(.agent == preferred_agent) filter discarded it).
jq '.buckets["b0:fp0"].models[0].routes += [{agent:"kilo", model_arg:"m0-a", provider:"p0"}]' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"

# ---------------------------------------------------------------- Test 1
echo "=== Test 1: both harnesses are offered, not just preferred_agent ==="
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_true "opencode's route to m0-a is offered" \
  '[[ -n "$(printf "%s" "$out" | grep -E "opencode.*m0-a")" ]]'
assert_true "kilo's route to the SAME model is now also offered" \
  '[[ -n "$(printf "%s" "$out" | grep -E "kilo.*m0-a")" ]]'

# ---------------------------------------------------------------- Test 2
echo "=== Test 2: a strong agent-axis record reorders which harness is tried first ==="
jq '.agent_stats = {kilo: {stats:{ok:10,fail:0}, cat_stats:{coding:{ok:10,fail:0}}}}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
p_kilo=$(printf '%s\n' "$out" | grep -nE 'kilo.*m0-a'     | head -1 | cut -d: -f1)
p_oc=$(printf '%s\n' "$out"   | grep -nE 'opencode.*m0-a' | head -1 | cut -d: -f1)
assert_true "kilo's route is present at all (not just absent from the chain)" '[[ -n "$p_kilo" ]]'
assert_true "kilo's strong record ranks it above opencode for the SAME model" \
  '[[ -n "$p_kilo" && -n "$p_oc" && $p_kilo -lt $p_oc ]]'

# Reset for the next tests - clean slate, no agent evidence at all.
jq '.agent_stats = {}' "$REG" > "$REG.t" && mv "$REG.t" "$REG"

# ---------------------------------------------------------------- Test 3
echo "=== Test 3: a successful run records agent_stats, fault-gated the same as model stats ==="
"$REPO/bin/run.sh" -c coding -b b1:fp1 "do a thing" >/dev/null 2>run_agentstats_err.txt || true
kilo_ok="$(jq '.agent_stats.kilo.stats.ok // 0' "$REG")"
kilo_cat_ok="$(jq '.agent_stats.kilo.cat_stats.coding.ok // 0' "$REG")"
assert_true "agent_stats.kilo.stats.ok incremented (got ${kilo_ok})" '[[ $kilo_ok -ge 1 ]]'
assert_true "agent_stats.kilo.cat_stats.coding.ok incremented (got ${kilo_cat_ok})" '[[ $kilo_cat_ok -ge 1 ]]'
rm -f run_agentstats_err.txt

mode_for opencode ratelimit
"$REPO/bin/run.sh" -b b0:fp0 "do a thing" >/dev/null 2>run_agentstats_err2.txt || true
oc_fail="$(jq '.agent_stats.opencode.stats.fail // 0' "$REG")"
assert_eq "a bucket-level fault does not count against the AGENT either (mirrors .stats)" "$oc_fail" "0"
rm -f run_agentstats_err2.txt
clear_modes

# ---------------------------------------------------------------- Test 4
# THE feature: automatic fallback to the next-best HARNESS on the SAME
# wallet and SAME model, not just to a different model or a different
# wallet. Force opencode's row to be tried FIRST (a strong prior favoring
# it), fail it with a MODEL-scope fault (not a bucket fault - the bucket
# must stay eligible), and confirm kilo's route to the identical model
# picks up the run.
echo "=== Test 4: automatic fallback to the next-best HARNESS on the same wallet+model ==="
jq '.agent_stats = {opencode: {stats:{ok:10,fail:0}, cat_stats:{}}}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
mode_for opencode error   # generic failure -> classifies "dead" (model-scope, not bucket)

out="$(timeout 60 "$REPO/bin/run.sh" -b b0:fp0 "do a thing" 2>run4_err.txt)"
rc=$?
meta="$(grep -- '---RUN-META---' run4_err.txt || true)"

assert_eq "the run still succeeds despite opencode's route failing" "$rc" "0"
assert_contains "RUN-META shows kilo actually served it" "$meta" '"agent":"kilo"'
assert_contains "RUN-META shows the SAME model, not a different one" "$meta" '"model":"m0-a"'
oc_fail4="$(jq '.agent_stats.opencode.stats.fail // 0' "$REG")"
assert_true "the failing agent's OWN record reflects the failure (got ${oc_fail4})" '[[ $oc_fail4 -ge 1 ]]'
kilo_ok4="$(jq '.agent_stats.kilo.stats.ok // 0' "$REG")"
assert_true "the succeeding agent's OWN record reflects the success (got ${kilo_ok4})" '[[ $kilo_ok4 -ge 1 ]]'

rm -f run4_err.txt
clear_modes

# ---------------------------------------------------------------- Test 5
# `fa profile`: a read-only view of agent_stats, so an operator (or the
# coordinating LLM) can see WHY a harness was picked without reading and
# mentally executing the ranking formula in run.sh.
echo "=== Test 5: fa profile surfaces the learned per-agent record ==="
jq '.agent_stats = {opencode: {stats:{ok:12,fail:3}, cat_stats:{coding:{ok:8,fail:1}}}}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$("$REPO/bin/buckets.sh" profile 2>&1)"
assert_contains "shows the agent name" "$out" "opencode"
assert_contains "shows overall ok/fail counts" "$out" "12 ok / 3 fail"
assert_contains "shows the per-category breakdown" "$out" "coding:"
assert_contains "shows a computed percentage" "$out" "80%"
assert_contains "names harnesses with no data yet, rather than omitting them silently" \
  "$out" "no data yet for:"
assert_contains "an agent never dispatched is listed as having no data" "$out" "hermes"

end_suite
final_report
