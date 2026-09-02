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
PROJECT="${1:-$(cd "${HERE}/.." && pwd)}"
# Resolve state EXACTLY as the engine does, by sourcing the same file rather than
# recomputing the path. The two had drifted: this recomputed a machine-wide path
# while the engine used <clone>/state, so the registry line printed a path and a
# lane count that came from different places. Sourcing makes that impossible
# rather than merely fixing it once.
# shellcheck source=bin/lib/common.sh
. "${HERE}/bin/lib/common.sh"
STATE="$STATE_DIR"

say() { printf '[fa] %s\n' "$*"; }

cd "$PROJECT"
say "project: $PROJECT"
say "tool:    $HERE"

chmod +x "${HERE}"/bin/*.sh "${HERE}"/bin/lib/*.sh "${HERE}/bin/fa" \
         "${HERE}/setup.sh" 2>/dev/null || true
mkdir -p .orch
[[ -f .orch/tasks.json ]] || echo '{"tasks":[]}' > .orch/tasks.json
cat > .orch/.gitignore <<'EOF'
# Commit tasks.json - it is the specification and travels between machines.
# Everything else here records one machine's run.
journal.ndjson
results/
*.lock
EOF

# Keep the tool out of the project's git unless the user decides otherwise.
if [[ -d .git ]] && ! grep -qs '^\.free-agents/' .gitignore 2>/dev/null; then
  printf '\n# free-agents tool (clone; not part of this project)\n.free-agents/\n' >> .gitignore
  say "added .free-agents/ to your .gitignore"
fi

# The registry lives wherever the engine says it does - inside this clone by
# default, or at FREE_AGENTS_STATE if set, in which case projects share it.
if [[ -f "${STATE}/buckets.json" ]]; then
  say "registry: $("${HERE}/bin/buckets.sh" lanes 2>/dev/null || echo '?') healthy lane(s)"
  say "          ${STATE}"
else
  say "no registry yet - run once for this project:"
  say "    .free-agents/bin/fa bootstrap"
fi

cat <<EOF

Ready.

  1. Start any agent from here:  opencode | kilo | hermes | claude
  2. Paste this into it:         .free-agents/prompts/coordinator.md
  3. Then just talk normally - it picks the mode itself.

First time in a project, the coordinator will run:
    .free-agents/bin/fa bootstrap

Or drive it yourself:
    .free-agents/bin/fa lanes -v
    .free-agents/bin/fa plan "goal"  &&  .free-agents/bin/fa orch run
EOF
