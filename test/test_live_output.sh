#!/usr/bin/env bash
# Proves a background job's log, which its herdr pane follows, shows what an agent
# prints while the agent is still working.
#
# Adapters capture an agent's output, because fa classifies it, so a pane used to
# show nothing from the agent until the attempt ended. What comes back to fa must
# not change: classification reads it, and a wrong byte there scores a model wrong.
#
# Liveness is proved without timing: the fake agent prints a line, then waits to be
# let go, so only a log that is really live can hold that line in the meantime.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "a background job shows its agent as it works"
fixture_registry 1 || exit 1        # one lane: b0:fp0, reached through opencode
sandbox_on

FA="$REPO/bin/fa"
PROJ="$(mktemp -d)"; T="$(mktemp -d)"
trap 'touch "$T/release"; rm -rf "$PROJ" "$T" "$FIXTURE_DIR"' EXIT
export RELEASE="$T/release"
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
echo "STEP_ONE"
echo "TO_STDERR" >&2
for ((i = 0; i < 400; i++)); do [[ -f "$RELEASE" ]] && break; sleep 0.1; done
printf '\033[0m\n'
printf '\033[31mSTEP_TWO\033[0m\r\n'
printf '{"ok":true,"agent":"opencode","summary":"finished"}'
EOF
chmod +x "$T/opencode"
export PATH="$T:$PATH"

wait_for() { # $1=seconds, rest=command; polls until the command succeeds
  local s="$1" i; shift
  for ((i = 0; i < s * 5; i++)); do "$@" && return 0; sleep 0.2; done
  return 1
}
in_log() { grep -qF -- "$2" "$PROJ/.orch/jobs/$1/log" 2>/dev/null; }
has_rc() { [[ -f "$PROJ/.orch/jobs/$1/rc" ]]; }
log_of() { cat "$PROJ/.orch/jobs/$1/log" 2>/dev/null; }
times_in_log() { grep -cF -- "$2" "$PROJ/.orch/jobs/$1/log" 2>/dev/null; }

# --- 1. fa run --detach ---------------------------------------------------------
( cd "$PROJ" && "$FA" run --detach -b b0:fp0 "a task" </dev/null >/dev/null 2>&1 )
if wait_for 20 in_log j1 "STEP_ONE"; then
  pass "a line the agent printed is in the log while it is still working"
else
  fail "a line the agent printed is in the log while it is still working"
fi
assert_contains "  ...named for the agent that printed it" "$(log_of j1)" "opencode | STEP_ONE"
assert_contains "  ...what it prints to stderr too" "$(log_of j1)" "opencode | TO_STDERR"
assert_not_contains "  ...and what it has not printed yet is not there" "$(log_of j1)" "STEP_TWO"
touch "$RELEASE"
wait_for 30 has_rc j1
assert_eq "the job then finishes as it always did" "$(cat "$PROJ/.orch/jobs/j1/rc" 2>/dev/null)" "0"
assert_contains "the rest arrives, with its colour codes gone" "$(log_of j1)" "opencode | STEP_TWO$"
assert_not_contains "  ...lines that were only colour codes are dropped" "$(log_of j1)" "opencode | $"
assert_eq "the output appears once, not again when the run ends" "$(times_in_log j1 STEP_ONE)" "1"
assert_contains "fa's own lines are all still there" "$(log_of j1)" "---RUN-META---"
log="$(log_of j1)"
assert_true "an agent cannot send escape codes to the pane" '[[ "$log" != *$'"'"'\033'"'"'* ]]'
assert_true "  ...or carriage returns, which could hide a line" '[[ "$log" != *$'"'"'\r'"'"'* ]]'
rm -f "$RELEASE"

# --- 2. a task's check, in the same place ---------------------------------------
touch "$RELEASE"
( cd "$PROJ" && "$FA" run --detach -b b0:fp0 --verify 'echo CHECK_SAYS' "a task" </dev/null >/dev/null 2>&1 )
wait_for 30 has_rc j2
assert_contains "a task's verify command shows too" "$(log_of j2)" "check | CHECK_SAYS"
assert_eq "  ...and its job still passes" "$(cat "$PROJ/.orch/jobs/j2/rc" 2>/dev/null)" "0"
rm -f "$RELEASE"

# --- 3. fa dispatch --detach: tasks share one pane, so each line names its task --
mkdir -p "$PROJ/.orch"
printf 'mode: strict\nverify: echo PROJECT_SAYS\n' > "$PROJ/.orch/config.yaml"
jq -n '{tasks:[{id:"api", prompt:"do it", deps:[], files:[], category:"general",
                verify:"echo TASK_CHECK_SAYS"}]}' > "$PROJ/.orch/tasks.json"
( cd "$PROJ" && TASK_RETRIES=0 "$FA" dispatch --detach </dev/null >/dev/null 2>&1 )
if wait_for 20 in_log j3 "[api] opencode | STEP_ONE"; then
  pass "a dispatched task's lines are live, and name the task"
else
  fail "a dispatched task's lines are live, and name the task | $(log_of j3)"
fi
touch "$RELEASE"
wait_for 60 has_rc j3
assert_eq "the plan finishes" "$(cat "$PROJ/.orch/jobs/j3/rc" 2>/dev/null)" "0"
assert_contains "the task's check names the task too" "$(log_of j3)" '\[api\] check | TASK_CHECK_SAYS'
assert_contains "the project check shows" "$(log_of j3)" "check | PROJECT_SAYS"
assert_contains "  ...and still fills its own log" "$(cat "$PROJ/.orch/results/_check.log" 2>/dev/null)" "PROJECT_SAYS"
assert_contains "the task's result file still holds the agent's output" \
  "$(cat "$PROJ/.orch/results/api"* 2>/dev/null)" "STEP_ONE"

# --- 4. a CLI that prints nothing until it ends still shows progress --------------
# hermes -z and pi --print are like this: without these lines their panes stay empty.
rm -f "$RELEASE"
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
sleep 1.5
echo x > "${dir:-.}/made.txt"
mkdir -p "${dir:-.}/.hidden" "${dir:-.}/node_modules/dep"
echo x > "${dir:-.}/.hidden/noise.txt"
echo x > "${dir:-.}/node_modules/dep/noise.txt"
for ((i = 0; i < 400; i++)); do [[ -f "$RELEASE" ]] && break; sleep 0.1; done
printf '{"ok":true,"agent":"opencode","summary":"finished"}'
EOF
( cd "$PROJ" && rm -f .orch/tasks.json .orch/config.yaml && FA_LIVE_STEP=1 ATTEMPT_TIMEOUT=60 \
    "$FA" run --detach -b b0:fp0 "a quiet task" </dev/null >/dev/null 2>&1 )
if wait_for 20 in_log j4 "made.txt"; then
  pass "an agent that prints nothing still shows the files it changed"
else
  fail "an agent that prints nothing still shows the files it changed | $(log_of j4)"
fi
assert_contains "  ...in a line that says fa wrote it" "$(log_of j4)" "opencode | (fa: 0m[0-9]*s in, changed: made.txt"
assert_not_contains "  ...without folders that would drown it" "$(log_of j4)" "noise.txt"
if wait_for 20 in_log j4 "still working"; then
  pass "when no file changes, it still says the work is going"
else
  fail "when no file changes, it still says the work is going | $(log_of j4)"
fi
touch "$RELEASE"
wait_for 30 has_rc j4
assert_eq "the job finishes" "$(cat "$PROJ/.orch/jobs/j4/rc" 2>/dev/null)" "0"
size="$(wc -c < "$PROJ/.orch/jobs/j4/log")"
sleep 3
assert_eq "the progress lines stop when the agent does" "$(wc -c < "$PROJ/.orch/jobs/j4/log")" "$size"

# --- 5. what comes back to fa is exactly what it would have been ----------------
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
printf '  leading spaces\n\ttabbed \\n literal\n\n\033[31mred\033[0m\r\nno newline at the end'
exit "${STUB_RC:-0}"
EOF
call() { # -> the agent's output as fa receives it; exit code after a final line
  bash -c ". '$REPO/bin/lib/common.sh'; out=\"\$(adapter_invoke opencode m p x)\"; rc=\$?; printf '%s' \"\$out\"; printf '\nrc=%s' \"\$rc\""
}
plain="$(INVOKE_TIMEOUT=5 call)"
live_file="$T/live.log"
assert_eq "live, fa receives the same bytes" "$(FA_LIVE_LOG="$live_file" INVOKE_TIMEOUT=5 call)" "$plain"
assert_contains "  ...and the live log did get them" "$(cat "$live_file" 2>/dev/null)" "no newline at the end"
assert_contains "the exit code still comes back" "$(STUB_RC=7 FA_LIVE_LOG="$live_file" INVOKE_TIMEOUT=5 call)" "rc=7"
assert_eq "a log that cannot be written costs nothing" \
  "$(FA_LIVE_LOG=/nonexistent/dir/log INVOKE_TIMEOUT=5 call)" "$plain"
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
sleep 2.5; printf 'QUIET_REPLY'
EOF
assert_eq "progress lines never join what fa classifies" \
  "$(FA_LIVE_STEP=1 FA_LIVE_LOG="$live_file" INVOKE_TIMEOUT=10 call)" "$(printf 'QUIET_REPLY\nrc=0')"

cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
echo "BEFORE_THE_LIMIT"; sleep 30
EOF
out="$(FA_LIVE_LOG="$live_file" INVOKE_TIMEOUT=1 call 2>&1)"
assert_contains "the time limit still fires, with timeout's 124" "$out" "rc=124"
assert_contains "  ...and what was printed before it survives" "$out" "BEFORE_THE_LIMIT"

# --- 6. nothing changes outside a background job --------------------------------
cat > "$T/opencode" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true,"agent":"opencode","summary":"FOREGROUND_REPLY"}'
EOF
WD="$(mktemp -d)"
"$REPO/bin/run.sh" -w "$WD" -b b0:fp0 "a task" >"$T/fg.out" 2>"$T/fg.err" </dev/null
assert_contains "in the foreground the result is on stdout, as ever" "$(cat "$T/fg.out")" "FOREGROUND_REPLY"
assert_not_contains "  ...and not repeated on stderr" "$(cat "$T/fg.err")" "FOREGROUND_REPLY"
rm -rf "$WD"

end_suite
final_report
