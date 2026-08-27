#!/usr/bin/env bash
set -euo pipefail

# handoff.sh - Capture and pass context between tasks
# Usage: handoff.sh <task_id> [action]
# Actions: capture (default), get, compress

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
PROJECT_FILE="${ORCH_DIR}/project.json"
TASKS_DIR="${ORCH_DIR}/tasks"
HANDOFFS_DIR="${ORCH_DIR}/handoffs"

mkdir -p "${TASKS_DIR}" "${HANDOFFS_DIR}"

# Validate arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task_id> [capture|get|compress]"
  exit 1
fi

TASK_ID="$1"
ACTION="${2:-capture}"

# Check task exists
TASK_FILE="${TASKS_DIR}/${TASK_ID}.json"
if [[ ! -f "${TASK_FILE}" ]]; then
  echo "Error: Task file not found: ${TASK_FILE}"
  exit 1
fi

# Capture handoff from completed task
capture_handoff() {
  local task_id="$1"
  local task_file="${TASKS_DIR}/${task_id}.json"
  
  # Check task is done
  local status
  status=$(jq -r '.status' "${task_file}")
  
  if [[ "${status}" != "done" ]]; then
    echo "Error: Task ${task_id} is not done (status: ${status})"
    return 1
  fi
  
  # Extract task info
  local role
  role=$(jq -r '.role' "${task_file}")
  local task_type
  task_type=$(jq -r '.task_type' "${task_file}")
  local description
  description=$(jq -r '.description' "${task_file}")
  local result_summary
  result_summary=$(jq -r '.result.summary' "${task_file}")
  local files
  files=$(jq -r '.files | join(", ")' "${task_file}")
  
  # Create handoff file
  jq -n \
    --arg task_id "${task_id}" \
    --arg role "${role}" \
    --arg task_type "${task_type}" \
    --arg description "${description}" \
    --arg summary "${result_summary}" \
    --arg files "${files}" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      task_id: $task_id,
      role: $role,
      task_type: $task_type,
      description: $description,
      summary: $summary,
      files: ($files | split(", ") | map(select(length > 0))),
      created_at: $created_at
    }' > "${HANDOFFS_DIR}/${task_id}.json"
  
  echo "Handoff captured for task ${task_id}"
}

# Get handoff context for a task
get_handoff_context() {
  local task_id="$1"
  
  # Get task dependencies
  local dependencies
  dependencies=$(jq -r '.dependencies | join(" ")' "${TASK_FILE}")
  
  if [[ -z "${dependencies}" ]]; then
    echo "No dependencies - fresh start"
    return
  fi
  
  echo "Context from previous tasks:"
  echo ""
  
  for dep in ${dependencies}; do
    local handoff_file="${HANDOFFS_DIR}/${dep}.json"
    
    if [[ -f "${handoff_file}" ]]; then
      local dep_role
      dep_role=$(jq -r '.role' "${handoff_file}")
      local dep_task_type
      dep_task_type=$(jq -r '.task_type' "${handoff_file}")
      local dep_summary
      dep_summary=$(jq -r '.summary' "${handoff_file}")
      local dep_files
      dep_files=$(jq -r '.files | join(", ")' "${handoff_file}")
      
      echo "=== Task ${dep} (${dep_role}/${dep_task_type}) ==="
      echo "Summary: ${dep_summary}"
      echo "Files: ${dep_files}"
      echo ""
    else
      echo "=== Task ${dep} ==="
      echo "Warning: Handoff not found"
      echo ""
    fi
  done
}

# Compress handoff context (summarize for token efficiency)
compress_handoff() {
  local task_id="$1"
  local handoff_file="${HANDOFFS_DIR}/${task_id}.json"
  
  if [[ ! -f "${handoff_file}" ]]; then
    echo "Error: Handoff not found for task ${task_id}"
    return 1
  fi
  
  # Get summary and truncate
  local summary
  summary=$(jq -r '.summary' "${handoff_file}")
  
  # Simple compression: take first 500 chars
  local compressed
  compressed=$(echo "${summary}" | head -c 500)
  
  # Update handoff with compressed summary
  jq --arg compressed "${compressed}" '.summary = $compressed | .compressed = true' \
    "${handoff_file}" > "${handoff_file}.tmp" && mv "${handoff_file}.tmp" "${handoff_file}"
  
  echo "Handoff compressed for task ${task_id}"
}

# Get all handoffs for a task (including transitive dependencies)
get_full_context() {
  local task_id="$1"
  local depth="${2:-0}"
  local indent=""
  
  # Build indent
  for ((i=0; i<depth; i++)); do
    indent="${indent}  "
  done
  
  # Per-task file (NOT the global TASK_FILE, which would cause infinite
  # recursion by always reading the root task's dependencies).
  local node_file="${TASKS_DIR}/${task_id}.json"
  [[ -f "${node_file}" ]] || return
  
  # Get THIS task's dependencies
  local dependencies
  dependencies=$(jq -r '.dependencies | join(" ")' "${node_file}")
  
  if [[ -z "${dependencies}" ]]; then
    return
  fi
  
  for dep in ${dependencies}; do
    local handoff_file="${HANDOFFS_DIR}/${dep}.json"
    
    if [[ -f "${handoff_file}" ]]; then
      local dep_role
      dep_role=$(jq -r '.role' "${handoff_file}")
      local dep_task_type
      dep_task_type=$(jq -r '.task_type' "${handoff_file}")
      local dep_summary
      dep_summary=$(jq -r '.summary' "${handoff_file}" | head -c 200)
      
      echo "${indent}Task ${dep} (${dep_role}/${dep_task_type}):"
      echo "${indent}  ${dep_summary}"
      echo ""
      
      # Recursively get context for dependencies of dependencies
      get_full_context "${dep}" $((depth + 1))
    fi
  done
}

# Main
main() {
  case "${ACTION}" in
    capture)
      capture_handoff "${TASK_ID}"
      ;;
    get)
      get_handoff_context "${TASK_ID}"
      ;;
    compress)
      compress_handoff "${TASK_ID}"
      ;;
    full)
      get_full_context "${TASK_ID}"
      ;;
    *)
      echo "Error: Unknown action: ${ACTION}"
      echo "Actions: capture, get, compress, full"
      exit 1
      ;;
  esac
}

main "$@"
