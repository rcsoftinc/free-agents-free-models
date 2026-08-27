#!/usr/bin/env bash
set -euo pipefail

# compress.sh - AI-powered context compression for handoffs
# Usage: compress.sh <task_id> [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
RANKINGS_FILE="${ORCH_DIR}/rankings.json"
HANDOFFS_DIR="${ORCH_DIR}/handoffs"

# Check dependencies
if [[ ! -f "${RANKINGS_FILE}" ]]; then
  echo "Error: Rankings not found"
  exit 1
fi

# Validate arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task_id> [--force]"
  exit 1
fi

TASK_ID="$1"
FORCE="${2:-}"
HANDOFF_FILE="${HANDOFFS_DIR}/${TASK_ID}.json"

if [[ ! -f "${HANDOFF_FILE}" ]]; then
  echo "Error: Handoff not found for task ${TASK_ID}"
  exit 1
fi

# Check if already compressed
if [[ "${FORCE}" != "--force" ]]; then
  already_compressed=$(jq -r '.compressed // false' "${HANDOFF_FILE}")
  if [[ "${already_compressed}" == "true" ]]; then
    echo "Handoff already compressed. Use --force to recompress."
    exit 0
  fi
fi

# Get the best model for summarization
get_summarizer_model() {
  jq -r '
    .rankings.researcher.analysis[0] |
    "\(.agent) \(.model_id)"
  ' "${RANKINGS_FILE}"
}

# Compress context using AI
compress_context() {
  local handoff_file="$1"
  
  # Read current handoff
  local summary
  summary=$(jq -r '.summary' "${handoff_file}")
  local description
  description=$(jq -r '.description' "${handoff_file}")
  local files
  files=$(jq -r '.files | join(", ")' "${handoff_file}")
  
  # Get summarizer model
  local model_info
  model_info=$(get_summarizer_model)
  local agent
  agent=$(echo "${model_info}" | cut -d' ' -f1)
  local model_id
  model_id=$(echo "${model_info}" | cut -d' ' -f2)
  
  echo "Compressing context with ${agent}/${model_id}..." >&2
  
  # Create compression prompt
  local prompt
  prompt=$(cat << EOF
Summarize the following task result in 1-2 concise sentences.
Focus on: what was done, key decisions, and any issues.
Remove: verbose output, ANSI codes, redundant information.

Original task: ${description}
Files: ${files}

Result to summarize:
${summary}

Provide ONLY the compressed summary, nothing else.
EOF
  )
  
  # Execute compression
  local compressed=""
  local exit_code=0
  
  case "${agent}" in
    opencode)
      compressed=$(echo "${prompt}" | opencode run -m "${model_id}" --auto 2>&1) || exit_code=$?
      ;;
    kilo)
      compressed=$(kilo run -m "${model_id}" --auto "${prompt}" 2>&1) || exit_code=$?
      ;;
    hermes)
      compressed=$(hermes chat -m "${model_id}" -z "${prompt}" 2>&1) || exit_code=$?
      ;;
  esac
  
  if [[ ${exit_code} -ne 0 || -z "${compressed}" ]]; then
    echo "Warning: AI compression failed, using simple truncation" >&2
    compressed=$(echo "${summary}" | sed 's/\x1b\[[0-9;]*m//g' | head -c 500)
  fi
  
  # Clean up ANSI codes
  compressed=$(echo "${compressed}" | sed 's/\x1b\[[0-9;]*m//g')
  
  echo "${compressed}"
}

# Main
main() {
  echo "Compressing handoff for task ${TASK_ID}..." >&2
  
  # Compress context
  local compressed
  compressed=$(compress_context "${HANDOFF_FILE}")
  
  # Update handoff file
  jq --arg compressed "${compressed}" '
    .summary = $compressed |
    .compressed = true |
    .compressed_at = (now | todate)
  ' "${HANDOFF_FILE}" > "${HANDOFF_FILE}.tmp" && mv "${HANDOFF_FILE}.tmp" "${HANDOFF_FILE}"
  
  echo "Handoff compressed!" >&2
  echo "" >&2
  echo "Compressed summary:" >&2
  echo "${compressed}"
}

main "$@"
