#!/usr/bin/env bash
set -euo pipefail

# install.sh - install free-agents-free-models ONCE on this machine.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash
# or, from a clone:
#   ./install.sh
#
# Installs the tool to ~/.local/share/free-agents-free-models and puts `fa` on
# PATH. It does NOT go into your project: credentials and learned wallet health
# are machine-wide, so one install serves every project. A project gets only its
# routing rules (`fa init`) and its own run journal.
#
# Env: FA_HOME (install dir), FA_BIN (symlink dir), FA_REPO (git URL), FA_REF (branch)

FA_HOME="${FA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/free-agents-free-models}"
FA_BIN="${FA_BIN:-$HOME/.local/bin}"
FA_REPO="${FA_REPO:-}"
FA_REF="${FA_REF:-main}"

say()  { printf '[fa] %s\n' "$*"; }
die()  { printf '[fa] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- dependencies -----------------------------------------------------------
missing=()
for c in git jq curl; do have "$c" || missing+=("$c"); done
# flock and timeout are in util-linux/coreutils; sqlite3 is only needed for kilo.
for c in flock timeout; do have "$c" || missing+=("$c"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  say "missing: ${missing[*]}"
  if have apt-get; then
    say "installing (sudo apt-get)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq git jq curl util-linux coreutils sqlite3 \
      || die "could not install dependencies - install them manually: ${missing[*]}"
  else
    die "install these first: ${missing[*]}"
  fi
fi

# --- fetch or update --------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SELF_DIR}/bin" && -f "${SELF_DIR}/bin/fa" ]]; then
  # Running from a clone: install in place.
  FA_HOME="$SELF_DIR"
  say "installing from this clone: $FA_HOME"
elif [[ -d "${FA_HOME}/.git" ]]; then
  say "updating $FA_HOME"
  git -C "$FA_HOME" pull --ff-only || die "update failed"
else
  [[ -n "$FA_REPO" ]] || die "set FA_REPO=https://github.com/OWNER/REPO.git (or run from a clone)"
  say "cloning into $FA_HOME"
  git clone --depth 1 -b "$FA_REF" "$FA_REPO" "$FA_HOME" || die "clone failed"
fi

chmod +x "${FA_HOME}"/bin/*.sh "${FA_HOME}/bin/fa" 2>/dev/null || true

# --- put `fa` on PATH -------------------------------------------------------
mkdir -p "$FA_BIN"
ln -sfn "${FA_HOME}/bin/fa" "${FA_BIN}/fa"
say "linked ${FA_BIN}/fa"

case ":${PATH}:" in
  *":${FA_BIN}:"*) ;;
  *) say "NOTE: ${FA_BIN} is not on PATH. Add to your shell rc:"
     printf '\n    export PATH="%s:$PATH"\n\n' "$FA_BIN" ;;
esac

# --- credentials ------------------------------------------------------------
# Deliberately NOT automated. Keys live in each agent's own config, they are
# secrets, and guessing where they belong is how a key ends up in the wrong file.
say ""
say "Next:"
say "  1. Make sure at least one agent CLI is installed and authenticated:"
say "       opencode   kilo   hermes"
say "     More independent credentials = more parallel lanes. The SAME key in two"
say "     agents is ONE lane, not two."
say "  2. Build the credential registry:"
say "       fa discover && fa probe"
say "  3. Check the machine is ready:"
say "       fa doctor"
say "  4. In any project:"
say "       cd ~/projects/thing && fa init"
say "       fa go \"what you want built\""
