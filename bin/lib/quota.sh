# quota.sh - OPTIONAL, opt-in LIVE quota check. Source, do not execute.
#
# Everything else in this tool that learns a bucket is out of quota does so
# REACTIVELY, by classifying a failed attempt after the fact (see
# classify.sh's no_credits/rate_limited states). This is the one exception:
# it asks a provider directly, ahead of time, how much of ITS OWN published
# budget is left - but only when explicitly asked to (`fa quota` / `bin/
# buckets.sh quota`), never from the hot dispatch path. run.sh's candidates()
# and cmd_lanes() both stay offline-only, exactly as before.
#
# One provider today: OpenRouter publishes a real, documented, keyed endpoint
# (GET /api/v1/auth/key) that answers with usage/limit for the exact key used
# to call it - no scraping, no guessing. A second provider with an equally
# real endpoint is the point at which this becomes a per-adapter contract
# function; until then a flat, explicit case is the honest size of the
# problem (same reasoning keys.sh gives for FA_TIERA_KEYS staying three
# hardcoded lines instead of a generic N-provider mechanism).
#
# HONESTY, NOT A GUESS PRESENTED AS FACT: OpenRouter's `limit`/`usage` fields
# are its DOLLAR-CREDIT ledger, not a free-tier token count. A free-tier-only
# key can show usage=0/limit=null forever while still being rate-limited -
# this tells you about billing headroom, not free-tier headroom. Surfaced as
# exactly that, never folded into scheduling.

# The only place a raw provider key is ever reconstituted from an agent's own
# config outside of identify()'s fingerprinting. Never logged, never written
# anywhere but into the one curl call below.
openrouter_key_from_kilo() { # -> raw key on stdout, or nothing / rc=1
  local cfg="${KILO_CONFIG:-$HOME/.config/kilo/kilo.jsonc}"
  [[ -f "$cfg" ]] || return 1
  jq -e . "$cfg" >/dev/null 2>&1 || return 1
  local key
  key="$(jq -r '.provider // {} | to_entries[]
                | select((.value.options.baseURL // "") | test("openrouter\\.ai"; "i"))
                | (.value.options.apiKey // empty)' "$cfg" 2>/dev/null | head -1)"
  [[ -n "$key" ]] || return 1
  printf '%s' "$key"
}

# $1=key -> tsv(usage, limit, limit_remaining, is_free_tier, rate_requests, rate_interval)
openrouter_quota_check() {
  local key="${1:-}"
  [[ -n "$key" ]] || return 1
  local resp
  resp="$(curl -sS --max-time 15 -H "Authorization: Bearer ${key}" \
          "https://openrouter.ai/api/v1/auth/key" 2>/dev/null)" || return 1
  printf '%s' "$resp" | jq -e '.data' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -r '
    .data
    | [ (.usage // 0), (.limit // "null"), (.limit_remaining // "null"),
        (.is_free_tier // false), (.rate_limit.requests // "null"),
        (.rate_limit.interval // "null") ]
    | @tsv'
}
