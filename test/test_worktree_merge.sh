#!/usr/bin/env bash
# test_worktree_merge.sh - orch.sh's --isolate merge-back must COMMIT in
# $PROJECT, so a later dependent task's worktree (created from $PROJECT's
# CURRENT HEAD) actually contains an earlier task's merged work, instead of
# being silently reverted when the later task's own cp runs. This is exactly
# the pattern plan.sh's check_boundaries() permits between a declared
# dependency edge: two tasks sharing one file is not a conflict when one
# depends on the other.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "worktree isolation: merge-back preserves prior work"
fixture_registry 3 || exit 1
sandbox_on

PROJECT_DIR="$(mktemp -d)"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@test.test
git -C "$PROJECT_DIR" config user.name test
git -C "$PROJECT_DIR" commit --allow-empty -q -m init

# Stub protocol (test/stubs/{opencode,kilo,hermes}): a prompt line
# FA_STUB_WRITE:<relpath>:<base64> writes that file verbatim under --dir;
# FA_STUB_APPEND:<relpath>:<base64> reads whatever is CURRENTLY there (empty
# if absent) and appends the decoded suffix. If task b's worktree does not
# contain task a's committed content, the append reads nothing and the final
# file is just the suffix - proving the earlier work was lost, not merged.
base_b64="$(printf '%s' 'A-BASE' | base64)"
suffix_b64="$(printf '%s' '-B-EXTRA' | base64)"

mkdir -p "${PROJECT_DIR}/.orch"
cat > "${PROJECT_DIR}/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","prompt":"write the base file\nFA_STUB_WRITE:shared.txt:${base_b64}",
   "deps":[],"files":["shared.txt"],"category":"coding"},
  {"id":"b","prompt":"extend the base file\nFA_STUB_APPEND:shared.txt:${suffix_b64}",
   "deps":["a"],"files":["shared.txt"],"category":"coding"}
]}
EOF

ORCH_PROJECT="$PROJECT_DIR" timeout 120 "$REPO/bin/orch.sh" \
  run "${PROJECT_DIR}/.orch/tasks.json" --isolate >"${PROJECT_DIR}/out.log" 2>&1
rc=$?

assert_eq "the dependency chain completes" "$rc" "0"

JOURNAL="${PROJECT_DIR}/.orch/journal.ndjson"
done_n="$(jq -r 'select(.event=="done")|.task' "$JOURNAL" 2>/dev/null | sort -u | wc -l)"
assert_eq "both tasks reach done" "$done_n" "2"

final="$(cat "${PROJECT_DIR}/shared.txt" 2>/dev/null || echo MISSING)"
assert_eq "b's worktree saw a's merged content - nothing was reverted" \
  "$final" "A-BASE-B-EXTRA"

commit_count="$(git -C "$PROJECT_DIR" log --oneline | wc -l)"
assert_true "both tasks produced a real commit (got ${commit_count}, want >=3: init+a+b)" \
  '[[ $commit_count -ge 3 ]]'
assert_contains "task a's commit is in the log" \
  "$(git -C "$PROJECT_DIR" log --format=%s)" "fa: a"
assert_contains "task b's commit is in the log" \
  "$(git -C "$PROJECT_DIR" log --format=%s)" "fa: b"

wt_count="$(git -C "$PROJECT_DIR" worktree list | wc -l)"
assert_eq "no worktrees were left behind" "$wt_count" "1"
assert_not_contains "throwaway task branches were cleaned up" \
  "$(git -C "$PROJECT_DIR" branch)" "fa-task-"

# --- 2. two INDEPENDENT isolated tasks (no deps, disjoint files) running
# concurrently must not lose either commit under the merge lock ------------
PROJECT2="$(mktemp -d)"
git -C "$PROJECT2" init -q
git -C "$PROJECT2" config user.email test@test.test
git -C "$PROJECT2" config user.name test
git -C "$PROJECT2" commit --allow-empty -q -m init

x_b64="$(printf '%s' 'X-CONTENT' | base64)"
y_b64="$(printf '%s' 'Y-CONTENT' | base64)"
mkdir -p "${PROJECT2}/.orch"
cat > "${PROJECT2}/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"x","prompt":"write x\nFA_STUB_WRITE:x.txt:${x_b64}",
   "deps":[],"files":["x.txt"],"category":"coding"},
  {"id":"y","prompt":"write y\nFA_STUB_WRITE:y.txt:${y_b64}",
   "deps":[],"files":["y.txt"],"category":"coding"}
]}
EOF

ORCH_PROJECT="$PROJECT2" timeout 120 "$REPO/bin/orch.sh" \
  run "${PROJECT2}/.orch/tasks.json" --isolate --max-parallel 2 \
  >"${PROJECT2}/out.log" 2>&1
rc2=$?
assert_eq "two independent isolated tasks both complete" "$rc2" "0"
assert_eq "x.txt has its own content" "$(cat "${PROJECT2}/x.txt" 2>/dev/null)" "X-CONTENT"
assert_eq "y.txt has its own content" "$(cat "${PROJECT2}/y.txt" 2>/dev/null)" "Y-CONTENT"
commit_count2="$(git -C "$PROJECT2" log --oneline | wc -l)"
assert_true "neither commit was lost under the merge lock (got ${commit_count2}, want >=3: init+x+y)" \
  '[[ $commit_count2 -ge 3 ]]'

rm -rf "$PROJECT2"
rm -rf "$PROJECT_DIR"
end_suite
final_report
