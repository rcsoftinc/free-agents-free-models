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
# so it survives reboots; moving the clone means re-running `fa schedule`.
#
# What an absolute path does NOT carry is the environment, and that is the part
# that broke. Cron hands a job a bare system PATH, while every agent CLI installs
# into a per-user directory (~/.local/bin, ~/.opencode/bin, ~/.kilo/bin) - so
# for weeks the installed line found no agent at all, died in discovery with its
# one error message thrown away, and left a single line per run in refresh.log.
# The line now carries what the scheduled run needs:
#   - the PATH it was scheduled from, saved next to the registry
#     (schedule.path) and restored by `fa refresh --scheduled`
#   - FREE_AGENTS_STATE, so it refreshes the registry you actually use, and
#     finds that saved PATH, even when the state location is overridden
# and `fa doctor` reports what the scheduled run will actually see.
#
#   FA_CRONTAB_CMD   crontab binary name/path (default: crontab) - test hook
#   FA_NO_SCHEDULE=1 skip installing the cron with a note (ephemeral machines)
#   FA_SCHEDULE_MIN  minute of day  (default 0)   set both; once installed,
#   FA_SCHEDULE_HH   hour of day    (default 3)   the time survives re-installs
#
# A daily refresh also keeps the copilot budget current: an allowance that hits
# zero falls off the lane list on its own, instead of wasting an attempt.

SCHEDULE_MARKER='free-agents: daily refresh'
# The refresh line in either shape - the current one, and the bare
#   <root>/bin/fa refresh >> <state>/refresh.log 2>&1
# it replaces - so an upgrade swaps the old line out instead of stacking a
# second one beside it.
SCHEDULE_LINE_RE="bin/fa'? refresh( --scheduled)? >>"

schedule_tool_root() {
  # bin/lib/schedule.sh -> <repo>/bin/lib -> <repo>
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${here}/../.." && pwd
}

schedule_path_file() { printf '%s/schedule.path' "$STATE_DIR"; }

schedule_sq() { # $1 -> single-quoted for the /bin/sh that cron runs the line with
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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

schedule_lines() { # -> the installed refresh line(s), comments excluded
  schedule_existing | grep -vE '^[[:space:]]*#' | grep -E "$SCHEDULE_LINE_RE" || true
}

schedule_cron_cmd() { # -> the five time fields
  if [[ -n "${FA_SCHEDULE_MIN:-}" && -n "${FA_SCHEDULE_HH:-}" ]]; then
    printf '%s %s * * *' "$FA_SCHEDULE_MIN" "$FA_SCHEDULE_HH"; return
  fi
  # Keep the time an installed line already uses. FA_SCHEDULE_* are read only at
  # install time and every `fa refresh` re-installs, so without this a time
  # picked by hand went quietly back to 03:00 on the next refresh.
  local cur; cur="$(schedule_lines | head -1)"
  if [[ -n "$cur" ]]; then
    awk '{printf "%s %s %s %s %s", $1, $2, $3, $4, $5}' <<<"$cur"; return
  fi
  printf '0 3 * * *'
}

schedule_block() { # $1=time fields -> the marker comment + cron line, one unit
  local root; root="$(schedule_tool_root)"
  printf '# %s (installed by fa schedule; remove with fa unschedule)\n' "$SCHEDULE_MARKER"
  printf '%s FREE_AGENTS_STATE=%s %s refresh --scheduled >> %s 2>&1\n' \
    "$1" "$(schedule_sq "$STATE_DIR")" "$(schedule_sq "${root}/bin/fa")" \
    "$(schedule_sq "${STATE_DIR}/refresh.log")"
}

# The PATH this was scheduled from is the one that finds the agent CLIs; keep it
# beside the registry for `fa refresh --scheduled` to restore.
schedule_save_path() {
  local f; f="$(schedule_path_file)"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$PATH" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

schedule_saved_path() { # -> the saved PATH, or nothing
  local f p=""; f="$(schedule_path_file)"
  [[ -s "$f" ]] && { IFS= read -r p < "$f" || true; }
  printf '%s' "$p"
}

schedule_restore_path() { # -> 0 when the saved PATH was restored
  local p; p="$(schedule_saved_path)"
  [[ -n "$p" ]] || return 1
  export PATH="$p"
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
  local cur new when
  cur="$(schedule_existing)"
  # Read BEFORE writing: a crontab that truncates as it starts reading its new
  # contents would otherwise hide the time this is meant to keep.
  when="$(schedule_cron_cmd)"
  # Remove any previous FA refresh (marker line or the command line) so the
  # install is a replace, never an append that stacks duplicate runs.
  new="$(printf '%s\n' "$cur" | grep -vE "^# ${SCHEDULE_MARKER}|${SCHEDULE_LINE_RE}" || true)"
  new="$(printf '%s\n' "$new" | sed '/^$/N;/^\n$/D' || true)"
  if ! {
    [[ -n "$new" ]] && printf '%s\n' "$new"
    schedule_block "$when"
  } | "$cb" -; then
    echo "[fa] note: could not write the crontab - daily refresh not scheduled" >&2
    return 1
  fi
  schedule_save_path
  echo "[fa] daily refresh scheduled at ${when} ($(schedule_tool_root)/bin/fa refresh, with this shell's PATH)"
}

schedule_uninstall() { # remove the FA refresh line; silent if there was none
  local cb="${FA_CRONTAB_CMD:-crontab}"
  if [[ "${FA_NO_SCHEDULE:-0}" == "1" ]] || ! schedule_has_crontab; then
    echo "[fa] note: nothing to unschedule" >&2
    return 0
  fi
  local cur new
  cur="$(schedule_existing)"
  new="$(printf '%s\n' "$cur" | grep -vE "^# ${SCHEDULE_MARKER}|${SCHEDULE_LINE_RE}" || true)"
  rm -f "$(schedule_path_file)"
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

# fa doctor's "daily refresh" section. Advisory only - like registry age,
# nothing here stops a task running today, so it never fails doctor. It exists
# because the refresh failed silently for weeks and nothing anywhere said so.
schedule_status() {
  if [[ "${FA_NO_SCHEDULE:-0}" == "1" ]]; then
    echo "  off     FA_NO_SCHEDULE=1 is set - refresh by hand: fa refresh"
    return 0
  fi
  if ! schedule_has_crontab; then
    echo "  absent  no crontab on this machine - refresh by hand: fa refresh"
    return 0
  fi
  local lines line when tool n
  lines="$(schedule_lines)"
  if [[ -z "$lines" ]]; then
    echo "  absent  no daily refresh scheduled - run: fa schedule"
    return 0
  fi
  n="$(printf '%s\n' "$lines" | wc -l)"
  line="$(printf '%s\n' "$lines" | head -1)"
  when="$(awk '{printf "%s %s %s %s %s", $1, $2, $3, $4, $5}' <<<"$line")"
  # The quoted path first (today's line, which may contain spaces), then the
  # bare one an older copy wrote.
  tool="$(sed -nE "s#.*'([^']*/bin/fa)' refresh.*#\1#p" <<<"$line")"
  [[ -n "$tool" ]] || tool="$(grep -oE "[^ ']*/bin/fa" <<<"$line" | head -1)"

  [[ "$n" -gt 1 ]] && echo "  note    ${n} refresh lines installed (an older copy of the tool added its own) - run: fa schedule"
  if [[ ! -x "$tool" ]]; then
    echo "  note    the copy of the tool it runs is gone: ${tool} - run: fa schedule"
  elif [[ "$line" != *"refresh --scheduled"* ]]; then
    echo "  note    scheduled the old way: cron's own PATH finds no agent CLI, so every"
    echo "          run fails - run: fa schedule"
  else
    # What the scheduled run will actually see: every agent installed here must
    # be findable on the PATH it restores.
    local saved missing="" a b
    saved="$(schedule_saved_path)"
    if [[ -z "$saved" ]]; then
      echo "  note    no saved PATH for it ($(schedule_path_file)) - run: fa schedule"
    else
      for a in $(adapters_installed); do
        for b in $(adapter_binaries "$a"); do
          ( PATH="$saved"; command -v "$b" >/dev/null 2>&1 ) && continue 2
        done
        missing+="${missing:+ }$a"
      done
      if [[ -n "$missing" ]]; then
        echo "  note    the scheduled run cannot find: ${missing} - run fa schedule from the shell you use them in"
      else
        echo "  ok      ${when}  ${tool} refresh  (finds all $(adapters_installed | wc -l) installed agents)"
      fi
    fi
  fi

  local last
  last="$(grep -E 'scheduled refresh: (start|finished)' "${STATE_DIR}/refresh.log" 2>/dev/null \
          | tail -1 | sed 's/^\[fa\] //')"
  if [[ -z "$last" ]]; then
    echo "  note    no scheduled run recorded yet"
  elif [[ "$last" == *"finished rc=0" ]]; then
    echo "  ok      last run: ${last}"
  else
    # rc != 0, or a start with no finish: killed mid-run, or still running.
    echo "  note    last run: ${last} - see ${STATE_DIR}/refresh.log"
  fi

  # Cron does not catch up a run it missed, so a machine that is off or asleep
  # at the scheduled time simply never refreshes - one real machine managed 2
  # runs in 13 days at 03:00. Two days stale under a daily schedule is that, or a
  # failing run; either way it should be said.
  local age; age="$(registry_age_days)"
  if [[ "$age" =~ ^[0-9]+$ && "$age" -ge 2 ]]; then
    echo "  note    the registry is ${age} days old although it refreshes daily - cron skips"
    echo "          a run while this machine is off or asleep at ${when}. Pick an hour it is"
    echo "          usually on:  FA_SCHEDULE_HH=13 FA_SCHEDULE_MIN=0 fa schedule"
  fi
}
