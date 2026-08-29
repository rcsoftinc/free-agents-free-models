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

  # MODEL-SCOPE FIRST. These messages arrive carrying an HTTP status that belongs
  # to a different category - "HTTP 401: Model x-preview-f-free is not supported"
  # is a statement about one MODEL, not about the credential. Matching 401 first
  # would cool the entire wallet for 24h because one model is unsupported, which
  # is the single most expensive misclassification available here.
  if printf '%s' "$t" | grep -qE 'is not supported|not supported|unknown model|no such model|does not exist|model .* not found|invalid model'; then
    echo dead; return
  fi

  # Account-wide free-tier exhaustion. This is a WALLET fault and must trip the
  # breaker: every other model on the same account will fail identically, so
  # walking them one at a time is pure waste. Note these messages say neither
  # "429" nor "insufficient balance".
  if printf '%s' "$t" | grep -qE 'free usage exceeded|usage exceeded|subscribe to|upgrade to continue|free tier.*exceeded|daily limit reached'; then
    echo no_credits; return
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

  # A gateway failing upstream is usually transient and says nothing about the
  # model's health - parking it for 72h like a genuinely dead model throws away a
  # working endpoint over a blip. Short cooldown instead.
  if printf '%s' "$t" | grep -qE 'upstream request failed|provider returned error|upstream error|bad gateway|service unavailable|50[234]'; then
    echo provider_error; return
  fi

  if printf '%s' "$t" | grep -qE 'not found|404'; then
    echo dead; return
  fi
  # 124 = timeout(1) killed it, 143 = SIGTERM. A hang is the model's fault.
  if [[ "$rc" == "124" || "$rc" == "143" ]]; then echo timeout; return; fi
  [[ "$rc" == "0" ]] && { echo ok; return; }
  echo dead
}

# Providers often state their own retry window ("retrying in 3h 53m",
# "try again in 45 seconds"). An advertised window beats any guess we could make:
# retrying earlier just burns an attempt, and later wastes the lane.
retry_after_secs() { # $1=output -> seconds, or empty
  local t h m sec
  t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  h="$(printf '%s' "$t" | grep -oE '(retry|retrying|try again)[^0-9]{0,12}([0-9]+) ?h' | grep -oE '[0-9]+' | head -1)"
  m="$(printf '%s' "$t" | grep -oE '([0-9]+) ?m(in|inutes?)?\b' | grep -oE '[0-9]+' | head -1)"
  sec="$(printf '%s' "$t" | grep -oE 'retry-after[^0-9]{0,4}([0-9]+)' | grep -oE '[0-9]+' | head -1)"
  if [[ -n "$h" || -n "$m" ]]; then
    printf '%s' "$(( ${h:-0} * 3600 + ${m:-0} * 60 ))"
  elif [[ -n "$sec" ]]; then
    printf '%s' "$sec"
  fi
}

# Is this state the WALLET's fault? Only these may trip the bucket breaker.
is_bucket_fault() {
  case "$1" in rate_limited|no_credits|auth_error) return 0 ;; *) return 1 ;; esac
}

# Cooldown seconds per state, ESCALATING with consecutive failures.
#
# A first failure is treated as possibly transient, however severe it looks. This
# matters: a single 401 blip was observed benching a healthy 21-model wallet for
# 24h, and the wallet answered fine seconds later. A genuinely bad key or an empty
# balance re-fails immediately and escalates to the long window on its own, so
# nothing is lost by starting short - while a blip costs minutes instead of a day.
#
# Escalation: attempt 1 -> base, 2 -> base x4, 3+ -> the long window, capped.
cooldown_for() { # $1=state $2=consecutive_failures(optional, default 1) -> seconds
  local state="$1" n="${2:-1}" base cap
  case "$state" in
    rate_limited)     base="${COOLDOWN_RATE_LIMITED:-900}";   cap="${CAP_RATE_LIMITED:-3600}" ;;   # 15m -> 1h
    no_credits)       base="${COOLDOWN_NO_CREDITS:-1800}";    cap="${CAP_NO_CREDITS:-86400}" ;;    # 30m -> 24h
    auth_error)       base="${COOLDOWN_AUTH_ERROR:-900}";     cap="${CAP_AUTH_ERROR:-86400}" ;;    # 15m -> 24h
    timeout)          base="${COOLDOWN_TIMEOUT:-600}";        cap="${CAP_TIMEOUT:-3600}" ;;
    provider_error)   base="${COOLDOWN_PROVIDER_ERROR:-600}"; cap="${CAP_PROVIDER_ERROR:-3600}" ;;
    dead)             base="${COOLDOWN_DEAD:-3600}";          cap="${CAP_DEAD:-259200}" ;;         # 1h -> 72h
    context_overflow) echo 0; return ;;
    *)                echo 0; return ;;
  esac
  [[ "$n" -lt 1 ]] && n=1
  local secs="$base" i
  for ((i=1; i<n && i<4; i++)); do secs=$((secs * 4)); done
  [[ "$secs" -gt "$cap" ]] && secs="$cap"
  echo "$secs"
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

  echo "real messages observed in the wild"
  # A gateway blip, not a dead model - 72h would discard a working endpoint.
  _ct 1 "Error from provider (Console): Upstream request failed: [404] Provider returned error" \
                                                               provider_error   || fails=1
  # Account-wide free-tier exhaustion. Says neither "429" nor "insufficient
  # balance", yet every other model on the account will fail the same way.
  _ct 1 "Free usage exceeded, subscribe to Go [retrying in 3h 53m attempt #1]" \
                                                               no_credits       || fails=1
  _ct 1 "Unauthorized: Insufficient balance"                   no_credits       || fails=1
  # Carries a 401 but is a statement about ONE MODEL. Reading the status first
  # would cool the whole wallet for 24h because one model is unsupported.
  _ct 1 "HTTP 401: Model x-preview-f-free is not supported"    dead             || fails=1
  # ... while a real credential failure must still condemn the wallet.
  _ct 1 "HTTP 401 Unauthorized: invalid api key"               auth_error       || fails=1

  echo "advertised retry windows"
  [[ "$(retry_after_secs 'retrying in 3h 53m attempt #1')" == "13980" ]] \
    && echo "  ok   parsed 3h 53m as 13980s" || { echo "  FAIL 3h53m"; fails=1; }
  [[ "$(retry_after_secs 'please try again in 45 minutes')" == "2700" ]] \
    && echo "  ok   parsed 45 minutes"       || { echo "  FAIL 45m"; fails=1; }
  [[ -z "$(retry_after_secs 'no window mentioned here')" ]] \
    && echo "  ok   no window -> no hint"    || { echo "  FAIL spurious hint"; fails=1; }

  echo "cooldown escalation (a first failure must not bench a wallet for a day)"
  [[ "$(cooldown_for auth_error 1)" -le 1800 ]] \
    && echo "  ok   first auth_error <= 30min" || { echo "  FAIL first auth_error too long"; fails=1; }
  [[ "$(cooldown_for auth_error 4)" -ge 3600 ]] \
    && echo "  ok   repeated auth_error escalates" || { echo "  FAIL no escalation"; fails=1; }
  [[ "$(cooldown_for no_credits 1)" -lt "$(cooldown_for no_credits 3)" ]] \
    && echo "  ok   no_credits escalates with repeats" || { echo "  FAIL"; fails=1; }
  [[ "$(cooldown_for local_network 9)" == "0" ]] \
    && echo "  ok   local_network never cools, however many times" || { echo "  FAIL"; fails=1; }

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
