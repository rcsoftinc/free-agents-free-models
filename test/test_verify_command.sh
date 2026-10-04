#!/usr/bin/env bash
# Proves a task's own verify command is what decides "done" (run.sh --verify; a
# task's "verify" in tasks.json): the command runs in the task's workdir once
# the agent reports success; only exit 0 counts; a failure goes back to the
# SAME agent on the SAME lease with the whole task and the failing output; and
# what the ranking learns is the verified outcome, not the agent's claim.
#
# Before this, "done" meant the declared files exist and changed - plus an
# optional syntax check for JS, Python and shell only. Nothing ran a project's
# own tests, and nothing at all was checked for Kotlin, Java, C# or SQL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "a task's verify command decides when it is done"
fixture_registry 1 || exit 1        # one lane: b0:fp0, reached through opencode
sandbox_on

FAKE="$(mktemp -d)"; WD="$(mktemp -d)"
trap 'rm -rf "$FAKE" "$WD" "$FIXTURE_DIR"' EXIT
# A fake agent that does what a free model does: writes the next word of
# FAKE_SEQ into out.txt each time it is called. It also keeps every prompt it
# was given, and whether its lane's lease was held while it worked.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
IFS=',' read -ra seq <<<"${FAKE_SEQ:-GOOD}"
word="${seq[$((n - 1))]:-${seq[-1]}}"
printf '%s\n' "$word" > "${dir:-.}/out.txt"
printf '%s' "${@: -1}" > "$FAKE_DIR/prompt.$n"
if ( exec 9<>"$FREE_AGENTS_STATE/leases/b0_fp0.lock"; flock -n 9 ) 2>/dev/null
then echo free > "$FAKE_DIR/lease.$n"; else echo held > "$FAKE_DIR/lease.$n"; fi
printf '{"ok":true,"agent":"opencode","summary":"wrote %s"}' "$word"
EOF
chmod +x "$FAKE/opencode"
export FAKE_DIR="$FAKE"
CHECK='grep -qx GOOD out.txt'
TASK="write the word GOOD into out.txt"

run() { # $1=FAKE_SEQ; rest: run.sh options -> leaves $rc, $err
  local seq="$1"; shift
  rm -f "$FAKE"/calls "$FAKE"/prompt.* "$FAKE"/lease.*
  FAKE_SEQ="$seq" PATH="$FAKE:$PATH" "$REPO/bin/run.sh" -w "$WD" -b b0:fp0 "$@" "$TASK" \
    >"$FAKE/out" 2>"$FAKE/err"; rc=$?
  err="$(cat "$FAKE/err")"
}
calls() { cat "$FAKE/calls" 2>/dev/null || echo 0; }
stat() { # $1=jq path under the model -> value
  jq -r ".buckets[\"b0:fp0\"].models[] | select(.upstream == \"m0-a\") | $1" "$FIXTURE_DIR/buckets.json"
}

# --- 1. it passes: one call, and it says so ------------------------------------
ok0="$(stat '.stats.ok // 0')"
run GOOD --verify "$CHECK"
assert_eq "a run whose verify passes exits 0" "$rc" "0"
assert_eq "  ...after a single agent call" "$(calls)" "1"
assert_contains "  ...and says it was verified" "$err" "verified: $CHECK"
assert_contains "  ...in its run record too" "$err" '"verify":"passed"'
assert_eq "  ...and the model is credited once, after the check" "$(stat '.stats.ok // 0')" "$((ok0 + 1))"

# --- 2. it fails, a fix round fixes it ----------------------------------------------
run BAD,GOOD --verify "$CHECK"
assert_eq "a failed verify is sent back, and the fix passes: exit 0" "$rc" "0"
assert_eq "  ...after exactly one fix round" "$(calls)" "2"
assert_contains "  ...which the run record counts" "$err" '"fix_rounds":1'
p2="$(cat "$FAKE/prompt.2" 2>/dev/null)"
assert_contains "the fix round names the check that failed" "$p2" "did not pass its verify command, \`$CHECK\`"
assert_contains "  ...and how it failed" "$p2" "exit 1"
assert_contains "  ...and gets the WHOLE task again - a fix round starts cold" "$p2" "The task:"
assert_contains "  ...the task itself" "$p2" "$TASK"
assert_contains "  ...as a worker, in its workdir" "$p2" "Your working directory is $WD"
assert_contains "  ...told not to cheat its way past the check" "$p2" "Do not weaken, skip or delete the checks"
assert_eq "the first attempt ran under its lane's lease" "$(cat "$FAKE/lease.1" 2>/dev/null)" "held"
assert_eq "and so did the fix round - no other task can take the lane mid-fix" "$(cat "$FAKE/lease.2" 2>/dev/null)" "held"

# --- 3. it never passes ------------------------------------------------------------
fail0="$(stat '.stats.fail // 0')"; probe0="$(stat '.probe.state')"
run BAD,BAD,BAD --verify "$CHECK" --validate-rounds 2
assert_eq "a verify that never passes fails the run (exit 1)" "$rc" "1"
assert_eq "  ...after its rounds: 2 checks, 1 fix round" "$(calls)" "2"
assert_contains "  ...saying so" "$err" "verify FAILED after 2 round(s): $CHECK"
assert_contains "  ...with a marker the orchestrator journals" "$err" "---VERIFY-FAILED---"
assert_contains "  ...and a run record that says unverified" "$err" '"state":"unverified"'
assert_eq "the model is ranked down for it" "$(stat '.stats.fail // 0')" "$((fail0 + 1))"
assert_eq "  ...for this category" "$(stat '.cat_stats.general.fail')" "1"
assert_eq "but not marked dead - it answered; its work failed" "$(stat '.probe.state')" "$probe0"
assert_eq "  ...nor parked in a cooldown" "$(stat '.cooldown_until // 0')" "0"
assert_eq "and the wallet stays healthy" \
  "$(jq -r '.buckets["b0:fp0"].health.state' "$FIXTURE_DIR/buckets.json")" "ok"

# --- 4. where and how long it runs ------------------------------------------------
run GOOD --verify "test \"\$(pwd -P)\" = \"$(cd "$WD" && pwd -P)\""
assert_eq "the verify command runs in the task's workdir" "$rc" "0"
FA_VERIFY_TIMEOUT=1 run BAD,GOOD --verify 'sleep 5'
assert_contains "a verify that hangs is cut off and says so" "$(cat "$FAKE/prompt.2" 2>/dev/null)" "(timed out after 1s)"
run GOOD --verify 'echo it ran > verify-ran.txt'
assert_true "no verify given, no verify run (and with one, it does run)" '[[ -f "$WD/verify-ran.txt" ]]'
rm -f "$WD/verify-ran.txt"
run GOOD
assert_not_contains "without --verify the run record carries no verdict" "$err" '"verify":"passed"'

# --- 5. through fa and the orchestrator -----------------------------------------------
out="$(cd "$WD" && FAKE_SEQ=GOOD PATH="$FAKE:$PATH" "$REPO/bin/fa" run --verify 'true' -b b0:fp0 "x" 2>&1)"; rc=$?
assert_eq "fa run --verify passes it through" "$rc" "0"
assert_contains "  ...and verifies" "$out" "verified: true"

orch() { # $1=verify command for the one task -> runs it, leaves $PROJ
  PROJ="$(mktemp -d)"; mkdir -p "$PROJ/.orch"
  jq -n --arg v "$1" --arg t "$TASK" \
    '{tasks:[{id:"word", prompt:$t, deps:[], files:["out.txt"], category:"general", verify:$v}]}' \
    > "$PROJ/.orch/tasks.json"
  rm -f "$FAKE/calls"
  ( cd "$PROJ" && FAKE_SEQ="${2:-GOOD}" FA_VALIDATE_ROUNDS=2 TASK_RETRIES=0 PATH="$FAKE:$PATH" \
      timeout 120 "$REPO/bin/orch.sh" run </dev/null >/dev/null 2>&1 )
}
orch "$CHECK" GOOD
assert_contains "orch passes a task's verify and records it verified" \
  "$(cat "$PROJ/.orch/journal.ndjson")" '"event":"done","task":"word".*"verified":"yes"'
assert_contains "  ...which fa status shows" "$(cd "$PROJ" && "$REPO/bin/fa" status 2>&1)" "done    word.*(verified)"
rm -rf "$PROJ"
orch "$CHECK" BAD,BAD
assert_contains "a task whose verify never passes is journaled verify_failed" \
  "$(cat "$PROJ/.orch/journal.ndjson")" '"event":"verify_failed","task":"word","cmd":"grep -qx GOOD out.txt"'
assert_contains "  ...and fa status shows the command, to run by hand" \
  "$(cd "$PROJ" && "$REPO/bin/fa" status 2>&1)" "VERIFY FAILED  word  \`$CHECK\`"
rm -rf "$PROJ"

end_suite
final_report
