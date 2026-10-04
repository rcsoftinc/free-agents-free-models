#!/usr/bin/env bash
# Proves the daily `fa refresh` cron can be installed idempotently via a fake
# crontab (never touching the real user crontab), that unschedule removes only
# its own line, and that `fa bootstrap` wires it in automatically - so a fresh
# clone + setup.sh needs no manual step to stay current.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "daily refresh cron is self-installing and safe"
sandbox_on
export FAKE_CRONTAB="$(mktemp)"
export FA_CRONTAB_CMD="crontab"
STUB_CRONTAB="$REPO/test/stubs/crontab"
FA="$REPO/bin/fa"
STATE="$(mktemp -d)"
# The refresh line in either shape: today's, and the bare one it replaced.
FA_LINE="bin/fa'? refresh( --scheduled)? >>"
fa_lines() { printf '%s\n' "$1" | grep -cE "$FA_LINE"; }

# --- install ---------------------------------------------------------------
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" timeout 60 "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_contains "schedule announces success" "$out" "daily refresh scheduled"
assert_contains "cron file holds the marker" "$cron" "free-agents: daily refresh"
assert_contains "cron runs the tool by ABSOLUTE path, in scheduled mode" "$cron" "'$FA' refresh --scheduled"
assert_contains "cron targets the state-dir log" "$cron" "$STATE/refresh.log"
assert_contains "cron pins the state dir the refresh must update" "$cron" "FREE_AGENTS_STATE='$STATE'"
assert_true "refresh runs daily at 03:00" '[[ "$cron" == *"0 3 * * * FREE_AGENTS_STATE="* ]]'
assert_eq "exactly one FA refresh line after install" "$(fa_lines "$cron")" "1"
# Cron's own PATH holds no agent CLI; the scheduling shell's does. It must be
# kept for the scheduled run to restore (test_schedule_cron.sh runs that).
assert_eq "the scheduling shell's PATH is saved for the cron run" \
  "$(cat "$STATE/schedule.path" 2>/dev/null)" "$HERE/stubs:$PATH"

# --- a second run is a replace, not a stack -------
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_eq "re-schedule leaves exactly one FA line" "$(fa_lines "$cron")" "1"

# --- a line from before --scheduled existed is REPLACED, not joined -----------
# Older copies of the tool installed the bare line, and still do until updated;
# it fails every run under cron. An upgrade must swap it out, never add a second.
printf '# free-agents: daily refresh (installed by fa schedule; remove with fa unschedule)\n0 3 * * * %s refresh >> %s/refresh.log 2>&1\n' \
  "$FA" "$STATE" > "$FAKE_CRONTAB"
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_eq "upgrading the old line leaves exactly one FA line" "$(fa_lines "$cron")" "1"
assert_contains "and it is the new one" "$cron" "refresh --scheduled"
assert_eq "with exactly one marker comment" "$(printf '%s\n' "$cron" | grep -c 'free-agents: daily refresh')" "1"

# --- a time picked by hand survives later re-installs -------------------------
# Every fa refresh re-installs the line; FA_SCHEDULE_* are only read when set,
# so the time already installed must be what a plain re-install keeps.
out="$(FREE_AGENTS_STATE="$STATE" FA_SCHEDULE_MIN=30 FA_SCHEDULE_HH=13 PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
assert_true "FA_SCHEDULE_MIN/HH set the time" '[[ "$(cat "$FAKE_CRONTAB")" == *"30 13 * * * FREE_AGENTS_STATE="* ]]'
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
assert_true "a plain re-install keeps that time" '[[ "$(cat "$FAKE_CRONTAB")" == *"30 13 * * * FREE_AGENTS_STATE="* ]]'
assert_contains "and says which time it kept" "$out" "scheduled at 30 13 * * *"

# --- foreign lines survive install AND unschedule ---------------------------
printf '%s\n' "17 2 * * * /usr/bin/backup --quiet" >> "$FAKE_CRONTAB"
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_contains "an existing unrelated cron line survives schedule" "$cron" "/usr/bin/backup --quiet"

out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" unschedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_eq "unschedule removes the FA line" "$(fa_lines "$cron")" "0"
assert_contains "unschedule keeps unrelated crons" "$cron" "/usr/bin/backup --quiet"
assert_contains "unschedule announces removal" "$out" "removed"
assert_true "unschedule drops the saved PATH with it" '[[ ! -e "$STATE/schedule.path" ]]'

# --- FA_NO_SCHEDULE=1 opts out without error ---------------------------------
rm -f "$FAKE_CRONTAB"
out="$(FREE_AGENTS_STATE="$STATE" FA_NO_SCHEDULE=1 PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
assert_eq "FA_NO_SCHEDULE writes no cron file" "$(cat "$FAKE_CRONTAB" 2>/dev/null || echo empty)" "empty"
assert_contains "FA_NO_SCHEDULE says so" "$out" "no daily refresh scheduled"

# --- missing crontab causes a graceful skip ----------------------------------
out="$(FREE_AGENTS_STATE="$STATE" FA_CRONTAB_CMD=/nonexistent-crontab-xyz PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
assert_contains "no crontab binary -> note, not a crash" "$out" "no crontab found"

# --- the auto-wiring claim (source-level, so it never drifts) ----------------
if grep -q 'schedule_install' "$REPO/bin/fa" && grep -q 'keeping credentials current' "$REPO/bin/fa"; then
  pass "fa bootstrap/refresh call schedule_install (checked in bin/fa)"
else
  fail "fa bootstrap no longer installs the daily refresh"
fi
assert_contains "setup.sh bootstraps through fa bootstrap" "$(cat "$REPO/setup.sh")" 'fa" bootstrap'

# --- fa schedule/unschedule are documented in the entry point ----------------
# Read the header the way usage() does (up to the HERE= line), not a fixed line
# range - a range here goes stale on the first line added above it.
help="$(awk '/^HERE=/{exit} NR>=6{print}' "$FA")"
assert_contains "fa help lists schedule" "$help" "fa schedule"
assert_contains "fa help lists unschedule" "$help" "fa unschedule"
assert_contains "fa help lists the cron's own entry point" "$help" "--scheduled"

end_suite
final_report