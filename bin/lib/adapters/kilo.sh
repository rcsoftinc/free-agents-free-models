# kilo.sh - adapter for the kilo CLI.
#
# Identity: two separate things. The native kilo gateway needs no credential
#   (empty kilo.db account table is still a real, free wallet) and is emitted as
#   "kilo:unauthenticated"; extra OpenAI-compatible providers configured in
#   kilo.jsonc (e.g. OpenRouter via kilo-add-openrouter.sh) are emitted per key.
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