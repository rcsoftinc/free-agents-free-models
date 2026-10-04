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
  local launch=(nohup); have setsid && launch=(setsid nohup)
  ( FA_COORDINATOR="$coord" "${launch[@]}" "${root}/bin/fa" __job "$dir" "$@" \
      </dev/null >"$dir/log" 2>&1 & )
  printf '%s' "$id"
}

job_run() { # $1=job dir; rest = fa arguments. The detached half of job_start.
  local dir="$1"; shift
  printf '%s\n' "$$" > "$dir/pid"
  # Lets a command tell it is running as a background job: `fa dispatch` then
  # runs the plan whatever the split, since nobody is there to "work directly".
  export FA_JOB; FA_JOB="$(basename "$dir")"
  local rc=0
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fa" "$@" || rc=$?
  now_epoch > "$dir/finished_at"
  printf '%s\n' "$rc" > "$dir/rc.tmp" && mv "$dir/rc.tmp" "$dir/rc"
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

job_line() { # $1=job dir -> one row for a listing
  local dir="$1" st label cmd
  st="$(job_state "$dir")"
  case "$st" in
    failed) label="FAILED rc=$(cat "$dir/rc")" ;;
    died)   label="DIED" ;;
    *)      label="$st" ;;
  esac
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
  local c; c="$(cat "$dir/coordinator" 2>/dev/null || echo none)"
  [[ "$c" != none ]] && printf '  lanes:  started from %s, so its wallet is held back from this job\n' "$c"
  grep -q '^fa dispatch' "$dir/cmd" 2>/dev/null && echo "  tasks:  fa status"
  echo "--- last 20 lines of the log ---"
  tail -n 20 "$dir/log" 2>/dev/null || true
}

jobs_clean() { # drop finished and dead jobs; a running one is never touched
  local d n=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case "$(job_state "$d")" in
      done|failed|died) rm -rf "$d"; n=$((n+1)) ;;
    esac
  done <<<"$(jobs_all)"
  echo "[fa] removed ${n} finished job(s)"
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
}
