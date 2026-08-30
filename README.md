# free-agents

Run real coding work on **free models** across several agent CLIs (opencode, kilo,
hermes) without a rate limit ever stopping you, and without two workers fighting
over the same API key.

## The idea

**Give each agent a different free API key, and you get more lanes.**

opencode, kilo and hermes each ship with their own free models, and each accepts
additional gateway keys (OpenRouter, Kilo gateway, FreeModel, …). Every *distinct
credential* is an independent quota you can run in parallel. Adding a different
free key to each agent is the whole point — it is how you turn three CLIs into
five or six independently rate-limited lanes.

The scheduling unit is therefore the **credential**, not the agent:

> A **bucket** is one wallet: `(provider, credential)`. It is the unit of rate
> limiting, so it is the unit of scheduling.

This matters in both directions:

- **Different keys → real parallelism.** Two agents with different keys are two
  lanes even when running the same model. Add keys freely; each one is capacity.
- **The same key in two agents is ONE lane.** Running both does not go faster — it
  races that single key into its own rate limit. The tool detects this
  automatically (bucket ids derive from the credential) and flags it as a shared
  wallet, so you never mistake it for extra capacity.

A real example from the machine this was built on — three CLIs, six credentials,
**75 free models across 5 usable lanes**:

| Lane | Reached via | Free models |
|---|---|---|
| `kilo` gateway (no key needed) | kilo | 24 |
| OpenRouter key in kilo | kilo | 21 |
| Kilo-gateway key in hermes | hermes | 20 |
| `nous` OAuth free tier | hermes | 6 |
| opencode account | opencode | 4 |

`docs/SETUP.md` shows where each agent keeps its keys.

## Use it in a project

Go into your project — empty or existing — and clone the tool into it:

```sh
cd ~/projects/thing
gh repo clone noonelifecoach/free-agents-free-models .free-agents
.free-agents/setup.sh
```

Everything the tool owns lives in **two hidden directories**: `.free-agents/`
(the clone) and `.orch/` (this project's run state). `setup.sh` adds
`.free-agents/` to your `.gitignore`, so the tool never becomes part of your repo.

Then **start any agent's TUI** from that directory — `opencode`, `kilo`, `hermes`,
`claude` — and paste a prompt:

```
.free-agents/prompts/coordinator.md
```

**One prompt, pasted once.** After that just talk normally — the coordinator reads
what you are asking for and picks the mode itself: orienting, researching, one
bounded task, a parallel build, or resuming after an interruption. You never tell
it which mode to use.

Pasting is deliberate. Agents do not read `AGENTS.md` consistently — tested here,
kilo picks it up and quotes the gate exactly, hermes ignores it and falls back to
its own idea of when to parallelise. A pasted prompt works in all of them.

You can also drive it directly, without an agent:

```sh
.free-agents/bin/fa lanes -v          # how many independent credential lanes
.free-agents/bin/fa plan "a goal"     # goal -> .orch/tasks.json
.free-agents/bin/fa orch run          # execute across every healthy lane
.free-agents/bin/fa status            # progress
.free-agents/bin/fa resume            # safe after ANY interruption
```

## Metered lanes (copilot, cursor) — opt-in

`copilot` and `cursor-agent` work as lanes, but their free tiers are a **depleting
monthly allowance**, not an unlimited pool. They are therefore **off by default**,
and when enabled they are always tried **last** — after every genuinely free lane
is busy or cold.

```sh
fa lanes -v                              # shows credits remaining + renewal date
FA_ALLOW_METERED=1 fa orch run           # opt in for this run
fa run --allow-metered "task"
```

They cannot bill you. GitHub reports `overage_permitted: false` — the allowance
simply stops, and it renews monthly (`fa lanes -v` prints the reset date). Copilot
also exposes live credit counts, which the registry records at discovery.

Neither exposes a model list — both route through a vendor "Auto" selector — so
each is a single-model bucket. That is fine: the scheduler addresses wallets, not
models.

## Bootstrap (once per project)

```sh
.free-agents/bin/fa bootstrap    # discover credentials, probe wallets, install skills
.free-agents/bin/fa doctor       # verify the machine
.free-agents/bin/fa lanes -v     # what you ended up with
```

`bootstrap` reads whatever credentials your agents already hold — it never asks
for keys and never stores one. `state/` lives inside `.free-agents/`, so deleting
that folder removes every trace of this tool. The agents stay logged in; their
keys are their own.

Sharing one registry across projects instead (skips re-probing per project):

```sh
export FREE_AGENTS_STATE="$HOME/.local/state/free-agents"
```

Where each agent keeps its keys, and how to add more: `docs/SETUP.md`.

## Handoffs between tasks

Workers are isolated: a task sees its own spec and nothing else. That is what makes
weak models succeed, but it means a task cannot learn what the task it *depends on*
decided — only what file that task left behind.

So a task that has dependents is asked to end with one line:

```
---HANDOFF--- ids are uuid4 strings; the store is notes.json
```

That line, and only that line, is given to the tasks that named it in `deps`. Nothing
else changes: no extra model call, no lane spent, no summariser. A worker that writes
nothing degrades to the previous behaviour, and a task nothing depends on is never
asked — the request is a line in every prompt, so it is not free.

Bounded by `HANDOFF_MAX_CHARS` (320). Stored in `.orch/handoffs/`, gitignored.

## Prompt size

Every dispatch estimates its prompt size and reports it in `RUN-META` as
`est_prompt_tokens`. Above `BLOAT_WARN_TOKENS` (8000) it says so:

```
[run] prompt is large: ~10035 tokens (warn above 8000).
[run]   a spec this size usually means a file listing leaked into it
```

Oversized prompts are the usual upstream cause of `context_overflow` and of
free-model calls that are slow or wrong for no visible reason. One call in this
project's own history sent ~31,875 input tokens unnoticed.

## What gets scheduled, and what does not

A model must be able to do the job before quality is even a question. Discovery now
records what the providers already publish — context size, output budget, output
modality — and excludes what cannot work:

| Excluded | Why |
|---|---|
| `non_text_output` | generates audio or images. `google/lyria-3-*` sat in the free set with a **1M context**, so no context floor would have caught it |
| `context_too_small` | below `CONTEXT_FLOOR` (200000, configurable) |
| `not_a_generalist` | classifiers, moderation, embedding and rerank models |

Nothing is deleted — the reason is recorded, and `fa lanes -v` shows it:

```
kilo:anon  kilo  22 usable (2 context_too_small filtered)  health=ok
```

**Unknown context is kept.** Where a provider does not publish it, the model is
accepted as-is. Metadata is also pooled per model across lanes: context belongs to the
model, not to whichever wallet happens to list it.

Vendor routers (`kilo-auto/free`, `openrouter/auto`, …) are kept and flagged. They work;
they just cannot be ranked, because the model behind them changes per request.

## Working on an existing codebase

All the guidance above holds, with one difference that matters. On a greenfield
project a task's declared `files` are checked for **existence**. On an existing
one that proves nothing — the file is already there — so the runner also
checksums every declared file before dispatch and requires it to have **changed**.

A task that declares a file and leaves it byte-identical is reported
`unverified` and retried, exactly like one that wrote nothing at all.

```
[orch] unverified refactor: declared but not written: src/api.py (unchanged)
```

If a task legitimately may make no change, give it an empty `files` list and
verify it another way.

## Findings — how a project feeds a fix back

A *finding* is not an error. Errors are handled: a rate limit cools a wallet, a
hang parks a model. A finding is the tool admitting it **did not know what
something was**, or that it did the same unhelpful thing twice.

```sh
fa findings          # what has been noticed
fa findings --issue  # emit a ready-to-file GitHub issue
fa findings --ack    # mark them seen
```

Three things are recorded:

| Kind | When |
|---|---|
| `unclassified` | provider output no taxonomy rule matched — it is still handled as `dead`, the safe default, but the text is kept |
| `unverified_repeat` | a task claimed success without producing its files more than once — a signal about the spec or the models |
| `deadlock` | a task graph that could not progress |

`unclassified` is the valuable one. **Every classification bug found in this
project was invisible for the same reason**: the taxonomy has a silent default and
the text that reached it was discarded. A billing refusal read as `dead`; a model
404 read as an auth failure that cooled an entire wallet for 24 hours.

After an orchestrated run, `orch.sh` prints any new findings and the coordinator
reports them to you. Nothing leaves the machine on its own. Evidence is redacted
before it is stored — keys, JWTs, bearer tokens and email addresses — because a
finding is meant to be pasteable into a public issue.

## Model ranking (learned, per category)

There is no static "best model" list — free models change too often for one to
stay true. The engine ranks by **observed outcomes**, per category:

```
score = 2 x (this category: ok - 2xfail)      evidence from THIS kind of work
      +      (overall:       ok - 2xfail)      evidence from any work
      + 5 if the model answered its last probe
```

Category evidence counts double, because a model that is good at `coding` is not
automatically good at `reasoning` and free models vary wildly between the two.
Overall evidence still counts, so a model with no history in a category is not
stranded at the bottom forever. Categories: `coding | reasoning | research |
general | fast`.

Two rules keep the ranking honest:

- **A wallet-level failure is never scored against a model.** A rate limit or an
  exhausted balance says nothing about whether that model is any good, so it
  updates the *bucket's* health and leaves the model's record untouched.
- **Nothing that cannot be attributed is recorded at all.** If your network drops,
  no model and no wallet is blamed. A failure you caused is not evidence.

Rankings live in `state/buckets.json` under each model's `stats` and `cat_stats`,
and accumulate as you use the tool.

### Cold start

A fresh registry has stats for nothing, so ordering would otherwise be arbitrary. Models
with **no observed results at all** are ordered by a prior built from the same metadata:
context size, output budget, a parameter hint in the id, and an optional tier from
`data/model-seed.json`.

The prior applies **only** while a model has no stats. Clamping it below the value of one
success is not enough — the *spread* between two priors can still offset an evidence gap —
so it is gated on absence of evidence outright. Opinion orders the unknown; evidence orders
everything else; the two never compete.

`data/model-seed.json` is optional, absent by default, and **never fetched at runtime**.
It is where leaderboard opinion belongs: edit it by hand or generate it whenever you like.
It cannot break a run and cannot override a real result. Delete it and nothing changes.

## Prompts the tool injects for you

Two prompts are added automatically, because free models reliably get these wrong
otherwise:

**1. A working-directory contract**, prepended to every dispatched task:

> `Your working directory is <abs path>. Create and edit files only inside it,
> using paths relative to it. Do not use absolute paths.`

Flags alone are not enough — a model given `--dir` was still observed writing to
`/gamma.txt`. Stating the contract fixed it. (The runner also *verifies* the
declared files afterwards, because a model can still ignore both.)

**2. Task-shape rules**, injected when `fa plan` asks a model for a task graph:
each task must be self-contained, `files` must list everything it touches,
concurrent tasks must not share a file, and splits go by file boundary rather than
by phase-of-thought.

Nothing else is injected. Your prompt reaches the model as you wrote it, after
those lines.

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
│   ├── find-free-providers.sh   scan models.dev for new free providers
│   ├── kilo-add-openrouter.sh   register OpenRouter free models with kilo
│   └── lib/                  common.sh (paths, locking) - classify.sh (taxonomy)
├── skills/                   skill cards, linked into the project by `fa bootstrap`
├── state/                    the credential registry (gitignored, regenerated)
├── docs/                     SETUP.md - dev/ holds the design history
└── test/                     stub agent CLIs + harness, for offline testing
```

## State

```
~/.local/state/free-agents/buckets.json   wallets + health   GLOBAL (learned)
<project>/.orch/journal.ndjson            append-only log    PER PROJECT
```

Learning is global because a dead wallet is dead everywhere. Run state is local so
two projects can run at once. Resume replays the journal — there is no mutable
status field for a crash to leave lying.

## Tests

```sh
bin/lib/classify.sh --self-test   # error taxonomy, 28 cases, offline, ~1s
bin/fa doctor                     # deps, agent CLIs+versions, self-test, lanes
bin/fa lanes                      # smoke check: >0 means credentials work
DRY_RUN_LIMIT=0 bin/run.sh --dry-run   # the full candidate chain, spends nothing
```

**`bin/` has no regression suite yet.** The engine is verified by end-to-end runs,
not by automated tests. `test/` keeps the stub agent CLIs and harness that a suite
would be built on. The retired Layer B and its 14 suites were removed in the
cleanup — they tested code that no longer ships; `git log` has them.

## Visual reference

Two published pages, source in `docs/artifacts/`:

- **[Route map](https://claude.ai/code/artifact/68bc7de1-6a06-4242-86f0-957904c09e1f)** — every
  route the tool can take: discovery, the gate, the dispatch loop, the error taxonomy, and what
  is deliberately absent.
- **[One run, end to end](https://claude.ai/code/artifact/727f0341-8a96-4e91-99fd-47ec5cdb7076)** —
  a real recorded build, compared against a wide run and a deliberately starved one.

## Docs

- **`docs/ALIGNMENT.md`** — the design, every finding, and the build log. Current.
- `docs/ANALYSIS.md` — the original survey. Historical.
- `SESSION.md` — where the work stands and what is next.
- `AGENTS.md` — when to work directly vs orchestrate (the gate).

## Things that cost real debugging time

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a
  billing refusal). Classify on output, never on exit code.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, and hermes via
  `HOME` — it honours neither `cwd` nor `--in`.
- A route is `(agent, model, **provider**)`. `hermes -m X` resolves against its
  *active* provider only.
- A model can still write to an absolute path regardless of any flag. **Verify the
  files; an agent reporting success is not evidence.**
