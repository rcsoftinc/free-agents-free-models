# classify.sh - the single error taxonomy. Source, do not execute.
#
# Exit codes from these CLIs are not trustworthy: hermes returns 0 on HTTP 404
# and on a billing refusal, and opencode has been observed exiting 0 on credit
# errors. Classification is therefore CONTENT-first, with rc used only to catch
# a kill.
#
# Attribution is the point of this file. Each state says WHO is at fault, which
# decides what may be written to the learning store:
#
#   state             attributable to   effect
#   ----------------------------------------------------------------------
#   ok                model+bucket      success stats, bucket healthy
#   rate_limited      BUCKET            bucket cooldown (breaker)
#   no_credits        BUCKET            bucket cooldown, long
#   auth_error        BUCKET            bucket cooldown, long
#   context_overflow  neither           caller's prompt is too big; retry smaller
#   timeout           MODEL             model cooldown only
#   dead              MODEL             model cooldown, long
#   local_network     NOBODY            record NOTHING, retry after connectivity
#
# local_network is the one that protects the learning store: a failure we caused
# is not evidence about anyone's model, and a minute of bad wifi must not bench
# good models for three days.

classify() { # $1=rc $2=output -> state
  local rc="${1:-0}" t
  t="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$t" | grep -qE 'could not resolve host|name or service not known|network is unreachable|no route to host|connection refused|temporary failure in name resolution|ssl connect error|tls handshake|connection reset by peer'; then
    echo local_network; return
  fi
  if printf '%s' "$t" | grep -qE '429|rate.?limit|too many requests|temporarily rate-limited|try again later|in-flight requests|overloaded'; then
    echo rate_limited; return
  fi
  if printf '%s' "$t" | grep -qE 'insufficient balance|model access is unavailable|subscribe or add credits|exceed your available credits|quota|billing|payment required|402'; then
    echo no_credits; return
  fi
  if printf '%s' "$t" | grep -qE 'unauthorized|forbidden|invalid api key|authentication|401|403'; then
    echo auth_error; return
  fi
  if printf '%s' "$t" | grep -qE 'context length|too large|maximum context|token limit exceeded'; then
    echo context_overflow; return
  fi
  if printf '%s' "$t" | grep -qE 'not found|does not exist|unknown model|unrecognized arguments|404'; then
    echo dead; return
  fi
  # 124 = timeout(1) killed it, 143 = SIGTERM. A hang is the model's fault.
  if [[ "$rc" == "124" || "$rc" == "143" ]]; then echo timeout; return; fi
  [[ "$rc" == "0" ]] && { echo ok; return; }
  echo dead
}

# Is this state the WALLET's fault? Only these may trip the bucket breaker.
is_bucket_fault() {
  case "$1" in rate_limited|no_credits|auth_error) return 0 ;; *) return 1 ;; esac
}

# Cooldown seconds per state. Rate limits recover in minutes; a drained balance
# or a bad key does not, so retrying it costs an attempt slot for nothing.
cooldown_for() { # $1=state -> seconds
  case "$1" in
    rate_limited)     echo "${COOLDOWN_RATE_LIMITED:-1800}" ;;   # 30 min
    no_credits)       echo "${COOLDOWN_NO_CREDITS:-86400}" ;;    # 24 h
    auth_error)       echo "${COOLDOWN_AUTH_ERROR:-86400}" ;;    # 24 h
    timeout)          echo "${COOLDOWN_TIMEOUT:-600}" ;;         # 10 min
    dead)             echo "${COOLDOWN_DEAD:-259200}" ;;         # 72 h
    context_overflow) echo 0 ;;
    *)                echo 0 ;;
  esac
}

# Cheap connectivity check, used to tell "our network died" from "their API died"
# before anything is written to the learning store.
network_up() {
  curl -sS --max-time 8 -o /dev/null "${NETCHECK_URL:-https://cloudflare.com/cdn-cgi/trace}" 2>/dev/null
}

# --- self-test -----------------------------------------------------------
# Run: bash bin/lib/classify.sh --self-test
# Cases marked (D3) are real outputs observed from these CLIs, where the exit
# code said success and only the text revealed the failure.
_ct() { # rc, text, expected
  local got; got="$(classify "$1" "$2")"
  if [[ "$got" == "$3" ]]; then printf '  ok   %-16s %s\n' "$3" "${2:0:46}"
  else printf '  FAIL %-16s got=%-16s %s\n' "$3" "$got" "${2:0:46}"; return 1; fi
}

classify_self_test() {
  local fails=0
  echo "classify() self-test"
  _ct 0 "OK"                                                   ok               || fails=1
  _ct 1 "HTTP 429 Too Many Requests"                           rate_limited     || fails=1
  _ct 0 "provider is temporarily rate-limited upstream"        rate_limited     || fails=1
  # (D3) hermes exits 0 while refusing on billing
  _ct 0 "model access is unavailable. Subscribe or add credits" no_credits      || fails=1
  _ct 0 "Unauthorized: Insufficient balance"                   no_credits       || fails=1
  _ct 1 "401 Unauthorized"                                     auth_error       || fails=1
  _ct 1 "context length exceeded"                              context_overflow || fails=1
  # (D3) hermes exits 0 on an unknown model; (D6) a missing --provider looks identical
  _ct 0 "HTTP 404: Model 'x' not found."                       dead             || fails=1
  # (D2) a malformed invocation must not be mistaken for a dead model's fault
  _ct 2 "hermes: error: unrecognized arguments: list"          dead             || fails=1
  _ct 124 ""                                                   timeout          || fails=1
  _ct 143 ""                                                   timeout          || fails=1
  # the store-protecting cases: ours, not theirs
  _ct 1 "curl: (6) Could not resolve host: openrouter.ai"      local_network    || fails=1
  _ct 1 "Connection refused"                                   local_network    || fails=1
  _ct 1 "Temporary failure in name resolution"                 local_network    || fails=1
  # precedence: a rate-limit mentioning a model must not read as 'dead'
  _ct 1 "429 rate limit on model not found in pool"            rate_limited     || fails=1

  echo "attribution"
  is_bucket_fault rate_limited && echo "  ok   rate_limited blames the wallet"   || { echo "  FAIL"; fails=1; }
  is_bucket_fault timeout      && { echo "  FAIL timeout must not blame the wallet"; fails=1; } \
                               || echo "  ok   timeout blames the model only"
  is_bucket_fault local_network && { echo "  FAIL network must blame nobody"; fails=1; } \
                                || echo "  ok   local_network blames nobody"
  [[ "$(cooldown_for local_network)" == "0" ]] && echo "  ok   local_network has no cooldown" \
                                               || { echo "  FAIL"; fails=1; }
  [[ $fails -eq 0 ]] && echo "PASS" || { echo "FAIL"; return 1; }
}

# Guarded as an `if`, not `[[ ]] && cmd`: when this file is SOURCED under
# `set -e`, a trailing && whose test is false returns 1 and aborts the caller.
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  classify_self_test
fi
