#!/usr/bin/env bash
# run_all.sh - run every suite in test/. Offline: stub agents, fixture registry.
cd "$(dirname "$0")/.." || exit 3
total_p=0; total_f=0; failed=()
for f in test/test_*.sh; do
  out="$(timeout "${SUITE_TIMEOUT:-240}" bash "$f" 2>&1)"; rc=$?
  line="$(printf '%s' "$out" | grep -oE 'passed=[0-9]+ failed=[0-9]+' | tail -1)"
  p="${line#passed=}"; p="${p%% *}"; fl="${line##*failed=}"
  printf '%-22s %s%s\n' "$(basename "$f")" "${line:-no summary}" \
    "$([[ $rc -ne 0 ]] && echo "  (rc=$rc)")"
  printf '%s' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
  total_p=$((total_p + ${p:-0})); total_f=$((total_f + ${fl:-0}))
  [[ $rc -ne 0 || "${fl:-0}" -ne 0 ]] && failed+=("$(basename "$f")")
done
echo "----------------------------------------"
echo "TOTAL: passed=$total_p failed=$total_f"
if [[ ${#failed[@]} -gt 0 ]]; then echo "SUITES FAILED: ${failed[*]}"; exit 1; fi
echo "ALL SUITES PASSED"
