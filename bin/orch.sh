#!/usr/bin/env bash
set -euo pipefail

# orch.sh - run a task graph in ONE project, with crash-safe resume.
#
# State is split deliberately:
#
#   <project>/.orch/          run journal, task graph, results  -- PER PROJECT
#   ~/.local/state/free-agents/  buckets, health, model stats   -- GLOBAL
#
# What is LEARNED about a wallet is true for every project, so it is global.
# What a RUN is doing belongs to the project, so two projects can be in flight
# at once and deleting one loses nothing. The old orchestrator kept run state in
# its own install directory, which is why only one project could ever run.
#
#   usage:
#     orch.sh init                     create .orch/ here
#     orch.sh run TASKS.json [--max-parallel N] [--dry-run]
#     orch.sh resume [--max-parallel N]     re-dispatch whatever is unfinished
#     orch.sh status                   progress from the journal
#
#   TASKS.json:
#     { "tasks": [
#         { "id": "api",
#           "prompt": "self-contained spec...",
#           "deps": [],                       # ids that must finish first
#           "files": ["src/api.js"],          # boundary: overlapping tasks
#                                             # never run concurrently
#           "category": "coding" } ] }
#
# Exit: 0 all tasks done | 1 some task failed | 3 setup error

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG=orch
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
# shellcheck source=lib/findings.sh
. "${HERE}/lib/findings.sh"

RUN_SH="${HERE}/run.sh"
PROJECT="${ORCH_PROJECT:-$(pwd)}"
ORCH_DIR="${PROJECT}/.orch"
JOURNAL="${ORCH_DIR}/journal.ndjson"
JOURNAL_LOCK="${ORCH_DIR}/.journal.lock"
RESULTS="${ORCH_DIR}/results"
HANDOFFS="${ORCH_DIR}/handoffs"
TASKS_FILE="${ORCH_DIR}/tasks.json"

MAX_PARALLEL=""
DRY_RUN=0
TASK_RETRIES="${TASK_RETRIES:-2}"      # retries after a real failure
LANE_WAIT="${LANE_WAIT:-5}"            # seconds to wait when every lane is busy

# ------------------------------------------------------------------ journal --
# Append-only, one JSON object per line, flushed under flock. Crash safety comes
# from this being append-only: a half-written run is just a journal that stops,
# and replaying it always yields the same completed set.
journal() { # $1=event $2=task ; remaining: k=v pairs
  local event="$1" task="$2"; shift 2
  local extra="{}" kv k v
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"
    extra="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$extra")"
  done
  mkdir -p "$ORCH_DIR"
  ( flock -w 10 9 || return 0
    jq -cn --arg ts "$(iso_now)" --arg e "$event" --arg t "$task" --argjson x "$extra" \
      '{ts:$ts, event:$e, task:$t} + $x' >> "$JOURNAL"
  ) 9>"$JOURNAL_LOCK"
}

# Tasks that reached a terminal success, derived by REPLAY. The journal is the
# only source of truth for what is done - never a mutable status field, which is
# exactly the thing a crash can leave lying.
completed_tasks() {
  [[ -f "$JOURNAL" ]] || return 0
  jq -r 'select(.event == "done") | .task' "$JOURNAL" 2>/dev/null | sort -u
}
failed_tasks() {
  [[ -f "$JOURNAL" ]] || return 0
  jq -r 'select(.event == "failed") | .task' "$JOURNAL" 2>/dev/null | sort -u
}

# --------------------------------------------------------------- scheduling --
# Parallel width is DERIVED from how many wallets are actually healthy, never a
# constant. On one healthy bucket, concurrency buys nothing and only produces
# rate-limit collisions; on five, a fixed 2 wastes three lanes.
# How many lanes are free RIGHT NOW - i.e. healthy and not currently leased by
# another task. Dispatching more tasks than this is what produced the churn: a
# task would launch, find every wallet busy, exit 5, sleep, and repeat (observed:
# 9 requeues for one task). Checking first means we simply do not launch it.
free_lanes() {
  local dir="${FREE_AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/free-agents}/leases"
  local n=0 b f
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    f="${dir}/$(printf '%s' "$b" | tr '/:' '__').lock"
    # No lock file yet means nobody has ever leased it, so it is free.
    if [[ ! -e "$f" ]]; then n=$((n+1)); continue; fi
    # flock -n succeeds only if the lane is unheld; the subshell drops it at once.
    if ( exec 9<>"$f"; flock -n 9 ) 2>/dev/null; then n=$((n+1)); fi
  done < <(registry_read '.buckets | keys[]' 2>/dev/null)
  printf '%s' "$n"
}

healthy_buckets() {
  local now; now="$(now_epoch)"
  registry_read '[ .buckets[]
    | select((.health.cooldown_until // 0) <= ($now|tonumber))
    | select([.models[] | select(.free)] | length > 0) ] | length' --arg now "$now" 2>/dev/null || echo 1
}

task_field() { jq -r --arg id "$1" --arg k "$2" '.tasks[] | select(.id==$id) | .[$k] // empty' "$TASKS_FILE"; }
task_ids()   { jq -r '.tasks[].id' "$TASKS_FILE"; }
task_files() { jq -r --arg id "$1" '.tasks[] | select(.id==$id) | (.files // [])[]' "$TASKS_FILE"; }
task_deps()  { jq -r --arg id "$1" '.tasks[] | select(.id==$id) | (.deps  // [])[]' "$TASKS_FILE"; }

# ---------------------------------------------------------------- handoffs --
# A worker is isolated by design: it sees its own spec and nothing else. That is
# what makes weak models succeed, but it means a task cannot learn what the task
# it DEPENDS ON decided - only what file that task left behind. An interface
# choice, a version pin, a rejected approach: all invisible.
#
# The cheap fix, and the whole of it: a task that has dependents is asked to end
# its output with one marked line. That line - and only that line - is given to
# the tasks that declared it as a dependency.
#
# Deliberately NOT a summariser: no extra model call, no lane spent, and no
# second-hand account of work by an agent whose self-report we already decided
# not to trust. If a worker writes nothing, everything degrades to the old
# behaviour.
HANDOFF_MARK="---HANDOFF---"
HANDOFF_MAX_CHARS="${HANDOFF_MAX_CHARS:-320}"

# Tasks that declare $1 as a dependency.
dependents_of() { # $1=task id
  jq -r --arg id "$1" '.tasks[] | select((.deps // []) | index($id)) | .id' "$TASKS_FILE"
}

# Pull the marked line out of a finished task's output and store it.
capture_handoff() { # $1=task id
  local id="$1" out="${RESULTS}/${id}.out" line
  [[ -f "$out" ]] || return 0
  line="$(grep -a "^${HANDOFF_MARK}" "$out" 2>/dev/null | tail -1 || true)"
  line="${line#"$HANDOFF_MARK"}"
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && return 0
  mkdir -p "$HANDOFFS"
  printf '%.'"$HANDOFF_MAX_CHARS"'s' "$line" > "${HANDOFFS}/${id}.txt"
  journal handoff "$id" "chars=${#line}"
}

# Build what a worker actually receives: its dependencies' handoffs, then its own
# spec, then (only if something depends on it) the request for a handoff back.
build_prompt() { # $1=task id
  local id="$1" d ctx="" note h
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    h="$(cat "${HANDOFFS}/${d}.txt" 2>/dev/null || true)"
    [[ -n "$h" ]] && ctx+="- ${d}: ${h}"$'\n'
  done < <(task_deps "$id")
  [[ -n "$ctx" ]] && ctx="Context from the tasks you depend on (already finished):"$'\n'"${ctx}"$'\n'

  if [[ -n "$(dependents_of "$id")" ]]; then
    note=$'\n\n'"Other tasks depend on this one. End your reply with a single line:"$'\n'
    note+="${HANDOFF_MARK} <one sentence: decisions, names or constraints the next task must match>"
  fi
  printf '%s%s%s' "$ctx" "$(task_field "$id" prompt)" "${note:-}"
}

# Two tasks that touch the same file must not run at once, however many lanes are
# free. The coordinator contract promises disjoint boundaries; this enforces it
# rather than trusting it.
files_conflict() { # $1=task, rest: currently-running task ids
  local id="$1"; shift
  local mine other running
  mine="$(task_files "$id" | sort -u)"
  [[ -z "$mine" ]] && return 1
  for running in "$@"; do
    other="$(task_files "$running" | sort -u)"
    [[ -z "$other" ]] && continue
    if [[ -n "$(comm -12 <(printf '%s\n' "$mine") <(printf '%s\n' "$other"))" ]]; then
      return 0
    fi
  done
  return 1
}

deps_met() { # $1=task
  local d; local done_list; done_list="$(completed_tasks)"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    grep -qxF "$d" <<<"$done_list" || return 1
  done < <(task_deps "$1")
  return 0
}

# --------------------------------------------------------------- execution --
run_task() { # $1=task id ; runs in a subshell as a background job
  local id="$1" prompt category out rc=0 meta
  prompt="$(build_prompt "$id")"
  category="$(task_field "$id" category)"; category="${category:-general}"
  out="${RESULTS}/${id}.out"; mkdir -p "$RESULTS"

  journal started "$id"
  set +e
  "$RUN_SH" -c "$category" -w "$PROJECT" "$prompt" \
    >"$out" 2>"${RESULTS}/${id}.err"
  rc=$?
  set -e
  meta="$(sed -n 's/^---RUN-META--- //p' "${RESULTS}/${id}.err" | tail -1)"

  # VERIFY, do not trust. An agent reporting success is not evidence the work
  # happened: models have claimed to create a file and written it elsewhere, or
  # not at all. If the task declared files, they must exist in the project.
  if [[ $rc -eq 0 ]]; then
    local missing=() f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -e "${PROJECT}/${f}" ]] || missing+=("$f")
    done < <(task_files "$id")
    if [[ ${#missing[@]} -gt 0 ]]; then
      journal unverified "$id" "missing=${missing[*]}"
      log "unverified $id: declared but absent: ${missing[*]}"
      # Once is a bad draw. Twice on the same task is a signal about the SPEC or
      # the models, and it is the kind of thing a real project notices that a
      # test suite never will.
      if [[ $(grep -c "\"event\":\"unverified\",\"task\":\"${id}\"" "$JOURNAL" 2>/dev/null || echo 0) -ge 2 ]]; then
        record_finding unverified_repeat \
          "task claimed success without producing its files, more than once" \
          "task=${id} declared=${missing[*]}" "task=${id}"
      fi
      return 1
    fi
  fi

  [[ $rc -eq 0 ]] && capture_handoff "$id"

  case $rc in
    0) journal done "$id" \
         "bucket=$(jq -r '.bucket // ""' <<<"${meta:-{\}}")" \
         "model=$(jq -r '.model // ""' <<<"${meta:-{\}}")" \
         "agent=$(jq -r '.agent // ""' <<<"${meta:-{\}}")" ;;
    5) journal no_lane "$id" ;;          # not a failure: requeue
    *) journal attempt_failed "$id" "rc=$rc" ;;
  esac
  return $rc
}

cmd_run() {
  [[ -f "$TASKS_FILE" ]] || die "no task graph at $TASKS_FILE"
  jq -e '.tasks | type == "array" and length > 0' "$TASKS_FILE" >/dev/null \
    || die "$TASKS_FILE has no tasks"

  write_orch_gitignore
  local width="${MAX_PARALLEL:-$(healthy_buckets)}"
  [[ "$width" -ge 1 ]] || width=1
  log "project=$PROJECT  parallel=$width (healthy buckets)"

  declare -A ATTEMPTS=() PIDS=() RUNNING=() LANEWAIT=()
  local todo remaining id pid finished progressed

  while :; do
    todo=""; remaining=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      grep -qxF "$id" <<<"$(completed_tasks)" && continue
      grep -qxF "$id" <<<"$(failed_tasks)"    && continue
      remaining=$((remaining+1))
      todo+="$id"$'\n'
    done < <(task_ids)
    [[ $remaining -eq 0 ]] && break

    progressed=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      [[ -n "${RUNNING[$id]:-}" ]] && continue
      [[ ${#RUNNING[@]} -ge $width ]] && break
      # Never dispatch into a full house. Without this the task launches only to
      # discover every wallet is busy, and burns a cycle finding out.
      if [[ $DRY_RUN -eq 0 && ${#RUNNING[@]} -gt 0 ]]; then
        [[ "$(free_lanes)" -gt 0 ]] || break
      fi
      deps_met "$id" || continue
      files_conflict "$id" "${!RUNNING[@]}" && continue

      if [[ $DRY_RUN -eq 1 ]]; then
        printf 'would run: %-14s deps=[%s] files=[%s]\n' "$id" \
          "$(task_deps "$id" | tr '\n' ' ')" "$(task_files "$id" | tr '\n' ' ')"
        RUNNING[$id]=dry; continue
      fi
      run_task "$id" & PIDS[$id]=$!; RUNNING[$id]=1
      log "dispatch $id (pid ${PIDS[$id]})"
      progressed=1
    done <<<"$todo"

    if [[ $DRY_RUN -eq 1 ]]; then break; fi

    if [[ ${#RUNNING[@]} -eq 0 ]]; then
      # Nothing runnable: a dependency cycle, a dependency on a task id that does
      # not exist, or everything left is waiting on something that failed.
      # Record it - the journal is the only account of a run, and a stall that
      # leaves it empty tells a later reader nothing.
      local blocked; blocked="$(printf '%s' "$todo" | tr '\n' ' ' | sed 's/ *$//')"
      journal deadlock "-" "blocked=${blocked}" "remaining=${remaining}"
      record_finding deadlock "a task graph could not progress" \
        "blocked: ${blocked}" "remaining=${remaining}"
      log "deadlock: $remaining task(s) left, none runnable: ${blocked}"
      log "  (dependency cycle, unknown dependency id, or a failed prerequisite)"
      return 1
    fi

    # Reap one finished child, then re-plan.
    finished=""
    for id in "${!RUNNING[@]}"; do
      pid="${PIDS[$id]}"
      if ! kill -0 "$pid" 2>/dev/null; then finished="$id"; break; fi
    done
    if [[ -z "$finished" ]]; then sleep 1; continue; fi

    set +e; wait "${PIDS[$finished]}"; rc=$?; set -e
    unset 'RUNNING[$finished]' 'PIDS[$finished]'

    if [[ $rc -eq 0 ]]; then
      unset 'LANEWAIT[$finished]'
      log "done $finished"
    elif [[ $rc -eq 5 ]]; then
      # All lanes were busy. Nothing was tried, so this costs no retry budget -
      # but back off so a task that keeps losing the race does not spin.
      LANEWAIT[$finished]=$(( ${LANEWAIT[$finished]:-0} + 1 ))
      local w=$(( LANE_WAIT * (1 << (${LANEWAIT[$finished]} > 4 ? 4 : ${LANEWAIT[$finished]} - 1)) ))
      [[ $w -gt ${LANE_WAIT_MAX:-60} ]] && w=${LANE_WAIT_MAX:-60}
      log "requeue $finished (no lane free; waiting ${w}s)"
      sleep "$w"
    else
      ATTEMPTS[$finished]=$(( ${ATTEMPTS[$finished]:-0} + 1 ))
      if [[ ${ATTEMPTS[$finished]} -gt $TASK_RETRIES ]]; then
        journal failed "$finished" "attempts=${ATTEMPTS[$finished]}"
        log "FAILED $finished after ${ATTEMPTS[$finished]} attempt(s)"
      else
        log "retry $finished (${ATTEMPTS[$finished]}/$TASK_RETRIES)"
      fi
    fi
  done

  local nfail; nfail="$(failed_tasks | grep -c . || true)"
  log "complete: $(completed_tasks | grep -c . || true) done, ${nfail} failed"
  # Surface anything the tool noticed about ITSELF during this run, so a real
  # project can feed a fix back rather than the observation dying with the run.
  local nnew; nnew="$(findings_count new 2>/dev/null || echo 0)"
  if [[ "${nnew:-0}" -gt 0 ]]; then
    log ""
    log "${nnew} new finding(s) from this run - things the tool handled badly:"
    findings_show new 2>/dev/null | sed 's/^/  /' | head -12 >&2
    log "review with: fa findings     file one with: fa findings --issue"
  fi
  [[ "$nfail" -eq 0 ]]
}

cmd_status() {
  [[ -f "$JOURNAL" ]] || { echo "no journal at $JOURNAL"; return 0; }
  local total done_n fail_n
  total="$( [[ -f "$TASKS_FILE" ]] && task_ids | grep -c . || echo '?')"
  done_n="$(completed_tasks | grep -c . || true)"
  fail_n="$(failed_tasks | grep -c . || true)"
  printf 'project: %s\n%s/%s done, %s failed\n\n' "$PROJECT" "$done_n" "$total" "$fail_n"
  jq -r 'select(.event=="done")
         | "  done    \(.task)  <- \(.bucket // "?")  \(.model // "")"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="failed") | "  FAILED  \(.task)"' "$JOURNAL" | sort -u
  # A deadlocked run leaves tasks that will never become runnable. Listing them
  # as "pending" reads as "waiting its turn", which is the wrong thing to
  # believe - nothing is going to move without a change to the graph.
  jq -r 'select(.event=="deadlock")
         | "  BLOCKED  \(.blocked // "?")  (cycle, unknown dependency id, or a failed prerequisite)"' \
     "$JOURNAL" 2>/dev/null | tail -1
  if [[ -f "$TASKS_FILE" ]]; then
    local d; d="$(completed_tasks)"; local f; f="$(failed_tasks)"
    while IFS= read -r id; do
      grep -qxF "$id" <<<"$d" && continue
      grep -qxF "$id" <<<"$f" && continue
      echo "  pending $id"
    done < <(task_ids)
  fi
}

# What of .orch/ belongs in the PROJECT's git:
#   tasks.json      YES - it is the specification, and it is what makes a run
#                   repeatable on someone else's machine (with their own lanes).
#   journal.ndjson  NO  - a record of what happened on ONE machine. Committing it
#                   guarantees conflicts and reproduces nothing: which wallet
#                   served a task is not a property of the project.
#   results/        NO  - raw agent transcripts.
write_orch_gitignore() {
  mkdir -p "$ORCH_DIR"
  [[ -f "${ORCH_DIR}/.gitignore" ]] && return 0
  cat > "${ORCH_DIR}/.gitignore" <<'EOF'
# Commit tasks.json - it is the specification, and it travels between machines.
# Everything else here is a record of one machine's run.
journal.ndjson
results/
handoffs/
*.lock
EOF
}

cmd_init() {
  mkdir -p "$ORCH_DIR" "$RESULTS"
  [[ -f "$TASKS_FILE" ]] || echo '{"tasks":[]}' > "$TASKS_FILE"
  write_orch_gitignore
  echo "initialised $ORCH_DIR"
}

usage() { sed -n '6,32p' "$0" >&2; exit 3; }

CMD="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) # a positional after `run` is the task graph to install
       if [[ "$CMD" == "run" ]]; then
         mkdir -p "$ORCH_DIR"
         # bin/plan.sh writes straight to .orch/tasks.json, so the argument is
         # frequently the destination itself - copying it over itself fails.
         if [[ "$(readlink -f "$1")" != "$(readlink -f "$TASKS_FILE")" ]]; then
           cp "$1" "$TASKS_FILE"
         fi
       fi; shift ;;
  esac
done

case "$CMD" in
  init)   cmd_init ;;
  run)    cmd_run ;;
  resume) log "resuming from journal"; cmd_run ;;   # replay-derived, so identical
  status) cmd_status ;;
  *) usage ;;
esac
