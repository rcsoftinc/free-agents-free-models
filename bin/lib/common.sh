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

registry_read() { # $1=jq program; remaining args passed to jq
  local prog="$1"; shift
  [[ -f "$REGISTRY" ]] || die "no registry; run: bin/buckets.sh discover"
  jq -r "$@" "$prog" "$REGISTRY"
}
