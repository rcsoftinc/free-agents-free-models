#!/usr/bin/env bash
# Metered wallets (copilot, cursor) spend a depleting monthly allowance, not an
# unlimited free pool - so every use of one should earn its keep. The default
# mode (FA_METERED=auto) is: a metered wallet is a lane ONLY when a token was
# actually detected (credential_fp != "anon") and its recorded credits are not
# spent. It stays sorted LAST and can be forced on/off explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "metered wallets: auto-include when detected, never drawn first"
fixture_registry 4 || exit 1
sandbox_on
REG="$FREE_AGENTS_STATE/buckets.json"

# b1: metered, a token was detected (fp1), credits remain  -> auto-included
# b2: metered, no token (anon credential)                  -> auto-excluded
# b3: metered, token detected but allowance spent (0 left) -> auto-excluded
jq '.buckets["b1:fp1"].metered = true
  | .buckets["b1:fp1"].meter = {credits_remaining:10, credits_entitlement:200}
  | .buckets["b2:fp2"].metered = true
  | .buckets["b2:fp2"].meter = {credits_remaining:10, credits_entitlement:200}
  | .buckets["b2:fp2"].credential_fp = "anon"
  | .buckets["b3:fp3"].metered = true
  | .buckets["b3:fp3"].meter = {credits_remaining:0, credits_entitlement:200}' \
  "$REG" > "$REG.t" && mv "$REG.t" "$REG"

# --- default (auto): detected-with-credits is in, the others are not ---------
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_contains    "metered wallet with a token and credits is auto-included" "$out" "b1:fp1"
assert_not_contains "anon-credential metered wallet is hidden by default"   "$out" "b2:fp2"
assert_not_contains "depleted metered wallet is hidden by default"           "$out" "b3:fp3"

# auto-included metered still sorts LAST behind the genuinely free wallet
first_metered=$(printf '%s\n' "$out" | grep -n 'b1:fp1' | head -1 | cut -d: -f1)
last_free=$(printf '%s\n' "$out" | grep -n 'b0:fp0' | tail -1 | cut -d: -f1)
assert_true "unmetered candidates are tried before any metered one" \
            '[[ $first_metered -gt $last_free ]]'

assert_eq "lanes counts auto-included metered wallet" "$("$REPO/bin/buckets.sh" lanes)" "2"

# --- FA_METERED=0: every metered wallet off -----------------------------------
out="$(DRY_RUN_LIMIT=0 FA_METERED=0 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_not_contains "FA_METERED=0 hides metered wallets" "$out" "b1:fp1"
assert_eq "lanes drops metered wallets at 0" "$(FA_METERED=0 "$REPO/bin/buckets.sh" lanes)" "1"

# --- FA_METERED=1: every metered wallet on, still after free ------------------
out="$(DRY_RUN_LIMIT=0 FA_METERED=1 timeout 60 "$REPO/bin/run.sh" --dry-run 2>/dev/null)"
assert_contains "FA_METERED=1 reveals anon metered wallet" "$out" "b2:fp2"
assert_contains "FA_METERED=1 reveals depleted metered wallet" "$out" "b3:fp3"
first_metered=$(printf '%s\n' "$out" | grep -n 'b2:fp2' | head -1 | cut -d: -f1)
last_free=$(printf '%s\n' "$out" | grep -n 'b0:fp0' | tail -1 | cut -d: -f1)
assert_true "forced metered wallets still sort after every free one" \
            '[[ $first_metered -gt $last_free ]]'
assert_eq "lanes counts every metered wallet at 1" "$(FA_METERED=1 "$REPO/bin/buckets.sh" lanes)" "4"

# --- legacy FA_ALLOW_METERED / --allow-metered still force on -----------------
assert_eq "legacy FA_ALLOW_METERED=1 forces metered on" \
          "$(FA_ALLOW_METERED=1 "$REPO/bin/buckets.sh" lanes)" "4"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run --allow-metered 2>/dev/null)"
assert_contains "--allow-metered still forces metered on" "$out" "b3:fp3"
out="$(DRY_RUN_LIMIT=0 timeout 60 "$REPO/bin/run.sh" --dry-run --no-metered 2>/dev/null)"
assert_not_contains "--no-metered forces metered off" "$out" "b1:fp1"
assert_eq "--no-metered agrees with lanes" "$(FA_METERED=0 "$REPO/bin/buckets.sh" lanes)" "1"

# --- a metered wallet is never CHOSEN while a free one is usable ---------------
mode_for opencode success
res="$(FA_METERED=1 timeout 60 "$REPO/bin/run.sh" "task" 2>&1 >/dev/null | sed -n 's/^---RUN-META--- //p' | tail -1)"
assert_eq "free wallet is preferred over the metered one" \
          "$(printf '%s' "$res" | jq -r '.bucket')" "b0:fp0"

# --- the -v listing must agree with the count -------------------------------
# This drifted twice: the count excluded a wallet while the listing still showed
# it as a usable LANE. They share a predicate now; assert they stay in step.
n_default="$("$REPO/bin/buckets.sh" lanes)"
v_default="$("$REPO/bin/buckets.sh" lanes -v | grep -c '^  LANE')"
assert_eq "lanes -v LANE rows match the count (default)" "$v_default" "$n_default"

n_allowed="$(FA_METERED=1 "$REPO/bin/buckets.sh" lanes)"
v_allowed="$(FA_METERED=1 "$REPO/bin/buckets.sh" lanes -v | grep -c '^  LANE')"
assert_eq "lanes -v LANE rows match the count (forced)" "$v_allowed" "$n_allowed"
assert_true "forcing metered strictly increases the lane count" '[[ $n_allowed -gt $n_default ]]'

end_suite
final_report