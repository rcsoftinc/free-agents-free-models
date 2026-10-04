#!/usr/bin/env bash
# Proves --detach gives the coordinator its conversation back. `fa run --detach`
# and `fa dispatch --detach` must return at once while the work runs on in the
# background, survive the caller being killed, report through `fa jobs` and
# `fa status` - and a project must never run two orchestrators at once, which
# backgrounding makes one stray command away.
#
# "Returns at once" is measured through `$(...)`, deliberately: command
# substitution waits for EOF on the command's stdout, so a job that kept the
# caller's stdout open would make it wait for the whole job - which is exactly
# what an agent CLI's shell tool would do too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "background jobs: fa run / fa dispatch --detach"
# Two lanes, both agents that take --dir, so FA_STUB_WRITE lands where the
# runner verifies it.
fixture_registry 2 || exit 1
sandbox_on

FA="$REPO/bin/fa"
PROJ="$(mktemp -d)"; CONC="$(mktemp -d)"
trap 'rm -rf "$PROJ" "$CONC" "$FIXTURE_DIR"' EXIT
# Every stubbed agent call now takes HOLD seconds: long enough to tell
# "returned at once" from "waited for the work".
export STUB_CONC_DIR="$CONC" STUB_HOLD=4

wait_for() { # $1=seconds, rest=command; polls until the command succeeds
  local s="$1" i; shift
  for ((i = 0; i < s * 5; i++)); do "$@" && return 0; sleep 0.2; done
  return 1
}
has_rc()  { [[ -f "$PROJ/.orch/jobs/$1/rc" ]]; }
fajobs()  { ( cd "$PROJ" && "$FA" jobs "$@" ) 2>&1; }
run_lock_held() { ! ( exec 9<>"$PROJ/.orch/.run.lock"; flock -n 9 ) 2>/dev/null; }

# --- 1. fa run --detach returns at once and the work still happens -----------
t0=$(date +%s)
out="$(cd "$PROJ" && "$FA" run --detach -b b0:fp0 "slow task" </dev/null 2>&1)"; rc=$?
dt=$(( $(date +%s) - t0 ))
assert_eq "fa run --detach exits 0" "$rc" "0"
assert_true "it returns at once, not when the work ends (${dt}s, work takes ${STUB_HOLD}s)" '[[ $dt -lt 3 ]]'
assert_contains "it names the job" "$out" "job j1 started in the background"
assert_contains "fa jobs shows it running meanwhile" "$(fajobs)" "j1   running"
assert_true ".orch/.gitignore keeps jobs/ out of git" 'grep -qx "jobs/" "$PROJ/.orch/.gitignore"'
wait_for 30 has_rc j1
assert_eq "the job finishes and records its exit" "$(cat "$PROJ/.orch/jobs/j1/rc" 2>/dev/null)" "0"
assert_contains "its log holds the run's output" "$(cat "$PROJ/.orch/jobs/j1/log" 2>/dev/null)" "stub success"
assert_contains "fa jobs then shows it done" "$(fajobs)" "j1   done"
assert_contains "fa jobs <id> shows the detail" "$(fajobs j1)" "state:  done"

# --- 2. the job survives its caller's whole process group being killed ---------
# An agent CLI may kill the process group of a shell call once it returns or
# times out. The job must not be in that group.
PG="$PROJ/caller.pgid"
setsid bash -c 'echo $$ > "$1"; cd "$2" && "$3" run --detach -b b1:fp1 "outlives its caller" \
  </dev/null >/dev/null 2>&1; sleep 30' _ "$PG" "$PROJ" "$FA" &
wait_for 10 test -d "$PROJ/.orch/jobs/j2"
kill -TERM -- "-$(cat "$PG")" 2>/dev/null
wait_for 30 has_rc j2
assert_eq "a job outlives its caller's killed process group" "$(cat "$PROJ/.orch/jobs/j2/rc" 2>/dev/null)" "0"

# --- 3. fa dispatch --detach: the plan runs in the background ------------------
b64() { printf '%s' "$1" | base64 -w0; }
cat > "$PROJ/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"one","prompt":"write one\nFA_STUB_WRITE:one.txt:$(b64 one)","deps":[],"files":["one.txt"],"category":"coding"},
  {"id":"two","prompt":"write two\nFA_STUB_WRITE:two.txt:$(b64 two)","deps":["one"],"files":["two.txt"],"category":"coding"}]}
EOF
t0=$(date +%s)
out="$(cd "$PROJ" && "$FA" dispatch --detach </dev/null 2>&1)"; rc=$?
dt=$(( $(date +%s) - t0 ))
assert_eq "fa dispatch --detach exits 0" "$rc" "0"
assert_true "it returns at once (${dt}s for a two-task chain)" '[[ $dt -lt 3 ]]'
assert_contains "it names the job" "$out" "job j3 started in the background"
assert_contains "it says which files are the plan's until it ends" "$out" "hands off these files until it ends: one.txt two.txt"

# --- 4. one orchestrator per project ------------------------------------------
wait_for 10 run_lock_held
out="$(cd "$PROJ" && "$FA" dispatch --detach </dev/null 2>&1)"; rc=$?
assert_ne "a second detached dispatch is refused while one runs" "$rc" "0"
assert_contains "  ...and says why" "$out" "already in progress"
out="$(cd "$PROJ" && "$FA" resume </dev/null 2>&1)"; rc=$?
assert_ne "so is a resume - it would replay the same journal" "$rc" "0"
assert_contains "  ...also saying why" "$out" "already in progress"
assert_contains "fa status shows the running job" "$(cd "$PROJ" && "$FA" status 2>&1)" "j3   running"

wait_for 60 has_rc j3
assert_eq "the detached dispatch finishes cleanly" "$(cat "$PROJ/.orch/jobs/j3/rc" 2>/dev/null)" "0"
assert_contains "it ran the plan through orch, even as a chain" \
  "$(cat "$PROJ/.orch/jobs/j3/log" 2>/dev/null)" "background job j3: running the plan through orch"
assert_true "both tasks' files were written" '[[ -f "$PROJ/one.txt" && -f "$PROJ/two.txt" ]]'
st="$(cd "$PROJ" && "$FA" status 2>&1)"
assert_contains "fa status counts both tasks done" "$st" "2/2 done"
assert_contains "and lists the finished job" "$st" "j3   done"

# --- 5. mistakes are reported now, not into a log ------------------------------
EMPTY="$(mktemp -d)"
out="$(cd "$EMPTY" && "$FA" dispatch --detach </dev/null 2>&1)"; rc=$?
assert_ne "dispatch --detach with no goal and no plan fails at once" "$rc" "0"
assert_contains "  ...in the foreground, saying why" "$out" "no goal given and no plan"
assert_true "  ...without leaving a job behind" '[[ ! -d "$EMPTY/.orch/jobs" ]]'
out="$(cd "$PROJ" && "$FA" run --detach - </dev/null 2>&1)"; rc=$?
assert_ne "a detached run cannot take its prompt from stdin" "$rc" "0"
assert_contains "  ...and says so" "$out" "has no stdin"
rm -rf "$EMPTY"

# A prompt that merely mentions --detach is a prompt, not a flag.
STUB_HOLD=0 out="$(cd "$PROJ" && "$FA" run -b b0:fp0 "add a --detach flag to the CLI" </dev/null 2>&1)"
assert_true "'--detach' inside a prompt starts no job" '[[ ! -d "$PROJ/.orch/jobs/j4" ]]'

# --- 6. a job that vanished is called dead, not running ------------------------
D="$PROJ/.orch/jobs/j99"; mkdir -p "$D"
sleep 0 & dead=$!; wait "$dead"
echo "$dead" > "$D/pid"; echo "fa run \"lost\"" > "$D/cmd"; echo $(( $(date +%s) - 60 )) > "$D/started_at"
assert_contains "a job with no exit and no process shows DIED" "$(fajobs)" "j99  DIED"

# --- 7. --news: each ending reported once, silence when nothing happened -------
# The coordinator runs this at the start of every reply (director mode), so it
# must say each ending exactly once - and nothing at all when nothing happened.
news="$(fajobs --news)"
assert_contains "--news reports a job that ended" "$news" "ended: j1 done after"
assert_contains "  ...with what to review" "$news" "review it: fa jobs j1"
assert_contains "  ...including a dispatch's tasks" "$news" "fa status (its tasks)"
assert_eq "--news reports each ending only once" "$(fajobs --news | grep -c '^ended:' || true)" "0"
STUB_HOLD=4 out="$(cd "$PROJ" && "$FA" run --detach -b b0:fp0 "news in progress" </dev/null 2>&1)"
nid="$(grep -o 'job j[0-9]*' <<<"$out" | cut -d' ' -f2)"
assert_contains "--news names what is still running" "$(fajobs --news)" "running: ${nid} ("
wait_for 30 has_rc "$nid"
assert_contains "and reports it once it ends" "$(fajobs --news)" "ended: ${nid} done"
assert_eq "--news is silent when nothing ended and nothing runs" "$(fajobs --news)" ""

# --- 8. --clean drops what ended, never what runs ------------------------------
out="$(cd "$PROJ" && "$FA" run --detach -b b0:fp0 "still running" </dev/null 2>&1)"
running="$(grep -o 'job j[0-9]*' <<<"$out" | cut -d' ' -f2)"
fajobs --clean >/dev/null
assert_true "--clean removes finished and dead jobs" '[[ ! -d "$PROJ/.orch/jobs/j1" && ! -d "$PROJ/.orch/jobs/j99" ]]'
assert_true "--clean leaves a running job alone" '[[ -d "$PROJ/.orch/jobs/$running" ]]'
wait_for 30 has_rc "$running"

end_suite
final_report
