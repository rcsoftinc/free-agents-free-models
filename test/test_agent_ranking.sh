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

# Agent evidence fades like model evidence: those ten successes dated ten
# half-lives ago are worth a hundredth of one, so two of opencode's from
# today outrank them. Undated, ten beat two (the control).
jq --argjson old "$(( $(date +%s) - 300*86400 ))" '.agent_stats = {
      kilo:     {stats:{ok:10,fail:0,at:$old}, cat_stats:{coding:{ok:10,fail:0,at:$old}}},
      opencode: {stats:{ok:2,fail:0},          cat_stats:{coding:{ok:2,fail:0}}}}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
p_kilo=$(printf '%s\n' "$out" | grep -nE 'kilo.*m0-a'     | head -1 | cut -d: -f1)
p_oc=$(printf '%s\n' "$out"   | grep -nE 'opencode.*m0-a' | head -1 | cut -d: -f1)
assert_true "ten successes dated ten half-lives ago rank below two from today" \
  '[[ -n "$p_kilo" && -n "$p_oc" && $p_oc -lt $p_kilo ]]'
jq 'del(.agent_stats[].stats.at, .agent_stats[].cat_stats[].at)' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
p_kilo=$(printf '%s\n' "$out" | grep -nE 'kilo.*m0-a'     | head -1 | cut -d: -f1)
p_oc=$(printf '%s\n' "$out"   | grep -nE 'opencode.*m0-a' | head -1 | cut -d: -f1)
assert_true "  ...undated (taken at face value), ten beat two" \
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
# And what that attempt cost its lane, in ms, beside the counts: on the agent,
# per category, and on the model that served it.
kilo_ms="$(jq '.agent_stats.kilo.stats.ms // 0' "$REG")"
kilo_cat_ms="$(jq '.agent_stats.kilo.cat_stats.coding.ms // 0' "$REG")"
m_ms="$(jq '[.buckets["b1:fp1"].models[].stats.ms // 0] | max' "$REG")"
m_cat_ms="$(jq '[.buckets["b1:fp1"].models[].cat_stats.coding.ms // 0] | max' "$REG")"
assert_true "agent_stats.kilo.stats.ms carries the attempt's lane time (got ${kilo_ms})" '[[ $kilo_ms -gt 0 ]]'
assert_true "  ...per category too (got ${kilo_cat_ms})" '[[ $kilo_cat_ms -gt 0 ]]'
assert_true "  ...and on the model's own record (got ${m_ms})" '[[ $m_ms -gt 0 ]]'
assert_true "  ...per category (got ${m_cat_ms})" '[[ $m_cat_ms -gt 0 ]]'
rm -f run_agentstats_err.txt

# A wallet fault, for real: both harnesses answer rate-limited, so whichever
# route b0 tries first trips the bucket. (Before, only opencode was put in that
# mode; kilo's route to the same model, ranked first by now, simply served the
# run, so no fault happened and the check below passed empty.)
# (Counts, not raw objects: on a fault record() writes a model's empty
# {ok:0,fail:0} defaults, which is not evidence either.)
tallies() { jq -c '{a:.agent_stats, m:[.buckets["b0:fp0"].models[]
                     | {ok:(.stats.ok // 0), fail:(.stats.fail // 0), ms:(.stats.ms // 0),
                        cats:((.cat_stats // {}) | map_values({ok:(.ok // 0), fail:(.fail // 0), ms:(.ms // 0)}))}]}' "$REG"; }
before="$(tallies)"
mode_for opencode ratelimit; mode_for kilo ratelimit
"$REPO/bin/run.sh" -b b0:fp0 "do a thing" >/dev/null 2>run_agentstats_err2.txt || true
assert_contains "the wallet answered rate-limited" "$(cat run_agentstats_err2.txt)" '-> rate'
assert_contains "  ...and was written off for the run" "$(cat run_agentstats_err2.txt)" 'is at fault (rate'
after="$(tallies)"
assert_eq "a bucket-level fault counts against no AGENT and no model: not as a failure, not as lane time" "$after" "$before"
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
assert_contains "RUN-META carries the time the attempt held its lane" "$meta" '"lane_ms":'
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
# Lane time per pass sits beside each rate: opencode's 15 attempts held a lane
# for 50.4 minutes in all and 12 passed (4.2 min/ok); its 9 coding attempts
# 24.8 minutes for 8 passes (3.1); docs never passed (n/a); kilo's record is
# from before timing was kept (n/a). Per model the same, for models that have
# been dispatched at all: m0-a's 5 attempts held b0 for 10 minutes and 4
# passed (2.5); m0-b never ran and is not listed.
jq '.agent_stats = {opencode: {stats:{ok:12,fail:3,ms:3024000},
                               cat_stats:{coding:{ok:8,fail:1,ms:1488000}, docs:{ok:0,fail:2,ms:120000}}},
                    kilo: {stats:{ok:3,fail:0}, cat_stats:{}}}
    | del(.buckets[].models[].stats, .buckets[].models[].cat_stats)
    | .buckets["b0:fp0"].models[0].stats = {ok:4,fail:1,ms:600000}
    | .buckets["b0:fp0"].models[0].cat_stats = {coding:{ok:4,fail:1,ms:600000}}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$("$REPO/bin/buckets.sh" profile 2>&1)"
assert_contains "shows the agent name" "$out" "opencode"
assert_contains "shows overall ok/fail counts" "$out" "12 ok / 3 fail"
assert_contains "shows the per-category breakdown" "$out" "coding:"
assert_contains "shows a computed percentage" "$out" "80%"
assert_contains "shows lane minutes per pass overall" "$out" "overall: 12 ok / 3 fail  (80%)  4.2 min/ok"
assert_contains "  ...and per category" "$out" "coding:  8 ok / 1 fail  (89%)  3.1 min/ok"
assert_contains "  ...n/a where nothing passed" "$out" "docs:  0 ok / 2 fail  (0%)  n/a min/ok"
assert_contains "  ...and n/a for a record from before timing was kept" "$out" "overall: 3 ok / 0 fail  (100%)  n/a min/ok"
assert_contains "the same per model, under its wallet" "$out" "b0:fp0  m0-a"
assert_contains "  ...with its lane minutes per pass" "$out" "overall: 4 ok / 1 fail  (80%)  2.5 min/ok"
assert_not_contains "  ...a model never dispatched is not listed" "$out" "m0-b"
# Shown as the ranking sees it: a record dated one half-life ago at half
# its counts - same rate, same minutes per pass, since both fade alike.
jq --argjson at "$(( $(date +%s) - 30*86400 ))" '.agent_stats.opencode.stats.at = $at' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$("$REPO/bin/buckets.sh" profile 2>&1)"
assert_contains "a record dated one half-life ago shows at half its counts, same rate and min/ok" \
  "$out" "overall: 6 ok / 1.5 fail  (80%)  4.2 min/ok"
assert_contains "  ...and the profile says that counts fade" "$out" "counts fade: halved every 30 days"
out="$(FA_HALF_LIFE_DAYS=0 "$REPO/bin/buckets.sh" profile 2>&1)"
assert_contains "with FA_HALF_LIFE_DAYS=0 the same record shows its lifetime counts" \
  "$out" "overall: 12 ok / 3 fail  (80%)  4.2 min/ok"
assert_contains "  ...and says so" "$out" "counts do not fade"
assert_contains "names harnesses with no data yet, rather than omitting them silently" \
  "$out" "no data yet for:"
assert_contains "an agent never dispatched is listed as having no data" "$out" "hermes"

end_suite
final_report
