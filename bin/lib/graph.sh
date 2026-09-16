#!/usr/bin/env bash
# graph.sh - render a task graph as an ASCII diagram.
#
# Reads a tasks.json (the plan.sh output) and prints an ASCII graph:
#   dependency chains as arrows, parallel tasks side by side,
#   category and file sets per node.
#
# Usage:
#   graph.sh [-w DIR] [tasks.json]         # print the graph
#   graph.sh --validate [-w DIR]           # exit 0 if graph is renderable
#
# Exit: 0 rendered | 1 nothing to render | 2 setup error

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG=graph
# shellcheck source=lib/common.sh
. "${HERE}/common.sh"

WORKDIR="$(pwd)"
TASKS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workdir) WORKDIR="$2"; shift 2 ;;
    --validate)   VALIDATE=1; shift ;;
    -*)           die "unknown option: $1" ;;
    *)            TASKS="$1"; shift ;;
  esac
done

TASKS="${TASKS:-${WORKDIR}/.orch/tasks.json}"
[[ -f "$TASKS" ]] || die "no task graph at $TASKS"

[[ -n "${VALIDATE:-}" ]] && {
  jq -e '.tasks | type == "array" and length > 0' "$TASKS" >/dev/null && exit 0 || exit 1
}

# Extract task ids into an array
mapfile -t IDS < <(jq -r '.tasks[].id' "$TASKS")
[[ ${#IDS[@]} -eq 0 ]] && { echo "no tasks"; exit 1; }

# Build a lookup for deps, files, category
declare -A DEPS=() FILES=() CATEGORY=() BLOCKED=()
for id in "${IDS[@]}"; do
  DEPS[$id]="$(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.deps // [])[]' "$TASKS" | sort -u | tr '\n' ' ')"
  FILES[$id]="$(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.files // [])[]' "$TASKS" | sort -u | tr '\n' ' ')"
  CATEGORY[$id]="$(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.category // "coding")' "$TASKS")"
  BLOCKED[$id]="$(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.blocked // "")' "$TASKS")"
done

# Find root tasks (no deps) and leaf tasks (no dependents)
roots=(); leaves=()
for id in "${IDS[@]}"; do
  [[ -z "${DEPS[$id]}" ]] && roots+=("$id")
  is_leaf=1
  for other in "${IDS[@]}"; do
    [[ "$other" == "$id" ]] && continue
    [[ " ${DEPS[$other]} " == *" $id "* ]] && { is_leaf=0; break; }
  done
  [[ $is_leaf -eq 1 ]] && leaves+=("$id")
done

# BFS layering: assign each task a depth (longest path from any root)
declare -A DEPTH=()
for id in "${IDS[@]}"; do DEPTH[$id]=-1; done

# Start from roots at depth 0
queue=()
for r in "${roots[@]}"; do
  DEPTH[$r]=0
  queue+=("$r")
done

# Process queue
while [[ ${#queue[@]} -gt 0 ]]; do
  current="${queue[0]}"; queue=("${queue[@]:1}")
  for id in "${IDS[@]}"; do
    [[ " ${DEPS[$id]} " == *" $current "* ]] || continue
    new_depth=$(( DEPTH[$current] + 1 ))
    if [[ ${DEPTH[$id]} -lt $new_depth ]]; then
      DEPTH[$id]=$new_depth
      queue+=("$id")
    fi
  done
done

# Group tasks by depth
declare -A LAYERS=()
max_depth=0
for id in "${IDS[@]}"; do
  d=${DEPTH[$id]}
  [[ $d -lt 0 ]] && d=0  # cycle fallback
  LAYERS[$d]="${LAYERS[$d]:-} $id"
  [[ $d -gt $max_depth ]] && max_depth=$d
done

# Category color codes (ANSI)
cat_color() {
  case "$1" in
    coding)     printf '\033[36m' ;;    # cyan
    research)   printf '\033[35m' ;;    # magenta
    reasoning)  printf '\033[33m' ;;    # yellow
    general)    printf '\033[37m' ;;    # white
    fast)       printf '\033[32m' ;;    # green
    *)          printf '\033[37m' ;;
  esac
}
RESET=$(printf '\033[0m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')

# Print the graph
echo
printf '%sTASK GRAPH%s\n' "$BOLD" "$RESET"
printf '%s%s%s\n' "$DIM" "$(printf '─%.0s' {1..50})" "$RESET"
echo

for d in $(seq 0 $max_depth); do
  layer="${LAYERS[$d]}"
  [[ -z "$layer" ]] && continue

  # Print tasks at this depth side by side
  first=1
  for id in $layer; do
    cat="${CATEGORY[$id]}"
    files="${FILES[$id]}"
    blocked="${BLOCKED[$id]}"

    # Node box
    if [[ -n "$blocked" ]]; then
      # Blocked task: dashed border
      printf '%s┌─[ %s ]─%s\n' "$DIM" "$id" "$RESET"
      printf '%s│  %s⏸ blocked%s\n' "$DIM" "$RESET" "$RESET"
      printf '%s│  %s%s%s' "$DIM" "$RESET" "$blocked" "$RESET"
    else
      cat_color "$cat"
      printf '┌─[ '
      printf '%s%s%s' "$BOLD" "$id" "$RESET"
      cat_color "$cat"
      printf ' ]─── %s%s%s\n' "$RESET" "$cat" "$RESET"
      if [[ -n "$files" ]]; then
        printf '│  '
        printf '%s' "$files"
      fi
    fi
    printf '\n'
    printf '%s└─────%s\n' "$DIM" "$RESET"
    echo

    first=0
  done

  # Print arrows to next layer
  if [[ $d -lt $max_depth ]]; then
    next_layer="${LAYERS[$((d+1))]}"
    for id in $layer; do
      for next in $next_layer; do
        [[ " ${DEPS[$next]} " == *" $id "* ]] || continue
        printf '%s    │%s\n' "$DIM" "$RESET"
        printf '%s    ▼%s\n' "$DIM" "$RESET"
      done
    done
    echo
  fi
done

# Summary
printf '%s%s%s\n' "$DIM" "$(printf '─%.0s' {1..50})" "$RESET"
printf '%s%d tasks' "$BOLD" "${#IDS[@]}"
[[ ${#roots[@]} -gt 0 ]] && printf ', %d root(s)' "${#roots[@]}"
[[ ${#leaves[@]} -gt 0 ]] && printf ', %d leaf(s)' "${#leaves[@]}"
echo "$RESET"

# Parallel width: max tasks at any depth
max_width=0
for d in $(seq 0 $max_depth); do
  layer="${LAYERS[$d]}"
  count=0
  for _ in $layer; do count=$((count+1)); done
  [[ $count -gt $max_width ]] && max_width=$count
done
printf '%smax parallel width: %d%s\n' "$BOLD" "$max_width" "$RESET"
echo
