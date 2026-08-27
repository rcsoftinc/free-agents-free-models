#!/usr/bin/env bash
# dispatch.sh — orchestrator: run each task as an ISOLATED session, respecting a
# dependency graph, with PARALLEL execution where independent + executor (runner)
# DIVERSITY so a rate-limited/exhausted provider on one runner never blocks the
# batch. Audits agent + model + session + tokens per task.
#
# Usage:
#   dispatch.sh taskfile.json [--max-parallel N] [--timeout SEC] [--workdir DIR]
#
# taskfile.json shape:
#   { "tasks": [ { "id": "...", "prompt": "...",
#     "executor": "opencode|direct|kilo|hermes"   # default opencode
#     "model": "<provider/model-id>",             # optional pin (opencode only)
#     "category": "coding", "deps": ["id"], "timeout": 280 } ] }
#
# Outputs:
#   <workdir>/dispatch-report.json   per-task: id, executor, model, session,
#                                     attempts, status, exit, tokens, elapsed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC="${OC_SCRIPT:-$(cd "$SCRIPT_DIR/.." && pwd)/opencode-free-agents/scripts/oc.sh}"

TASKFILE="${1:?taskfile.json required}"
MAX_PARALLEL=2
TIMEOUT=280
WORKDIR="$(pwd)"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
command -v sqlite3 >/dev/null || { echo "sqlite3 required" >&2; exit 3; }
cd "$WORKDIR" || exit 3

RESULTS_DIR=".dispatch-results"
rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"

declare -A DONE=()
declare -A PIDS=()
declare -A RUNLIST=()
FAILED=0; EXHAUSTED=0

log() { printf '[dispatch] %s\n' "$*"; }

ids()      { jq -r '.tasks[].id' "$TASKFILE"; }
field()    { jq -r --arg id "$1" --arg k "$2" '.tasks[] | select(.id==$id) | .[$k] // ""' "$TASKFILE"; }

ready_tasks() {
  local id d deps_ok
  for id in $(ids); do
    [[ -n "${DONE[$id]:-}" ]] && continue
    [[ -n "${RUNLIST[$id]:-}" ]] && continue
    deps_ok=1
    for d in $(field "$id" deps); do
      [[ -n "${DONE[$d]:-}" ]] || { deps_ok=0; break; }
    done
    [[ $deps_ok -eq 1 ]] && echo "$id"
  done
}

measure_session() { # session_id -> "input output cache_read"
  local s="$1" tin=0 tout=0 tc=0
  if [[ -n "$s" ]]; then
    tin=$(sqlite3 "$HOME/.local/share/opencode/opencode.db" \
      "SELECT COALESCE(SUM(json_extract(data,'$.tokens.input')),0) FROM message WHERE session_id='$s';" 2>/dev/null || echo 0)
    tout=$(sqlite3 "$HOME/.local/share/opencode/opencode.db" \
      "SELECT COALESCE(SUM(json_extract(data,'$.tokens.output')),0) FROM message WHERE session_id='$s';" 2>/dev/null || echo 0)
    tc=$(sqlite3 "$HOME/.local/share/opencode/opencode.db" \
      "SELECT COALESCE(SUM(json_extract(data,'$.tokens.cache.read')),0) FROM message WHERE session_id='$s';" 2>/dev/null || echo 0)
  fi
  echo "$tin $tout $tc"
}

run_via_opencode() { # id
  local id="$1"
  local prompt agent model cat to rc summary model_used session attempts tin=0 tout=0 tc=0
  prompt="$(field "$id" prompt)"; agent="$(field "$id" agent)"; model="$(field "$id" model)"
  cat="$(field "$id" category)"; cat="${cat:-coding}"; to="$(field "$id" timeout)"; to="${to:-$TIMEOUT}"
  log "START  $id [opencode] model=${model:-auto} cat=$cat timeout=${to}s"
  local args=(-c "$cat" -t "$to")
  [[ -n "$agent" ]] && args+=(-a "$agent")
  [[ -n "$model" ]] && args+=(-m "$model")
  args+=("$prompt")
  local t0 t1; t0=$(date +%s)
  summary=$(bash "$OC" "${args[@]}" 2>&1) || true
  rc=$? t1=$(date +%s)
  model_used=$(printf '%s' "$summary" | sed -n '/---OC-META---/{n;p;}' | jq -r '.model // ""' 2>/dev/null || echo "")
  session=$(printf '%s' "$summary" | sed -n '/---OC-META---/{n;p;}' | jq -r '.session // ""' 2>/dev/null || echo "")
  attempts=$(printf '%s' "$summary" | sed -n '/---OC-META---/{n;p;}' | jq -r '.attempts // ""' 2>/dev/null || echo "")
  if [[ -n "$session" ]]; then read tin tout tc <<<"$(measure_session "$session")"; fi
  local status="ok"
  if [[ $rc -eq 2 ]]; then
    status="exhausted"; EXHAUSTED=$((EXHAUSTED+1))
    log "WARN   $id — all candidate models exhausted (rate-limited/no credits): $(printf '%s' "$summary" | grep -m1 '\[oc\]' || echo 'see log')"
  elif [[ $rc -ne 0 ]]; then
    status="exited_$rc"; FAILED=$((FAILED+1))
  fi
  jq -cn --arg id "$id" --arg executor "opencode" --arg model "$model_used" \
     --arg session "$session" --arg attempts "$attempts" --arg status "$status" \
     --argjson rc "$rc" --argjson tin "$tin" --argjson tout "$tout" --argjson tc "$tc" \
     --argjson elapsed "$((t1-t0))" \
     '{id:$id, executor:$executor, model:$model, session:$session, attempts:$attempts,
       status:$status, exit:$rc, tokens:{input:$tin, output:$tout, cache_read:$tc}, elapsed_s:$elapsed}' \
     > "$RESULTS_DIR/$id.jsonl"
  log "DONE   $id rc=$rc status=$status model=$model_used session=$session elapsed=$((t1-t0))s"
}

run_via_direct() { # id, runner = kilo|hermes|direct
  local id="$1" runr="$2"
  local prompt exec_model to rc t0 t1 tin=0 tout=0
  prompt="$(field "$id" prompt)"; exec_model="$(field "$id" model)"; to="$(field "$id" timeout)"; to="${to:-$TIMEOUT}"
  log "START  $id [$runr] model=${exec_model:-default} timeout=${to}s"
  t0=$(date +%s)
  case "$runr" in
    kilo)
      local args=(run "$prompt")
      [[ -n "$exec_model" ]] && args+=(-m "$exec_model")
      args+=(--print-logs)
      # run headless, kill after timeout
      rc=$(timeout "${to}s" kilo "${args[@]}" >/dev/null 2>"$RESULTS_DIR/$id.stderr") 2>/dev/null; rc=$?
      ;;
    hermes)
      local args=(chat -z "$prompt")
      [[ -n "$exec_model" ]] && args+=(-m "$exec_model")
      rc=$(timeout "${to}s" hermes "${args[@]}" >/dev/null 2>"$RESULTS_DIR/$id.stderr") 2>/dev/null; rc=$?
      ;;
    direct)
      rc=0  # noop placeholder
      ;;
  esac
  t1=$(date +%s)
  local status="ok"; [[ $rc -ne 0 ]] && { status="exited_$rc"; FAILED=$((FAILED+1)); }
  jq -cn --arg id "$id" --arg executor "$runr" --arg model "$exec_model" \
     --arg status "$status" --argjson rc "$rc" --argjson tin "$tin" --argjson tout "$tout" --argjson tc "0" \
     --argjson elapsed "$((t1-t0))" \
     '{id:$id, executor:$executor, model:$model, session:"", attempts:1,
       status:$status, exit:$rc, tokens:{input:$tin, output:$tout, cache_read:0}, elapsed_s:$elapsed}' \
     > "$RESULTS_DIR/$id.jsonl"
  log "DONE   $id [$runr] rc=$rc status=$status elapsed=$((t1-t0))s"
}

reap_done() {
  local id pid
  for id in "${!RUNLIST[@]}"; do
    pid="${RUNLIST[$id]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      DONE["$id"]=1; unset 'RUNLIST[$id]'
    fi
  done
}

round=0
while true; do
  reap_done
  remaining=0
  for id in $(ids); do [[ -z "${DONE[$id]:-}" ]] && remaining=$((remaining+1)); done
  [[ $remaining -eq 0 ]] && break

  round=$((round+1))
  for id in $(ready_tasks); do
    [[ ${#RUNLIST[@]} -ge $MAX_PARALLEL ]] && break
    execr="$(field "$id" executor)"; execr="${execr:-opencode}"
    if [[ "$execr" == "opencode" ]]; then run_via_opencode "$id" &
    else run_via_direct "$id" "$execr" & fi
    RUNLIST["$id"]=$!
  done
  [[ ${#RUNLIST[@]} -eq 0 ]] && { log "round $round: 0 running, $remaining pending — deadlock, sleeping"; sleep 5; }
  sleep 1
done

log "=== dispatch complete: failed=$FAILED exhausted=$EXHAUSTED ==="
printf '%s\n' "$RESULTS_DIR"/*.jsonl 2>/dev/null | jq -s 'sort_by(.id)' > dispatch-report.json 2>/dev/null || printf '[]\n' > dispatch-report.json

echo ""
echo "=== per-task report (executor + model + session + tokens) ==="
jq -r '.[] | "\(.id)\t\(.executor)\t\(.model // "-")\t\(.status)\tin=\(.tokens.input)\tout=\(.tokens.output)\t\(.elapsed_s)s\t\(.session // "-")"' \
  dispatch-report.json | column -t -s $'\t'
echo ""
echo "=== aggregate ==="
jq '{total_input:[.[].tokens.input]|add, total_output:[.[].tokens.output]|add, total_cache:[.[].tokens.cache_read]|add, failed:[.[]|select(.status|startswith("exited_"))]|length, exhausted:[.[]|select(.status=="exhausted")]|length}' \
  dispatch-report.json