#!/usr/bin/env bash
# ============================================================================
# find-free-providers.sh - discover NEW free-model providers worth signing up
#
# Queries the public models.dev catalog and ranks every provider by how many
# zero-cost models it offers (plus its largest free context window). Feed the
# winners' env var names into your .env, run bootstrap.sh, done.
#
# Usage: find-free-providers.sh [topN]     (default 15)
# Requires: curl + jq only.
# ============================================================================
set -euo pipefail

TOP="${1:-15}"
URL="https://models.dev/api.json"

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 3; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -s --max-time 30 "$URL" -o "$TMP"
[[ -s "$TMP" ]] || { echo "could not download catalog" >&2; exit 1; }

echo "Providers offering FREE models (cost input==0 && output==0), ranked:"
echo ""
jq -r '
  to_entries[]
  | .key as $pid
  | .value as $p
  | [$p.models // {} | to_entries[]
      | select((.value.cost.input // 1) == 0 and (.value.cost.output // 1) == 0)] as $free
  | select(($free | length) > 0)
  | {
      id: $pid,
      name: ($p.name // $pid),
      env: ($p.env // [] | join(",")),
      count: ($free | length),
      maxctx: ($free | map(.value.limit.context // 0) | max)
    }
  | "\(.count)\t\(.maxctx)\t\(.id)\t\(.name)\t\(.env)"
' "$TMP" | sort -t$'\t' -k1,1nr -k2,2nr | head -n "$TOP" | \
awk -F'\t' 'BEGIN{printf "%-5s %-10s %-22s %s\n","FREE","MAXCTX","PROVIDER_ID","NAME / ENV VAR"}
{printf "%-5s %-10s %-22s %s", $1,$2,$3,$4; if($5!="") printf "  [env: %s]", $5; print ""}'

echo ""
echo "Next steps for a provider you like:"
echo "  1. add its API key to your .env (alias <PROVIDER>_API_KEY or PROVIDER_N_ID block)"
echo "  2. bash scripts/bootstrap.sh"
