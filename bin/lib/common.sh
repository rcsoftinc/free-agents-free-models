# common.sh - shared paths, logging and registry access.
# Source, do not execute.

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
