#!/usr/bin/env bash
# test_worktree_pool.sh - the worktree POOL itself (wt_pool_claim/
# wt_pool_prepare in orch.sh): a slot survives across SEPARATE orch.sh
# invocations (not just within one run), a stray file a prior task's agent
# left behind is cleaned before the next task ever sees it, and a corrupted
# slot recovers by recreating rather than failing the task.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "worktree pool: cross-invocation reuse and contamination safety"
fixture_registry 3 || exit 1
sandbox_on

PROJECT_DIR="$(mktemp -d)"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@test.test
git -C "$PROJECT_DIR" config user.name test
git -C "$PROJECT_DIR" commit --allow-empty -q -m init

run_one() { # $1=task_id $2=file $3=content -> combined stdout+stderr
  local id="$1" file="$2" content_b64; content_b64="$(printf '%s' "$3" | base64)"
  mkdir -p "${PROJECT_DIR}/.orch"
  cat > "${PROJECT_DIR}/.orch/tasks.json" <<EOF
{"tasks":[{"id":"${id}","prompt":"write it\nFA_STUB_WRITE:${file}:${content_b64}",
           "deps":[],"files":["${file}"],"category":"coding"}]}
EOF
  ORCH_PROJECT="$PROJECT_DIR" timeout 60 "$REPO/bin/orch.sh" \
    run "${PROJECT_DIR}/.orch/tasks.json" --isolate 2>&1
}

POOL1="${PROJECT_DIR}/.orch/worktrees/pool-1"

# --- 1. first invocation creates the slot -----------------------------------
out1="$(run_one first first.txt FIRST-CONTENT)"
assert_contains "first run creates pool slot 1 fresh" "$out1" "pool slot 1: created fresh"
assert_eq "first.txt landed in the project" "$(cat "${PROJECT_DIR}/first.txt" 2>/dev/null)" "FIRST-CONTENT"
assert_true "the pool slot directory persists after the run ends" '[[ -d "$POOL1" ]]'

# --- 2. a SEPARATE orch.sh invocation reuses it, not a fresh checkout -------
out2="$(run_one second second.txt SECOND-CONTENT)"
assert_contains "a second, separate orch.sh invocation reuses the same slot" \
  "$out2" "pool slot 1: reused (reset to current HEAD)"
assert_not_contains "it did not need to create a new one" "$out2" "created fresh"
assert_eq "second.txt landed correctly" "$(cat "${PROJECT_DIR}/second.txt" 2>/dev/null)" "SECOND-CONTENT"

# --- 3. a stray file a prior task's agent left behind never reaches the ----
#        next task - proves git clean -fdx actually runs before reuse
touch "${POOL1}/leftover-scratch-file.tmp"
assert_true "the stray file exists before the next run" '[[ -e "${POOL1}/leftover-scratch-file.tmp" ]]'
out3="$(run_one third third.txt THIRD-CONTENT)"
assert_contains "the third run also reuses the slot" "$out3" "pool slot 1: reused"
assert_true "the stray file was cleaned before this task ran" \
  '[[ ! -e "${POOL1}/leftover-scratch-file.tmp" ]]'
assert_eq "third.txt is unaffected" "$(cat "${PROJECT_DIR}/third.txt" 2>/dev/null)" "THIRD-CONTENT"

# --- 4. a corrupted slot recovers by recreating, not by failing the task ----
rm -f "${POOL1}/.git"
printf 'not a real git pointer file' > "${POOL1}/.git"
out4="$(run_one fourth fourth.txt FOURTH-CONTENT)"
assert_contains "a corrupted slot is detected and recreated" "$out4" "could not be reset cleanly - recreating it"
assert_contains "recreation itself succeeds" "$out4" "pool slot 1: created fresh"
assert_eq "the task still completes correctly despite the corruption" \
  "$(cat "${PROJECT_DIR}/fourth.txt" 2>/dev/null)" "FOURTH-CONTENT"

# --- 5. exactly one slot exists throughout - nothing accumulated -----------
wt_count="$(git -C "$PROJECT_DIR" worktree list | wc -l)"
assert_eq "still exactly one pool slot after four separate runs (main + pool-1)" "$wt_count" "2"

# --- 6. `setup:` gives a fresh checkout what git does not carry, once -------
# .deps is ignored by git, so a reset would normally remove it (clean -fdx).
# With a setup configured a slot keeps what it installed between tasks (clean
# -fd), so the install happens once per slot, not per task - and again when
# the setup line changes. A failing setup is said, journaled, shown by fa
# status, and the task still runs.
printf '.deps\n' > "$PROJECT_DIR/.gitignore"
git -C "$PROJECT_DIR" add .gitignore && git -C "$PROJECT_DIR" commit -q -m gitignore
SETUP_LOG="$(mktemp)"
printf 'setup: echo ran >> %s && echo installed > .deps\n' "$SETUP_LOG" > "$PROJECT_DIR/.orch/config.yaml"
out6="$(run_one fifth fifth.txt FIFTH)"
assert_contains "a reused slot gets the setup when none ran there before" "$out6" "setup (pool-1):"
assert_eq "  ...once" "$(grep -c ran "$SETUP_LOG")" "1"
assert_true "  ...and it left its install in the slot" '[[ -f "$POOL1/.deps" ]]'
assert_contains "  ...journaled as passed" "$(cat "$PROJECT_DIR/.orch/journal.ndjson")" \
  '"event":"setup","task":"-","where":"pool-1","result":"passed"'
assert_eq "  ...and the task ran" "$(cat "${PROJECT_DIR}/fifth.txt" 2>/dev/null)" "FIFTH"
out7="$(run_one sixth sixth.txt SIXTH)"
assert_not_contains "the next task does not run it again" "$out7" "setup (pool-1):"
assert_eq "  ...(still once)" "$(grep -c ran "$SETUP_LOG")" "1"
assert_true "  ...and the install survived the slot's reset" '[[ -f "$POOL1/.deps" ]]'
printf 'setup: echo ran >> %s && echo v2 > .deps\n' "$SETUP_LOG" > "$PROJECT_DIR/.orch/config.yaml"
out8="$(run_one seventh seventh.txt SEVENTH)"
assert_eq "a changed setup line runs again" "$(grep -c ran "$SETUP_LOG")" "2"
assert_eq "  ...and its result replaces the old one" "$(cat "$POOL1/.deps" 2>/dev/null)" "v2"
printf 'setup: exit 3\n' > "$PROJECT_DIR/.orch/config.yaml"
out9="$(run_one eighth eighth.txt EIGHTH)"
assert_contains "a failing setup is reported" "$out9" "setup (pool-1) FAILED: it exited 3"
assert_contains "  ...journaled" "$(cat "$PROJECT_DIR/.orch/journal.ndjson")" \
  '"event":"setup","task":"-","where":"pool-1","result":"failed","cmd":"exit 3","rc":"3"'
assert_eq "  ...and the task still ran" "$(cat "${PROJECT_DIR}/eighth.txt" 2>/dev/null)" "EIGHTH"
assert_contains "  ...which fa status shows" "$(cd "$PROJECT_DIR" && "$REPO/bin/fa" status 2>&1)" \
  "SETUP FAILED  (pool-1)  \`exit 3\`"
out10="$(run_one ninth ninth.txt NINTH)"
assert_contains "  ...and the next task tries it again" "$out10" "setup (pool-1) FAILED"
: > "$PROJECT_DIR/.orch/config.yaml"
touch "$POOL1/.deps"
out11="$(run_one tenth tenth.txt TENTH)"
assert_true "without a setup, a reset removes ignored files as before" '[[ ! -e "$POOL1/.deps" ]]'
rm -f "$SETUP_LOG"

rm -rf "$PROJECT_DIR"
end_suite
final_report
