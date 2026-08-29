#!/usr/bin/env bash
# Proves bin/plan.sh turns a goal into a usable task graph, and - the point of
# B2 - that planning itself has a fallback chain rather than dying on one bad
# model. A plan that is unusable is THIS MODEL's failure, not the wallet's.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "plan.sh: goal -> task graph, with fallback"
fixture_registry 3 || exit 1
sandbox_on

PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
printf '# Demo\n' > "$PROJ/README.md"
OUT="$PROJ/.orch/tasks.json"

# --- 1. a well-behaved model produces a valid graph -------------------------
clear_modes; mode_for opencode plan; mode_for kilo plan; mode_for hermes plan
timeout 90 "$REPO/bin/plan.sh" -w "$PROJ" -o "$OUT" "build the thing" >/dev/null 2>&1
rc=$?
assert_eq "plan.sh exits 0 on a good plan" "$rc" "0"
assert_true "wrote a task file" '[[ -s "$OUT" ]]'
assert_json_valid "the plan is valid JSON" "$OUT"
assert_eq "task count" "$(jq -r '.tasks | length' "$OUT" 2>/dev/null)" "2"
assert_eq "tasks carry a self-contained prompt" \
          "$(jq -r '[.tasks[] | select((.prompt // "") != "")] | length' "$OUT")" "2"
assert_eq "dependencies survive" "$(jq -r '.tasks[1].deps[0]' "$OUT")" "one"

# --- 2. JSON buried in prose is still extracted -----------------------------
# Small free models wrap valid JSON in commentary and fences. Discarding those
# would waste a lane for no reason.
rm -f "$OUT"
clear_modes; mode_for opencode planprose; mode_for kilo planprose; mode_for hermes planprose
timeout 90 "$REPO/bin/plan.sh" -w "$PROJ" -o "$OUT" "build the thing" >/dev/null 2>&1
assert_eq "a fenced plan wrapped in prose is accepted" "$?" "0"
assert_eq "extracted the embedded graph" "$(jq -r '.tasks[0].id' "$OUT" 2>/dev/null)" "solo"

# --- 3. a model that returns no plan is retried, not fatal ------------------
# One agent answers with prose, the others with a real plan. plan.sh must land
# on a working candidate instead of failing the run.
rm -f "$OUT"
clear_modes; mode_for opencode planbad; mode_for kilo plan; mode_for hermes plan
timeout 120 "$REPO/bin/plan.sh" -w "$PROJ" -o "$OUT" "build the thing" >/dev/null 2>&1
assert_eq "falls back past a model that returns no JSON" "$?" "0"
assert_true "still produced a graph" '[[ -s "$OUT" ]]'

# --- 4. every model failing is a clean failure, not a corrupt file ----------
rm -f "$OUT"
clear_modes; mode_for opencode planbad; mode_for kilo planbad; mode_for hermes planbad
timeout 120 "$REPO/bin/plan.sh" -w "$PROJ" -o "$OUT" --max-tries 2 "build" >/dev/null 2>&1
assert_eq "exits 2 when no model produces a plan" "$?" "2"
assert_true "leaves no half-written task file behind" '[[ ! -s "$OUT" ]]'

# --- 5. a plan violating file boundaries is rejected ------------------------
# Two tasks with no dependency writing the same file would be dispatched
# concurrently. The planner is the cheapest place to catch that.
rm -f "$OUT"
clear_modes; mode_for opencode planconflict; mode_for kilo planconflict; mode_for hermes planconflict
timeout 120 "$REPO/bin/plan.sh" -w "$PROJ" -o "$OUT" --max-tries 2 "build" >/dev/null 2>&1
assert_eq "rejects a plan whose independent tasks share a file" "$?" "2"
assert_true "the conflicting plan is not written" '[[ ! -s "$OUT" ]]'

end_suite
final_report
