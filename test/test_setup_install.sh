#!/usr/bin/env bash
# Proves setup.sh on a machine with nothing on it: it installs every agent CLI
# it does not find with the vendor's own install script (each adapter names
# it; the stub curl plays each script and lands the agent's stub where the real
# script lands the real binary), puts what it installed on PATH for the rest of
# its run, says who still has no account and the step that gives it one, and
# ends Ready only when a lane can take work. Run a second time, once a
# credential is there, it refreshes the registry it left stale and builds the
# lanes from it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "setup.sh: installs what is missing; the second run builds the lanes"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FA_CRONTAB_CMD="${STUBS_DIR}/crontab" FAKE_CRONTAB="$T/crontab"

# The tool cloned into a project as .free-agents/, as the README says.
PROJ="$T/proj"; TOOL="$PROJ/.free-agents"; mkdir -p "$TOOL"
cp -r "$REPO/bin" "$REPO/skills" "$REPO/setup.sh" "$TOOL/"

# A bare machine: the system tools, the stub curl, and no agent CLI anywhere.
# Not sandbox_on: that keeps the real PATH, every agent on it, behind the stubs -
# the opposite of what this suite is about.
BARE="$T/bin"; mkdir -p "$BARE"
ln -s "${STUBS_DIR}/curl" "$BARE/curl"
BARE_PATH="$BARE:/usr/bin:/bin"
field() { bash -c '. '"$REPO"'/bin/lib/common.sh; adapter_field "$1" "$2"' _ "$1" "$2"; }
AGENTS="$(bash -c '. '"$REPO"'/bin/lib/common.sh; printf "%s\n" "${FA_AGENTS[@]}"')"

# --- 1. every adapter names its vendor's installer -----------------------------
# The seven lines were verified on 2026-11-17: each URL served a script, and each
# script's install directory is where that binary is on a real machine.
expect_url() { assert_eq "$1 installs with its vendor's script" "$(field "$1" INSTALL_URL)" "$2"; }
expect_url opencode https://opencode.ai/install
expect_url kilo     https://kilo.ai/cli/install
expect_url hermes   https://hermes-agent.nousresearch.com/install.sh
expect_url copilot  https://gh.io/copilot-install
expect_url cursor   https://cursor.com/install
expect_url agy      https://antigravity.google/cli/install.sh
expect_url pi       https://pi.dev/install.sh
assert_eq "pi's script is written for sh, not bash" "$(field pi INSTALL_SHELL)" "sh"
assert_eq "opencode's script lands in ~/.opencode/bin" "$(field opencode BIN_DIR)" ".opencode/bin"
assert_eq "kilo's script lands in ~/.kilo/bin" "$(field kilo BIN_DIR)" ".kilo/bin"
for a in hermes copilot cursor agy pi; do
  assert_eq "$a's script lands in ~/.local/bin" "$(field "$a" BIN_DIR)" ".local/bin"
done
assert_eq "no adapter guesses a package for a package manager any more" \
  "$(grep -lE 'npm install -g|pip3 install |cargo install |brew install ' "$REPO"/bin/lib/adapters/*.sh "$REPO"/bin/lib/install.sh 2>/dev/null | wc -l)" "0"

# The table the stub curl plays installers from - read from the adapters.
TABLE="$T/installers.tsv"; : > "$TABLE"
while IFS= read -r a; do
  printf '%s\t%s\t%s\n' "$(field "$a" INSTALL_URL)" "$(field "$a" VERSION_BIN)" "$(field "$a" BIN_DIR)" >> "$TABLE"
done <<<"$AGENTS"
install_calls() { grep -c -F -f <(cut -f1 "$TABLE") "$1" 2>/dev/null || echo 0; }

run_setup() { # $1=home $2=state $3=out file; rest: VAR=value for this run -> rc
  local home="$1" state="$2" out="$3"; shift 3
  env -i HOME="$home" PATH="$BARE_PATH" FREE_AGENTS_STATE="$state" \
      STUB_INSTALL_TABLE="$TABLE" FA_CRONTAB_CMD="$FA_CRONTAB_CMD" FAKE_CRONTAB="$FAKE_CRONTAB" \
      FA_COORDINATOR=none BACKOFF_BASE=0 BACKOFF_CAP=0 PROBE_TIMEOUT=10 ATTEMPT_TIMEOUT=10 \
      "$@" bash "$TOOL/setup.sh" "$PROJ" </dev/null >"$out" 2>&1
}
lanes_in() { # $1=home $2=state -> lane count, with the installed CLIs on PATH
  FREE_AGENTS_STATE="$2" PATH="$BARE_PATH:$1/.opencode/bin:$1/.kilo/bin:$1/.local/bin" \
    "$TOOL/bin/buckets.sh" lanes 2>/dev/null || echo 0
}

# --- 2. the first run on a bare machine: everything installed, no lane yet -----
HOME_A="$T/home-a"; STATE_A="$T/state-a"; mkdir -p "$HOME_A"
# The two anonymous gateways refuse - the findings showed kilo's doing exactly
# that without a sign-in - so nothing answers and no lane can take work.
run_setup "$HOME_A" "$STATE_A" "$T/out-a1" FA_AUTO_INSTALL=1 CURL_STUB_LOG="$T/curl-a1.log" \
  opencode_STUB_MODE=error kilo_STUB_MODE=error; rc=$?
out="$(cat "$T/out-a1")"
assert_eq "the first run ends 1: nothing can take work yet" "$rc" "1"
while IFS= read -r a; do
  b="$(field "$a" VERSION_BIN)"; d="$(field "$a" BIN_DIR)"; u="$(field "$a" INSTALL_URL)"
  assert_contains "$a is reported missing" "$out" "$a: not installed"
  assert_contains "and installed with the vendor's own line" "$out" "$a: installing - curl -fsSL $u | "
  assert_true "$b landed where the vendor's script puts it" '[[ -x "$HOME_A/$d/$b" ]]'
  assert_contains "the stub curl was asked for exactly that script, with -fsSL" "$(cat "$T/curl-a1.log")" "curl -fsSL $u"
  assert_contains "and setup says where it went" "$out" "$a: installed in $HOME_A/$d"
done <<<"$AGENTS"
assert_eq "seven installers ran, once each" "$(install_calls "$T/curl-a1.log")" "7"
assert_eq "pi's script ran under sh" "$(cat "$HOME_A/.stub-installer-shell.pi")" ""
assert_eq "opencode's under bash" "$(cat "$HOME_A/.stub-installer-shell.opencode")" "bash"
assert_contains "the verdict is not ready" "$out" "Not ready yet: no lane can take work"
assert_not_contains "and never Ready" "$out" "Ready."
assert_contains "a registry was built from the anonymous wallets, none a lane" "$out" "none a lane right now"
assert_true "the registry is there" '[[ -s "$STATE_A/buckets.json" ]]'
assert_eq "with no lane" "$(lanes_in "$HOME_A" "$STATE_A")" "0"
assert_contains "opencode is an anonymous gateway only" "$out" "opencode *anonymous gateway only"
assert_contains "kilo too" "$out" "kilo *anonymous gateway only"
assert_contains "opencode's step names its login" "$out" "opencode auth login"
assert_contains "hermes has no credential, with its step" "$out" "hermes *no credential - hermes auth upgrade"
assert_contains "copilot: gh auth login" "$out" "copilot *no credential - gh auth login"
assert_contains "cursor" "$out" "cursor *no credential - cursor-agent login"
assert_contains "agy" "$out" "agy *no credential - agy login"
assert_contains "pi: a key in keys.env" "$out" "pi *no credential - PI_OPENROUTER_KEY in keys.env"
assert_contains "it says to give at least one an account" "$out" "Give at least one of these an account"
assert_contains "and to run setup again" "$out" "Then run this again"
assert_contains "the PATH line for this shell names the three install directories, once each" "$out" \
  "export PATH=\"$HOME_A/.opencode/bin:$HOME_A/.kilo/bin:$HOME_A/.local/bin:\$PATH\""
assert_contains "the daily refresh was scheduled" "$(cat "$FAKE_CRONTAB")" "fa' refresh --scheduled"
assert_contains "with a PATH that finds what was installed" "$(cat "$STATE_A/schedule.path")" "$HOME_A/.opencode/bin"

# --- 3. the second run: a credential is there, the stale registry is refreshed -
# `opencode auth login` writes auth.json; here it is written by hand.
mkdir -p "$HOME_A/.local/share/opencode"
echo '{"openrouter":{"type":"api","key":"sk-or-v1-SECONDRUN000000000000000"}}' \
  > "$HOME_A/.local/share/opencode/auth.json"
run_setup "$HOME_A" "$STATE_A" "$T/out-a2" FA_AUTO_INSTALL=1 CURL_STUB_LOG="$T/curl-a2.log"; rc=$?
out="$(cat "$T/out-a2")"
assert_eq "the second run ends 0" "$rc" "0"
assert_not_contains "nothing is installed again" "$out" "installing - curl"
assert_not_contains "nothing is reported missing: the installed CLIs were found off PATH" "$out" "not installed"
assert_eq "no installer ran" "$(install_calls "$T/curl-a2.log")" "0"
assert_contains "the registry had gone stale" "$out" "registry is STALE - your credentials changed"
assert_contains "and setup refreshed it itself" "$out" "refreshing now"
assert_contains "the verdict is Ready" "$out" "Ready."
assert_contains "with the agents to start" "$out" \
  "Start any agent from here:  opencode | kilo | hermes | copilot | cursor-agent | agy | pi"
assert_true "a lane exists" '[[ "$(lanes_in "$HOME_A" "$STATE_A")" -ge 1 ]]'
assert_contains "the account's wallet is in the registry" "$(jq -r '.buckets | keys[]' "$STATE_A/buckets.json")" "openrouter"
assert_not_contains "the key is not" "$(cat "$STATE_A/buckets.json")" "SECONDRUN"
assert_contains "the agents still without an account are listed as more lanes" "$out" "More lanes, once these have an account"
assert_contains "hermes among them" "$out" "hermes *no credential"
assert_not_contains "opencode, with an account now, is not" "$(grep 'anonymous gateway only' "$T/out-a2")" "opencode"
assert_not_contains "no PATH line: nothing was installed this run" "$out" "In this one, first:"

# --- 4. a first run can already be Ready: the anonymous gateways answer --------
HOME_B="$T/home-b"; STATE_B="$T/state-b"; mkdir -p "$HOME_B"
run_setup "$HOME_B" "$STATE_B" "$T/out-b" FA_AUTO_INSTALL=1; rc=$?
out="$(cat "$T/out-b")"
assert_eq "with lanes, the first run ends 0" "$rc" "0"
assert_contains "Ready" "$out" "Ready."
assert_true "on the anonymous lanes" '[[ "$(lanes_in "$HOME_B" "$STATE_B")" -ge 1 ]]'
assert_contains "but it still names who has no account, as more lanes" "$out" "More lanes, once these have an account"
assert_contains "and how to pick them up" "$out" "fa refresh"
assert_contains "the PATH line is there, for the shell setup ran from" "$out" "In this one, first:"

# --- 5. with no answer to its questions, nothing is installed -----------------
HOME_C="$T/home-c"; STATE_C="$T/state-c"; mkdir -p "$HOME_C"
run_setup "$HOME_C" "$STATE_C" "$T/out-c" CURL_STUB_LOG="$T/curl-c.log"; rc=$?
out="$(cat "$T/out-c")"
assert_eq "ends 1" "$rc" "1"
assert_contains "each agent was offered its installer, by its line" "$out" \
  "installs with: curl -fsSL https://opencode.ai/install | bash"
assert_contains "pi's, under sh" "$out" "installs with: curl -fsSL https://pi.dev/install.sh | sh"
assert_contains "and skipped" "$out" "skipped opencode"
assert_eq "no installer ran" "$(install_calls "$T/curl-c.log")" "0"
assert_true "nothing landed" '[[ ! -e "$HOME_C/.local/bin" && ! -e "$HOME_C/.opencode" && ! -e "$HOME_C/.kilo" ]]'
assert_contains "the verdict names them all as not installed" "$out" \
  "not installed:  opencode kilo hermes copilot cursor agy pi"
assert_true "no registry" '[[ ! -e "$STATE_C/buckets.json" ]]'
assert_contains "and says so" "$out" "no registry yet"

# --- 6. an installer that fails, or installs nothing, is said so ---------------
HOME_D="$T/home-d"; STATE_D="$T/state-d"; mkdir -p "$HOME_D"
run_setup "$HOME_D" "$STATE_D" "$T/out-d" FA_AUTO_INSTALL=1 \
  STUB_INSTALL_FAIL=hermes STUB_INSTALL_NOOP=agy opencode_STUB_MODE=error kilo_STUB_MODE=error; rc=$?
out="$(cat "$T/out-d")"
assert_contains "a failing installer is reported" "$out" "hermes: the installer failed"
assert_contains "one that left nothing is reported" "$out" "agy: the installer finished but left no 'agy'"
assert_true "the other five are there" \
  '[[ -x "$HOME_D/.opencode/bin/opencode" && -x "$HOME_D/.kilo/bin/kilo" && -x "$HOME_D/.local/bin/pi" ]]'
assert_true "and the two are not" '[[ ! -e "$HOME_D/.local/bin/hermes" && ! -e "$HOME_D/.local/bin/agy" ]]'
assert_contains "the verdict lists the two as not installed" "$out" "not installed:  hermes agy"
assert_eq "ends 1" "$rc" "1"

# --- 7. git is a system dependency: orch builds in worktrees and commits --------
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
for c in bash dirname tr jq curl flock sqlite3 timeout; do ln -s "$(command -v "$c")" "$FAKEBIN/$c"; done
assert_eq "missing_deps reports git when it is absent" \
  "$(PATH="$FAKEBIN" bash -c '. '"$REPO"'/bin/lib/common.sh; missing_deps')" "git"

# --- 8. the docs give the same seven lines -------------------------------------
# grep the files, not a captured copy: `echo "$big" | grep -q` ends in a broken
# pipe under pipefail when the match is early and the rest exceeds the pipe.
while IFS= read -r a; do
  u="$(field "$a" INSTALL_URL)"
  assert_true "docs/SETUP.md names $a's installer" 'grep -qF -- "$u" "$REPO/docs/SETUP.md"'
done <<<"$AGENTS"
assert_true "README says a new machine takes two runs" 'grep -q "second run" "$REPO/README.md"'
assert_true "README.es.md says so too" 'grep -q "dos ejecuciones" "$REPO/README.es.md"'

end_suite
final_report
