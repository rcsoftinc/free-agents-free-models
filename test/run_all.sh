#!/usr/bin/env bash
# run_all.sh - Execute the full orchestrator test suite.
# Each suite reports pass/fail; this script exits non-zero if any suite fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: > "${HERE}/test.log"

SUITES=(
  test_discover.sh
  test_rankings.sh
  test_handoff.sh
  test_promote.sh
  test_classify.sh
  test_fallback.sh
  test_edge.sh
  test_orchestrator.sh
  test_resume.sh
  test_parallel.sh
  test_compress.sh
  test_backoff.sh
  test_distribution.sh
  test_runner.sh
)

overall=0
for s in "${SUITES[@]}"; do
  echo "########## RUNNING $s ##########" | tee -a "${HERE}/test.log"
  bash "${HERE}/$s" >> "${HERE}/test.log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "RESULT: $s PASS" | tee -a "${HERE}/test.log"
  else
    echo "RESULT: $s FAIL (rc=$rc)" | tee -a "${HERE}/test.log"
    overall=1
  fi
done

echo
echo "================ SUMMARY ================"
grep -E "^(SUITE|RESULT|PASS|FAIL|TOTAL)" "${HERE}/test.log" | sed 's/^/  /'
echo
if [[ $overall -eq 0 ]]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit $overall
