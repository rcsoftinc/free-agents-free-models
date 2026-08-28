---
name: free-agents
description: Use when running AI coding work across multiple free-model agents (opencode, kilo, hermes) without hitting rate limits - dispatching a single task with automatic fallback, or running a multi-task project in parallel across independent API credentials. Schedules on CREDENTIAL BUCKETS rather than agents, so two agents sharing one API key are correctly treated as one lane. Provides bin/buckets.sh (registry, lane count, health), bin/run.sh (single dispatch with fallback chain and circuit breaker), bin/plan.sh (goal to task graph), bin/orch.sh (task graph with crash-safe resume). Keywords: free models, rate limited, 429, fallback, multi-agent, orchestrate, parallel, opencode, kilo, hermes, openrouter, quota, resume, lanes, buckets.
---

# free-agents

Run real work on free models across several agent runtimes, without a rate limit
ever stopping you and without two workers fighting over the same API key.

## The one idea

**A bucket is one wallet: `(provider, credential)`. It is the unit of rate
limiting, so it is the unit of scheduling.**

Not the agent. Three agents configured with the same OpenRouter key are **one**
lane — running them together does not go faster, it races that one key into its
own 429. Two agents with different keys are two lanes even when they run the same
model. Bucket ids are derived from the credential, so this is detected, never
assumed: put one key in two agents and they collapse into a single lane
automatically.

## First run on a machine

```sh
bin/buckets.sh discover     # find credentials + the models each can actually reach
bin/buckets.sh probe        # prove each wallet answers
bin/buckets.sh show
```

Discovery enumerates models **per credential the agent actually holds**, never
from third-party metadata — otherwise you get routes that look real and dispatch
into nothing.

## Everyday use

```sh
bin/buckets.sh lanes            # how many independent lanes are healthy (offline)
bin/run.sh -w DIR "do a thing"  # one task, with fallback across every lane
bin/plan.sh -w DIR "goal"       # a goal -> .orch/tasks.json
bin/orch.sh run tasks.json      # run the graph; width = healthy lanes
bin/orch.sh status              # progress, from the journal
bin/orch.sh resume              # safe after ANY interruption
```

## When to fan out

Only when **both** hold:

1. ≥2 tasks with **disjoint file sets** and no dependency between them.
2. `bin/buckets.sh lanes` ≥ 2.

With one healthy lane, orchestrating a perfectly splittable job is *worse* than
doing it directly. If you cannot write each task's file boundary down, you have
one task, not several.

## What the engine handles so you don't

- **One lane per credential**, held under `flock`. Busy lanes are skipped, not queued.
- **A circuit breaker.** A wallet returning rate-limit / billing / auth errors is
  cooled down and its remaining models are skipped — instead of discovering the
  account is limited one model at a time.
- **Attribution.** A model that hangs is demoted alone. A network failure of *yours*
  is recorded nowhere: a failure you caused is not evidence about someone's model,
  and writing it down would poison the only state that compounds.
- **Containment.** Each agent needs a *different* mechanism — `opencode --dir`,
  `kilo --dir`, and hermes via `HOME` (it honours neither `cwd` nor `--in`).
- **Verification.** A task's declared `files` must exist afterwards. An agent
  reporting success is not evidence the work happened.

## Task graph

```json
{ "tasks": [
    { "id": "api", "deps": [], "files": ["src/api.js"], "category": "coding",
      "prompt": "self-contained spec - the worker sees NOTHING else" } ] }
```

`files` is enforced, not documentation: overlapping tasks never run concurrently,
and the files are checked afterwards.

## State

```
~/.local/state/free-agents/buckets.json   wallets + health   (GLOBAL - learned)
<project>/.orch/journal.ndjson            append-only run log (PER PROJECT)
```

Learning is global because a dead wallet is dead everywhere. Run state is local so
two projects can run at once. Resume replays the journal — there is no mutable
status field for a crash to leave lying.

## Install into a project

```sh
bash workflow-kit/install.sh /path/to/project
```

Installs `AGENTS.md` (the routing gate), `CLAUDE.md`, the coordinator skill, and
`bin/`. Then start any agent from that directory.

## Exit codes

`run.sh`: 0 ok · 2 exhausted · 3 setup · 4 network down · **5 no lane free (requeue —
nothing was tried and nothing is broken)**.
`orch.sh`: 0 all done · 1 something failed.

## Gotchas that cost real time

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a
  billing refusal). Classify on output, never on exit code.
- A route is `(agent, model, provider)`. `hermes -m X` resolves against its *active*
  provider only; omit `--provider` and every model from another gateway 404s and
  looks dead.
- A model can write to an absolute path regardless of any flag. Verify.
