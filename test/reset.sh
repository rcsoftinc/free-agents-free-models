#!/usr/bin/env bash
# reset.sh - Restore a named snapshot into the live .orchestrator state
# Usage: reset.sh <name>   (defaults to 'baseline')
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/../.orchestrator"
SNAP_DIR="${ORCH_DIR}/.test_snapshots"

NAME="${1:-baseline}"
SRC="${SNAP_DIR}/${NAME}"

if [[ ! -d "${SRC}" ]]; then
  echo "Error: snapshot '${NAME}' not found in ${SNAP_DIR}" >&2
  exit 1
fi

cp "${SRC}/catalog.json" "${ORCH_DIR}/catalog.json" 2>/dev/null || true
cp "${SRC}/rankings.json" "${ORCH_DIR}/rankings.json" 2>/dev/null || true
cp "${SRC}/project.json" "${ORCH_DIR}/project.json" 2>/dev/null || true

rm -rf "${ORCH_DIR}/tasks" "${ORCH_DIR}/handoffs"
mkdir -p "${ORCH_DIR}/tasks" "${ORCH_DIR}/handoffs"

# agent_state.json is runtime distribution state (rebuilt from rankings on
# first use), not part of a snapshot -- always start fresh.
rm -f "${ORCH_DIR}/.agent_state.json" "${ORCH_DIR}/.agent_state.lock"
cp -r "${SRC}/tasks/." "${ORCH_DIR}/tasks/" 2>/dev/null || true
cp -r "${SRC}/handoffs/." "${ORCH_DIR}/handoffs/" 2>/dev/null || true

echo "Restored snapshot '${NAME}'"
