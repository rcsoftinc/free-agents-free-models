---
name: opencode-free-agents
description: Use when ANY AI agent must drive opencode headlessly from the CLI without the TUI - delegating coding/research tasks via scripts/oc.ps1 (Windows) or scripts/oc.sh (Linux) with automatic free-model fallback chains, continuing sessions across model switches, checking provider token balances, and refreshing maintained model/ranking lists from provider metadata. Keywords: opencode cli, headless, oc.ps1, oc.sh, free models, fallback, balance, tokens, rate limited, session.
---

# opencode-free-agents: headless opencode for agents

Delegate work to opencode through `scripts/oc.ps1`. It guarantees maximum
resilience: it walks a ranked chain of free models and switches models
mid-session on any failure. It exits non-zero **only** when every candidate
model is exhausted (dead / rate-limited everywhere / out of credits).

## Delegate a task (primary use)

```powershell
# from your project directory:
& "<skill-dir>\scripts\oc.ps1" "Fix the failing test in src/auth.spec.ts"
& "<skill-dir>\scripts\oc.ps1" "Refactor the db layer" -Category coding
```

- `-Category` one of: `coding` (default-quality code work), `reasoning`,
  `research`, `general`, `fast` (quick/cheap questions).
- Output: model's answer on stdout; last line block is machine-readable:

  ```
  ---OC-META---
  {"session":"ses_...","model":"...","attempts":1,"category":"coding"}
  ```

- Exit codes: `0` success | `2` ALL models exhausted (report to user; do not
  retry blindly) | `3` bootstrap error.

## Continue an existing conversation

Model switches keep full history (verified). Always resume via oc.ps1 so a
quota failure transparently moves the same conversation to another model:

```powershell
& oc.ps1 "Continue with step 2" -SessionId ses_xxx   # specific session
& oc.ps1 "go on" -Continue                           # most recent session
```

Other passthroughs: `-Agent build`, `-NoAuto` (disable permission
auto-approval), `-TimeoutSeconds N`, `-Json` (raw event stream), `-Model`
(pin a specific model first in the chain).

## Permissions

oc.ps1 runs opencode with `--auto` by default (full permissions: edits,
bash, etc.). Only pass `-NoAuto` when the delegated task must be sandboxed.

## Check tokens/balance before long jobs

```powershell
& oc.ps1-dir\scripts\get-balance.ps1            # cached 60 min
& ...\get-balance.ps1 -Force -AsJson            # fresh, machine-readable
```

Semantics (verified): OpenRouter exposes a GLOBAL per-key limit plus separate
per-model DAILY request caps on `:free` models (~50 req/day free tier; those
daily caps are invisible to the API - they appear as rate-limit errors at
runtime). freemodel has no public endpoint: "Unauthorized: Insufficient
balance" at runtime means drained.

## Maintenance protocol (keep the list truthful)

- data/models.json = live status of every candidate (ok | rate_limited |
  no_credits | timeout | context_overflow | auth_error | dead + latency +
  rolling success counters).
- data/rankings.json = ordered candidates per category (best-first), rebuilt
  from scripts/rankings-seed.json + observed stats.
- oc.ps1 auto-refreshes both when older than `staleHours` (24h default).
- Force maintenance: `scripts\refresh.ps1 -Force` (balance -> discover models
  from metadata -> rebuild rankings). Metadata queries are instant (~2s).
- To add a free model not marked free in metadata (e.g. unlimited provider
  specials like Ox Alpha), append its id to data/manual-overrides.txt, then
  run refresh.

## Failure taxonomy (runtime classification)

| Pattern in stderr                              | Meaning        | Auto-retry after |
|-----------------------------------------------|----------------|------------------|
| `temporarily rate-limited upstream` / 429      | rate_limited   | 30 min           |
| `Unauthorized: Insufficient balance`           | no_credits     | 24 h             |
| `UnknownError` / unexpected server error       | dead           | 72 h             |
| killed after timeout                           | timeout        | 10 min           |
| context length / too large                     | never retried  | -                |

## Files

```
SKILL.md                  this file
README.md                 porting guide + Linux/server quickstart
GETTING-STARTED.md        full setup runbook (new machine, from scratch)
.env.example              credential template (generic PROVIDER_N blocks)
scripts/
  oc.ps1 / oc.sh               THE entry points (Windows | Linux)
  install.sh                   one-shot setup: deps + opencode + keys + skill install
  bootstrap.ps1 / bootstrap.sh .env -> auth.json bridge (Windows | Linux)
  refresh.ps1 / .sh            balance + discover models + rebuild rankings
  classify-error.sh            shared error classification (rate_limited, no_credits, etc.)
  get-balance.ps1 / .sh        provider credit/quota status (cached)
  find-free-providers.sh       discover new free providers via models.dev
  config.json                  intervals, timeouts, retry windows
  rankings-seed.json           curated initial per-category order

data/
  models.json                  free model metadata (discovered from opencode models --verbose)
  rankings.json                generated category chains
  balance-cache.json           cached provider balance (git-ignored)
  manual-overrides.txt         user manual free-model entries
```

## Linux / fresh server setup

```bash
sudo apt install -y jq curl && opencode --version   # prerequisites
bash <skill>/scripts/install.sh /path/to/project     # step zero: installs skill,
                                                     # merges .env -> auth.json, discovers models
cp <skill>/.env.example <project>/.env && nano <project>/.env
```

`.env` resolution order (first found wins): `$PWD/.env` → skill folder →
`~/.config/opencode-free-agents/.env` → none = keep existing credentials.
Keys are merged into opencode's own `~/.local/share/opencode/auth.json`
(additive-only; backups kept; chmod 600). Verify anytime:
`bash scripts/bootstrap.sh --self-test`.
Discover additional free providers: `scripts/find-free-providers.sh`
(e.g., NVIDIA alone exposes ~98 free models via `NVIDIA_API_KEY`).
