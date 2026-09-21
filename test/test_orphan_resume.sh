#!/usr/bin/env bash
# test_orphan_resume.sh - killing the orchestrator does not kill the children
# it already forked. A naive resume has no memory of what a previous, now-dead
# orch.sh process had in flight (RUNNING/PIDS are fresh, empty maps on every
# invocation), and could dispatch a SECOND run_task() for a task whose first
# attempt is still running as an orphan - both writing to the same
# ${RESULTS}/<id>.out/.err files.
#
# Test 1: a task whose last journal event is "started" under a PID that is
# still alive must NOT be redispatched, however long resume polls.
# Test 2: a task whose last event is "started" under a PID that is NOT alive
# (the previous process AND its child are both gone) is safe to redispatch,
# and gets a visible orphan_abandoned finding.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "orphan-aware resume"
fixture_registry 3 || exit 1
sandbox_on

append_started() { # $1=journal $2=task $3=pid
  jq -cn --arg t "$(date -u +%FT%TZ)" --arg task "$2" --arg pid "$3" \
    '{ts:$t, event:"started", task:$task, pid:$pid}' >> "$1"
}

# --- 1. a live orphan is never redispatched ---------------------------------
PROJ1="$(mktemp -d)"; mkdir -p "$PROJ1/.orch"
cat > "$PROJ1/.orch/tasks.json" <<'EOF'
{"tasks":[{"id":"solo","prompt":"do the work","deps":[],"files":[],"category":"coding"}]}
EOF
JOURNAL1="$PROJ1/.orch/journal.ndjson"

sleep 30 & orphan_pid=$!
append_started "$JOURNAL1" solo "$orphan_pid"

# resume would poll forever waiting on an orphan that never finishes in this
# test, so bound it with `timeout` - what matters is what happens WHILE it's
# polling, not that it ever exits on its own.
ORCH_PROJECT="$PROJ1" ORPHAN_POLL=1 timeout 6 "$REPO/bin/orch.sh" resume \
  --max-parallel 1 >"$PROJ1/out.log" 2>&1 || true

kill "$orphan_pid" 2>/dev/null || true
wait "$orphan_pid" 2>/dev/null || true

started_count="$(jq -s 'map(select(.event=="started" and .task=="solo")) | length' "$JOURNAL1")"
assert_eq "no duplicate dispatch while the orphan's pid stayed alive" "$started_count" "1"
assert_not_contains "no fresh 'dispatch solo' log line was ever printed" \
  "$(cat "$PROJ1/out.log")" "dispatch solo"
assert_contains "resume logs that it is waiting on the orphan" \
  "$(cat "$PROJ1/out.log")" "waiting on"

rm -rf "$PROJ1"

# --- 2. an abandoned orphan (pid already gone) is safely redispatched ------
PROJ2="$(mktemp -d)"; mkdir -p "$PROJ2/.orch"
cat > "$PROJ2/.orch/tasks.json" <<'EOF'
{"tasks":[{"id":"solo2","prompt":"do the work","deps":[],"files":[],"category":"coding"}]}
EOF
JOURNAL2="$PROJ2/.orch/journal.ndjson"

# A PID guaranteed to be dead: start a process, wait for it to exit, reuse
# its now-free pid number. (Vanishingly small chance of PID reuse colliding
# with something else on a real machine between these two lines; acceptable
# for a test.)
( exit 0 ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null || true
append_started "$JOURNAL2" solo2 "$dead_pid"

ORCH_PROJECT="$PROJ2" timeout 60 "$REPO/bin/orch.sh" resume --max-parallel 1 \
  >"$PROJ2/out.log" 2>&1
rc2=$?

assert_eq "the task completes once redispatched" "$rc2" "0"
abandoned_count="$(jq -s 'map(select(.event=="orphan_abandoned" and .task=="solo2")) | length' "$JOURNAL2")"
assert_eq "an orphan_abandoned event is journaled exactly once" "$abandoned_count" "1"
done_count="$(jq -s 'map(select(.event=="done" and .task=="solo2")) | length' "$JOURNAL2")"
assert_eq "solo2 reaches done via the fresh dispatch" "$done_count" "1"

rm -rf "$PROJ2"

# --- 3. retry budget (ATTEMPTS) survives a resume, not reset to zero -------
# ATTEMPTS is otherwise a fresh, empty map on every cmd_run invocation, so a
# task that already failed once under a prior, now-dead process would get up
# to TASK_RETRIES+1 MORE attempts on this resume alone, on top of what it had
# already spent - burning extra lane/request budget on a task the configured
# retry count was meant to cap.
PROJ3="$(mktemp -d)"; mkdir -p "$PROJ3/.orch"
cat > "$PROJ3/.orch/tasks.json" <<'EOF'
{"tasks":[{"id":"failer","prompt":"do the work","deps":[],"files":[],"category":"coding"}]}
EOF
JOURNAL3="$PROJ3/.orch/journal.ndjson"

# Simulate: a prior orch.sh process already spent one attempt on this task,
# failed, and crashed before retrying it further.
jq -cn --arg t "$(date -u +%FT%TZ)" \
  '{ts:$t, event:"attempt_failed", task:"failer", rc:"2"}' >> "$JOURNAL3"

mode_for opencode error; mode_for kilo error; mode_for hermes error

TASK_RETRIES=2 ORCH_PROJECT="$PROJ3" timeout 120 "$REPO/bin/orch.sh" resume \
  --max-parallel 1 >"$PROJ3/out.log" 2>&1
rc3=$?

assert_eq "the run reports failure once the budget is exhausted" "$rc3" "1"
total_attempts="$(jq -s 'map(select(.event=="attempt_failed" and .task=="failer")) | length' "$JOURNAL3")"
# 1 pre-seeded (the crashed prior process) + TASK_RETRIES(2) more from this
# resume = 3 total. Without the fix, this resume alone would spend up to
# TASK_RETRIES+1(=3) MORE attempts on top of the pre-seeded one, for 4 total.
assert_eq "resume continues the SAME retry budget, not a fresh one" "$total_attempts" "3"
failed_count="$(jq -s 'map(select(.event=="failed" and .task=="failer")) | length' "$JOURNAL3")"
assert_eq "the task is marked failed exactly once" "$failed_count" "1"

clear_modes
rm -rf "$PROJ3"

end_suite
final_report
