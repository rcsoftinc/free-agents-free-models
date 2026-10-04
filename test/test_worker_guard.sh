#!/usr/bin/env bash
# Proves a worker can never start more workers. Every agent fa launches is
# marked FA_DEPTH=1 by adapter_invoke, and every command that launches agents
# refuses inside one (refuse_if_worker, exit 6) before it reads, writes or
# spends anything.
#
# Why it matters: AGENTS.md is read by every agent, workers included. A worker
# that decided to hand its task on - the obvious move for one told to "always
# delegate" - would start another layer of workers, each free to do the same.
# A prompt can only ask a free model not to; this is what makes it impossible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "a worker can never start more workers"
fixture_registry 3 || exit 1
sandbox_on

FA="$REPO/bin/fa"
COMMON="$REPO/bin/lib/common.sh"
PROJ="$(mktemp -d)"; FAKE="$(mktemp -d)"
trap 'rm -rf "$PROJ" "$FAKE" "$FIXTURE_DIR"' EXIT
mkdir -p "$PROJ/.orch"
printf '%s\n' '{"tasks":[{"id":"a","prompt":"do a","deps":[],"files":[]},{"id":"b","prompt":"do b","deps":[],"files":[]}]}' \
  > "$PROJ/.orch/tasks.json"
reg_before="$(sha256sum < "$FIXTURE_DIR/buckets.json")"
tasks_before="$(cat "$PROJ/.orch/tasks.json")"
stub_log_new

# --- 1. what makes a worker: adapter_invoke marks every agent it launches -----
# A fake agent that only reports what it was handed.
printf '#!/usr/bin/env bash\necho "FA_DEPTH=${FA_DEPTH:-unset}"\n' > "$FAKE/opencode"
chmod +x "$FAKE/opencode"
depth() { # $1=caller's FA_DEPTH ("" = unset) -> what the agent saw, then the caller's after
  PATH="$FAKE:$PATH" bash -c '
    [[ -n "$2" ]] && export FA_DEPTH="$2"
    . "$1"; adapter_invoke opencode m p "x"; echo " after=${FA_DEPTH:-unset}"' _ "$COMMON" "$1"
}
out="$(depth "")"
assert_contains "an agent fa launches is marked a worker" "$out" "FA_DEPTH=1"
assert_contains "and the caller itself is left as it was" "$out" "after=unset"
assert_contains "an agent launched from inside a worker is one level deeper" "$(depth 1)" "FA_DEPTH=2"

# --- 2. everything that launches agents refuses inside a worker ---------------
refused() { # $1=what; rest=the command
  local what="$1" out rc; shift
  out="$(cd "$PROJ" && FA_DEPTH=1 timeout 60 "$@" </dev/null 2>&1)"; rc=$?
  assert_eq "$what refuses inside a worker (exit 6)" "$rc" "6"
  assert_contains "  ...and says so" "$out" "REFUSED"
}
refused "fa run"                "$FA" run "hand it on"
refused "fa run --detach"       "$FA" run --detach "hand it on"
refused "fa dispatch"           "$FA" dispatch
refused "fa dispatch --detach"  "$FA" dispatch --detach
refused "fa go"                 "$FA" go "a goal"
refused "fa plan"               "$FA" plan "a goal"
refused "orch.sh run"           "$REPO/bin/orch.sh" run "$PROJ/.orch/tasks.json"
refused "fa resume"             "$FA" resume
refused "fa probe"              "$FA" probe
refused "fa discover"           "$FA" discover
refused "fa bootstrap"          "$FA" bootstrap

# ...before touching anything at all.
assert_eq "no agent was started by any refused command" "$(stub_log_lines)" "0"
assert_eq "the registry was not touched" "$(sha256sum < "$FIXTURE_DIR/buckets.json")" "$reg_before"
assert_eq "the task graph was not overwritten" "$(cat "$PROJ/.orch/tasks.json")" "$tasks_before"
assert_true "no background job was created" '[[ ! -d "$PROJ/.orch/jobs" ]]'

# --- 3. reading is still a worker's business ----------------------------------
for c in "lanes" "rank coding" "status"; do
  ( cd "$PROJ" && FA_DEPTH=1 timeout 60 "$FA" $c </dev/null >/dev/null 2>&1 ); rc=$?
  assert_eq "fa $c still works inside a worker" "$rc" "0"
done

# --- 4. end to end: a worker that tries to hand its task on -------------------
# The fake agent does what a confused worker would: run fa itself, then get on
# with the job. The outer run must complete, the inner one must be refused,
# and exactly one agent must ever have run.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
echo started >> "$FAKE_CALLS"
printf '%s\n' "$*" > "$FAKE_PROMPT"
"$FA_BIN" run "hand it on" </dev/null >/dev/null 2>&1; echo "inner rc=$?"
printf '{"ok":true,"agent":"opencode","summary":"did it myself"}'
EOF
chmod +x "$FAKE/opencode"
out="$(cd "$PROJ" && PATH="$FAKE:$PATH" FAKE_CALLS="$FAKE/calls" FAKE_PROMPT="$FAKE/prompt" \
       FA_BIN="$FA" timeout 120 "$FA" run -b b0:fp0 "outer task" </dev/null 2>/dev/null)"; rc=$?
assert_eq "the outer run completes" "$rc" "0"
assert_contains "the worker's own attempt to hand it on was refused" "$out" "inner rc=6"
assert_eq "exactly one agent ever ran" "$(wc -l < "$FAKE/calls" 2>/dev/null)" "1"
assert_contains "the worker was told up front that it is a worker" \
  "$(cat "$FAKE/prompt" 2>/dev/null)" "launched by the coordinator to do this one task yourself"
# $(...) strips trailing newlines, which once ran every section of a worker's
# prompt into the next: "...inside a worker.Your working directory is...".
assert_true "each section of the prompt starts on its own line" \
  'grep -q "^Your working directory is" "$FAKE/prompt"'

end_suite
final_report
