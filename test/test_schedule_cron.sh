#!/usr/bin/env bash
# Proves the daily refresh WORKS when cron runs it - not merely that a line got
# installed (test_schedule.sh covers installing it). This runs the installed
# command the way cron does: `env -i`, a bare system PATH, `/bin/sh -c`.
#
# Why it exists: every agent CLI installs into a per-user directory and cron's
# PATH has none of them, so for weeks the installed line found no agent, died in
# discovery with its one error message thrown away, and left a single line per
# run in refresh.log. Nothing anywhere said so. Every assertion below about the
# log and the outcome failed on that code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "the scheduled refresh works under cron's environment"

# A throwaway project holding its own copy of the tool, as test_bootstrap.sh
# does, so install-skills writes into a temp project - never next to this
# checkout.
PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
TOOL="$PROJ/.free-agents"; mkdir -p "$TOOL"
cp -r "$REPO/bin" "$REPO/skills" "$TOOL/"
FA="$TOOL/bin/fa"
STATE="$PROJ/state"; LOG="$STATE/refresh.log"
CRON_HOME="$PROJ/home"; mkdir -p "$CRON_HOME"   # no credentials: anonymous lanes only
export FA_CRONTAB_CMD="$STUBS_DIR/crontab" FAKE_CRONTAB="$PROJ/crontab"

# The shell that schedules has the agent CLIs on its PATH, as a user's does;
# cron's does not. Stubs plus system directories only, so no real agent CLI is
# reachable from either.
USER_PATH="$STUBS_DIR:/usr/bin:/bin"
CRON_PATH="/usr/bin:/bin"

cron_cmd() { # the installed line minus its five time fields: what cron hands to sh
  grep -vE '^[[:space:]]*#' "$FAKE_CRONTAB" | grep -E "bin/fa'? refresh" | head -1 \
    | cut -d' ' -f6-
}
as_cron() { # $1=command line -> runs it with cron's environment, not this one
  env -i HOME="$CRON_HOME" LOGNAME=fa-test SHELL=/bin/sh PATH="$CRON_PATH" \
      FA_CRONTAB_CMD="$FA_CRONTAB_CMD" FAKE_CRONTAB="$FAKE_CRONTAB" PROBE_TIMEOUT=10 \
      timeout 200 /bin/sh -c "$1"
}
status() { # the doctor section on its own - schedule_status, in the user's shell
  FREE_AGENTS_STATE="$STATE" PATH="$USER_PATH" bash -c \
    '. "$1/bin/lib/common.sh"; . "$1/bin/lib/schedule.sh"; schedule_status' _ "$TOOL"
}

# --- schedule it from the user's shell ----------------------------------------
out="$(FREE_AGENTS_STATE="$STATE" PATH="$USER_PATH" "$FA" schedule 2>&1)"
assert_contains "schedule succeeds" "$out" "daily refresh scheduled"
cmd="$(cron_cmd)"
assert_contains "the line runs the refresh in its scheduled mode" "$cmd" "refresh --scheduled"
assert_contains "the line pins the state the user actually uses" "$cmd" "FREE_AGENTS_STATE='$STATE'"
assert_eq "the scheduling shell's PATH is saved beside the registry" \
  "$(cat "$STATE/schedule.path" 2>/dev/null)" "$USER_PATH"

# --- run it exactly the way cron does -----------------------------------------
cron_before="$(cat "$FAKE_CRONTAB")"
as_cron "$cmd"; rc=$?
log="$(cat "$LOG" 2>/dev/null)"
assert_eq "the scheduled refresh exits 0 under cron's environment" "$rc" "0"
assert_true "the log stamps the start in UTC" \
  '[[ "$log" =~ \[fa\]\ 20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ scheduled\ refresh:\ start ]]'
assert_contains "and records how it finished" "$log" "scheduled refresh: finished rc=0"
assert_not_contains "discovery found the agents" "$log" "no agent CLI found"
assert_true "it wrote a registry" '[[ -s "$STATE/buckets.json" ]]'
assert_true "with at least one bucket" \
  '[[ "$(jq -r ".buckets | length" "$STATE/buckets.json" 2>/dev/null)" -ge 1 ]]'
assert_eq "the cron's own run leaves the crontab alone" "$(cat "$FAKE_CRONTAB")" "$cron_before"
# A re-install from here would write identical bytes, so also check it never ran.
assert_not_contains "and never re-installs itself" "$log" "daily refresh scheduled"

# --- doctor reports what the scheduled run will see ---------------------------
st="$(status)"
assert_contains "doctor confirms the scheduled run finds every installed agent" "$st" "finds all"
assert_contains "doctor shows the last run and its outcome" "$st" "finished rc=0"
out="$(FREE_AGENTS_STATE="$STATE" PATH="$USER_PATH" timeout 90 "$FA" doctor 2>&1)"
assert_contains "fa doctor has a daily refresh section" "$out" "daily refresh"

# --- a saved PATH that cannot see an agent is called out ----------------------
cp "$STATE/schedule.path" "$PROJ/path.keep"
printf '%s\n' "$CRON_PATH" > "$STATE/schedule.path"
assert_contains "doctor names the agents the scheduled run cannot find" "$(status)" "cannot find: opencode"

# --- no saved PATH: the run still fails, but loudly ---------------------------
rm -f "$STATE/schedule.path"; : > "$LOG"
as_cron "$cmd"; rc=$?
log="$(cat "$LOG" 2>/dev/null)"
assert_ne "without its saved PATH the scheduled run cannot refresh" "$rc" "0"
assert_contains "the log says the saved PATH is missing" "$log" "no saved PATH"
assert_contains "the log says why discovery failed" "$log" "no agent CLI found on PATH"
assert_contains "the log still records how it finished" "$log" "finished rc=${rc}"
assert_contains "doctor shows that failed run" "$(status)" "finished rc=${rc} - see"
cp "$PROJ/path.keep" "$STATE/schedule.path"

# --- the line that shipped before, under the same environment ------------------
# It still cannot work - nothing in it can find an agent - but it must never
# fail silently again: its log now says why, not just "discovering...".
OLD_STATE="$CRON_HOME/.local/state/free-agents"; mkdir -p "$OLD_STATE"
as_cron "$FA refresh >> $OLD_STATE/refresh.log 2>&1"; rc=$?
old_log="$(cat "$OLD_STATE/refresh.log" 2>/dev/null)"
assert_ne "the pre-fix line still cannot refresh under cron (expected)" "$rc" "0"
assert_contains "but its log now names the cause" "$old_log" "no agent CLI found on PATH"
assert_contains "and the PATH it searched" "$old_log" "PATH=${CRON_PATH})"

# ...and doctor recognises that line for what it is.
printf '# free-agents: daily refresh (installed by fa schedule; remove with fa unschedule)\n0 3 * * * %s refresh >> %s/refresh.log 2>&1\n' \
  "$FA" "$STATE" > "$FAKE_CRONTAB"
assert_contains "doctor flags a line scheduled the old way" "$(status)" "scheduled the old way"

# --- a registry that is not being refreshed is called out ---------------------
jq --arg d "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" '.generated_at = $d' \
  "$STATE/buckets.json" > "$STATE/b.tmp" && mv "$STATE/b.tmp" "$STATE/buckets.json"
assert_contains "doctor says a daily-refreshed registry is days old" "$(status)" "5 days old although"
assert_contains "and how to move the run to an hour the machine is on" "$(status)" "FA_SCHEDULE_HH="

end_suite
final_report
