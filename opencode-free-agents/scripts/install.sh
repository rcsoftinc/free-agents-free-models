#!/usr/bin/env bash
# ============================================================================
# install.sh — one-shot setup + install for opencode-free-agents
#
#   bash /path/to/opencode-free-agents/scripts/install.sh [project-dir]
#
# What it does:
#   1. Checks / installs system deps (curl, jq, git)
#   2. Checks / installs opencode
#   3. Detects missing API keys, prompts for them (all optional)
#   4. Installs the skill into <project>/.opencode/skills/opencode-free-agents
#      (symlink when possible, copy with --copy)
#   5. Runs bootstrap.sh (.env -> auth.json) + initial refresh
#
# Safe to re-run — idempotent at every step.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="link"
TARGET_PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy) MODE="copy"; shift ;;
    *) TARGET_PROJECT="$1"; shift ;;
  esac
done

[[ -n "$TARGET_PROJECT" ]] || TARGET_PROJECT="$PWD"
TARGET_PROJECT="$(cd "$TARGET_PROJECT" && pwd)"
TARGET="$TARGET_PROJECT/.opencode/skills/opencode-free-agents"
ENV_FILE="$TARGET_PROJECT/.env"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# ============================================================================
# 1. System dependencies
# ============================================================================
log "checking system dependencies..."

install_if_missing() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" &>/dev/null; then
    log "$cmd not found — installing $pkg..."
    if command -v apt &>/dev/null; then
      sudo apt update -qq && sudo apt install -y -qq "$pkg"
    elif command -v yum &>/dev/null; then
      sudo yum install -y "$pkg"
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y "$pkg"
    else
      die "cannot auto-install $pkg — install $cmd manually"
    fi
  fi
}

install_if_missing curl curl
install_if_missing jq jq
install_if_missing git git

log "system dependencies OK"

# ============================================================================
# 2. opencode
# ============================================================================
log "checking opencode..."

if ! command -v opencode &>/dev/null; then
  log "opencode not found — installing..."
  curl -fsSL https://opencode.ai/install | bash

  export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"
  if [[ -f "$HOME/.bashrc" ]]; then
    set +euo pipefail
    source "$HOME/.bashrc" 2>/dev/null || true
    set -euo pipefail
  fi

  if ! command -v opencode &>/dev/null; then
    die "opencode install failed — install manually: curl -fsSL https://opencode.ai/install | bash"
  fi
fi

log "opencode OK ($(command -v opencode))"

# ============================================================================
# 3. API keys — detect missing, prompt, write .env
# ============================================================================
AUTH_FILE="$HOME/.local/share/opencode/auth.json"

declare -A PROV_ID=([OPENROUTER_API_KEY]="openrouter" [FREEMODEL_API_KEY]="freemodel" [KILO_GATEWAY_API_KEY]="kilo")
declare -A PROV_HINT=(
  [OPENROUTER_API_KEY]="sk-or-v1-..."
  [FREEMODEL_API_KEY]="fe_..."
  [KILO_GATEWAY_API_KEY]="your-kilo-api-key"
)

has_key() {
  local envvar="$1"
  if [[ -f "$AUTH_FILE" ]]; then
    local pid="${PROV_ID[$envvar]}"
    local k
    k="$(jq -r --arg p "$pid" '.[$p].key // ""' "$AUTH_FILE" 2>/dev/null || echo "")"
    if [[ -n "$k" ]]; then return 0; fi
  fi
  if [[ -f "$ENV_FILE" ]]; then
    if grep -qE "^${envvar}=.+" "$ENV_FILE" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

PROMPTED=0
for envvar in OPENROUTER_API_KEY FREEMODEL_API_KEY KILO_GATEWAY_API_KEY; do
  if ! has_key "$envvar"; then
    if [[ $PROMPTED -eq 0 ]]; then
      echo ""
      log "no API keys detected — add as many as you have (press Enter to skip any)"
      echo ""
      PROMPTED=1
    fi
    read -rp "${envvar%%_API_KEY} API key (${PROV_HINT[$envvar]}): " user_key
    user_key="$(echo "$user_key" | xargs)"
    if [[ -n "$user_key" ]]; then
      if [[ -f "$ENV_FILE" ]]; then
        printf '%s=%s\n' "$envvar" "$user_key" >> "$ENV_FILE"
      else
        {
          printf '# opencode-free-agents credentials\n'
          printf '# see .env.example for all options\n\n'
          printf '%s=%s\n' "$envvar" "$user_key"
        } > "$ENV_FILE"
      fi
      log "$envvar saved"
    else
      log "$envvar skipped"
    fi
  fi
done

if [[ $PROMPTED -eq 0 ]]; then
  log "all known providers already configured"
fi

# ============================================================================
# 4. Install skill into project
# ============================================================================
log "skill source : $PKG_ROOT"
log "project      : $TARGET_PROJECT"

mkdir -p "$TARGET_PROJECT/.opencode/skills"

FRESH_INSTALL=0
install_skill() {
  FRESH_INSTALL=1
  if [[ "$MODE" == "link" ]]; then
    ln -s "$PKG_ROOT" "$TARGET"
  else
    mkdir -p "$TARGET"
    cp -r "$PKG_ROOT/SKILL.md" "$PKG_ROOT/scripts" "$PKG_ROOT/data" "$PKG_ROOT/.env.example" "$PKG_ROOT/README.md" "$TARGET/" 2>/dev/null || true
  fi
}

if [[ -e "$TARGET" && "$MODE" == "link" && "$(readlink "$TARGET" 2>/dev/null)" == "$PKG_ROOT" ]]; then
  log "symlink already up to date"
else
  [[ -e "$TARGET" ]] && { log "target exists - refreshing contents"; rm -rf "$TARGET"; }
  install_skill
fi

log "installed at: $TARGET"

if [[ ! -f "$TARGET_PROJECT/.gitignore" ]] || ! grep -qE '^\.env$' "$TARGET_PROJECT/.gitignore" 2>/dev/null; then
  echo "" >> "$TARGET_PROJECT/.gitignore" 2>/dev/null || touch "$TARGET_PROJECT/.gitignore"
  printf '# opencode-free-agents skill credentials\n.env\n' >> "$TARGET_PROJECT/.gitignore"
  log "added '.env' to .gitignore"
fi

# ============================================================================
# 5. Bootstrap + refresh
# ============================================================================
cd "$TARGET_PROJECT"

if [[ $FRESH_INSTALL -eq 1 || $PROMPTED -eq 1 ]]; then
  # Fresh install or new keys: merge .env, then do a full forced refresh from scratch.
  bash "$PKG_ROOT/scripts/bootstrap.sh" --no-refresh
  bash "$PKG_ROOT/scripts/refresh.sh" --force
else
  # Re-run: normal bootstrap (handles .env merge + conditional refresh).
  bash "$PKG_ROOT/scripts/bootstrap.sh"
fi

echo ""
log "=== SETUP COMPLETE ==="
echo ""
echo "Test it:"
echo "  $PKG_ROOT/scripts/oc.sh \"Reply OK\""
echo ""
echo "Useful commands:"
echo "  $PKG_ROOT/scripts/oc.sh \"Refactor db layer\" -c coding"
echo "  $PKG_ROOT/scripts/get-balance.sh          # check credits"
echo "  $PKG_ROOT/scripts/find-free-providers.sh   # discover more free providers"
echo "  $PKG_ROOT/scripts/refresh.sh --force       # refresh all models"
exit 0
