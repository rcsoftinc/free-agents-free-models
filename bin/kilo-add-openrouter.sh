#!/usr/bin/env bash
set -euo pipefail

# kilo-add-openrouter.sh - register OpenRouter's FREE models with the kilo CLI.
#
# kilo reaches OpenRouter through an OpenAI-compatible provider entry in
# kilo.jsonc. This writes that entry, enumerating the free models explicitly.
#
# WHY AN EXPLICIT WHITELIST (and not ["*"]):
#   "*" exposes OpenRouter's ENTIRE catalogue through this provider, paid models
#   included. Downstream we treat everything kilo exposes on this provider as
#   free - so with "*" the first scheduling decision that picks a paid model
#   spends real money. Listing the free ids explicitly makes that assumption
#   true by construction.
#
# Usage:  kilo-add-openrouter.sh [--dry-run] [--all]
#           --dry-run   print the resulting config, write nothing
#           --all       whitelist "*" instead of the free ids (SPENDS MONEY)
#
# Key: $OPENROUTER_API_KEY, else the key already in kilo.jsonc, else prompted.
# Exit: 0 ok | 3 environment/setup error

CONFIG_FILE="${KILO_CONFIG:-$HOME/.config/kilo/kilo.jsonc}"
API_BASE="https://openrouter.ai/api/v1"
DRY_RUN=0
ALLOW_PAID=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --all)     ALLOW_PAID=1; shift ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 3 ;;
  esac
done

die() { printf 'error: %s\n' "$*" >&2; exit 3; }
command -v jq   >/dev/null || die "jq is required"
command -v curl >/dev/null || die "curl is required"

mkdir -p "$(dirname "$CONFIG_FILE")"
[[ -f "$CONFIG_FILE" ]] || echo '{}' > "$CONFIG_FILE"

# kilo.jsonc permits comments; jq does not. Fail loudly rather than writing a
# mangled config over a file we could not faithfully read.
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die \
  "$CONFIG_FILE is not plain JSON (comments?). jq cannot round-trip it safely - strip comments first."

# Reuse the key already in the config so a re-run never has to be told again,
# and never silently drops the credential that is already working.
EXISTING_KEY="$(jq -r '.provider.openai.options.apiKey // ""' "$CONFIG_FILE")"
API_KEY="${OPENROUTER_API_KEY:-${EXISTING_KEY:-}}"
if [[ -z "$API_KEY" ]]; then
  read -rsp "OpenRouter API key: " API_KEY && echo   # -s: do not echo a secret
fi
[[ -n "$API_KEY" ]] || die "no API key given"

resp="$(mktemp)"; trap 'rm -f "$resp" "${resp}.cfg"' EXIT
curl -fsS --max-time 45 -H "Authorization: Bearer ${API_KEY}" \
     "${API_BASE}/models" -o "$resp" \
  || die "could not reach ${API_BASE}/models (network, or bad key)"
jq -e '.data | type == "array"' "$resp" >/dev/null 2>&1 \
  || die "unexpected response from OpenRouter: $(head -c 200 "$resp")"

# Free means PRICED at zero. The ":free" suffix is a naming convention and
# `test("free")` would also match e.g. "freeform" - pricing is authoritative.
free_models="$(jq -c '
  [ .data[]
    | select((.pricing.prompt      // "1" | tonumber) == 0
         and (.pricing.completion // "1" | tonumber) == 0)
    | {key: .id, value: {name: .name}} ]
  | from_entries' "$resp")"

count="$(jq 'length' <<<"$free_models")"
[[ "$count" -gt 0 ]] || die "no zero-priced models found - refusing to write an empty provider"

# Merge, preserving everything already there. Note the paths are absolute:
# writing this as `.provider // {} | .openai = ...` silently reads
# `.provider.provider.openai` (always null), which drops the apiKey and every
# existing model, whitelist and blacklist entry.
jq --argjson models "$free_models" \
   --arg key "$API_KEY" --arg base "$API_BASE" --argjson paid "$ALLOW_PAID" '
  .provider //= {}
| .provider.openai //= {}
| .provider.openai.options //= {}
| .provider.openai.options.apiKey  = $key
| .provider.openai.options.baseURL = $base
| .provider.openai.options.timeout = (.provider.openai.options.timeout // 300000)
| .provider.openai.models    = ((.provider.openai.models // {}) + $models)
| .provider.openai.blacklist = (.provider.openai.blacklist // [])
| .provider.openai.whitelist =
    (if $paid == 1 then ["*"]
     else ((.provider.openai.whitelist // []) - ["*"]) + ($models | keys) | unique
     end)
' "$CONFIG_FILE" > "${resp}.cfg" || die "failed to build config"

jq -e '.provider.openai.options.apiKey | length > 0' "${resp}.cfg" >/dev/null \
  || die "refusing to write a config without an apiKey"

if [[ $DRY_RUN -eq 1 ]]; then
  jq '.provider.openai.options.apiKey = "<redacted>"' "${resp}.cfg"
  echo "dry run: $count free models would be registered; nothing written." >&2
  exit 0
fi

cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
mv "${resp}.cfg" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"          # it holds a secret

echo "Registered $count free OpenRouter models in $CONFIG_FILE"
[[ $ALLOW_PAID -eq 1 ]] \
  && echo "WARNING: whitelist is [\"*\"] - paid models are reachable and WILL be billed." >&2
echo "Next: bin/buckets.sh discover && bin/buckets.sh probe"
