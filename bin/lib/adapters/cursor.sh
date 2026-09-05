# cursor.sh - adapter for Cursor's agent CLI.
#
# METERED: like copilot, a depleting monthly allowance - off unless
# FA_ALLOW_METERED=1 and always tried last.
# Auto-routed: no model list (a vendor "Auto" selector), so one pseudo-model.
# Identity: `cursor-agent status` reports the account email.
# Invoke:   cursor-agent -p prompt -f (trusts the dir) --output-format text.

FA_cursor_BINARY="cursor-agent,cursor"
FA_cursor_METERED=1
FA_cursor_VERIFIED_VERSION="2026.09.02"
FA_cursor_VERSION_BIN="cursor-agent"

cursor_identify() {
  command -v cursor-agent >/dev/null 2>&1 || return 0
  local ident="anon" who
  who="$(timeout 20 cursor-agent status 2>/dev/null \
    | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | head -1 || true)"
  [[ -n "$who" ]] && ident="$(fp "$who")"
  printf 'cursor\x1fcursor\x1fcursor\x1f%s\x1f%s\x1f{"metered":true}\n' \
    "$ident" "cursor:status"
}

cursor_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v cursor-agent >/dev/null 2>&1 || return 0
  printf 'cursor\tcursor\tauto\tauto\ttrue\t0\t0\t\n'
}

cursor_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  # -f trusts the directory (it refuses to run headless otherwise).
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(cd "$FA_WORKDIR" && timeout "$t" cursor-agent -p "$prompt" \
      --output-format text -f </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" cursor-agent -p "$prompt" --output-format text -f \
      </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}