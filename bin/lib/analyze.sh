#!/usr/bin/env bash
# analyze.sh - read the journal after a run and surface patterns.
#
# Headroom reads past sessions, finds failed tool calls, correlates with what
# succeeded, and writes learnings. Our equivalent: the journal is the record of
# what happened on this machine, and a run that leaves it without comment is a
# run whose observations died with the session.
#
# This is NOT a summariser. It does not re-read agent output or call a model. It
# reads the same NDJSON the scheduler already wrote and looks for shapes that
# the scheduler's own findings (unverified_repeat, missing_handoff, deadlock)
# do not cover — because those fire at the moment of failure, and a pattern
# spread across five tasks is visible only in aggregate.
#
# Source, do not execute. Requires lib/common.sh and lib/findings.sh.
# Sets defaults for ORCH_DIR/JOURNAL if not already set (orch.sh sets them).

# If orch.sh already set these (end-of-run analysis), keep its values.
# If called standalone via `fa analyze`, derive from project dir.
if [[ -z "${ORCH_DIR:-}" ]]; then
  ORCH_DIR="$(pwd)/.orch"
  JOURNAL="${ORCH_DIR}/journal.ndjson"
fi

# --------------------------------------------------------------- patterns --

# A task that failed on every lane that tried it: the credentials are not the
# suspect, the task is. The scheduler records each attempt_failed separately;
# this correlates them.
_analyze_all_lanes_failed() {
  [[ -f "$JOURNAL" ]] || return 0
  # Tasks that have attempt_failed events but never a done event.
  local -A failed_on=() tried_on=()
  local task event bucket
  while IFS= read -r line; do
    task="$(jq -r '.task' <<<"$line" 2>/dev/null)"
    event="$(jq -r '.event' <<<"$line" 2>/dev/null)"
    bucket="$(jq -r '.bucket // "?"' <<<"$line" 2>/dev/null)"
    [[ -z "$task" || "$task" == "null" ]] && continue
    case "$event" in
      attempt_failed|unverified)
        failed_on["$task"]="${failed_on[$task]:-} $bucket"
        tried_on["$task"]="${tried_on[$task]:-} $bucket"
        ;;
      started)
        tried_on["$task"]="${tried_on[$task]:-} $bucket"
        ;;
    esac
  done < "$JOURNAL"

  for task in "${!tried_on[@]}"; do
    # Never succeeded?
    jq -e --arg t "$task" 'select(.event=="done" and .task==$t)' "$JOURNAL" >/dev/null 2>&1 && continue
    # Failed on more than one distinct bucket?
    local buckets; buckets="$(echo "${failed_on[$task]:-}" | tr ' ' '\n' | sort -u | grep -c . || true)"
    if [[ "${buckets:-0}" -gt 1 ]]; then
      record_finding all_lanes_failed \
        "task failed on ${buckets} distinct lanes — the task is the suspect, not the wallets" \
        "task=${task} lanes=$(echo "${failed_on[$task]}" | tr ' ' '\n' | sort -u | tr '\n' ',')" \
        "task=${task}"
    fi
  done
}

# A task that was retried many times across different lanes: either the spec is
# too large for a free model, or the task is not actually self-contained.
_analyze_repeated_retries() {
  [[ -f "$JOURNAL" ]] || return 0
  local task n
  while IFS= read -r task; do
    [[ -z "$task" ]] && continue
    n="$(jq -r --arg t "$task" 'select(.task==$t and (.event=="attempt_failed" or .event=="unverified")) | .task' "$JOURNAL" 2>/dev/null | grep -c . || true)"
    if [[ "${n:-0}" -ge 3 ]]; then
      record_finding repeated_retries \
        "task failed ${n} times — spec may be too large or not self-contained" \
        "task=${task} failures=${n}" \
        "task=${task}"
    fi
  done < <(jq -r 'select(.event=="attempt_failed" or .event=="unverified") | .task' "$JOURNAL" 2>/dev/null | sort -u)
}

# One lane did all the work while others sat idle: a scheduling anomaly, or a
# lane that was never healthy when it mattered.
_analyze_lane_imbalance() {
  [[ -f "$JOURNAL" ]] || return 0
  local total done_by_bucket
  total="$(jq -r 'select(.event=="done") | .task' "$JOURNAL" 2>/dev/null | grep -c . || true)"
  [[ "${total:-0}" -lt 3 ]] && return 0  # not enough data
  # Count distinct buckets that completed tasks
  local buckets; buckets="$(jq -r 'select(.event=="done") | .bucket // "?"' "$JOURNAL" 2>/dev/null | sort -u | grep -c . || true)"
  if [[ "${buckets:-0}" -eq 1 ]]; then
    record_finding single_lane_did_all \
      "all ${total} completed tasks ran on a single lane — other lanes were idle or unhealthy" \
      "tasks=${total} lanes_used=1" \
      "tasks=${total}"
  fi
}

# --------------------------------------------------------------- public --

# Run all analyses. Called at the end of cmd_run, or standalone via `fa analyze`.
analyze_journal() {
  [[ -f "$JOURNAL" ]] || { echo "no journal at $JOURNAL"; return 0; }
  _analyze_all_lanes_failed
  _analyze_repeated_retries
  _analyze_lane_imbalance
}

# Write a learnings file that future coordinator sessions can read. This is the
# persistent memory across runs — the journal is per-run, learnings survive.
write_learnings() {
  local out="${ORCH_DIR}/learnings.md"
  local n; n="$(findings_count all 2>/dev/null || echo 0)"
  [[ "${n:-0}" -eq 0 ]] && { echo "no findings — no learnings to write"; return 0; }

  local g; g="$(_grouped all)"

  {
    echo "# Learnings"
    echo
    echo "Auto-generated from run findings. Read this before planning the next run."
    echo
    echo "Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Patterns"
    echo
    # Emit each finding as a bullet from the grouped JSON
    jq -r '.[] | "- [\(.kind)] \(.summary) (seen \(.count)x, \(.evidence[0:120]))"' <<<"$g"
    echo
    echo "## Suggested actions"
    echo
    echo "- Review tasks marked all_lanes_failed: rewrite the spec, not the wallet"
    echo "- Review tasks marked repeated_retries: split or simplify"
    echo "- Review single_lane_did_all: check lane health before next run"
    echo
    echo "To clear: fa findings --ack"
  } > "$out"
  echo "wrote $out"
}
