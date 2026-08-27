#!/usr/bin/env bash
set -euo pipefail

# runner.sh - Execute tasks from the project plan with parallel execution and error recovery
# Usage: runner.sh [task_id|--resume|--parallel N]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="${SCRIPT_DIR}/.orchestrator"
PROJECT_FILE="${ORCH_DIR}/project.json"
RANKINGS_FILE="${ORCH_DIR}/rankings.json"
TASKS_DIR="${ORCH_DIR}/tasks"
LOCKS_DIR="${ORCH_DIR}/.locks"
LOG_FILE="${ORCH_DIR}/runner.log"

mkdir -p "${TASKS_DIR}" "${LOCKS_DIR}"

# Config
MAX_RETRIES=3
RETRY_DELAY=5
MAX_PARALLEL=1
# Per-attempt wall-clock timeout (seconds). A combo that exceeds this is killed
# and treated as a failure so the runner moves on instead of hanging forever.
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-120}"
# Overall budget for a single task (seconds). Guards against an unbounded
# exhaustive loop when every combo is slow. 0 disables the budget.
TASK_TIMEOUT="${TASK_TIMEOUT:-1800}"

# Backoff (seconds) between attempts after a rate_limited result. Avoids piling
# up in-flight requests on a single provider -- the original rate-limit cause.
# Delay = BASE * FACTOR^(attempt-1), capped at CAP, unless the result carries a
# Retry-After value (which wins, also capped). Set BASE=0 to disable.
BACKOFF_BASE="${BACKOFF_BASE:-5}"
BACKOFF_CAP="${BACKOFF_CAP:-60}"
BACKOFF_FACTOR="${BACKOFF_FACTOR:-2}"

# Agent/provider distribution state (reduces per-provider rate-limit pile-ups).
AGENT_STATE_FILE="${AGENT_STATE_FILE:-${ORCH_DIR}/.agent_state.json}"
AGENT_LOCK_FILE="${AGENT_LOCK_FILE:-${ORCH_DIR}/.agent_state.lock}"

# Logging
log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
  echo "${msg}" >> "${LOG_FILE}"
  echo "${msg}" >&2
}

# ---- Result classification & helpers (added for rate-limit aware fallback) ----

# Substrings that indicate a transient rate-limit / credit exhaustion error
# rather than a genuine task failure. These must be caught because some
# agents (e.g. `opencode run`) exit 0 even when the API returns a credit error.
RATE_LIMIT_PATTERNS=(
  "exceed your available credits"
  "in-flight requests"
  "rate limit"
  "rate_limit"
  "429"
  "quota"
  "too many requests"
  "try again later"
  "rate limited"
  "503"
  "service unavailable"
  "upstream"
)

# Classify a task result into: success | failure | rate_limited
# Usage: classify_result <result_text> <exit_code>
classify_result() {
  local result="$1" exit_code="$2"
  local lower
  lower=$(printf '%s' "$result" | tr '[:upper:]' '[:lower:]')

  for p in "${RATE_LIMIT_PATTERNS[@]}"; do
    if printf '%s' "$lower" | grep -qi -- "$p"; then
      echo "rate_limited"
      return
    fi
  done

  # Genuine success needs a clean exit AND non-empty, non-error-looking output.
  if [[ "${exit_code}" -eq 0 ]] && [[ -n "$result" ]] && ! printf '%s' "$lower" | grep -qi "error:"; then
    echo "success"
    return
  fi

  echo "failure"
}

# Strip ANSI escape codes from a string
strip_ansi() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Compute the backoff delay (seconds) before retrying after a rate_limited
# result. Pure function (no sleeps) so it is unit-testable.
#   attempt     : 1-based count of attempts already made
#   retry_after : optional Retry-After value (seconds) parsed from the result
# Returns BASE * FACTOR^(attempt-1), capped at CAP; a Retry-After value wins
# (also capped). Set BACKOFF_BASE=0 to disable (always returns 0).
next_backoff() {
  local attempt="${1:-1}"
  local retry_after="${2:-}"
  local delay=0
  if [[ -n "${retry_after}" && "${retry_after}" =~ ^[0-9]+$ ]]; then
    delay=$(( retry_after > BACKOFF_CAP ? BACKOFF_CAP : retry_after ))
  elif [[ "${BACKOFF_BASE}" -gt 0 ]]; then
    delay=$(( BACKOFF_BASE * (BACKOFF_FACTOR ** (attempt - 1)) ))
    (( delay > BACKOFF_CAP )) && delay=${BACKOFF_CAP}
  fi
  echo "${delay}"
}

# Extract a Retry-After value (seconds) from a result body if present.
retry_after_from() {
  printf '%s' "$1" | grep -oiE 'retry[ -]?after[^0-9]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true
}

# ---- Agent/provider distribution -------------------------------------------
# Goal: stop hammering a single provider (e.g. OpenRouter) with back-to-back
# calls. Each task is OWNED by one agent, chosen least-recently-used and biased
# away from the provider just used. Within a task's fallback, next_combo_for_task
# never picks the same provider twice in a row when an alternative exists.

# Initialize agent_state from the agents present in the rankings (idempotent).
init_agent_state() {
  if [[ ! -f "${AGENT_STATE_FILE}" ]]; then
    local agents
    agents=$(jq -r '[.rankings[][]?[]? | .agent] | unique | join(" ")' "${RANKINGS_FILE}" 2>/dev/null)
    jq -n --arg agents "$agents" '
      ($agents | split(" ") | map(select(length>0))) as $a
      | { agents: ([ $a[] | {key:.} ]
            | map({key:.key, value:{last_used:0, last_provider:null, inflight:0}})
            | from_entries),
          last_provider_attempt: null }
    ' > "${AGENT_STATE_FILE}"
  fi
}

# Apply a jq program to agent_state atomically under an exclusive flock.
agent_state_txn() {
  local prog="$1"
  (
    flock -w 15 9 || { printf ''; return 1; }
    local cur new
    cur=$(cat "${AGENT_STATE_FILE}")
    new=$(printf '%s' "$cur" | jq "$prog")
    printf '%s' "$new" > "${AGENT_STATE_FILE}.tmp" && mv "${AGENT_STATE_FILE}.tmp" "${AGENT_STATE_FILE}"
    printf '%s' "$new"
  ) 9>"${AGENT_LOCK_FILE}"
}

# Assign a task to an agent: atomic select + mark-start under one lock.
# Selection prefers agents whose last provider differs from the globally most
# recent provider, then least-recently-used, then fewest in-flight. Echoes the
# chosen agent, or "" if no agent has combos for (role,task_type).
acquire_agent_for_task() {
  local role="$1" tt="$2"
  local candidates_json
  candidates_json=$(jq --arg role "$role" --arg tt "$tt" '
    [ (.rankings[$role][$tt] // [])[] | .agent ] | unique' "${RANKINGS_FILE}")
  [[ "$candidates_json" == "[]" || -z "$candidates_json" ]] && { echo ""; return 1; }
  local now; now=$(date +%s)
  (
    flock -w 15 9 || { echo ""; return 1; }
    local cur new
    cur=$(cat "${AGENT_STATE_FILE}")
    new=$(printf '%s' "$cur" | jq --argjson cands "$candidates_json" --argjson now "$now" '
      ($cands) as $cands
      | .last_provider_attempt as $gprev
      | (.agents) as $ag
      | ($cands | map(. as $a | (($ag[$a] // {last_used:0,last_provider:null,inflight:0}) | .agent=$a))) as $list
      | ($list | sort_by(
            (if (.last_provider == $gprev) then 1 else 0 end),
            (.last_used),
            (.inflight)
         )[0]) as $pick
      | (.agents[$pick.agent].last_used = $now
         | .agents[$pick.agent].inflight += 1
         | .agents[$pick.agent].last_provider = $pick.last_provider
         | .last_provider_attempt = $pick.last_provider) as $upd
      | {agent: $pick.agent, state: $upd}
    ')
    printf '%s' "$new" | jq -c '.state' > "${AGENT_STATE_FILE}.tmp" && mv "${AGENT_STATE_FILE}.tmp" "${AGENT_STATE_FILE}"
    printf '%s' "$new" | jq -r '.agent'
  ) 9>"${AGENT_LOCK_FILE}"
}

# Release an agent's in-flight slot (atomic under lock).
mark_agent_end() {
  local agent="$1"
  agent_state_txn ".agents[\"${agent}\"].inflight = ((.agents[\"${agent}\"].inflight // 1) - 1 | if . < 0 then 0 else . end)"
}

# Record that an agent just used a provider (atomic under lock). Updates both the
# agent's own last_provider and the global last_provider_attempt so the next
# acquire_agent_for_task can steer away from the provider just hammered.
mark_provider_used() {
  local agent="$1" provider="$2"
  agent_state_txn ".agents[\"${agent}\"].last_provider = \"${provider}\" | .last_provider_attempt = \"${provider}\""
}

# Provider of a given "agent model_id" combo (helper for gap tracking).
combo_provider() {
  jq -r --arg k "$1" --arg role "$2" --arg tt "$3" '
    (.rankings[$role][$tt] // [])[] | select((.agent+" "+.model_id)==$k) | .provider' "${RANKINGS_FILE}"
}

# Pick the next combo for the CURRENT task, enforcing a provider gap.
# Depends on globals ASSIGNED_AGENT, LAST_PROVIDER, TRIED_KEYS (set by caller).
# Echoes "agent model_id score" or "" if no untried combo remains.
next_combo_for_task() {
  local role="$1" task_type="$2"
  local tried_json
  tried_json=$(printf '%s\n' "${TRIED_KEYS[@]:-}" | jq -R -s 'split("\n") | map(select(length>0))')
  jq -r --arg role "$role" --arg tt "$task_type" \
        --arg agent "$ASSIGNED_AGENT" --arg lastp "${LAST_PROVIDER:-}" \
        --argjson tried "$tried_json" '
    (.rankings[$role][$tt] // []) as $ranking
    | ($ranking | map(select((( .agent + " " + .model_id) as $k | ($tried | index($k) | not))))) as $untried
    | ($untried | map(select(.agent == $agent))) as $mine
    | ($mine | map(select(.provider != $lastp))) as $mine_gap
    | (if ($mine_gap | length) > 0 then $mine_gap else
         (if ($mine | length) > 0 then $mine else
            (($untried | map(select(.agent != $agent))) as $others
             | (($others | map(select(.provider != $lastp))) as $others_gap
                | if ($others_gap | length) > 0 then $others_gap else $others end))
          end)
       end) as $pool
    | (if ($pool | length) > 0 then ($pool | sort_by(-.score) | .[0]) else null end) as $best
    | if $best == null then "" else "\($best.agent) \($best.model_id) \($best.score)" end
  ' "${RANKINGS_FILE}"
}

# Check that project/rankings exist (called by modes that need them)
check_deps() {
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    echo "Error: Project not found. Run orchestrator.sh first" >&2
    exit 1
  fi
  if [[ ! -f "${RANKINGS_FILE}" ]]; then
    echo "Error: Rankings not found. Run rankings.sh first" >&2
    exit 1
  fi
}

# Pre-flight check: fail fast (before doing any work) if a provider the project
# actually needs has no API key, or if a task type has no ranked combos. This
# avoids burning time/queries only to fail partway through a run.
# Disabled when RUNNER_SKIP_PREFLIGHT is set (used by the offline test harness).
preflight_check() {
  [[ -n "${RUNNER_SKIP_PREFLIGHT:-}" ]] && return 0

  # Providers actually needed by the project's tasks (role/task_type -> rankings).
  local needed
  needed=$(jq -r '
    [.plan.phases[]?.tasks[]? | "\(.role)/\(.task_type)"] as $tts
    | [ $tts[] | split("/") | .[0] as $r | .[1] as $t
        | (.rankings[$r][$t] // [])[].provider ] | unique | .[]' "${RANKINGS_FILE}" 2>/dev/null)

  local missing=()
  for p in ${needed:-}; do
    local env="${p^^}"; env="${env//-/_}_API_KEY"
    if [[ -z "${!env:-}" ]]; then missing+=("$p"); fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing API key(s) for provider(s): ${missing[*]}" >&2
    echo "Set the corresponding <PROVIDER>_API_KEY environment variable (e.g. OPENROUTER_API_KEY) before running." >&2
    exit 1
  fi

  # Each task type referenced by the plan must have at least one ranked combo.
  local empty_tt
  empty_tt=$(jq -r '
    [.plan.phases[]?.tasks[]? | "\(.role)/\(.task_type)"] as $tts
    | [ $tts[] | split("/") | .[0] as $r | .[1] as $t
        | if ((.rankings[$r][$t] // []) | length) == 0 then "\($r)/\($t)" else empty end ] | unique | .[]' "${RANKINGS_FILE}" 2>/dev/null)
  if [[ -n "${empty_tt:-}" ]]; then
    echo "Error: no ranked combos for task type(s): ${empty_tt}" >&2
    echo "Run rankings.sh / promote.sh to populate these before executing." >&2
    exit 1
  fi
}

# Get all available tasks (respecting dependencies)
get_available_tasks() {
  jq -r '
    [.plan.phases[].tasks[].id] as $all_tasks |
    # Tasks already present in .tasks have been attempted/started and must
    # not be re-selected (covers done, running, and failed states).
    [.tasks[] | .id] as $handled |
    [.tasks[] | select(.status == "done") | .id] as $completed |
    
    [.plan.phases[].tasks[] |
      select(
        (.id as $id | $handled | index($id) | not) and
        (.dependencies | all(. as $dep | $completed | index($dep) != null))
      )
    ]
  ' "${PROJECT_FILE}"
}

# Get next task to execute
get_next_task() {
  local specific_task="${1:-}"
  
  if [[ -n "${specific_task}" ]]; then
    jq -r --arg id "${specific_task}" '
      .plan.phases[].tasks[] | select(.id == $id)
    ' "${PROJECT_FILE}"
  else
    get_available_tasks | jq -r '.[0] // empty'
  fi
}

# Get the best model for a task
get_best_model() {
  local role="$1"
  local task_type="$2"
  
  jq -r --arg role "${role}" --arg tt "${task_type}" '
    .rankings[$role][$tt][0] |
    "\(.agent) \(.model_id) \(.score)"
  ' "${RANKINGS_FILE}"
}

# Get next model for retry (fallback chain)
get_retry_model() {
  local role="$1"
  local task_type="$2"
  local attempt="$3"
  
  jq -r --arg role "${role}" --arg tt "${task_type}" --argjson idx "${attempt}" '
    .rankings[$role][$tt][$idx] |
    "\(.agent) \(.model_id) \(.score)"
  ' "${RANKINGS_FILE}" 2>/dev/null || echo ""
}

# Execute task with agent
execute_task() {
  local task_json="$1"
  local model_info="$2"
  
  # Parse task
  local task_id
  task_id=$(echo "${task_json}" | jq -r '.id')
  local role
  role=$(echo "${task_json}" | jq -r '.role')
  local task_type
  task_type=$(echo "${task_json}" | jq -r '.task_type')
  local description
  description=$(echo "${task_json}" | jq -r '.description')
  local files
  files=$(echo "${task_json}" | jq -r '.files | join(" ")')
  local dependencies
  dependencies=$(echo "${task_json}" | jq -r '.dependencies | join(" ")')
  
  # Parse model info
  local agent
  agent=$(echo "${model_info}" | cut -d' ' -f1)
  local model_id
  model_id=$(echo "${model_info}" | cut -d' ' -f2)
  local score
  score=$(echo "${model_info}" | cut -d' ' -f3)
  
  log "Executing task: ${task_id} (${role}/${task_type}) with ${agent}/${model_id}"
  
  # Build context from handoffs
  local context=""
  if [[ -n "${dependencies}" ]]; then
    context="Previous work:\n"
    for dep in ${dependencies}; do
      local handoff_file="${ORCH_DIR}/handoffs/${dep}.json"
      if [[ -f "${handoff_file}" ]]; then
        local dep_summary
        dep_summary=$(jq -r '.summary' "${handoff_file}" | head -c 300)
        context="${context}Task ${dep}: ${dep_summary}\n"
      fi
    done
  fi
  
  # Create prompt
  local prompt
  prompt=$(cat << EOF
You are a software developer working on a project.

Task: ${description}

${context:+${context}

}Files to work with:
${files}

Complete this task and provide:
1. A summary of what you did
2. Any files you created or modified
3. Any issues encountered

Be concise and focused on the task.
EOF
  )
  
  # Execute with the appropriate agent (timeout-wrapped so a hung combo
  # cannot block the whole run).
  local result=""
  local exit_code=0
  result=$(invoke_agent "${agent}" "${model_id}" "${prompt}") || exit_code=$?

  # Return result
  echo "${result}"
  return ${exit_code}
}

# Invoke an agent with a per-attempt timeout. Echoes combined output and
# returns the agent's exit code (124 if the timeout killed it).
invoke_agent() {
  local agent="$1" model_id="$2" prompt="$3"
  local out="" rc=0
  case "${agent}" in
    opencode)
      out=$(printf '%s' "${prompt}" | timeout "${ATTEMPT_TIMEOUT}" opencode run -m "${model_id}" --auto 2>&1) || rc=$?
      ;;
    kilo)
      out=$(timeout "${ATTEMPT_TIMEOUT}" kilo run -m "${model_id}" --auto "${prompt}" 2>&1) || rc=$?
      ;;
    hermes)
      out=$(timeout "${ATTEMPT_TIMEOUT}" hermes -m "${model_id}" -z "${prompt}" 2>&1) || rc=$?
      ;;
    *)
      echo "Error: Unknown agent: ${agent}"
      return 1
      ;;
  esac
  printf '%s' "${out}"
  return ${rc}
}

# Save task result
save_task_result() {
  local task_json="$1"
  local result="$2"
  local exit_code="$3"
  local model_info="$4"
  
  local task_id
  task_id=$(echo "${task_json}" | jq -r '.id')

  # Clean ANSI codes from stored output
  result=$(strip_ansi "${result}")
  
  # Determine status
  local status="done"
  if [[ ${exit_code} -ne 0 ]]; then
    status="failed"
  fi
  
  # Create task file
  jq -n \
    --argjson task "$(echo "${task_json}" | jq '.')" \
    --arg status "${status}" \
    --arg result "${result}" \
    --argjson exit_code "${exit_code}" \
    --arg model_info "${model_info}" \
    --arg executed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $task.id,
      role: $task.role,
      task_type: $task.task_type,
      description: $task.description,
      files: $task.files,
      dependencies: $task.dependencies,
      status: $status,
      result: {
        summary: $result[:500],
        exit_code: $exit_code,
        model: $model_info
      },
      executed_at: $executed_at
    }' > "${TASKS_DIR}/${task_id}.json"
  
  # Update project file (dedupe any prior entry for this task id)
  jq --arg id "${task_id}" --arg status "${status}" --arg result "${result}" '
    .tasks |= (map(select(.id != $id)) + [{
      id: $id,
      status: $status,
      result: {summary: $result[:500]},
      updated_at: (now | todate)
    }])
  ' "${PROJECT_FILE}" > "${PROJECT_FILE}.tmp" && mv "${PROJECT_FILE}.tmp" "${PROJECT_FILE}"
  
  # Capture handoff if task succeeded
  if [[ "${status}" == "done" ]]; then
    "${SCRIPT_DIR}/handoff.sh" "${task_id}" capture >/dev/null 2>&1 || true
  fi
}

# Update rankings based on result classification
update_rankings() {
  local task_json="$1"
  local classification="$2"
  local model_info="$3"
  
  local role
  role=$(echo "${task_json}" | jq -r '.role')
  local task_type
  task_type=$(echo "${task_json}" | jq -r '.task_type')
  local agent
  agent=$(echo "${model_info}" | cut -d' ' -f1)
  local model_id
  model_id=$(echo "${model_info}" | cut -d' ' -f2)
  
  # classification must be one of success|failure|rate_limited
  case "${classification}" in
    success|failure|rate_limited) ;;
    *) classification="failure" ;;
  esac
  
  "${SCRIPT_DIR}/promote.sh" "${role}" "${task_type}" "${model_id}" "${agent}" "${classification}" >/dev/null 2>&1 || true
}

# Execute task with agent-owned, provider-gap-aware fallback.
# The task is assigned to one agent (LRU + provider-spread via
# acquire_agent_for_task). Within the task, next_combo_for_task walks every
# distinct combo (best-untried, provider-gap-enforced) until one succeeds or all
# are exhausted. A rate-limited combo is classified as rate_limited and the next
# combo is tried immediately -- never failing unless absolutely every combo fails.
execute_with_retry() {
  local task_json="$1"
  local task_id
  task_id=$(echo "${task_json}" | jq -r '.id')
  local role
  role=$(echo "${task_json}" | jq -r '.role')
  local task_type
  task_type=$(echo "${task_json}" | jq -r '.task_type')

  init_agent_state

  # Assign this task to an agent (atomic under lock: spreads load across agents
  # and avoids re-hitting the provider just used by another task).
  local assigned
  assigned=$(acquire_agent_for_task "$role" "$task_type") || assigned=""
  if [[ -z "${assigned}" ]]; then
    log "Task ${task_id}: no agents available for ${role}/${task_type}"
    save_task_result "${task_json}" "No agents available for ${role}/${task_type}" 1 ""
    return 1
  fi
  log "Task ${task_id}: assigned agent ${assigned}"

  # Total combos available for this role/task_type (the exhaustion ceiling).
  local total
  total=$(jq -r --arg role "$role" --arg tt "$task_type" '
    (.rankings[$role][$tt] // []) | length' "${RANKINGS_FILE}")
  total=${total:-0}

  local TRIED_KEYS=()
  local ASSIGNED_AGENT="$assigned"
  local LAST_PROVIDER=""
  local success=false
  local last_model=""
  local attempt=0
  local start_ts
  start_ts=$(date +%s)

  while [[ ${attempt} -lt ${total} ]]; do
    # Global budget guard: stop the exhaustive loop if we blow the time budget.
    if [[ "${TASK_TIMEOUT}" -gt 0 ]]; then
      local now_ts elapsed
      now_ts=$(date +%s)
      elapsed=$((now_ts - start_ts))
      if [[ ${elapsed} -ge ${TASK_TIMEOUT} ]]; then
        log "Task ${task_id}: TASK_TIMEOUT (${TASK_TIMEOUT}s) exceeded after ${attempt} attempts"
        break
      fi
    fi

    local model_info
    model_info=$(next_combo_for_task "$role" "$task_type")

    if [[ -z "${model_info}" ]]; then
      log "No untried models remain for ${role}/${task_type}"
      break
    fi

    local a_id m_id
    a_id=$(echo "${model_info}" | cut -d' ' -f1)
    m_id=$(echo "${model_info}" | cut -d' ' -f2)
    # Track tried combos by "agent model_id" (no score) so next_combo_for_task's
    # filter matches exactly. This is what lets a task spill to other agents once
    # its assigned agent's combos are exhausted.
    TRIED_KEYS+=("${a_id} ${m_id}")
    last_model="${model_info}"
    attempt=$((attempt + 1))
    LAST_PROVIDER=$(combo_provider "${a_id} ${m_id}" "$role" "$task_type")
    mark_provider_used "${assigned}" "${LAST_PROVIDER}"

    log "Attempt ${attempt}/${total} for task ${task_id}: ${model_info} (provider ${LAST_PROVIDER})"

    # Execute task
    local result
    local exit_code=0
    result=$(execute_task "${task_json}" "${model_info}") || exit_code=$?

    # Classify outcome (catches credit/rate-limit errors that exit 0).
    local classification
    classification=$(classify_result "${result}" "${exit_code}")

    update_rankings "${task_json}" "${classification}" "${model_info}"

    if [[ "${classification}" == "success" ]]; then
      success=true
      save_task_result "${task_json}" "${result}" 0 "${model_info}"
      log "Task ${task_id}: SUCCESS on attempt ${attempt}"
      break
    else
      log "Task ${task_id}: ${classification} on attempt ${attempt} (trying next combo)"
      # Back off before retrying, especially after a rate-limit, so we don't pile
      # up in-flight requests on the same provider (the original rate-limit cause).
      if [[ "${classification}" == "rate_limited" && ${attempt} -lt ${total} ]]; then
        local ra delay
        ra=$(retry_after_from "${result}")
        delay=$(next_backoff "${attempt}" "${ra}")
        # Respect the global task budget: never sleep past TASK_TIMEOUT.
        if [[ "${TASK_TIMEOUT}" -gt 0 && "${delay}" -gt 0 ]]; then
          local now_ts elapsed
          now_ts=$(date +%s); elapsed=$((now_ts - start_ts))
          if [[ $((elapsed + delay)) -ge ${TASK_TIMEOUT} ]]; then
            log "Task ${task_id}: skipping backoff (would exceed TASK_TIMEOUT)"
            delay=0
          fi
        fi
        if [[ "${delay}" -gt 0 ]]; then
          log "Task ${task_id}: backing off ${delay}s before next attempt"
          sleep "${delay}"
        fi
      fi
    fi
  done

  mark_agent_end "${assigned}"

  if [[ "${success}" == "false" ]]; then
    log "Task ${task_id}: FAILED after exhausting all ${total} model combinations"
    save_task_result "${task_json}" "Failed after exhausting all ${total} model combinations" 1 "${last_model:-unknown}"
    return 1
  fi

  return 0
}

# Execute tasks in parallel
run_parallel() {
  local max_parallel="$1"
  local pids=()
  local task_ids=()
  local running=0
  
  log "Starting parallel execution (max: ${max_parallel})"
  
  while true; do
    # Check for completed background tasks
    for i in "${!pids[@]}"; do
      if ! kill -0 "${pids[$i]}" 2>/dev/null; then
        wait "${pids[$i]}" 2>/dev/null || true
        unset "pids[$i]"
        unset "task_ids[$i]"
        running=$((running - 1))
      fi
    done
    
    # Get available tasks
    local available
    available=$(get_available_tasks)
    local available_count
    available_count=$(echo "${available}" | jq 'length')
    
    if [[ ${available_count} -eq 0 && ${running} -eq 0 ]]; then
      log "No more tasks to execute"
      break
    fi
    
    # Start new tasks if we have capacity
    while [[ ${running} -lt ${max_parallel} && ${available_count} -gt 0 ]]; do
      local next_task
      next_task=$(echo "${available}" | jq -r '.[0]')
      
      if [[ -z "${next_task}" || "${next_task}" == "null" ]]; then
        break
      fi
      
      local task_id
      task_id=$(echo "${next_task}" | jq -r '.id')
      
      # Check if task is already running
      if [[ " ${task_ids[*]:-} " =~ " ${task_id} " ]]; then
        available=$(echo "${available}" | jq '.[1:]')
        available_count=$((available_count - 1))
        continue
      fi
      
      log "Starting task ${task_id} in background"
      
      # Execute task in background
      (
        execute_with_retry "${next_task}"
      ) &
      
      pids+=($!)
      task_ids+=("${task_id}")
      running=$((running + 1))
      
      # Remove from available
      available=$(echo "${available}" | jq '.[1:]')
      available_count=$((available_count - 1))
    done
    
    # Wait a bit before checking again
    if [[ ${running} -gt 0 ]]; then
      sleep 2
    fi
  done
  
  log "All tasks completed"
}

# Execute all tasks sequentially
run_all_tasks() {
  log "Starting sequential task execution..."
  
  local task_count=0
  local success_count=0
  local fail_count=0
  
  while true; do
    local next_task
    next_task=$(get_next_task)
    
    if [[ -z "${next_task}" ]]; then
      log "No more tasks to execute"
      break
    fi
    
    local task_id
    task_id=$(echo "${next_task}" | jq -r '.id')
    
    echo "" >&2
    echo "=== Task ${task_id} ===" >&2
    
    if execute_with_retry "${next_task}"; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
    
    task_count=$((task_count + 1))
  done
  
  echo "" >&2
  echo "=== Execution Complete ===" >&2
  echo "Total tasks: ${task_count}" >&2
  echo "Success: ${success_count}" >&2
  echo "Failed: ${fail_count}" >&2
}

# Resume interrupted project
resume_project() {
  log "Resuming project..."
  
  # Find failed or incomplete tasks
  local incomplete_tasks
  incomplete_tasks=$(jq -r '
    [.plan.phases[].tasks[].id] as $all_tasks |
    [.tasks[] | select(.status == "failed") | .id] as $failed |
    
    [.plan.phases[].tasks[] |
      select(.id as $id | $failed | index($id))
    ]
  ' "${PROJECT_FILE}")
  
  local count
  count=$(echo "${incomplete_tasks}" | jq 'length')
  
  if [[ ${count} -eq 0 ]]; then
    log "No incomplete tasks found"
    return
  fi
  
  log "Found ${count} incomplete tasks"
  
  # Execute each incomplete task
  echo "${incomplete_tasks}" | jq -c '.[]' | while read -r task_json; do
    local task_id
    task_id=$(echo "${task_json}" | jq -r '.id')
    
    echo "" >&2
    echo "=== Resuming Task ${task_id} ===" >&2
    
    execute_with_retry "${task_json}"
  done
}

# Main
main() {
  local mode="${1:-}"
  
  # Debug: classify a result piped via stdin without needing project state.
  if [[ "${mode}" == "--classify" ]]; then
    local input
    input=$(cat)
    classify_result "${input}" "${CLASSIFY_EXIT_CODE:-0}"
    return
  fi

  # Debug: compute a backoff delay without running anything (pure function).
  if [[ "${mode}" == "--backoff" ]]; then
    next_backoff "${2:-1}" "${3:-}"
    return
  fi

  # Debug: extract a Retry-After value from a result piped via stdin.
  if [[ "${mode}" == "--retry-after" ]]; then
    retry_after_from "$(cat)"
    return
  fi

  check_deps
  preflight_check
  
  log "Task runner starting..."
  log "Project: $(jq -r '.info.name' "${PROJECT_FILE}")"
  
  case "${mode}" in
    --resume)
      resume_project
      ;;
    --parallel)
      local max_parallel="${2:-2}"
      run_parallel "${max_parallel}"
      ;;
    --status)
      # Show project status
      jq -r '
        "Project: \(.info.name)",
        "Status: \(.status)",
        "Tasks completed: \(.tasks | length)",
        "Tasks total: \([.plan.phases[].tasks | length] | add)"
      ' "${PROJECT_FILE}"
      ;;
    *)
      if [[ -n "${mode}" && "${mode}" != "--"* ]]; then
        # Execute specific task
        local next_task
        next_task=$(get_next_task "${mode}")
        
        if [[ -z "${next_task}" ]]; then
          echo "Error: Task ${mode} not found" >&2
          exit 1
        fi
        
        execute_with_retry "${next_task}"
      else
        # Execute all tasks sequentially
        run_all_tasks
      fi
      ;;
  esac
}

main "$@"
