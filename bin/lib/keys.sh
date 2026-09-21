# keys.sh - optional, non-interactive credential setup for a fresh machine.
# Sourced by setup.sh only; not a standalone entry point (uses `say`,
# `prompt_yn` and `$HERE` from there).
#
# Two tiers, because the seven agents are not symmetric:
#
#   Tier A - opencode, kilo, pi: a raw API key dropped into a JSON/JSONC file
#     is all they need. Fully scriptable from one `keys.env`.
#   Tier B - copilot, cursor, agy, hermes: real OAuth/account login. Nothing
#     here can safely automate CONSENTING to that on your behalf - login is a
#     trust boundary, not a convenience. This only detects who is not logged
#     in yet, offers each agent's own login step one at a time, and reports
#     what is still outstanding either way.

# One env var per Tier-A credential slot: VARNAME:agent:provider. Deliberately
# a flat list, not a generic N-provider mechanism - three known agents, three
# known lines; a fourth would be a fourth line, not a reason to abstract this.
FA_TIERA_KEYS=(
  "OPENCODE_OPENROUTER_KEY:opencode:openrouter"
  "KILO_OPENROUTER_KEY:kilo:openrouter"
  "PI_OPENROUTER_KEY:pi:openrouter"
)

FA_TIERB_AGENTS=(copilot cursor agy hermes)

_keys_env_file() { printf '%s/keys.env' "$HERE"; }

# Pull VARNAME=value out of keys.env without sourcing it - sourcing an
# arbitrary file as shell would execute anything a user (or a copy-pasted
# example) put in there. grep + strip quotes only.
_keys_env_value() { # $1=varname $2=file -> value, or empty
  local v
  v="$(grep -oP "(?<=^${1}=).*" "$2" 2>/dev/null | head -1)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

provision_keys() {
  local file; file="$(_keys_env_file)"
  [[ -f "$file" ]] || return 0
  chmod 600 "$file" 2>/dev/null || true

  local entry varname agent provider val fn
  declare -A seen_from=()
  local -a dup_warnings=()
  local any=0
  for entry in "${FA_TIERA_KEYS[@]}"; do
    IFS=':' read -r varname agent provider <<<"$entry"
    val="$(_keys_env_value "$varname" "$file")"
    [[ -z "$val" ]] && continue
    any=1
    # Same key reused across two lines collapses to one wallet - defeats the
    # whole point of a second credential. Compare raw values in memory only;
    # never print one, in a warning or anywhere else.
    if [[ -n "${seen_from[$val]:-}" ]]; then
      dup_warnings+=("$varname is the same key as ${seen_from[$val]} - same key = same wallet, not an extra lane")
    else
      seen_from[$val]="$varname"
    fi
    fn="${agent}_provision_key"
    if ! declare -F "$fn" >/dev/null 2>&1; then
      say "$agent: no provisioning support for this adapter (unexpected) - skipped $varname"
      continue
    fi
    if "$fn" "$provider" "$val"; then
      say "$agent: provisioned a $provider key from keys.env"
    else
      say "$agent: keys.env had $varname but provisioning it failed (see above)"
    fi
  done

  local w
  for w in "${dup_warnings[@]}"; do
    say "warning: $w"
  done
  [[ "$any" == "0" ]] && say "keys.env present but every line is blank - nothing to provision"
  return 0
}

guided_logins() {
  local agent still_out=()
  for agent in "${FA_TIERB_AGENTS[@]}"; do
    adapter_installed "$agent" || continue
    if adapter_logged_in "$agent"; then
      say "$agent: already logged in"
      continue
    fi
    say "$agent: not logged in - $(adapter_login_hint "$agent")"
    if prompt_yn "  attempt that now?"; then
      case "$agent" in
        copilot) gh auth login || true ;;
        cursor)  cursor-agent login || true ;;
        agy)     agy login || true ;;
        hermes)  hermes login || true ;;
      esac
      if adapter_logged_in "$agent"; then
        say "$agent: now logged in"
      else
        say "$agent: still not logged in"
      fi
    fi
    adapter_logged_in "$agent" || still_out+=("$agent")
  done

  if [[ "${#still_out[@]}" -gt 0 ]]; then
    say "accounts not yet logged in (${#still_out[@]}):"
    for agent in "${still_out[@]}"; do
      say "  $agent - $(adapter_login_hint "$agent")"
    done
    say "re-run '.free-agents/setup.sh' or 'fa bootstrap' after logging in to pick them up."
  fi
  return 0
}