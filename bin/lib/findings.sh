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
            assigned: (.[0].assigned // null),
            # Set on every entry sharing this fp by _mark_filed once --post
            # actually files it - read across all of them (not just [0]) so a
            # NEW occurrence of an already-filed fp does not look unfiled.
            filed: ([.[].filed] | any),
            filed_issue_url: ([.[].filed_issue_url] | map(select(. != null)) | first // null) })
    | sort_by(-.count)' "$FINDINGS" 2>/dev/null
}

# Always a number. An empty store produced empty output, so anything comparing
# `fa findings --count` against 0 saw a blank instead of a zero.
findings_count() {
  local g n
  g="$(_grouped "${1:-all}")"
  [[ -z "$g" ]] && { echo 0; return 0; }
  n="$(jq -r 'length' <<<"$g" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}

findings_show() {
  local g; g="$(_grouped "${1:-all}")"
  [[ -z "$g" || "$g" == "[]" ]] && { echo "No findings. The tool has not noticed anything it handled badly."; return 0; }
  jq -r '.[] | "\(.count)x  \(.kind)\n    \(.summary)\n    evidence: \(.evidence[0:150])\n" +
         (if .model then "    model: \(.model)  provider: \(.provider // "?")\n" else "" end) +
         (if .assigned then "    classified as: \(.assigned)\n" else "" end) +
         "    first \(.first)  last \(.last)\n"' <<<"$g"
}

# One place that turns a grouped finding into an issue TITLE + BODY, so the
# text a human reviews (findings_issue, and the --post confirmation prompt)
# can never drift from the text that actually gets filed (--post reads the
# exact same rows) - the same "one writer per artifact" rule this project has
# already been bitten by twice elsewhere (a stale coordinator playbook, a
# duplicated .gitignore).
_finding_rows() { # $1 = "new"|"all" -> one JSON object per line: {fp,title,body,filed,filed_issue_url}
  local g; g="$(_grouped "${1:-all}")"
  [[ -z "$g" || "$g" == "[]" ]] && return 0
  jq -c '.[] |
    { fp: .fp, filed: .filed, filed_issue_url: .filed_issue_url,
      title: ("\(.kind): \(.summary)" | if (length > 120) then .[0:117] + "..." else . end),
      body: (
        "Seen **\(.count)x** (first \(.first), last \(.last)).\n\n" +
        "```\n\(.evidence)\n```\n\n" +
        (if .kind == "all_lanes_failed" then
           "Every healthy lane failed on this same task, so the credentials are not\n" +
           "the suspect - the task is. Usually a spec too large or too vague for a\n" +
           "free model. Check the prompt above against what a worker actually needs:\n" +
           "a self-contained instruction, not inherited context.\n\n"
         elif .kind == "missing_handoff" then
           "This task had dependents and did not end with the handoff line, so those\n" +
           "tasks ran without knowing what it decided. Nothing failed; the work just\n" +
           "got quietly worse. Consider whether the handoff request is reaching the\n" +
           "worker at all, or whether the model is dropping it.\n\n"
         elif .kind == "note" then
           "Recorded by hand - the tool could not have detected this one.\n\n"
         else "" end) +
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
        "\n---\n*fp=`\(.fp)` - from a local `fa findings` run.*\n"
      ) }' <<<"$g"
}

# A finding is only useful if acting on it is easy, so this emits the whole issue.
findings_issue() {
  local rows; rows="$(_finding_rows "${1:-all}")"
  [[ -z "$rows" ]] && { echo "No findings to report."; return 0; }
  jq -r '"## " + .title + "\n\n" + .body +
         (if .filed then "*(already filed: \(.filed_issue_url))*\n\n" else "" end)' <<<"$rows"
}

# Where this clone's own origin points - the repo --post files issues against,
# regardless of which project's directory `fa` happens to be run from (a
# finding is about THIS TOOL, never about the user's own project). A fork that
# repoints its own origin remote files against itself, not upstream, for free.
FINDINGS_REPO_SLUG="${FINDINGS_REPO_SLUG:-}"  # test hook / override; empty = auto-resolve

_findings_tool_root() {
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${here}/../.." && pwd
}

_findings_repo_slug() { # -> "owner/repo" on stdout, or rc=1 if unresolvable
  if [[ -n "$FINDINGS_REPO_SLUG" ]]; then printf '%s' "$FINDINGS_REPO_SLUG"; return 0; fi
  local url
  url="$(git -C "$(_findings_tool_root)" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$url" ]] || return 1
  printf '%s' "$url" | sed -E 's#^git@github\.com:##; s#^https?://github\.com/##; s#\.git$##'
}

# Mark every stored entry sharing $fp as filed, so a later --post never opens
# a second issue for the same fingerprint - same locked read-modify-write
# shape as findings_ack, just scoped to one fp instead of every row.
_mark_filed() { # $1=fp $2=issue_url
  local fp="$1" issue_url="$2"
  [[ -s "$FINDINGS" ]] || return 0
  ( flock -w 10 9 || return 0
    jq -c --arg fp "$fp" --arg u "$issue_url" \
      'if .fp == $fp then .filed = true | .filed_issue_url = $u else . end' \
      "$FINDINGS" > "${FINDINGS}.tmp" && mv "${FINDINGS}.tmp" "$FINDINGS"
  ) 9>"${FINDINGS}.lock"
}

# The one place this tool ever actually posts to GitHub on its own initiative -
# and even here, only after listing every issue it is about to open and
# getting one explicit yes. Never called except from `fa findings --issue
# --post`; nothing in discover/probe/run/orch can reach it.
findings_post() { # $1 = "new"|"all"
  have gh || { log "gh (GitHub CLI) is required for --post - install it, or use --issue alone and file by hand"; return 3; }
  local repo; repo="$(_findings_repo_slug)" || {
    log "cannot resolve this tool's own GitHub repo (no origin remote under $(_findings_tool_root))"
    return 3
  }

  local rows; rows="$(_finding_rows "${1:-all}")"
  [[ -z "$rows" ]] && { echo "No findings to report."; return 0; }

  local already todo
  already="$(jq -c 'select(.filed)' <<<"$rows")"
  todo="$(jq -c 'select(.filed | not)' <<<"$rows")"

  if [[ -n "$already" ]]; then
    echo "already filed, skipping:"
    jq -r '"  " + .title + "  -> " + .filed_issue_url' <<<"$already"
  fi
  if [[ -z "$todo" ]]; then
    echo "nothing new to file."
    return 0
  fi

  echo "about to file $(jq -sc 'length' <<<"$todo") new issue(s) on ${repo}:"
  jq -r '"  - " + .title' <<<"$todo"
  local ans
  read -rp "proceed? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo "cancelled - nothing filed."; return 0; }

  local row fp title body issue_url
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    fp="$(jq -r '.fp' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    body="$(jq -r '.body' <<<"$row")"
    if issue_url="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>&1)"; then
      echo "filed: $issue_url"
      _mark_filed "$fp" "$issue_url"
    else
      echo "FAILED to file '${title}': ${issue_url}"
    fi
  done <<<"$todo"
}

# CLI-facing: `fa findings --issue [--post] [new|all]`. Parsing lives here,
# not split with bin/fa's own case arm, so it is tested once.
findings_issue_cmd() {
  local post=0 scope="all" a
  for a in "$@"; do
    case "$a" in
      --post) post=1 ;;
      *) scope="$a" ;;
    esac
  done
  if [[ $post -eq 1 ]]; then findings_post "$scope"; else findings_issue "$scope"; fi
}

findings_ack() {
  [[ -s "$FINDINGS" ]] || return 0
  ( flock -w 10 9 || return 0
    jq -c '.acked = true' "$FINDINGS" > "${FINDINGS}.tmp" && mv "${FINDINGS}.tmp" "$FINDINGS"
  ) 9>"${FINDINGS}.lock"
}
