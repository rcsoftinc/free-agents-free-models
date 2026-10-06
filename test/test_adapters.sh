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
cnt="$(grep -rh -- 'opencode kilo hermes copilot cursor agy pi' "$BIN" | wc -l)"
assert_eq "the canonical list appears exactly once under bin/" "$cnt" "1"
assert_eq "and that one copy is adapters.sh" \
  "$(grep -rl -- 'opencode kilo hermes copilot cursor agy pi' "$BIN")" "$BIN/lib/adapters.sh"
assert_eq "no call site hardcodes a for-agent loop" \
  "$(grep -rn -- 'for a in opencode\|for a in kilo\|for a in hermes' "$BIN" | wc -l)" "0"

# --- 2. the loader sees every adapter, and each is functional -----------------
# A harness added to the list (a <name>.sh in lib/adapters/) must be picked up
# with no edit anywhere else.
COMMON="$REPO/bin/lib/common.sh"
n="$(bash -c '. '"$COMMON"'; printf "%s" "${#FA_AGENTS[@]}"')"
assert_eq "the adapter list has seven harnesses" "$n" "7"
for a in opencode kilo hermes copilot cursor agy pi; do
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
# The pins are read from the adapters, so re-verifying a CLI and bumping its pin
# is one edit there (plus its stub's --version), not a hunt through the tests.
pin() { bash -c '. '"$COMMON"'; adapter_field '"$1"' VERIFIED_VERSION'; }
assert_contains "copilot is present" "$out" "copilot"
assert_contains "doctor verifies against the pinned copilot version" "$out" "ok      copilot   $(pin copilot)"
assert_contains "cursor-agent is present" "$out" "cursor"
assert_contains "doctor verifies against the pinned cursor build" "$out" "ok      cursor    $(pin cursor)"
assert_contains "agy is present" "$out" "agy"
assert_contains "doctor verifies against the pinned agy version" "$out" "ok      agy       $(pin agy)"
assert_contains "the metered lanes are marked as such" "$out" "metered"

# --- 5. the presence broom: unfamiliar harnesses are surfaced, not ignored -----
# Against a fake one: this passed only where the real claude CLI happened to be
# installed, and a clean machine (CI) has none.
UNAD="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$UNAD/claude"; chmod +x "$UNAD/claude"
broom="$(PATH="$UNAD:$PATH" FREE_AGENTS_STATE="$FIXTURE_DIR" timeout 90 "$FA" doctor 2>&1)"
rm -rf "$UNAD"
assert_contains "doctor names a harness that has no adapter" "$broom" "claude"
assert_contains "and states the consequence" "$broom" "no adapter"

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
# </dev/null: setup offers to install the missing dependency and reads the
# answer from stdin. From a terminal - or any stdin that never reaches EOF - the
# suite otherwise sat waiting on a prompt whose text it had captured into a file.
PATH="$FAKEBIN" bash "$REPO/setup.sh" --no-bootstrap "$SP" </dev/null >"$SP/out" 2>&1; rc=$?
assert_eq "setup exits 3 when a dependency is missing" "$rc" "3"
assert_contains "setup names the missing dependency" "$(cat "$SP/out")" "jq"
assert_contains "setup says how to install it" "$(cat "$SP/out")" "apt-get"

# --- 7. no test can reach a real agent CLI or a real credential ---------------
# sandbox_on puts test/stubs/ FIRST on PATH but keeps the real PATH behind it,
# so an adapter whose binary has no stub silently drives the developer's real
# CLI. pi shipped without one: every suite that bootstrapped probed real models
# with the real key, and nothing failed - the requests just quietly went out.
for a in $(bash -c '. '"$COMMON"'; printf "%s\n" "${FA_AGENTS[@]}"'); do
  b="$(bash -c '. '"$COMMON"'; adapter_field '"$a"' VERSION_BIN')"
  assert_eq "$a resolves to its offline stub, never the real $b" \
    "$(command -v "$b")" "$STUBS_DIR/$b"
done

# Every adapter falls back to a credential file under $HOME. Which variables
# those are is asked of the adapters themselves - loaded in a clean environment
# with a fake HOME - rather than trusting the pattern the harness uses to find
# them, so a fallback the harness misses is still caught here.
home_vars="$(env -i HOME=/nonexistent/fakehome PATH="$PATH" bash -c '. '"$COMMON"'
  for v in $(compgen -v); do
    [[ "$v" == "_" ]] && continue   # bash'"'"'s last-argument variable, not a setting
    [[ "${!v:-}" == /nonexistent/fakehome/* ]] && printf "%s\n" "$v"
  done; true')"
assert_true "the adapters do derive credential paths from HOME (sanity)" \
  '[[ "$(wc -w <<<"$home_vars")" -ge 5 ]]'
leaks=""
for v in $home_vars; do
  val="$(bash -c '. '"$COMMON"'; printf "%s" "${'"$v"':-}"')"
  [[ "$val" == "$HOME"/* ]] && leaks+="$v "
done
assert_eq "no adapter reads a real credential file during a test" "$leaks" ""

end_suite
final_report