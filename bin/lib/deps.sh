# deps.sh - the single source of truth for the system tools the engine needs.
# setup.sh, fa bootstrap and fa doctor all ask the same question, so a dependency
# added here is caught by every entry point. A missing jq once let setup.sh print
# "Ready." and then die on the first real command - the one failure mode that a
# clean-install smoke test never trips.

# git: orch.sh builds every task in a worktree and commits what lands; run.sh
# reads the project with it too. A machine without it fails at the first task.
REQUIRED_DEPS=(jq curl flock sqlite3 timeout git)

# echoes each missing dependency, one per line; empty output means all present.
missing_deps() {
  local c
  for c in "${REQUIRED_DEPS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || printf '%s\n' "$c"
  done
}