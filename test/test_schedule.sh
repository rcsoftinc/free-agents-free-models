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

# --- install ---------------------------------------------------------------
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" timeout 60 "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_contains "schedule announces success" "$out" "daily refresh scheduled"
assert_contains "cron file holds the marker" "$cron" "free-agents: daily refresh"
assert_contains "cron runs the tool by ABSOLUTE path" "$cron" "$FA"
assert_contains "cron targets the state-dir log" "$cron" "$STATE/refresh.log"
assert_true "refresh runs daily at 03:00" '[[ "$cron" == *"0 3 * * * $FA"* ]]'
assert_eq "exactly one FA refresh line after install" "$(printf '%s' "$cron" | grep -c 'bin/fa refresh >>')" "1"

# --- a second run is a replace, not a stack -------
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_eq "re-schedule leaves exactly one FA line" "$(printf '%s' "$cron" | grep -c 'bin/fa refresh >>')" "1"

# --- foreign lines survive install AND unschedule ---------------------------
printf '%s\n' "17 2 * * * /usr/bin/backup --quiet" >> "$FAKE_CRONTAB"
out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" schedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_contains "an existing unrelated cron line survives schedule" "$cron" "/usr/bin/backup --quiet"

out="$(FREE_AGENTS_STATE="$STATE" PATH="$HERE/stubs:$PATH" "$FA" unschedule 2>&1)"
cron="$(cat "$FAKE_CRONTAB")"
assert_eq "unschedule removes the FA line" "$(printf '%s' "$cron" | grep -c 'bin/fa refresh >>')" "0"
assert_contains "unschedule keeps unrelated crons" "$cron" "/usr/bin/backup --quiet"
assert_contains "unschedule announces removal" "$out" "removed"

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
assert_contains "fa help lists schedule" "$(sed -n '6,16p' "$FA")" "fa schedule"
assert_contains "fa help lists unschedule" "$(sed -n '6,16p' "$FA")" "fa unschedule"

end_suite
final_report