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

## Visual Guide

### 1. What is a lane?

A lane is one wallet — one `(provider, credential)` pair. The wallet is the unit of rate limiting, therefore the unit of scheduling.

```
┌─────────────────────────────────────────────────────────────┐
│  LANE = one wallet = one (provider, credential) pair       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Credential  │    │    Models    │    │    Health    │  │
│  │              │    │              │    │              │  │
│  │  provider:   │───▶│  model_a     │    │  state: ok   │  │
│  │  openrouter  │    │  model_b     │    │  failures: 0 │  │
│  │  fp: 845a..  │    │  model_c     │    │  cooldown: - │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│                                                             │
│  Different keys = different lanes = real parallelism        │
│  Same key in two agents = ONE lane = they race each other   │
└─────────────────────────────────────────────────────────────┘
```

#### Credential collapse

```
  hermes ──▶ nous:9162a7f63a81 ──┐
                                 ├──▶ SAME LANE (one wallet)
  opencode ──▶ nous:9162a7f63a81 ─┘

  opencode ──▶ openrouter:845a3f963b8a ──┐
                                          ├──▶ DIFFERENT LANES (parallel)
  pi ──▶ openrouter:131083dc00f2 ────────┘
```

### 2. What happens when you run a task?

```
  ┌─────────┐
  │  fa run │
  │ "task"  │
  └────┬────┘
       │
       ▼
  ┌──────────────┐     ┌──────────────┐
  │  PLAN        │────▶│  Self-       │
  │  goal → spec │     │  contained   │
  └──────┬───────┘     │  task spec   │
         │             └──────────────┘
         ▼
  ┌──────────────┐
  │  DISPATCH    │
  │  pick lane   │
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐     ┌──────────────┐
  │  INVOKE      │────▶│  Agent runs  │
  │  agent + model│     │  the task    │
  └──────┬───────┘     └──────────────┘
         │
         ▼
  ┌──────────────┐
  │  CLASSIFY    │
  │  output      │
  └──────┬───────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌───────┐ ┌───────┐
│  OK   │ │ FAIL  │
└───┬───┘ └───┬───┘
    │         │
    │         ▼
    │    ┌──────────┐     ┌──────────────┐
    │    │  RETRY   │────▶│  Same lane,  │
    │    │  same lane│     │  same model  │
    │    └────┬─────┘     └──────────────┘
    │         │
    │    ┌────┴────┐
    │    │         │
    │    ▼         ▼
    │ ┌───────┐ ┌──────────┐
    │ │  OK   │ │ EXHAUSTED│
    │ └───────┘ └────┬─────┘
    │                │
    │                ▼
    │         ┌──────────────┐
    │         │  FALLBACK    │
    │         │  next lane   │
    │         └──────┬───────┘
    │                │
    │           ┌────┴────┐
    │           │         │
    │           ▼         ▼
    │        ┌───────┐ ┌───────┐
    │        │  OK   │ │ FAIL  │──▶ circuit breaker
    │        └───────┘ └───────┘    (cooldown wallet)
    │
    ▼
┌──────────┐
│  DONE    │
│  report  │
└──────────┘
```

### 3. How does the orchestrator think?

```
                    ┌─────────────────┐
                    │  fa orch run    │
                    │  tasks.json     │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Work splits?   │
                    │  ≥2 tasks,      │
                    │  disjoint files │
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                   YES               NO
                    │                 │
                    ▼                 ▼
           ┌───────────────┐  ┌───────────────┐
           │  Lanes ≥ 2?   │  │  WORK DIRECT  │
           │  fa lanes -v  │  │  (one task)   │
           └───────┬───────┘  └───────────────┘
                   │
           ┌───────┴───────┐
           │               │
          YES              NO
           │               │
           ▼               ▼
    ┌──────────────┐  ┌──────────────┐
    │  DISPATCH    │  │  WORK DIRECT │
    │  parallel    │  │  (one lane)  │
    │  + isolation │  └──────────────┘
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │  PER TASK:   │
    │  pick lane   │
    │  by ranking  │
    │  + health    │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │  RUN         │
    │  agent +     │
    │  model       │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │  VERIFY      │
    │  files exist │
    │  tests pass  │
    └──────┬───────┘
           │
    ┌──────┴──────┐
    │             │
   FAIL          PASS
    │             │
    ▼             ▼
  ┌──────┐   ┌──────────┐
  │RETRY │   │  MERGE   │
  │or    │   │  worktree│
  │FALLB.│   │  report  │
  └──────┘   └──────────┘
```

### 4. Concrete scenario: "Build a React dashboard"

Using the actual registry state (8 lanes, 163 free models):

```
┌─────────────────────────────────────────────────────────────────┐
│  REGISTRY: 8 lanes, 163 free models                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  antigravity:67da9cad9d70  ── agy        14 free (Gemini/Claude)│
│  opencode:zen             ── opencode    4 free (hosted)        │
│  openrouter:845a3f963b8a  ── opencode   27 free (OR key 1)     │
│  openrouter:131083dc00f2  ── pi         86 free (OR key 2)     │
│  kilo:anon                ── kilo       23 free (no key)       │
│  nous:6b7db10dba77        ── hermes      7 free (Nous key)     │
│  copilot:bbc7cfd0e9b0     ── copilot     1 (metered, last)     │
│  cursor:eca81fa11190      ── cursor      1 (metered, last)     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

SCENARIO: "Build a React dashboard with tests"

┌─────────────────────────────────────────────────────────────────┐
│  STEP 1: PLAN                                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │ Task A: API │  │ Task B: UI  │  │ Task C: Tests│            │
│  │ src/api.js  │  │ src/components│ │ src/tests/  │            │
│  │ deps: []    │  │ deps: [A]   │  │ deps: [A,B] │             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
│         │                │                │                     │
│         ▼                ▼                ▼                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  STEP 2: DISPATCH (parallel where possible)             │   │
│  │                                                         │   │
│  │  Task A ──▶ openrouter:131083dc00f2 (pi, 86 models)    │   │
│  │  Task B ──▶ opencode:zen (hosted, no credential)       │   │
│  │  Task C ──▶ kilo:anon (23 models, no key)             │   │
│  │                                                         │   │
│  │  All three run SIMULTANEOUSLY on independent wallets   │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  STEP 3: EXECUTE                                         │   │
│  │                                                         │   │
│  │  pi runs api.js ──────────────▶ ✓ success               │   │
│  │  opencode runs components ────▶ ✓ success               │   │
│  │  kilo runs tests ─────────────▶ ✗ failure               │   │
│  │       │                                                 │   │
│  │       └──▶ FALLBACK to next lane: nous:6b7db10dba77     │   │
│  │           hermes runs tests ──▶ ✓ success               │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  STEP 4: VERIFY & REPORT                                │   │
│  │                                                         │   │
│  │  ✓ api.js exists, syntax OK                             │   │
│  │  ✓ components/ exists, syntax OK                        │   │
│  │  ✓ tests/ exists, syntax OK                             │   │
│  │                                                         │   │
│  │  Files changed: 12                                      │   │
│  │  Verification: all pass                                 │   │
│  │  Remaining work: none                                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5. Failure handling: "Keep things running no matter what"

```
┌─────────────────────────────────────────────────────────────────┐
│  FAILURE MODES AND RESPONSES                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. MODEL RETURNS GARBAGE                                       │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ classify │───▶│  RETRY   │───▶│  same    │              │
│     │ = soft   │    │  same    │    │  lane    │              │
│     └──────────┘    │  lane    │    └──────────┘              │
│                     └──────────┘                                │
│                                                                 │
│  2. RATE LIMITED (429)                                          │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ classify │───▶│ FALLBACK │───▶│ next     │              │
│     │ = 429    │    │ next lane│    │ healthy  │              │
│     └──────────┘    └──────────┘    └──────────┘              │
│                                                                 │
│  3. CREDENTIAL DEAD (401, billing)                              │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ classify │───▶│ FALLBACK │───▶│ next     │              │
│     │ = auth   │    │ skip lane│    │ lane     │              │
│     └──────────┘    └──────────┘    └──────────┘              │
│                                                                 │
│  4. CONSECUTIVE FAILURES                                        │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ 3 fails  │───▶│ CIRCUIT  │───▶│ FREEZE   │              │
│     │ in a row │    │ BREAKER  │    │ wallet   │              │
│     └──────────┘    └──────────┘    │ 15 min   │              │
│                                     └──────────┘              │
│                                                                 │
│  5. ALL LANES EXHAUSTED                                         │
│     ┌──────────┐    ┌──────────┐                               │
│     │ no lanes │───▶│ TASK     │                               │
│     │ healthy  │    │ FAILS    │                               │
│     └──────────┘    └──────────┘                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6. Metered lanes: when they're used

```
┌─────────────────────────────────────────────────────────────────┐
│  LANE SELECTION ORDER (auto mode)                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Free lanes (unlimited)                                      │
│     ┌─────────────────────────────────────────────────────┐    │
│     │  kilo:anon, opencode:zen, openrouter:*, nous:*,     │    │
│     │  antigravity:*, pi:*                                │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
│  2. Metered lanes (depleting)                                   │
│     ┌─────────────────────────────────────────────────────┐    │
│     │  copilot:bbc7cfd0e9b0 (200 credits, renews Oct 1)  │    │
│     │  cursor:eca81fa11190 (metered)                     │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
│  Metered lanes are tried LAST, only when all free lanes are     │
│  busy, cold, or exhausted. They cannot bill you — they stop     │
│  when credits run out and renew monthly.                        │
│                                                                 │
│  --no-metered  → skip step 2 entirely                          │
│  --allow-metered → force step 2 even if free lanes available   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Setup (one-time)

```sh
cd myproject
gh repo clone rcsoftinc/free-agents-free-models .free-agents
.free-agents/setup.sh
fa bootstrap          # discover credentials, install skills
fa lanes -v           # see your lanes
```

## Agent roles

Each agent brings something different beyond just its tooling — different model access, different containment semantics, different failure modes. Here's what each one adds to your pool:

### opencode

Two distinct wallets. First, **zen models** — hosted by opencode itself, no credential needed, 4 free models (zen). Second, any OpenRouter key you configure, giving you access to 200+ community models. Opencode uses `--dir` for containment (real process isolation), which makes it one of the safest lanes for parallel work. Its model list includes context size and max output, so the scheduler can match task complexity to model capacity.

### kilo

The **biggest unauthenticated pool** — 23 free models with no key needed at all. It also accepts OpenRouter keys via `kilo.jsonc`, so you can stack it with a different key than opencode to double your OpenRouter lanes. Kilo uses `--dir` for containment. Its models include output modality (text, audio, etc.), which helps the scheduler avoid sending text tasks to audio models. Watch for: it can be verbose — classify on output patterns, not exit code.

### hermes

The **multi-provider generalist**. It reaches Nous, Kilo gateway, OpenRouter, and others through a single CLI — each becomes a separate lane. Hermes is the only agent that reads gateway-specific free signals (isFree, zero pricing, `:free` suffix), so it surfaces models others miss. Containment is different: it ignores `--dir`, so fa uses `HOME` redirection instead. Its OAuth tokens rotate hourly — the registry fingerprints the stable subject, not the token.

### pi

The **high-volume lane**. Pi backed by OpenRouter gives you 353 models (86 free), making it the largest single bucket. It's a strong general-purpose worker: `--add-dir` containment, straightforward `--model` + `--print` invocation, standard OpenRouter catalog with clear context sizes. The sheer volume means when other lanes are busy or cold, pi almost always has capacity. Watch for: pi doesn't publish `:free` suffixes — the adapter detects `:free` and `:batch` variants.

### agy (Antigravity)

The **Google-quality lane** with 14 free models (Gemini, Claude, GPT-OSS). Uses Google OAuth — the adapter fingerprints the refresh token (stable) so token rotation doesn't create duplicate lanes. Uses `--add-dir` for containment. Useful when you want models from Google's ecosystem without managing an API key directly. The `--print` flag makes it non-interactive and script-friendly.

### copilot

The **metered safety net**. 200 monthly credits, renews monthly, `overage_permitted: false` — it stops rather than bills. Auto-routed (no model selector, one bucket with "auto"). Tried last by default, only when all free lanes are busy or cold. Uses `--allow-all` + `--add-dir` for containment. Its strength is not volume but reliability — GitHub's models tend to be well-tested and current.

### cursor

The **second metered lane**, similar to copilot: auto-routed, depleting monthly allowance, tried last. Reports account email via `cursor-agent status`. Uses `-f` to trust the directory (it refuses to run headless otherwise). Like copilot, its value is as a fallback when free lanes are exhausted — not as a primary worker.

## Orchestration roles

When the coordinator decides a task splits into independent pieces, three conceptual roles emerge. These aren't tied to specific agents — they're about who does what during a run.

### Coordinator (you, in the TUI)

The agent you're talking to. It decides what to build, keeps small work for itself, and dispatches the substantial, self-contained pieces to workers.

Its job is to:
- **Hold context** — your TUI session already has the project loaded. Don't dispatch a task that requires reading code you can just hand the worker in the spec.
- **Write self-contained specs** — a worker receives a string, not a repository. If it needs to match existing style, quote the relevant code into the prompt.
- **Guard the gate** — only split when 2+ tasks have disjoint file sets AND 2+ lanes are available. With one lane, working directly is strictly better.
- **Keep the small things** — one-line fixes, renames, config tweaks, glue files cost a lane more than they cost you. If writing the spec takes about as long as doing the work, do the work.
- **Record judgment** — the tool sees outputs, not intent. When a spec was ambiguous, a split caused a collision, or a worker missed the point, write it with `fa findings`. Those observations are lost when the session closes.

### Workers (dispatched agents)

Cold-start agents that receive a self-contained prompt, run it, and report back. They don't talk to you, don't see other tasks, and can't ask questions.

Their constraints:
- **No shared state** — each worker gets its own worktree (when `--isolate` is on) and sees nothing of the others.
- **No conversation** — the prompt must be complete. The worker never sees this conversation.
- **Declared files are enforced** — overlapping tasks never run together. Files are checked after execution; byte-identical files count as unverified.
- **Category matters** — tasks declare a category (`coding`, `reasoning`, `research`, `general`, `fast`). The scheduler tracks which models succeed per category and ranks future picks accordingly. A model good at coding may be bad at research — the category keeps that signal separate.

### Work that waits

Some tasks can't be done yet: they need credentials you don't have, a service that isn't provisioned, or a decision only you can make. Mark them with a `blocked` field — they're never dispatched, never counted as failures, and anything depending on them waits with them. When you unblock them, `fa resume` picks them up. The coordinator should ask before assuming something is blocked.

### Categories of work

The `category` field on a task isn't cosmetic — it drives model selection:

| Category | Best for | What the scheduler learns |
|----------|----------|---------------------------|
| **coding** | Implementation, features, bug fixes | Which models write correct code, respect file boundaries, follow specs |
| **reasoning** | Debugging, root cause analysis, design decisions | Which models reason about tradeoffs, trace logic, explain clearly |
| **research** | Comparing options, evaluating approaches, reading docs | Which models synthesize information, cite sources, avoid hallucination |
| **general** | Mixed tasks that don't fit above | Overall model quality across varied work |
| **fast** | Simple queries, formatting, single-file tweaks | Which models are quick without being sloppy |

### Project modes

How much autonomy workers get, per project:

| Mode | When to use | Behavior |
|------|-------------|----------|
| **strict** (default) | Unreviewed code, shared branches | Workers propose changes, coordinator reviews before merging |
| **push** | Personal projects, trusted lanes | Workers merge their own worktrees after passing verification |
| **local** | Experimental work, scratch branches | Workers operate in the main working tree, no isolation |

Set with `fa config --mode push` or by editing `.orch/config.yaml`. The orchestrator (`fa orch run`) reads the mode and adjusts isolation behavior accordingly.

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

- **`docs/SETUP.md`** — install, where each agent hides its credentials, full file layout
- **`docs/dev/ALIGNMENT.md`** — the design and every finding
- **`docs/dev/SESSION.md`** — current state, invariants, bugs
- **`docs/dev/RUN-*.md`** — real project run records

## Pitfalls

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a billing refusal). Classify on output, never on exit code.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, and hermes via `HOME`.
- A route is `(agent, model, **provider**)`. `hermes -m X` resolves against its *active* provider only.
- A model can still write to an absolute path regardless of any flag. **Verify the files.**
- **The `free` field in adapter output must be literal `true` or `false`** — the parser in `buckets.sh` checks `(.[4]==\"true\")`, not a freeform label like `"free"`.
- **Keep TSV format strict**: 7 tab-separated fields for models (`agent provider model_arg upstream free context max_output`), 6 for identities (`agent provider wallet ident source extra`). Any literal newline in the `extra` field breaks the registry builder.
