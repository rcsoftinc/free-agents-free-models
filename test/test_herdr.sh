#!/usr/bin/env bash
# Proves a background job started inside herdr is watched from a pane of its
# own - streaming its log, its state in herdr's sidebar, a notification when it
# ends - while staying exactly as robust as anywhere else: herdr failing must
# never fail or stall a job, and fa only ever closes panes it opened itself.
#
# Every herdr call here goes to test/stubs/herdr, which logs it. The harness
# hides HERDR_* from every suite; this one opts back in, against the stub - a
# suite run from a herdr pane must never put panes into the live session.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "background jobs inside herdr: a pane, a state, a notification"
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
in_herdr() { HERDR_ENV=1 HERDR_PANE_ID=wT:p1 "$@"; }
wait_rc() { local i; for ((i = 0; i < 150; i++)); do [[ -f "$PROJ/.orch/jobs/$1/rc" ]] && return 0; sleep 0.2; done; return 1; }
calls() { cat "$HERDR_STUB_LOG" 2>/dev/null; }

# --- 1. outside herdr nothing changes -----------------------------------------
detach "$FA" run --detach -b b0:fp0 "outside" >/dev/null
wait_rc j1
assert_eq "outside herdr, a job never calls herdr" "$(calls | wc -l)" "0"

# --- 2. inside herdr: a pane of its own -----------------------------------------
t0=$(date +%s)
out="$(in_herdr detach "$FA" run --detach -b b0:fp0 "inside")"
dt=$(( $(date +%s) - t0 ))
assert_true "detaching still returns at once (${dt}s)" '[[ $dt -lt 2 ]]'
assert_contains "it says where to watch it" "$out" "watching it in herdr pane wT:p9"
assert_contains "the pane splits from the caller's, keeping the user's focus" \
  "$(calls)" "pane split --current --direction right --cwd $PROJ --no-focus"
assert_contains "the pane is named after the job" "$(calls)" "pane rename wT:p9 fa j2"
assert_contains "the pane follows the job" "$(calls)" "pane run wT:p9 .*/bin/fa jobs --follow j2"
assert_eq "the job knows its pane" "$(cat "$PROJ/.orch/jobs/j2/herdr_pane" 2>/dev/null)" "wT:p9"
wait_rc j2
sleep 0.3
assert_contains "the sidebar shows it working while it runs" \
  "$(calls)" "pane report-agent --source fa --agent fa --state working --message j2: fa run -b b0:fp0 inside --seq 1 wT:p9"
assert_contains "and idle once it is done" \
  "$(calls)" "pane report-agent --source fa --agent fa --state idle --message j2 done --seq 2 wT:p9"
assert_contains "a notification says it is done" "$(calls)" "notification show fa j2 done --body fa run -b b0:fp0 inside --sound done"
assert_contains "fa jobs <id> names its pane" "$(detach "$FA" jobs j2)" "pane:   wT:p9 (herdr)"

# A tall pane is split downward, as herdr's own layout rule says.
: > "$HERDR_STUB_LOG"
HERDR_STUB_W=60 HERDR_STUB_H=40 in_herdr detach "$FA" run --detach -b b0:fp0 "tall" >/dev/null
wait_rc j3
assert_contains "a narrow or tall caller pane is split downward" "$(calls)" "pane split --current --direction down"

# A failure is said as loudly as a success.
: > "$HERDR_STUB_LOG"
in_herdr detach "$FA" run --detach -b no-such:bucket "will fail" >/dev/null
wait_rc j4; sleep 0.3
assert_ne "(that job did fail)" "$(cat "$PROJ/.orch/jobs/j4/rc" 2>/dev/null)" "0"
assert_contains "a failed job's notification says so, and asks for attention" \
  "$(calls)" "notification show fa j4 FAILED rc=.* --sound request"

# --- 3. herdr broken or switched off: the job does not care ------------------------
: > "$HERDR_STUB_LOG"
HERDR_STUB_FAIL=1 in_herdr detach "$FA" run --detach -b b0:fp0 "herdr down" >/dev/null
wait_rc j5
assert_eq "with herdr failing, the job still completes" "$(cat "$PROJ/.orch/jobs/j5/rc" 2>/dev/null)" "0"
assert_true "  ...just without a pane" '[[ ! -e "$PROJ/.orch/jobs/j5/herdr_pane" ]]'
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

# --- 5. cleaning up closes fa's own panes, and only those ------------------------------
: > "$HERDR_STUB_LOG"
STUB_HOLD=6 in_herdr detach "$FA" run --detach -b b0:fp0 "still running" >/dev/null
printf 'wT:p7\n' > "$PROJ/.orch/jobs/j9/herdr_pane"    # the running job's pane
in_herdr detach "$FA" jobs --clean >/dev/null
assert_contains "--clean closes a finished job's pane" "$(calls)" "pane close wT:p9"
assert_not_contains "but never a running job's" "$(calls)" "pane close wT:p7"
assert_true "  ...whose job is left alone" '[[ -d "$PROJ/.orch/jobs/j9" ]]'
wait_rc j9

end_suite
final_report
