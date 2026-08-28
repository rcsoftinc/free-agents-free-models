#!/usr/bin/env bash
set -euo pipefail

# plan.sh - turn a goal into a task graph that bin/orch.sh can run.
#
# This is B2 fixed. The old planner (legacy/orchestrator.sh:generate_plan) called
# ONE model, ONCE, with stderr discarded: a single rate limit produced invalid
# JSON and killed the whole run. The one call that most needs a fallback chain was
# the only one without one.
#
# Here planning goes through bin/run.sh like everything else, so it inherits the
# chain, the bucket leasing and the breaker for free. It is also VALIDATED: a plan
# that is not usable JSON is a failed attempt, not a corrupt run - so a model that
# free-associates instead of answering costs one attempt and the chain moves on.
#
#   usage:
#     plan.sh "goal"  [-w DIR] [-o tasks.json] [--max-tries N] [--print]
#
# Exit: 0 wrote a valid plan | 2 no model produced one | 3 setup error

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG=plan
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

WORKDIR="$(pwd)"
OUT=""
MAX_TRIES="${PLAN_MAX_TRIES:-4}"
PRINT=0
GOAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workdir) WORKDIR="$2"; shift 2 ;;
    -o|--out)     OUT="$2"; shift 2 ;;
    --max-tries)  MAX_TRIES="$2"; shift 2 ;;
    --print)      PRINT=1; shift ;;
    -h|--help)    sed -n '6,20p' "$0"; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            GOAL="$1"; shift ;;
  esac
done
[[ -n "$GOAL" ]] || die "no goal given"
[[ -d "$WORKDIR" ]] || die "workdir does not exist: $WORKDIR"
OUT="${OUT:-${WORKDIR}/.orch/tasks.json}"

# A short, factual survey. Deliberately small: the planner needs the shape of the
# project, not its contents, and a huge listing crowds out the instructions on the
# small-context models this runs on.
survey() {
  printf 'Directory: %s\n' "$WORKDIR"
  printf 'Files (up to 60):\n'
  ( cd "$WORKDIR" && find . -maxdepth 3 \
      \( -name .git -o -name node_modules -o -name .orch -o -name __pycache__ \) -prune -o \
      -type f -print 2>/dev/null | sed 's|^\./||' | head -60 )
  local readme
  readme="$(cd "$WORKDIR" && ls README* 2>/dev/null | head -1)"
  if [[ -n "$readme" ]]; then
    printf '\n--- %s (first 25 lines) ---\n' "$readme"
    head -25 "${WORKDIR}/${readme}"
  fi
}

prompt_for() {
  cat <<EOF
Produce a task plan as JSON. Output JSON ONLY - no prose, no markdown fences.

GOAL: ${GOAL}

PROJECT:
$(survey)

Required shape:
{"tasks":[{"id":"short-slug","prompt":"self-contained instruction","deps":[],"files":["path"],"category":"coding"}]}

Rules:
- Each task's "prompt" must be self-contained: a worker executes it with NO other
  context - not this goal, not the project listing, not another task's output.
- "files" lists every file the task creates or edits. Tasks that run at the same
  time MUST NOT share a file. Get this right; it is enforced.
- "deps" names task ids that must finish first. Use it only for real dependencies.
- Prefer 2-6 tasks. Split by file boundary, never by phase-of-thought.
- "category" is one of: coding, reasoning, research, general, fast.
EOF
}

# Extract the first balanced JSON object, tolerating prose or fences around it.
# Small free models routinely wrap valid JSON in commentary; discarding an
# otherwise-correct plan over that would waste a lane for no reason.
extract_json() {
  sed -e 's/^```json[[:space:]]*//' -e 's/^```[[:space:]]*//' \
  | awk 'BEGIN{d=0;s=0} {
      for(i=1;i<=length($0);i++){c=substr($0,i,1)
        if(c=="{"){if(d==0)s=1;d++}
        if(s)printf "%s",c
        if(c=="}"){d--;if(d==0&&s){print "";exit}}}
      if(s)print ""}'
}

valid_plan() { # $1=file
  jq -e '
    (.tasks | type == "array") and (.tasks | length > 0)
    and all(.tasks[]; (.id | type == "string" and length > 0)
                  and (.prompt | type == "string" and length > 0))
  ' "$1" >/dev/null 2>&1
}

# Cross-task check the model cannot be trusted to do: concurrent tasks must not
# share a file. Two tasks with no dependency between them may run together.
check_boundaries() { # $1=file -> prints offending pairs
  jq -r '
    [.tasks[] | {id, files:(.files//[]), deps:(.deps//[])}] as $t
    | [ $t[] as $a | $t[] as $b
        | select($a.id < $b.id)
        | select(($a.deps | index($b.id)) == null and ($b.deps | index($a.id)) == null)
        | select((($a.files // []) - (($a.files // []) - ($b.files // []))) | length > 0)
        | "\($a.id) and \($b.id) both touch: \((($a.files//[]) - (($a.files//[]) - ($b.files//[]))) | join(", "))" ]
    | .[]' "$1" 2>/dev/null
}

mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp)"; trap 'rm -f "$tmp" "${tmp}.json"' EXIT
prompt_for > "$tmp"

try=0
while [[ $try -lt $MAX_TRIES ]]; do
  try=$((try+1))
  log "planning attempt ${try}/${MAX_TRIES}"
  set +e
  "${HERE}/run.sh" -c reasoning -w "$WORKDIR" - < "$tmp" > "${tmp}.raw" 2>"${tmp}.err"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "  dispatch failed (rc=$rc) - the chain has already moved on"
    [[ $rc -eq 4 ]] && exit 4          # network down: stop, do not burn tries
    continue
  fi

  extract_json < "${tmp}.raw" > "${tmp}.json"
  if ! valid_plan "${tmp}.json"; then
    # A malformed plan is THIS MODEL's failure, not the wallet's. run.sh already
    # recorded the call as ok, so we simply try again and land on another model.
    log "  model returned no usable plan - retrying on the next candidate"
    continue
  fi

  local_conflicts="$(check_boundaries "${tmp}.json")"
  if [[ -n "$local_conflicts" ]]; then
    log "  plan violates file boundaries - rejecting:"
    printf '    %s\n' $local_conflicts >&2
    continue
  fi

  jq '.' "${tmp}.json" > "$OUT"
  log "wrote $OUT ($(jq '.tasks | length' "$OUT") tasks) via $(sed -n 's/^---RUN-META--- //p' "${tmp}.err" | tail -1 | jq -r '.bucket // "?"')"
  [[ $PRINT -eq 1 ]] && jq '.' "$OUT"
  exit 0
done

log "no model produced a usable plan in ${MAX_TRIES} attempt(s)"
exit 2
