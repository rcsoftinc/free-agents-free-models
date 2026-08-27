# Getting Started

## One-liner (Linux / macOS)

```bash
mkdir my-project && cd my-project
git init
git clone <your-repo-url> opencode-free-agents
bash opencode-free-agents/scripts/install.sh
```

That's it. The script handles everything:
- Installs system dependencies (curl, jq, git) if missing
- Installs opencode if missing
- Detects which API keys you have, prompts for any missing ones
- Installs the skill, merges keys, discovers free models (~2-3 seconds)

## What you need

- A Linux, macOS, or WSL terminal
- At least one free API key (pick any):

| Provider | Where to get it | Key format |
|---|---|---|
| **OpenRouter** | [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys) | `sk-or-v1-...` |
| **FreeModel** | [freemodel.dev](https://freemodel.dev) | `fe_...` |
| **Kilo Gateway** | [kilo.ai](https://kilo.ai) | your API key |

## After setup

```bash
# test it
opencode-free-agents/scripts/oc.sh "Reply OK"

# delegate a task
opencode-free-agents/scripts/oc.sh "Fix the failing test in src/auth.spec.ts" -c coding

# check credits
opencode-free-agents/scripts/get-balance.sh

# discover more free providers (NVIDIA has ~98 free models)
bash opencode-free-agents/scripts/find-free-providers.sh

# force refresh all models
opencode-free-agents/scripts/refresh.sh --force

# verify error classification
bash opencode-free-agents/scripts/classify-error.sh --self-test
```

## Manual setup (if you prefer)

If you don't want to use install.sh, you can do it step by step:

```bash
# install dependencies
sudo apt install -y curl jq git
curl -fsSL https://opencode.ai/install | bash

# clone the skill
git clone <your-repo-url> ~/opencode-free-agents

# set up your project
cd /path/to/your/project
cp ~/opencode-free-agents/.env.example .env
nano .env                        # paste your API keys

# install + bootstrap
bash ~/opencode-free-agents/scripts/install.sh .
```

## Windows (PowerShell)

```powershell
# install opencode (pick one)
choco install opencode
npm install -g opencode-ai

# clone and run
git clone <your-repo-url> C:\path\to\opencode-free-agents
powershell -ExecutionPolicy Bypass -File C:\path\to\opencode-free-agents\scripts\bootstrap.ps1
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `opencode: command not found` | Run `source ~/.bashrc` or re-login; or reinstall: `curl -fsSL https://opencode.ai/install \| bash` |
| `jq: command not found` | `sudo apt install -y jq` |
| Bootstrap says "no .env found" | Make sure `.env` is in your project root (where you ran install.sh) |
| Models showing `no_credits` | Your provider balance is low; add credits at the provider dashboard |
| Refresh is slow | First run was slow (~5-10 min) because it probed each model. Now uses metadata (~2-3s). |
| Want to test without touching real files | `bash scripts/bootstrap.sh --self-test` |
| Error classification not working | `bash scripts/classify-error.sh --self-test` (13 test cases) |
