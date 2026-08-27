#!/usr/bin/env bash
set -euo pipefail

# promote.sh - Update rankings based on task results
# Usage: promote.sh <role> <task_type> <model_id> <agent> <result>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
RANKINGS_FILE="${ORCH_DIR}/rankings.json"
BACKUP_DIR="${ORCH_DIR}/.backups"

mkdir -p "${BACKUP_DIR}"

# Validate arguments
if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <role> <task_type> <model_id> <agent> <result>"
  echo "  result: success | failure | rate_limited"
  exit 1
fi

ROLE="$1"
TASK_TYPE="$2"
MODEL_ID="$3"
AGENT="$4"
RESULT="$5"

if [[ "${RESULT}" != "success" && "${RESULT}" != "failure" && "${RESULT}" != "rate_limited" ]]; then
  echo "Error: result must be success, failure, or rate_limited"
  exit 1
fi

if [[ ! -f "${RANKINGS_FILE}" ]]; then
  echo "Error: Rankings not found at ${RANKINGS_FILE}"
  exit 1
fi

# Backup rankings
cp "${RANKINGS_FILE}" "${BACKUP_DIR}/rankings_$(date +%Y%m%d_%H%M%S).json"

echo "Updating: ${ROLE}/${TASK_TYPE} -> ${MODEL_ID} (${RESULT})" >&2

# Update rankings using jq
jq \
  --arg role "${ROLE}" \
  --arg task_type "${TASK_TYPE}" \
  --arg model_id "${MODEL_ID}" \
  --arg agent "${AGENT}" \
  --arg result "${RESULT}" '
  
  # Get current ranking
  .rankings[$role][$task_type] as $ranking |
  
  # Find model index
  ($ranking | to_entries | map(select(.value.model_id == $model_id and .value.agent == $agent)) | first | .key // -1) as $idx |
  
  if $idx == -1 then
    # Model not found, add with initial score
    (if $result == "success" then 0.7
     elif $result == "failure" then 0.3
     else 0.5 end) as $init_score |
    
    .rankings[$role][$task_type] = ($ranking + [{
      agent: $agent,
      model_id: $model_id,
      provider: ($model_id | split("/") | .[0]),
      score: $init_score,
      attempts: 1,
      successes: (if $result == "success" then 1 else 0 end),
      last_used: (now | todate)
    }] | sort_by(-.score))
    
  else
    # Model found, update it
    $ranking[$idx] as $current |
    
    # Calculate new stats
    (if $result == "success" then
      {score: (($current.score + (1 - $current.score) * 0.2) * 100 | round / 100),
       attempts: ($current.attempts + 1),
       successes: ($current.successes + 1)}
    elif $result == "failure" then
      {score: ($current.score * 0.8 * 100 | round / 100),
       attempts: ($current.attempts + 1),
       successes: $current.successes}
    else
      {score: ($current.score * 0.9 * 100 | round / 100),
       attempts: ($current.attempts + 1),
       successes: $current.successes}
    end) as $stats |
    
    # Build updated entry
    ($current | .score = $stats.score | .attempts = $stats.attempts | .successes = $stats.successes | .last_used = (now | todate)) as $updated |
    
    # Replace and sort
    (.rankings[$role][$task_type] | .[$idx] = $updated | sort_by(-.score)) as $new_ranking |
    
    .rankings[$role][$task_type] = $new_ranking
  end
' "${RANKINGS_FILE}" > "${RANKINGS_FILE}.tmp" && mv "${RANKINGS_FILE}.tmp" "${RANKINGS_FILE}"

echo "Rankings updated!" >&2

# Show updated position
echo "" >&2
echo "Top 5 for ${ROLE}/${TASK_TYPE}:" >&2
jq -r "
  .rankings[\"${ROLE}\"][\"${TASK_TYPE}\"][:5] | 
  to_entries[] | 
  \"  \(.key + 1). \(.value.model_id) (score: \(.value.score), s/\(.value.attempts))\"
" "${RANKINGS_FILE}" 2>/dev/null
