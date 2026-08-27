#!/usr/bin/env bash
# install.sh — install the agent workflow kit into a target project.
# Usage:
#   bash workflow-kit/install.sh /path/to/new/project
#
# What it installs:
#   AGENTS.md                     routing rules (read by opencode/kilo/hermes)
#   CLAUDE.md                     bridge for hermes/claude-code
#   .opencode/skills/agent-coordinator/SKILL.md   orchestrate playbook
#   scripts/dispatch.sh           isolated-session orchestrator + audit
#   scripts/measure.sh            per-session token/cost measurement
#   scripts/taskfile-example.json sample task spec (dependency graph)
#
# Idempotent: safe to re-run (skips existing files unless FORCE=1).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: bash workflow-kit/install.sh /path/to/project}"
mkdir -p "$TARGET" || exit 3
cd "$TARGET"

copy() { # src -> dst (relative to target)
  local src="$KIT_DIR/$1" dst="$2"
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
copy scripts/dispatch.sh scripts/dispatch.sh
copy scripts/measure.sh scripts/measure.sh
copy scripts/taskfile-example.json scripts/taskfile-example.json

chmod +x scripts/dispatch.sh scripts/measure.sh 2>/dev/null

echo ""
echo "[kit] installed into: $(pwd)"
echo "[kit] usage:"
echo "  1. start ANY agent (opencode | kilo | hermes) from here  -> reads AGENTS.md"
echo "  2. small task: just describe it (direct mode)"
echo "  3. big project: say 'use agents' or '>>coordinator'      -> orchestrate mode"
echo "  4. headless dispatch:  bash scripts/dispatch.sh <taskfile.json>"
echo "[kit] per-task agent+model+token audit -> dispatch-report.json"