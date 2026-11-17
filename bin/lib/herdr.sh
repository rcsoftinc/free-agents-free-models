# herdr.sh - what fa shows inside herdr. Sourced by common.sh.
#
# Inside herdr (HERDR_ENV=1, the herdr CLI on PATH), a background job gets a tab of
# its own, and so does each task of a dispatch. A tab streams the job's log (fa jobs
# --follow), and it and herdr's sidebar name the agent working in it, with its state.
# A notification says how a job ended.
#
# A view and nothing more. Agents still run in the background with no terminal, so
# herdr cannot recognize them itself, and fa reports them by name instead. The job
# runs exactly as it does anywhere else, so closing a tab stops nothing, and every
# herdr call is best-effort and time-boxed: herdr failing must never fail, or stall, a
# job or the coordinator that started it. FA_HERDR=0 turns it all off. bin/fa runs
# under set -e, so a read of a file that may be missing here needs its || true.
#
# A view is a folder holding what fa opened for one thing: the job's own folder, or
# tasks/<id> under it for a task. FA_HERDR_VIEW says which one the current work is in.
herdr_on() { [[ "${HERDR_ENV:-}" == 1 && "${FA_HERDR:-1}" != 0 ]] && have herdr; }

# Its JSON on stdout, or nothing - within FA_HERDR_TIMEOUT seconds per call, so
# a hung herdr server costs a detach a few seconds, never the coordinator.
hcall() { timeout "${FA_HERDR_TIMEOUT:-5}" herdr "$@" 2>/dev/null; }

herdr_fa() { printf '%q' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fa"; }

herdr_open_view() { # $1=view folder $2=command to run there -> records the tab, or nothing
  local view="$1" follow="$2" out pane tab where=()
  [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && where=(--workspace "$HERDR_WORKSPACE_ID")
  out="$(hcall tab create "${where[@]}" --cwd "$PWD" --label "fa $(basename "$view")" --no-focus)" || return 0
  pane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out" 2>/dev/null || true)"
  tab="$(jq -r '.result.tab.tab_id // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$pane" ]] || return 0
  mkdir -p "$view"
  printf '%s\n' "$pane" > "$view/herdr_pane"
  printf '%s\n' "$tab" > "$view/herdr_tab"
  hcall pane run "$pane" "$follow" >/dev/null
  return 0
}

herdr_open_job() { # $1=job folder
  herdr_open_view "$1" "$(herdr_fa) jobs --follow $(basename "$1")"
}

# The calling task's own tab, when it runs inside a background job. A task put back
# in the queue keeps the one it had. With no tab, the task must not fall back on the
# job's view, or tasks running side by side would keep relabelling the plan's tab.
herdr_open_task() { # $1=task id
  [[ -n "${FA_LIVE_LOG:-}" ]] && herdr_on || return 0
  local job view
  job="$(dirname "$FA_LIVE_LOG")"; view="${job}/tasks/$1"
  [[ -s "$view/herdr_pane" ]] ||
    herdr_open_view "$view" "$(herdr_fa) jobs --follow $(basename "$job") $(printf '%q' "$1")"
  if [[ -s "$view/herdr_pane" ]]; then export FA_HERDR_VIEW="$view"; else unset FA_HERDR_VIEW; fi
  return 0
}

# The agent the current work just started: its name in the sidebar and on the tab.
# Each attempt calls this, so a fallback to another agent shows.
herdr_agent_working() { # $1=agent
  [[ -n "${FA_HERDR_VIEW:-}" ]] && herdr_on || return 0
  local pane name
  pane="$(cat "$FA_HERDR_VIEW/herdr_pane" 2>/dev/null || true)"
  [[ -n "$pane" ]] || return 0
  name="$(basename "$FA_HERDR_VIEW")"
  printf '%s\n' "$1" 2>/dev/null > "$FA_HERDR_VIEW/herdr_agent" || true
  hcall pane report-agent --source fa --agent "$1" --state working \
    --message "$name: $1" --seq "$(now_ms)" "$pane" >/dev/null
  hcall tab rename "$(cat "$FA_HERDR_VIEW/herdr_tab" 2>/dev/null || true)" "$name $1" >/dev/null
  return 0
}

herdr_view_idle() { # $1=view folder $2=message; keeps the agent's name, or says fa
  local pane agent
  pane="$(cat "$1/herdr_pane" 2>/dev/null || true)"
  [[ -n "$pane" ]] || return 0
  agent="$(cat "$1/herdr_agent" 2>/dev/null || true)"
  hcall pane report-agent --source fa --agent "${agent:-fa}" --state idle \
    --message "$2" --seq "$(now_ms)" "$pane" >/dev/null
  return 0
}

# A task's sidebar state once it ends. Only ever a task's: a plan's tab says how the
# plan ended, and exit 5 is not failure, just no lane free yet (see run.sh).
herdr_task_ended() { # $1=rc
  [[ "${FA_HERDR_VIEW:-}" == */tasks/* ]] && herdr_on || return 0
  local verdict
  case "$1" in
    0) verdict="done" ;;
    5) verdict="waiting for a free lane" ;;
    *) verdict="FAILED rc=$1" ;;
  esac
  herdr_view_idle "$FA_HERDR_VIEW" "$(basename "$FA_HERDR_VIEW") $verdict"
}

herdr_report() { # $1=job folder $2=working|ended [$3=rc]: the sidebar, and the end
  local dir="$1" pane id cmd verdict sound
  herdr_on || return 0
  pane="$(cat "$dir/herdr_pane" 2>/dev/null || true)"
  id="$(basename "$dir")"; cmd="$(cat "$dir/cmd" 2>/dev/null || true)"
  if [[ "$2" == working ]]; then
    [[ -n "$pane" ]] && hcall pane report-agent --source fa --agent fa --state working \
      --message "$id: $cmd" --seq "$(now_ms)" "$pane" >/dev/null
    return 0
  fi
  verdict="done"; sound="done"
  [[ "${3:-}" == 0 ]] || { verdict="FAILED rc=${3:-?}"; sound="request"; }
  herdr_view_idle "$dir" "$id $verdict"
  hcall notification show "fa $id $verdict" --body "$cmd" --sound "$sound" >/dev/null
  return 0
}
