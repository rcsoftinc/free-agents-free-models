#!/usr/bin/env bash
# Proves a background job started inside herdr is watched from a tab of its own,
# and each task of a dispatch from its own - streaming its log, the agent's name and
# state in herdr's sidebar, a notification when it ends - while staying exactly as
# robust as anywhere else: herdr failing must never fail or stall a job, and fa only
# ever closes tabs it opened itself.
#
# Every herdr call here goes to test/stubs/herdr, which logs it. The harness
# hides HERDR_* from every suite; this one opts back in, against the stub - a
# suite run from a herdr pane must never put tabs into the live session.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "background jobs inside herdr: a tab, the agent's state, a notification"
assert_eq "the harness hides herdr from every suite by default" \
  "$(env | grep -c '^HERDR_' || true)" "0"
fixture_registry 2 || exit 1
sandbox_on

FA="$REPO/bin/fa"
PROJ="$(mktemp -d)"; CONC="$(mktemp -d)"
trap 'rm -rf "$PROJ" "$CONC" "$FIXTURE_DIR"' EXIT
export HERDR_STUB_LOG="$PROJ/herdr.log"
export STUB_CONC_DIR="$CONC" STUB_HOLD=2
detach() { ( cd "$PROJ" && "$@" </dev/null 2>&1 ); }
in_herdr() { HERDR_ENV=1 HERDR_PANE_ID=wT:p1 HERDR_WORKSPACE_ID=wT "$@"; }
wait_rc() { local i; for ((i = 0; i < 150; i++)); do [[ -f "$PROJ/.orch/jobs/$1/rc" ]] && return 0; sleep 0.2; done; return 1; }
# A job writes its rc BEFORE its last herdr calls, so an rc does not mean they are
# over. Waiting on the rc alone let a slow CI runner log them after the next section
# had cleared the log, and a job with herdr switched off appeared to have called it.
wait_gone() {
  local i pid
  pid="$(cat "$PROJ/.orch/jobs/$1/pid" 2>/dev/null)"
  for ((i = 0; i < 150; i++)); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  return 1
}
calls() { cat "$HERDR_STUB_LOG" 2>/dev/null; }

# --- 1. outside herdr nothing changes -----------------------------------------
detach "$FA" run --detach -b b0:fp0 "outside" >/dev/null
wait_rc j1
assert_eq "outside herdr, a job never calls herdr" "$(calls | wc -l)" "0"

# --- 2. inside herdr: a tab of its own, named for the agent working in it --------
t0=$(date +%s)
out="$(in_herdr detach "$FA" run --detach -b b0:fp0 "inside")"
dt=$(( $(date +%s) - t0 ))
assert_true "detaching still returns at once (${dt}s)" '[[ $dt -lt 2 ]]'
assert_contains "it says where to watch it" "$out" "watching it in herdr tab wT:t9"
assert_contains "the job opens a tab, keeping the user's focus" \
  "$(calls)" "tab create --workspace wT --cwd $PROJ --label fa j2 --no-focus"
assert_not_contains "  ...and never splits the pane the user is reading" "$(calls)" "pane split"
assert_contains "the tab follows the job" "$(calls)" "pane run wT:p9 .*/bin/fa jobs --follow j2"
assert_eq "the job knows its pane" "$(cat "$PROJ/.orch/jobs/j2/herdr_pane" 2>/dev/null)" "wT:p9"
wait_rc j2; wait_gone j2
assert_contains "the sidebar shows the job starting" \
  "$(calls)" "pane report-agent --source fa --agent fa --state working --message j2: fa run -b b0:fp0 inside --seq [0-9]* wT:p9"
assert_contains "then the agent working in it, by name" \
  "$(calls)" "pane report-agent --source fa --agent opencode --state working --message j2: opencode --seq [0-9]* wT:p9"
assert_contains "  ...and so does the tab" "$(calls)" "tab rename wT:t9 j2 opencode"
assert_contains "and idle once it is done, still by name" \
  "$(calls)" "pane report-agent --source fa --agent opencode --state idle --message j2 done --seq [0-9]* wT:p9"
seqs="$(calls | sed -n 's/^pane report-agent.* --seq \([0-9]*\) wT:p9$/\1/p')"
assert_eq "herdr drops a report with a lower number, so they only go up" "$seqs" "$(sort -un <<<"$seqs")"
assert_contains "a notification says it is done" "$(calls)" "notification show fa j2 done --body fa run -b b0:fp0 inside --sound done"
assert_contains "fa jobs <id> names its tab" "$(detach "$FA" jobs j2)" "tab:    wT:t9 (herdr)"
log="$(cat "$PROJ/.orch/jobs/j2/log")"
assert_not_contains "herdr's answers stay out of what the agent printed" "$log" "cli:stub"

# Each attempt names its own agent, so a fallback shows.
: > "$HERDR_STUB_LOG"
in_herdr detach "$FA" run --detach -b b1:fp1 "on the other lane" >/dev/null
wait_rc j3; wait_gone j3
assert_ne "(that lane is another agent)" \
  "$(jq -r '.buckets["b1:fp1"].models[0].agent // empty' "$FIXTURE_DIR/buckets.json")" "opencode"
assert_contains "the tab names whichever agent is working" "$(calls)" \
  "tab rename wT:t9 j3 $(jq -r '.buckets["b1:fp1"].models[0].agent // empty' "$FIXTURE_DIR/buckets.json")"

# A failure is said as loudly as a success.
: > "$HERDR_STUB_LOG"
in_herdr detach "$FA" run --detach -b no-such:bucket "will fail" >/dev/null
wait_rc j4; wait_gone j4
assert_ne "(that job did fail)" "$(cat "$PROJ/.orch/jobs/j4/rc" 2>/dev/null)" "0"
assert_contains "a failed job's notification says so, and asks for attention" \
  "$(calls)" "notification show fa j4 FAILED rc=.* --sound request"
assert_contains "  ...and with no agent started, the sidebar says fa" \
  "$(calls)" "pane report-agent --source fa --agent fa --state idle --message j4 FAILED"

# --- 3. herdr broken or switched off: the job does not care ------------------------
: > "$HERDR_STUB_LOG"
HERDR_STUB_FAIL=1 in_herdr detach "$FA" run --detach -b b0:fp0 "herdr down" >/dev/null
wait_rc j5
assert_eq "with herdr failing, the job still completes" "$(cat "$PROJ/.orch/jobs/j5/rc" 2>/dev/null)" "0"
assert_true "  ...just without a tab" '[[ ! -e "$PROJ/.orch/jobs/j5/herdr_pane" ]]'
wait_gone j5
: > "$HERDR_STUB_LOG"
FA_HERDR=0 in_herdr detach "$FA" run --detach -b b0:fp0 "switched off" >/dev/null
wait_rc j6
assert_eq "FA_HERDR=0 keeps herdr out of it entirely" "$(calls | wc -l)" "0"
# A herdr server that hangs instead of failing: every call is time-boxed.
t0=$(date +%s)
HERDR_STUB_HANG=30 FA_HERDR_TIMEOUT=1 in_herdr detach "$FA" run --detach -b b0:fp0 "herdr hangs" >/dev/null
dt=$(( $(date +%s) - t0 ))
assert_true "a hung herdr costs a detach seconds, not the coordinator (${dt}s)" '[[ $dt -lt 6 ]]'
wait_rc j7
assert_eq "  ...and the job still completes" "$(cat "$PROJ/.orch/jobs/j7/rc" 2>/dev/null)" "0"

# --- 4. the viewer the pane runs -----------------------------------------------------
detach "$FA" run --detach -b b0:fp0 "followed" >/dev/null
t0=$(date +%s)
out="$(detach "$FA" jobs --follow j8)"
dt=$(( $(date +%s) - t0 ))
assert_contains "fa jobs --follow streams the job's output" "$out" "stub success"
assert_contains "  ...and ends by saying how the job ended" "$out" "job j8: done after"
assert_true "  ...returning once the job ends, not before (${dt}s for a ${STUB_HOLD}s job)" '[[ $dt -ge 1 && $dt -lt 15 ]]'
assert_contains "following a job that already ended prints its log at once" \
  "$(detach "$FA" jobs --follow j1)" "job j1: done after"

# --- 5. a dispatch: each task in a tab of its own -----------------------------------
: > "$HERDR_STUB_LOG"
jq -n '{tasks:[{id:"api", prompt:"do api", deps:[], files:[], category:"general"},
               {id:"web", prompt:"do web", deps:[], files:[], category:"general"}]}' \
  > "$PROJ/.orch/tasks.json"
in_herdr detach "$FA" dispatch --detach >/dev/null
wait_rc j9; wait_gone j9
assert_eq "the plan finishes" "$(cat "$PROJ/.orch/jobs/j9/rc" 2>/dev/null)" "0"
assert_contains "the plan has its tab, for the overview" "$(calls)" "tab create --workspace wT --cwd $PROJ --label fa j9 --no-focus"
assert_contains "each task has its own" "$(calls)" "tab create --workspace wT --cwd $PROJ --label fa api --no-focus"
assert_contains "  ...both of them" "$(calls)" "tab create --workspace wT --cwd $PROJ --label fa web --no-focus"
assert_contains "a task's tab follows only that task" "$(calls)" "pane run wT:p_api .*/bin/fa jobs --follow j9 api"
assert_contains "the sidebar names the agent working on it" \
  "$(calls)" "pane report-agent --source fa --agent [a-z]* --state working --message api: [a-z]* --seq [0-9]* wT:p_api"
assert_contains "  ...and so does the tab" "$(calls)" "tab rename wT:t_api api [a-z]*"
assert_contains "the sidebar says when that task is done, before the plan is" \
  "$(calls)" "pane report-agent --source fa --agent [a-z]* --state idle --message api done --seq [0-9]* wT:p_api"
assert_not_contains "the plan's tab does not take a task's agent as its own" "$(calls)" "tab rename wT:t9 "
n="$(calls | grep -c '^notification show')"
assert_eq "one notification for the plan, not one per task" "$n" "1"

# Run the helpers directly for what a whole plan will not show cheaply.
hb() { bash -c ". '$REPO/bin/lib/common.sh'; . '$REPO/bin/lib/jobs.sh'; $1"; }
V="$PROJ/.orch/jobs/fake"; mkdir -p "$V"; : > "$HERDR_STUB_LOG"
hb "FA_LIVE_LOG='$V/log' HERDR_ENV=1 ; export HERDR_ENV; herdr_open_task again; herdr_open_task again"
assert_eq "a task put back in the queue keeps its tab" "$(calls | grep -c '^tab create')" "1"
hb "FA_LIVE_LOG='$V/log' HERDR_ENV=1 HERDR_STUB_FAIL=1; export HERDR_ENV HERDR_STUB_FAIL; FA_HERDR_VIEW='$V'; herdr_open_task nope; printf 'view=%s' \"\${FA_HERDR_VIEW:-none}\"" > "$PROJ/view.out"
assert_eq "with no tab, a task's agent cannot relabel the plan's" "$(cat "$PROJ/view.out")" "view=none"
for rc_case in "0:done" "5:waiting for a free lane" "2:FAILED rc=2"; do
  : > "$HERDR_STUB_LOG"
  hb "HERDR_ENV=1; export HERDR_ENV; FA_HERDR_VIEW='$V/tasks/again'; herdr_task_ended ${rc_case%%:*}"
  assert_contains "a task ending with ${rc_case%%:*} says so" "$(calls)" "--message again ${rc_case#*:} "
done
: > "$HERDR_STUB_LOG"
printf 'wT:p_job\n' > "$V/herdr_pane"
hb "HERDR_ENV=1; export HERDR_ENV; FA_HERDR_VIEW='$V'; herdr_task_ended 0"
assert_eq "a job's own view is never marked ended by a task" "$(calls | wc -l)" "0"
rm -rf "$V"

# --- 6. the viewer a task's tab runs ---------------------------------------------------
J="$PROJ/.orch/jobs/j20"; mkdir -p "$J"; printf 'fa dispatch\n' > "$J/cmd"; echo 0 > "$J/rc"
now="$(date +%s)"; echo "$now" > "$J/started_at"; echo "$now" > "$J/finished_at"
cat > "$J/log" <<'EOF'
[orch] started
  [api] kilo | API_LINE
  [web] pi | WEB_LINE
  [api] check | API_CHECK
EOF
out="$(detach "$FA" jobs --follow j20 api)"
assert_contains "a task's view shows its lines" "$out" "kilo | API_LINE"
assert_contains "  ...and its checks" "$out" "check | API_CHECK"
assert_not_contains "  ...not the other task's" "$out" "WEB_LINE"
assert_not_contains "  ...nor the plan's own" "$out" "orch"
assert_not_contains "  ...without the prefix it no longer needs" "$out" "\[api\]"
assert_contains "the job's own view still shows everything" "$(detach "$FA" jobs --follow j20)" "WEB_LINE"

# --- 7. cleaning up closes fa's own tabs, and only those ------------------------------
: > "$HERDR_STUB_LOG"
STUB_HOLD=6 in_herdr detach "$FA" run --detach -b b0:fp0 "still running" >/dev/null
R=j10
printf 'wT:p7\n' > "$PROJ/.orch/jobs/$R/herdr_pane"    # the running job's pane
in_herdr detach "$FA" jobs --clean >/dev/null
assert_contains "--clean closes a finished job's tab" "$(calls)" "pane close wT:p9"
assert_contains "  ...and its tasks' tabs" "$(calls)" "pane close wT:p_api"
assert_not_contains "but never a running job's" "$(calls)" "pane close wT:p7"
assert_true "  ...whose job is left alone" '[[ -d "$PROJ/.orch/jobs/$R" ]]'
wait_rc "$R"

end_suite
final_report
