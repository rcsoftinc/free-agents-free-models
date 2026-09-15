# free-agents-free-models

Run real coding work on **free models** across several agent CLIs (opencode, kilo, hermes, copilot, cursor, agy, pi) without a rate limit ever stopping you, and without two workers fighting over the same API key.

## What it is

A scheduling layer that turns free AI models into parallel build lanes. The core insight: **a bucket is one wallet — one `(provider, credential)` pair — and the wallet is the unit of rate limiting, therefore the unit of scheduling.**

Give each agent a different free API key, and you get more lanes. opencode, kilo, and hermes each ship with their own free models, and each accepts additional gateway keys. Every distinct credential is an independent quota you can run in parallel.

The scheduling unit is the **credential**, not the agent:
- **Different keys → real parallelism.** Two agents with different keys are two lanes even when running the same model.
- **The same key in two agents is ONE lane.** Running both does not go faster — it races that single key into its own rate limit. The tool detects this automatically and flags it as a shared wallet.

## How it works

You work inside an agent's TUI the way you always have. The difference is that the agent has access to parallel lanes and decides when to use them.

### Step 1: Open your TUI

Open any supported agent (opencode, kilo, hermes, pi, agy, copilot, cursor). Use tmux or herdr to see multiple windows at once — this is the recommended setup because you'll see workers being launched in their own windows.

### Step 2: Paste the coordinator prompt

Paste `.free-agents/prompts/coordinator.md` into the TUI at the start of a session. The agent reads it, runs `fa doctor` to check the machine, and from that point on it's the coordinator — it decides what to build, when to split work, and how to dispatch.

### Step 3: Work normally

Talk to the agent. Ask it to build something, research something, fix something. The agent picks the mode:
- **Small task** → does it directly in your TUI
- **Multi-part build** → plans, dispatches workers across your lanes, monitors them

### Step 4: Monitor (optional)

Open another terminal and run `fa status` to see what's running. In tmux/herdr you'll see worker windows appear and disappear as lanes are used.

When it finishes, the orchestrator prints an exit report: files changed, verification status, remaining work.

## Setup (one-time)

```sh
cd myproject
gh repo clone rcsoftinc/free-agents-free-models .free-agents
.free-agents/setup.sh
fa bootstrap          # discover credentials, install skills
fa lanes -v           # see your lanes
```

## Supported agents

| Agent | Location | Identity source | Notes |
|-------|----------|-----------------|-------|
| opencode | `/usr/local/nodejs/bin/opencode` | `~/.local/share/opencode/auth.json` | Also has zen models (hosted, no credential) |
| kilo | `/usr/local/nodejs/bin/kilo` | unauthenticated | 23 free models, no key needed |
| hermes | `hermes` on PATH | `~/.hermes/auth.json` | Multi-provider (nous, kilo, etc.) |
| copilot | `/usr/local/nodejs/bin/copilot` | GitHub OAuth | Metered (200 credits, renews monthly) |
| cursor | `/usr/local/nodejs/bin/cursor-agent` | cursor status | Metered |
| agy | `~/.local/bin/agy` | Google OAuth | 14+ free models (Gemini, Claude, GPT) |
| pi | `/usr/local/nodejs/bin/pi` | `~/.pi/agent/auth.json` | OpenRouter-backed |

## Features

| Feature | What it does |
|---------|--------------|
| **Lane detection** | Discovers every credential your agents hold, attributes each model to its wallet |
| **Parallel dispatch** | Runs independent tasks on separate lanes simultaneously |
| **Isolated execution** | Runs tasks in git worktrees to prevent collisions (`--isolate`) |
| **Fallback chain** | Tries the next healthy lane when one fails — no manual intervention |
| **Bucket circuit breaker** | Freezes a wallet after consecutive failures, skips all its models instantly |
| **Learned rankings** | Ranks models by observed outcomes per category (coding, reasoning, research) |
| **Crash-safe resume** | Append-only journal; resume any run after interruption |
| **Metered lanes** | Auto-includes copilot/cursor when detected with credits, tried last |
| **Validation gate** | Optional post-build syntax check with auto-fix loop (`--validate`) |
| **Project modes** | Per-project autonomy: strict (default), push, local |
| **Handoffs** | Tasks pass one-line summaries to dependents; no extra model call |
| **Findings** | Records what the tool noticed it handled badly; pasteable into issues |

## Metered lanes (copilot, cursor)

copilot and cursor-agent work as lanes, but their free tiers are a **depleting monthly allowance**, not an unlimited pool. They are **in by default the moment they are detected with a token** — tried **last**, after every genuinely free lane is busy or cold.

```sh
fa lanes -v                                  # shows credits remaining + renewal date
fa run --no-metered "task"                   # force them off for this run
FA_METERED=0 fa orch run                     # same, for the whole run
fa run --allow-metered "task"                # force them on even when no token was seen
```

They cannot bill you. GitHub reports `overage_permitted: false` — the allowance simply stops and renews monthly.

## Bootstrap (once per machine)

```sh
fa bootstrap    # discover credentials, probe wallets, install skills
fa doctor       # verify the machine
fa lanes -v     # what you ended up with
```

`bootstrap` reads whatever credentials your agents already hold — it never asks for keys and never stores one. The registry is **machine-wide** at `~/.local/state/free-agents`. One bootstrap serves every project on the box.

`bootstrap` installs a **daily refresh** crontab, so a fresh clone needs no manual step. `fa schedule` / `fa unschedule` manage it.

## Adding a new agent

1. Create `bin/lib/adapters/<agent>.sh` — implement `agent_identify`, `agent_models`, `agent_invoke`
2. Add to `FA_AGENTS` array in `bin/lib/adapters.sh`
3. Run `fa discover` to populate the registry

Each adapter identifies credentials, lists models (agent-prefixed TSV), and invokes the CLI with the right containment flags.

## Layout

```
.free-agents/
├── README.md
├── setup.sh                  make the parent directory a project
├── AGENTS.md                 the routing gate the coordinator follows
├── prompts/coordinator.md    paste this into any agent TUI
├── bin/
│   ├── fa                    single entry point
│   ├── buckets.sh            credential registry: lanes, discover, probe, show
│   ├── run.sh                dispatch engine: fallback, lease, breaker
│   ├── plan.sh               goal -> task graph
│   ├── orch.sh               task graph + journal-based resume
│   ├── analyze.sh            post-run journal analysis + learnings
│   └── lib/                  common.sh, deps.sh, adapters.sh, classify.sh
│       └── adapters/         one file per harness (opencode, kilo, hermes, copilot, cursor, agy, pi)
├── skills/                   skill cards, linked by `fa bootstrap`
├── state/                    the credential registry (gitignored, regenerated)
├── docs/                     SETUP.md, design history in dev/
└── test/                     stub agent CLIs + harness, for offline testing
```

## State

```
~/.local/state/free-agents/buckets.json   wallets + health   GLOBAL (learned)
<project>/.orch/tasks.json                task graph        PER PROJECT (committed)
<project>/.orch/config.yaml               project mode      PER PROJECT (committed)
<project>/.orch/journal.ndjson            append-only log   PER PROJECT
<project>/.orch/results/                  agent transcripts PER PROJECT
<project>/.orch/handoffs/                 task handoffs     PER PROJECT
<project>/.orch/worktrees/                isolated worktrees PER PROJECT (temp)
<project>/.orch/learnings.md              patterns from runs PER PROJECT (gitignored)
```

## Reproducibility

**Reproducible:** the tool, the install, the routing rules, the error taxonomy, and the *shape* of a run.

**Not reproducible, by nature:**
- **Model output.** Free models are nondeterministic; the same plan yields different code each run. Tasks declare `files` and the runner verifies them.
- **Which model serves a task.** Depends on live wallet health. The journal records what actually happened.
- **The free-model roster.** Providers add and remove free models constantly. Re-run `fa discover && fa probe` to self-heal.

A **project** is reproducible: commit `.orch/tasks.json`, and anyone with their own lanes can run `fa orch run .orch/tasks.json`.

## Tests

```sh
bash test/run_all.sh               # 16 offline suites: stub agent CLIs, fixture registry
bin/lib/classify.sh --self-test    # error taxonomy, 28 cases, offline, ~1s
bin/fa doctor                      # deps, harness CLIs+versions, presence, self-test, lanes
bin/fa lanes                       # smoke check: >0 means credentials work
DRY_RUN_LIMIT=0 bin/run.sh --dry-run   # the full candidate chain, spends nothing
```

## Docs

- **`docs/VISUAL-GUIDE.md`** — lane anatomy, run flow, orchestrator decision logic, failure handling (ASCII diagrams)
- **`docs/SETUP.md`** — install, where each agent hides its credentials, full file layout
- **`docs/dev/ALIGNMENT.md`** — the design and every finding
- **`docs/dev/SESSION.md`** — current state, invariants, bugs
- **`docs/dev/RUN-*.md`** — real project run records

## Things that cost real debugging time

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a billing refusal). Classify on output, never on exit code.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, and hermes via `HOME`.
- A route is `(agent, model, **provider**)`. `hermes -m X` resolves against its *active* provider only.
- A model can still write to an absolute path regardless of any flag. **Verify the files.**
- **The `free` field in adapter output must be literal `true` or `false`** — the parser in `buckets.sh` checks `(.[4]=="true")`, not a freeform label like `"free"`.
- **Keep TSV format strict**: 7 tab-separated fields for models (`agent provider model_arg upstream free context max_output`), 6 for identities (`agent provider wallet ident source extra`). Any literal newline in the `extra` field breaks the registry builder.
