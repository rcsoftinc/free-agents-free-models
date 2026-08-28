#!/usr/bin/env bash
set -euo pipefail

# ============================ RETIRED ============================
# This script is superseded by bin/plan.sh (planning) and bin/orch.sh (execution).
# It is kept only so its test suites keep running. Do not build on it.
# See legacy/README.md for the replacement map and the known defects
# that were deliberately NOT fixed here.
# =================================================================

# orchestrator.sh - Analyze project and create development plan
# Usage: orchestrator.sh <project_path> [description]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
CATALOG_FILE="${ORCH_DIR}/catalog.json"
RANKINGS_FILE="${ORCH_DIR}/rankings.json"
PROJECT_FILE="${ORCH_DIR}/project.json"

# Check dependencies
if [[ ! -f "${CATALOG_FILE}" ]]; then
  echo "Error: Catalog not found. Run discover.sh first"
  exit 1
fi

if [[ ! -f "${RANKINGS_FILE}" ]]; then
  echo "Error: Rankings not found. Run rankings.sh first"
  exit 1
fi

# Validate arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <project_path> [description]"
  echo ""
  echo "Arguments:"
  echo "  project_path  - Path to the project directory"
  echo "  description   - Optional description of what to build/fix"
  exit 1
fi

PROJECT_PATH="$1"
DESCRIPTION="${2:-}"

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Error: Project path does not exist: ${PROJECT_PATH}"
  exit 1
fi

# Get the best orchestrator model from rankings
get_orchestrator_model() {
  jq -r '
    .rankings.orchestrator.orchestration[0] |
    "\(.agent) \(.model_id)"
  ' "${RANKINGS_FILE}"
}

# Analyze project structure
analyze_project() {
  local project_path="$1"
  
  echo "Analyzing project structure..." >&2
  
  # Get project info
  local project_name
  project_name=$(basename "${project_path}")
  
  # Find key files
  local files
  files=$(find "${project_path}" -type f -name "*.json" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.md" -o -name "*.yaml" -o -name "*.yml" -o -name "*.toml" 2>/dev/null | head -50)
  
  # Get package.json or similar config
  local config_file=""
  if [[ -f "${project_path}/package.json" ]]; then
    config_file="package.json"
  elif [[ -f "${project_path}/Cargo.toml" ]]; then
    config_file="Cargo.toml"
  elif [[ -f "${project_path}/go.mod" ]]; then
    config_file="go.mod"
  elif [[ -f "${project_path}/requirements.txt" ]]; then
    config_file="requirements.txt"
  fi
  
  # Get git info if available
  local git_info=""
  if [[ -d "${project_path}/.git" ]]; then
    git_info=$(cd "${project_path}" && git log --oneline -5 2>/dev/null || echo "No git history")
  fi
  
  cat << EOF
{
  "name": "${project_name}",
  "path": "${project_path}",
  "config_file": "${config_file}",
  "files": $(echo "${files}" | jq -R -s 'split("\n") | map(select(length > 0))'),
  "git_info": "${git_info}",
  "has_tests": $(find "${project_path}" -type f -name "*.test.*" -o -name "*_test.*" -o -name "test_*" 2>/dev/null | head -1 | grep -q . && echo "true" || echo "false"),
  "has_ci": $([ -f "${project_path}/.github/workflows" ] || [ -f "${project_path}/.gitlab-ci.yml" ] || [ -f "${project_path}/Jenkinsfile" ] && echo "true" || echo "false")
}
EOF
}

# Generate plan using AI
generate_plan() {
  local project_info="$1"
  local description="$2"
  
  # Get orchestrator model
  local model_info
  model_info=$(get_orchestrator_model)
  local agent
  agent=$(echo "${model_info}" | cut -d' ' -f1)
  local model_id
  model_id=$(echo "${model_info}" | cut -d' ' -f2)
  
  echo "Using orchestrator: ${agent}/${model_id}" >&2
  
  # Create prompt
  local prompt
  prompt=$(cat << EOF
You are a software development orchestrator. Analyze this project and create a development plan.

Project Info:
${project_info}

Task: ${description:-"Analyze the project and suggest improvements"}

Create a JSON plan with the following structure:
{
  "project_name": "name",
  "summary": "Brief project summary",
  "tech_stack": ["language", "framework"],
  "phases": [
    {
      "name": "phase name",
      "description": "what this phase does",
      "tasks": [
        {
          "id": "task-001",
          "role": "coder|researcher|planner|reviewer|debugger",
          "task_type": "implementation|analysis|planning|refactoring|bug_fix|code_review|research",
          "description": "what to do",
          "files": ["relevant files"],
          "priority": "high|medium|low",
          "dependencies": []
        }
      ]
    }
  ]
}

Rules:
1. Start with analysis/research tasks
2. Then planning
3. Then implementation
4. Then review
5. Each task should be small and focused
6. Include file paths when known
7. Use the appropriate role for each task

Output ONLY the JSON plan, no other text.
EOF
  )
  
  # Call the appropriate agent
  case "${agent}" in
    opencode)
      echo "${prompt}" | opencode run -m "${model_id}" --auto 2>/dev/null
      ;;
    kilo)
      kilo run -m "${model_id}" --auto "${prompt}" 2>/dev/null
      ;;
    hermes)
      hermes -m "${model_id}" -z "${prompt}" 2>/dev/null
      ;;
    *)
      echo "Error: Unknown agent: ${agent}"
      exit 1
      ;;
  esac
}

# Save project
save_project() {
  local project_info="$1"
  local plan="$2"
  local description="$3"
  
  jq -n \
    --argjson info "$(echo "${project_info}" | jq '.')" \
    --argjson plan "$(echo "${plan}" | jq '.')" \
    --arg desc "${description}" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      info: $info,
      description: $desc,
      plan: $plan,
      tasks: [],
      status: "planning",
      created_at: $created_at,
      updated_at: $created_at
    }' > "${PROJECT_FILE}"
}

# Main
main() {
  echo "Orchestrator starting..." >&2
  echo "Project: ${PROJECT_PATH}" >&2
  
  # Analyze project
  local project_info
  project_info=$(analyze_project "${PROJECT_PATH}")
  
  echo "" >&2
  echo "Project analysis complete." >&2
  echo "  Name: $(echo "${project_info}" | jq -r '.name')" >&2
  echo "  Files: $(echo "${project_info}" | jq '.files | length')" >&2
  echo "  Config: $(echo "${project_info}" | jq -r '.config_file // "none"')" >&2
  
  # Generate plan
  echo "" >&2
  echo "Generating development plan..." >&2
  local plan
  plan=$(generate_plan "${project_info}" "${DESCRIPTION}")
  
  # Strip markdown code blocks if present
  plan=$(echo "${plan}" | sed 's/```json//g' | sed 's/```//g' | sed '/^$/d')
  
  # Validate plan
  if ! echo "${plan}" | jq empty 2>/dev/null; then
    echo "Error: Generated plan is not valid JSON" >&2
    echo "Plan output:" >&2
    echo "${plan}" >&2
    exit 1
  fi
  
  # Save project
  save_project "${project_info}" "${plan}" "${DESCRIPTION}"
  
  echo "" >&2
  echo "Plan generated!" >&2
  echo "Project saved to: ${PROJECT_FILE}" >&2
  
  # Show plan summary
  echo "" >&2
  echo "Plan summary:" >&2
  echo "${plan}" | jq -r '
    "  Summary: \(.summary // "N/A")",
    "  Tech stack: \(.tech_stack // [] | join(", "))",
    "  Phases: \(.phases | length)",
    "  Total tasks: \([.phases[].tasks | length] | add)"
  ' 2>/dev/null
  
  # Show tasks
  echo "" >&2
  echo "Tasks:" >&2
  echo "${plan}" | jq -r '
    .phases[] | 
    "  \(.name):", 
    (.tasks[] | "    - [\(.role)/\(.task_type)] \(.description)")
  ' 2>/dev/null
}

main "$@"
