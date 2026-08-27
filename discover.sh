#!/usr/bin/env bash
set -euo pipefail

# discover.sh - Discover available agents and models
# Assumes agents are installed and authenticated
# Produces: .orchestrator/catalog.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
CATALOG_FILE="${ORCH_DIR}/catalog.json"
CONFIG_FILE="${ORCH_DIR}/config.json"
TEMP_DIR=$(mktemp -d)

# Default config
MIN_CONTEXT_WINDOW=200000
EXCLUDED_MODELS="opencode/big-pickle"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# Create orchestrator directory
mkdir -p "${ORCH_DIR}"

# Load config if exists
if [[ -f "${CONFIG_FILE}" ]]; then
  MIN_CONTEXT_WINDOW=$(jq -r '.min_context_window // 200000' "${CONFIG_FILE}")
  EXCLUDED_MODELS=$(jq -r '.excluded_models // ["opencode/big-pickle"] | join("|")' "${CONFIG_FILE}")
fi

# Check if agent is installed
check_agent() {
  command -v "$1" &>/dev/null
}

# Get agent version
get_version() {
  case "$1" in
    opencode) opencode --version 2>/dev/null || echo "unknown" ;;
    kilo) kilo --version 2>/dev/null || echo "unknown" ;;
    hermes) hermes --version 2>/dev/null | head -1 || echo "unknown" ;;
    *) echo "unknown" ;;
  esac
}

# Fetch OpenRouter model metadata
fetch_openrouter_metadata() {
  echo "Fetching OpenRouter metadata..." >&2
  curl -s "https://openrouter.ai/api/v1/models" 2>/dev/null | jq -c '
    [.data[] | {
      id: .id,
      context_length: .context_length,
      pricing_prompt: (.pricing.prompt // "0" | tonumber),
      pricing_completion: (.pricing.completion // "0" | tonumber)
    }]
  ' > "${TEMP_DIR}/openrouter_metadata.json" 2>/dev/null || echo "[]" > "${TEMP_DIR}/openrouter_metadata.json"
}

# Discover opencode models
discover_opencode() {
  echo "Discovering opencode models..." >&2
  
  local output
  output=$(opencode models --verbose 2>&1) || {
    echo "Warning: opencode models command failed" >&2
    echo "[]"
    return
  }
  
  # Parse output: extract model blocks
  echo "${output}" | awk -v min_ctx="${MIN_CONTEXT_WINDOW}" -v excluded="${EXCLUDED_MODELS}" '
    BEGIN {
      model_count = 0
    }
    
    # New model block
    /^(opencode|openrouter|freemodel)\// {
      # Save previous model
      if (model_id != "" && context >= min_ctx && !excluded_match) {
        free = (cost_input == 0) ? "true" : "false"
        models[model_count] = "{"
        models[model_count] = models[model_count] "\"agent\":\"opencode\","
        models[model_count] = models[model_count] "\"model_id\":\"" model_id "\","
        models[model_count] = models[model_count] "\"provider\":\"" provider "\","
        models[model_count] = models[model_count] "\"context_window\":" context ","
        models[model_count] = models[model_count] "\"cost_input\":" cost_input ","
        models[model_count] = models[model_count] "\"free\":" free ","
        models[model_count] = models[model_count] "\"status\":\"" status "\","
        models[model_count] = models[model_count] "\"capabilities\":[]}"
        model_count++
      }
      
      # Start new model
      model_id = $0
      provider = substr($0, 1, index($0, "/") - 1)
      context = 0
      cost_input = -1
      status = "active"
      excluded_match = 0
      
      # Check if excluded
      if (index(excluded, model_id) > 0) {
        excluded_match = 1
      }
      next
    }
    
    # Extract context window
    /"context":/ {
      gsub(/[^0-9]/, "", $2)
      if ($2+0 > 0) context = $2+0
    }
    
    # Extract cost input (first occurrence only)
    /"input":/ && cost_input == -1 {
      gsub(/[^0-9]/, "", $2)
      if ($2+0 >= 0) cost_input = $2+0
    }
    
    # Extract status
    /"status":/ {
      gsub(/[^a-z]/, "", $2)
      if (length($2) > 0) status = $2
    }
    
    END {
      # Save last model
      if (model_id != "" && context >= min_ctx && !excluded_match) {
        free = (cost_input == 0) ? "true" : "false"
        models[model_count] = "{"
        models[model_count] = models[model_count] "\"agent\":\"opencode\","
        models[model_count] = models[model_count] "\"model_id\":\"" model_id "\","
        models[model_count] = models[model_count] "\"provider\":\"" provider "\","
        models[model_count] = models[model_count] "\"context_window\":" context ","
        models[model_count] = models[model_count] "\"cost_input\":" cost_input ","
        models[model_count] = models[model_count] "\"free\":" free ","
        models[model_count] = models[model_count] "\"status\":\"" status "\","
        models[model_count] = models[model_count] "\"capabilities\":[]}"
        model_count++
      }
      
      # Output as JSON array
      printf "["
      for (i = 0; i < model_count; i++) {
        if (i > 0) printf ","
        printf "%s", models[i]
      }
      printf "]"
    }
  '
}

# Discover hermes models (read cache files)
discover_hermes() {
  echo "Discovering hermes models..." >&2
  
  local cache_dir="${HOME}/.hermes/cache"
  local catalog_file="${cache_dir}/model_catalog.json"
  
  if [[ ! -f "${catalog_file}" ]]; then
    echo "Warning: hermes cache not found at ${catalog_file}" >&2
    echo "Run 'hermes model' to populate cache" >&2
    echo "[]"
    return
  fi
  
  # Extract model IDs from hermes catalog
  local hermes_models
  hermes_models=$(jq -r '
    [.providers.openrouter.models[]? | {
      id: .id,
      provider: "openrouter"
    }]
  ' "${catalog_file}" 2>/dev/null || echo "[]")
  
  # If no openrouter models, check other providers
  if [[ "$(echo "${hermes_models}" | jq 'length')" -eq 0 ]]; then
    hermes_models=$(jq -r '
      [.providers | to_entries[] | .value.models[]? | {
        id: (.id // "unknown"),
        provider: .key
      }]
    ' "${catalog_file}" 2>/dev/null || echo "[]")
  fi
  
  # Save hermes models to temp file
  echo "${hermes_models}" > "${TEMP_DIR}/hermes_models.json"
  
  # Merge with OpenRouter metadata if available
  if [[ -f "${TEMP_DIR}/openrouter_metadata.json" ]]; then
    jq -n \
      --argjson models "$(cat "${TEMP_DIR}/hermes_models.json")" \
      --argjson metadata "$(cat "${TEMP_DIR}/openrouter_metadata.json")" \
      '
      [$models[] | . as $m | {
        agent: "hermes",
        model_id: ("openrouter/" + .id),
        provider: "openrouter",
        context_window: ([$metadata[] | select(.id == $m.id) | .context_length] | first // 0),
        cost_input: ([$metadata[] | select(.id == $m.id) | .pricing_prompt] | first // 0),
        free: (([$metadata[] | select(.id == $m.id) | .pricing_prompt] | first // 0) == 0),
        status: "active",
        capabilities: []
      }]
      ' 2>/dev/null || echo "[]"
  else
    # No metadata available, use basic info
    jq '
      [.[] | {
        agent: "hermes",
        model_id: ("openrouter/" + .id),
        provider: "openrouter",
        context_window: 0,
        cost_input: -1,
        free: false,
        status: "active",
        capabilities: []
      }]
    ' "${TEMP_DIR}/hermes_models.json" 2>/dev/null || echo "[]"
  fi
}

# Discover kilo models
discover_kilo() {
  echo "Discovering kilo models..." >&2
  
  local output
  output=$(kilo models --verbose 2>&1) || {
    echo "Warning: kilo models command failed" >&2
    echo "[]"
    return
  }
  
  # Parse output similar to opencode
  echo "${output}" | awk -v min_ctx="${MIN_CONTEXT_WINDOW}" -v excluded="${EXCLUDED_MODELS}" '
    BEGIN {
      model_count = 0
    }
    
    # New model block (kilo uses "kilo/" prefix)
    /^kilo\// {
      # Save previous model
      if (model_id != "" && context >= min_ctx && !excluded_match) {
        free = (cost_input == 0) ? "true" : "false"
        models[model_count] = "{"
        models[model_count] = models[model_count] "\"agent\":\"kilo\","
        models[model_count] = models[model_count] "\"model_id\":\"" model_id "\","
        models[model_count] = models[model_count] "\"provider\":\"kilo\","
        models[model_count] = models[model_count] "\"context_window\":" context ","
        models[model_count] = models[model_count] "\"cost_input\":" cost_input ","
        models[model_count] = models[model_count] "\"free\":" free ","
        models[model_count] = models[model_count] "\"status\":\"" status "\","
        models[model_count] = models[model_count] "\"capabilities\":[]}"
        model_count++
      }
      
      # Start new model
      model_id = $0
      context = 0
      cost_input = -1
      status = "active"
      excluded_match = 0
      
      # Check if excluded
      if (index(excluded, model_id) > 0) {
        excluded_match = 1
      }
      next
    }
    
    # Extract context window
    /"context":/ {
      gsub(/[^0-9]/, "", $2)
      if ($2+0 > 0) context = $2+0
    }
    
    # Extract cost input (first occurrence only)
    /"input":/ && cost_input == -1 {
      gsub(/[^0-9]/, "", $2)
      if ($2+0 >= 0) cost_input = $2+0
    }
    
    # Extract status
    /"status":/ {
      gsub(/[^a-z]/, "", $2)
      if (length($2) > 0) status = $2
    }
    
    END {
      # Save last model
      if (model_id != "" && context >= min_ctx && !excluded_match) {
        free = (cost_input == 0) ? "true" : "false"
        models[model_count] = "{"
        models[model_count] = models[model_count] "\"agent\":\"kilo\","
        models[model_count] = models[model_count] "\"model_id\":\"" model_id "\","
        models[model_count] = models[model_count] "\"provider\":\"kilo\","
        models[model_count] = models[model_count] "\"context_window\":" context ","
        models[model_count] = models[model_count] "\"cost_input\":" cost_input ","
        models[model_count] = models[model_count] "\"free\":" free ","
        models[model_count] = models[model_count] "\"status\":\"" status "\","
        models[model_count] = models[model_count] "\"capabilities\":[]}"
        model_count++
      }
      
      # Output as JSON array
      printf "["
      for (i = 0; i < model_count; i++) {
        if (i > 0) printf ","
        printf "%s", models[i]
      }
      printf "]"
    }
  '
}

# Main discovery
main() {
  echo "Starting model discovery..." >&2
  echo "Min context window: ${MIN_CONTEXT_WINDOW}" >&2
  
  # Fetch OpenRouter metadata for hermes
  fetch_openrouter_metadata
  
  local all_models="[]"
  local agents_found=()
  
  # Discover opencode
  if check_agent "opencode"; then
    local opencode_models
    opencode_models=$(discover_opencode)
    local count
    count=$(echo "${opencode_models}" | jq 'length')
    echo "  opencode: ${count} models found" >&2
    all_models=$(echo "${all_models}" "${opencode_models}" | jq -s '.[0] + .[1]')
    agents_found+=("opencode")
  else
    echo "  opencode: not found" >&2
  fi
  
  # Discover hermes
  if check_agent "hermes"; then
    local hermes_models
    hermes_models=$(discover_hermes)
    local count
    count=$(echo "${hermes_models}" | jq 'length')
    echo "  hermes: ${count} models found" >&2
    all_models=$(echo "${all_models}" "${hermes_models}" | jq -s '.[0] + .[1]')
    agents_found+=("hermes")
  else
    echo "  hermes: not found" >&2
  fi
  
  # Discover kilo
  if check_agent "kilo"; then
    local kilo_models
    kilo_models=$(discover_kilo)
    local count
    count=$(echo "${kilo_models}" | jq 'length')
    echo "  kilo: ${count} models found" >&2
    all_models=$(echo "${all_models}" "${kilo_models}" | jq -s '.[0] + .[1]')
    agents_found+=("kilo")
  else
    echo "  kilo: not found" >&2
  fi
  
  # Build agents object
  local agents_json="{}"
  for agent in "${agents_found[@]}"; do
    local version
    version=$(get_version "${agent}")
    agents_json=$(echo "${agents_json}" | jq \
      --arg agent "${agent}" \
      --arg version "${version}" \
      '. + {($agent): {"installed": true, "version": $version}}')
  done
  
  # Write catalog
  jq -n \
    --argjson agents "${agents_json}" \
    --argjson models "${all_models}" \
    --arg min_context "${MIN_CONTEXT_WINDOW}" \
    --arg excluded "${EXCLUDED_MODELS}" \
    --arg discovered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      agents: $agents,
      models: $models,
      filters: {
        min_context_window: ($min_context | tonumber),
        excluded_models: ($excluded | split("|"))
      },
      discovered_at: $discovered_at
    }' > "${CATALOG_FILE}"
  
  echo "" >&2
  echo "Discovery complete!" >&2
  echo "Catalog written to: ${CATALOG_FILE}" >&2
  echo "Total models: $(echo "${all_models}" | jq 'length')" >&2
  
  # Output catalog path
  echo "${CATALOG_FILE}"
}

main "$@"
