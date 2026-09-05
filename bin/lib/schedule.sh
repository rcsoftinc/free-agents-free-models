# schedule.sh - self-maintained daily `fa refresh` via the user's own crontab.
# Source, do not execute.

# Why this exists: the registry records credential FINGERPRINTS and live credit
# budget, so it is exactly as fresh as the last time someone ran `fa refresh`.
# Nothing re-probes on its own. A key you add, a copilot allowance that runs
# out, or an agent you install stays invisible until the next manual refresh -
# and "manual" is a step a fresh clone of this repo is supposed to not need.
# `fa schedule` puts a daily refresh in the user's crontab, and `fa bootstrap`
# / `fa refresh` / `setup.sh` call it automatically, so:
#
#   clone the repo  ->  run setup.sh (or fa bootstrap)  ->  done
#
# Per-user crontab, not /etc/cron.d: setup runs as the calling user, works when
# that user is not root, and the refresh only ever touches that user's own
# credential files. The cron line uses the tool's ABSOLUTE path at install time,
# so it survives reboots and PATH changes, and stays valid if the clone moves.
#
#   FA_CRONTAB_CMD   crontab binary name/path (default: crontab) - test hook
#   FA_NO_SCHEDULE=1 skip installing the cron with a note (ephemeral machines)
#   FA_SCHEDULE_MIN  minute of day  (default 0)
#   FA_SCHEDULE_HH   hour of day    (default 3)
#
# A daily refresh also keeps the copilot budget current: an allowance that hits
# zero falls off the lane list on its own, instead of wasting an attempt.

SCHEDULE_MARKER='free-agents: daily refresh'

schedule_tool_root() {
  # bin/lib/schedule.sh -> <repo>/bin/lib -> <repo>
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${here}/../.." && pwd
}

schedule_cron_cmd() {
  [[ -n "${FA_SCHEDULE_MIN:-}" && -n "${FA_SCHEDULE_HH:-}" ]] \
    && printf '%s %s * * *' "$FA_SCHEDULE_MIN" "$FA_SCHEDULE_HH" \
    || printf '0 3 * * *'
}

schedule_block() { # the marker comment + cron line, installed as one unit
  local root; root="$(schedule_tool_root)"
  printf '# %s (installed by fa schedule; remove with fa unschedule)\n' "$SCHEDULE_MARKER"
  printf '%s %s/bin/fa refresh >> %s/refresh.log 2>&1\n' \
    "$(schedule_cron_cmd)" "$root" "$STATE_DIR"
}

schedule_has_crontab() { # 0 if a crontab binary exists (real or FA_CRONTAB_CMD)
  local cb="${FA_CRONTAB_CMD:-crontab}"
  if [[ "$cb" == */* ]]; then [[ -x "$cb" ]] && return 0 || return 1
  else command -v "$cb" >/dev/null 2>&1; fi
}

schedule_existing() { # -> the user's current crontab lines (empty if none)
  local cb="${FA_CRONTAB_CMD:-crontab}"
  [[ "${FA_NO_SCHEDULE:-0}" == "1" ]] && return 0
  schedule_has_crontab || return 0
  "$cb" -l 2>/dev/null || true
}

schedule_install() { # idempotent add/replace; exits 0 with a note when skipped
  if [[ "${FA_NO_SCHEDULE:-0}" == "1" ]]; then
    echo "[fa] note: FA_NO_SCHEDULE=1, no daily refresh scheduled" >&2
    return 0
  fi
  local cb="${FA_CRONTAB_CMD:-crontab}"
  if ! schedule_has_crontab; then
    echo "[fa] note: no crontab found - daily refresh not scheduled" >&2
    echo "[fa]       run 'fa refresh' yourself when credentials change" >&2
    return 0
  fi
  local cur new
  cur="$(schedule_existing)"
  # Remove any previous FA refresh (marker line or the command line) so the
  # install is a replace, never an append that stacks duplicate runs.
  new="$(printf '%s\n' "$cur" | grep -vE "^# ${SCHEDULE_MARKER}|bin/fa refresh >>" || true)"
  new="$(printf '%s\n' "$new" | sed '/^$/N;/^\n$/D' || true)"
  {
    [[ -n "$new" ]] && printf '%s\n' "$new"
    schedule_block
  } | "$cb" -
  echo "[fa] daily refresh scheduled at $(schedule_cron_cmd) ($(schedule_tool_root)/bin/fa refresh)"
}

schedule_uninstall() { # remove the FA refresh line; silent if there was none
  local cb="${FA_CRONTAB_CMD:-crontab}"
  if [[ "${FA_NO_SCHEDULE:-0}" == "1" || ! schedule_has_crontab ]]; then
    echo "[fa] note: nothing to unschedule" >&2
    return 0
  fi
  local cur new
  cur="$(schedule_existing)"
  new="$(printf '%s\n' "$cur" | grep -vE "^# ${SCHEDULE_MARKER}|bin/fa refresh >>" || true)"
  if [[ "$new" == "$cur" ]]; then
    echo "[fa] no daily refresh was scheduled" >&2
    return 0
  fi
  if [[ -z "$new" ]]; then
    "$cb" -r 2>/dev/null || true
  else
    printf '%s\n' "$new" | "$cb" -
  fi
  echo "[fa] daily refresh removed"
}

schedule_status() {
  if [[ "${FA_NO_SCHEDULE:-0}" == "1" ]]; then
    echo "  off    FA_NO_SCHEDULE=1 is set"
    return 0
  fi
  if ! schedule_has_crontab; then
    echo "  absent no crontab found (run 'fa schedule' on a machine with cron)"
    return 0
  fi
  if schedule_existing | grep -qE 'bin/fa refresh >>'; then
    local line; line="$(schedule_existing | grep 'bin/fa refresh >>' | head -1)"
    echo "  ok     $(printf '%s' "$line" | sed 's|>>.*refresh.log 2>&1||')"
  else
    echo "  absent no daily refresh (run: fa schedule)"
  fi
}