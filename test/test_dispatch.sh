#!/usr/bin/env bash
# test_dispatch.sh - `fa dispatch`/`fa go`: the orchestrate-vs-direct gate as
# real, enforced code instead of prose a coordinator LLM computes in its
# head. `fa go` used to call orch.sh unconditionally regardless of whether
# the plan actually had anything worth splitting - nothing checked
# AGENTS.md's own documented gate before dispatching.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "fa dispatch: the split gate as real code"
sandbox_on

mkproj() { local p; p="$(mktemp -d)"; printf '# demo\n' > "$p/README.md"; printf '%s' "$p"; }

# ---------------------------------------------------------------- Test 1
echo "=== Test 1: a single task -> DIRECT, orch.sh never runs ==="
fixture_registry 3 || exit 1
P="$(mkproj)"
clear_modes; mode_for opencode planprose; mode_for kilo planprose; mode_for hermes planprose
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" dispatch "build the thing" 2>&1)"
rc=$?
assert_eq "exits 0" "$rc" "0"
assert_contains "SPLIT EVALUATION line is printed" "$out" "SPLIT EVALUATION"
assert_contains "decision is DIRECT" "$out" "-> DIRECT"
assert_contains "tells the coordinator to do the work itself" "$out" "do the work yourself"
assert_not_contains "orch.sh never actually dispatched anything" "$out" "dispatch "
assert_not_contains "no journal was ever created (orch.sh never ran)" \
  "$([[ -f "$P/.orch/journal.ndjson" ]] && echo present || echo absent)" "present"
rm -rf "$P"

# ---------------------------------------------------------------- Test 2
echo "=== Test 2: a strict 2-task chain (no parallelizable pair) -> DIRECT ==="
P="$(mkproj)"
clear_modes; mode_for opencode plan; mode_for kilo plan; mode_for hermes plan
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" dispatch "build the thing" 2>&1)"
rc=$?
assert_eq "exits 0" "$rc" "0"
assert_contains "disjoint_pair is reported false" "$out" "disjoint_pair=false"
assert_contains "decision is DIRECT" "$out" "-> DIRECT"
rm -rf "$P"

# ---------------------------------------------------------------- Test 3
echo "=== Test 3: two independent tasks but only 1 lane -> DIRECT ==="
fixture_registry 1 || exit 1
P="$(mkproj)"
clear_modes; mode_for opencode planparallel; mode_for kilo planparallel; mode_for hermes planparallel
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" dispatch "build the thing" 2>&1)"
rc=$?
assert_eq "exits 0" "$rc" "0"
assert_contains "disjoint_pair is reported true" "$out" "disjoint_pair=true"
assert_contains "lanes is reported as 1" "$out" "lanes=1"
assert_contains "decision is still DIRECT (not enough lanes)" "$out" "-> DIRECT"
rm -rf "$P"

# ---------------------------------------------------------------- Test 4
echo "=== Test 4: two independent tasks + 2+ lanes -> ORCHESTRATE, and it actually runs ==="
fixture_registry 3 || exit 1
P="$(mkproj)"
clear_modes; mode_for opencode planparallel; mode_for kilo planparallel; mode_for hermes planparallel
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" dispatch "build the thing" 2>&1)"
rc=$?
assert_eq "exits 0" "$rc" "0"
assert_contains "disjoint_pair is reported true" "$out" "disjoint_pair=true"
assert_contains "decision is ORCHESTRATE" "$out" "-> ORCHESTRATE"
assert_contains "the trivial-tasks hint fires (batch would suit this better, not built)" \
  "$out" "batch dispatch"
assert_true "orch.sh actually ran and completed both tasks" \
  '[[ -f "$P/.orch/journal.ndjson" && $(jq -s "map(select(.event==\"done\")) | length" "$P/.orch/journal.ndjson") -eq 2 ]]'
rm -rf "$P"

# ---------------------------------------------------------------- Test 5
echo "=== Test 5: fa go is a thin alias for fa dispatch ==="
fixture_registry 3 || exit 1
P="$(mkproj)"
clear_modes; mode_for opencode planprose; mode_for kilo planprose; mode_for hermes planprose
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" go "build the thing" 2>&1)"
assert_eq "fa go exits 0 the same way" "$?" "0"
assert_contains "fa go also prints the SPLIT EVALUATION" "$out" "SPLIT EVALUATION"
rm -rf "$P"

# ---------------------------------------------------------------- Test 6
# The mode a coordinator actually wants: it already wrote tasks.json itself
# (AGENTS.md's own Phase 1), in its own already-loaded context - fa dispatch
# with no goal must evaluate that directly, never pay for a cold plan.sh
# re-derivation of a project the coordinator already understands.
echo "=== Test 6: no goal -> evaluates an already hand-written tasks.json ==="
fixture_registry 3 || exit 1
P="$(mkproj)"; mkdir -p "$P/.orch"
cat > "$P/.orch/tasks.json" <<'EOF'
{"tasks":[
  {"id":"x","prompt":"do x","deps":[],"files":[],"category":"coding"},
  {"id":"y","prompt":"do y","deps":[],"files":[],"category":"coding"}
]}
EOF
clear_modes
out="$(cd "$P" && timeout 90 "$REPO/bin/fa" dispatch 2>&1)"
rc=$?
assert_eq "exits 0" "$rc" "0"
assert_contains "evaluates the hand-written plan without re-planning" "$out" "SPLIT EVALUATION"
assert_contains "decision is ORCHESTRATE (2 independent tasks, 3 lanes)" "$out" "-> ORCHESTRATE"
assert_true "orch.sh actually ran it" \
  '[[ -f "$P/.orch/journal.ndjson" && $(jq -s "map(select(.event==\"done\")) | length" "$P/.orch/journal.ndjson") -eq 2 ]]'
rm -rf "$P"

# ---------------------------------------------------------------- Test 7
echo "=== Test 7: no goal AND no existing plan -> a clear error, not a crash ==="
P="$(mkproj)"
out="$(cd "$P" && timeout 20 "$REPO/bin/fa" dispatch 2>&1)"
rc=$?
assert_eq "exits 3 (setup error)" "$rc" "3"
assert_contains "names the problem" "$out" "no goal given and no plan"
rm -rf "$P"

clear_modes
end_suite
final_report
