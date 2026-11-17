#!/usr/bin/env bash
set -euo pipefail

# setup.sh - make the CURRENT directory a free-agents project, and this machine
# able to run it.
#
# Intended use: you are in your project (empty or existing), you cloned this repo
# into it as `.free-agents/`, and you run:
#
#     .free-agents/setup.sh
#
# On a new machine, run it twice. The first run installs what is missing: the
# system tools (apt), and every agent CLI it does not find, each with its
# vendor's own install script (bin/lib/install.sh). Logging in and pasting keys
# is yours to do between the runs - a login is consent, and nothing here gives
# it for you - and the second run finds the credentials, builds the registry of
# lanes from them (or refreshes one that has gone stale) and schedules the daily
# refresh. Every run ends by saying what it found and what is still missing,
# and exits 0 only when at least one lane can take work: 1 when none can, 3
# when a system tool is missing.
#
# Everything this tool owns stays inside two hidden directories - `.free-agents/`
# (the tool) and `.orch/` (this project's run state). Nothing else is added to
# your project, and neither directory needs to be committed. The agent CLIs
# install where their vendors put them, under your home directory.
#
#   FA_AUTO_INSTALL=1   install without asking: the system tools and the agent CLIs
#   --no-bootstrap      no network: install and configure, but build no registry

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --no-bootstrap is for scripting setup offline; everyone else wants the network
# call, because a registry is the one thing nothing works without.
DO_BOOTSTRAP=1; PROJECT=""
for arg in "$@"; do
  case "$arg" in
    --no-bootstrap) DO_BOOTSTRAP=0 ;;
    -*) printf 'setup.sh: unknown option %s\n' "$arg" >&2; exit 2 ;;
    *)  PROJECT="$arg" ;;
  esac
done
PROJECT="${PROJECT:-$(cd "${HERE}/.." && pwd)}"
# Resolve state EXACTLY as the engine does, by sourcing the same file rather than
# recomputing the path. The two had drifted: this recomputed a machine-wide path
# while the engine used <clone>/state, so the registry line printed a path and a
# lane count that came from different places. Sourcing makes that impossible
# rather than merely fixing it once.
# shellcheck source=bin/lib/common.sh
. "${HERE}/bin/lib/common.sh"
STATE="$STATE_DIR"
# shellcheck source=bin/lib/keys.sh
. "${HERE}/bin/lib/keys.sh"
# shellcheck source=bin/lib/install.sh
. "${HERE}/bin/lib/install.sh"

say() { printf '[fa] %s\n' "$*"; }

prompt_yn() { # $1=prompt -> 0 if yes
  local ans
  read -rp "$1 [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# The tool cannot talk to a provider without the system tools - setup previously
# swallowed a missing jq and declared "Ready." with a silent half-install. Fail
# loudly (with the apt line) before anything else runs.
_miss="$(missing_deps)"
if [[ -n "$_miss" ]]; then
  say "missing system dependencies: $(tr '\n' ' ' <<<"$_miss")"
  if [[ "${FA_AUTO_INSTALL:-0}" == "1" ]] || prompt_yn "install them now?"; then
    if command -v apt-get >/dev/null 2>&1; then
      # A new machine's package lists may be empty; refreshing them first costs
      # a moment and saves an "Unable to locate package" on the install.
      sudo apt-get update -qq || true
      sudo apt-get install -y $_miss || { say "apt install failed"; exit 3; }
    elif command -v brew >/dev/null 2>&1; then
      brew install $_miss || { say "brew install failed"; exit 3; }
    else
      say "  install them first, e.g.:  sudo apt-get install -y $(tr '\n' ' ' <<<"$_miss")"
      exit 3
    fi
  else
    say "  install them first, e.g.:  sudo apt-get install -y $(tr '\n' ' ' <<<"$_miss")"
    exit 3
  fi
fi

cd "$PROJECT"
say "project: $PROJECT"
say "tool:    $HERE"

# Agent CLIs: each one missing is offered its vendor's installer, and what is
# installed goes on PATH for the rest of this run (bin/lib/install.sh).
install_missing_agents

chmod +x "${HERE}"/bin/*.sh "${HERE}"/bin/lib/*.sh "${HERE}/bin/fa" \
         "${HERE}/setup.sh" 2>/dev/null || true

# Credentials, in two tiers because the seven agents are not symmetric - see
# bin/lib/keys.sh and docs/SETUP.md for the full picture.
#
# Tier A (opencode, kilo, pi): a raw key is all they need, so it is fully
# scriptable from .free-agents/keys.env (copy keys.env.example, gitignored).
# Silently a no-op if that file does not exist - this is entirely optional.
provision_keys

# Tier B (copilot, cursor, agy, hermes): real OAuth/account login. This
# cannot safely automate consenting on your behalf, so it only detects who
# is not logged in yet, offers each agent's own login step one at a time,
# and reports what is still outstanding either way - so nothing is silently
# skipped just because it needed a human.
guided_logins

# Let orch.sh define what .orch/ contains. This used to be open-coded here, and
# the copy drifted: it omitted handoffs/, ran first, and orch.sh's own writer
# no-ops when the file already exists - so every project committed its handoffs.
# One writer, no drift.
ORCH_PROJECT="$PROJECT" "${HERE}/bin/orch.sh" init >/dev/null

# Keep the tool out of the project's git unless the user decides otherwise.
if [[ -d .git ]] && ! grep -qs '^\.free-agents/' .gitignore 2>/dev/null; then
  printf '\n# free-agents tool (clone; not part of this project)\n.free-agents/\n' >> .gitignore
  say "added .free-agents/ to your .gitignore"
fi

# The registry lives wherever the engine says it does - inside this clone by
# default, or at FREE_AGENTS_STATE if set, in which case projects share it.
_status="$(registry_status)"

# guided_logins() just took someone from "not logged in" to "now logged in" -
# don't make them remember to run `fa refresh` by hand, or wait for the
# daily cron, to actually get a lane out of it. Registry HEALTH is otherwise
# deliberately never proactively re-checked (it self-corrects at the first
# real dispatch attempt - see common.sh's own registry_status() comment);
# this is the one exception, scoped to the exact moment something we just
# watched happen would otherwise stay invisible. Skipped when there is no
# registry yet at all (the `missing` branch below bootstraps unconditionally
# regardless - refreshing here too would just probe everything twice) or
# under --no-bootstrap (which means "no network calls", full stop).
if [[ "$_status" != "missing" && "$DO_BOOTSTRAP" -eq 1 && "${#NEWLY_LOGGED_IN[@]}" -gt 0 ]]; then
  say "just signed in: ${NEWLY_LOGGED_IN[*]} - refreshing now to pick up the new lane(s)"
  "${HERE}/bin/fa" refresh || say "refresh failed - run it yourself: .free-agents/bin/fa refresh"
  _status="$(registry_status)"
fi

case "$_status" in
  missing)
    if [[ "$DO_BOOTSTRAP" -eq 0 ]]; then
      say "no registry - run: .free-agents/bin/fa bootstrap"
    else
      say "no registry on this machine - bootstrapping now."
      say "  this contacts each provider once to see what your credentials reach"
      say "  (~2 min). It stores no secrets. Skip with --no-bootstrap."
      "${HERE}/bin/fa" bootstrap || say "bootstrap failed - run it again with: fa bootstrap"
    fi
    ;;
  stale:credentials|stale:new-agent)
    # A key pasted or a login done since the last run, or a CLI installed just
    # now: the second run on a new machine lands exactly here, and it is the run
    # that is supposed to build the lanes. A stale registry is the one health
    # state that IS re-checked: the docs tell a person to refresh here, so do it.
    if [[ "$_status" == "stale:credentials" ]]; then
      say "registry is STALE - your credentials changed since it was built; refreshing now."
    else
      say "registry is STALE - an agent is installed that has no lane yet; refreshing now."
    fi
    if [[ "$DO_BOOTSTRAP" -eq 1 ]]; then
      "${HERE}/bin/fa" refresh || say "refresh failed - run it yourself: .free-agents/bin/fa refresh"
    else
      say "  (--no-bootstrap: not now) a key you added is invisible until you run: .free-agents/bin/fa refresh"
    fi
    ;;
  aged:*)
    say "registry: $("${HERE}/bin/buckets.sh" lanes) lane(s), $(registry_age_days) days old"
    say "  free-model lists drift; refresh when convenient: fa refresh" ;;
  *)
    say "registry: $("${HERE}/bin/buckets.sh" lanes) healthy lane(s), $(registry_age_days) days old"
    say "          ${STATE}" ;;
esac

# ---- the verdict: a lane, or exactly what is still missing -------------------
lanes=0
if [[ -f "$REGISTRY" ]]; then
  lanes="$("${HERE}/bin/buckets.sh" lanes 2>/dev/null || echo 0)"
fi

# Built from FA_AGENTS, not typed out - a hand-copied roster in a banner is
# exactly the "second definition of the harness list" this project's own
# adapters.sh already warns against (it drifted once before: this exact line
# used to read "opencode | kilo | hermes | copilot | cursor", silently
# missing agy and pi ever since they were added).
#
# The COMMAND to type is adapter_field VERSION_BIN, not the bare adapter
# name - they are the same string for six of the seven agents, but cursor's
# own binary is `cursor-agent`; bare `cursor` is only an alternate presence-
# detection signal (FA_cursor_BINARY="cursor-agent,cursor") and, on a real
# machine, running it directly refuses outright: "No Cursor IDE installation
# found. Use 'cursor agent' or 'agent' to run the agent." VERSION_BIN is
# already the one binary each adapter is pinned/verified against, which is
# exactly "the one that actually works" for every agent, cursor included.
agent_list=""; not_installed=""
for agent in "${FA_AGENTS[@]}"; do
  agent_list="${agent_list:+${agent_list} | }$(adapter_field "$agent" VERSION_BIN)"
  adapter_installed "$agent" || not_installed="${not_installed:+${not_installed} }${agent}"
done
needs="$(credential_summary)"
pathline="$(installed_now_path_line)"

if [[ "$lanes" -ge 1 ]]; then
  cat <<EOT

Ready.

  1. Start any agent from here:  ${agent_list}
  2. Paste this into it:         .free-agents/prompts/coordinator.md
  3. Then just talk normally - it picks the mode itself.
EOT
  if [[ -n "$needs" ]]; then
    echo
    echo "More lanes, once these have an account (then: .free-agents/bin/fa refresh):"
    printf '%s\n' "$needs"
  fi
  if [[ -n "$not_installed" ]]; then
    echo
    echo "Not installed, so not a lane: ${not_installed}  (run setup again to install them)"
  fi
  if [[ -n "$pathline" ]]; then
    echo
    echo "The CLIs installed just now are on PATH in a new shell. In this one, first:"
    echo "    ${pathline}"
  fi
  cat <<EOT

Refresh the registry when you add a credential or install another agent
(setup and doctor both tell you when):
    .free-agents/bin/fa refresh

Or drive it yourself:
    .free-agents/bin/fa lanes -v
    .free-agents/bin/fa plan "goal"  &&  .free-agents/bin/fa orch run
EOT
  exit 0
fi

cat <<EOT

Not ready yet: no lane can take work.
EOT
[[ -n "$not_installed" ]] && echo "  not installed:  ${not_installed}"
if [[ ! -f "$REGISTRY" ]]; then
  if [[ "$DO_BOOTSTRAP" -eq 0 ]]; then
    echo "  no registry yet (--no-bootstrap) - this builds it: .free-agents/bin/fa bootstrap"
  else
    echo "  no registry yet - nothing to build one from"
  fi
else
  echo "  the registry has $(jq -r '.buckets | length' "$REGISTRY" 2>/dev/null || echo 0) wallet(s), none a lane right now - this says why: .free-agents/bin/fa lanes -v"
fi
if [[ -n "$needs" ]]; then
  echo
  echo "Give at least one of these an account:"
  printf '%s\n' "$needs"
fi
if [[ -n "$pathline" ]]; then
  echo
  echo "The CLIs installed just now are on PATH in a new shell. In this one, first:"
  echo "    ${pathline}"
fi
cat <<EOT

Then run this again - it finds the credentials and builds the lanes from them:
    .free-agents/setup.sh
EOT
exit 1
