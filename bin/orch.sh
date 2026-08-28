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

RUN_SH="${HERE}/run.sh"
PROJECT="${ORCH_PROJECT:-$(pwd)}"
ORCH_DIR="${PROJECT}/.orch"
JOURNAL="${ORCH_DIR}/journal.ndjson"
JOURNAL_LOCK="${ORCH_DIR}/.journal.lock"
RESULTS="${ORCH_DIR}/results"
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
  prompt="$(task_field "$id" prompt)"
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
      return 1
    fi
  fi

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

  declare -A ATTEMPTS=() PIDS=() RUNNING=()
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
      # Nothing runnable: either a dependency cycle, or everything left is
      # blocked on a file boundary held by a task that already failed.
      log "deadlock: $remaining task(s) left, none runnable"
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
      log "done $finished"
    elif [[ $rc -eq 5 ]]; then
      # All lanes were busy. Nothing was tried, so this costs no retry budget.
      log "requeue $finished (no lane free)"
      sleep "$LANE_WAIT"
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
