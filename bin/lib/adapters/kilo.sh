# kilo.sh - adapter for the kilo CLI.
#
# Identity: two separate things. The native kilo gateway needs no credential
#   (empty kilo.db account table is still a real, free wallet) and is emitted as
#   "kilo:unauthenticated"; extra OpenAI-compatible providers configured in
#   kilo.jsonc are emitted per key.
# Models:   `kilo models --verbose` - shared parser with opencode, in buckets.sh.
# Invoke:   kilo run --auto; contained with --dir when a workdir is given.

KILO_DB="${KILO_DB:-$HOME/.local/share/kilo/kilo.db}"
KILO_CONFIG="${KILO_CONFIG:-$HOME/.config/kilo/kilo.jsonc}"

FA_kilo_BINARY="kilo"
FA_kilo_METERED=0
FA_kilo_VERIFIED_VERSION="7.5.5"
FA_kilo_VERSION_BIN="kilo"

kilo_identify() {
  command -v kilo >/dev/null 2>&1 || return 0
  local key=""
  # kilo keeps its own gateway credential in sqlite; an empty store means the
  # gateway is serving this machine unauthenticated, which is still a distinct
  # wallet from any account-backed one.
  if [[ -f "$KILO_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    key="$(sqlite3 "$KILO_DB" \
      "SELECT COALESCE(access_token,'') FROM account LIMIT 1;" 2>/dev/null || true)"
  fi
  printf 'kilo\x1fkilo\x1fkilo\x1f%s\x1f%s\x1f{}\n' "$(fp "$key")" \
    "$([[ -n "$key" ]] && echo 'kilo:kilo.db' || echo 'kilo:unauthenticated')"

  # Extra OpenAI-compatible providers configured in kilo.jsonc (e.g. OpenRouter).
  # The provider NAME is local config ("openai"); the wallet is the base URL's
  # host plus the key, so the same key in another agent still collapses to one
  # bucket regardless of what each agent calls the provider.
  [[ -f "$KILO_CONFIG" ]] || return 0
  jq -e . "$KILO_CONFIG" >/dev/null 2>&1 || {
    log "warning: $KILO_CONFIG is not plain JSON (comments?) - skipping its providers"
    return 0
  }
  local name pkey base
  while IFS=$'\x1f' read -r name pkey base; do
    [[ -z "$name" || -z "$pkey" ]] && continue
    printf 'kilo\x1f%s\x1f%s\x1f%s\x1f%s\x1f{}\n' \
      "$name" "$(host_of "$base" "$name")" "$(fp "$pkey")" "kilo:kilo.jsonc[$name]"
  done < <(jq -r '.provider // {} | to_entries[]
                  | [.key, (.value.options.apiKey // ""), (.value.options.baseURL // "")]
                  | join("\u001f")' "$KILO_CONFIG" 2>/dev/null)
}

kilo_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v kilo >/dev/null 2>&1 || return 0
  models_from_verbose kilo | sed 's/^/kilo\t/'
}

kilo_caps() { printf 'code,reasoning,shell,git,file'; }

kilo_install() { # -> 0 if install was run (or already installed)
  command -v kilo >/dev/null 2>&1 && return 1  # already installed
  if [[ "${FA_AUTO_INSTALL:-0}" == "1" ]] || prompt_yn "kilo not installed. Install now?"; then
    if command -v npm >/dev/null 2>&1; then
      npm install -g @kilocode/kilo
    elif command -v brew >/dev/null 2>&1; then
      brew install kilocode/tap/kilo
    else
      say "Install kilo manually: https://github.com/glenng/kilo"
      return 1
    fi
  fi
}

kilo_provision_key() { # $1=provider (default openrouter) $2=key -> 0 on success
  # Signature matches opencode/pi's *_provision_key (provider, key) so the
  # generic dispatcher in keys.sh can call all three identically - only the
  # base URL is agent-specific, and it's looked up here, not passed in.
  local provider="${1:-openrouter}" key="${2:-}" base
  [[ -z "$key" ]] && return 1
  case "$provider" in
    openrouter) base="https://openrouter.ai/api/v1" ;;
    *) log "kilo_provision_key: no known base URL for provider '$provider'"; return 1 ;;
  esac
  # Refuses cleanly (via json_merge_file) rather than corrupting kilo.jsonc if
  # it already carries comments - see kilo_identify's own note on this file.
  # The provider NAME here is just a local label (wallet identity comes from
  # host_of(baseURL), not this string) - "openrouter" is clearer than the
  # generic "openai" label seen on some real configs, and works the same.
  json_merge_file "$KILO_CONFIG" \
    '.provider.openrouter = {"options": {"apiKey": $k, "baseURL": $b}}' \
    --arg k "$key" --arg b "$base"
}

kilo_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local model="$1" prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(timeout "$t" kilo run --dir "$FA_WORKDIR" -m "$model" --auto "$prompt" \
      </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" kilo run -m "$model" --auto "$prompt" </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}