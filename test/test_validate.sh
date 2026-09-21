#!/usr/bin/env bash
# test_validate.sh - the --validate gate (run.sh's Phase 1 syntax check +
# auto-fix loop). This path was never exercised end-to-end: it crashed on
# every successful run before it ever reached validate_build() (a `local`
# outside a function, then a function called before its own definition).
# These tests exist so a regression to either bug fails loudly here instead
# of shipping silently again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "--validate gate"
fixture_registry 3 || exit 1
sandbox_on

WORKDIR=""
new_workdir() { WORKDIR="$(mktemp -d)"; }

# ---------------------------------------------------------------- Test 1
# A successful build with nothing to flag: validate_build finds no
# js/py/sh files at all, so the gate passes trivially. This is the exact
# path that used to crash with "local: can only be used in a function"
# before ever printing output or the RUN-META footer.
echo "=== Test 1: --validate on a clean workdir does not crash ==="
new_workdir
out="$("$REPO/bin/run.sh" -w "$WORKDIR" -b b0:fp0 --validate "do a thing" 2>err1.txt)"
rc=$?
err="$(cat err1.txt)"
assert_eq "Test 1: exits 0" "$rc" "0"
assert_contains "Test 1: RUN-META present" "$err" '---RUN-META---'
assert_contains "Test 1: stub output printed" "$out" "stub success"
assert_not_contains "Test 1: no 'local' misuse error" "$err" "can only be used in a function"
assert_not_contains "Test 1: validate_build was actually reachable" "$err" "command not found"
rm -f err1.txt

# ---------------------------------------------------------------- Test 2
# A workdir containing a file with a genuine syntax error: validate_build
# must detect it, run the (bounded) auto-fix loop, and exit 1 cleanly after
# exhausting --validate-rounds - not crash partway through.
echo "=== Test 2: --validate exhausts cleanly on a real syntax error ==="
new_workdir
printf 'def broken(:\n    pass\n' > "${WORKDIR}/bad.py"
"$REPO/bin/run.sh" -w "$WORKDIR" -b b1:fp1 --validate --validate-rounds 1 \
  "do a thing" >out2.txt 2>err2.txt
rc=$?
err="$(cat err2.txt)"
assert_eq "Test 2: exits 1 (validation exhausted, not a crash)" "$rc" "1"
assert_contains "Test 2: reports exhaustion after the configured rounds" "$err" "validation FAILED after 1 round(s)"
assert_not_contains "Test 2: no 'local' misuse error" "$err" "can only be used in a function"
assert_not_contains "Test 2: validate_build was actually reachable" "$err" "command not found"
assert_not_contains "Test 2: no unbound variable abort" "$err" "unbound variable"
rm -f out2.txt err2.txt

rm -rf "$WORKDIR"
end_suite
final_report
