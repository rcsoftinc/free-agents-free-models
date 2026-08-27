#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh - one-time setup bridge: .env -> opencode's auth.json
#
# opencode does NOT read .env files; this script does it for the skill.
# auth.json belongs to OPENCODE (~/.local/share/opencode/auth.json) - we only
# merge entries into it, never remove. You maintain .env exclusively.
#
# Usage:
#   bootstrap.sh [--env-file PATH] [--force] [--no-refresh] [--self-test]
#
# .env resolution order (first found wins):
#   1. --env-file argument
#   2. $PWD/.env                      (project root convention)
#   3. $PKG_ROOT/.env                 (skill folder)
#   4. $HOME/.config/opencode-free-agents/.env (machine-global)
#   5. none -> keep existing credentials as-is (additive-only, never fails)
#
# Safety: auth.json is backed up before first modification in a run,
#         created with chmod 600, keys are NEVER printed (masked).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE=""
FORCE=0
NO_REFRESH=0
SELF_TEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)  ENV_FILE="$2"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    --no-refresh) NO_REFRESH=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 3 ;;
  esac
done

log()  { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

command -v jq      >/dev/null || die "jq not found (apt install jq)"
command -v opencode >/dev/null || die "opencode not found on PATH"

mask() { # sk-or-v1-abcdef...wxyz -> sk-o...wxyz
  local k="$1"
  if [[ ${#k} -le 10 ]]; then printf '%s' "***"; else printf '%s...%s' "${k:0:4}" "${k: -4}"; fi
}

# --- safe KEY=VALUE parser (never executes file content) --------------------
# outputs lines of "KEY<TAB>VALUE"
parse_env() {
  local f="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}" val="${line#*=}"
    key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="${val%$'\r'}"
    # strip surrounding single or double quotes
    if [[ ${#val} -ge 2 ]]; then
      case "$val" in
        \"*\") val="${val:1:${#val}-2}" ;;
        \'*\') val="${val:1:${#val}-2}" ;;
      esac
    fi
    [[ -z "$key" || -z "$val" ]] && continue
    printf '%s\t%s\n' "$key" "$val"
  done < "$f"
}

# --- alias map: ENV VAR NAME -> opencode provider id ------------------------
alias_to_provider() {
  case "$1" in
    OPENROUTER_API_KEY)   echo "openrouter" ;;
    FREEMODEL_API_KEY)    echo "freemodel" ;;
    OPENCODE_ZEN_API_KEY) echo "opencode" ;;
    ANTHROPIC_API_KEY)    echo "anthropic" ;;
    OPENAI_API_KEY)       echo "openai" ;;
    GROQ_API_KEY)         echo "groq" ;;
    DEEPSEEK_API_KEY)     echo "deepseek" ;;
    NVIDIA_API_KEY)       echo "nvidia" ;;
    TOGETHER_API_KEY)     echo "together-ai" ;;
    MISTRAL_API_KEY)      echo "mistral" ;;
    XAI_API_KEY)          echo "xai" ;;
    KILO_GATEWAY_API_KEY) echo "kilo" ;;
    *)                    echo "" ;;
  esac
}

# --- key format validation: provider id + key -> 0 ok / 1 mismatch -----------
validate_key() {
  local id="$1" key="$2"
  case "$id" in
    openrouter) [[ "$key" == sk-or-v1-* ]] && return 0 || return 1 ;;
    freemodel)  [[ "$key" == fe_* ]]       && return 0 || return 1 ;;
    opencode)   [[ "$key" == sk-* && "$key" != sk-or-v1-* ]] && return 0 || return 1 ;;
    kilo)       [[ "$key" != sk-or-v1-* ]] && return 0 || return 1 ;;
    *)          return 0 ;;  # unknown provider: accept any format
  esac
}

# ============================================================================
if [[ $SELF_TEST -eq 1 ]]; then
  # Runs the whole merge logic inside a sandbox; touches nothing real.
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  cat > "$T/.env" <<'EOF'
# comment
OPENROUTER_API_KEY="sk-or-test-1234567890abcd"

FREEMODEL_API_KEY='fe_test_9876543210'
PROVIDER_1_ID=my-provider
PROVIDER_1_KEY=pk_custom_42
PROVIDER_2_ID=openrouter
PROVIDER_2_KEY=ignored_duplicate
EOF
  export OPENCODE_AUTH="$T/auth.json"
  export OC_SELF_TEST=1
  bash "$SCRIPT_DIR/bootstrap.sh" --env-file "$T/.env" --no-refresh || { echo "SELF-TEST FAIL (run)"; exit 1; }
  n=$(jq 'length' "$T/auth.json")
  ok1=$(jq -r '.openrouter.key' "$T/auth.json")
  ok2=$(jq -r '.freemodel.key' "$T/auth.json")
  ok3=$(jq -r '.["my-provider"].key' "$T/auth.json")
  t1=$(jq -r '.openrouter.type' $T/auth.json)
  perms=$(stat -c '%a' "$T/auth.json")
  os="$(uname -s)"
  pass=1
  [[ "$n" == "3" ]]            || { warn "expected 3 providers, got $n"; pass=0; }
  [[ "$ok1" == "sk-or-test-1234567890abcd" ]] || { warn "openrouter key wrong"; pass=0; }
  [[ "$ok2" == "fe_test_9876543210" ]]        || { warn "freemodel key wrong"; pass=0; }
  [[ "$ok3" == "pk_custom_42" ]]              || { warn "generic block wrong"; pass=0; }
  [[ "$t1" == "api" ]]         || { warn "type wrong"; pass=0; }
  # chmod 600 enforced on Linux; MSYS/NTFS emulates it as 644 - accept both there
  if [[ "$os" == "Linux" ]]; then [[ "$perms" == "600" ]] || { warn "perms wrong: $perms"; pass=0; }
  else [[ "$perms" == "600" || "$perms" == "644" ]] || { warn "perms wrong: $perms"; pass=0; }; fi
  if [[ $pass -eq 1 ]]; then echo "SELF-TEST PASS"; exit 0; else echo "SELF-TEST FAIL"; exit 1; fi
fi

# --- locate .env -------------------------------------------------------------
if [[ -z "$ENV_FILE" ]]; then
  for cand in "$PWD/.env" "$PKG_ROOT/.env" "$HOME/.config/opencode-free-agents/.env"; do
    if [[ -f "$cand" ]]; then ENV_FILE="$cand"; break; fi
  done
fi

# --- locate auth.json (opencode's own store) ---------------------------------
AUTH_FILE="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"
AUTH_DIR="$(dirname "$AUTH_FILE")"

merged=0 skipped=0

do_merge() { # id key type
  local id="$1" key="$2" type="${3:-api}"
  mkdir -p "$AUTH_DIR"
  if [[ ! -f "$AUTH_FILE" ]]; then
    printf '{}\n' > "$AUTH_FILE"
  fi
  # backup once per run before first write
  if [[ ! -f "$AUTH_FILE.bak.bootstrap" ]]; then
    cp "$AUTH_FILE" "$AUTH_FILE.bak.bootstrap"
  fi
  local existing=""
  existing="$(jq -r --arg id "$id" '.[$id].key // ""' "$AUTH_FILE" 2>/dev/null || echo "")" || true
  if [[ "$existing" == "$key" ]]; then
    ((skipped+=1)); return 0
  fi
  if [[ -n "$existing" && $FORCE -eq 0 ]]; then
    log "[$id] already configured (${existing:0:6}...) - keeping existing (use --force to override)"
    ((skipped+=1)); return 0
  fi
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg k "$key" --arg t "$type" \
     '.[$id] = {"type": $t, "key": $k}' "$AUTH_FILE" > "$tmp" && mv "$tmp" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE" 2>/dev/null || true
  log "[$id] merged key $(mask "$key")"
  ((merged+=1))
}

if [[ -n "$ENV_FILE" ]]; then
  log "using env file: $ENV_FILE"
  declare -A seen_generic_ids=()
  while IFS=$'\t' read -r key val; do
    pid="$(alias_to_provider "$key")"
    if [[ -n "$pid" ]]; then
      if validate_key "$pid" "$val"; then
        do_merge "$pid" "$val" api
      else
        warn "[$pid] key format mismatch (expected prefix for $pid) - skipped"
        ((skipped+=1))
      fi
    elif [[ "$key" =~ ^PROVIDER_([0-9]+)_ID$ ]]; then
      idx="${BASH_REMATCH[1]}"
      seen_generic_ids["$idx"]="$val"
    fi
  done < <(parse_env "$ENV_FILE")

  # second pass: resolve PROVIDER_N_KEY/_TYPE for collected ids
  while IFS=$'\t' read -r key val; do
    if [[ "$key" =~ ^PROVIDER_([0-9]+)_KEY$ ]]; then
      idx="${BASH_REMATCH[1]}"
      id="${seen_generic_ids[$idx]:-}"
      [[ -z "$id" ]] && { warn "$key without matching PROVIDER_${idx}_ID - skipped"; continue; }
      type="$(parse_env "$ENV_FILE" | awk -F'\t' -v k="PROVIDER_${idx}_TYPE" '$1==k {print $2; exit}')"
      do_merge "$id" "$val" "${type:-api}"
    fi
  done < <(parse_env "$ENV_FILE")
else
  log "no .env found (looked at \$PWD/.env, skill folder, ~/.config/opencode-free-agents/.env)"
fi

if [[ $merged -eq 0 && $skipped -eq 0 ]]; then
  log "nothing to merge - continuing with existing credentials"
fi

chmod 600 "$AUTH_FILE" 2>/dev/null || true

# --- sanity check --------------------------------------------------------------
if [[ "${OC_SELF_TEST:-0}" == "1" ]]; then
  log "self-test mode: skipping opencode sanity check"
else
  model_count="$(opencode models 2>/dev/null | grep -c . || true)"
  if [[ "${model_count:-0}" -eq 0 ]]; then
    die "opencode models returned nothing - keys may be invalid or network down"
  fi
  log "sanity ok: $model_count models available"
fi

if [[ "${OC_SELF_TEST:-0}" == "1" ]]; then exit 0; fi

if [[ $NO_REFRESH -eq 1 ]]; then
  log "skip refresh requested (--no-refresh / OC_SKIP_REFRESH)"
else
  log "running initial refresh (first run discovers free models)..."
  bash "$SCRIPT_DIR/refresh.sh" || warn "refresh failed - run it manually later"
fi

log "bootstrap complete"
exit 0
