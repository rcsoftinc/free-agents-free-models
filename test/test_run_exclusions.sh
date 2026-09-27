#!/usr/bin/env bash
# Proves explain_exclusions() (run.sh): when a bucket/model/route does not make
# the candidate chain, the reason is visible - in --dry-run always, and in the
# empty-chain guard when nothing at all qualifies. Every reason here reuses a
# field discover()/record() already computes; this only adds visibility.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "run.sh: exclusion trace"
fixture_registry 3 || exit 1
sandbox_on
REG="$FREE_AGENTS_STATE/buckets.json"

# --- 1. a cooling-down bucket is explained, not just silently absent --------
future=$(( $(date +%s) + 999999 ))
jq --argjson t "$future" \
   '.buckets["b0:fp0"].health = {state:"rate_limited", consecutive_failures:2, cooldown_until:$t, last_used:0}' \
   "$REG" > "$REG.t" && mv "$REG.t" "$REG"

out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "dry-run prints an excluded: section" "$out" "excluded:"
assert_contains "the cooling-down bucket's reason is named" "$out" "bucket cooling down"

# --- 2. an explicit -x exclusion is explained -------------------------------
jq '.buckets["b0:fp0"].health = {state:"ok", consecutive_failures:0, cooldown_until:0, last_used:0}' \
   "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run -x b1:fp1 2>&1 >/dev/null)"
assert_contains "an explicitly excluded bucket is explained" "$out" "excluded via -x"

# --- 3. an unsuitable model is explained with ITS OWN recorded reason ------
jq '.buckets["b2:fp2"].models[0].suitable = false
  | .buckets["b2:fp2"].models[0].unsuitable_reason = "context_too_small"' \
   "$REG" > "$REG.t" && mv "$REG.t" "$REG"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "the model-level reason is surfaced verbatim" "$out" "model unsuitable: context_too_small"

# --- 4. a bucket cooled to the point of zero candidates: the empty-chain ----
#        guard itself explains why, not just "no candidates"
jq --argjson t "$future" '
  .buckets[].health = {state:"rate_limited", consecutive_failures:2, cooldown_until:$t, last_used:0}
' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
rc=0
out="$(timeout 60 "$REPO/bin/run.sh" "a task" 2>&1 >/dev/null)" || rc=$?
assert_eq "every bucket cooling down exhausts the chain (exit 2)" "$rc" "2"
assert_contains "the guard explains why, not just that there were none" "$out" "why:"
assert_contains "and names the actual reason" "$out" "bucket cooling down"

end_suite
final_report
