#!/usr/bin/env bash
# ============================================================================
# oc.sh (Linux/Bash port of oc.ps1 - identical flags, output contract, exits)
#
# Run any opencode task headlessly with automatic free-model fallback.
# THE entry point agents use to delegate work to opencode.
#
# Output contract:
#   stdout : model output, then final footer:
#            ---OC-META---
#            {"session":"...","model":"...","attempts":N,"category":"..."}
#   stderr : [oc] diagnostics
#   exit   : 0 success | 2 all models exhausted | 3 bootstrap error
#
# Usage: oc.sh [options] "message"
#   -c CATEGORY    coding|reasoning|research|general|fast (default general)
#   -m MODEL       pin a specific model first in the chain
#   -s SESSION_ID  continue this session (survives model switches)
#   -C             continue most recent session
#   -a AGENT       agent name passthrough
#   -j             --format json events (raw output passed through)
#   -N             no --auto (disable permission auto-approval)
#   -S             skip refresh-on-stale logic
#   -t SECONDS     run timeout (default config.runTimeoutSeconds)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PKG_ROOT/data"
CONFIG="$SCRIPT_DIR/config.json"
MODELS_PATH="$DATA_DIR/models.json"
RANKINGS_PATH="$DATA_DIR/rankings.json"

CATEGORY="general"; MODEL=""; SID=""; CONT=0; AGENT=""; JSON=0; NOAUTO=0; SKIPREFRESH=0; TIMEOUT=0
MESSAGE=""
while getopts "c:m:s:a:CjNSt:" opt; do
  case "$opt" in
    c) CATEGORY="$OPTARG" ;; m) MODEL="$OPTARG" ;; s) SID="$OPTARG" ;;
    C) CONT=1 ;; a) AGENT="$OPTARG" ;; j) JSON=1 ;; N) NOAUTO=1 ;;
    S) SKIPREFRESH=1 ;; t) TIMEOUT="$OPTARG" ;;
    \?) echo "usage: oc.sh [-c cat] [-m model] [-s sid] [-C] [-a agent] [-j] [-N] [-S] [-t sec] \"msg\"" >&2; exit 3 ;;
  esac
done
shift $((OPTIND-1))
[[ $# -ge 1 ]] || { echo "[oc] message required" >&2; exit 3; }
MESSAGE="$1"

command -v jq >/dev/null || { echo "[oc] jq required" >&2; exit 3; }
command -v opencode >/dev/null || { echo "[oc] opencode not on PATH" >&2; exit 3; }

source "$SCRIPT_DIR/classify-error.sh"

# --- config validation ---------------------------------------------------------
if ! jq -e '.runTimeoutSeconds' "$CONFIG" >/dev/null 2>&1; then
  echo "[oc] ERROR: config.json is missing or malformed (runTimeoutSeconds required)" >&2
  exit 3
fi

# --- temp file cleanup on exit -------------------------------------------------
_cleanup() { rm -f "$outF" "$errF" "$LOCK_FILE" 2>/dev/null; }
outF=""; errF=""; LOCK_FILE=""
trap _cleanup EXIT

diag() { printf '[oc] %s\n' "$*" >&2; }
cfg()  { jq -r "$1" "$CONFIG"; }

if [[ $TIMEOUT -le 0 ]]; then TIMEOUT="$(cfg '.runTimeoutSeconds')"; fi

# --- bootstrap if needed -------------------------------------------------------
need_refresh=0
if [[ ! -f $MODELS_PATH || ! -f $RANKINGS_PATH ]]; then need_refresh=1; fi
if [[ $need_refresh -eq 0 && $SKIPREFRESH -eq 0 ]] && [[ "$(cfg '.autoRefreshOnStale')" == "true" ]]; then
  updated="$(jq -r '.updatedAt // empty' "$MODELS_PATH" 2>/dev/null || echo "")"
  if [[ -n "$updated" ]]; then
    upd_e="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
    age_h=$(( ($(date +%s) - upd_e) / 3600 ))
    stale="$(cfg '.staleHours')"
    if (( age_h > stale )); then
      if (( age_h < 4 )); then diag "list stale (${age_h}h) but recently refreshed; skipping refresh"
      else need_refresh=1; fi
    fi
  fi
fi
if [[ $need_refresh -eq 1 && $SKIPREFRESH -eq 0 ]]; then
  diag "model list missing/stale -> refresh.sh (~2-3 seconds)"
  bash "$SCRIPT_DIR/refresh.sh" || true
fi
[[ -f $RANKINGS_PATH ]] || { echo "[oc] rankings.json missing after refresh" >&2; exit 3; }

# --- retryable() ---------------------------------------------------------------
retryable() { # id -> 0 true / 1 false
  local id="$1" st lc last_e age_min
  st="$(jq -r --arg id "$id" '.models[] | select(.id==$id) | .status // ""' "$MODELS_PATH" 2>/dev/null)"
  [[ -z "$st" ]] && return 0                      # unknown -> worth trying
  [[ "$st" == "ok" ]] && return 0
  lc="$(jq -r --arg id "$id" '.models[] | select(.id==$id) | .lastChecked // ""' "$MODELS_PATH")"
  [[ -z "$lc" ]] && return 0
  last_e="$(date -u -d "$lc" +%s 2>/dev/null || echo 0)"
  age_min=$(( ($(date +%s) - last_e) / 60 ))
  case "$st" in
    rate_limited)     (( age_min > $(cfg '.retryAfter.rate_limited_minutes') )) && return 0 || return 1 ;;
    timeout)          (( age_min > $(cfg '.retryAfter.timeout_minutes') * 60 )) && return 0 || return 1 ;;
    no_credits)       (( age_min > $(cfg '.retryAfter.no_credits_hours') * 60 )) && return 0 || return 1 ;;
    context_overflow) return 1 ;;
    auth_error)       (( age_min > $(cfg '.retryAfter.no_credits_hours') * 60 )) && return 0 || return 1 ;;
    *)                (( age_min > $(cfg '.retryAfter.dead_hours') * 60 )) && return 0 || return 1 ;;
  esac
}

cat_name="$CATEGORY"
jq -e --arg c "$cat_name" '.categories[$c]' "$RANKINGS_PATH" >/dev/null 2>&1 || cat_name="general"

CHAIN=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  for existing in "${CHAIN[@]:-}"; do [[ "$existing" == "$id" ]] && continue 2; done
  if retryable "$id"; then CHAIN+=("$id"); fi
done < <(jq -r --arg c "$cat_name" '.categories[$c][]' "$RANKINGS_PATH")

if [[ -n "$MODEL" ]]; then
  CHAIN=("$MODEL" "${CHAIN[@]:-}")
  declare -A seenD=(); DEDUPED=()
  for id in "${CHAIN[@]}"; do [[ -z "${seenD[$id]:-}" ]] && { seenD[$id]=1; DEDUPED+=("$id"); }; done
  CHAIN=("${DEDUPED[@]:-}")
fi

MAXATTEMPTS="$(cfg '.maxAttemptsPerRun')"
if [[ ${#CHAIN[@]} -eq 0 ]]; then
  echo "[oc] NO eligible models for category '$cat_name'. Run scripts/refresh.sh --force." >&2
  exit 2
fi
diag "chain ($cat_name): $(printf '%s -> ' "${CHAIN[@]:0:$MAXATTEMPTS}" | sed 's/ -> $//')"

attempt=0; used_model=""

# --- file lock (prevent concurrent models.json corruption) --------------------
LOCK_FILE="/tmp/oc-run-$$.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  diag "another oc instance is running; waiting..."
  flock 9  # block until available
fi

for candidate in "${CHAIN[@]:0:$MAXATTEMPTS}"; do
  attempt=$((attempt+1))
  diag "attempt $attempt/$MAXATTEMPTS via $candidate"

  args=(run "$MESSAGE")
  [[ -n "$SID" ]] && args+=(-s "$SID")
  [[ $CONT -eq 1 && -z "$SID" ]] && args+=(-c)
  args+=(-m "$candidate")
  [[ -n "$AGENT" ]] && args+=(--agent "$AGENT")
  [[ $JSON -eq 1 ]] && args+=(--format json)
  [[ $NOAUTO -eq 0 ]] && args+=(--auto)
  args+=(--title "oc-skill")

  outF="$(mktemp)"; errF="$(mktemp)"
  start_ms=$(($(date +%s%N)/1000000))
  timeout "${TIMEOUT}s" opencode "${args[@]}" >"$outF" 2>"$errF"
  rc=$?
  end_ms=$(($(date +%s%N)/1000000))
  lat=$((end_ms-start_ms))

  err_text="$(cat "$errF" 2>/dev/null || true)"
  raw_out="$(cat "$outF" 2>/dev/null || true)"

  if [[ $rc -eq 124 ]]; then status="timeout"
  elif [[ -n "${raw_out//[[:space:]]/}" ]]; then status="ok"
  else
    status="$(printf '%s' "$err_text" | classify)"
  fi
  rm -f "$outF" "$errF"
  outF=""; errF=""

  # record outcome in models.json
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exists="$(jq -r --arg id "$candidate" '.models[] | select(.id==$id) | .id // ""' "$MODELS_PATH" 2>/dev/null)"
  if [[ -z "$exists" ]]; then
    newrec="$(jq -cn --arg id "$candidate" --arg ts "$ts" '{id:$id, provider:($id|split("/")[0]), free:true,
      source:"runtime", status:"unknown", lastChecked:$ts, latencyMs:null, context:null, reasoning:null,
      successCount:0, failCount:0, latencySamplesMs:0, latencyRuns:0, lastError:null}')"
    tmp="$(mktemp)"
    jq --argjson rec "$newrec" '.models += [$rec]' "$MODELS_PATH" > "$tmp" && mv "$tmp" "$MODELS_PATH"
  fi
  if [[ "$status" == "ok" ]]; then
    tmp="$(mktemp)"
    jq --arg id "$candidate" --arg ts "$ts" --argjson lat "$lat" \
      '.models |= map(if .id==$id then (.successCount+=1 | .latencySamplesMs+=(($lat)) | .latencyRuns+=1 | .latencyMs=$lat | .lastChecked=$ts | .status="ok" | .lastError=null) else . end)' \
      "$MODELS_PATH" > "$tmp" && mv "$tmp" "$MODELS_PATH"
  else
    err_first="$(printf '%s' "$err_text" | grep -m1 . || echo '(no stderr)')"
    [[ ${#err_first} -gt 200 ]] && err_first="${err_first:0:200}"
    tmp="$(mktemp)"
    jq --arg id "$candidate" --arg ts "$ts" --arg st "$status" --arg le "$err_first" \
      '.models |= map(if .id==$id then (.failCount+=1 | .lastChecked=$ts | .status=$st | .lastError=$le) else . end)' \
      "$MODELS_PATH" > "$tmp" && mv "$tmp" "$MODELS_PATH"
  fi

  if [[ "$status" == "ok" ]]; then used_model="$candidate"; break; fi
  diag "$candidate failed ($status); falling back"
done

if [[ -z "$used_model" ]]; then
  echo "[oc] ALL candidate models exhausted (category '$cat_name', attempts=$MAXATTEMPTS)." >&2
  echo "[oc] Check balance: scripts/get-balance.sh ; refresh: scripts/refresh.sh --force" >&2
  exit 2
fi

# --- resolve session id ----------------------------------------------------------
if [[ -z "$SID" ]]; then
  SID="$(opencode session list 2>/dev/null | grep -oE 'ses_[A-Za-z0-9]+' | head -1 || echo "")"
fi

printf '%s\n' "$(printf '%s' "$raw_out" | sed -e 's/[[:space:]]*$//')"
echo '---OC-META---'
jq -cn --arg s "$SID" --arg m "$used_model" --argjson a "$attempt" --arg c "$cat_name" \
  '{session:$s, model:$m, attempts:$a, category:$c}'
exit 0
