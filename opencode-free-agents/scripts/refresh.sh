#!/usr/bin/env bash
# ============================================================================
# refresh.sh (Linux/Bash port of refresh.ps1)
#
# Full maintenance cycle: balance -> discover free models -> rebuild rankings.
# oc.sh auto-runs this when the list is stale.
#
# Usage: refresh.sh [--force] [--self-test]
# Exit : 0 ok | 3 error
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PKG_ROOT/data"
CONFIG="$SCRIPT_DIR/config.json"
MODELS_PATH="$DATA_DIR/models.json"
RANKINGS_PATH="$DATA_DIR/rankings.json"
SEED="$SCRIPT_DIR/rankings-seed.json"
OVERRIDES="$DATA_DIR/manual-overrides.txt"
AUTH_FILE="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"

FORCE=0; SELF_TEST=0
for arg in "$@"; do
  case "$arg" in
    --force|-Force) FORCE=1 ;;
    --self-test) SELF_TEST=1 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
if [[ $SELF_TEST -eq 0 ]]; then
  command -v opencode >/dev/null || { echo "opencode not on PATH" >&2; exit 3; }
fi

# --- file lock (prevent concurrent refresh) ------------------------------------
LOCK_FILE="/tmp/oc-refresh-$$.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[refresh] another refresh is running; skipping."
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT

# --- self-test mode ------------------------------------------------------------
if [[ $SELF_TEST -eq 1 ]]; then
  echo "[refresh] self-test mode"
  TMPDIR_TEST="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_TEST"' EXIT
  # Create mock models.json and rankings.json
  echo '{"version":1,"updatedAt":"2026-01-01T00:00:00Z","models":[{"id":"test/model-a","provider":"test","free":true,"source":"metadata","context":100000,"reasoning":false}]}' > "$TMPDIR_TEST/models.json"
  echo '{"version":1,"updatedAt":"2026-01-01T00:00:00Z","categories":{"general":["test/model-a"]}}' > "$TMPDIR_TEST/rankings.json"
  # Verify they parse correctly
  jq -e '.models | length' "$TMPDIR_TEST/models.json" >/dev/null || { echo "FAIL: models.json parse" >&2; exit 3; }
  jq -e '.categories.general | length' "$TMPDIR_TEST/rankings.json" >/dev/null || { echo "FAIL: rankings.json parse" >&2; exit 3; }
  echo "[refresh] self-test PASSED"
  exit 0
fi

# --force: destroy and recreate from scratch
if [[ $FORCE -eq 1 ]]; then
  rm -f "$MODELS_PATH" "$RANKINGS_PATH"
  echo "[refresh] --force: cleared models.json + rankings.json"
fi

# --- rate-limit whole cycle (skipped on --force since we just cleared) ---------
if [[ $FORCE -eq 0 && -f "$MODELS_PATH" ]]; then
  updated="$(jq -r '.updatedAt // empty' "$MODELS_PATH")"
  if [[ -n "$updated" ]]; then
    upd_e="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
    age_h=$(( ($(date +%s) - upd_e) / 3600 ))
    stale="$(jq -r '.staleHours' "$CONFIG")"
    if (( age_h < stale )); then
      echo "[refresh] refreshed ${age_h}h ago (< ${stale}h). Nothing to do; use --force."
      exit 0
    fi
  fi
fi

# --- provider key check -------------------------------------------------------
provider_has_key() {
  local provider="$1"
  [[ "$provider" == "opencode" ]] && return 0  # zen works without key
  [[ -f "$AUTH_FILE" ]] || return 1
  local k
  k="$(jq -r --arg p "$provider" '.[$p].key // ""' "$AUTH_FILE" 2>/dev/null || echo "")"
  [[ -n "$k" ]] && return 0 || return 1
}

# ============================================================================
# Step 1: Provider balances
# ============================================================================
echo "== [1/2] Provider balances =="
bash "$SCRIPT_DIR/get-balance.sh" $( [[ $FORCE -eq 1 ]] && echo --force ) || echo "[refresh] balance check reported a problem (continuing)"

# ============================================================================
# Step 2: Discover free models from metadata (instant, no probing)
# ============================================================================
echo ""
echo "== [2/2] Discovering free models =="

# Parse opencode models --verbose output into TSV: id \t context \t reasoning
# Only includes free models (cost.input == 0 && cost.output == 0)
DISCOVERED_TSV="$DATA_DIR/.discovered.$$.tsv"
: > "$DISCOVERED_TSV"
JSONL_FILE="$DATA_DIR/.models.jsonl.$$.tmp"
trap 'rm -f "$DISCOVERED_TSV" "$JSONL_FILE" "$LOCK_FILE"' EXIT

# Step 2a: Awk pairs model IDs with their JSON blocks -> JSONL file
opencode models --verbose 2>/dev/null | awk '
  /^[A-Za-z0-9~]/ { 
    if (id != "") printf "{\"id\":\"%s\",\"meta\":%s}\n", id, json
    id = $1; gsub(/"/, "\\\"", id)
    json = ""; next 
  }
  { json = json $0 }
  END { if (id != "") printf "{\"id\":\"%s\",\"meta\":%s}\n", id, json }
' > "$JSONL_FILE"

# Step 2b: Filter free models with jq (single call on file, no pipefail issues)
jq -r '
  select(.meta.cost.input == 0 and .meta.cost.output == 0) |
  [.id, (.meta.limit.context // 0), (.meta.capabilities.reasoning // false)] | @tsv
' "$JSONL_FILE" > "$DISCOVERED_TSV" 2>/dev/null || true
rm -f "$JSONL_FILE"

# Validate: if opencode succeeded but we got 0 results, the format may have changed
disc_count="$(wc -l < "$DISCOVERED_TSV" 2>/dev/null || echo 0)"
if [[ "$disc_count" -eq 0 ]]; then
  echo "[refresh] WARNING: opencode models --verbose returned 0 free models." >&2
  echo "[refresh] The output format may have changed. Check: opencode models --verbose | head -20" >&2
fi

# build models.json: only free models from providers with keys
FILTERED_TSV="$DATA_DIR/.filtered.$$.tsv"
: > "$FILTERED_TSV"

# DISCOVERED_TSV has: id \t context \t reasoning (all already free)
while IFS=$'\t' read -r id ctx reasoning; do
  provider="${id%%/*}"
  if provider_has_key "$provider"; then
    printf '%s\t%s\t%s\t%s\n' "$id" "$provider" "${ctx:-0}" "$reasoning" >> "$FILTERED_TSV"
  fi
done < "$DISCOVERED_TSV"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg ts "$ts" --argjson models "$(
  jq -R 'split("\t") | {id: .[0], provider: .[1], free: true, source: "metadata", context: (.[2] | tonumber | if . > 0 then . else null end), reasoning: (.[3] == "true")}' \
    "$FILTERED_TSV" | jq -s '.'
)" '{version:1, updatedAt:$ts, models:$models}' \
  > "$MODELS_PATH.tmp" && mv "$MODELS_PATH.tmp" "$MODELS_PATH"

rm -f "$DISCOVERED_TSV" "$FILTERED_TSV"

# Validate models.json
total="$(jq '.models | length' "$MODELS_PATH" 2>/dev/null)"
if [[ -z "$total" || "$total" == "null" ]]; then
  echo "[refresh] ERROR: models.json is invalid or empty after build." >&2
  exit 3
fi

# --- Step 2c: Merge manual overrides ------------------------------------------
if [[ -f "$OVERRIDES" ]]; then
  manual_added=0
  while IFS= read -r line; do
    # skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    id="$(echo "$line" | tr -d '[:space:]')"
    # skip if already in models.json
    exists="$(jq -r --arg id "$id" '[.models[] | select(.id==$id)] | length' "$MODELS_PATH")"
    [[ "$exists" != "0" ]] && continue
    provider="${id%%/*}"
    if provider_has_key "$provider"; then
      rec="$(jq -cn --arg id "$id" --arg p "$provider" --arg ts "$ts" \
        '{id:$id, provider:$p, free:true, source:"manual", context:null, reasoning:false}')"
      tmp="$(mktemp)"
      jq --argjson rec "$rec" '.models += [$rec]' "$MODELS_PATH" > "$tmp" && mv "$tmp" "$MODELS_PATH"
      manual_added=$((manual_added + 1))
    fi
  done < "$OVERRIDES"
  if [[ $manual_added -gt 0 ]]; then
    echo "[refresh] added $manual_added manual overrides from manual-overrides.txt"
    total="$(jq '.models | length' "$MODELS_PATH")"
  fi
fi

echo "[refresh] discovered $total free models -> data/models.json"

# ============================================================================
# Step 3: Rebuild category rankings
# ============================================================================
echo ""
echo "== [3/2] Rebuilding rankings =="

LAST_RESORT="$(jq -r '.lastResortModel' "$CONFIG")"

# Pre-compute model data as bash associative arrays (avoids per-model jq calls)
declare -A MODEL_CTX MODEL_REASONING MODEL_EXISTS
while IFS=$'\t' read -r id ctx reasoning; do
  MODEL_CTX["$id"]="${ctx:-0}"
  MODEL_REASONING["$id"]="${reasoning:-false}"
  MODEL_EXISTS["$id"]=1
done < <(jq -r '.models[] | [.id, (.context // 0), (.reasoning // false)] | @tsv' "$MODELS_PATH")

# Pre-compute excluded set
declare -A EXCLUDED
while IFS= read -r id; do
  EXCLUDED["$id"]=1
done < <(jq -r '(.excluded.models // [])[]' "$SEED")

# Pre-compute seed categories
declare -A SEED_IDS
for cat in $(jq -r '.categories | keys_unsorted[]' "$SEED"); do
  while IFS= read -r id; do
    [[ -n "$id" ]] && SEED_IDS["${cat}:${id}"]=1
  done < <(jq -r --arg c "$cat" '.categories[$c][]' "$SEED")
done

# Score function (pure bash, no jq)
score() {
  local id="$1" ctx="${MODEL_CTX[$id]:-0}" r="${MODEL_REASONING[$id]:-false}"
  echo "scale=2; ${ctx:-0}/1000 + $([ "$r" = "true" ] && echo 50 || echo 0)" | bc 2>/dev/null || echo "0"
}

dropped=0
OUT='{}'
for cat in $(jq -r '.categories | keys_unsorted[]' "$SEED"); do
  ORDERED=()
  add() { local id="$1"; for e in "${ORDERED[@]:-}"; do [[ "$e" == "$id" ]] && return; done; ORDERED+=("$id"); }

  # Add seed models (in order, if they exist and aren't excluded)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ -n "${EXCLUDED[$id]:-}" ]] && continue
    if [[ -z "${MODEL_EXISTS[$id]:-}" ]]; then
      dropped=$((dropped + 1))
      continue
    fi
    add "$id"
  done < <(jq -r --arg c "$cat" '.categories[$c][]' "$SEED")

  # Append discovered models missing from seed, best score first
  extras="$(mktemp)"
  : > "$extras"
  for id in "${!MODEL_EXISTS[@]}"; do
    [[ "$id" == "$LAST_RESORT" ]] && continue
    [[ -n "${SEED_IDS[${cat}:${id}]:-}" ]] && continue
    [[ -n "${EXCLUDED[$id]:-}" ]] && continue
    printf '%s\t%s\t%s\n' "$(score "$id")" "${MODEL_CTX[$id]:-0}" "$id"
  done >> "$extras"
  if [[ -s "$extras" ]]; then
    while IFS=$'\t' read -r _s _ctx id; do [[ -n "$id" ]] && add "$id"; done < <(sort -t$'\t' -k1,1nr -k2,2nr "$extras")
  fi
  rm -f "$extras"

  # Pin last-resort auto-router at the very end
  if [[ -n "$LAST_RESORT" && -z "${EXCLUDED[$LAST_RESORT]:-}" ]]; then
    add "$LAST_RESORT"
  fi

  json_arr="$(jq -cn '$ARGS.positional' --args "${ORDERED[@]:-}")"
  OUT="$(jq -c --arg c "$cat" --argjson arr "$json_arr" '. + {($c): $arr}' <<<"$OUT")"
done

jq -n --arg ts "$ts" --argjson categories "$OUT" '{version:1, updatedAt:$ts, categories:$categories}' \
  > "$RANKINGS_PATH.tmp" && mv "$RANKINGS_PATH.tmp" "$RANKINGS_PATH"

ncat="$(jq -r '.categories | length' "$RANKINGS_PATH")"
echo "[refresh] rankings rebuilt: $ncat categories, $total models -> data/rankings.json"
if [[ $dropped -gt 0 ]]; then
  echo "[refresh] NOTE: $dropped seed models not found in metadata (dropped from rankings)"
fi
exit 0
