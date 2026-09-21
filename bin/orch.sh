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
#     orch.sh run TASKS.json [--max-parallel N] [--dry-run] [--validate] [--isolate]
#     orch.sh resume [--max-parallel N] [--dry-run] [--validate] [--isolate]     re-dispatch whatever is unfinished
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
# shellcheck source=lib/analyze.sh
. "${HERE}/lib/analyze.sh"

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
VALIDATE=0
ISOLATE=0
TASK_RETRIES="${TASK_RETRIES:-2}"      # retries after a real failure
LANE_WAIT="${LANE_WAIT:-5}"            # seconds to wait when every lane is busy

# Project mode: read from .orch/config.yaml
project_mode() {
  local config="${ORCH_DIR}/config.yaml"
  [[ -f "$config" ]] || { echo "strict"; return; }
  grep -E '^mode:' "$config" 2>/dev/null | head -1 | sed 's/mode:[[:space:]]*//'
}

project_automerge() {
  local config="${ORCH_DIR}/config.yaml"
  [[ -f "$config" ]] || { echo "false"; return; }
  grep -E '^automerge:' "$config" 2>/dev/null | head -1 | sed 's/automerge:[[:space:]]*//'
}

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
# A task a "when" clause elsewhere decided not to run - terminal, like done
# or failed, but neither: nothing was attempted and nothing was wrong.
skipped_tasks() {
  [[ -f "$JOURNAL" ]] || return 0
  jq -r 'select(.event == "skipped") | .task' "$JOURNAL" 2>/dev/null | sort -u
}

# ------------------------------------------------------------------ orphans --
# Killing the orchestrator does not kill the children it already forked -
# run_task() keeps running to completion on its own, independent of its
# parent, and writes its own journal events regardless. A naive resume has no
# memory of this (RUNNING/PIDS are fresh, empty maps on every invocation) and
# would dispatch a brand-new run_task() for the same id while the orphan is
# still out there - both writing to the same ${RESULTS}/<id>.out/.err files,
# and, if isolated, colliding on the same git worktree branch name.
#
# The last event journaled for a task, whatever it is. An un-terminated
# "started" (nothing after it) means the invocation that logged it either is
# STILL running or died without ever reporting back - which one determines
# whether redispatching is safe, and the journal alone cannot say; see
# orphan_alive_pid below.
last_event_for() { # $1=id -> event name, or empty
  [[ -f "$JOURNAL" ]] || return 0
  jq -r --arg t "$1" 'select(.task == $t) | .event' "$JOURNAL" 2>/dev/null | tail -1
}

# If task $1's last event is an un-terminated "started" AND the PID it
# recorded is still alive, print that PID (so the caller knows not to
# redispatch). Prints nothing for an old journal with no pid field either -
# there is nothing to check liveness against, so this degrades to the
# pre-existing behaviour rather than blocking dispatch forever.
orphan_alive_pid() { # $1=id -> pid, or empty
  [[ "$(last_event_for "$1")" == "started" ]] || return 0
  local pid
  pid="$(jq -r --arg t "$1" \
        'select(.task == $t and .event == "started") | .pid // empty' \
        "$JOURNAL" 2>/dev/null | tail -1)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
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

# A task can be blocked on something no agent can supply - third-party
# credentials, a service that is not provisioned yet, a decision only the user
# can make. Dispatching it wastes lane attempts, fails verification, and then
# deadlocks everything downstream. It is not a failure; it is a pause.
task_blocked() { # $1=id -> reason, or empty
  jq -r --arg id "$1" '.tasks[] | select(.id==$id) | .blocked // empty' "$TASKS_FILE"
}

# Blocked itself, or waiting on something that is.
# NOTE the visited set. Without it this recurses forever on a dependency cycle -
# and a cycle is a graph this tool explicitly supports detecting, so the guard is
# not defensive, it is required. An unguarded version hung instead of reporting a
# deadlock, which is strictly worse than the behaviour it replaced.
is_halted() { # $1=id  $2=visited (internal)
  local seen=" ${2:-} "
  case "$seen" in *" $1 "*) return 1 ;; esac
  [[ -n "$(task_blocked "$1")" ]] && return 0
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    is_halted "$d" "${2:-} $1" && return 0
  done < <(task_deps "$1")
  return 1
}

halted_tasks() {
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    is_halted "$id" && printf '%s\n' "$id"
  done < <(task_ids)
}

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
HANDOFF_MAX_CHARS="${HANDOFF_MAX_CHARS:-800}"

# Tasks that declare $1 as a dependency.
dependents_of() { # $1=task id
  jq -r --arg id "$1" '.tasks[] | select((.deps // []) | index($id)) | .id' "$TASKS_FILE"
}

# True if any OTHER task's "when" clause reads this task's result - only
# then is it worth asking this task to emit a result: line at all (see
# build_prompt()). No point requesting a field nobody reads.
task_needs_result() { # $1=id
  jq -e --arg id "$1" '.tasks[] | select((.when.dep // "") == $id)' "$TASKS_FILE" >/dev/null 2>&1
}

# A task's "when" clause: {"dep":"<id>","path":"<jq path, e.g. .decision>",
# "equals":"<value>"}. Optional - absent means "always run", unchanged
# behaviour. Evaluated against the named dependency's captured result (see
# capture_handoff) - a dependency that reported no result, or a malformed
# one, reads as {} here, same as everywhere else this degrades rather than
# crashes. A malformed "when" clause itself (missing dep or path) never
# blocks dispatch over a spec error - that is what plan.sh's own validation
# is for, not a runtime hang.
when_satisfied() { # $1=id -> 0 if satisfied (or no when clause at all)
  local id="$1" w dep path want result got
  w="$(task_field "$id" when)"
  [[ -z "$w" ]] && return 0
  dep="$(jq -r '.dep // empty' <<<"$w" 2>/dev/null)"
  path="$(jq -r '.path // empty' <<<"$w" 2>/dev/null)"
  want="$(jq -r '.equals // empty' <<<"$w" 2>/dev/null)"
  [[ -z "$dep" || -z "$path" ]] && return 0
  result="$(cat "${HANDOFFS}/${dep}.result.json" 2>/dev/null || true)"
  [[ -z "$result" ]] && result='{}'
  jq -e . <<<"$result" >/dev/null 2>&1 || result='{}'
  got="$(jq -r "${path} // empty" <<<"$result" 2>/dev/null || true)"
  [[ "$got" == "$want" ]]
}

# Pull the marked block out of a finished task's output and store it.
# Supports the structured format:
#   ---HANDOFF---
#   decisions: ...
#   rejected: ...
#   open: ...
# Or the legacy one-line format (still works).
capture_handoff() { # $1=task id
  local id="$1" out="${RESULTS}/${id}.out" block
  [[ -f "$out" ]] || return 0

  # Extract everything after the last ---HANDOFF--- marker
  block="$(awk -v mark="$HANDOFF_MARK" '
    $0 ~ mark { found=1; next }
    found { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "$out")"

  block="$(printf '%s' "$block" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//')"

  if [[ -z "$block" ]]; then
    if [[ -n "$(dependents_of "$id")" ]]; then
      record_finding missing_handoff \
        "a task with dependents ended without the handoff block it was asked for" \
        "task=${id} dependents=$(dependents_of "$id" | tr '\n' ' ')" "task=${id}"
    fi
    return 0
  fi

  mkdir -p "$HANDOFFS"
  printf '%.'"$HANDOFF_MAX_CHARS"'s' "$block" > "${HANDOFFS}/${id}.txt"
  journal handoff "$id" "chars=${#block}"

  # Optional machine-readable line, for a "when" clause elsewhere in the
  # graph to branch on: "result: <one-line JSON>". Default {} on absence or
  # malformed JSON - never a crash, and never blocks dispatch; a when clause
  # reading a key that is not there just evaluates false, same as any
  # dependency that reported no result at all.
  local rline rjson
  # grep exits 1 when there is no result: line - the common case - and
  # under set -euo pipefail a plain assignment checks that exit status, so
  # this needs the same `|| true` already applied elsewhere in this file for
  # exactly this reason (orphan_alive_pid, check_graph_integrity).
  rline="$(printf '%s\n' "$block" | grep -m1 '^result:')" || true
  rjson="$(sed 's/^result:[[:space:]]*//' <<<"$rline")"
  if [[ -n "$rjson" ]] && jq -e . <<<"$rjson" >/dev/null 2>&1; then
    jq -c . <<<"$rjson" > "${HANDOFFS}/${id}.result.json"
  elif [[ -n "$rjson" ]]; then
    printf '{}' > "${HANDOFFS}/${id}.result.json"
    record_finding malformed_result \
      "a task's result: line was not valid JSON - any when clause reading it sees {} instead" \
      "task=${id} result=${rjson}" "task=${id}"
  fi
}

# Build what a worker actually receives: its dependencies' handoffs, then its own
# spec, then (only if something depends on it) the request for a handoff back.
build_prompt() { # $1=task id
  local id="$1" d ctx="" note h
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    h="$(cat "${HANDOFFS}/${d}.txt" 2>/dev/null || true)"
    if [[ -n "$h" ]]; then
      ctx+="- ${d}: ${h}"$'\n'
    else
      # A dependency that completed but left no handoff used to be an empty
      # context slot - silently worse, not louder: the dependent had no way
      # to know it was missing anything at all. capture_handoff() already
      # records a missing_handoff finding for the DEPENDENCY's side; this is
      # the DEPENDENT's side - a fixed, deterministic caution line, not a
      # model call (no extra request, no lane spent), so a worker is at
      # least told to verify rather than silently assume an interface no one
      # ever described.
      ctx+="- ${d}: (no handoff was provided - verify this dependency's output directly; do not assume its interface, naming, or format)"$'\n'
      journal handoff_recovery_injected "$id" "dependency=${d}"
    fi
  done < <(task_deps "$id")
  [[ -n "$ctx" ]] && ctx="Context from the tasks you depend on (already finished):"$'\n'"${ctx}"$'\n'

  if [[ -n "$(dependents_of "$id")" ]]; then
    note=$'\n\n'"Other tasks depend on this one. End your reply with a structured handoff:"$'\n'
    note+="---HANDOFF---"$'\n'
    note+="decisions: <what you chose and why>"$'\n'
    note+="rejected: <alternatives considered and why they were rejected>"$'\n'
    note+="open: <questions or decisions the next task must make>"$'\n'
    # Only asked when something downstream actually reads it (a "when"
    # clause naming this task) - no point requesting a field nobody
    # consumes.
    if task_needs_result "$id"; then
      note+="result: <one-line JSON a later task's \"when\" clause can check, e.g. {\"decision\":\"yes\"}>"$'\n'
    fi
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
  # A skipped dependency (its own "when" clause decided not to run) is
  # RESOLVED for this purpose, same as done - a dependent must not wait
  # forever on a task that already, correctly, decided never to run. What a
  # dependent then finds in that dependency's handoff/result (absent) is a
  # separate, unrelated question - the same "no handoff" case build_prompt()
  # already soft-injects a caution for.
  local d; local resolved; resolved="$(completed_tasks; skipped_tasks)"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    grep -qxF "$d" <<<"$resolved" || return 1
  done < <(task_deps "$1")
  return 0
}

# --------------------------------------------------------------- execution --
# Checksum a task's declared files before it runs. On a GREENFIELD project this
# is empty and existence is a sufficient test. On an EXISTING codebase it is not:
# a task told to modify a file that is already there would pass a mere existence
# check without touching anything - which is exactly the "claimed success, did
# nothing" failure verification exists to catch.
snapshot_files() { # $1=task id
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "${PROJECT}/${f}" ]]; then
      printf '%s\t%s\n' "$f" "$(md5sum "${PROJECT}/${f}" 2>/dev/null | cut -d" " -f1)"
    else
      printf '%s\t-\n' "$f"
    fi
  done < <(task_files "$1")
}

run_task() { # $1=task id ; runs in a subshell as a background job
  local id="$1" prompt category out rc=0 meta before wt_dir
  prompt="$(build_prompt "$id")"
  category="$(task_field "$id" category)"; category="${category:-coding}"
  out="${RESULTS}/${id}.out"; mkdir -p "$RESULTS"
  
  # Worktree isolation: create a clean worktree for coding tasks
  local workdir="$PROJECT"
  if [[ $ISOLATE -eq 1 && "$category" == "coding" ]]; then
    wt_dir="${ORCH_DIR}/worktrees/${id}"
    mkdir -p "$(dirname "$wt_dir")"
    # Create worktree from current HEAD
    if git -C "$PROJECT" worktree add -b "fa-task-${id}" "$wt_dir" HEAD 2>/dev/null ||
       git -C "$PROJECT" worktree add "$wt_dir" HEAD 2>/dev/null; then
      workdir="$wt_dir"
      log "isolated $id in $wt_dir"
    else
      log "WARNING: worktree isolation failed for $id, using main worktree"
    fi
  fi
  
  before="$(snapshot_files "$id")"

  # $BASHPID, not $$: run_task is invoked as `run_task "$id" &`, and $$ is
  # documented (and confirmed empirically) to stay the PARENT shell's PID
  # even inside a backgrounded subshell - only $BASHPID reports this
  # process's own, real PID, which is what resume needs to later check
  # whether this specific invocation is still alive.
  journal started "$id" "pid=$BASHPID"
  set +e
  local validate_flag=""
  [[ $VALIDATE -eq 1 ]] && validate_flag="--validate"
  FA_TASK_ID="$id" "$RUN_SH" -c "$category" -w "$workdir" $validate_flag "$prompt" \
    >"$out" 2>"${RESULTS}/${id}.err"
  rc=$?
  set +e
  meta="$(sed -n 's/^---RUN-META--- //p' "${RESULTS}/${id}.err" | tail -1)"

  # VERIFY, do not trust. An agent reporting success is not evidence the work
  # happened: models have claimed to create a file and written it elsewhere, or
  # not at all. If the task declared files, they must exist.
  if [[ $rc -eq 0 ]]; then
    local missing=() f was now check_dir
    check_dir="$workdir"
    # For isolated tasks, check in the worktree; for non-isolated, check in PROJECT
    [[ $ISOLATE -eq 1 && "$category" == "coding" ]] && check_dir="$wt_dir" || check_dir="$PROJECT"
    
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ ! -e "${check_dir}/${f}" ]]; then
        missing+=("${f} (absent)")
        continue
      fi
      was="$(printf '%s' "$before" | awk -F'\t' -v k="$f" '$1==k{print $2}')"
      now="$(md5sum "${check_dir}/${f}" 2>/dev/null | cut -d' ' -f1)"
      # It existed before and is byte-identical now: the task declared it would
      # touch this file and did not. Unchanged is as unverified as absent.
      [[ "$was" != "-" && "$was" == "$now" ]] && missing+=("${f} (unchanged)")
    done < <(task_files "$id")
    
    # For research tasks: verify report file exists
    if [[ "$category" == "research" && ${#missing[@]} -eq 0 ]]; then
      # Research tasks should write to docs/ or .orch/reports/
      local has_report=0
      while IFS= read -r f; do
        [[ "$f" == docs/* || "$f" == .orch/reports/* ]] && has_report=1
      done < <(task_files "$id")
      if [[ $has_report -eq 0 ]]; then
        missing+=("research task must write report to docs/ or .orch/reports/")
      fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
      journal unverified "$id" "missing=${missing[*]}"
      log "unverified $id: declared but not written: ${missing[*]}"
      # Once is a bad draw. Twice on the same task is a signal about the SPEC or
      # the models, and it is the kind of thing a real project notices that a
      # test suite never will.
      if [[ $(grep -c "\"event\":\"unverified\",\"task\":\"${id}\"" "$JOURNAL" 2>/dev/null || echo 0) -ge 2 ]]; then
        record_finding unverified_repeat \
          "task claimed success without producing its files, more than once" \
          "task=${id} declared=${missing[*]}" "task=${id}"
      fi
      # Cleanup worktree on failure
      [[ -n "$wt_dir" && -d "$wt_dir" ]] && git -C "$PROJECT" worktree remove --force "$wt_dir" 2>/dev/null
      return 1
    fi
    
    # Merge changes back from the isolated worktree into the main project,
    # and COMMIT them there. Every worktree is created from $PROJECT's HEAD
    # at dispatch time (git worktree add ... HEAD, above); without a real
    # commit here, HEAD never advances, so a LATER task's worktree is still
    # branched from the pre-run HEAD and never sees an earlier task's merged
    # work. For two unrelated tasks that never touch the same file this is
    # invisible - but a dependent pair that legitimately extends the same
    # file (plan.sh's check_boundaries() allows exactly this between a
    # declared dependency edge) would have the later task's own worktree
    # start from the file's ORIGINAL content, and its cp back to $PROJECT
    # would silently overwrite - not merge with - the earlier task's already
    # -verified work. Committing closes the gap: deps_met() only dispatches
    # a dependent after its dependency's `done` event, which now only fires
    # after that dependency's commit has landed.
    #
    # The commit itself is serialized under a merge lock: two run_task()
    # background jobs can finish and reach this block at the same moment,
    # and `git add`/`git commit` against one shared working tree is not safe
    # to run concurrently from two processes.
    if [[ $ISOLATE -eq 1 && "$category" == "coding" && -n "$wt_dir" && -d "$wt_dir" ]]; then
      local merged=()
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -f "${wt_dir}/${f}" ]]; then
          mkdir -p "$(dirname "${PROJECT}/${f}")"
          cp "${wt_dir}/${f}" "${PROJECT}/${f}" 2>/dev/null && merged+=("$f")
        fi
      done < <(task_files "$id")

      if [[ ${#merged[@]} -gt 0 ]]; then
        (
          flock -w 30 9 || { log "WARNING: merge lock timed out for $id - files copied but NOT committed, a later dependent task will not see them"; exit 1; }
          git -C "$PROJECT" add -A -- "${merged[@]}" >/dev/null 2>&1
          GIT_AUTHOR_NAME="free-agents" GIT_AUTHOR_EMAIL="free-agents@localhost" \
          GIT_COMMITTER_NAME="free-agents" GIT_COMMITTER_EMAIL="free-agents@localhost" \
            git -C "$PROJECT" commit -q -m "fa: ${id}" -- "${merged[@]}" >/dev/null 2>&1
        ) 9>"${ORCH_DIR}/.merge.lock" \
          && log "merged and committed $id changes from worktree" \
          || log "WARNING: $id changes were copied but the commit failed - a later dependent task may not see them; check ${ORCH_DIR}/.merge.lock contention or run 'git -C $PROJECT status'"
      fi

      # Cleanup the worktree and its throwaway branch
      git -C "$PROJECT" worktree remove --force "$wt_dir" 2>/dev/null || true
      git -C "$PROJECT" branch -D "fa-task-${id}" >/dev/null 2>&1 || true
    fi
  fi

  [[ $rc -eq 0 ]] && capture_handoff "$id"

  # Check if this was a validation failure (distinct from build failure)
  local validation_err=""
  if [[ $rc -ne 0 && -f "${RESULTS}/${id}.err" ]]; then
    validation_err="$(grep -a '^---VALIDATION-FAILED---' "${RESULTS}/${id}.err" | tail -1 || true)"
  fi

  case $rc in
    0) journal done "$id" \
         "bucket=$(jq -r '.bucket // ""' <<<"${meta:-null}")" \
         "model=$(jq -r '.model // ""' <<<"${meta:-null}")" \
         "agent=$(jq -r '.agent // ""' <<<"${meta:-null}")" ;;
    5) journal no_lane "$id" ;;          # not a failure: requeue
    *)
      if [[ -n "$validation_err" ]]; then
        journal validation_failed "$id" "${validation_err#---VALIDATION-FAILED--- }"
      else
        journal attempt_failed "$id" "rc=$rc"
      fi
      # Cleanup worktree on failure
      [[ -n "$wt_dir" && -d "$wt_dir" ]] && git -C "$PROJECT" worktree remove --force "$wt_dir" 2>/dev/null
      ;;
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
  
  # Auto-enable isolation when at least two tasks have GENUINELY disjoint
  # file sets - a real pairwise overlap check (the same comm -12 technique
  # files_conflict() below already applies to running tasks at dispatch
  # time, just run up front against the whole static task list), not merely
  # "more than one task declares a files array". That used to just count
  # tasks regardless of overlap, so it was right only by accident: a graph
  # where every task deliberately shares one file (a valid, plan.sh-permitted
  # pattern between a dependent pair) still had isolation silently switched
  # on, when isolation buys nothing for tasks that can never run concurrently
  # anyway (files_conflict() already blocks that) and are dispatched with no
  # dependency relationship in mind here.
  # Only works in git repos — skip if project isn't a git repo
  if [[ $ISOLATE -eq 0 ]]; then
    local disjoint_count=0 _ids=() _files=() _i _j _clean
    mapfile -t _ids < <(task_ids)
    for _i in "${_ids[@]}"; do _files+=("$(task_files "$_i" | sort -u)"); done
    for ((_i=0; _i<${#_ids[@]}; _i++)); do
      [[ -z "${_files[$_i]}" ]] && continue
      _clean=1
      for ((_j=0; _j<${#_ids[@]}; _j++)); do
        [[ $_i -eq $_j || -z "${_files[$_j]}" ]] && continue
        if [[ -n "$(comm -12 <(printf '%s\n' "${_files[$_i]}") <(printf '%s\n' "${_files[$_j]}"))" ]]; then
          _clean=0; break
        fi
      done
      [[ $_clean -eq 1 ]] && disjoint_count=$((disjoint_count+1))
    done
    [[ $disjoint_count -gt 1 && $width -gt 1 ]] && git -C "$PROJECT" rev-parse --is-inside-work-tree 2>/dev/null && ISOLATE=1 && log "auto-enabled isolation for parallel disjoint tasks"
  fi
  
  local mode="$(project_mode)"
  log "project=$PROJECT  parallel=$width  mode=$mode  isolate=$ISOLATE"

  declare -A ATTEMPTS=() PIDS=() RUNNING=() LANEWAIT=()
  # Reconstruct the retry budget from the journal, so a resume after a crash
  # continues the SAME budget instead of restarting it. ATTEMPTS is otherwise
  # a fresh, empty map on every invocation: a task that had already failed
  # once under a prior, now-dead process would get up to TASK_RETRIES+1 MORE
  # attempts on top of whatever it had already spent.
  if [[ -f "$JOURNAL" ]]; then
    while IFS=$'\t' read -r _cnt _id; do
      [[ -z "$_id" ]] && continue
      ATTEMPTS[$_id]="$_cnt"
    done < <(jq -r 'select(.event == "attempt_failed") | .task' "$JOURNAL" 2>/dev/null \
             | sort | uniq -c | awk '{print $1"\t"$2}')
  fi
  local todo remaining id pid finished progressed orphan_ids

  while :; do
    todo=""; remaining=0; orphan_ids=()
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      grep -qxF "$id" <<<"$(completed_tasks)" && continue
      grep -qxF "$id" <<<"$(failed_tasks)"    && continue
      grep -qxF "$id" <<<"$(skipped_tasks)"   && continue
      is_halted "$id" && continue
      remaining=$((remaining+1))
      # A task we did not dispatch OURSELVES this run (not in RUNNING) whose
      # last journal event is still "started" under a PID that is alive is
      # being run by an orphaned child of a previous, now-dead orch.sh
      # process. Do not dispatch a second run_task() for it - just wait; the
      # orphan writes its own terminal event independently and this loop
      # will pick that up on a later pass. A "started" with no live PID
      # (old journal with no pid field, or the orphan died too) falls
      # through to a normal, fresh dispatch below.
      if [[ -z "${RUNNING[$id]:-}" ]]; then
        # orphan_alive_pid intentionally returns non-zero when the pid is
        # dead - `|| true` so that, under set -euo pipefail, a plain
        # assignment from its non-zero exit does not abort the whole script
        # (the same class of bug fixed elsewhere in this file's --validate
        # gate: `local x; x="$(cmd)"` checks cmd's exit status, unlike
        # `local x="$(cmd)"` on one line, which does not).
        local opid; opid="$(orphan_alive_pid "$id")" || true
        if [[ -n "$opid" ]]; then
          orphan_ids+=("$id(pid $opid)")
          continue
        elif [[ "$(last_event_for "$id")" == "started" ]] \
             && ! grep -q "\"event\":\"orphan_abandoned\",\"task\":\"${id}\"" "$JOURNAL" 2>/dev/null; then
          journal orphan_abandoned "$id"
          record_finding orphan_abandoned \
            "a task's previous attempt vanished mid-run: no PID left alive and no terminal event was ever written" \
            "task=${id}"
          log "  $id: previous attempt is gone with no result - redispatching"
        fi
      fi
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
      # Blocked, or downstream of something blocked: skip silently. Journalled
      # once so the record explains the gap, then never attempted.
      if is_halted "$id"; then
        if ! grep -q "\"event\":\"blocked\",\"task\":\"${id}\"" "$JOURNAL" 2>/dev/null; then
          journal blocked "$id" "reason=$(task_blocked "$id" || true)"
        fi
        continue
      fi
      deps_met "$id" || continue
      # deps_met above already guarantees any dependency named in a "when"
      # clause has resolved (done or skipped) by this point, so its result
      # (if any) is final - safe to evaluate now, once, before ever
      # spending a lane on a task whose own precondition says not to run.
      if ! when_satisfied "$id"; then
        if ! grep -q "\"event\":\"skipped\",\"task\":\"${id}\"" "$JOURNAL" 2>/dev/null; then
          journal skipped "$id" "reason=when-not-satisfied"
          log "skip $id (when clause not satisfied)"
        fi
        continue
      fi
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
      # We have nothing of our own in flight, but at least one task is still
      # running under an orphaned child from a previous process - that is
      # progress happening outside this loop's view, not a stall. Poll for
      # it to finish (or die) rather than declaring a deadlock.
      if [[ ${#orphan_ids[@]} -gt 0 ]]; then
        log "waiting on ${#orphan_ids[@]} task(s) still running under a PID from an earlier orch.sh process: ${orphan_ids[*]}"
        sleep "${ORPHAN_POLL:-5}"
        continue
      fi
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

  local nfail nhalt nskip; nfail="$(failed_tasks | grep -c . || true)"
  nhalt="$(halted_tasks | grep -c . || true)"
  nskip="$(skipped_tasks | grep -c . || true)"
  log "complete: $(completed_tasks | grep -c . || true) done, ${nfail} failed$([[ ${nskip:-0} -gt 0 ]] && echo ", ${nskip} skipped (when clause)")$([[ ${nhalt:-0} -gt 0 ]] && echo ", ${nhalt} waiting on you")"
  if [[ "${nhalt:-0}" -gt 0 ]]; then
    log ""
    log "Waiting on you - these were never attempted:"
    local h r
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      r="$(task_blocked "$h")"
      if [[ -n "$r" ]]; then log "  $h — $r"
      else log "  $h — blocked by a dependency above"; fi
    done < <(halted_tasks)
    log "When it is unblocked: remove the \"blocked\" field from .orch/tasks.json, then fa resume"
  fi
  # Surface anything the tool noticed about ITSELF during this run, so a real
  # project can feed a fix back rather than the observation dying with the run.
  # Then run the aggregate analysis — patterns spread across tasks that the
  # per-task findings above (fired at the moment of failure) cannot see.
  analyze_journal
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
  local total done_n fail_n skip_n
  total="$( [[ -f "$TASKS_FILE" ]] && task_ids | grep -c . || echo '?')"
  done_n="$(completed_tasks | grep -c . || true)"
  fail_n="$(failed_tasks | grep -c . || true)"
  skip_n="$(skipped_tasks | grep -c . || true)"
  printf 'project: %s\n%s/%s done, %s failed, %s skipped\n\n' "$PROJECT" "$done_n" "$total" "$fail_n" "$skip_n"
  jq -r 'select(.event=="done")
         | "  done    \(.task)  <- \(.bucket // "?")  \(.model // "")"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="failed") | "  FAILED  \(.task)"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="skipped") | "  SKIPPED \(.task)  (when clause not satisfied)"' "$JOURNAL" | sort -u
  # Validation failures: distinct from build failures — the agent built
  # something that doesn't parse. Show them prominently.
  jq -r 'select(.event=="validation_failed")
         | "  VALIDATION FAILED  \(.task)  \(. // "")"' "$JOURNAL" | sort -u
  # A deadlocked run leaves tasks that will never become runnable. Listing them
  # as "pending" reads as "waiting its turn", which is the wrong thing to
  # believe - nothing is going to move without a change to the graph.
  local h r
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    r="$(task_blocked "$h")"
    if [[ -n "$r" ]]; then printf '  WAITING  %s  — %s\n' "$h" "$r"
    else printf '  WAITING  %s  — blocked by a dependency\n' "$h"; fi
  done < <(halted_tasks 2>/dev/null)
  jq -r 'select(.event=="deadlock")
         | "  BLOCKED  \(.blocked // "?")  (cycle, unknown dependency id, or a failed prerequisite)"' \
     "$JOURNAL" 2>/dev/null | tail -1
  if [[ -f "$TASKS_FILE" ]]; then
    local d; d="$(completed_tasks)"; local f; f="$(failed_tasks)"; local s; s="$(skipped_tasks)"
    while IFS= read -r id; do
      grep -qxF "$id" <<<"$d" && continue
      grep -qxF "$id" <<<"$f" && continue
      grep -qxF "$id" <<<"$s" && continue
      is_halted "$id" && continue
      echo "  pending $id"
    done < <(task_ids)
  fi
}

# What of .orch/ belongs in the PROJECT's git:
#   tasks.json      YES - it is the specification, and it is what makes a run
#                   repeatable on someone else's machine (with their own lanes).
#   config.yaml     YES - project autonomy mode (strict/push/local).
#   journal.ndjson  NO  - a record of what happened on ONE machine. Committing it
#                   guarantees conflicts and reproduces nothing: which wallet
#                   served a task is not a property of the project.
#   results/        NO  - raw agent transcripts.
#   worktrees/      NO  - git worktrees for isolated task execution.
write_orch_gitignore() {
  mkdir -p "$ORCH_DIR"
  # Never clobber a hand-edited file - but do repair the one line that an older
  # setup.sh left out, or those handoffs stay tracked forever.
  if [[ -f "${ORCH_DIR}/.gitignore" ]]; then
    grep -qx 'handoffs/' "${ORCH_DIR}/.gitignore" \
      || printf 'handoffs/\n' >> "${ORCH_DIR}/.gitignore"
    return 0
  fi
  cat > "${ORCH_DIR}/.gitignore" <<'EOF'
# Commit tasks.json and config.yaml - they are the specification.
# Everything else here is a record of one machine's run.
journal.ndjson
results/
handoffs/
*.lock
worktrees/
EOF
}

cmd_init() {
  mkdir -p "$ORCH_DIR" "$RESULTS"
  [[ -f "$TASKS_FILE" ]] || echo '{"tasks":[]}' > "$TASKS_FILE"
  
  # Create default .orch/config.yaml if not present
  if [[ ! -f "${ORCH_DIR}/config.yaml" ]]; then
    cat > "${ORCH_DIR}/config.yaml" <<'EOF'
# Project autonomy mode:
#   strict    - verify after every change (default)
#   push      - can push and create PRs
#   local     - no remote operations
mode: strict

# Allow autonomous merging (only with push mode)
automerge: false
EOF
    log "created ${ORCH_DIR}/config.yaml (mode: strict)"
  fi
  
  write_orch_gitignore
  echo "initialised $ORCH_DIR"
}

usage() { sed -n '6,32p' "$0" >&2; exit 3; }

CMD="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --validate) VALIDATE=1; shift ;;
    --isolate) ISOLATE=1; shift ;;
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
