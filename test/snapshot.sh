#!/usr/bin/env bash
# snapshot.sh - Save current .orchestrator state under a named snapshot
# Usage: snapshot.sh <name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/../.orchestrator"
SNAP_DIR="${ORCH_DIR}/.test_snapshots"
mkdir -p "${SNAP_DIR}"

NAME="${1:-manual_$(date +%Y%m%d_%H%M%S)}"
DEST="${SNAP_DIR}/${NAME}"
mkdir -p "${DEST}/tasks" "${DEST}/handoffs"

cp "${ORCH_DIR}/catalog.json" "${DEST}/catalog.json" 2>/dev/null || true
cp "${ORCH_DIR}/rankings.json" "${DEST}/rankings.json" 2>/dev/null || true
cp "${ORCH_DIR}/project.json" "${DEST}/project.json" 2>/dev/null || true
cp -r "${ORCH_DIR}/tasks/." "${DEST}/tasks/" 2>/dev/null || true
cp -r "${ORCH_DIR}/handoffs/." "${DEST}/handoffs/" 2>/dev/null || true

echo "Snapshot '${NAME}' saved to ${DEST}"
