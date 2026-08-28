#!/usr/bin/env bash
# Phase A1: discover.sh produces a valid catalog offline (curl stubbed).
set -uo pipefail
source "$(dirname "$0")/harness.sh"
begin_suite "A1 discover"

sandbox_on
reset_state baseline
rm -f "${ORCH_DIR}/catalog.json"

out=$(bash "${LEGACY_DIR}/discover.sh" 2>&1)
assert_eq "discover exits 0" "$?" "0"

assert_json_valid "catalog.json is valid JSON" "${ORCH_DIR}/catalog.json"

agents=$(jq -r '.agents | keys | join(",")' "${ORCH_DIR}/catalog.json")
assert_contains "agents object lists opencode" "$agents" "opencode"
assert_contains "agents object lists kilo" "$agents" "kilo"
assert_contains "agents object lists hermes" "$agents" "hermes"

assert_true "catalog has models array" 'jq -e ".models | type == \"array\"" "${ORCH_DIR}/catalog.json" >/dev/null'
assert_true "catalog has filters object" 'jq -e ".filters" "${ORCH_DIR}/catalog.json" >/dev/null'

end_suite
final_report
