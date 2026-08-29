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

"$REPO/bin/run.sh" -b b0:fp0 "do a thing" >/dev/null 2>run3_err.txt || true

after_fail=$(jq '.buckets["b0:fp0"].models[0].stats.fail' "$REG")
after_state=$(jq -r '.buckets["b0:fp0"].health.state' "$REG")

# Fixture models start with no .stats key at all; a bucket fault must not
# invent a failure against the model, so .stats.fail stays 0 (the default).
assert_eq "Test 3a: model .stats.fail not incremented" "$after_fail" "0"
assert_eq "Test 3b: bucket health became rate_limited" "$after_state" "rate_limited"

rm -f run3_err.txt

# ---------------------------------------------------------------- cleanup
clear_modes

end_suite
final_report