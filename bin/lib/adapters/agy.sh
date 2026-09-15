# agy.sh - adapter for the Antigravity (Google) CLI.
#
# Identity: Antigravity uses Google OAuth. The token lives at
#   ~/.gemini/antigravity-cli/antigravity-oauth-token
# and rotates, so we fingerprint the refresh token (stable) or fall back to
# the JWT subject claim from the id_token.
# Models:   `agy models` - tab-separated id\tname, all free tier.
# Invoke:   agy --print, contained with --add-dir when a workdir is given.

FA_agy_BINARY="agy"
FA_agy_METERED=0
FA_agy_VERIFIED_VERSION="1.2.0"
FA_agy_VERSION_BIN="agy"

AGY_TOKEN_FILE="${AGY_TOKEN_FILE:-$HOME/.gemini/antigravity-cli/antigravity-oauth-token}"

agy_identify() {
  command -v agy >/dev/null 2>&1 || return 0
  local token_file="$AGY_TOKEN_FILE" fp_val="anon"
  if [[ -f "$token_file" ]]; then
    # Prefer the JWT subject from id_token; fall back to refresh token fingerprint
    local idt
    idt="$(jq -r '.token.id_token // empty' "$token_file" 2>/dev/null || true)"
    if [[ -n "$idt" ]]; then
      local sub
      sub="$(printf '%s' "$idt" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.sub // .email // empty' 2>/dev/null || true)"
      [[ -n "$sub" ]] && fp_val="$(fp "$sub")"
    fi
    if [[ "$fp_val" == "anon" ]]; then
      local rt
      rt="$(jq -r '.token.refresh_token // empty' "$token_file" 2>/dev/null || true)"
      [[ -n "$rt" ]] && fp_val="$(fp "$rt")"
    fi
  fi
  printf 'agy\x1fantigravity\x1fantigravity\x1f%s\x1f%s\x1f{}\n' \
    "$fp_val" "agy:antigravity-cli"
}

agy_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v agy >/dev/null 2>&1 || return 0
  local line id name
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" || "$id" == "id" ]] && continue
    # All agy models are free tier; format must match the 7-field TSV
    # parser in buckets.sh: agent<TAB>provider<TAB>model_arg<TAB>upstream<TAB>free<TAB>context<TAB>max_output
    printf 'agy\tantigravity\t%s\t%s\ttrue\t0\t0\n' "$id" "$name"
  done < <(agy models 2>/dev/null | tail -n +1)
}

agy_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local model="$1" prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(timeout "$t" agy --add-dir "$FA_WORKDIR" --model "$model" --print "$prompt" </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" agy --model "$model" --print "$prompt" </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}