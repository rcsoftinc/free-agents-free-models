#!/usr/bin/env bash
# ============================================================================
# get-balance.sh (Linux/Bash port of get-balance.ps1)
#
# Checks provider token/credit status from opencode's auth.json (keys are
# NEVER printed). Cached to data/balance-cache.json for balanceCacheMinutes.
#
# Verified semantics: OpenRouter exposes a GLOBAL per-key limit/usage; ':free'
# models additionally carry per-model DAILY request caps (~50/day free tier)
# which are NOT exposed by any API - they appear as runtime rate-limit errors.
# freemodel has no public endpoint -> "probe-only".
#
# Usage: get-balance.sh [--force] [--json]
# Exit : 0 ok | 1 no credentials found
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PKG_ROOT/data"
CONFIG="$SCRIPT_DIR/config.json"
CACHE="$DATA_DIR/balance-cache.json"
AUTH_FILE="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"
API_URL="$(jq -r '.openrouterKeyApiUrl' "$CONFIG")"

FORCE=0; ASJSON=0
[[ "${1:-}" == "--force" ]] && FORCE=1
[[ "${2:-}" == "--json" || "${1:-}" == "--json" ]] && ASJSON=1

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 3; }
[[ -f "$AUTH_FILE" ]] || { echo "[balance] auth.json not found at $AUTH_FILE (run bootstrap.sh first)" >&2; exit 1; }

mkdir -p "$DATA_DIR"

if [[ $FORCE -eq 0 && -f "$CACHE" ]]; then
  cache_age_s="$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)"
  age_min=$(( ($(date +%s) - cache_age_s) / 60 ))
  limit_min="$(jq -r '.balanceCacheMinutes' "$CONFIG")"
  if (( age_min < limit_min )); then
    if [[ $ASJSON -eq 1 ]]; then cat "$CACHE"; else
      jq -r '.providers[] | render' --arg x x 2>/dev/null || \
      jq -r '.providers[] | ("[" + .provider + "] " +
        (if .usageUsd then "used=$\(.usageUsd) " else "" end) +
        (if .remainingUsd then "remaining=$\(.remainingUsd) " else "" end) +
        (if .freeTier then "freeTier=\(.freeTier) " else "" end) + "- " + .note)' "$CACHE"
      echo "(cached ${age_min} min ago; use --force to recheck)"
    fi
    exit 0
  fi
fi

mask() { local k="$1"; if [[ ${#k} -le 10 ]]; then echo "***"; else echo "${k:0:4}...${k: -4}"; fi; }

PROVIDERS="[]"
for id in $(jq -r 'keys[] | select(. != "$schema")' "$AUTH_FILE"); do
  key="$(jq -r --arg id "$id" '.[$id].key // ""' "$AUTH_FILE")"
  ktype="$(jq -r --arg id "$id" '.[$id].type // "api"' "$AUTH_FILE")"
  entry=""
  case "$id" in
    openrouter)
      resp="$(curl -s --max-time 20 -H "Authorization: Bearer $key" "$API_URL" || echo "")"
      if [[ -n "$resp" ]] && jq -e '.data' <<<"$resp" >/dev/null 2>&1; then
        entry="$(jq -cn --arg p openrouter \
          --argjson usage "$(jq '.data.usage // null' <<<"$resp")" \
          --argjson rem   "$(jq '.data.limit_remaining // null' <<<"$resp")" \
          --argjson lim   "$(jq '.data.limit // null' <<<"$resp")" \
          --argjson free  "$(jq '.data.is_free_tier // null' <<<"$resp")" \
          '{provider:$p, kind:"api", usageUsd:$usage, remainingUsd:$rem, limitUsd:$lim, freeTier:$free,
            note:(if $rem then "global key limit not exhausted"
                  elif ($lim|not) then "no hard limit set (pay-as-you-go); :free models still have daily request caps"
                  else "limit reached" end)}')"
      else
        entry='{"provider":"openrouter","kind":"api","note":"key check failed (network or invalid key)"}'
      fi
      ;;
    freemodel)
      entry="{\"provider\":\"freemodel\",\"kind\":\"$ktype\",\"note\":\"no public balance endpoint; runtime errors report Insufficient balance when drained (probe-only)\"}"
      ;;
    opencode)
      entry="{\"provider\":\"opencode\",\"kind\":\"$ktype\",\"freeTier\":true,\"note\":\"zen models cost=0; probe-only\"}"
      ;;
    kilo)
      entry="{\"provider\":\"kilo\",\"kind\":\"$ktype\",\"note\":\"no public balance endpoint; probe-only\"}"
      ;;
    *)
      entry="$(jq -cn --arg p "$id" '{provider:$p, kind:"api", note:"unknown provider; probe-only"}')"
      ;;
  esac
  PROVIDERS="$(jq -c --argjson p "$entry" '. + [$p]' <<<"$PROVIDERS")"
done

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result="$(jq -cn --arg ts "$ts" --argjson providers "$PROVIDERS" '{checkedAt:$ts, providers:$providers}')"
printf '%s\n' "$result" > "$CACHE.tmp" 2>/dev/null && { mv "$CACHE.tmp" "$CACHE" || true; }

if [[ $ASJSON -eq 1 ]]; then printf '%s\n' "$result"; exit 0; fi
jq -r '.providers[] | ("[" + .provider + "] " +
  (if .usageUsd then "used=$\(.usageUsd) " else "" end) +
  (if .remainingUsd then "remaining=$\(.remainingUsd) " else "" end) +
  (if .freeTier then "freeTier=\(.freeTier) " else "" end) + "- " + (.note // ""))' <<<"$result"
exit 0
