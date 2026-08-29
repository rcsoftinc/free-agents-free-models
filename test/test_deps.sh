#!/usr/bin/env bash
# Proves bin/orch.sh handles dependency edge cases without hanging, and reports
# WHY it stopped. A scheduler that stalls silently is worse than one that fails:
# the journal is the only record, so it has to say what happened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "orch.sh dependency edge cases"
fixture_registry 3 || exit 1
sandbox_on
clear_modes

# A task with files:[] always verifies; one declaring a file the stubs never
# create always fails verification. That gives deterministic pass/fail without
# depending on stub modes.
mkproj() { # $1 = tasks json
  local p; p="$(mktemp -d)"; mkdir -p "$p/.orch"
  printf '%s' "$1" > "$p/.orch/tasks.json"; printf '%s' "$p"
}
run_orch() { # $1 = project dir ; echoes exit code
  local rc=0
  ( cd "$1" && TASK_RETRIES=0 timeout 90 "$REPO/bin/orch.sh" run .orch/tasks.json ) \
    >"$1/out.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}
ev() { jq -r --arg e "$2" --arg t "$3" \
        'select(.event==$e and .task==$t) | .task' "$1/.orch/journal.ndjson" 2>/dev/null | head -1; }
# NOTE: `grep -c` prints 0 AND exits 1 when there are no matches, so `|| echo 0`
# would emit a second line. Swallow the status instead of adding output.
started() { local f="$1/.orch/journal.ndjson"
  [[ -f "$f" ]] || { printf '0'; return; }
  grep -c "\"event\":\"started\",\"task\":\"$2\"" "$f" 2>/dev/null || true; }

# --- 1. a cycle must terminate, not hang ------------------------------------
P="$(mkproj '{"tasks":[
  {"id":"a","prompt":"x","deps":["b"],"files":[]},
  {"id":"b","prompt":"y","deps":["a"],"files":[]}]}')"
rc="$(run_orch "$P")"
assert_ne "a dependency cycle does not exit 0" "$rc" "0"
assert_ne "a cycle does not hang until the timeout (124)" "$rc" "124"
assert_contains "it says why it stopped" "$(cat "$P/out.log")" "deadlock"
# The journal is meant to be the only record of a run. A stall that leaves it
# empty tells a later reader nothing about why nothing happened.
assert_true "the deadlock is recorded in the journal" \
            '[[ -s "$P/.orch/journal.ndjson" ]] && grep -q deadlock "$P/.orch/journal.ndjson"'
assert_contains "the journal names the blocked tasks" \
            "$(cat "$P/.orch/journal.ndjson" 2>/dev/null)" "blocked"
# status must not describe a permanently blocked task as merely "pending".
st="$( cd "$P" && timeout 30 "$REPO/bin/orch.sh" status 2>&1 )"
assert_contains "status reports the run as blocked" "$st" "BLOCKED"
assert_eq "no task in a cycle is ever started" "$(started "$P" a)" "0"

# --- 2. a task blocked behind a FAILED dependency must not run --------------
P="$(mkproj '{"tasks":[
  {"id":"broken","prompt":"x","deps":[],"files":["never_created.txt"]},
  {"id":"dependent","prompt":"y","deps":["broken"],"files":[]},
  {"id":"unrelated","prompt":"z","deps":[],"files":[]}]}')"
rc="$(run_orch "$P")"
assert_ne "a failed dependency makes the run fail" "$rc" "0"
assert_eq "the failing task is journaled failed" "$(ev "$P" failed broken)" "broken"
assert_eq "its dependent never starts" "$(started "$P" dependent)" "0"
assert_eq "an unrelated task still completes" "$(ev "$P" done unrelated)" "unrelated"

# --- 3. a diamond runs in dependency order ----------------------------------
P="$(mkproj '{"tasks":[
  {"id":"top","prompt":"x","deps":[],"files":[]},
  {"id":"left","prompt":"y","deps":["top"],"files":[]},
  {"id":"right","prompt":"z","deps":["top"],"files":[]},
  {"id":"bottom","prompt":"w","deps":["left","right"],"files":[]}]}')"
rc="$(run_orch "$P")"
assert_eq "a diamond completes" "$rc" "0"
J="$P/.orch/journal.ndjson"
line_of() { grep -n "\"event\":\"done\",\"task\":\"$1\"" "$J" | head -1 | cut -d: -f1; }
assert_true "top finishes before left"   '[[ $(line_of top) -lt $(line_of left) ]]'
assert_true "top finishes before right"  '[[ $(line_of top) -lt $(line_of right) ]]'
assert_true "bottom finishes after left" '[[ $(line_of bottom) -gt $(line_of left) ]]'
assert_true "bottom finishes after right" '[[ $(line_of bottom) -gt $(line_of right) ]]'

# --- 4. a dependency on a task that does not exist --------------------------
# This is a plan authoring error. It must be reported, not waited on forever.
P="$(mkproj '{"tasks":[
  {"id":"orphan","prompt":"x","deps":["nosuchtask"],"files":[]},
  {"id":"fine","prompt":"y","deps":[],"files":[]}]}')"
rc="$(run_orch "$P")"
assert_ne "an unknown dependency id does not exit 0" "$rc" "0"
assert_ne "and does not hang (124)" "$rc" "124"
assert_eq "the runnable task still completes" "$(ev "$P" done fine)" "fine"
assert_eq "the orphaned task never starts" "$(started "$P" orphan)" "0"

# --- 5. a self-dependency is a cycle of one ---------------------------------
P="$(mkproj '{"tasks":[{"id":"selfdep","prompt":"x","deps":["selfdep"],"files":[]}]}')"
rc="$(run_orch "$P")"
assert_ne "a self-dependency does not exit 0" "$rc" "0"
assert_ne "and does not hang (124)" "$rc" "124"
assert_eq "it never starts" "$(started "$P" selfdep)" "0"

end_suite
final_report
