#!/usr/bin/env bash
# test_when.sh - the "when" conditional-edge graph primitive: a task can
# declare {"when":{"dep":"<id>","path":"<jq path>","equals":"<value>"}} to
# run only if a completed dependency's captured result matches. Unsatisfied
# means SKIPPED (terminal, like done/failed, but neither) - not a failure,
# and not a silent hang for anything downstream that depends on it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "the \"when\" conditional edge"
sandbox_on

mkproj() { local p; p="$(mktemp -d)"; mkdir -p "$p/.orch"; printf '%s' "$p"; }
run_orch() { ( cd "$1" && TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run .orch/tasks.json ) >"$1/out.log" 2>&1; printf '%s' "$?"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

YES="$(b64 '{"decision":"yes"}')"
NO="$(b64 '{"decision":"no"}')"
BAD="$(b64 'not-json')"

# ---------------------------------------------------------------- Test 1
echo "=== Test 1: a satisfied when clause runs the task normally ==="
fixture_registry 3 || exit 1; clear_modes
P="$(mkproj)"
cat > "$P/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","deps":[],"files":[],"prompt":"decide\nFA_STUB_RESULT:${YES}"},
  {"id":"b","deps":["a"],"files":[],"prompt":"do b",
   "when":{"dep":"a","path":".decision","equals":"yes"}}
]}
EOF
rc="$(run_orch "$P")"
assert_eq "the run completes" "$rc" "0"
assert_contains "b actually ran" "$(cat "$P/.orch/journal.ndjson")" '"event":"done","task":"b"'
assert_not_contains "b was not skipped" "$(cat "$P/.orch/journal.ndjson")" '"event":"skipped"'
rm -rf "$P"

# ---------------------------------------------------------------- Test 2
echo "=== Test 2: an unsatisfied when clause skips the task, not a failure ==="
fixture_registry 3 || exit 1; clear_modes
P="$(mkproj)"
cat > "$P/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","deps":[],"files":[],"prompt":"decide\nFA_STUB_RESULT:${NO}"},
  {"id":"b","deps":["a"],"files":[],"prompt":"do b",
   "when":{"dep":"a","path":".decision","equals":"yes"}}
]}
EOF
rc="$(run_orch "$P")"
assert_eq "the run still completes - skipping is not a failure" "$rc" "0"
assert_contains "b was skipped, journaled" "$(cat "$P/.orch/journal.ndjson")" '"event":"skipped","task":"b"'
assert_not_contains "b was never actually dispatched" "$(cat "$P/.orch/journal.ndjson")" '"event":"started","task":"b"'
assert_contains "fa status reports it as skipped" "$(cd "$P" && "$REPO/bin/orch.sh" status)" "SKIPPED b"
rm -rf "$P"

# ---------------------------------------------------------------- Test 3
echo "=== Test 3: a task depending on a SKIPPED task is not stuck forever ==="
fixture_registry 3 || exit 1; clear_modes
P="$(mkproj)"
cat > "$P/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","deps":[],"files":[],"prompt":"decide\nFA_STUB_RESULT:${NO}"},
  {"id":"b","deps":["a"],"files":[],"prompt":"do b",
   "when":{"dep":"a","path":".decision","equals":"yes"}},
  {"id":"c","deps":["b"],"files":[],"prompt":"do c"}
]}
EOF
rc="$(run_orch "$P")"
assert_eq "the run completes" "$rc" "0"
assert_contains "b was skipped" "$(cat "$P/.orch/journal.ndjson")" '"event":"skipped","task":"b"'
assert_contains "c still ran - a skipped dependency resolved it, not blocked it" \
  "$(cat "$P/.orch/journal.ndjson")" '"event":"done","task":"c"'
rm -rf "$P"

# ---------------------------------------------------------------- Test 4
echo "=== Test 4: a dependency that reports no result at all -> when evaluates false ==="
fixture_registry 3 || exit 1; clear_modes
P="$(mkproj)"
cat > "$P/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","deps":[],"files":[],"prompt":"decide, no result line at all"},
  {"id":"b","deps":["a"],"files":[],"prompt":"do b",
   "when":{"dep":"a","path":".decision","equals":"yes"}}
]}
EOF
rc="$(run_orch "$P")"
assert_eq "the run completes" "$rc" "0"
assert_contains "b was skipped (missing result degrades to {}, not a crash)" \
  "$(cat "$P/.orch/journal.ndjson")" '"event":"skipped","task":"b"'
rm -rf "$P"

# ---------------------------------------------------------------- Test 5
echo "=== Test 5: a malformed result: line is recorded as a finding, not a crash ==="
fixture_registry 3 || exit 1; clear_modes
P="$(mkproj)"
cat > "$P/.orch/tasks.json" <<EOF
{"tasks":[
  {"id":"a","deps":[],"files":[],"prompt":"decide badly\nFA_STUB_RESULT:${BAD}"},
  {"id":"b","deps":["a"],"files":[],"prompt":"do b",
   "when":{"dep":"a","path":".decision","equals":"yes"}}
]}
EOF
rc="$(run_orch "$P")"
assert_eq "the run completes" "$rc" "0"
assert_contains "b was skipped (malformed result also degrades to {})" \
  "$(cat "$P/.orch/journal.ndjson")" '"event":"skipped","task":"b"'
assert_contains "a malformed_result finding was recorded" \
  "$("$REPO/bin/fa" findings)" "malformed_result"
rm -rf "$P"

# ---------------------------------------------------------------- Test 6
echo "=== Test 6: plan.sh catches a when.dep referencing an unknown task ==="
fixture_registry 3 || exit 1; clear_modes
mode_for opencode plandangling_when; mode_for kilo plandangling_when; mode_for hermes plandangling_when
P="$(mkproj)"
timeout 60 "$REPO/bin/plan.sh" -w "$P" -o "$P/.orch/tasks.json" --max-tries 1 "build" >/dev/null 2>&1
assert_eq "a plan with a dangling when.dep is rejected" "$?" "2"
assert_true "no tasks.json was written" '[[ ! -s "$P/.orch/tasks.json" ]]'
rm -rf "$P"

# ---------------------------------------------------------------- Test 7
echo "=== Test 7: plan.sh catches a when.dep not also listed in deps ==="
fixture_registry 3 || exit 1; clear_modes
mode_for opencode planwhen_nodep; mode_for kilo planwhen_nodep; mode_for hermes planwhen_nodep
P="$(mkproj)"
timeout 60 "$REPO/bin/plan.sh" -w "$P" -o "$P/.orch/tasks.json" --max-tries 1 "build" >/dev/null 2>&1
assert_eq "a when.dep missing from deps is rejected" "$?" "2"
assert_true "no tasks.json was written" '[[ ! -s "$P/.orch/tasks.json" ]]'
rm -rf "$P"

clear_modes
end_suite
final_report
