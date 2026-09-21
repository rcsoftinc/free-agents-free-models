#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"          # ALWAYS call the engine via "$REPO/bin/..."
source "$HERE/harness.sh"
begin_suite "per-category ranking"
fixture_registry 3 || exit 1
sandbox_on

REG="$FREE_AGENTS_STATE/buckets.json"

# ---------------------------------------------------------------- Test 1
# Give b0:fp0's models opposite histories in buckets.json
#   m0-a -> .cat_stats = {"coding":{"ok":0,"fail":5},"reasoning":{"ok":5,"fail":0}}
#   m0-b -> .cat_stats = {"coding":{"ok":5,"fail":0},"reasoning":{"ok":0,"fail":5}}
echo "=== Test 1: per-category ranking changes candidate order ==="

jq '.buckets["b0:fp0"].models[0].cat_stats = {"coding":{"ok":0,"fail":5},"reasoning":{"ok":5,"fail":0}}
  | .buckets["b0:fp0"].models[1].cat_stats = {"coding":{"ok":5,"fail":0},"reasoning":{"ok":0,"fail":5}}' \
  "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"

# coding: m0-b (score 10) must come before m0-a (score -20)
out_coding="$(DRY_RUN_LIMIT=0 "$REPO/bin/run.sh" --dry-run -c coding 2>&1)"
pos_b_coding=$(printf '%s\n' "$out_coding" | grep -n 'm0-b' | head -1 | cut -d: -f1)
pos_a_coding=$(printf '%s\n' "$out_coding" | grep -n 'm0-a' | head -1 | cut -d: -f1)
assert_true "coding: m0-b before m0-a" '[[ $pos_b_coding -lt $pos_a_coding ]]'

# reasoning: m0-a (score 10) must come before m0-b (score -20)
out_reasoning="$(DRY_RUN_LIMIT=0 "$REPO/bin/run.sh" --dry-run -c reasoning 2>&1)"
pos_a_reasoning=$(printf '%s\n' "$out_reasoning" | grep -n 'm0-a' | head -1 | cut -d: -f1)
pos_b_reasoning=$(printf '%s\n' "$out_reasoning" | grep -n 'm0-b' | head -1 | cut -d: -f1)
assert_true "reasoning: m0-a before m0-b" '[[ $pos_a_reasoning -lt $pos_b_reasoning ]]'

# ---------------------------------------------------------------- Test 2
# After a successful -c coding run pinned to b1:fp1, assert the used model's
# .cat_stats.coding.ok is >= 1 in the registry.
echo "=== Test 2: success increments category ok count ==="

"$REPO/bin/run.sh" -c coding -b b1:fp1 "do a thing" >/dev/null 2>run2_err.txt || true
run2_meta="$(grep -- '---RUN-META---' run2_err.txt)"
assert_contains "Test 2: RUN-META present" "$run2_meta" '---RUN-META---'

coding_ok=$(jq '.buckets["b1:fp1"].models[0].cat_stats.coding.ok' "$REG")
assert_true "Test 2: coding.ok >= 1 after success" '[[ $coding_ok -ge 1 ]]'

rm -f run2_err.txt

# ---------------------------------------------------------------- Test 3
# With opencode in ratelimit mode, run pinned to b0:fp0, then assert the MODEL's
# .stats.fail did NOT increase while .buckets["b0:fp0"].health.state became "rate_limited".
echo "=== Test 3: wallet fault not scored against model ==="

mode_for opencode ratelimit

before_state=$(jq -r '.buckets["b0:fp0"].health.state' "$REG")
# Seed a known probe result so a bucket fault clobbering it is detectable -
# the fixture's default is "unprobed", which a bug that resets .probe to
# "rate_limited" would be indistinguishable from without this.
jq '.buckets["b0:fp0"].models[0].probe = {state:"ok", at:"2026-01-01T00:00:00Z", ms:1}' \
  "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"

"$REPO/bin/run.sh" -b b0:fp0 "do a thing" >/dev/null 2>run3_err.txt || true

after_fail=$(jq '.buckets["b0:fp0"].models[0].stats.fail' "$REG")
after_state=$(jq -r '.buckets["b0:fp0"].health.state' "$REG")
after_probe=$(jq -r '.buckets["b0:fp0"].models[0].probe.state' "$REG")
after_catfail=$(jq '.buckets["b0:fp0"].models[0].cat_stats.general.fail // 0' "$REG")

# Fixture models start with no .stats key at all; a bucket fault must not
# invent a failure against the model, so .stats.fail stays 0 (the default).
assert_eq "Test 3a: model .stats.fail not incremented" "$after_fail" "0"
assert_eq "Test 3b: bucket health became rate_limited" "$after_state" "rate_limited"
assert_eq "Test 3c: model .cat_stats.*.fail not incremented" "$after_catfail" "0"
# A bucket-level fault is a fact about the WALLET, not this model - it must
# not overwrite the model's own last probe result either.
assert_eq "Test 3d: bucket fault does not clobber the model's .probe" "$after_probe" "ok"

rm -f run3_err.txt
clear_modes

# ---------------------------------------------------------------- Test 4
# context_overflow is "neither" attribution per classify.sh (same as
# local_network): the CALLER's prompt was too big, which says nothing about
# whether the model or wallet is any good. Nothing should be recorded at all.
echo "=== Test 4: context_overflow is recorded nowhere ==="

mode_for opencode contextoverflow

before_probe=$(jq -r '.buckets["b0:fp0"].models[0].probe.state' "$REG")
before_fail=$(jq '.buckets["b0:fp0"].models[0].stats.fail // 0' "$REG")
before_state4=$(jq -r '.buckets["b0:fp0"].health.state' "$REG")

"$REPO/bin/run.sh" -b b0:fp0 "do a thing" >/dev/null 2>run4_err.txt || true

after_probe4=$(jq -r '.buckets["b0:fp0"].models[0].probe.state' "$REG")
after_fail4=$(jq '.buckets["b0:fp0"].models[0].stats.fail // 0' "$REG")
after_state4=$(jq -r '.buckets["b0:fp0"].health.state' "$REG")

assert_eq "Test 4a: model .probe untouched by context_overflow" "$after_probe4" "$before_probe"
assert_eq "Test 4b: model .stats.fail not incremented" "$after_fail4" "$before_fail"
assert_eq "Test 4c: bucket health untouched by context_overflow" "$after_state4" "$before_state4"

rm -f run4_err.txt

# ---------------------------------------------------------------- cleanup
clear_modes

# --- cold start: the prior orders models nothing is yet known about ---------
# Measured on the live registry, 0 of 418 models had any observed stats, so
# without a prior the ordering of a fresh registry is arbitrary. The prior must
# break that tie - and must lose the moment real evidence exists.
REG="$FREE_AGENTS_STATE/buckets.json"
# nano-model is listed FIRST deliberately: with no prior the two tie and the
# input order stands, so the assertion below can only pass if the prior actually
# reorders them. A test that passes on input order proves nothing.
jq '.buckets["b2:fp2"].models = [
      {upstream:"nano-model",  free:true, context:200000,  max_output:4096,
       routes:[{agent:"hermes",model_arg:"nano-model",provider:"p2"}],
       probe:{state:"unprobed"}},
      {upstream:"big-model",   free:true, context:1000000, max_output:64000,
       routes:[{agent:"hermes",model_arg:"big-model",provider:"p2"}],
       probe:{state:"unprobed"}}]' "$REG" > "$REG.t" && mv "$REG.t" "$REG"

out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
pos_big=$(printf '%s\n' "$out" | grep -n 'big-model'  | head -1 | cut -d: -f1)
pos_nano=$(printf '%s\n' "$out" | grep -n 'nano-model' | head -1 | cut -d: -f1)
assert_true "with no stats at all, the larger model is preferred" '[[ $pos_big -lt $pos_nano ]]'

# One observed success must outweigh the best possible prior.
jq '.buckets["b2:fp2"].models |= map(
      if .upstream=="nano-model" then . + {cat_stats:{coding:{ok:1,fail:0}}} else . end)'    "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
pos_big=$(printf '%s\n' "$out" | grep -n 'big-model'  | head -1 | cut -d: -f1)
pos_nano=$(printf '%s\n' "$out" | grep -n 'nano-model' | head -1 | cut -d: -f1)
assert_true "a single observed success beats the prior (evidence > opinion)" '[[ $pos_nano -lt $pos_big ]]'

# --- per-category seed_tiers overrides the flat seed_tier, per category ----
# spec-up and spec-down each have a FLAT tier deliberately opposite to what
# their per-category override implies, so a passing assertion can ONLY be
# explained by the override actually being read - if the code silently fell
# back to the flat tier (the old, pre-this-feature behaviour), every
# assertion below would flip to its opposite, not merely weaken. Verified by
# hand-computing both the old and new formula for these exact fixtures
# before writing this test (see the commit message).
#   spec-up:   flat tier=0 (would rank LOW alone), tiers.coding=3
#   spec-down: flat tier=3 (would rank HIGH alone), tiers.research=0
#   flat3-x / flat1-x: no tiers - fixed, unambiguous reference points
jq '.buckets["b2:fp2"].models = [
      {upstream:"spec-up", free:true, context:200000, max_output:4096,
       seed_tier:0, seed_tiers:{coding:3},
       routes:[{agent:"hermes",model_arg:"spec-up",provider:"p2"}], probe:{state:"unprobed"}},
      {upstream:"spec-down", free:true, context:200000, max_output:4096,
       seed_tier:3, seed_tiers:{research:0},
       routes:[{agent:"hermes",model_arg:"spec-down",provider:"p2"}], probe:{state:"unprobed"}},
      {upstream:"flat3-x", free:true, context:200000, max_output:4096, seed_tier:3,
       routes:[{agent:"hermes",model_arg:"flat3-x",provider:"p2"}], probe:{state:"unprobed"}},
      {upstream:"flat1-x", free:true, context:200000, max_output:4096, seed_tier:1,
       routes:[{agent:"hermes",model_arg:"flat1-x",provider:"p2"}], probe:{state:"unprobed"}}
    ]' "$REG" > "$REG.t" && mv "$REG.t" "$REG"

pos_of() { printf '%s\n' "$1" | grep -n "$2" | head -1 | cut -d: -f1; }

echo "=== per-category seed_tiers: an override can RAISE a model above its own flat tier ==="
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
p_up=$(pos_of "$out" spec-up); p_f1=$(pos_of "$out" flat1-x)
assert_true "tiers.coding=3 beats flat tier=1, despite spec-up's OWN flat tier being 0" \
  '[[ $p_up -lt $p_f1 ]]'

echo "=== per-category seed_tiers: an override can LOWER a model below its own flat tier ==="
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c research 2>/dev/null)"
p_down=$(pos_of "$out" spec-down); p_f1=$(pos_of "$out" flat1-x)
assert_true "tiers.research=0 loses to flat tier=1, despite spec-down's OWN flat tier being 3 (an explicit 'avoid' is not silently treated as neutral)" \
  '[[ $p_f1 -lt $p_down ]]'

echo "=== per-category seed_tiers: a category not named falls back to each model's OWN flat tier ==="
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c general 2>/dev/null)"
p_up=$(pos_of "$out" spec-up); p_down=$(pos_of "$out" spec-down)
assert_true "general is covered by neither model's tiers, so each falls back to its own flat tier (spec-down=3 beats spec-up=0)" \
  '[[ $p_down -lt $p_up ]]'

# --- the zero-evidence gate is per-CATEGORY, not per-model ------------------
# A model with real evidence in ANOTHER category must still get seed/size
# guidance for a category it has never been tried in - losing that the
# moment ANY evidence exists anywhere used to strand every other category
# back at "nothing known", with no signal at all, even a crude one (and, as
# here, silently drop an explicit "avoid" opinion for the untested category
# too).
#
# Isolated via a TWIN: spec-down and twin-down share the exact same flat
# tier (3) and the exact same one unrelated coding success; the ONLY
# difference is spec-down has tiers.research=0 and twin-down has no
# research override at all (so it falls back to its own flat tier=3 for
# research). If the override still applies despite the unrelated evidence,
# twin-down must clearly outscore spec-down for research. Under the OLD,
# model-wide gate this used to TIE (any evidence anywhere zeroed the prior
# for both, override or not) - with spec-down listed BEFORE twin-down here,
# a tie's stable sort would rank spec-down first, the OPPOSITE of what is
# asserted, so this cannot pass by coincidental ordering either.
jq '.buckets["b2:fp2"].models += [
      {upstream:"twin-down", free:true, context:200000, max_output:4096, seed_tier:3,
       stats:{ok:1,fail:0}, cat_stats:{coding:{ok:1,fail:0}},
       routes:[{agent:"hermes",model_arg:"twin-down",provider:"p2"}], probe:{state:"unprobed"}}
    ] | .buckets["b2:fp2"].models |= map(
      if .upstream=="spec-down"
      then . + {stats:{ok:1,fail:0}, cat_stats:{coding:{ok:1,fail:0}}}
      else . end)' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c research 2>/dev/null)"
p_down=$(pos_of "$out" spec-down); p_twin=$(pos_of "$out" twin-down)
assert_true "tiers.research=0 still applies despite unrelated coding evidence (untested category is not stranded by other-category evidence)" \
  '[[ $p_twin -lt $p_down ]]'

# --- unsuitable models never reach the chain --------------------------------
jq '.buckets["b1:fp1"].models |= map(. + {suitable:false, unsuitable_reason:"context_too_small"})'    "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_not_contains "an unsuitable model is not offered as a candidate" "$out" "b1:fp1"
assert_contains "suitable lanes are unaffected" "$out" "b0:fp0"

# --- `fa rank`: the ranked chain, exposed read-only, no dispatch -----------
# Compared against an EXPLICIT DRY_RUN_LIMIT=0 call (the full, untruncated
# chain) rather than a bare `--dry-run` (which defaults to a 20-row
# preview): matching that byte-for-byte is exactly what proves fa rank's
# own default shows everything, regardless of how many candidates this
# fixture happens to have at this point.
echo "=== fa rank exposes the same, FULL chain candidates() would dispatch from ==="
direct="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -c coding 2>/dev/null)"
via_fa="$(timeout 60 "$REPO/bin/fa" rank coding 2>/dev/null)"
assert_eq "fa rank coding matches the FULL run.sh --dry-run -c coding chain exactly" "$via_fa" "$direct"

end_suite
final_report