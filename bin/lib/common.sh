# common.sh - shared paths, logging and registry access.
# Source, do not execute.

# State is MACHINE-WIDE by default: one registry serves every project on this box.
#
# It lived inside the clone for a while, which made a project self-contained but
# had a real hazard: leases are files in this directory, so two projects running
# at once could not see each other's locks and could dispatch onto the SAME
# wallet simultaneously - exactly the collision this design exists to prevent.
# A machine-wide directory makes leasing work across projects, and stops every
# new project re-probing credentials it already knew about.
#
# The trade: deleting a project's .free-agents/ no longer removes everything.
# Set FREE_AGENTS_STATE=<clone>/state to go back to per-project isolation.
#
# NOTE: no secrets are stored here. Credentials stay in each agent's own config;
# this keeps only sha256 FINGERPRINTS, which is what lets it tell two wallets
# apart without ever holding a key.
STATE_DIR="${FREE_AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/free-agents}"
REGISTRY="${STATE_DIR}/buckets.json"
REGISTRY_LOCK="${STATE_DIR}/.registry.lock"

log()  { printf '[%s] %s\n' "${LOG_TAG:-free-agents}" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "${LOG_TAG:-free-agents}" "$*" >&2; exit 3; }
have() { command -v "$1" >/dev/null 2>&1; }

# Workers never dispatch. Every agent fa launches is a WORKER: adapter_invoke
# hands it FA_DEPTH=1, which its shell commands inherit whichever of the seven
# CLIs it is. Anything that would launch agents in turn refuses inside one.
# AGENTS.md is read by every agent, workers included, so without this a worker
# that decided to hand its task on would start another layer of workers, each
# free to do the same. A prompt can ask a free model not to; only this enforces
# it. Exit 6, so no caller can mistake it for run.sh's requeue (5) or failure (2).
refuse_if_worker() { # $1=what was attempted
  local d="${FA_DEPTH:-0}"
  [[ "$d" =~ ^[0-9]+$ && "$d" -ge 1 ]] || return 0
  printf '[fa] REFUSED: %s inside a worker (FA_DEPTH=%s).\n' "$1" "$d" >&2
  printf '[fa] fa launched you to do one task: do it here, directly. Nothing you start may launch agents.\n' >&2
  exit 6
}

# The system dependencies every entry point needs, and the SINGLE canonical list
# of harnesses the tool can drive. Both are sourced here so setup.sh, fa,
# buckets.sh and run.sh ask the same question and can never drift apart.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
. "${_LIB_DIR}/deps.sh"
# shellcheck source=lib/adapters.sh
. "${_LIB_DIR}/adapters.sh"
unset _LIB_DIR

# ---------------------------------------------------- the coordinator's lane --
# The coordinator is the agent the director talks to, and while it talks it
# spends requests on its own wallet. A worker on that same wallet races it into
# one rate limit: the director's conversation starts failing exactly while a
# build runs - the normal case since --detach, when the coordinator keeps
# talking instead of waiting.
#
# coordinator_agent -> the adapter this fa process runs under (opencode, kilo,
# ...), or nothing: a plain terminal, cron, or an agent fa has no adapter for
# (claude, ...), which is on none of fa's lanes. Found by walking up the process
# tree to the first agent CLI: by process name, by the script an interpreter
# runs (copilot and pi are node scripts), or - for a name of 4+ characters - by
# a directory in its path (cursor-agent's real process is node .../cursor-agent/
# .../index.js). FA_COORDINATOR overrides it: a background job gets it at detach
# time, since once reparented its ancestry is gone, and "none" switches the
# reservation off. Linux /proc only; elsewhere nothing is detected or reserved.
coordinator_agent() {
  if [[ -n "${FA_COORDINATOR:-}" ]]; then
    [[ "$FA_COORDINATOR" == none ]] || printf '%s' "$FA_COORDINATOR"
    return 0
  fi
  local names=() owners=() ag b v i p="$PPID" comm a0 a1 stat
  for ag in "${FA_AGENTS[@]}"; do
    v="FA_${ag}_BINARY"; IFS=',' read -ra v <<<"${!v:-}"
    for b in "${v[@]}"; do names+=("$b"); owners+=("$ag"); done
  done
  for ((i = 0; i < 40 && p > 1; i++)); do
    [[ -r "/proc/$p/comm" ]] || return 0
    comm="$(< "/proc/$p/comm")"; a0=""; a1=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "/proc/$p/cmdline" 2>/dev/null || true
    for ((b = 0; b < ${#names[@]}; b++)); do
      _proc_is "${names[$b]}" "$comm" "$a0" "$a1" && { printf '%s' "${owners[$b]}"; return 0; }
    done
    for b in "${FA_KNOWN_UNSUPPORTED[@]}"; do
      _proc_is "$b" "$comm" "$a0" "$a1" && return 0
    done
    stat="$(< "/proc/$p/stat")" || return 0
    stat="${stat##*) }"           # past "pid (comm) " - comm may contain spaces
    read -r _ p _ <<<"$stat"       # what is left starts: state ppid ...
  done
}

_proc_is() { # $1=binary $2=comm $3=argv0 $4=argv1 -> 0 if that process is it
  local b="$1"
  [[ "$2" == "$b" || "${3##*/}" == "$b" || "${4##*/}" == "$b" ]] && return 0
  [[ ${#b} -ge 4 && ( "$3" == */"$b"/* || "$4" == */"$b"/* ) ]]
}

# -> bucket ids held back from workers: every bucket the coordinator's agent can
# reach. Which one its TUI uses right now is that TUI's own setting, out of reach
# from here, so all of them - costing a lane when one agent reaches two wallets.
# Never every lane, though: when no other bucket has a free model, nothing is
# held back and the work shares the coordinator's - waiting for a lane that can
# never free up would help nobody.
coordinator_buckets() {
  local ag; ag="$(coordinator_agent)"
  [[ -n "$ag" && -f "$REGISTRY" ]] || return 0
  jq -r --arg a "$ag" '
    [ .buckets[] | select([.models[] | select(.free)] | length > 0) ] as $b
    | [ $b[] | select((.reachable_via // []) | index($a)) | .id ] as $mine
    | if ([ $b[] | select(.id | IN($mine[]) | not) ] | length) > 0
      then $mine[] else empty end' "$REGISTRY" 2>/dev/null || true
}

# The same, as a JSON array for jq programs (--argjson).
coordinator_buckets_json() { coordinator_buckets | jq -R . | jq -sc 'map(select(length > 0))'; }

now_epoch() { date +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Wall clock in milliseconds, for timing an attempt. Not `date +%s%3N`: that is
# GNU-only. uutils coreutils (date on Ubuntu 26.04) ignores the 3 and prints all
# nine nanosecond digits, and BSD date has no %N at all - so every recorded
# duration came out a million times too large, or as noise. bash 5's
# EPOCHREALTIME is the same clock without a fork; its decimal mark follows the
# locale, hence the digit strip.
now_ms() {
  local us="${EPOCHREALTIME//[!0-9]/}"
  if [[ -n "$us" ]]; then printf '%s' "$(( us / 1000 ))"
  else printf '%s' "$(( $(date +%s) * 1000 ))"; fi
}

# Read-modify-write the registry atomically. Concurrent tasks share this file,
# so every mutation goes through here - a lost update would silently resurrect a
# bucket that another worker just put into cooldown.
registry_txn() { # $1=jq program; remaining args passed to jq
  local prog="$1"; shift
  mkdir -p "$STATE_DIR"
  ( flock -w 20 9 || { echo "registry lock timeout" >&2; exit 3; }
    [[ -f "$REGISTRY" ]] || die "no registry; run: bin/buckets.sh discover"
    jq "$@" "$prog" "$REGISTRY" > "${REGISTRY}.txn" \
      && mv "${REGISTRY}.txn" "$REGISTRY"
  ) 9>"$REGISTRY_LOCK"
}

# Is the registry worth trusting? Age is the WRONG question - health and rankings
# self-correct at runtime and never go stale, while a credential you added is
# invisible until rediscovery no matter how recent the file is.
#
# So compare FINGERPRINTS, not timestamps. mtime is unusable here: the nous OAuth
# token rotates hourly and kilo writes session rows on every invocation, so both
# config files look "changed" constantly. Fingerprints are immune - the nous one
# is the JWT subject claim, stable across rotation.
#
# Echoes: missing | stale:credentials | stale:new-agent | aged:<days> | current
REGISTRY_MAX_AGE_DAYS="${REGISTRY_MAX_AGE_DAYS:-14}"

registry_status() {
  [[ -f "$REGISTRY" ]] || { printf 'missing'; return; }

  # Compare against every credential the last pass EXAMINED, not against the
  # buckets it produced: a key that reached no free model yields no bucket, and
  # would otherwise look new forever. Older registries predate `identified` and
  # fall back to bucket keys.
  local live reg
  live="$("$(dirname "${BASH_SOURCE[0]}")/../buckets.sh" identify 2>/dev/null \
          | grep -oE 'bucket=[^ ]+' | sed 's/bucket=//' | sort -u)"
  reg="$(jq -r '(.identified // (.buckets|keys))[]' "$REGISTRY" 2>/dev/null | sort -u)"
  if [[ -n "$live" ]] && [[ -n "$(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$reg"))" ]]; then
    printf 'stale:credentials'; return
  fi

  # An agent installed since the last discovery contributes no lane until refresh.
  # Only an agent that was never EXAMINED is a reason to refresh. One that was
  # examined and reached nothing (no key for it) is a known fact, not stale news.
  # Iterates the adapter list - a new harness must never be invisible here.
  local a seen
  seen="$(jq -r '(.examined_agents // [.buckets[].models[].routes[].agent])|unique[]' \
          "$REGISTRY" 2>/dev/null)"
  for a in "${FA_AGENTS[@]}"; do
    adapter_installed "$a" || continue
    printf '%s\n' "$seen" | grep -qx "$a" || { printf 'stale:new-agent'; return; }
  done

  local built age
  built="$(jq -r '.generated_at // empty' "$REGISTRY" 2>/dev/null)"
  if [[ -n "$built" ]]; then
    age=$(( ( $(date +%s) - $(date -d "$built" +%s 2>/dev/null || echo 0) ) / 86400 ))
    [[ "$age" -gt "$REGISTRY_MAX_AGE_DAYS" ]] && { printf 'aged:%s' "$age"; return; }
  fi
  printf 'current'
}

registry_age_days() {
  local built; built="$(jq -r '.generated_at // empty' "$REGISTRY" 2>/dev/null)"
  [[ -z "$built" ]] && { printf '?'; return; }
  printf '%s' $(( ( $(date +%s) - $(date -d "$built" +%s 2>/dev/null || echo 0) ) / 86400 ))
}

registry_read() { # $1=jq program; remaining args passed to jq
  local prog="$1"; shift
  [[ -f "$REGISTRY" ]] || die "no registry; run: bin/buckets.sh discover"
  jq -r "$@" "$prog" "$REGISTRY"
}

# Read-modify-write an arbitrary JSON file atomically - NOT the registry, an
# AGENT'S OWN credential file (opencode's auth.json, pi's auth.json, kilo's
# kilo.jsonc). Used by the optional <agent>_provision_key adapter functions so
# `setup.sh` can add a key non-interactively instead of requiring each agent's
# own interactive login flow.
#
# Refuses rather than clobbers when the target exists and is not plain JSON -
# kilo.jsonc in particular may carry comments a jq merge would silently drop.
# A failed merge leaves the real file untouched: the seed for a missing file is
# a throwaway temp, never the target itself, so nothing is written until the
# atomic `mv` at the end.
json_merge_file() { # $1=file $2=jq filter; remaining args -> jq (e.g. --arg k v)
  local file="$1" filter="$2"; shift 2
  mkdir -p "$(dirname "$file")"
  local seed
  if [[ -f "$file" ]]; then
    jq -e . "$file" >/dev/null 2>&1 || {
      log "refusing to touch $file - not plain JSON (comments?); add the key by hand"
      return 1
    }
    seed="$file"
  else
    seed="$(mktemp)"; printf '{}' > "$seed"
  fi
  local rc=0
  jq "$@" "$filter" "$seed" > "${file}.tmp" && mv "${file}.tmp" "$file" && chmod 600 "$file" || rc=$?
  if [[ "$seed" != "$file" ]]; then rm -f "$seed"; fi
  return $rc
}
