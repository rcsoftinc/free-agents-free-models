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
#           "verify": "npm test -- api",      # optional: done = exits 0, run in
#                                             # the task's workdir (run.sh --verify)
#           "readonly": ["fixtures/*"],       # optional: more files the worker must
#                                             # not change, on top of the project's
#                                             # `readonly:` in .orch/config.yaml
#           "category": "coding" } ] }
#
#   .orch/config.yaml (init writes one): readonly: files no worker may change;
#   verify: the project's own check, run once a run's tasks have landed (a
#   failure goes to one worker); mode: push takes the work to a branch and a
#   pull request, and what CI reports back to a worker.
#
# Exit: 0 all tasks done (and checked) | 1 a task failed, the project check
#       failed, or - push mode - the push or CI failed | 3 setup error

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

# Where a run's work lands. The project itself - except in push mode, where
# the run builds on its own branch in its own worktree (push_setup), so the
# working directory you are in is never switched or touched.
WORK="$PROJECT"

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
# Both of these leave the coordinator's own wallet out (RESERVED_JSON, set once
# per run in cmd_run from common.sh's coordinator_buckets): run.sh will not put
# a worker there, so counting it as a free lane would launch a task straight
# into an exit 5 and back into the queue - churn, not progress.
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
  done < <(registry_read '.buckets | keys[] | select(IN($res[]) | not)' \
             --argjson res "${RESERVED_JSON:-[]}" 2>/dev/null)
  printf '%s' "$n"
}

# free_lanes sees only leases already held, and a task launched a moment ago
# has not taken its lane yet: run_task does its own setup first, then run.sh
# starts up and picks one. Until then the lane it is about to take still looks
# free, the loop launches another task into it, and that one finds every lane
# busy, exits 5 and requeues - churn, worse the longer a task takes to start.
# run.sh touches FA_LEASED_SIGNAL once it holds a lane; until it has, a task
# still alive counts as holding one.
unleased_running() {
  local id n=0
  for id in "${!RUNNING[@]}"; do
    if [[ -e "${RESULTS}/${id}.leased" || -z "${PIDS[$id]:-}" ]]; then continue; fi
    if kill -0 "${PIDS[$id]}" 2>/dev/null; then n=$((n+1)); fi
  done
  printf '%s' "$n"
}

healthy_buckets() {
  local now; now="$(now_epoch)"
  registry_read '[ .buckets[]
    | select(.id | IN($res[]) | not)
    | select((.health.cooldown_until // 0) <= ($now|tonumber))
    | select([.models[] | select(.free)] | length > 0) ] | length' --arg now "$now" \
    --argjson res "${RESERVED_JSON:-[]}" 2>/dev/null || echo 1
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

# ------------------------------------------------------------ worktree pool --
# One slot per possible lane (1..width), each an flock-guarded git worktree
# reused across tasks - and across separate orch.sh invocations, since
# nothing here ever destroys the directory - instead of created and torn
# down per task. `git worktree add` is a full checkout of every tracked
# file; resetting an EXISTING one only touches what actually changed since
# its last use. Concurrency safety mirrors bin/run.sh's own bucket
# lease_acquire/lease_release (flock on a per-resource file, held via a
# caller-scoped FD) - the same idiom, not shared code, since these guard
# different resources (a bucket vs. a pool slot) in different files.
WT_POOL_DIR="${ORCH_DIR}/worktrees"
WT_LEASE_FD=""

wt_pool_acquire() { # $1=slot -> 0 if we hold it
  local slot="$1" f
  mkdir -p "$WT_POOL_DIR"
  f="${WT_POOL_DIR}/.pool-${slot}.lock"
  exec {WT_LEASE_FD}>"$f" || return 1
  flock -n "$WT_LEASE_FD" || { exec {WT_LEASE_FD}>&-; WT_LEASE_FD=""; return 1; }
  return 0
}
wt_pool_release() {
  [[ -n "$WT_LEASE_FD" ]] || return 0
  flock -u "$WT_LEASE_FD" 2>/dev/null || true
  exec {WT_LEASE_FD}>&-
  WT_LEASE_FD=""
}

# Claim the first free slot (1..$1), setting $WT_ACQUIRED_SLOT on success.
#
# MUST be called DIRECTLY - never as `x="$(wt_pool_claim ...)"`. Command
# substitution forks a subshell to run its command and collect its output;
# the instant that subshell exits (which happens as soon as the command
# finishes), every FD it opened is closed - including the flock'd
# WT_LEASE_FD wt_pool_acquire just opened, releasing the lock it was
# supposed to hand back to the caller. A real run hit exactly this: two
# concurrent tasks both "succeeded" in acquiring slot 1, because the first
# task's lock was already gone by the time the second even asked - the
# subshell that briefly held it had already exited. Calling this directly
# (no `$(...)`) keeps WT_LEASE_FD open in the CALLER's own shell, for as
# long as the caller holds it.
wt_pool_claim() { # $1=pool_size -> 0 if a slot was claimed
  local pool_size="${1:-1}" slot
  WT_ACQUIRED_SLOT=""
  for ((slot = 1; slot <= pool_size; slot++)); do
    wt_pool_acquire "$slot" && { WT_ACQUIRED_SLOT="$slot"; return 0; }
  done
  return 1
}

# Reuse or create the worktree at an ALREADY-CLAIMED slot, at the current
# $PROJECT HEAD. Safe to call via `$(...)` (unlike wt_pool_claim above) -
# this holds no lock state that needs to outlive its own return. Echoes the
# worktree's directory on stdout, or nothing if neither reuse nor a fresh
# create worked.
wt_pool_prepare() { # $1=project $2=slot -> worktree dir, or empty
  local project="$1" slot="$2" dir head
  dir="${WT_POOL_DIR}/pool-${slot}"
  if [[ -e "${dir}/.git" ]]; then
    # A returned slot from an earlier task (this run or a previous one) -
    # bring it to the CURRENT project HEAD before handing it to a new task.
    # Both steps matter: reset alone leaves an untracked scratch file a
    # prior task's agent wrote; clean alone leaves it on a stale commit if
    # $project has since advanced (every successful task commits its merge
    # - see the commit block in run_task()).
    head="$(git -C "$project" rev-parse HEAD 2>/dev/null)"
    if [[ -n "$head" ]] \
       && git -C "$dir" reset --hard "$head" >/dev/null 2>&1 \
       && git -C "$dir" clean -fdx >/dev/null 2>&1; then
      log "pool slot ${slot}: reused (reset to current HEAD)"
      printf '%s' "$dir"; return 0
    fi
    # Would not reset cleanly (corrupted, or moved out from under git) -
    # deregister and recreate from scratch rather than hand over a slot
    # nothing can vouch for. `worktree remove --force` is NOT enough here -
    # confirmed directly: git refuses it outright ("validation failed...
    # is not a .git file") whenever the worktree's own .git pointer is
    # itself broken, `--force` notwithstanding (force overrides a dirty or
    # locked worktree, not a corrupted one). rm -rf the directory FIRST,
    # then `worktree prune` clears git's now-dangling admin record for a
    # path that no longer exists - only then does a fresh `add` succeed.
    log "pool slot ${slot}: could not be reset cleanly - recreating it"
    rm -rf "$dir"
    git -C "$project" worktree prune >/dev/null 2>&1 || true
  fi
  # `git worktree add` prints status lines ("Preparing worktree...", "HEAD
  # is now at ...") to STDOUT, not just stderr - this function's own stdout
  # IS its return value (the worktree path), so BOTH streams must be
  # silenced here or that git noise corrupts the caller's $workdir.
  if git -C "$project" worktree add -B "fa-pool-${slot}" "$dir" HEAD >/dev/null 2>&1; then
    log "pool slot ${slot}: created fresh"
    printf '%s' "$dir"; return 0
  fi
  return 1
}

# What a task changed outside its declared files. In its own worktree that
# work is DROPPED at merge - only declared files come back - which quietly
# loses a line the task really needed; in place it is KEPT, which quietly keeps
# what nobody reviewed. Either way it is said now. git-backed: a project
# without git gets no report.
dirty_state() { # $1=dir -> "<md5> <path>" per modified, deleted or untracked file
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local f h
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    h="$(cd "$1" && md5sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
    printf '%s %s\n' "${h:-deleted}" "$f"
  done < <( { git -C "$1" ls-files --modified --deleted
              git -C "$1" ls-files --others --exclude-standard; } | sort -u )
  return 0
}

undeclared_changes() { # $1=dir $2=dirty_state before $3=task -> paths, one per line
  local f declared
  declared="$(task_files "$3")"
  comm -13 <(printf '%s\n' "$2" | sort) <(dirty_state "$1" | sort) | cut -d' ' -f2- \
    | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in .orch/*|.free-agents/*) continue ;; esac
        if grep -qxF -- "$f" <<<"$declared"; then continue; fi
        printf '%s\n' "$f"
      done
  return 0
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
    if [[ -f "${WORK}/${f}" ]]; then
      printf '%s\t%s\n' "$f" "$(md5sum "${WORK}/${f}" 2>/dev/null | cut -d" " -f1)"
    else
      printf '%s\t-\n' "$f"
    fi
  done < <(task_files "$1")
}

run_task() { # $1=task id ; runs in a subshell as a background job
  local id="$1" prompt category out rc=0 meta before wt_slot=""
  # The project run lock belongs to the orchestrator alone (cmd_run).
  [[ -n "${RUN_LOCK_FD:-}" ]] && exec {RUN_LOCK_FD}>&-
  prompt="$(build_prompt "$id")"
  category="$(task_field "$id" category)"; category="${category:-coding}"
  out="${RESULTS}/${id}.out"; mkdir -p "$RESULTS"

  # Worktree isolation: claim a slot from the pool (see wt_pool_claim /
  # wt_pool_prepare above) instead of creating and tearing one down per
  # task. $width is cmd_run's own local - visible here because run_task is
  # only ever invoked from inside cmd_run's active call frame, the same way
  # this file already relies on $ISOLATE/$VALIDATE/$DRY_RUN as top-level
  # globals instead.
  local workdir="$WORK"
  if [[ $ISOLATE -eq 1 && "$category" == "coding" ]]; then
    if wt_pool_claim "${width:-1}"; then
      wt_slot="$WT_ACQUIRED_SLOT"
      local prepared; prepared="$(wt_pool_prepare "$WORK" "$wt_slot")" || true
      if [[ -n "$prepared" ]]; then
        workdir="$prepared"
        log "isolated $id in pool slot ${wt_slot} ($workdir)"
      else
        log "WARNING: pool slot ${wt_slot} could not be prepared for $id, using main worktree"
        wt_pool_release
        wt_slot=""
      fi
    else
      log "WARNING: no free worktree pool slot for $id, using main worktree"
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
  local validate_flag="" verify_cmd verify_args=() ro_args=() g f
  [[ $VALIDATE -eq 1 ]] && validate_flag="--validate"
  # Read-only: the project's list plus the task's own - minus the files this
  # task declares, which it is meant to write. run.sh puts any other change to
  # them back before a single check runs.
  while IFS= read -r g; do [[ -n "$g" ]] && ro_args+=(--readonly "$g"); done \
    < <(project_readonly_globs "$PROJECT"; jq -r --arg id "$id" \
          '.tasks[] | select(.id == $id) | (.readonly // [])[]' "$TASKS_FILE")
  if [[ ${#ro_args[@]} -gt 0 ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && ro_args+=(--writable "$f"); done < <(task_files "$id")
  fi
  local before_dirty; before_dirty="$(dirty_state "$workdir")"
  # The task's own definition of done, run by run.sh in $workdir - the
  # isolated worktree when there is one, so it checks this task's work BEFORE
  # anything merges back.
  verify_cmd="$(task_field "$id" verify)"
  [[ -n "$verify_cmd" ]] && verify_args=(--verify "$verify_cmd")
  FA_TASK_ID="$id" FA_LEASED_SIGNAL="${RESULTS}/${id}.leased" \
    "$RUN_SH" -c "$category" -w "$workdir" $validate_flag "${verify_args[@]}" \
    "${ro_args[@]}" "$prompt" >"$out" 2>"${RESULTS}/${id}.err"
  rc=$?
  set +e
  meta="$(sed -n 's/^---RUN-META--- //p' "${RESULTS}/${id}.err" | tail -1)"

  # Read-only files the worker changed and run.sh put back, for fa status.
  local restored
  restored="$(sed -n 's/^---PROTECTED-RESTORED--- //p' "${RESULTS}/${id}.err" \
              | jq -rs 'add // [] | unique | join(" ")' 2>/dev/null)"
  [[ -n "$restored" ]] && journal protected "$id" "files=${restored}"

  # And whatever it changed that it never declared.
  local undeclared fate patch=""
  undeclared="$(undeclared_changes "$workdir" "$before_dirty" "$id")"
  if [[ -n "$undeclared" ]]; then
    if [[ -n "$wt_slot" || "$WORK" != "$PROJECT" ]]; then
      # Push mode commits only declared files, so in place there too they
      # stay off the branch that gets pushed.
      fate="dropped, not merged"
      [[ -z "$wt_slot" ]] && fate="not committed, so not pushed"
      # Kept as a patch, in case it was a line the task really needed:
      # git apply .orch/results/<id>.undeclared.patch
      patch="${RESULTS}/${id}.undeclared.patch"
      mapfile -t _u <<<"$undeclared"
      git -C "$workdir" add -N -- "${_u[@]}" >/dev/null 2>&1
      git -C "$workdir" diff -- "${_u[@]}" > "$patch" 2>/dev/null
    else
      fate="kept, in the project"
    fi
    log "$id changed files it did not declare (${fate}): $(tr '\n' ' ' <<<"$undeclared")"
    journal undeclared "$id" "files=$(tr '\n' ' ' <<<"$undeclared" | sed 's/ $//')" \
      "fate=${fate}" ${patch:+"patch=${patch#"${PROJECT}"/}"}
  fi

  # VERIFY, do not trust. An agent reporting success is not evidence the work
  # happened: models have claimed to create a file and written it elsewhere, or
  # not at all. If the task declared files, they must exist.
  if [[ $rc -eq 0 ]]; then
    local missing=() f was now
    # $workdir already reflects reality (falls back to $PROJECT whenever
    # isolation was skipped or the pool had no free slot) - a separate
    # variable here used to re-derive the same answer from $ISOLATE/
    # $category instead of asking what actually happened, and could disagree
    # with $workdir on exactly the "pool exhausted" edge case.
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ ! -e "${workdir}/${f}" ]]; then
        missing+=("${f} (absent)")
        continue
      fi
      was="$(printf '%s' "$before" | awk -F'\t' -v k="$f" '$1==k{print $2}')"
      now="$(md5sum "${workdir}/${f}" 2>/dev/null | cut -d' ' -f1)"
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
      # Return the pool slot (never destroy it - see wt_pool_claim above).
      wt_pool_release
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
    if [[ -n "$wt_slot" ]]; then
      local merged=()
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -f "${workdir}/${f}" ]]; then
          mkdir -p "$(dirname "${WORK}/${f}")"
          cp "${workdir}/${f}" "${WORK}/${f}" 2>/dev/null && merged+=("$f")
        fi
      done < <(task_files "$id")

      if [[ ${#merged[@]} -gt 0 ]]; then
        (
          flock -w 30 9 || { log "WARNING: merge lock timed out for $id - files copied but NOT committed, a later dependent task will not see them"; exit 1; }
          git -C "$WORK" add -A -- "${merged[@]}" >/dev/null 2>&1
          GIT_AUTHOR_NAME="free-agents" GIT_AUTHOR_EMAIL="free-agents@localhost" \
          GIT_COMMITTER_NAME="free-agents" GIT_COMMITTER_EMAIL="free-agents@localhost" \
            git -C "$WORK" commit -q -m "fa: ${id}" -- "${merged[@]}" >/dev/null 2>&1
        ) 9>"${ORCH_DIR}/.merge.lock" \
          && log "merged and committed $id changes from worktree" \
          || log "WARNING: $id changes were copied but the commit failed - a later dependent task may not see them; check ${ORCH_DIR}/.merge.lock contention or run 'git -C $WORK status'"
      fi

      # Return the pool slot for the next task to reuse (see wt_pool_claim
      # above) - never destroy it. Its branch (fa-pool-N) is reset in place
      # next time, not deleted; there is no per-task branch to clean up
      # anymore.
      wt_pool_release
    elif [[ "$WORK" != "$PROJECT" ]]; then
      # Push mode, in place: the task wrote straight onto the run's branch, and
      # only a commit puts its work on what gets pushed - its declared files,
      # as a worktree merge would.
      local landed=()
      while IFS= read -r f; do
        if [[ -n "$f" && -e "${WORK}/${f}" ]]; then landed+=("$f"); fi
      done < <(task_files "$id")
      if [[ ${#landed[@]} -gt 0 ]]; then
        commit_work "fa: ${id}" "${landed[@]}" \
          || log "WARNING: $id's files are on the run's branch but the commit failed - they will not be pushed"
      fi
    fi
  fi

  [[ $rc -eq 0 ]] && capture_handoff "$id"

  # Check if this was a validation failure (distinct from build failure)
  local validation_err="" verify_err=""
  if [[ $rc -ne 0 && -f "${RESULTS}/${id}.err" ]]; then
    validation_err="$(grep -a '^---VALIDATION-FAILED---' "${RESULTS}/${id}.err" | tail -1 || true)"
    verify_err="$(grep -a '^---VERIFY-FAILED---' "${RESULTS}/${id}.err" | tail -1 || true)"
  fi

  case $rc in
    0) journal done "$id" \
         "bucket=$(jq -r '.bucket // ""' <<<"${meta:-null}")" \
         "model=$(jq -r '.model // ""' <<<"${meta:-null}")" \
         "agent=$(jq -r '.agent // ""' <<<"${meta:-null}")" \
         "verified=$(jq -r 'if .verify == "passed" then "yes" else "" end' <<<"${meta:-null}")" ;;
    5) journal no_lane "$id" ;;          # not a failure: requeue
    *)
      if [[ -n "$verify_err" ]]; then
        local vj="${verify_err#---VERIFY-FAILED--- }"
        journal verify_failed "$id" "cmd=$(jq -r '.cmd' <<<"$vj")" \
          "rounds=$(jq -r '.rounds' <<<"$vj")" "tail=$(jq -r '.tail' <<<"$vj")"
      elif [[ -n "$validation_err" ]]; then
        journal validation_failed "$id" "${validation_err#---VALIDATION-FAILED--- }"
      else
        journal attempt_failed "$id" "rc=$rc"
      fi
      # Return the pool slot (never destroy it - see wt_pool_claim above).
      wt_pool_release
      ;;
  esac
  return $rc
}

# ------------------------------------------------------------ a new plan --
# A new plan starts a new run record. The journal is the only record of what
# is done, and plans name their tasks with short slugs ("api", "tests"): a
# second plan's "api" read as already done, and never ran - in push mode its
# work was simply missing from the branch. So when `run` meets a plan other
# than the one the journal belongs to, that journal is put aside in
# .orch/history/ and this run starts fresh. `resume`, and `run` on the same
# plan, keep it: done tasks stay done.
plan_turnover() {
  local now last stray=""
  [[ $DRY_RUN -eq 1 ]] && return 0        # a dry run changes nothing
  now="$(md5sum < "$TASKS_FILE" | cut -d' ' -f1)"
  last="$(jq -r 'select(.event=="plan") | .md5' "$JOURNAL" 2>/dev/null | tail -1)" || true
  [[ "$last" == "$now" ]] && return 0
  if [[ "$CMD" == "run" && -s "$JOURNAL" ]]; then
    if [[ -z "$last" ]]; then
      # A journal from before plans were recorded: a task it ran that this
      # plan does not have means it belonged to another plan.
      stray="$(comm -23 <(jq -r '.task' "$JOURNAL" 2>/dev/null | grep -vx -- '-' | sort -u) \
                        <(task_ids | sort -u))" || true
    fi
    if [[ -n "$last" || -n "$stray" ]]; then
      mkdir -p "${ORCH_DIR}/history"
      mv "$JOURNAL" "${ORCH_DIR}/history/journal-$(date -u +%Y%m%d-%H%M%S).ndjson"
      log "a new plan: the last one's run record is in .orch/history/, and this run starts fresh"
    fi
  fi
  journal plan - "md5=${now}" "tasks=$(task_ids | grep -c . || true)"
}

# ----------------------------------------------------------- after a run --
# Settings with one value per line in .orch/config.yaml, YAML quotes dropped.
project_setting() { # $1=key -> its value, or empty
  local config="${ORCH_DIR}/config.yaml" v dq='^"(.*)"$' sq="^'(.*)'\$"
  [[ -f "$config" ]] || return 0
  v="$(grep -E "^$1:" "$config" 2>/dev/null | head -1 \
        | sed "s/^$1:[[:space:]]*//; s/[[:space:]]*\$//")" || true
  if [[ "$v" =~ $dq || "$v" =~ $sq ]]; then v="${BASH_REMATCH[1]}"; fi
  printf '%s' "$v"
}

# Task ids that reached "done" after the last journal event of kind $1 (all of
# them, if there is none): what landed since the project was last checked, or
# since push mode started its branch.
done_since() { # $1=event
  [[ -f "$JOURNAL" ]] || return 0
  local n; n="$(grep -n "\"event\":\"$1\"" "$JOURNAL" | tail -1 | cut -d: -f1)" || true
  tail -n +"$(( ${n:-0} + 1 ))" "$JOURNAL" | jq -r 'select(.event=="done") | .task' 2>/dev/null \
    | awk '!seen[$0]++' || true
  return 0
}

# Commit paths in the run's working tree as fa, under the merge lock the
# worktree merges take - the same identity, so `git log` tells fa's commits
# apart from yours.
commit_work() { # $1=message, rest=paths
  local msg="$1"; shift
  (
    flock -w 30 9 || exit 1
    git -C "$WORK" add -A -- "$@" >/dev/null 2>&1
    GIT_AUTHOR_NAME="free-agents" GIT_AUTHOR_EMAIL="free-agents@localhost" \
    GIT_COMMITTER_NAME="free-agents" GIT_COMMITTER_EMAIL="free-agents@localhost" \
      git -C "$WORK" commit -q -m "$msg" -- "$@" >/dev/null 2>&1
  ) 9>"${ORCH_DIR}/.merge.lock"
}

# What changed in $WORK between two dirty_state snapshots: paths, one per line.
changed_between() { # $1=before $2=after
  comm -3 <(printf '%s\n' "$1" | sed '/^$/d' | sort) <(printf '%s\n' "$2" | sed '/^$/d' | sort) \
    | sed 's/^\t//' | cut -d' ' -f2- | grep -v '^\.orch/' | sort -u || true
  return 0
}

# Hand a failure to one worker: run.sh in $WORK, the project's read-only files
# held, and - when there is one - the project's own check as its verify, so
# run.sh's fix rounds apply and "fixed" means the check passed. Sets
# FIX_CHANGED (paths, one per line); returns run.sh's exit code.
FIX_CHANGED=""
send_fixer() { # $1=label for its results $2=prompt $3=verify command (may be empty)
  local ro=() g before frc=0 verify=()
  while IFS= read -r g; do
    if [[ -n "$g" ]]; then ro+=(--readonly "$g"); fi
  done < <(project_readonly_globs "$PROJECT")
  if [[ -n "$3" ]]; then verify=(--verify "$3"); fi
  before="$(dirty_state "$WORK")"
  FA_TASK_ID="$1" FA_VERIFY_TIMEOUT="${FA_PROJECT_VERIFY_TIMEOUT:-1800}" \
    "$RUN_SH" -c coding -w "$WORK" "${verify[@]}" "${ro[@]}" "$2" \
    >"${RESULTS}/$1.out" 2>"${RESULTS}/$1.err" || frc=$?
  FIX_CHANGED="$(changed_between "$before" "$(dirty_state "$WORK")")"
  return "$frc"
}

# Each landed task with its declared files, for a prompt or a PR body.
describe_tasks() { # stdin: ids -> "id (file, file)" per line
  local id files
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    files="$(task_files "$id" 2>/dev/null | tr '\n' ' ' | sed 's/ $//; s/ /, /g')" || true
    printf '%s%s\n' "$id" "${files:+ (${files})}"
  done
  return 0
}

# ---------------------------------------------------------- project check --
# The project's own check: `verify:` in .orch/config.yaml, one command (bash
# -c) that says the whole project works - npm test, dotnet test, ./gradlew
# test. A task's own verify proves that task in its own workdir, and two tasks
# can each pass theirs and still break each other once both land. So this
# runs where the run's work landed, once its tasks are done; when it fails,
# one worker is sent to fix it, with this same command as its verify.
CHECK_RESULT=""     # passed | fixed | failed, or empty when it did not run
project_check() { # -> 1 only when the check fails and a worker could not fix it
  local cmd; cmd="$(project_setting verify)"
  [[ -n "$cmd" ]] || return 0
  # Only when something landed since it last ran: a resume after a crash that
  # came before the check still gets it, a run that landed nothing does not.
  local d c
  d="$(grep -n '"event":"done"' "$JOURNAL" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  c="$(grep -n '"event":"project_check"' "$JOURNAL" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  if [[ -z "$d" || ( -n "$c" && "$c" -gt "$d" ) ]]; then
    log "project check: nothing landed since it last ran - skipped"
    return 0
  fi
  local logf="${RESULTS}/_check.log" t="${FA_PROJECT_VERIFY_TIMEOUT:-1800}" rc=0 landed
  mkdir -p "$RESULTS"
  landed="$(done_since project_check | describe_tasks)"
  log "project check: \`${cmd}\`"
  ( cd "$WORK" && timeout "$t" bash -c "$cmd" ) >"$logf" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    CHECK_RESULT=passed
    journal project_check - "result=passed" "cmd=${cmd}"
    log "project check passed"
    return 0
  fi
  local why="exited ${rc}"
  [[ $rc -eq 124 ]] && why="was cut off after ${t}s"
  log "project check FAILED: it ${why} - output in ${logf#"${PROJECT}"/}"
  if [[ "${FA_PROJECT_FIX:-1}" == "0" ]]; then
    CHECK_RESULT=failed
    journal project_check - "result=failed" "cmd=${cmd}" "rc=${rc}"
    return 1
  fi
  local prompt
  prompt="The project's own check fails, and it has to pass.

The check: \`${cmd}\`, run in the project root. It ${why}. The end of its output:

$(tail -n 60 "$logf" | cut -c1-300)

What just landed, and so the likeliest cause:
${landed:-(nothing recorded)}

Find what breaks the check and fix it in the code. The tests, CI files and the
project's other read-only files are part of the check, not the work: any change
to them is undone."
  log "project check: sending one worker to fix it"
  local frc=0 changed=()
  send_fixer _check "$prompt" "$cmd" || frc=$?
  mapfile -t changed < <(printf '%s' "$FIX_CHANGED" | sed '/^$/d')
  if [[ $frc -eq 0 ]]; then
    CHECK_RESULT=fixed
    journal project_check - "result=fixed" "cmd=${cmd}" "files=${changed[*]}"
    log "project check fixed by a worker${changed[*]:+ - it changed: ${changed[*]}}"
    # Committed when this run commits its work (isolated tasks, push mode): a
    # later worktree starts from HEAD and would never see an uncommitted fix.
    if [[ ${#changed[@]} -gt 0 ]] && { [[ $ISOLATE -eq 1 ]] || [[ "$WORK" != "$PROJECT" ]]; }; then
      commit_work "fa: fix the project check" "${changed[@]}" \
        || log "WARNING: the fix for the project check could not be committed"
    fi
    return 0
  fi
  CHECK_RESULT=failed
  journal project_check - "result=failed" "cmd=${cmd}" "rc=${rc}" "files=${changed[*]}"
  log "project check still fails after a worker tried - output in ${logf#"${PROJECT}"/}, the worker's in ${RESULTS#"${PROJECT}"/}/_check.err"
  return 1
}

# -------------------------------------------------------------- push mode --
# mode: push. A run's work goes onto a new branch, fa/<time>, built in its own
# worktree (.orch/worktrees/run) so your working directory is never switched
# or touched. Every task's declared files are committed there; at the end the
# branch is pushed (never forced), a pull request is opened, and fa waits for
# what GitHub reports on it - each failing check goes to a worker with its log,
# a bounded number of times. `automerge: true` then merges it, but only work
# something actually checked. A plan keeps its branch, and its pull request,
# while that is open; a new plan starts a new one.
PUSH_BRANCH=""; PUSH_BASE=""; PUSH_FROM=""; PUSHED_SHA=""

push_setup() {
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "mode: push needs the project to be a git repository"
  git -C "$PROJECT" remote get-url origin >/dev/null 2>&1 \
    || die "mode: push needs a remote named origin (git remote add origin <url>)"
  have gh || die "mode: push needs gh, the GitHub CLI"
  gh auth status >/dev/null 2>&1 || die "mode: push needs gh logged in: gh auth login"
  # Every gh call below means origin. With a second remote (a fork's upstream)
  # gh would otherwise ask which one - and with nobody there to answer, refuse.
  local origin_url re='github\.com[:/]([^/]+)/([^/]+)$'
  origin_url="$(git -C "$PROJECT" remote get-url origin 2>/dev/null)" || true
  if [[ "$origin_url" =~ $re ]]; then
    export GH_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  fi
  local dir="${WT_POOL_DIR}/run" last b url state=""
  mkdir -p "$WT_POOL_DIR"
  # A plan keeps its branch. The journal belongs to one plan (a new plan puts
  # it aside - plan_turnover), so its latest branch is this plan's: continue
  # it - on a resume, or the same plan run again - while its pull request is
  # open. Merged or closed, by fa or on GitHub, the next run starts anew.
  last="$(jq -c 'select(.event=="branch")' "$JOURNAL" 2>/dev/null | tail -1)" || true
  b="$(jq -r '.branch // empty' <<<"${last:-null}" 2>/dev/null)" || true
  if [[ -n "$b" ]]; then
    url="$(jq -rs --arg b "$b" '[.[] | select(.event=="pr" and .branch==$b)] | last | .url // empty' \
           "$JOURNAL" 2>/dev/null)" || true
    if [[ -n "$url" ]]; then
      if grep -qF "\"event\":\"merged\",\"task\":\"-\",\"url\":\"${url}\"" "$JOURNAL" 2>/dev/null; then
        state=MERGED
      else
        state="$( (cd / && gh pr view "$url" --json state -q .state) 2>/dev/null)" || true
      fi
    fi
    if [[ "$state" == MERGED || "$state" == CLOSED ]]; then
      log "push mode: ${b}'s pull request is ${state,,} - starting a new branch"
    elif [[ -e "${dir}/.git" ]] \
         && [[ "$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" == "$b" ]]; then
      PUSH_BRANCH="$b"
      PUSH_BASE="$(jq -r '.base' <<<"$last")"; PUSH_FROM="$(jq -r '.from' <<<"$last")"
      WORK="$dir"
      log "push mode: continuing ${PUSH_BRANCH}${url:+ and ${url}}"
      return 0
    else
      log "WARNING: push mode: ${b} cannot be continued - its worktree is gone or on another branch; starting a new branch, without the work of tasks already done (that stays on ${b})"
    fi
  fi
  PUSH_BASE="$(project_setting base)"; PUSH_BASE="${PUSH_BASE%%[[:space:]]#*}"
  if [[ -z "$PUSH_BASE" ]]; then
    PUSH_BASE="$(git -C "$PROJECT" symbolic-ref --short -q HEAD 2>/dev/null)" || true
  fi
  [[ -n "$PUSH_BASE" ]] \
    || die "mode: push needs a branch checked out, or base: <branch> in .orch/config.yaml"
  PUSH_FROM="$(git -C "$PROJECT" rev-parse -q --verify HEAD 2>/dev/null)" \
    || die "mode: push needs at least one commit to branch from"
  local stamp i=1; stamp="fa/$(date -u +%Y%m%d-%H%M%S)"; PUSH_BRANCH="$stamp"
  while git -C "$PROJECT" show-ref --verify -q "refs/heads/${PUSH_BRANCH}"; do
    i=$((i + 1)); PUSH_BRANCH="${stamp}-${i}"
  done
  # The previous run's worktree goes; its branch, and every commit on it, stays.
  if [[ -e "$dir" ]]; then
    git -C "$PROJECT" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
    git -C "$PROJECT" worktree prune >/dev/null 2>&1 || true
  fi
  git -C "$PROJECT" worktree add -q -b "$PUSH_BRANCH" "$dir" "$PUSH_FROM" >/dev/null 2>&1 \
    || die "mode: push could not create the run's worktree at ${dir}"
  WORK="$dir"
  journal branch - "branch=${PUSH_BRANCH}" "base=${PUSH_BASE}" "from=${PUSH_FROM}"
  log "push mode: building on a new branch, ${PUSH_BRANCH}, from ${PUSH_BASE} at ${PUSH_FROM:0:7} - in ${dir#"${PROJECT}"/}, not in your working directory"
}

push_branch() {
  local sha out
  sha="$(git -C "$WORK" rev-parse HEAD)"
  # Never forced: a branch someone else also pushed to is theirs to reconcile.
  # No terminal prompt either - a background job would wait on it forever.
  if ! out="$(GIT_TERMINAL_PROMPT=0 git -C "$WORK" push -q origin "HEAD:refs/heads/${PUSH_BRANCH}" 2>&1)"; then
    journal push_failed - "branch=${PUSH_BRANCH}" "error=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    log "push mode: push FAILED: ${out}"
    return 1
  fi
  PUSHED_SHA="$sha"
  journal pushed - "branch=${PUSH_BRANCH}" "sha=${sha}"
  log "pushed ${PUSH_BRANCH} (${sha:0:7})"
}

pr_open() { # $1=ids -> prints the pull request's URL
  local body="${RESULTS}/_pr.md" title out url draft=() id m
  {
    printf '## What this run did\n\n'
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      m="$(jq -rs --arg t "$id" '[.[] | select(.event=="done" and .task==$t)] | last
            | "\(.model // "?") on \(.bucket // "?")\(if .verified == "yes" then ", its own check passed" else "" end)"' \
            "$JOURNAL" 2>/dev/null)" || true
      printf -- '- **%s** - %s\n' "$(describe_tasks <<<"$id")" "$m"
    done <<<"$1"
    printf '\n## Checks\n\n'
    case "$CHECK_RESULT" in
      passed) printf -- '- The project check, `%s`, passed.\n' "$(project_setting verify)" ;;
      fixed)  printf -- '- The project check, `%s`, failed once; a worker fixed it.\n' "$(project_setting verify)" ;;
      failed) printf -- '- **The project check, `%s`, fails** - this is a draft until it passes.\n' "$(project_setting verify)" ;;
      *)      printf -- '- No project check is set (`verify:` in .orch/config.yaml).\n' ;;
    esac
    printf '\nBuilt by fa on `%s`, from `%s` at %s. Each task ran on a free model; its declared files are what landed.\n' \
      "$PUSH_BRANCH" "$PUSH_BASE" "${PUSH_FROM:0:7}"
  } > "$body"
  title="fa: $(printf '%s' "$1" | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//; s/ /, /g' | cut -c1-70)"
  if [[ "$CHECK_RESULT" == "failed" ]]; then draft=(--draft); fi
  if ! out="$(cd "$WORK" && gh pr create --head "$PUSH_BRANCH" --base "$PUSH_BASE" \
                --title "$title" --body-file "$body" "${draft[@]}" 2>&1)"; then
    journal pr_failed - "branch=${PUSH_BRANCH}" "error=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    log "push mode: could not open a pull request: ${out}"
    return 1
  fi
  url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1)" || true
  [[ -n "$url" ]] || { log "push mode: gh opened no pull request it could name: ${out}"; return 1; }
  journal pr - "branch=${PUSH_BRANCH}" "url=${url}"
  log "opened ${url}${draft[*]:+ (draft)}"
  printf '%s' "$url"
}

# What GitHub reports on a pushed commit - its check runs (GitHub Actions and
# other apps) and its commit statuses (older CI services) - from the API: gh's
# own `pr checks` has JSON output only in versions newer than many distros ship.
ci_rows() { # $1=sha -> "name<TAB>pending|pass|fail<TAB>link" per check
  ( cd "$WORK" && {
      gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" -q '.check_runs[]
        | [.name, (if .status != "completed" then "pending"
                   elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped")
                   then "pass" else "fail" end), (.html_url // "")] | @tsv'
      gh api "repos/{owner}/{repo}/commits/$1/status" -q '.statuses[]
        | [.context, (if .state == "pending" then "pending" elif .state == "success" then "pass"
                      else "fail" end), (.target_url // "")] | @tsv'
    } ) 2>/dev/null || true
  return 0
}

# Wait for every check on the commit to finish. Prints passed | failed | none
# | timeout; the failing rows go to ${RESULTS}/_ci.failed. Checks register a
# moment after a push, and not all at once, so "all finished" counts only when
# two looks in a row agree. And "nothing yet" becomes "none" only where nothing
# would run: a branch with a workflow that runs on pull requests WILL report,
# however long GitHub takes to start it - a new repository's first run took a
# minute in the first real trial, half of FA_CI_APPEAR, and "none" with a
# passing project check is enough to merge.
ci_wait() { # $1=sha
  local start rows prev="" poll="${FA_CI_POLL:-15}" expect=0
  if grep -qs 'pull_request' "$WORK"/.github/workflows/*.yml "$WORK"/.github/workflows/*.yaml; then
    expect=1
  fi
  start="$(now_epoch)"
  while :; do
    rows="$(ci_rows "$1" | sort)"
    if [[ -z "$rows" ]]; then
      if (( expect == 0 && $(now_epoch) - start >= ${FA_CI_APPEAR:-120} )); then echo none; return 0; fi
    elif ! grep -q $'\tpending\t' <<<"$rows"; then
      if [[ "$rows" == "$prev" ]]; then
        grep $'\tfail\t' <<<"$rows" > "${RESULTS}/_ci.failed" || true
        if [[ -s "${RESULTS}/_ci.failed" ]]; then echo failed; else echo passed; fi
        return 0
      fi
    fi
    prev="$rows"
    if (( $(now_epoch) - start >= ${FA_CI_TIMEOUT:-3600} )); then echo timeout; return 0; fi
    sleep "$poll"
  done
}

# One round of fixing what CI reported: the failing checks' logs to a worker,
# then commit and push what it changed. 0 when a fix was pushed.
ci_fix() { # $1=round
  local names logs="" name state link job prompt frc=0 changed=()
  names="$(cut -f1 "${RESULTS}/_ci.failed" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  while IFS=$'\t' read -r name state link; do
    job="$(grep -oE '/job/[0-9]+' <<<"$link" | grep -oE '[0-9]+$')" || true
    if [[ -n "$job" ]]; then
      logs+="--- ${name} ---"$'\n'"$( (cd "$WORK" && gh run view --job "$job" --log-failed 2>/dev/null) \
                                       | tail -n 80 | cut -c1-300)"$'\n'
    else
      logs+="--- ${name} --- no log reachable from here: ${link}"$'\n'
    fi
  done < "${RESULTS}/_ci.failed"
  prompt="CI fails on this branch's pull request, and it has to pass.

Failing: ${names}. What they report:

${logs}
Find what breaks them and fix it in the code. The tests, CI files and the
project's other read-only files are part of the check, not the work: any change
to them is undone."
  log "CI failed (${names}) - fix round $1/${FA_CI_FIX_ROUNDS:-2}: sending one worker"
  send_fixer "_ci$1" "$prompt" "$(project_setting verify)" || frc=$?
  mapfile -t changed < <(printf '%s' "$FIX_CHANGED" | sed '/^$/d')
  journal ci_fix - "round=$1" "checks=${names}" "rc=${frc}" "files=${changed[*]}"
  if [[ $frc -ne 0 || ${#changed[@]} -eq 0 ]]; then
    log "the worker could not fix it${changed[*]:+ (it changed: ${changed[*]})}"
    return 1
  fi
  commit_work "fa: fix CI (${names})" "${changed[@]}" || { log "could not commit the CI fix"; return 1; }
  push_branch
}

pr_merge() { # $1=url
  local m out=""
  for m in --merge --squash --rebase; do   # whichever the repository allows
    if out="$(cd / && gh pr merge "$1" "$m" 2>&1)"; then
      journal merged - "url=$1" "method=${m#--}"
      log "merged ${1} (${m#--}) - git pull in your project to get it"
      return 0
    fi
  done
  journal merge_failed - "url=$1" "error=$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  log "automerge FAILED for ${1}: ${out}"
  return 1
}

push_finish() { # -> 0 when the work is pushed and nothing reported on it failed
  if [[ "$(git -C "$WORK" rev-list --count "${PUSH_FROM}..HEAD" 2>/dev/null || echo 0)" -eq 0 ]]; then
    log "push mode: nothing was committed on ${PUSH_BRANCH} - nothing to push"
    return 0
  fi
  # The same plan run again with nothing new: the branch is as pushed, and CI
  # has already had its say on that commit.
  local last_sha last_ci
  last_sha="$(jq -rs --arg b "$PUSH_BRANCH" '[.[] | select(.event=="pushed" and .branch==$b)] | last | .sha // empty' \
              "$JOURNAL" 2>/dev/null)" || true
  if [[ -n "$last_sha" && "$(git -C "$WORK" rev-parse HEAD)" == "$last_sha" ]]; then
    last_ci="$(jq -rs --arg s "$last_sha" '[.[] | select(.event=="ci" and .sha==$s)] | last | .result // empty' \
               "$JOURNAL" 2>/dev/null)" || true
    log "push mode: nothing new on ${PUSH_BRANCH} since ${last_sha:0:7} was pushed${last_ci:+ (CI: ${last_ci})}"
    [[ "$last_ci" != failed && "$last_ci" != timeout ]]
    return
  fi
  push_branch || return 1
  local url
  url="$(jq -rs --arg b "$PUSH_BRANCH" '[.[] | select(.event=="pr" and .branch==$b)] | last | .url // empty' \
         "$JOURNAL" 2>/dev/null)" || true
  if [[ -n "$url" ]]; then
    log "pull request: ${url} (updated)"
  else
    url="$(pr_open "$(done_since branch)")" || return 1
  fi
  if [[ "$CHECK_RESULT" == "failed" ]]; then
    log "push mode: the project check fails, so nothing waits on CI and nothing merges"
    return 1
  fi
  local result round=0
  while :; do
    log "waiting for the checks on ${PUSHED_SHA:0:7}"
    result="$(ci_wait "$PUSHED_SHA")"
    journal ci - "result=${result}" "sha=${PUSHED_SHA}" \
      "checks=$( [[ "$result" == failed ]] && cut -f1 "${RESULTS}/_ci.failed" | sort -u | tr '\n' ',' | sed 's/,$//' )"
    [[ "$result" == failed && $round -lt ${FA_CI_FIX_ROUNDS:-2} ]] || break
    round=$((round + 1))
    ci_fix "$round" || break
  done
  case "$result" in
    passed)  log "CI passed on ${url}" ;;
    none)    log "no checks reported on ${url} within ${FA_CI_APPEAR:-120}s - none configured?" ;;
    timeout) log "CI still running on ${url} after ${FA_CI_TIMEOUT:-3600}s - not waiting longer" ;;
    failed)  log "CI FAILED on ${url}: $(cut -f1 "${RESULTS}/_ci.failed" | sort -u | tr '\n' ' ')" ;;
  esac
  if [[ "$(project_automerge)" == "true" ]]; then
    # Only work something checked: CI passing, or - with no CI at all - the
    # project check. Nothing checked means nothing to trust.
    if [[ "$result" == passed ]] \
       || [[ "$result" == none && ( "$CHECK_RESULT" == passed || "$CHECK_RESULT" == fixed ) ]]; then
      pr_merge "$url" || return 1
    else
      journal merge_skipped - "url=${url}" "ci=${result}" "check=${CHECK_RESULT:-none}"
      log "automerge: leaving ${url} open - CI ${result}, project check ${CHECK_RESULT:-not set}"
    fi
  fi
  [[ "$result" == passed || "$result" == none ]]
}

cmd_run() {
  [[ -f "$TASKS_FILE" ]] || die "no task graph at $TASKS_FILE"
  jq -e '.tasks | type == "array" and length > 0' "$TASKS_FILE" >/dev/null \
    || die "$TASKS_FILE has no tasks"

  write_orch_gitignore
  # One run per project at a time. While runs only happened in the foreground,
  # two at once took two people starting them; `fa dispatch --detach` makes it
  # one stray command, and two runs replaying one journal would each dispatch
  # the same pending tasks. Held by this process alone - run_task closes it - so
  # a worker still running after its orchestrator died never blocks the resume
  # that is meant to recover from exactly that.
  exec {RUN_LOCK_FD}>"${ORCH_DIR}/.run.lock"
  flock -n "$RUN_LOCK_FD" || die "a run is already in progress in this project - see: fa jobs, fa status"
  plan_turnover
  RESERVED_JSON="$(coordinator_buckets_json)"
  [[ "$RESERVED_JSON" != "[]" ]] && log "held back for the coordinator ($(coordinator_agent)), its own wallet: $(jq -r 'join(" ")' <<<"$RESERVED_JSON")"
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
  if [[ "$mode" == "push" && $DRY_RUN -eq 0 ]]; then push_setup; fi
  log "project=$PROJECT  parallel=$width  mode=$mode  isolate=$ISOLATE${PUSH_BRANCH:+  branch=$PUSH_BRANCH}"

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
  local todo remaining id pid finished progressed orphan_ids onway

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
      # Tasks still on their way to a lane are counted FIRST, held leases
      # second: one that takes its lane in between is then counted twice (one
      # launch too few, made up on the next pass). The other order counts it
      # not at all - one launch too many, straight into exit 5.
      if [[ $DRY_RUN -eq 0 && ${#RUNNING[@]} -gt 0 ]]; then
        onway="$(unleased_running)"
        [[ $(( $(free_lanes) - onway )) -gt 0 ]] || break
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
      rm -f "${RESULTS}/${id}.leased"
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
    rm -f "${RESULTS}/${finished}.leased"

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
  # What landed, checked together (project_check), and in push mode taken to a
  # pull request (push_finish).
  local check_ok=0 push_ok=0
  if [[ $DRY_RUN -eq 0 ]]; then
    project_check || check_ok=1
    if [[ -n "$PUSH_BRANCH" ]]; then push_finish || push_ok=1; fi
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
  [[ "$nfail" -eq 0 && $check_ok -eq 0 && $push_ok -eq 0 ]]
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
         | "  done    \(.task)  <- \(.bucket // "?")  \(.model // "")\(if .verified == "yes" then "  (verified)" else "" end)"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="failed") | "  FAILED  \(.task)"' "$JOURNAL" | sort -u
  # What a worker did outside its task: read-only files it changed (put back
  # before any check ran), and files it changed without declaring them.
  jq -r 'select(.event=="protected")
         | "  note    \(.task): read-only files it changed were put back: \(.files)"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="undeclared")
         | "  note    \(.task): changed files it did not declare (\(.fate)\(if .patch then "; patch: \(.patch)" else "" end)): \(.files)"' "$JOURNAL" | sort -u
  # A verify command that never passed: the work exists but does not do what
  # the task said it must. Shown with the command, so it can be run by hand.
  jq -r 'select(.event=="verify_failed")
         | "  VERIFY FAILED  \(.task)  `\(.cmd)` after \(.rounds) fix round(s)"' "$JOURNAL" | sort -u
  jq -r 'select(.event=="skipped") | "  SKIPPED \(.task)  (when clause not satisfied)"' "$JOURNAL" | sort -u
  # The project check, as it last ran.
  jq -rs '[.[] | select(.event=="project_check")] | last // empty
          | if .result == "failed" then "  CHECK FAILED  `\(.cmd)`  output: .orch/results/_check.log"
            elif .result == "fixed" then "  check   fixed   `\(.cmd)`\(if (.files // "") != "" then "  a worker changed: \(.files)" else "" end)"
            else "  check   passed  `\(.cmd)`" end' "$JOURNAL" 2>/dev/null || true
  # Push mode: the latest branch, its pull request, what CI said, the merge.
  jq -rs '. as $j
    | ([range(0; $j | length)] | map(select($j[.].event == "branch")) | last) as $i
    | if $i == null then empty else
        $j[$i] as $b | $j[$i + 1:] as $a
        | ($a | map(select(.event == "pushed")) | last) as $push
        | ($a | map(select(.event == "pr")) | last) as $pr
        | ($a | map(select(.event == "ci")) | last) as $ci
        | ($a | map(select(.event == "ci_fix")) | length) as $fixes
        | ($a | map(select(.event == "pushed" or .event == "push_failed" or .event == "pr"
                           or .event == "pr_failed" or .event == "merged" or .event == "merge_failed"
                           or .event == "merge_skipped")) | last) as $last
        | "  branch  \($b.branch) -> \($b.base)\(if $push then "  pushed \($push.sha[0:7])" else "  not pushed yet" end)",
          (if $pr then "  PR      \($pr.url)" else empty end),
          (if $ci == null then empty
           elif $ci.result == "failed" then "  CI FAILED  \($ci.checks)\(if $fixes > 0 then "  after \($fixes) fix round(s)" else "" end)"
           elif $ci.result == "passed" then "  CI      passed\(if $fixes > 0 then " after \($fixes) fix round(s)" else "" end)"
           elif $ci.result == "none" then "  CI      no checks reported"
           else "  CI      still running when fa stopped waiting" end),
          (if $last.event == "merged" then "  merged  (\($last.method))"
           elif $last.event == "merge_skipped" then "  not merged: CI \($last.ci), project check \($last.check)"
           elif ($last.event // "" | test("_failed$")) then "  PUSH ERROR  \($last.event): \($last.error // "")"
           else empty end)
      end' "$JOURNAL" 2>/dev/null || true
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
#   history/        NO  - earlier plans' journals, put aside by a new plan.
write_orch_gitignore() {
  mkdir -p "$ORCH_DIR"
  # Never clobber a hand-edited file - but do repair the lines an older version
  # left out, or what they cover stays tracked forever: handoffs/ (an older
  # setup.sh) and jobs/ (background jobs, which came later).
  if [[ -f "${ORCH_DIR}/.gitignore" ]]; then
    local line
    for line in handoffs/ jobs/ history/; do
      grep -qx "$line" "${ORCH_DIR}/.gitignore" \
        || printf '%s\n' "$line" >> "${ORCH_DIR}/.gitignore"
    done
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
jobs/
history/
EOF
}

cmd_init() {
  mkdir -p "$ORCH_DIR" "$RESULTS"
  [[ -f "$TASKS_FILE" ]] || echo '{"tasks":[]}' > "$TASKS_FILE"
  
  # Create default .orch/config.yaml if not present
  if [[ ! -f "${ORCH_DIR}/config.yaml" ]]; then
    cat > "${ORCH_DIR}/config.yaml" <<'EOF'
# What fa does with a run's work once its tasks are done:
#   strict  - leave it in the project for you to review (default)
#   local   - the same, and never touches a remote
#   push    - put it on a new branch (in its own worktree - your working
#             directory is left alone), push it, open a pull request, wait for
#             CI and send a worker to fix what CI reports. Needs git, an origin
#             remote and gh logged in. A plan keeps its branch while its pull
#             request is open; a new plan starts a new one.
mode: strict

# push mode: merge the pull request once its checks pass - only work something
# checked (CI, or the project check where there is no CI)
automerge: false

# push mode: the branch pull requests go into (default: the one checked out)
# base: main

# Files no worker may change: globs over paths relative to the project,
# separated by spaces (* matches across directories). A worker's edits to them
# are put back before any check runs - so it cannot pass its verify by editing
# the tests - and a task may still write any file it declares in its "files".
readonly: tests/* test/* spec/* __tests__/* src/test/* */tests/* */test/* */__tests__/* */src/test/* *.Tests/* *.test.* *.spec.* *_test.* .github/*

# The project's own check, run where a run's work landed once its tasks are
# done (bash -c, in the project root). Each task's verify proves that task;
# this proves them together. When it fails, one worker is sent to fix it.
# For example: npm test | dotnet test | ./gradlew test | pytest
# In push mode it runs in a fresh checkout, with no node_modules or .venv:
# install first if the check needs them (npm ci && npm test).
verify:
EOF
    log "created ${ORCH_DIR}/config.yaml (mode: strict)"
  fi
  
  write_orch_gitignore
  echo "initialised $ORCH_DIR"
}

usage() { sed -n '6,/^$/p' "$0" >&2; exit 3; }

CMD="${1:-}"; shift || true
# Before the option loop: a positional after `run` is copied over tasks.json
# right there, and a worker must not get even that far (common.sh).
case "$CMD" in run|resume) refuse_if_worker "orch.sh $CMD" ;; esac
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
