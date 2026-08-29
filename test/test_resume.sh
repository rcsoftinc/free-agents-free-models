#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"          # ALWAYS call the engine via "$REPO/bin/..."
source "$HERE/harness.sh"
begin_suite "journal replay and resume"
fixture_registry 3 || exit 1
sandbox_on

# Create a temporary project directory
PROJ="$(mktemp -d)"
rm -rf "$PROJ/.orch"
mkdir -p "$PROJ/.orch"

# Write tasks.json with three tasks: a, b (no deps) and c (deps a,b)
cat > "$PROJ/.orch/tasks.json" <<'EOF'
{
  "tasks": [
    {"id": "a", "prompt": "task a", "deps": [], "files": []},
    {"id": "b", "prompt": "task b", "deps": [], "files": []},
    {"id": "c", "prompt": "task c", "deps": ["a", "b"], "files": []}
  ]
}
EOF

# First run
( cd "$PROJ" && "$REPO/bin/orch.sh" run .orch/tasks.json )
RUN1_EXIT=$?
assert_eq "First run should exit 0" "$RUN1_EXIT" "0"

# Count done and started events in journal
DONE_BEFORE=$(jq -r 'select(.event=="done") | .task' "$PROJ/.orch/journal.ndjson" | wc -l || echo 0)
STARTED_BEFORE=$(jq -r 'select(.event=="started") | .task' "$PROJ/.orch/journal.ndjson" | wc -l || echo 0)

assert_eq "Should have 3 done events" "$DONE_BEFORE" "3"
assert_eq "Should have 3 started events" "$STARTED_BEFORE" "3"

# Record line numbers for dependency order verification
# Get line numbers of done events
echo "=== Checking dependency order ==="
pos_a=$(jq -r 'select(.event=="done" and .task=="a") | .ts' "$PROJ/.orch/journal.ndjson" 2>/dev/null || echo "")
pos_b=$(jq -r 'select(.event=="done" and .task=="b") | .ts' "$PROJ/.orch/journal.ndjson" 2>/dev/null || echo "")
pos_c=$(jq -r 'select(.event=="done" and .task=="c") | .ts' "$PROJ/.orch/journal.ndjson" 2>/dev/null || echo "")

# Check that c's done line appears after both a's and b's (dependency order)
if [[ -n "$pos_a" && -n "$pos_b" && -n "$pos_c" ]]; then
  # Convert to epoch seconds for comparison
  # Note: .ts is in format YYYY-MM-DDTHH:MM:SSZ, but we can use grep with line numbers
  # and grep -n returns line numbers
  LINE_A=$(grep -n '"done".*"a"' "$PROJ/.orch/journal.ndjson" | head -1 | cut -d: -f1)
  LINE_B=$(grep -n '"done".*"b"' "$PROJ/.orch/journal.ndjson" | head -1 | cut -d: -f1)
  LINE_C=$(grep -n '"done".*"c"' "$PROJ/.orch/journal.ndjson" | head -1 | cut -d: -f1)

  assert_true "c after a" '[[ $LINE_C -gt $LINE_A ]]'
  assert_true "c after b" '[[ $LINE_C -gt $LINE_B ]]'
else
  fail "Could not extract timestamps for dependency check"
fi

# Second run (resume) - should not re-run any tasks
( cd "$PROJ" && "$REPO/bin/orch.sh" resume )
RUN2_EXIT=$?
assert_eq "Resume run should exit 0" "$RUN2_EXIT" "0"

# Count done and started events after resume
DONE_AFTER=$(jq -r 'select(.event=="done") | .task' "$PROJ/.orch/journal.ndjson" | wc -l || echo 0)
STARTED_AFTER=$(jq -r 'select(.event=="started") | .task' "$PROJ/.orch/journal.ndjson" | wc -l || echo 0)

# Tasks should not start again during resume
assert_eq "Done events should not increase" "$DONE_AFTER" "$DONE_BEFORE"
assert_eq "Started events should not increase" "$STARTED_AFTER" "$STARTED_BEFORE"

# Cleanup
rm -rf "$PROJ"

echo "=== All resume tests passed ==="
end_suite
final_report