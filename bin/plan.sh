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
#     plan.sh "goal"  [-w DIR] [-o tasks.json] [--max-tries N] [--print] [--graph]
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
GRAPH=0
GOAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workdir) WORKDIR="$2"; shift 2 ;;
    -o|--out)     OUT="$2"; shift 2 ;;
    --max-tries)  MAX_TRIES="$2"; shift 2 ;;
    --print)      PRINT=1; shift ;;
    --graph)      GRAPH=1; shift ;;
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
{"tasks":[{"id":"short-slug","prompt":"self-contained instruction","deps":[],"files":["path"],"category":"coding","complexity":"standard"}]}

Rules:
- Each task's "prompt" must be self-contained: a worker executes it with NO other
  context - not this goal, not the project listing, not another task's output.
- "files" lists every file the task creates or edits. Tasks that run at the same
  time MUST NOT share a file. Get this right; it is enforced.
- "deps" names task ids that must finish first. Use it only for real dependencies.
- Prefer 2-6 tasks. Split by file boundary, never by phase-of-thought.
- "category" is one of: coding (default), reasoning, research, general, fast.
  - coding: produces code changes
  - research: produces an investigation report (write to docs/ or .orch/reports/)
- "complexity" is one of: trivial, standard (default), substantial.
  - trivial: a one-line fix, a rename, a config tweak - writing the spec costs
    about as much as just doing it
  - standard: a typical, self-contained feature or fix
  - substantial: real design or interface work, touching multiple files, with
    decisions a later task might need to know about
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
  # An EMPTY file must fail here. `jq -e` produces no output on empty input and
  # exits 0, so without this guard a model that returned pure prose was accepted
  # and an empty tasks.json was written as a "successful" plan - which then fails
  # downstream in orch.sh, far from the cause.
  [[ -s "$1" ]] || return 1
  jq -e '
    (.tasks | type == "array") and (.tasks | length > 0)
    and all(.tasks[]; . as $t |
                  (.id | type == "string" and length > 0)
                  and (.prompt | type == "string" and length > 0)
                  and ((.category // "coding") | test("^(coding|reasoning|research|general|fast)$"))
                  and ((.complexity // "standard") | test("^(trivial|standard|substantial)$"))
                  # "when" is optional; if present its dep/path must be
                  # non-empty strings and equals must at least be present
                  # (any type). Piping has("when") through `not` clobbers
                  # `.` with a bare boolean, so the object is captured in
                  # $t first and every when.* reference below goes through
                  # $t explicitly rather than relying on `.` - confirmed by
                  # hand-testing the naive version directly: it does not
                  # silently misjudge a when clause, it makes jq itself
                  # error (index-on-boolean) for EVERY task carrying a
                  # "when" field, valid or not - which the 2>&1 discard
                  # around this whole jq call would have made
                  # indistinguishable from an ordinary "model returned no
                  # usable plan" retry.
                  and ((($t|has("when")) | not)
                       or (($t.when.dep  | type == "string" and length > 0)
                       and ($t.when.path | type == "string" and length > 0)
                       and ($t.when | has("equals")))))
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

task_deps_of() { jq -r --arg id "$1" '.tasks[] | select(.id==$id) | (.deps // [])[]' "$2"; }

# Cross-task checks graph.sh's BFS layering (and orch.sh's own scheduling
# loop) cannot survive: a "deps" entry naming a task id that does not exist,
# or a dependency cycle. Both are exactly the "the graph could not progress"
# failure orch.sh's own deadlock detector reports at RUN time - catching
# them here costs zero lane requests instead of a wasted dispatch. A cycle
# specifically sends graph.sh's depth-BFS into an ACTUAL infinite loop
# whenever it is reachable from a root (each pass around the cycle strictly
# increases a node's computed depth, unbounded) - confirmed by hand before
# writing this check, not assumed from the code alone.
check_graph_integrity() { # $1=file -> prints one problem per line, or nothing
  local file="$1" ids dupes id d dangling=0
  ids="$(jq -r '.tasks[].id' "$file")"

  dupes="$(printf '%s\n' "$ids" | sort | uniq -d)"
  [[ -n "$dupes" ]] && printf 'duplicate task id: %s\n' $dupes

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      if ! grep -qxF "$d" <<<"$ids"; then
        printf '%s depends on unknown task id: %s\n' "$id" "$d"
        dangling=1
      fi
    done < <(task_deps_of "$id" "$file")
  done <<<"$ids"

  # Same check for "when.dep" - a conditional edge naming a task that does
  # not exist would otherwise wait forever: deps_met() never sees it as a
  # real dependency (when is evaluated separately, after deps_met), so
  # nothing would ever detect this at run time the way a dangling "deps"
  # entry is at least caught by the cycle/deadlock machinery.
  while IFS=$'\t' read -r id d; do
    [[ -z "$id" || -z "$d" ]] && continue
    if ! grep -qxF "$d" <<<"$ids"; then
      printf '%s has a "when" clause depending on unknown task id: %s\n' "$id" "$d"
      dangling=1
    fi
  done < <(jq -r '.tasks[] | select(.when.dep) | [.id, .when.dep] | @tsv' "$file" 2>/dev/null)

  # when.dep MUST also be listed in the task's own "deps" - orch.sh's
  # deps_met() is what makes a task wait for its dependency to actually
  # finish before when_satisfied() ever reads its result; a when clause
  # with no matching deps entry would let the task become eligible
  # immediately, reading a result file that may not exist yet (or may
  # never exist, if the dependency has not even been dispatched).
  while IFS=$'\t' read -r id d; do
    [[ -z "$id" || -z "$d" ]] && continue
    printf '%s has a "when" clause on %s but does not list it in "deps" too\n' "$id" "$d"
  done < <(jq -r '.tasks[] | . as $t | select($t.when.dep)
                  | select((($t.deps // []) | index($t.when.dep)) == null)
                  | [$t.id, $t.when.dep] | @tsv' "$file" 2>/dev/null)

  # A cycle check only means something once every dep reference is known to
  # exist - a dangling reference (already reported above) would otherwise
  # look identical to a cycle here, since its target is never "resolved"
  # either.
  [[ $dangling -eq 1 ]] && return 0

  # Kahn's algorithm: repeatedly remove tasks whose deps are all already
  # removed. Whatever is left once no more progress can be made is a cycle.
  local removed="" progress=1 unresolved
  while [[ $progress -eq 1 ]]; do
    progress=0
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      grep -qxF "$id" <<<"$removed" && continue
      unresolved=0
      while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        grep -qxF "$d" <<<"$removed" && continue
        unresolved=1; break
      done < <(task_deps_of "$id" "$file")
      [[ $unresolved -eq 0 ]] && { removed+="${id}"$'\n'; progress=1; }
    done <<<"$ids"
  done
  local stuck; stuck="$(comm -23 <(printf '%s\n' "$ids" | sort -u) <(printf '%s\n' "$removed" | sort -u))"
  [[ -n "$stuck" ]] && printf 'dependency cycle among: %s\n' "$(tr '\n' ' ' <<<"$stuck")"
  # Callers capture this function's OUTPUT (empty = clean) via a plain
  # assignment, e.g. `defects="$(check_graph_integrity ...)"` - under
  # set -euo pipefail that checks the ASSIGNMENT's exit status, which is
  # this function's last command. Without an explicit, unconditional
  # `return 0` here, the clean/no-defects case (the [[ -n ]] test above
  # being false) would make the function return 1 and abort the whole
  # script on every well-formed plan - the exact class of bug already fixed
  # twice elsewhere in this project (run.sh's --validate gate, orch.sh's
  # orphan_alive_pid).
  return 0
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

  graph_defects="$(check_graph_integrity "${tmp}.json")"
  if [[ -n "$graph_defects" ]]; then
    log "  plan graph is malformed - rejecting:"
    printf '    %s\n' "$graph_defects" >&2
    continue
  fi

  jq '.' "${tmp}.json" > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"
  log "wrote $OUT ($(jq '.tasks | length' "$OUT") tasks) via $(sed -n 's/^---RUN-META--- //p' "${tmp}.err" | tail -1 | jq -r '.bucket // "?"')"
  [[ $PRINT -eq 1 ]] && jq '.' "$OUT"
  [[ $GRAPH -eq 1 ]] && bash "${HERE}/lib/graph.sh" "$OUT"
  exit 0
done

log "no model produced a usable plan in ${MAX_TRIES} attempt(s)"
exit 2
