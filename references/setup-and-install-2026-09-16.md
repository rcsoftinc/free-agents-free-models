# Setup and Auto-Install

*September 2026*

## What setup.sh does

1. Checks system dependencies (jq, curl, flock, sqlite3, timeout) — auto-installs if missing (or `FA_AUTO_INSTALL=1`)
2. Checks for missing agent CLIs (opencode, kilo, hermes, copilot, cursor, agy, pi) — prompts to install
3. Creates the `.orch/` directory and bootstraps the registry
4. Adds `.free-agents/` to `.gitignore`

## Auto-install modes

| Mode | Behavior |
|------|----------|
| Interactive (default) | Prompts for each missing dependency/agent |
| `FA_AUTO_INSTALL=1` | Installs everything without prompting |
| `--no-bootstrap` | Skips registry bootstrap (offline setup) |

## System dependencies

The engine needs: `jq`, `curl`, `flock`, `sqlite3`, `timeout`

- **Debian/Ubuntu**: `sudo apt-get install -y jq curl flock sqlite3 coreutils`
- **macOS**: `brew install jq curl flock sqlite3 coreutils`

## Agent install methods

| Agent | npm | brew | manual |
|-------|-----|------|--------|
| opencode | `npm i -g opencode-ai` | `brew install opencode-ai` | https://opencode.ai |
| kilo | `npm i -g @kilocode/kilo` | `brew install kilocode/tap/kilo` | https://github.com/glenng/kilo |
| hermes | `cargo install hermes-agent` | `brew install hermes-agent` | https://hermes-agent.nousresearch.com |
| copilot | `npm i -g @github/copilot-cli` | `brew install github/copilot-cli` | https://github.com/github/copilot-cli |
| cursor | `npm i -g @cursor-ai/agent` | `brew install cursor-agent` | https://cursor.com |
| agy | `pip3 install antigravity-cli` | `brew install antigravity-cli` | pip |
| pi | `npm i -g @anthropic-ai/pi` | `brew install pi` | https://github.com/anthropics/pi |
