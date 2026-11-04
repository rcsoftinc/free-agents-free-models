#!/usr/bin/env bash
# Proves agents run with no controlling terminal, so one cannot freeze a run.
#
# `timeout` puts the agent in a background process group. If the agent then
# touches the terminal, the kernel stops the group - and uutils timeout (Ubuntu
# 26.04) does not ignore those signals, so its own limit freezes with it. A real
# `agy` probe sat stopped for 25 minutes that way under setup.sh, while the same
# probe answered in 5s with no terminal. GNU timeout survives the stop but still
# burns the whole limit, so these assertions catch the bug on either one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "agents have no controlling terminal"
sandbox_on

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# --- 1. every adapter survives an agent that touches the terminal -------------
# Run inside a real pty (script), because CI and most test runs have no terminal
# at all, and without one this bug cannot occur and the test would prove nothing.
if ! script -qec true /dev/null >/dev/null 2>&1 </dev/null; then
  pass "skipped: no util-linux script to provide a pty"
else
  while IFS= read -r agent; do
    bin="$(bash -c ". '$REPO/bin/lib/common.sh'; adapter_field '$agent' VERSION_BIN")"
    cat > "$T/bin/$bin" <<'EOF'
#!/usr/bin/env bash
stty sane </dev/tty 2>/dev/null
echo STUB_FINISHED
EOF
    chmod +x "$T/bin/$bin"
    cat > "$T/driver.sh" <<EOF
#!/usr/bin/env bash
export PATH="$T/bin:\$PATH" INVOKE_TIMEOUT=3
. "$REPO/bin/lib/common.sh"
ps -o tty= -p \$\$ > "$T/tty.$agent"
out="\$(adapter_invoke "$agent" some-model "" "reply")"; rc=\$?
printf 'rc=%s %s\n' "\$rc" "\$out" > "$T/result.$agent"
EOF
    # The hard limit is what ends a frozen run: this suite must fail, not hang.
    timeout -s KILL 6 script -qec "bash '$T/driver.sh'" /dev/null >/dev/null 2>&1 </dev/null
    assert_ne "$agent: the driver really had a terminal" \
      "$(tr -d ' ' < "$T/tty.$agent" 2>/dev/null)" "?"
    res="$(cat "$T/result.$agent" 2>/dev/null || echo 'frozen: killed by the hard limit')"
    assert_contains "$agent: finished with its output" "$res" "STUB_FINISHED"
    assert_contains "$agent: and was not timed out" "$res" "rc=0"
  done < <(bash -c ". '$REPO/bin/lib/common.sh'; printf '%s\n' \"\${FA_AGENTS[@]}\"")
fi

# --- 2. the helper keeps timeout's contract -----------------------------------
ntt() { bash -c ". '$REPO/bin/lib/common.sh'; ${1}"; }

ntt 'timeout_no_tty 5 bash -c "exit 7"'
assert_eq "the command's exit code comes back" "$?" "7"
ntt 'timeout_no_tty 1 sleep 30'
assert_eq "the limit still fires, with timeout's 124" "$?" "124"
assert_eq "a session leader still gets the output (setsid forks there)" \
  "$(setsid -w bash -c ". '$REPO/bin/lib/common.sh'; timeout_no_tty 5 echo hello")" "hello"
assert_eq "without setsid it falls back to plain timeout" \
  "$(ntt 'have() { return 1; }; timeout_no_tty 5 echo hello')" "hello"

# --- 3. nothing that launches an agent or a check goes around the helper ------
bare="$(grep -nE '(^|[^_[:alnum:]])timeout "?(\$|[0-9])' \
          "$REPO"/bin/lib/adapters/*.sh "$REPO/bin/run.sh" "$REPO/bin/orch.sh" \
          "$REPO/bin/buckets.sh" | grep -vE ':[0-9]+:[[:space:]]*#')"
assert_eq "no agent or check runs under a bare timeout" "$bare" ""

end_suite
final_report
