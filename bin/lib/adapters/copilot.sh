# copilot.sh - adapter for the GitHub Copilot CLI.
#
# METERED: its free tier is a depleting monthly allowance, not an unlimited pool,
# so it is off unless FA_ALLOW_METERED=1 and always tried last. GitHub reports
# overage_permitted:false - it stops rather than bills.
# Auto-routed: copilot exposes no model list (a vendor "Auto" selector), so it is
# one bucket with a single pseudo-model. It is a wallet, and the scheduler
# addresses wallets, not models.
# Identity: GitHub login via `gh api /copilot_internal/user`; credits recorded.

FA_copilot_BINARY="copilot"
FA_copilot_METERED=1
FA_copilot_VERIFIED_VERSION="1.0.83"
FA_copilot_VERSION_BIN="copilot"

copilot_identify() {
  command -v copilot >/dev/null 2>&1 || return 0
  local ident="anon" extra='{"metered":true}'
  if command -v gh >/dev/null 2>&1; then
    local info
    info="$(gh api /copilot_internal/user 2>/dev/null || true)"
    if [[ -n "$info" ]]; then
      ident="$(fp "$(printf '%s' "$info" | jq -r '.login // ""')")"
      extra="$(printf '%s' "$info" | jq -c '{metered:true,
        plan: .access_type_sku,
        renews: .quota_reset_date,
        overage_permitted: (.quota_snapshots.chat.overage_permitted // false),
        credits_remaining: (.quota_snapshots.chat.remaining // null),
        credits_entitlement: (.quota_snapshots.chat.entitlement // null)}' 2>/dev/null \
        || echo '{"metered":true}')"
    fi
  fi
  printf 'copilot\x1fcopilot\x1fcopilot\x1f%s\x1f%s\x1f%s\n' \
    "$ident" "copilot:github" "$extra"
}

copilot_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v copilot >/dev/null 2>&1 || return 0
  # Auto-routed: no model list, no published context. Unknown is kept.
  printf 'copilot\tcopilot\tauto\tauto\ttrue\t0\t0\t\n'
}

copilot_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  # --allow-all is required for unattended use; --add-dir is what contains it.
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(timeout "$t" copilot -p "$prompt" --allow-all --add-dir "$FA_WORKDIR" \
      </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" copilot -p "$prompt" --allow-all </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}