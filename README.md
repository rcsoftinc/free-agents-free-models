# free-agents-free-models

Run real coding work on **free models** across several agent CLIs (opencode, kilo, hermes, copilot, cursor, agy) without a rate limit ever stopping you, and without two workers fighting over the same API key.

## What it is

A scheduling layer that turns free AI models into parallel build lanes. The core insight: **a bucket is one wallet — one `(provider, credential)` pair — and the wallet is the unit of rate limiting, therefore the unit of scheduling.**

Give each agent a different free API key, and you get more lanes. opencode, kilo, and hermes each ship with their own free models, and each accepts additional gateway keys. Every distinct credential is an independent quota you can run in parallel.

The scheduling unit is the **credential**, not the agent:
- **Different keys → real parallelism.** Two agents with different keys are two lanes even when running the same model.
- **The same key in two agents is ONE lane.** Running both does not go faster — it races that single key into its own rate limit. The tool detects this automatically and flags it as a shared wallet.

## Quick start

```sh
# Clone into your project
cd myproject
gh repo clone rcsoftinc/free-agents-free-models .free-agents
.free-agents/setup.sh

# Check your lanes
fa lanes -v

# Run a single task
fa run "add a --json flag to the status command"

# Orchestrate a multi-task build
fa plan "build a markdown site with search"
fa orch run

# Check progress
fa status
```

## Features

| Feature | What it does |
|---------|--------------|
| **Lane detection** | Discovers every credential your agents hold, attributes each model to its wallet |
| **Parallel dispatch** | Runs independent tasks on separate lanes simultaneously |
| **Fallback chain** | Tries the next healthy lane when one fails — no manual intervention |
| **Bucket circuit breaker** | Freezes a wallet after consecutive failures, skips all its models instantly |
| **Learned rankings** | Ranks models by observed outcomes per category (coding, reasoning, research) |
| **Crash-safe resume** | Append-only journal; resume any run after interruption |
| **Metered lanes** | Auto-includes copilot/cursor when detected with credits, tried last |
| **Validation gate** | Optional post-build syntax check with auto-fix loop (`--validate`) |
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

## Validation gate

After a build completes, optionally verify the output before marking the task done:

```sh
fa run --validate "task"                     # syntax check only (Level 1)
fa orch run tasks.json --validate            # validate every task in a graph
fa run --validate --validate-rounds 5 "task" # custom retry count
```

Phase 1 checks syntax (`node --check`, `python3 -m py_compile`, `shellcheck`). On failure, the same agent gets the errors and retries (default 3 rounds). Exhaustion fails the task.

## Bootstrap (once per machine)

```sh
fa bootstrap    # discover credentials, probe wallets, install skills
fa doctor       # verify the machine
fa lanes -v     # what you ended up with
```

`bootstrap` reads whatever credentials your agents already hold — it never asks for keys and never stores one. The registry is **machine-wide** at `~/.local/state/free-agents`. One bootstrap serves every project on the box.

`bootstrap` installs a **daily refresh** crontab, so a fresh clone needs no manual step. `fa schedule` / `fa unschedule` manage it.

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
│   └── lib/                     common.sh, deps.sh, adapters.sh, classify.sh, findings.sh, analyze.sh
│       └── adapters/            one file per harness (opencode, kilo, hermes, copilot, cursor, agy)
├── skills/                   skill cards, linked into the project by `fa bootstrap`
├── state/                    the credential registry (gitignored, regenerated)
├── docs/                     SETUP.md, design history in dev/
└── test/                     stub agent CLIs + harness, for offline testing
```

## State

```
~/.local/state/free-agents/buckets.json   wallets + health   GLOBAL (learned)
<project>/.orch/journal.ndjson            append-only log    PER PROJECT
<project>/.orch/learnings.md              patterns from runs PER PROJECT (gitignored)
```

Learning is global because a dead wallet is dead everywhere. Run state is local so two projects can run at once. Resume replays the journal — there is no mutable status field for a crash to leave lying.

## Reproducibility

**Reproducible:** the tool, the install, the routing rules, the error taxonomy, and the *shape* of a run.

**Not reproducible, by nature:**
- **Model output.** Free models are nondeterministic; the same plan yields different code each run. Tasks declare `files` and the runner verifies them — the *contract* is checked even though the *output* varies.
- **Which model serves a task.** Depends on live wallet health. The journal records what actually happened; it is not a plan you can replay.
- **The free-model roster.** Providers add and remove free models constantly. Re-run `fa discover && fa probe` to self-heal.

A **project** is reproducible in the sense that matters: commit the files from `fa init` plus `.orch/tasks.json`, and anyone with their own lanes can run `fa orch run .orch/tasks.json` and get equivalent work.

## Tests

```sh
bash test/run_all.sh               # 16 offline suites: stub agent CLIs, fixture registry
bin/lib/classify.sh --self-test    # error taxonomy, 28 cases, offline, ~1s
bin/fa doctor                      # deps, harness CLIs+versions, presence, self-test, lanes
bin/fa lanes                       # smoke check: >0 means credentials work
DRY_RUN_LIMIT=0 bin/run.sh --dry-run   # the full candidate chain, spends nothing
```

The suite lives in `test/` — `test/test_*.sh` suites over `test/harness.sh`, using stub agent CLIs. No suite may touch real state: `harness.sh` redirects `FREE_AGENTS_STATE` to a throwaway directory on source and refuses to run against a live registry.

## Docs

- **`docs/SETUP.md`** — install, where each agent hides its credentials, full file layout
- **`docs/dev/ALIGNMENT.md`** — the design and every finding (source of truth for contributors)
- **`docs/dev/SESSION.md`** — current state, invariants, bugs the suite found
- **`docs/dev/RUN-2026-08-30-*.md`** — real project run records
- **`docs/validation-gate-plan.md`** — validation gate design and phases

## Things that cost real debugging time

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a billing refusal). Classify on output, never on exit code.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, and hermes via `HOME` — it honours neither `cwd` nor `--in`.
- A route is `(agent, model, **provider**)`. `hermes -m X` resolves against its *active* provider only.
- A model can still write to an absolute path regardless of any flag. **Verify the files; an agent reporting success is not evidence.**
