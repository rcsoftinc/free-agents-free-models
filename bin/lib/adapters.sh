# adapters.sh - the SINGLE canonical list of agent CLIs (harnesses) this tool
# can drive, and the shared plumbing every one of them uses.
#
# Everything that ever asks "which agents are here?" comes through this file:
#   - discovery identity and model enumeration       (bin/buckets.sh)
#   - the examined_agents staleness bookkeeping       (bin/buckets.sh)
#   - the registry staleness check                    (bin/lib/common.sh)
#   - doctor's version + presence reporting           (bin/fa)
#   - the run dispatcher                              (bin/run.sh)
#
# A new harness is exactly two things: an entry in FA_AGENTS and one file in
# adapters/. Nothing else needs to change - and a copy of the agent list in any
# other file is a regression. This is the "one writer, no drift" rule applied to
# the harness roster.
#
# Adapter contract - each adapters/<name>.sh sets:
#   FA_<NAME>_BINARY="bin1,bin2"
#       every executable whose presence means "this harness is installed".
#       (cursor advertises both cursor-agent and cursor.)
#   FA_<NAME>_METERED=0|1
#       a metered lane spends a depleting MONTHLY ALLOWANCE rather than an
#       unlimited free pool; it is off unless FA_ALLOW_METERED=1 and tried last.
#   FA_<NAME>_VERIFIED_VERSION="x.y.z"
#       the invocation-shape pin that fa doctor asserts (these CLIs have already
#       changed call shape once; a wrong shape is indistinguishable from a dead
#       model, so the version is checked, not assumed).
#   FA_<NAME>_VERSION_BIN="bin"      the binary asked for its --version
# and defines three functions:
#   <name>_identify                   identity rows  -> stdout (see buckets.sh)
#   <name>_models                     model rows     -> stdout (see buckets.sh)
#   <name>_invoke model provider prompt   run one model through this harness;
#                                         echoes output, returns rc

FA_AGENTS=(opencode kilo hermes copilot cursor)

# Harnesses the tool does NOT ship an adapter for. The presence broom surfaces
# them in `fa doctor` so an installed agent is never silently invisible - but a
# lane is only possible once an adapter exists.
FA_KNOWN_UNSUPPORTED=(claude codex aider gemini cody amp continue goose)

_ADAPTERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/adapters" && pwd)"
for _adapter in "${FA_AGENTS[@]}"; do
  # shellcheck source=adapters/opencode.sh
  . "${_ADAPTERS_DIR}/${_adapter}.sh"
done
unset _ADAPTERS_DIR _adapter

# ----------------------------------------------------- credential helpers ----
# Shared by several adapters for identity fingerprinting. Identity is STABLE,
# never the raw secret:
#   api key   -> sha256(key)[:12]
#   oauth     -> sha256(subject-claim)[:12]   (tokens rotate hourly; subjects do not)
#   none      -> "anon"

fp() { # stable 12-char fingerprint; never prints the input
  local v="${1:-}"
  [[ -z "$v" ]] && { printf 'anon'; return; }
  printf '%s' "$v" | sha256sum | cut -c1-12
}

# Subject claim out of a JWT payload, without verifying it (identity only).
jwt_subject() {
  local tok="${1:-}" payload
  [[ -z "$tok" || "$tok" != *.*.* ]] && return 1
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload+='==' ;; 3) payload+='=' ;; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq -er '.sub // .email // empty' 2>/dev/null
}

# Free-tier providers often publish their own limits inside the token.
jwt_limits() {
  local tok="${1:-}" payload
  [[ -z "$tok" || "$tok" != *.*.* ]] && { printf '{}'; return; }
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload+='==' ;; 3) payload+='=' ;; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -c '
    { rpm: .rate_limit_rpm, tpm: .rate_limit_tpm,
      rph: .rate_limit_rph, tph: .rate_limit_tph,
      paid: .paid_access, source: .rate_limit_source }
    | with_entries(select(.value != null))' 2>/dev/null || printf '{}'
}

# Wallet namespace: the API host the credential actually talks to, so two agents
# naming the same vendor differently still land in one bucket.
host_of() { # $1=base_url $2=fallback
  local h; h="$(printf '%s' "${1:-}" | sed -E 's|^https?://||; s|/.*$||')"
  printf '%s' "${h:-$2}"
}

# ------------------------------------------------------------- accessors ----

adapter_field() { # $1=agent $2=FIELD -> value; "" when undefined
  local key="FA_${1}_${2}"
  printf '%s' "${!key:-}"
}

adapter_binaries() { # $1=agent -> space-separated binaries
  local v; v="$(adapter_field "$1" BINARY)"
  printf '%s' "$v" | tr ',' ' '
}

adapter_installed() { # $1=agent -> 0 if any declared binary is on PATH
  local b
  for b in $(adapter_binaries "$1"); do
    command -v "$b" >/dev/null 2>&1 && return 0
  done
  return 1
}

adapters_installed() { # -> names of installed adapters, one per line
  local a
  for a in "${FA_AGENTS[@]}"; do
    adapter_installed "$a" && printf '%s\n' "$a"
  done
}

adapter_metered() { # $1=agent -> "1" if a depleting monthly allowance
  printf '%s' "$(adapter_field "$1" METERED)"
}

# Metered-mode resolution shared by the lanes count, the run candidate chain and
# the `show` listing, so they can never disagree about who is schedulable.
#
#   FA_METERED   auto (default) | 0 | 1
#   FA_ALLOW_METERED 1|0        legacy alias, honoured when FA_METERED is unset.
#
# "auto" is the answer to "they're still free, but it's a depleting allowance":
# a metered wallet is a lane ONLY when it was actually DETECTED with a token
# (credential_fp != "anon" - i.e. someone is logged in) and, for one with a
# published credit budget (copilot), still has credits left. A metered wallet
# nobody is signed into, or one whose allowance is exhausted, is invisible - it
# would spend a depleting budget on a user who is not even there. The callers
# still sort metered lanes LAST and mark them as allowance; this only decides
# whether they appear at all.
metered_mode() { # -> auto|0|1 ; 0==off, 1==on, auto==detect-on-token
  if [[ -n "${FA_METERED:-}" ]]; then printf '%s' "$FA_METERED"
  elif [[ "${FA_ALLOW_METERED:-0}" == "1" ]]; then printf '1'
  else printf 'auto'; fi
}

# The jq predicate fragment the lanes count and candidate chain both need.
#   $metered   "0" | "1" | "auto"   (from metered_mode)
# A helper because the auto rule mixes several fields:
#   - metered wallet (flagged)  -> only with a detected token (credential_fp != "anon")
#   - a published credit budget that says 0 left  -> invisible (spent)
#   - no published credits (cursor, or copilot without gh) -> its "has a token"
#     check is the only signal we have, so a token means include.
# The fragment is written against the bucket as `.` (not `$b`), so it can be
# spliced directly into a jq program as `select( <fragment> )`.
metered_include_pred() { # -> jq boolean expr operating on the current bucket `.`
  case "$(metered_mode)" in
    1) printf 'true' ;;
    0) printf '((.metered // false) == false)' ;;
    *)
      # auto: a metered wallet is a lane only when a token was actually detected
      # (credential_fp != "anon") AND its recorded allowance is not spent.
      # credits_remaining == 0 (the bucket reports zero left) is exhausted and
      # drops off; null/absent (cursor, or copilot without gh) is "unknown" and
      # stays in as long as a token was seen - spending nothing is worse than
      # one extra lane.
      printf '(((.metered // false) == false) or
              (((.credential_fp // "") != "anon")
               and ((.meter.credits_remaining == 0) | not)))'
      ;;
  esac
}

# Presence broom: harnesses that are installed but have no adapter. Surfaced so
# nothing is silent; NOT a lane (that needs an adapter) and not staleness (a
# refresh cannot change what is unadaptable).
# `continue` is both a shell builtin and (now) a real agent CLI - `command -v`
# matches the builtin on every machine, so builtins are excluded explicitly
# rather than letting doctor report a phantom harness everywhere.
adapters_present_without_adapter() { # -> installed unsupported binaries
  local b
  for b in "${FA_KNOWN_UNSUPPORTED[@]}"; do
    [[ -n "$(type -t "$b" 2>/dev/null)" && "$(type -t "$b")" != "builtin" ]] \
      && command -v "$b" >/dev/null 2>&1 && printf '%s\n' "$b"
  done
}

# The dispatcher. One route is (agent, model, provider); the adapter owns the
# invocation shape, so run.sh and buckets.sh share a single implementation and a
# harness added after the fact needs no edit anywhere but its adapter.
adapter_invoke() { # $1=agent; then (model provider prompt)
  local agent="$1"; shift
  local fn="${agent}_invoke"
  declare -F "$fn" >/dev/null 2>&1 || {
    printf 'adapter_invoke: no such adapter: %s\n' "$agent" >&2
    return 3
  }
  "$fn" "$@"
}