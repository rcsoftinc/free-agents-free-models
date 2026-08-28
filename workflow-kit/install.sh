#!/usr/bin/env bash
# install.sh — install the agent workflow kit into a target project.
# Usage:
#   bash workflow-kit/install.sh /path/to/new/project
#
# What it installs:
#   AGENTS.md                     routing rules (read by opencode/kilo/hermes)
#   CLAUDE.md                     bridge for hermes/claude-code
#   .opencode/skills/agent-coordinator/SKILL.md   orchestrate playbook
#   bin/buckets.sh                credential-bucket registry (lanes, health)
#   bin/run.sh                    the dispatch engine (fallback, leasing, breaker)
#   bin/plan.sh                   goal -> task graph (planning WITH fallback)
#   .opencode/skills/free-agents-free-models/SKILL.md   the engine's skill card
#   bin/orch.sh                   per-project task-graph runner + resume
#   bin/lib/{common,classify}.sh  shared paths and the error taxonomy
#   bin/kilo-add-openrouter.sh    register OpenRouter free models with kilo
#   scripts/measure.sh            per-session token/cost measurement
#   scripts/taskfile-example.json sample task spec (dependency graph)
#
# NOT installed: scripts/dispatch.sh - superseded by bin/orch.sh, which schedules
# on credentials rather than agents and journals for resume.
#
# Idempotent: safe to re-run (skips existing files unless FORCE=1).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The engine lives once, at the repo root. The kit does NOT keep its own copy:
# duplicated copies were exactly the ambiguity (H4) this installer is meant to
# resolve, and a stale second copy is worse than no copy.
REPO_DIR="$(cd "${KIT_DIR}/.." && pwd)"
TARGET="${1:?usage: bash workflow-kit/install.sh /path/to/project}"
mkdir -p "$TARGET" || exit 3
cd "$TARGET"

copy() { # src -> dst (relative to target); src is resolved in the kit, then the repo
  local src="$KIT_DIR/$1" dst="$2"
  [[ -e "$src" ]] || src="$REPO_DIR/$1"
  if [[ -e "$dst" && -z "${FORCE:-}" ]]; then
    echo "[kit] skip  $dst (exists; FORCE=1 to overwrite)"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "[kit] wrote $dst"
  fi
}

copy AGENTS.md AGENTS.md
copy CLAUDE.md CLAUDE.md
copy skills/agent-coordinator/SKILL.md .opencode/skills/agent-coordinator/SKILL.md
# The engine's own skill card, so a runtime with a skill loader can find it.
copy skill/SKILL.md .opencode/skills/free-agents-free-models/SKILL.md
copy scripts/measure.sh scripts/measure.sh
copy scripts/taskfile-example.json scripts/taskfile-example.json

# The engine. AGENTS.md refers to these by path, so they must land with the rules.
for f in buckets.sh run.sh plan.sh orch.sh kilo-add-openrouter.sh \
         lib/common.sh lib/classify.sh; do
  copy "bin/$f" "bin/$f"
done

chmod +x scripts/measure.sh bin/*.sh 2>/dev/null

# The registry is GLOBAL state (a wallet's health is true for every project), so
# it is not copied per project - it is built once, here, if it does not exist.
if [[ ! -f "${XDG_STATE_HOME:-$HOME/.local/state}/free-agents/buckets.json" ]]; then
  echo "[kit] no bucket registry yet - run: bin/buckets.sh discover && bin/buckets.sh probe"
else
  echo "[kit] lanes available: $(bash bin/buckets.sh lanes 2>/dev/null || echo '?')"
fi

echo ""
echo "[kit] installed into: $TARGET"
cat <<'USAGE'
[kit] usage:
  1. Start ANY agent (opencode | kilo | hermes | claude) from this directory.
     It reads AGENTS.md and acts as the coordinator.
  2. Just describe what you want. Direct mode is the default and is right for
     almost everything.
  3. It fans out only when the work actually splits AND you have >=2 lanes.
     Check yourself with:  bash bin/buckets.sh lanes -v
  4. From a goal:
       bash bin/plan.sh "what you want built"
       bash bin/orch.sh run .orch/tasks.json
  5. Task graph by hand:
       bash bin/orch.sh run scripts/taskfile-example.json
       bash bin/orch.sh status
       bash bin/orch.sh resume        # safe after any interruption
  6. First run on a new machine:
       bash bin/buckets.sh discover && bash bin/buckets.sh probe
USAGE
