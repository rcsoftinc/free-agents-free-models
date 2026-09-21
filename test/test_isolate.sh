#!/usr/bin/env bash
# test_isolate.sh - the auto-isolate heuristic in orch.sh's cmd_run(): only
# turn --isolate on when tasks have GENUINELY disjoint file sets, not merely
# "more than one task declares a files array". A prior version just counted
# tasks regardless of overlap, so a graph where two unrelated tasks share a
# file (or where a dependent pair deliberately shares one, a valid
# plan.sh-permitted pattern) still had isolation silently switched on - the
# precondition for the worktree merge-back bug to silently destroy an
# earlier task's already-merged work.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "auto-isolate: real pairwise disjointness"
fixture_registry 3 || exit 1
sandbox_on

PROJECT_DIR="$(mktemp -d)"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@test.test
git -C "$PROJECT_DIR" config user.name test
git -C "$PROJECT_DIR" commit --allow-empty -q -m init

run_orch() { # $1=tasks.json body -> combined stdout+stderr from --dry-run
  mkdir -p "${PROJECT_DIR}/.orch"
  printf '%s' "$1" > "${PROJECT_DIR}/.orch/tasks.json"
  ORCH_PROJECT="$PROJECT_DIR" timeout 60 "$REPO/bin/orch.sh" \
    run "${PROJECT_DIR}/.orch/tasks.json" --dry-run 2>&1
}

# --- 1. two unrelated tasks sharing a file: must NOT auto-isolate ----------
out="$(run_orch '{"tasks":[
  {"id":"a","prompt":"x","deps":[],"files":["shared.txt"],"category":"coding"},
  {"id":"b","prompt":"y","deps":[],"files":["shared.txt"],"category":"coding"}
]}')"
assert_not_contains "sharing a file does not auto-enable isolation" "$out" "auto-enabled isolation"

# --- 2. two tasks with genuinely disjoint files: SHOULD auto-isolate -------
out="$(run_orch '{"tasks":[
  {"id":"a","prompt":"x","deps":[],"files":["one.txt"],"category":"coding"},
  {"id":"b","prompt":"y","deps":[],"files":["two.txt"],"category":"coding"}
]}')"
assert_contains "genuinely disjoint tasks auto-enable isolation" "$out" "auto-enabled isolation"

# --- 3. a single task alone: never worth isolating --------------------------
out="$(run_orch '{"tasks":[
  {"id":"solo","prompt":"x","deps":[],"files":["one.txt"],"category":"coding"}
]}')"
assert_not_contains "a single task does not auto-enable isolation" "$out" "auto-enabled isolation"

rm -rf "$PROJECT_DIR"
end_suite
final_report
