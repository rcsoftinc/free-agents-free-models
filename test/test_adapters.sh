#!/usr/bin/env bash
# Proves the harness list is single-sourced in bin/lib/adapters.sh, that the
# adapters actually drive every call site that used to hardcode
# "opencode kilo hermes copilot cursor", and that `fa doctor` now sees the whole
# machine: metered harnesses are version-checked and any harness WITHOUT an
# adapter is surfaced instead of silently ignored.
#
# The driver for this was three real gaps: discovery and doctor each had their
# own copy of the agent list, so copilot and cursor were never version-checked,
# and a machine with claude/aider/goose... installed was reported healthy while
# those harnesses could never be a lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "single-sourced adapter list"
sandbox_on

FA="$REPO/bin/fa"
BIN="$REPO/bin"

# --- 1. the harness list has exactly ONE home ---------------------------------
# The list used to be copied in six places; every copy that was absent meant a
# harness the tool already knew was invisible somewhere. It must now live only
# in bin/lib/adapters.sh and be LOADED from there everywhere else.
cnt="$(grep -rh -- 'opencode kilo hermes copilot cursor' "$BIN" | wc -l)"
assert_eq "the canonical list appears exactly once under bin/" "$cnt" "1"
assert_eq "and that one copy is adapters.sh" \
  "$(grep -rl -- 'opencode kilo hermes copilot cursor' "$BIN")" "$BIN/lib/adapters.sh"
assert_eq "no call site hardcodes a for-agent loop" \
  "$(grep -rn -- 'for a in opencode\|for a in kilo\|for a in hermes' "$BIN" | wc -l)" "0"

# --- 2. the loader sees every adapter, and each is functional -----------------
# A harness added to the list (a <name>.sh in lib/adapters/) must be picked up
# with no edit anywhere else.
COMMON="$REPO/bin/lib/common.sh"
n="$(bash -c '. '"$COMMON"'; printf "%s" "${#FA_AGENTS[@]}"')"
assert_eq "the adapter list has five harnesses" "$n" "5"
for a in opencode kilo hermes copilot cursor; do
  have_fn="$(bash -c '. '"$COMMON"'; type -t '"$a"'_invoke')"
  assert_eq "$a has an invoke contract" "$have_fn" "function"
done

# --- 3. dispatcher must refuse an unknown harness ------------------------------
cmd=". $COMMON; adapter_invoke notaharn m1 p1 \"hello\""
out="$(bash -c "$cmd" 2>&1)"; rc=$?
assert_eq "an unknown harness returns 3" "$rc" "3"

# --- 4. doctor version-checks the metered harnesses too ------------------------
# These two were the blind spot: the old doctor only knew opencode/kilo/hermes.
fixture_registry 1 || exit 1
out="$(FREE_AGENTS_STATE="$FIXTURE_DIR" timeout 90 "$FA" doctor 2>&1)"
assert_contains "copilot is present" "$out" "copilot"
assert_contains "doctor verifies against the pinned copilot version" "$out" "1.0.83"
assert_contains "cursor-agent is present" "$out" "cursor"
assert_contains "doctor verifies against the pinned cursor build" "$out" "2026.09.02"
assert_contains "the metered lanes are marked as such" "$out" "metered"

# --- 5. the presence broom: unfamiliar harnesses are surfaced, not ignored -----
assert_contains "doctor names a harness that has no adapter" "$out" "claude"
assert_contains "and states the consequence" "$out" "no adapter"

# --- 6. missing_deps is real, and setup consults it ----------------------------
FAKEBIN="$(mktemp -d)"; trap 'rm -rf "$FAKEBIN"; rm -rf "$FIXTURE_DIR"' EXIT
# Every REQUIRED dep (so missing_deps has nothing to report) PLUS the coreutils
# setup.sh itself needs to print its message (tr). The absence we are proving is
# jq - which is intentionally left out.
for c in bash dirname curl flock sqlite3 timeout tr; do
  ln -s "$(command -v "$c")" "$FAKEBIN/$c"
done
got="$(PATH="$FAKEBIN" bash -c '. '"$COMMON"'; missing_deps')"
assert_eq "missing_deps() reports exactly jq" "$got" "jq"

SP="$(mktemp -d)"; trap 'rm -rf "$FAKEBIN" "$FIXTURE_DIR" "$SP"' EXIT
PATH="$FAKEBIN" bash "$REPO/setup.sh" --no-bootstrap "$SP" >"$SP/out" 2>&1; rc=$?
assert_eq "setup exits 3 when a dependency is missing" "$rc" "3"
assert_contains "setup names the missing dependency" "$(cat "$SP/out")" "jq"
assert_contains "setup says how to install it" "$(cat "$SP/out")" "apt-get"

end_suite
final_report