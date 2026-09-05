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

# The system dependencies every entry point needs, and the SINGLE canonical list
# of harnesses the tool can drive. Both are sourced here so setup.sh, fa,
# buckets.sh and run.sh ask the same question and can never drift apart.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
. "${_LIB_DIR}/deps.sh"
# shellcheck source=lib/adapters.sh
. "${_LIB_DIR}/adapters.sh"
unset _LIB_DIR

now_epoch() { date +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

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
