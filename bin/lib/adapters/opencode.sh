# opencode.sh - adapter for the opencode CLI.
#
# Identity: ~/.local/share/opencode/auth.json (api-key entries, e.g. opencode
#   account, openrouter).
# Models:   `opencode models --verbose` - shared parser with kilo, in
#   buckets.sh (models_from_verbose), which owns the discovery machinery.
#   Opencode also hosts its own zen models (providerID=opencode) — these form
#   a separate bucket since they need no credential (like kilo:anon).
# Invoke:   opencode run -m model prompt; contained with --dir when a workdir
#   is given (FA_WORKDIR).

OPENCODE_AUTH="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"

FA_opencode_BINARY="opencode"
FA_opencode_METERED=0
FA_opencode_VERIFIED_VERSION="1.17.20"
FA_opencode_VERSION_BIN="opencode"

opencode_identify() { # -> identity rows (see buckets.sh for the schema)
  command -v opencode >/dev/null 2>&1 || return 0
  # Always emit an identity for opencode's own zen models — they need no
  # credential and are available even without an auth file (like kilo:anon).
  # Ident "zen" distinguishes this from credential-backed opencode buckets.
  printf 'opencode\x1fopencode\x1fopencode\x1fzen\x1fopencode:anonymous\x1f{}\n'
  if [[ -f "$OPENCODE_AUTH" ]]; then
    local provider key
    while IFS=$'\x1f' read -r provider key; do
      [[ -z "$provider" ]] && continue
      printf 'opencode\x1f%s\x1f%s\x1f%s\x1fopencode:auth.json\x1f{}\n' \
        "$provider" "$provider" "$(fp "$key")"
    done < <(jq -r 'to_entries[] | [.key, (.value.key // .value.apiKey // .value.access // "")] | join("\u001f")' "$OPENCODE_AUTH" 2>/dev/null)
  fi
}

opencode_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v opencode >/dev/null 2>&1 || return 0
  models_from_verbose opencode | sed 's/^/opencode\t/'
}

opencode_caps() { printf 'code,reasoning,shell,git,file'; }

opencode_install() { # -> 0 if install was run (or already installed)
  command -v opencode >/dev/null 2>&1 && return 1  # already installed
  if [[ "${FA_AUTO_INSTALL:-0}" == "1" ]] || prompt_yn "opencode not installed. Install now?"; then
    if command -v npm >/dev/null 2>&1; then
      npm install -g opencode-ai
    elif command -v brew >/dev/null 2>&1; then
      brew install opencode-ai
    else
      say "Install opencode manually: https://opencode.ai"
      return 1
    fi
  fi
}

opencode_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local model="$1" prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(timeout "$t" opencode run --dir "$FA_WORKDIR" -m "$model" "$prompt" \
      </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" opencode run -m "$model" "$prompt" </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}