#!/usr/bin/env bash
set -euo pipefail

# rankings.sh - Generate initial rankings from catalog
# Produces: .orchestrator/rankings.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
CATALOG_FILE="${ORCH_DIR}/catalog.json"
RANKINGS_FILE="${ORCH_DIR}/rankings.json"

# Check catalog exists
if [[ ! -f "${CATALOG_FILE}" ]]; then
  echo "Error: Catalog not found at ${CATALOG_FILE}"
  echo "Run discover.sh first"
  exit 1
fi

# Generate initial rankings
generate_rankings() {
  # Use --rawfile to avoid argument list too long
  jq -n --rawfile catalog "${CATALOG_FILE}" '
    # Parse catalog from rawfile
    ($catalog | fromjson) as $cat |
    
    # Get free models with sufficient context
    [$cat.models[] | select(.free == true and .context_window >= 200000)] |
    sort_by(-.context_window) as $free_models |
    
    # Create ranking entry
    def make_ranking:
      {
        agent: .agent,
        model_id: .model_id,
        provider: .provider,
        score: (if .context_window >= 1000000 then 0.95
                elif .context_window >= 500000 then 0.90
                elif .context_window >= 200000 then 0.85
                else 0.80 end),
        attempts: 0,
        successes: 0,
        last_used: null
      };
    
    # Build rankings for each role and task type
    {
      researcher: {
        analysis: [$free_models[:10][] | make_ranking],
        research: [$free_models[:10][] | make_ranking]
      },
      coder: {
        implementation: [$free_models[:10][] | make_ranking],
        refactoring: [$free_models[:10][] | make_ranking]
      },
      debugger: {
        bug_fix: [$free_models[:10][] | make_ranking]
      },
      reviewer: {
        code_review: [$free_models[:10][] | make_ranking]
      },
      planner: {
        planning: [$free_models[:10][] | make_ranking]
      },
      orchestrator: {
        orchestration: [$free_models[:10][] | make_ranking]
      }
    }
  '
}

# Main
main() {
  echo "Generating rankings from catalog..." >&2
  
  local rankings
  rankings=$(generate_rankings)
  
  # Write rankings
  echo "${rankings}" | jq '{
    generated_at: (now | todate),
    rankings: .
  }' > "${RANKINGS_FILE}"
  
  # Summary
  echo "Rankings generated: ${RANKINGS_FILE}" >&2
  
  # Show top model per role/task
  echo "" >&2
  echo "Top model per role/task:" >&2
  
  # Use jq to extract and display
  echo "${rankings}" | jq -r '
    . as $rankings |
    ["orchestrator", "researcher", "planner", "coder", "reviewer", "debugger"] | 
    .[] as $role |
    ($rankings[$role] // {}) | keys[] as $tt |
    "\($role)/\($tt): \($rankings[$role][$tt][0].model_id // "none") (score: \($rankings[$role][$tt][0].score // "-"))"
  ' 2>/dev/null | while read -r line; do
    printf "  %s\n" "${line}" >&2
  done
}

main "$@"
