#!/usr/bin/env bash
set -euo pipefail

# setup.sh - make the CURRENT directory a free-agents project.
#
# Intended use: you are in your project (empty or existing), you cloned this repo
# into it as `.free-agents/`, and you run:
#
#     .free-agents/setup.sh
#
# Everything this tool owns stays inside two hidden directories - `.free-agents/`
# (the tool) and `.orch/` (this project's run state). Nothing else is added to
# your project, and neither directory needs to be committed.

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

say() { printf '[fa] %s\n' "$*"; }

# The tool cannot talk to a provider without the system tools - setup previously
# swallowed a missing jq and declared "Ready." with a silent half-install. Fail
# loudly (with the apt line) before anything else runs.
_miss="$(missing_deps)"
if [[ -n "$_miss" ]]; then
  say "missing system dependencies: $(tr '\n' ' ' <<<"$_miss")"
  say "  install them first, e.g.:  sudo apt-get install -y $(tr '\n' ' ' <<<"$_miss")"
  exit 3
fi

cd "$PROJECT"
say "project: $PROJECT"
say "tool:    $HERE"

chmod +x "${HERE}"/bin/*.sh "${HERE}"/bin/lib/*.sh "${HERE}/bin/fa" \
         "${HERE}/setup.sh" 2>/dev/null || true
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
case "$(registry_status)" in
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
  stale:credentials)
    say "registry is STALE - your credentials changed since it was built."
    say "  a key you added is invisible until you run: .free-agents/bin/fa refresh" ;;
  stale:new-agent)
    say "registry is STALE - an agent is installed that has no lane yet."
    say "  run: .free-agents/bin/fa refresh" ;;
  aged:*)
    say "registry: $("${HERE}/bin/buckets.sh" lanes) lane(s), $(registry_age_days) days old"
    say "  free-model lists drift; refresh when convenient: fa refresh" ;;
  *)
    say "registry: $("${HERE}/bin/buckets.sh" lanes) healthy lane(s), $(registry_age_days) days old"
    say "          ${STATE}" ;;
esac

cat <<EOF

Ready.

  1. Start any agent from here:  opencode | kilo | hermes | copilot | cursor
  2. Paste this into it:         .free-agents/prompts/coordinator.md
  3. Then just talk normally - it picks the mode itself.

Refresh the registry when you add a credential or install another agent
(setup and doctor both tell you when):
    .free-agents/bin/fa refresh

Or drive it yourself:
    .free-agents/bin/fa lanes -v
    .free-agents/bin/fa plan "goal"  &&  .free-agents/bin/fa orch run
EOF
