#!/usr/bin/env bash
# Proves mode: push. A run's work goes onto a new branch in its own worktree -
# the working directory it was started from is never switched or touched -
# with every task's declared files committed; the branch is pushed and a pull
# request opened; fa waits for the checks GitHub reports and sends each
# failure, with its log, to a worker, a bounded number of times; and
# `automerge: true` merges only work something checked. `fa resume` continues
# the branch; a new run starts a new one.
#
# Offline: origin is a bare repository in a temp dir, and gh is the stub in
# test/stubs/ - its pull requests, merges and CI results are scripted
# (GH_STUB_CI), never real.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "push mode: a branch, a pull request, and what CI says"
fixture_registry 1 || exit 1        # one lane, b0:fp0, reached through opencode
sandbox_on

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE" "$FIXTURE_DIR"' EXIT
# A fake agent that does, in its workdir, what its prompt asks: DO_A runs
# $FAKE_A (B, C likewise), the project check's fixer runs $FAKE_FIX, and CI's
# fixer runs $FAKE_CIFIX. It keeps every prompt it was given.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
p="${@: -1}"; printf '%s' "$p" > "$FAKE_DIR/prompt.$n"
act=""
if [[ "$p" == *"CI fails on this branch"* ]]; then
  act="${FAKE_CIFIX:-}"; echo "$n" >> "$FAKE_DIR/cifixer"
elif [[ "$p" == *"The project's own check fails"* ]]; then
  act="${FAKE_FIX:-}"
else
  for k in A B C; do v="FAKE_$k"; [[ "$p" == *"DO_$k"* ]] && act="${!v:-}"; done
fi
( cd "${dir:-.}" && eval "$act" )
printf '{"ok":true,"agent":"opencode","summary":"call %s"}' "$n"
EOF
chmod +x "$FAKE/opencode"
export FAKE_DIR="$FAKE" PATH="$FAKE:$PATH" FA_CI_POLL=0.1
CI_YML=$'name: ci\non: [pull_request]\n'

# A project on main with a bare origin, pushed. $1 = extra config lines,
# $2 = tasks (JSON array), $3 = noci for a project without a CI workflow.
project() {
  R="$(mktemp -d)"; git init -q --bare -b main "$R/origin.git"
  P="$(mktemp -d)"; mkdir -p "$P/.orch" "$P/.github/workflows" "$P/src"; : > "$P/src/.keep"
  [[ "${3:-}" == noci ]] || printf '%s' "$CI_YML" > "$P/.github/workflows/ci.yml"
  printf 'mode: push\nreadonly: tests/* .github/*\n%s\n' "$1" > "$P/.orch/config.yaml"
  local one='[{"id":"a","prompt":"DO_A","deps":[],"files":["src/a.txt"],"category":"general"}]'
  jq -n --argjson t "${2:-$one}" '{tasks: $t}' > "$P/.orch/tasks.json"
  git -C "$P" init -q -b main
  git -C "$P" -c user.name=t -c user.email=t@t add -A
  git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$P" remote add origin "$R/origin.git"
  git -C "$P" push -q origin main
  START="$(git -C "$P" rev-parse HEAD)"
  export GH_STUB_DIR; GH_STUB_DIR="$(mktemp -d)"
  rm -f "$FAKE"/calls "$FAKE"/prompt.* "$FAKE"/cifixer
}
orch() { # $@ = orch.sh arguments -> $rc, $out
  out="$( cd "$P" && FA_VALIDATE_ROUNDS=2 TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" "$@" </dev/null 2>&1 )"
  rc=$?
}
journal() { cat "$P/.orch/journal.ndjson" 2>/dev/null; }
status() { ( cd "$P" && "$REPO/bin/fa" status 2>&1 ); }
branches() { git -C "$R/origin.git" for-each-ref --format='%(refname:short)' refs/heads/fa/; }
ghlog() { cat "$GH_STUB_DIR/log" 2>/dev/null; }
on_branch() { git -C "$R/origin.git" show "$(branches | tail -1):$1" 2>/dev/null; }

# --- 1. what push mode needs, before any work starts ----------------------------------
project ""
git -C "$P" remote remove origin
FAKE_A='echo a > src/a.txt' orch run
assert_eq "no origin remote: refused as a setup error (exit 3)" "$rc" "3"
assert_contains "  ...saying what is missing" "$out" "needs a remote named origin"
assert_eq "  ...before any work started" "$(cat "$FAKE/calls" 2>/dev/null || echo 0)" "0"
project ""
GH_STUB_AUTH=fail FAKE_A='echo a > src/a.txt' orch run
assert_contains "gh not logged in: refused too" "$out" "needs gh logged in"

# --- 2. the whole path: branch, push, pull request, CI passes ---------------------------
project "" '[{"id":"a","prompt":"DO_A","deps":[],"files":["src/a.txt"],"category":"coding"},
            {"id":"b","prompt":"DO_B","deps":[],"files":["src/b.txt"],"category":"coding"}]'
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' FAKE_B='echo b > src/b.txt' orch run --isolate
assert_eq "a push-mode run whose CI passes exits 0" "$rc" "0"
assert_eq "the work is on one new fa/ branch on origin" "$(branches | wc -l | tr -d ' ')" "1"
assert_eq "  ...with both tasks' files" "$(on_branch src/a.txt)$(on_branch src/b.txt)" "ab"
assert_contains "  ...committed as fa, a commit per task" \
  "$(git -C "$R/origin.git" log --format='%an %s' "$(branches)")" "free-agents fa: a"
assert_eq "your working directory was never touched: same commit" "$(git -C "$P" rev-parse HEAD)" "$START"
assert_true "  ...and none of the work in it" '[[ ! -e "$P/src/a.txt" && ! -e "$P/src/b.txt" ]]'
assert_eq "  ...still on main" "$(git -C "$P" symbolic-ref --short HEAD)" "main"
assert_contains "a pull request from that branch into main" "$(ghlog)" "pr create head=$(branches) base=main draft=0"
assert_contains "  ...whose body lists what each task did" "$(cat "$GH_STUB_DIR/pr-body.1" 2>/dev/null)" '\*\*a (src/a.txt)\*\*'
assert_contains "it waited for CI, through a check still running" "$(journal)" '"event":"ci","task":"-","result":"passed"'
assert_true "  ...looking more than once" '[[ $(grep -c "check-runs" "$GH_STUB_DIR/calls") -ge 3 ]]'
assert_not_contains "automerge is off: nothing merged" "$(ghlog)" "pr merge"
st="$(status)"
assert_contains "fa status: the branch" "$st" "branch  $(branches) -> main  pushed"
assert_contains "  ...the pull request" "$st" "PR      https://github.com/stub-owner/stub-repo/pull/1"
assert_contains "  ...and CI" "$st" "CI      passed"

# --- 3. CI fails, a worker fixes it, CI passes --------------------------------------------
project ""
GH_STUB_CI="fail pass" FAKE_A='echo a > src/a.txt' FAKE_CIFIX='echo fixed > src/a.txt' orch run
assert_eq "CI failed once and a worker fixed it: exit 0" "$rc" "0"
cp="$(cat "$FAKE/prompt.$(head -1 "$FAKE/cifixer" 2>/dev/null)" 2>/dev/null)"
assert_contains "the worker is told which check failed" "$cp" "Failing: suite"
assert_contains "  ...and given its log" "$cp" "expected status 409, got 500"
assert_eq "its fix is on the branch" "$(on_branch src/a.txt)" "fixed"
assert_contains "  ...as its own commit" "$(git -C "$R/origin.git" log --format='%s' "$(branches)")" "fa: fix CI (suite)"
assert_contains "fa status: passed after the fix" "$(status)" "CI      passed after 1 fix round(s)"

# --- 4. the CI files are not the fixer's to change -------------------------------------------
project ""
GH_STUB_CI="fail pass" FAKE_A='echo a > src/a.txt' \
  FAKE_CIFIX='echo "on: []" > .github/workflows/ci.yml; echo fixed > src/a.txt' orch run
assert_eq "a fixer's edit to the CI file never reaches the branch" "$(on_branch .github/workflows/ci.yml)" "${CI_YML%$'\n'}"

# --- 5. CI keeps failing ------------------------------------------------------------------------
project ""
FA_CI_FIX_ROUNDS=1 GH_STUB_CI=fail FAKE_A='echo a > src/a.txt' FAKE_CIFIX='echo try > src/a.txt' orch run
assert_eq "CI that still fails after its fix rounds fails the run (exit 1)" "$rc" "1"
assert_eq "  ...after exactly FA_CI_FIX_ROUNDS workers" "$(grep -c . "$FAKE/cifixer" 2>/dev/null)" "1"
assert_contains "  ...and fa status says so" "$(status)" "CI FAILED  suite  after 1 fix round(s)"
project ""
GH_STUB_CI=fail FAKE_A='echo a > src/a.txt' FAKE_CIFIX=':' orch run
assert_eq "a fixer that changes nothing ends it at once" "$(grep -c . "$FAKE/cifixer" 2>/dev/null)" "1"

# --- 6. automerge ---------------------------------------------------------------------------------
project "automerge: true"
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' orch run
assert_contains "automerge: a pull request whose CI passed is merged" "$(ghlog)" "pr merge --merge https://github.com/stub-owner/stub-repo/pull/1"
assert_contains "  ...which fa status shows" "$(status)" "merged  (merge)"
project "automerge: true"
GH_STUB_MERGE_DENY="--merge" GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' orch run
assert_contains "  ...by whichever method the repository allows" "$(ghlog)" "pr merge --squash"
project "automerge: true"
FA_CI_FIX_ROUNDS=0 GH_STUB_CI=fail FAKE_A='echo a > src/a.txt' orch run
assert_not_contains "a pull request whose CI failed is never merged" "$(ghlog)" "pr merge"
assert_contains "  ...and fa status says why" "$(status)" "not merged: CI failed"
project "automerge: true" "" noci
FA_CI_APPEAR=0 GH_STUB_CI=none FAKE_A='echo a > src/a.txt' orch run
assert_not_contains "no CI and no project check: nothing checked it, nothing merges" "$(ghlog)" "pr merge"
project $'automerge: true\nverify: test -s src/a.txt' "" noci
GH_STUB_CI=none FA_CI_APPEAR=0 FAKE_A='echo a > src/a.txt' orch run
assert_contains "no CI, but the project check passed: merged" "$(ghlog)" "pr merge --merge"
# GitHub took a minute to start a new repository's first run in the first real
# trial: a workflow that runs on pull requests is waited for, never taken for
# "no CI" - which, with a passing project check, would merge unchecked by CI.
project $'automerge: true\nverify: test -s src/a.txt'
FA_CI_APPEAR=0 FA_CI_TIMEOUT=2 GH_STUB_CI=none FAKE_A='echo a > src/a.txt' orch run
assert_contains "a pull-request workflow that has not reported yet is not \"no CI\"" \
  "$(journal)" '"event":"ci","task":"-","result":"timeout"'
assert_not_contains "  ...so nothing merges" "$(ghlog)" "pr merge"
assert_eq "  ...and the run is not called done (exit 1)" "$rc" "1"

# --- 7. the project check fails: a draft, and nothing waits on CI ------------------------------
project "verify: false"
FAKE_A='echo a > src/a.txt' FAKE_FIX=':' orch run
assert_eq "a project check that fails in push mode fails the run" "$rc" "1"
assert_contains "  ...the pull request opens as a draft" "$(ghlog)" "draft=1"
assert_not_contains "  ...and nothing waits on CI" "$(cat "$GH_STUB_DIR/calls" 2>/dev/null)" "check-runs"

# --- 8. only declared files are pushed ---------------------------------------------------------
project ""
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt; echo junk > scratch.txt' orch run
assert_eq "a declared file is pushed" "$(on_branch src/a.txt)" "a"
assert_eq "  ...a file the task never declared is not" "$(on_branch scratch.txt)" ""
assert_contains "  ...which the journal says" "$(journal)" '"files":"scratch.txt","fate":"not committed, so not pushed"'

# --- 9. a plan keeps its branch while its pull request is open; a new plan starts anew ---------
project "" '[{"id":"a","prompt":"DO_A","deps":[],"files":["src/a.txt"],"category":"general"},
            {"id":"b","prompt":"DO_B","deps":[],"files":["src/b.txt"],"category":"general","blocked":"needs a key"}]'
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' FAKE_B='echo b > src/b.txt' orch run
first="$(branches)"
jq '(.tasks[] | select(.id == "b")) |= del(.blocked)' "$P/.orch/tasks.json" > "$P/t" && mv "$P/t" "$P/.orch/tasks.json"
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' FAKE_B='echo b > src/b.txt' orch resume
assert_eq "resume continues the same branch" "$(branches)" "$first"
assert_eq "  ...which now has the second task's work too" "$(on_branch src/b.txt)" "b"
assert_eq "  ...under the same pull request" "$(grep -c 'pr create' "$GH_STUB_DIR/log")" "1"
pushes="$(journal | grep -c '"event":"pushed"')"
GH_STUB_CI=pass orch run
assert_eq "the same plan run again stays on its branch" "$(branches)" "$first"
assert_eq "  ...and with nothing new, pushes nothing" "$(journal | grep -c '"event":"pushed"')" "$pushes"
GH_STUB_PR_STATE=MERGED GH_STUB_CI=pass orch run
assert_contains "a pull request merged on GitHub is not continued" "$out" "pull request is merged - starting a new branch"
jq '.tasks = [{"id":"c","prompt":"DO_C","deps":[],"files":["src/c.txt"],"category":"general"}]' \
  "$P/.orch/tasks.json" > "$P/t" && mv "$P/t" "$P/.orch/tasks.json"
GH_STUB_CI=pass FAKE_C='echo c > src/c.txt' orch run
assert_eq "a new plan starts a new branch" "$(branches | wc -l | tr -d ' ')" "2"
assert_eq "  ...and opens a new pull request" "$(grep -c 'pr create' "$GH_STUB_DIR/log")" "2"

# --- 10. gh always means origin; a resume with its worktree gone says so -------------------------
project ""
# origin names GitHub; pushes still land in the bare repo (pushInsteadOf).
git -C "$P" remote set-url origin https://github.com/stub-owner/stub-repo.git
git -C "$P" config url."$R/origin.git".pushInsteadOf https://github.com/stub-owner/stub-repo.git
GH_STUB_CI=pass FAKE_A='echo a > src/a.txt' orch run
assert_contains "with origin on GitHub, every gh call names it (a second remote cannot confuse it)" \
  "$(grep 'pr create' "$GH_STUB_DIR/calls")" '\[GH_REPO=stub-owner/stub-repo\]'
rm -rf "$P/.orch/worktrees/run"; git -C "$P" worktree prune
GH_STUB_CI=pass orch resume
assert_contains "a resume whose run worktree is gone warns instead of quietly starting over" \
  "$out" "cannot be continued - its worktree is gone"

# --- 11. strict (the default) pushes nothing ---------------------------------------------------
project ""
sed -i 's/^mode: push/mode: strict/' "$P/.orch/config.yaml"
FAKE_A='echo a > src/a.txt' orch run
assert_eq "mode: strict pushes nothing" "$(branches)" ""
assert_true "  ...and never calls gh" '[[ ! -s "$GH_STUB_DIR/calls" ]]'
assert_eq "  ...the work is in the project, as always" "$(cat "$P/src/a.txt" 2>/dev/null)" "a"

end_suite
final_report
