#!/usr/bin/env bash
set -euo pipefail

# resume.sh - Resume an interrupted project
# Usage: resume.sh [project_path]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
PROJECT_FILE="${ORCH_DIR}/project.json"

# Check if project exists
if [[ ! -f "${PROJECT_FILE}" ]]; then
  echo "Error: No project found. Run orchestrator.sh first."
  exit 1
fi

# Get project info
PROJECT_NAME=$(jq -r '.info.name' "${PROJECT_FILE}")
PROJECT_PATH=$(jq -r '.info.path' "${PROJECT_FILE}")

echo "Resuming project: ${PROJECT_NAME}" >&2
echo "Project path: ${PROJECT_PATH}" >&2

# Check project status
STATUS=$(jq -r '.status' "${PROJECT_FILE}")
echo "Current status: ${STATUS}" >&2

# Count tasks
TOTAL_TASKS=$(jq '[.plan.phases[].tasks | length] | add' "${PROJECT_FILE}")
COMPLETED_TASKS=$(jq '[.tasks[] | select(.status == "done")] | length' "${PROJECT_FILE}")
FAILED_TASKS=$(jq '[.tasks[] | select(.status == "failed")] | length' "${PROJECT_FILE}")
RUNNING_TASKS=$(jq '[.tasks[] | select(.status == "running")] | length' "${PROJECT_FILE}")

echo "" >&2
echo "Task summary:" >&2
echo "  Total: ${TOTAL_TASKS}" >&2
echo "  Completed: ${COMPLETED_TASKS}" >&2
echo "  Failed: ${FAILED_TASKS}" >&2
echo "  Running: ${RUNNING_TASKS}" >&2

# Find incomplete tasks
INCOMPLETE_TASKS=$(jq -r '
  [.plan.phases[].tasks[].id] as $all |
  [.tasks[] | select(.status == "failed" or .status == "running") | .id] as $incomplete |
  [$all[] | select(. as $id | $incomplete | index($id) != null)]
' "${PROJECT_FILE}")

INCOMPLETE_COUNT=$(echo "${INCOMPLETE_TASKS}" | jq 'length')

if [[ ${INCOMPLETE_COUNT} -eq 0 ]]; then
  echo "" >&2
  echo "All tasks completed! Project is done." >&2
  exit 0
fi

echo "" >&2
echo "Incomplete tasks: ${INCOMPLETE_COUNT}" >&2
echo "${INCOMPLETE_TASKS}" | jq -r '.[]' | while read -r task_id; do
  task_info=$(jq -r --arg id "${task_id}" '
    .plan.phases[].tasks[] | select(.id == $id) |
    "  - \(.id): \(.role)/\(.task_type) - \(.description[:50])..."
  ' "${PROJECT_FILE}")
  echo "${task_info}" >&2
done

# Ask user what to do
echo "" >&2
echo "Options:" >&2
echo "  1. Run all incomplete tasks" >&2
echo "  2. Run failed tasks only" >&2
echo "  3. Run specific task" >&2
echo "  4. View task details" >&2
echo "  5. Exit" >&2
echo "" >&2
read -p "Select option (1-5): " choice

case "${choice}" in
  1)
    echo "Running all incomplete tasks..." >&2
    "${SCRIPT_DIR}/runner.sh" --resume
    ;;
  2)
    echo "Running failed tasks..." >&2
    jq -r '.tasks[] | select(.status == "failed") | .id' "${PROJECT_FILE}" | while read -r task_id; do
      "${SCRIPT_DIR}/runner.sh" "${task_id}"
    done
    ;;
  3)
    read -p "Enter task ID: " task_id
    "${SCRIPT_DIR}/runner.sh" "${task_id}"
    ;;
  4)
    read -p "Enter task ID: " task_id
    echo "" >&2
    jq -r --arg id "${task_id}" '
      .plan.phases[].tasks[] | select(.id == $id) |
      "Task: \(.id)",
      "Role: \(.role)/\(.task_type)",
      "Description: \(.description)",
      "Files: \(.files | join(", "))",
      "Dependencies: \(.dependencies | join(", ") // "none")"
    ' "${PROJECT_FILE}"
    
    # Check if task has been run
    if [[ -f "${ORCH_DIR}/tasks/${task_id}.json" ]]; then
      echo "" >&2
      echo "Previous result:" >&2
      jq -r '
        "Status: \(.status)",
        "Result: \(.result.summary[:200])..."
      ' "${ORCH_DIR}/tasks/${task_id}.json"
    fi
    ;;
  5)
    echo "Exiting." >&2
    exit 0
    ;;
  *)
    echo "Invalid option" >&2
    exit 1
    ;;
esac
