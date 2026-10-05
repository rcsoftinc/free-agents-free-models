#!/usr/bin/env bash
# Proves a worker cannot pass its own check by editing the check. Files a task
# may not change (--readonly; `readonly:` in .orch/config.yaml; a task's own
# "readonly") are snapshotted before the first agent call and put back after
# every call, BEFORE any check runs - so verify always runs against the real
# tests. Files the task declares stay writable. And orch reports whatever a
# task changed outside its declared files: dropped from a worktree (kept as a
# patch) or kept in place.
#
# Without this, a free model that could not make a test pass would sometimes
# edit the test, and everything downstream said "(verified)".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "read-only files: a worker cannot pass by editing the check"
fixture_registry 1 || exit 1        # one lane, b0:fp0, reached through opencode
sandbox_on

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE" "$FIXTURE_DIR"' EXIT
# A fake agent that runs, in its workdir, the shell action scripted for this
# call (FAKE_CALL1, FAKE_CALL2, ...; FAKE_CALL_LAST after that) and keeps every
# prompt it was given.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
printf '%s' "${@: -1}" > "$FAKE_DIR/prompt.$n"
act="FAKE_CALL$n"; act="${!act:-${FAKE_CALL_LAST:-}}"
( cd "${dir:-.}" && eval "$act" )
printf '{"ok":true,"agent":"opencode","summary":"call %s"}' "$n"
EOF
chmod +x "$FAKE/opencode"
export FAKE_DIR="$FAKE" PATH="$FAKE:$PATH"
CHECK='grep -qx GOOD out.txt'
CHEAT='printf "exit 0\n" > tests/check.sh; echo BAD > out.txt'

fresh() { # a project whose one test is tests/check.sh; git if $1 == git
  P="$(mktemp -d)"; mkdir -p "$P/tests"; printf '%s\n' "$CHECK" > "$P/tests/check.sh"
  if [[ "${1:-}" == git ]]; then
    git -C "$P" init -q -b main; git -C "$P" -c user.name=t -c user.email=t@t add -A
    git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
  fi
  rm -f "$FAKE"/calls "$FAKE"/prompt.*
}
run() { # run.sh in $P; leaves $rc and $err
  "$REPO/bin/run.sh" -w "$P" -b b0:fp0 "$@" "make the check pass" >"$FAKE/out" 2>"$FAKE/err"
  rc=$?; err="$(cat "$FAKE/err")"
}
calls() { cat "$FAKE/calls" 2>/dev/null || echo 0; }

# --- 0. the gap, as it was --------------------------------------------------------
fresh
FAKE_CALL1="$CHEAT" run --verify 'bash tests/check.sh'
assert_eq "without read-only files, editing the test 'passes' (the gap)" "$rc" "0"
assert_eq "  ...and the real test is gone" "$(cat "$P/tests/check.sh")" "exit 0"

# --- 1. the cheat no longer works -------------------------------------------------
fresh
FAKE_CALL1="$CHEAT" FAKE_CALL2='echo GOOD > out.txt' run --readonly 'tests/*' --verify 'bash tests/check.sh'
assert_eq "with tests read-only, the edit is undone and the real check fails it" "$(calls)" "2"
assert_eq "  ...until the code is fixed: exit 0" "$rc" "0"
assert_eq "the test is exactly what it was" "$(cat "$P/tests/check.sh")" "$CHECK"
assert_contains "the run says what it put back" "$err" "put back read-only files the worker changed: tests/check.sh"
assert_contains "  ...and its record lists it" "$err" '"protected_restored":\["tests/check.sh"\]'
p2="$(cat "$FAKE/prompt.2" 2>/dev/null)"
assert_contains "the fix round is told its edit was undone" "$p2" "Its changes to these files were undone"
assert_contains "  ...and which files are read-only" "$p2" "tests/check.sh"
assert_contains "a finding names the model that tried" \
  "$(cat "$FREE_AGENTS_STATE/findings.ndjson" 2>/dev/null)" '"kind":"protected_edit"'

# --- 1b. whatever order the files come in ----------------------------------------
# The listing ends on a file no pattern matches - the shape that once left a
# failed match as the loop's status and, under set -e + pipefail, killed every
# run in a project with a readonly: list. test_readonly's own projects happened
# to end on a match; the full suite's detached jobs did not.
fresh
echo z > "$P/zzz-last.txt"
FAKE_CALL1='echo GOOD > out.txt' run --readonly 'tests/*' --verify 'bash tests/check.sh'
assert_eq "a run survives a file list that ends on a non-match" "$rc" "0"

# --- 2. deleted, created, and exempt ----------------------------------------------
fresh
FAKE_CALL1='rm tests/check.sh; echo x > tests/extra.sh; echo GOOD > out.txt' \
  run --readonly 'tests/*' --verify 'bash tests/check.sh'
assert_eq "a deleted read-only file is put back (and the work passes on it)" "$rc" "0"
assert_eq "  ...with its content" "$(cat "$P/tests/check.sh" 2>/dev/null)" "$CHECK"
assert_true "a file created where nothing may be created is removed" '[[ ! -e "$P/tests/extra.sh" ]]'
assert_contains "  ...and listed as such" "$err" "tests/extra.sh (new, removed)"
fresh
FAKE_CALL1='echo new > tests/new.sh; echo GOOD > out.txt' \
  run --readonly 'tests/*' --writable tests/new.sh --verify 'bash tests/check.sh'
assert_eq "a file the task may write (--writable) is kept" "$(cat "$P/tests/new.sh" 2>/dev/null)" "new"
fresh
FAKE_CALL1='echo hacked > tests/check.sh' run --readonly 'tests/*'
assert_eq "read-only holds without any verify command too" "$(cat "$P/tests/check.sh")" "$CHECK"

# --- 3. the director's own uncommitted edit survives ---------------------------------
fresh git
printf '%s\n# a note the director has not committed\n' "$CHECK" > "$P/tests/check.sh"
mine="$(cat "$P/tests/check.sh")"
FAKE_CALL1="$CHEAT" FAKE_CALL2='echo GOOD > out.txt' run --readonly 'tests/*' --verify 'bash tests/check.sh'
assert_eq "a worker's edit is undone back to YOUR version, uncommitted change and all" \
  "$(cat "$P/tests/check.sh")" "$mine"

# --- 4. what the check itself writes is not a worker's doing -------------------------
# Test runners write into test folders (a first screenshot baseline, a new
# snapshot). This verify creates its baseline and fails once, the way a first
# Playwright screenshot run does; the next restore must not delete it.
fresh
FAKE_CALL1='echo GOOD > out.txt' FAKE_CALL_LAST='echo GOOD > out.txt' \
  run --readonly 'tests/*' \
  --verify 'mkdir -p tests/snaps; [ -f tests/snaps/base ] || { echo base > tests/snaps/base; exit 1; }; grep -qx GOOD out.txt'
assert_eq "a baseline the check wrote survives into the next round" "$rc" "0"
assert_true "  ...and stays" '[[ -f "$P/tests/snaps/base" ]]'

# --- 5. the project's own list, through fa run -----------------------------------------
fresh
mkdir -p "$P/.orch"; printf 'mode: strict\nreadonly: tests/*  # the contract\n' > "$P/.orch/config.yaml"
( cd "$P" && FAKE_CALL1="$CHEAT" FAKE_CALL2='echo GOOD > out.txt' \
    "$REPO/bin/fa" run -b b0:fp0 --verify 'bash tests/check.sh' "x" </dev/null >/dev/null 2>&1 ); rc=$?
assert_eq "fa run applies the project's readonly: from .orch/config.yaml" "$(cat "$P/tests/check.sh")" "$CHECK"
assert_eq "  ...and the run still ends verified" "$rc" "0"

# --- 6. through orch: declared files stay writable, the rest is reported -------------
orch_project() { # $1 = task JSON; git project with the readonly config
  fresh git
  mkdir -p "$P/.orch" "$P/src"; : > "$P/src/.keep"   # git keeps no empty dirs
  printf 'mode: strict\nreadonly: tests/*\n' > "$P/.orch/config.yaml"
  printf '%s\n' "{\"tasks\":[$1]}" > "$P/.orch/tasks.json"
  git -C "$P" -c user.name=t -c user.email=t@t add -A
  git -C "$P" -c user.name=t -c user.email=t@t commit -qm plan
}
orch() { ( cd "$P" && FA_VALIDATE_ROUNDS=2 TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run "$@" </dev/null >/dev/null 2>&1 ); }
status() { ( cd "$P" && "$REPO/bin/fa" status 2>&1 ); }
journal() { cat "$P/.orch/journal.ndjson" 2>/dev/null; }

orch_project '{"id":"t","prompt":"p","deps":[],"files":["src/a.txt"],"category":"coding"}'
FAKE_CALL1='printf "exit 0\n" > tests/check.sh; echo a > src/a.txt; echo b > src/b.txt' orch
assert_contains "orch puts back a read-only file and journals it" "$(journal)" '"event":"protected","task":"t","files":"tests/check.sh"'
assert_contains "  ...which fa status shows" "$(status)" "t: read-only files it changed were put back: tests/check.sh"
assert_contains "a file changed in place without being declared is reported" \
  "$(journal)" '"event":"undeclared","task":"t","files":"src/b.txt","fate":"kept, in the project"'
assert_contains "  ...in fa status too" "$(status)" "t: changed files it did not declare (kept, in the project): src/b.txt"

orch_project '{"id":"t","prompt":"p","deps":[],"files":["src/a.txt"],"category":"coding"}'
FAKE_CALL1='echo a > src/a.txt; echo b > src/b.txt' orch --isolate
assert_contains "in a worktree, an undeclared file is reported as dropped" "$(journal)" '"fate":"dropped, not merged"'
assert_true "  ...it really did not reach the project" '[[ ! -e "$P/src/b.txt" ]]'
assert_true "  ...but survives as a patch to apply if it was needed" \
  'grep -q "src/b.txt" "$P/.orch/results/t.undeclared.patch" 2>/dev/null'
assert_contains "  ...which fa status points at" "$(status)" "patch: .orch/results/t.undeclared.patch"
assert_eq "the declared file did merge" "$(cat "$P/src/a.txt" 2>/dev/null)" "a"

orch_project '{"id":"t","prompt":"p","deps":[],"files":["tests/new.sh"],"category":"coding"}'
FAKE_CALL1='echo fresh > tests/new.sh' orch
assert_eq "a test file the task DECLARES is writable, read-only list or not" "$(cat "$P/tests/new.sh" 2>/dev/null)" "fresh"

orch_project '{"id":"t","prompt":"p","deps":[],"files":["src/a.txt"],"category":"coding","readonly":["src/*.lock"]}'
printf 'v1\n' > "$P/src/deps.lock"
FAKE_CALL1='echo a > src/a.txt; echo v2 > src/deps.lock' orch
assert_eq "a task's own readonly adds to the project's" "$(cat "$P/src/deps.lock")" "v1"

# --- 7. new projects start protected, whatever their layout ---------------------------
N="$(mktemp -d)"
( cd "$N" && ORCH_PROJECT="$N" "$REPO/bin/orch.sh" init >/dev/null 2>&1 )
assert_contains "a new project's config makes tests and CI read-only" \
  "$(grep '^readonly:' "$N/.orch/config.yaml")" "tests/\* .*\.github/\*"
# One test per common convention (pytest, RSpec, Maven/Gradle, Go, Jest/Vitest,
# .NET, CI), and code whose names merely contain "test". A worker edits them all.
tests=(tests/test_api.py test/run.sh spec/models/user_spec.rb src/test/java/AppTest.java
  app/src/test/kotlin/AppTest.kt pkg/tests/test_x.py src/app.test.ts web/button.spec.tsx
  internal/store_test.go __tests__/sum.js web/__tests__/button.js
  Calc.Tests/CalcTests.cs src/Parser.Tests/ParserTests.cs .github/workflows/ci.yml)
code=(src/app.ts src/latest/feed.ts src/contest.py Calc/Calc.cs internal/store.go README.md)
for f in "${tests[@]}" "${code[@]}"; do
  mkdir -p "$N/$(dirname "$f")"; printf '%s\n' "$f" > "$N/$f"
done
printf '%s\n' "${tests[@]}" "${code[@]}" > "$FAKE/all"; rm -f "$FAKE/calls"
( cd "$N" && FAKE_CALL1='while read -r f; do echo edited >> "$f"; done < "$FAKE_DIR/all"' \
    "$REPO/bin/fa" run -b b0:fp0 "x" </dev/null >/dev/null 2>&1 )
edited=""; for f in "${tests[@]}"; do [[ "$(cat "$N/$f")" == "$f" ]] || edited+=" $f"; done
assert_eq "  ...in every common layout: no test stays edited" "$edited" ""
lost=""; for f in "${code[@]}"; do [[ "$(tail -1 "$N/$f")" == edited ]] || lost+=" $f"; done
assert_eq "  ...while the code beside them stays the worker's to change" "$lost" ""
rm -rf "$N"

end_suite
final_report
