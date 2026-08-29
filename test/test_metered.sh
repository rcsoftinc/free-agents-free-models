#!/usr/bin/env bash
# Proves metered wallets (copilot, cursor) are opt-in and used last. Their free
# tiers are a depleting monthly allowance, so spending one by accident wastes
# scarce capacity even though it cannot produce a bill.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "metered wallets are opt-in and last"
fixture_registry 2 || exit 1
sandbox_on
REG="$FREE_AGENTS_STATE/buckets.json"

# Turn b1 into a metered wallet reachable through a stub agent.
jq '.buckets["b1:fp1"].metered = true
  | .buckets["b1:fp1"].meter = {credits_remaining:10, credits_entitlement:200}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"

# --- default: invisible ------------------------------------------------------
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_not_contains "metered wallet absent by default" "$out" "b1:fp1"
assert_contains    "unmetered wallet still offered"   "$out" "b0:fp0"
assert_eq "lanes ignores metered wallets" "$("$REPO/bin/buckets.sh" lanes)" "1"

# --- opted in: visible, but LAST --------------------------------------------
out="$(DRY_RUN_LIMIT=0 FA_ALLOW_METERED=1 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_contains "metered wallet appears when allowed" "$out" "b1:fp1"
assert_eq "lanes counts it when allowed" "$(FA_ALLOW_METERED=1 "$REPO/bin/buckets.sh" lanes)" "2"

first_metered=$(printf '%s\n' "$out" | grep -n 'b1:fp1' | head -1 | cut -d: -f1)
last_free=$(printf '%s\n' "$out" | grep -n 'b0:fp0' | tail -1 | cut -d: -f1)
assert_true "every unmetered candidate is tried before any metered one" \
            '[[ $first_metered -gt $last_free ]]'

# --- the flag works on run.sh too -------------------------------------------
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run --allow-metered 2>/dev/null)"
assert_contains "--allow-metered enables it" "$out" "b1:fp1"

# --- a metered wallet is never chosen while a free one is usable -------------
mode_for opencode success
res="$(FA_ALLOW_METERED=1 timeout 60 "$REPO/bin/run.sh" "task" 2>&1 >/dev/null | sed -n 's/^---RUN-META--- //p' | tail -1)"
assert_eq "free wallet is preferred over the metered one" \
          "$(printf '%s' "$res" | jq -r '.bucket')" "b0:fp0"

end_suite
final_report
