#!/usr/bin/env bash
# Proves `fa findings --issue --post`: the one place this tool ever files a
# GitHub issue on its own initiative, and only after listing exactly what it
# is about to file and getting one explicit human yes. Entirely offline via
# the gh stub (test/stubs/gh) - see its own header for GH_STUB_MODE.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "findings: --post files real issues, carefully"
fixture_registry 3 || exit 1
sandbox_on

FA="$REPO/bin/fa"
export FINDINGS_REPO_SLUG="test-owner/test-repo"
rec() { bash -c '. '"$REPO"'/bin/lib/common.sh; . '"$REPO"'/bin/lib/findings.sh; record_finding "$@"' _ "$@"; }
fresh() { FREE_AGENTS_STATE="$(mktemp -d)"; export FREE_AGENTS_STATE; STUB_LOG_FILE="$(mktemp)"; export STUB_LOG="$STUB_LOG_FILE"; }

# --- 1. nothing to file: says so, never prompts, never calls gh -------------
fresh
out="$(echo n | "$FA" findings --issue --post 2>&1)"
assert_contains "no findings at all: reports it plainly" "$out" "No findings to report."
assert_eq "and gh is never invoked" "$(wc -l < "$STUB_LOG_FILE")" "0"

# --- 2. declining the prompt files nothing ----------------------------------
fresh
rec unclassified "declined-file test" "some unrecognised provider text" model=m1 provider=p1
out="$(echo n | GH_STUB_MODE=success "$FA" findings --issue --post 2>&1)"
assert_contains "lists what it's about to file, before asking" "$out" "about to file 1 new issue(s) on test-owner/test-repo"
assert_contains "names the finding" "$out" "unclassified: declined-file test"
assert_contains "declining is honoured" "$out" "cancelled - nothing filed."
assert_eq "gh issue create is never called on a decline" "$(wc -l < "$STUB_LOG_FILE")" "0"
assert_eq "and nothing is marked filed" \
  "$(jq -s '[.[] | select(.filed == true)] | length' "$FREE_AGENTS_STATE/findings.ndjson")" "0"

# --- 3. the happy path: confirmed, filed, marked so it can't double-file ----
out="$(echo y | GH_STUB_MODE=success "$FA" findings --issue --post 2>&1)"
assert_contains "reports the filed issue's URL" "$out" "filed: https://github.com/stub-owner/stub-repo/issues/"
assert_contains "gh was actually called with a real title" "$(cat "$STUB_LOG_FILE")" "issue create: unclassified: declined-file test"
assert_eq "exactly one issue was filed" "$(wc -l < "$STUB_LOG_FILE")" "1"
assert_eq "the finding is now marked filed" \
  "$(jq -s '[.[] | select(.filed == true)] | length' "$FREE_AGENTS_STATE/findings.ndjson")" "1"
assert_contains "and its issue URL is recorded" \
  "$(jq -sr '[.[] | select(.filed_issue_url != null) | .filed_issue_url][0]' "$FREE_AGENTS_STATE/findings.ndjson")" \
  "github.com/stub-owner/stub-repo/issues/"

# --- 4. a second --post run does not re-file the same fingerprint ----------
out="$(echo y | GH_STUB_MODE=success "$FA" findings --issue --post 2>&1)"
assert_contains "the already-filed finding is named, not silently dropped" "$out" "already filed, skipping:"
assert_contains "nothing new to file" "$out" "nothing new to file."
assert_eq "gh issue create was NOT called again" "$(wc -l < "$STUB_LOG_FILE")" "1"

# --- 5. a NEW finding alongside an already-filed one: only the new one goes -
rec all_lanes_failed "second finding" "every lane failed on this task" attempts=3
out="$(echo y | GH_STUB_MODE=success "$FA" findings --issue --post 2>&1)"
assert_contains "the old one is still reported as already filed" "$out" "already filed, skipping:"
assert_contains "only the new finding is listed to file" "$out" "about to file 1 new issue(s)"
assert_eq "gh issue create was called exactly once more" "$(wc -l < "$STUB_LOG_FILE")" "2"
assert_eq "both findings are now marked filed" \
  "$(jq -s '[.[] | select(.filed == true)] | group_by(.fp) | length' "$FREE_AGENTS_STATE/findings.ndjson")" "2"

# --- 6. gh failing to create an issue is reported, and NOT marked filed ----
fresh
rec unclassified "gh-failure test" "provider said something odd" model=m2
out="$(echo y | GH_STUB_MODE=fail "$FA" findings --issue --post 2>&1)"
assert_contains "a gh failure is surfaced, not swallowed" "$out" "FAILED to file"
assert_eq "and the finding is NOT marked filed, so a retry can pick it up" \
  "$(jq -s '[.[] | select(.filed == true)] | length' "$FREE_AGENTS_STATE/findings.ndjson")" "0"

# --- 7. plain `--issue` (no --post) is completely unaffected ---------------
fresh
rec unclassified "display-only test" "text the taxonomy never saw"
out="$("$FA" findings --issue 2>&1)"
assert_contains "still just prints the issue text" "$out" "## unclassified: display-only test"
assert_eq "and never touches gh" "$(wc -l < "$STUB_LOG_FILE")" "0"

end_suite
final_report
