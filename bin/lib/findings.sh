# findings.sh - things the tool noticed it handled badly.
#
# A finding is not an error. Errors are handled: a rate limit cools a wallet, a
# hang parks a model. A FINDING is the tool admitting it did not know what
# something was, or that it did the same unhelpful thing repeatedly. It is the
# feedback path from a real project back to the tool.
#
# Every classification bug found in this project so far was invisible for the
# same reason: the taxonomy has a silent default, and the text that reached it
# was discarded. This keeps the text.
#
# Source, do not execute. Requires lib/common.sh (STATE_DIR, iso_now).

FINDINGS="${FINDINGS:-${STATE_DIR}/findings.ndjson}"
FINDING_MAX_CHARS="${FINDING_MAX_CHARS:-400}"

# Provider output can echo back fragments of a prompt, and a misconfigured agent
# can echo a key. Nothing reaches the store unredacted, because a finding is
# meant to be pasteable into a public issue.
redact() {
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{4})[A-Za-z0-9_-]+/\1…REDACTED/g' \
    -e 's/(sk-or-v1-[A-Za-z0-9]{4})[A-Za-z0-9]+/\1…REDACTED/g' \
    -e 's/(fe_oa_[A-Za-z0-9]{4})[A-Za-z0-9]+/\1…REDACTED/g' \
    -e 's/(nvapi-[A-Za-z0-9]{4})[A-Za-z0-9_-]+/\1…REDACTED/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}/…JWT-REDACTED/g' \
    -e 's/(Bearer )[A-Za-z0-9._-]+/\1…REDACTED/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/…EMAIL/g'
}

# Collapse to a comparable shape so the same failure seen twenty times is one
# finding with a count, not twenty rows.
_fingerprint() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[0-9a-f]{8,}/HEX/g; s/[0-9]+/N/g; s/[[:space:]]+/ /g' \
    | cut -c1-160 | sha256sum | cut -c1-12
}

# record_finding <kind> <summary> <evidence> [k=v ...]
record_finding() {
  local kind="$1" summary="$2" evidence="$3"; shift 3
  local ev fp extra="{}" kv k v
  ev="$(printf '%s' "$evidence" | redact | tr '\n' ' ' | cut -c1-"$FINDING_MAX_CHARS")"
  fp="$(_fingerprint "${kind}:${ev}")"
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"
    extra="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$extra")"; done
  mkdir -p "$(dirname "$FINDINGS")"
  ( flock -w 10 9 || return 0
    jq -cn --arg fp "$fp" --arg k "$kind" --arg s "$summary" --arg e "$ev" \
           --arg t "$(iso_now)" --argjson x "$extra" \
      '{fp:$fp, kind:$k, summary:$s, evidence:$e, at:$t, acked:false} + $x' >> "$FINDINGS"
  ) 9>"${FINDINGS}.lock"
}

# Grouped by fingerprint, newest first, with a count.
_grouped() { # $1 = "new" to show only unacknowledged
  [[ -s "$FINDINGS" ]] || return 0
  jq -s --arg only "${1:-all}" '
    map(select($only != "new" or (.acked | not)))
    | group_by(.fp)
    | map({ fp: .[0].fp, kind: .[0].kind, summary: .[0].summary,
            evidence: .[0].evidence, count: length,
            first: (map(.at) | min), last: (map(.at) | max),
            model: (.[0].model // null), provider: (.[0].provider // null),
            assigned: (.[0].assigned // null) })
    | sort_by(-.count)' "$FINDINGS" 2>/dev/null
}

findings_count() { _grouped "${1:-all}" | jq -r 'length // 0' 2>/dev/null || echo 0; }

findings_show() {
  local g; g="$(_grouped "${1:-all}")"
  [[ -z "$g" || "$g" == "[]" ]] && { echo "No findings. The tool has not noticed anything it handled badly."; return 0; }
  jq -r '.[] | "\(.count)x  \(.kind)\n    \(.summary)\n    evidence: \(.evidence[0:150])\n" +
         (if .model then "    model: \(.model)  provider: \(.provider // "?")\n" else "" end) +
         (if .assigned then "    classified as: \(.assigned)\n" else "" end) +
         "    first \(.first)  last \(.last)\n"' <<<"$g"
}

# A finding is only useful if acting on it is easy, so this emits the whole issue.
findings_issue() {
  local g; g="$(_grouped "${1:-all}")"
  [[ -z "$g" || "$g" == "[]" ]] && { echo "No findings to report."; return 0; }
  jq -r '.[] |
    "## \(.kind): \(.summary)\n\n" +
    "Seen **\(.count)x** (first \(.first), last \(.last)).\n\n" +
    "```\n\(.evidence)\n```\n\n" +
    (if .assigned then
       "Classified as `\(.assigned)`" +
       (if .kind == "unclassified" then
          " — but nothing in the taxonomy matched, so this is the silent default.\n\n" +
          "**Suggested test case** for `bin/lib/classify.sh --self-test`:\n\n" +
          "```bash\n  _ct 1 \"\(.evidence[0:60])\" <expected_state>\n```\n\n" +
          "Pick the state from: rate_limited (wallet fault) · no_credits (wallet) ·\n" +
          "auth_error (wallet) · dead (model) · timeout (model) · provider_error\n" +
          "(model, transient) · local_network (recorded nowhere).\n"
        else ".\n" end)
     else "" end) +
    (if .model then "\nModel: `\(.model)`  Provider: `\(.provider // "?")`\n" else "" end) +
    "\n---\n"' <<<"$g"
}

findings_ack() {
  [[ -s "$FINDINGS" ]] || return 0
  ( flock -w 10 9 || return 0
    jq -c '.acked = true' "$FINDINGS" > "${FINDINGS}.tmp" && mv "${FINDINGS}.tmp" "$FINDINGS"
  ) 9>"${FINDINGS}.lock"
}
