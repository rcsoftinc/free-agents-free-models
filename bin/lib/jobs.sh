# jobs.sh - background jobs: `fa run --detach` and `fa dispatch --detach`.
# Source, do not execute. Needs common.sh (now_epoch, die, have).
#
# Why: the coordinator is the director's one conversation. While `fa run` or
# `fa dispatch` holds it, nobody can ask it anything - and the work itself needs
# nothing from it until it is done. --detach starts the same command in the
# background and returns at once with a job id; `fa jobs` and `fa status` report
# on it. Workers launched by a job are still workers (FA_DEPTH, common.sh).
#
# A job is a directory, <project>/.orch/jobs/<id>/ (gitignored):
#   cmd          the fa command it runs, for display
#   started_at   epoch seconds;   pid   the runner's own pid
#   log          everything the command printed
#   rc           written when it ends - its presence is what "finished" means
#   finished_at  epoch seconds
#   coordinator  the agent that started it ("none" outside one) - see below
#   herdr_pane   the pane it is watched from, when started inside herdr
#   seen         set once `fa jobs --news` has reported its end
#
# Detaching has to survive the CALLER, which is usually an agent CLI's shell
# tool, and every one of these was a way for it not to:
#   - setsid: a new session, so a tool that kills its process group when the
#     call returns (or times out) does not take the job with it
#   - stdio to files, stdin from /dev/null: a background process still holding
#     the tool's stdout makes the tool wait for it anyway - `&` alone gives the
#     caller nothing back
#   - a double fork, so the job is nobody's child and nothing waits on it
#
# That double fork also cuts the job off from its ancestry, which is how
# common.sh finds the coordinator whose wallet workers must leave alone - so the
# coordinator is read HERE, while it is still an ancestor, and handed to the job
# as FA_COORDINATOR.

# Physical path: job_state finds a runner by the job dir in its command line,
# and a symlinked cwd would otherwise spell the same dir two ways.
jobs_dir() { printf '%s/.orch/jobs' "$(pwd -P)"; }

# .orch/ and the .gitignore that keeps jobs/ out of git - written by orch.sh,
# its one writer, before any job writes there.
jobs_ensure_orch() {
  grep -qsx 'jobs/' "$PWD/.orch/.gitignore" && return 0
  ORCH_PROJECT="$PWD" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/orch.sh" init >/dev/null
}

# 0 if an orchestrator holds this project's run lock (orch.sh cmd_run).
orch_run_active() {
  local f="$PWD/.orch/.run.lock"
  [[ -f "$f" ]] || return 1
  ! ( exec 9<>"$f"; flock -n 9 ) 2>/dev/null
}

job_next_id() { # -> j1, j2, ... - short enough to type, allocated under a lock
  local dir; dir="$(jobs_dir)"; mkdir -p "$dir"
  ( flock -w 10 9 || exit 1
    local n; n=$(( $(cat "$dir/.seq" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$dir/.seq"
    printf 'j%s' "$n"
  ) 9>"$dir/.seq.lock"
}

job_start() { # $1=tool root; rest = fa arguments to run detached -> prints the id
  local root="$1"; shift
  local id dir a disp="fa"
  id="$(job_next_id)" || die "could not allocate a job id"
  dir="$(jobs_dir)/${id}"; mkdir -p "$dir"
  for a in "$@"; do
    if [[ "$a" == *[[:space:]]* ]]; then disp+=" \"${a}\""; else disp+=" ${a}"; fi
  done
  printf '%s\n' "$disp" > "$dir/cmd"
  now_epoch > "$dir/started_at"
  local coord; coord="$(coordinator_agent)"; coord="${coord:-none}"
  printf '%s\n' "$coord" > "$dir/coordinator"
  # Inside herdr, a tab to watch it from - opened BEFORE the job starts, so the
  # job already knows where to report its state (herdr.sh).
  herdr_on && herdr_open_job "$dir"
  local launch=(nohup); have setsid && launch=(setsid nohup)
  # >>: agents' lines are appended to this log as well (FA_LIVE_LOG), and a plain >
  # would write over them.
  ( FA_COORDINATOR="$coord" "${launch[@]}" "${root}/bin/fa" __job "$dir" "$@" \
      </dev/null >>"$dir/log" 2>&1 & )
  printf '%s' "$id"
}

job_run() { # $1=job dir; rest = fa arguments. The detached half of job_start.
  local dir="$1"; shift
  printf '%s\n' "$$" > "$dir/pid"
  # Lets a command tell it is running as a background job: `fa dispatch` then
  # runs the plan whatever the split, since nobody is there to "work directly".
  export FA_JOB; FA_JOB="$(basename "$dir")"
  # What agents print goes to the log, and so to the job's pane, as they print it.
  # `fa run` writes its result to this same log, which would show it all twice; a
  # dispatch keeps each result in its own file, and plans read theirs, so only
  # `fa run` drops it.
  export FA_LIVE_LOG="${dir}/log"
  if [[ "${1:-}" == run ]]; then export FA_LIVE_SKIP_RESULT=1; fi
  export FA_HERDR_VIEW="$dir"
  herdr_report "$dir" working
  local rc=0
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fa" "$@" || rc=$?
  now_epoch > "$dir/finished_at"
  printf '%s\n' "$rc" > "$dir/rc.tmp" && mv "$dir/rc.tmp" "$dir/rc"
  herdr_report "$dir" ended "$rc"
  return "$rc"
}

job_state() { # $1=job dir -> starting | running | done | failed | died
  local dir="$1" pid
  if [[ -f "$dir/rc" ]]; then
    [[ "$(cat "$dir/rc")" == "0" ]] && echo done || echo failed
    return 0
  fi
  pid="$(cat "$dir/pid" 2>/dev/null || true)"
  # By command line, not just `kill -0`: a pid freed by a dead runner can be
  # reused by anything.
  if [[ -n "$pid" ]] && ps -p "$pid" -o args= 2>/dev/null | grep -qF -- "__job $dir"; then
    echo running; return 0
  fi
  if [[ -z "$pid" ]] && (( $(now_epoch) - $(cat "$dir/started_at" 2>/dev/null || echo 0) < 10 )); then
    echo starting; return 0
  fi
  echo died   # no exit recorded and no process: killed mid-run (or the machine stopped)
}

job_elapsed() { # $1=job dir -> e.g. 4m07s
  local dir="$1" s e
  s="$(cat "$dir/started_at" 2>/dev/null || echo 0)"
  e="$(cat "$dir/finished_at" 2>/dev/null || now_epoch)"
  printf '%dm%02ds' $(( (e - s) / 60 )) $(( (e - s) % 60 ))
}

job_label() { # $1=job dir -> starting | running | done | FAILED rc=N | DIED
  case "$(job_state "$1")" in
    failed) printf 'FAILED rc=%s' "$(cat "$1/rc")" ;;
    died)   printf 'DIED' ;;
    *)      job_state "$1" ;;
  esac
}

job_line() { # $1=job dir -> one row for a listing
  local dir="$1" label cmd
  label="$(job_label "$dir")"
  cmd="$(cat "$dir/cmd" 2>/dev/null)"
  (( ${#cmd} > 64 )) && cmd="${cmd:0:61}..."
  printf '  %-4s %-13s %7s  %s\n' "$(basename "$dir")" "$label" "$(job_elapsed "$dir")" "$cmd"
}

jobs_all() { # -> job dirs, oldest first
  local d; d="$(jobs_dir)"
  [[ -d "$d" ]] || return 0
  find "$d" -mindepth 1 -maxdepth 1 -type d -name 'j[0-9]*' | sort -V
}

jobs_list() {
  local dirs d; dirs="$(jobs_all)"
  [[ -n "$dirs" ]] || { echo "no background jobs in this project"; return 0; }
  echo "background jobs ($(jobs_dir))"
  while IFS= read -r d; do job_line "$d"; done <<<"$dirs"
  echo "one job: fa jobs <id>     drop finished ones: fa jobs --clean"
}

job_show() { # $1=job id
  local dir; dir="$(jobs_dir)/$1"
  [[ -d "$dir" ]] || { echo "fa jobs: no job '$1' here - see: fa jobs" >&2; return 3; }
  printf 'job %s: %s\n' "$1" "$(cat "$dir/cmd" 2>/dev/null)"
  printf '  state:  %s (%s)\n' "$(job_state "$dir")" "$(job_elapsed "$dir")"
  [[ -f "$dir/rc" ]] && printf '  exit:   %s\n' "$(cat "$dir/rc")"
  printf '  log:    %s\n' "$dir/log"
  [[ -s "$dir/herdr_tab" ]] && printf '  tab:    %s (herdr)\n' "$(cat "$dir/herdr_tab")"
  local c; c="$(cat "$dir/coordinator" 2>/dev/null || echo none)"
  [[ "$c" != none ]] && printf '  lanes:  started from %s, so its wallet is held back from this job\n' "$c"
  grep -q '^fa dispatch' "$dir/cmd" 2>/dev/null && echo "  tasks:  fa status"
  echo "--- last 20 lines of the log ---"
  tail -n 20 "$dir/log" 2>/dev/null || true
}

jobs_clean() { # drop finished and dead jobs; a running one is never touched
  local d p n=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case "$(job_state "$d")" in
      done|failed|died)
        # Its herdr tabs too - fa opened them, so fa may close them. Never any other.
        # Closing a tab's only pane closes the tab.
        for p in "$d/herdr_pane" "$d"/tasks/*/herdr_pane; do
          [[ -s "$p" ]] && herdr_on && hcall pane close "$(cat "$p")" >/dev/null
        done
        rm -rf "$d"; n=$((n+1)) ;;
    esac
  done <<<"$(jobs_all)"
  echo "[fa] removed ${n} finished job(s)"
}

# What the coordinator runs at the start of every reply in director mode
# (prompts/coordinator.md): each job that ended since the last --news, exactly
# once, then what is still running - and NOTHING when there is nothing to say,
# so checking every turn costs no attention. A turn-by-turn habit only works if
# it is quiet when nothing happened.
jobs_news() {
  local d running="" n=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case "$(job_state "$d")" in
      done|failed|died)
        [[ -f "$d/seen" ]] && continue
        : > "$d/seen"; n=$((n+1))
        printf 'ended: %s %s after %s - %s\n' "$(basename "$d")" "$(job_label "$d")" \
          "$(job_elapsed "$d")" "$(cat "$d/cmd" 2>/dev/null)"
        printf '       review it: fa jobs %s (its log), %sthe diff and the tests\n' "$(basename "$d")" \
          "$(grep -q '^fa dispatch' "$d/cmd" 2>/dev/null && echo 'fa status (its tasks), ')" ;;
      running|starting)
        running+="${running:+, }$(basename "$d") ($(job_elapsed "$d"))" ;;
    esac
  done <<<"$(jobs_all)"
  [[ -n "$running" ]] && printf 'running: %s\n' "$running"
  return 0
}

jobs_summary() { # for fa status: running jobs, then the last few that ended
  local dirs d running="" ended=""
  dirs="$(jobs_all)"
  [[ -n "$dirs" ]] || return 0
  while IFS= read -r d; do
    case "$(job_state "$d")" in
      running|starting) running+="$(job_line "$d")"$'\n' ;;
      *)                ended+="$(job_line "$d")"$'\n' ;;
    esac
  done <<<"$dirs"
  echo
  echo "background jobs (fa jobs for all of them)"
  printf '%s' "$running"
  printf '%s' "$ended" | tail -n 3
}

job_started_msg() { # $1=job id
  local dir; dir="$(jobs_dir)/$1"
  echo "[fa] job $1 started in the background: $(cat "$dir/cmd")"
  echo "[fa]   follow it:  fa jobs $1        log: $dir/log"
  [[ -s "$dir/herdr_tab" ]] && echo "[fa]   watching it in herdr tab $(cat "$dir/herdr_tab") - it says in the sidebar when it ends"
  return 0
}

# One task's lines from a dispatch's log, without the prefix that names the task
# (live_line, common.sh). What a task's herdr tab shows.
job_task_lines() { # $1=task id; stdin = the log
  local prefix="  [$1] " line
  while IFS= read -r line; do
    [[ "$line" == "$prefix"* ]] && printf '  %s\n' "${line#"$prefix"}"
  done
  return 0
}

# $1=job id [$2=task id, for only its lines]: stream the log until the job ends, then
# say how it ended
job_follow() {
  local dir; dir="$(jobs_dir)/$1"
  [[ -d "$dir" ]] || { echo "fa jobs: no job '$1' here - see: fa jobs" >&2; return 3; }
  printf '[fa] job %s%s: %s\n\n' "$1" "${2:+, task $2}" "$(cat "$dir/cmd" 2>/dev/null)"
  local pid="" i view=(cat)
  [[ -z "${2:-}" ]] || view=(job_task_lines "$2")
  # The runner records its pid on its first line; a viewer can start first.
  for ((i = 0; i < 50; i++)); do
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    [[ -n "$pid" || -f "$dir/rc" ]] && break
    sleep 0.1
  done
  if [[ -n "$pid" && ! -f "$dir/rc" ]]; then
    { tail -n +1 -f --pid="$pid" "$dir/log" 2>/dev/null || cat "$dir/log"; } | "${view[@]}"
  else
    "${view[@]}" < "$dir/log" 2>/dev/null
  fi
  # rc is written just before the runner exits; give the file a moment.
  for ((i = 0; i < 20; i++)); do [[ -f "$dir/rc" ]] && break; sleep 0.1; done
  printf '\n[fa] job %s: %s after %s\n' "$1" "$(job_label "$dir")" "$(job_elapsed "$dir")"
}
