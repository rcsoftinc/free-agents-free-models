#!/usr/bin/env bash
# Proves workers run with no_new_privs, so `sudo` refuses them even where a rule
# needs no password. The kernel flag is inherited and cannot be cleared, so it
# reaches every command a worker starts.
#
# A coordinator can be given a short list of root commands, and workers run as
# the same user with every approval turned off. Without the flag, any worker
# could run that list. The checks get the flag too, because they run code a
# worker just edited: a package.json script is as good as a shell.
#
# It is not a security boundary: same user, so see docs/SETUP.md for what still
# gets around it. These stubs also run their commands themselves, so they cannot
# show a real agent that hands them to a service: real hermes does, and passes
# here while its commands run in its gateway, without the flag.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "workers cannot gain privileges"

if ! command -v setpriv >/dev/null 2>&1 || [[ ! -r /proc/self/status ]]; then
  pass "skipped: this system has no setpriv or no /proc (macOS)"
  end_suite
  final_report
  exit
fi

fixture_registry 1 || exit 1        # one lane: b0:fp0, reached through opencode
sandbox_on

T="$(mktemp -d)"; WD="$(mktemp -d)"
trap 'rm -rf "$T" "$WD" "$FIXTURE_DIR"' EXIT
mkdir -p "$T/bin"

# What the kernel says about the process reading it. sed is the reader, so this
# is true of a child of whoever calls it.
FLAG="sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status"
outer="$(eval "$FLAG")"

# --- 1. every adapter, and what its agent starts --------------------------------
while IFS= read -r agent; do
  bin="$(bash -c ". '$REPO/bin/lib/common.sh'; adapter_field '$agent' VERSION_BIN")"
  rm -f "$T/bin/"*
  cat > "$T/bin/$bin" <<EOF
#!/usr/bin/env bash
bash -c "bash -c \"$(printf '%s' "$FLAG" | sed 's/"/\\"/g')\"" > "$T/flag.$agent"
echo STUB_FINISHED
EOF
  chmod +x "$T/bin/$bin"
  out="$(PATH="$T/bin:$PATH" INVOKE_TIMEOUT=5 \
    bash -c ". '$REPO/bin/lib/common.sh'; adapter_invoke '$agent' some-model '' 'reply'" 2>&1)"
  assert_contains "$agent: the agent ran" "$out" "STUB_FINISHED"
  assert_eq "$agent: what it starts cannot gain privileges" "$(cat "$T/flag.$agent" 2>/dev/null)" "1"
done < <(bash -c ". '$REPO/bin/lib/common.sh'; printf '%s\n' \"\${FA_AGENTS[@]}\"")
rm -f "$T/bin/"*

# --- 2. the checks, which run what a worker just edited -------------------------
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
echo done > "${dir:-.}/out.txt"
printf '{"ok":true,"agent":"opencode","summary":"wrote it"}'
EOF
chmod +x "$T/opencode"

PATH="$T:$PATH" "$REPO/bin/run.sh" -w "$WD" -b b0:fp0 \
  --verify "$FLAG > '$T/flag.verify'" "write out.txt" >/dev/null 2>"$T/err"
assert_eq "a task's verify command runs to the end" "$?" "0"
assert_eq "  ...and cannot gain privileges" "$(cat "$T/flag.verify" 2>/dev/null)" "1"

P="$(mktemp -d)"; mkdir -p "$P/.orch"
printf '%s > "%s"\n' "$FLAG" "$T/flag.project" > "$P/check.sh"
printf 'mode: strict\nverify: bash check.sh\n' > "$P/.orch/config.yaml"
jq -n '{tasks:[{id:"a", prompt:"write it", deps:[], files:["out.txt"], category:"general"}]}' \
  > "$P/.orch/tasks.json"
( cd "$P" && PATH="$T:$PATH" TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run ) </dev/null >/dev/null 2>&1
assert_eq "the project check runs to the end" "$?" "0"
assert_eq "  ...and cannot gain privileges" "$(cat "$T/flag.project" 2>/dev/null)" "1"
rm -rf "$P"

# --- 3. fa itself keeps what it had --------------------------------------------
if [[ "$outer" == 0 ]]; then
  after="$(bash -c ". '$REPO/bin/lib/common.sh'; timeout_no_tty 5 true; $FLAG")"
  assert_eq "the caller is unchanged: fa's own steps are not workers" "$after" "0"
else
  pass "skipped: this suite is already running with the flag set"
fi

# --- 4. where the flag cannot be set, work still runs ---------------------------
ntt() { bash -c ". '$REPO/bin/lib/common.sh'; ${1}"; }
assert_eq "no setpriv (macOS): the command still runs" \
  "$(ntt 'real_have() { command -v "$1" >/dev/null 2>&1; }
          have() { [[ "$1" != setpriv ]] && real_have "$1"; }
          timeout_no_tty 5 echo hello')" "hello"
cat > "$T/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T/bin/setpriv"
assert_eq "a setpriv that fails (a locked-down container): the command still runs" \
  "$(PATH="$T/bin:$PATH" bash -c ". '$REPO/bin/lib/common.sh'; timeout_no_tty 5 echo hello")" "hello"
rm -f "$T/bin/setpriv"

# --- 5. the point of all this, where the machine allows the test ----------------
# GitHub's runners have a rule with no password, so CI tests this for real. Most
# machines have none, and there a refusal would prove nothing.
if [[ "$outer" == 0 ]] && sudo -n true </dev/null >/dev/null 2>&1; then
  ntt 'timeout_no_tty 5 sudo -n true' </dev/null >/dev/null 2>&1
  assert_ne "sudo works here with no password, and is refused inside a worker" "$?" "0"
else
  pass "skipped: no passwordless sudo here to take away"
fi

# --- 6. the coordinator, which is who root work falls to -----------------------
assert_contains "the coordinator is told how to find what it may run" \
  "$(cat "$REPO/prompts/coordinator.md")" "sudo -n -l"

end_suite
final_report
