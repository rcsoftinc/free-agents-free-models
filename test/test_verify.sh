#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"          # ALWAYS call the engine via "$REPO/bin/..."
source "$HERE/harness.sh"
begin_suite "verify, do not trust"
fixture_registry 3 || exit 1
sandbox_on

# Work inside a temp project, exactly like the resume test.
PROJ="$(mktemp -d)"
rm -rf "$PROJ/.orch"
mkdir -p "$PROJ/.orch"

# Two tasks:
#   fail_task   - declares never_created.txt. The stub agents never create files,
#                 so dispatch succeeds (rc 0) but VERIFICATION must catch it.
#   success_task - declares no files. Dispatch success must reach done, proving
#                 the failure came from verification, not from dispatch.
cat > "$PROJ/.orch/tasks.json" <<'EOF'
{
  "tasks": [
    {"id": "fail_task",   "prompt": "task needing never_created.txt", "deps": [], "files": ["never_created.txt"]},
    {"id": "success_task", "prompt": "task needing no files",            "deps": [], "files": []}
  ]
}
EOF

# TASK_RETRIES=0: a verification failure must be terminal on the first attempt,
# not retried. The exit code is captured OUTSIDE the subshell so it survives.
(
  cd "$PROJ"
  export TASK_RETRIES=0
  "$REPO/bin/orch.sh" run .orch/tasks.json >/tmp/orch_verify.out 2>/tmp/orch_verify.err
)
RUN_EXIT=$?

# A task that claims success without producing its declared files must FAIL the run.
assert_eq "orch.sh exits 1 when a declared file is never created" "$RUN_EXIT" "1"

JOURNAL="$PROJ/.orch/journal.ndjson"

# Verification ran and reported the missing file.
UNVERIFIED_COUNT=$(jq -s 'map(select(.event=="unverified" and .task=="fail_task")) | length' "$JOURNAL")
assert_eq "fail_task has exactly 1 unverified event" "$UNVERIFIED_COUNT" "1"

# The task is then marked failed (no retry budget left).
FAILED_COUNT=$(jq -s 'map(select(.event=="failed" and .task=="fail_task")) | length' "$JOURNAL")
assert_eq "fail_task has exactly 1 failed event" "$FAILED_COUNT" "1"

# A claimed-success-with-no-work must NEVER be recorded as done.
DONE_COUNT=$(jq -s 'map(select(.event=="done" and .task=="fail_task")) | length' "$JOURNAL")
assert_eq "fail_task has 0 done events (verification failed)" "$DONE_COUNT" "0"

# success_task: files:[] means there is nothing to verify, so dispatch success
# must reach done. This is what proves the failure was verification, not dispatch.
SUCCESS_DONE_COUNT=$(jq -s 'map(select(.event=="done" and .task=="success_task")) | length' "$JOURNAL")
assert_eq "success_task has exactly 1 done event (no files to verify)" "$SUCCESS_DONE_COUNT" "1"

# Cleanup: temp project and captured output, nothing left in the repo root.
rm -rf "$PROJ"
rm -f /tmp/orch_verify.out /tmp/orch_verify.err

end_suite
final_report