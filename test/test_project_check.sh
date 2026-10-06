#!/usr/bin/env bash
# Proves the project's own check (`verify:` in .orch/config.yaml) runs once a
# run's tasks have landed, where they landed; that a failure goes to one
# worker with the check's output, the project's read-only files held and the
# check as that worker's own verify; and that fa status and the exit code say
# how it ended.
#
# Each task's verify proves that task in its own workdir. Two tasks can each
# pass theirs and still break each other once both land, and nothing ran the
# whole project's check after a run before this.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "the project's own check, once a run's tasks land"
fixture_registry 1 || exit 1        # one lane, b0:fp0, reached through opencode
sandbox_on

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE" "$FIXTURE_DIR"' EXIT
# A fake agent that does, in its workdir, what its prompt asks for: DO_A runs
# $FAKE_A, DO_B runs $FAKE_B, and the project check's fixer runs $FAKE_FIX. It
# keeps every prompt it was given.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
p="${@: -1}"; printf '%s' "$p" > "$FAKE_DIR/prompt.$n"
act=""
if [[ "$p" == *"The project's own check fails"* ]]; then
  act="${FAKE_FIX:-}"; echo "$n" >> "$FAKE_DIR/fixer"
else
  for k in A B; do v="FAKE_$k"; [[ "$p" == *"DO_$k"* ]] && act="${!v:-}"; done
fi
( cd "${dir:-.}" && eval "$act" )
printf '{"ok":true,"agent":"opencode","summary":"call %s"}' "$n"
EOF
chmod +x "$FAKE/opencode"
export FAKE_DIR="$FAKE" PATH="$FAKE:$PATH"

# Two tasks that each pass their own check, and the project's check, which
# fails unless both files agree.
project() { # $1 = extra config lines, $2 = git to make it a repository
  P="$(mktemp -d)"; mkdir -p "$P/.orch" "$P/tests"
  cat > "$P/tests/same.sh" <<'EOF'
x="$(cat x.txt)"; y="$(cat y.txt)"
[ "$x" = "$y" ] || { echo "x.txt says $x but y.txt says $y"; exit 1; }
EOF
  printf 'mode: strict\nreadonly: tests/*\n%s\n' "$1" > "$P/.orch/config.yaml"
  jq -n '{tasks:[
    {id:"a", prompt:"DO_A", deps:[], files:["x.txt"], category:"general", verify:"test -s x.txt"},
    {id:"b", prompt:"DO_B", deps:[], files:["y.txt"], category:"general", verify:"test -s y.txt"}]}' \
    > "$P/.orch/tasks.json"
  if [[ "${2:-}" == git ]]; then
    git -C "$P" init -q -b main; git -C "$P" -c user.name=t -c user.email=t@t add -A
    git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
  fi
  rm -f "$FAKE"/calls "$FAKE"/prompt.* "$FAKE"/fixer
}
orch() { # $1 = run | resume -> $rc, $out
  out="$( cd "$P" && FA_VALIDATE_ROUNDS=2 TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" "${1:-run}" </dev/null 2>&1 )"
  rc=$?
}
journal() { cat "$P/.orch/journal.ndjson" 2>/dev/null; }
status() { ( cd "$P" && "$REPO/bin/fa" status 2>&1 ); }
checks() { journal | grep -c '"event":"project_check"'; }
fixers() { grep -c . "$FAKE/fixer" 2>/dev/null || echo 0; }

# --- 1. no check configured: nothing extra happens ---------------------------------
project ""
FAKE_A='echo 1 > x.txt' FAKE_B='echo 1 > y.txt' orch
assert_eq "without verify: the run ends as it always did" "$rc" "0"
assert_eq "  ...and no project check runs" "$(checks)" "0"

# --- 2. it passes --------------------------------------------------------------------
project "verify: bash tests/same.sh"
FAKE_A='echo 1 > x.txt' FAKE_B='echo 1 > y.txt' orch
assert_eq "a passing project check: exit 0" "$rc" "0"
assert_contains "  ...journaled" "$(journal)" '"event":"project_check","task":"-","result":"passed","cmd":"bash tests/same.sh"'
assert_contains "  ...and shown by fa status" "$(status)" 'check   passed  `bash tests/same.sh`'
assert_eq "  ...and no worker was sent" "$(fixers)" "0"

# --- 3. each task passes its own check; together they do not -----------------------
# (a git repository: what a worker changed is git's view, as for undeclared changes)
project "verify: bash tests/same.sh" git
FAKE_A='echo 1 > x.txt' FAKE_B='echo 2 > y.txt' FAKE_FIX='echo 1 > y.txt' orch
assert_contains "both tasks passed their own checks" "$(status)" "done    b"
assert_eq "the project check caught the pair, and one worker fixed it: exit 0" "$rc" "0"
assert_eq "  ...exactly one worker" "$(fixers)" "1"
fp="$(cat "$FAKE/prompt.$(head -1 "$FAKE/fixer")" 2>/dev/null)"
assert_contains "the worker is given the check" "$fp" 'The check: `bash tests/same.sh`'
assert_contains "  ...how it failed" "$fp" "x.txt says 1 but y.txt says 2"
assert_contains "  ...what just landed, with its files" "$fp" "b (y.txt)"
assert_contains "  ...and that the tests are not its to change" "$fp" "any change"
assert_contains "it is journaled as fixed, with what the worker changed" "$(journal)" '"result":"fixed","cmd":"bash tests/same.sh","files":"y.txt"'
assert_contains "  ...and fa status says so" "$(status)" "check   fixed   \`bash tests/same.sh\`  a worker changed: y.txt"
assert_eq "  ...but in place, uncommitted - this run commits nothing of its own" \
  "$(git -C "$P" log --oneline | wc -l | tr -d ' ')" "1"

# --- 4. a worker that cannot fix it ---------------------------------------------------
project "verify: bash tests/same.sh"
FAKE_A='echo 1 > x.txt' FAKE_B='echo 2 > y.txt' FAKE_FIX=':' orch
assert_eq "a project check nobody could fix fails the run (exit 1)" "$rc" "1"
assert_contains "  ...fa status says so, and where the output is" "$(status)" "CHECK FAILED  \`bash tests/same.sh\`  output: .orch/results/_check.log"
assert_contains "  ...which holds the check's own words" "$(cat "$P/.orch/results/_check.log" 2>/dev/null)" "x.txt says 1 but y.txt says 2"

# --- 5. ...nor by changing the check ---------------------------------------------------
project "verify: bash tests/same.sh"
FAKE_A='echo 1 > x.txt' FAKE_B='echo 2 > y.txt' FAKE_FIX='echo "exit 0" > tests/same.sh' orch
assert_eq "a worker that edits the test to pass still fails" "$rc" "1"
assert_contains "  ...the test is put back" "$(cat "$P/tests/same.sh")" "x.txt says"

# --- 6. FA_PROJECT_FIX=0: report only ----------------------------------------------------
project "verify: bash tests/same.sh"
FA_PROJECT_FIX=0 FAKE_A='echo 1 > x.txt' FAKE_B='echo 2 > y.txt' orch
assert_eq "FA_PROJECT_FIX=0 sends no worker" "$(fixers)" "0"
assert_eq "  ...and the run fails" "$rc" "1"

# --- 7. a resume that lands nothing new checks nothing new ----------------------------
project "verify: bash tests/same.sh"
FAKE_A='echo 1 > x.txt' FAKE_B='echo 1 > y.txt' orch
orch resume
assert_eq "a resume with nothing new landed does not re-run the check" "$(checks)" "1"
assert_contains "  ...and says why" "$out" "nothing landed since it last ran"

# --- 8. quoted, the YAML way ----------------------------------------------------------------
project 'verify: "bash tests/same.sh"'
FAKE_A='echo 1 > x.txt' FAKE_B='echo 1 > y.txt' orch
assert_contains "a quoted verify: is the command inside the quotes" "$(journal)" '"result":"passed","cmd":"bash tests/same.sh"'

# --- 9. isolated: the fix is committed, like every merge ----------------------------------
project "verify: bash tests/same.sh"
jq '.tasks[].category = "coding"' "$P/.orch/tasks.json" > "$P/t" && mv "$P/t" "$P/.orch/tasks.json"
printf 'base\n' > "$P/x.txt"; printf 'base\n' > "$P/y.txt"
git -C "$P" init -q -b main; git -C "$P" -c user.name=t -c user.email=t@t add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
out="$( cd "$P" && FAKE_A='echo 1 > x.txt' FAKE_B='echo 2 > y.txt' FAKE_FIX='echo 1 > y.txt' \
        FA_VALIDATE_ROUNDS=2 TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run --isolate </dev/null 2>&1 )"; rc=$?
assert_eq "isolated: the pair is fixed" "$rc" "0"
assert_contains "  ...and the fix is a commit, so a later worktree sees it" \
  "$(git -C "$P" log --format='%an %s' 2>/dev/null)" "free-agents fa: fix the project check"

# --- 10. orch init offers it, empty ------------------------------------------------------------
N="$(mktemp -d)"
( cd "$N" && ORCH_PROJECT="$N" "$REPO/bin/orch.sh" init >/dev/null 2>&1 )
assert_contains "a new project's config has a verify: line, empty until set" "$(grep -x 'verify:' "$N/.orch/config.yaml")" "verify:"
rm -rf "$N"

end_suite
final_report
