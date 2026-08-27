# ALIGNMENT — what you want, what's true, what to build

> Written 2026-08-27 (Opus 5), after your statement of intent.
> Companion to `docs/ANALYSIS.md` (repo inventory + defect list).
> This file supersedes ANALYSIS.md §7 "the open question" — that question is now answered.

---

## 0. Your goal, restated as a spec

I'm restating it so you can correct me in one line if I got it wrong.

1. **Fresh Debian.** Install `opencode`, `kilo`, `hermes`. Each brings its own free
   models; each also accepts a gateway API key (openrouter / freemodel / kilo).
2. **cd into any folder** (empty or existing project), start **any one** of the three.
3. That agent is now the **coordinator**. It behaves like a normal coding agent —
   plan, debug, research, build, chat.
4. **Only when the work actually benefits from parallelism** does it recruit the other
   agents as **builders**, picking the best agent+model per task.
5. It must **never put the same combination in parallel against itself**, and never
   exhaust an API.
6. It must **survive**: model down, provider/account limited, your internet dropping.
7. It must **track results and resume** unfinished work.
8. Objective: **maximize what you get out of free**.

That is a coherent product. Points 1–8 are all achievable. Two of your premises are
factually wrong on this machine, and correcting them changes the design in a good way.

---

## 1. What's factually different from what you assumed

All evidence below is from `.orchestrator/catalog.json` (559 models, 52 free), the
real discovery output on this box.

### C1 — You do NOT have three independent free pools. You have three *buckets*, and they don't map to agents.

Free models, grouped as they actually bill:

| Agent | Provider | Free models | Who pays |
|---|---|---:|---|
| opencode | `opencode` | **4** | opencode's own account |
| kilo | `kilo` | **21** | Kilo gateway account |
| opencode | `openrouter` | 20 | **your OpenRouter key** |
| hermes | `openrouter` | 7 | **your OpenRouter key** |

The last two rows are **one bucket**, not two. `opencode` and `hermes` reach OpenRouter
through the same key you pasted into both. Draining it from hermes drains it for
opencode, instantly, invisibly.

So the real independent capacity is:

```
bucket A: opencode-account   →  4 free models
bucket B: kilo-gateway       → 21 free models
bucket C: your-openrouter-key→ 22 distinct free models (reachable via opencode OR hermes)
```

**Three buckets — but not the three agents you were counting.**

### C2 — Hermes contributes zero independent free quota here.

All 7 of hermes's free models are `openrouter/*`. There is **no `nous` provider** in the
catalog. And 5 of those 7 are models `opencode` already reaches on the same key:

```
nvidia/nemotron-3.5-lightning:free        ← opencode+openrouter, hermes+openrouter, kilo+kilo
nvidia/nemotron-3-super-120b-a12b:free    ← same three
nvidia/nemotron-3-ultra-550b-a55b:free    ← same three
poolside/laguna-s-2.1:free                ← same three
poolside/laguna-xs-2.1:free               ← same three
z-ai/glm-5.2:free                         ← opencode+openrouter, hermes+openrouter
```

Hermes's value is that it is a **third runtime** (different harness, different tool loop,
different failure modes) — not a third wallet. Keep it for runtime diversity and as a
fallback *executor*, not as extra quota. If you want hermes to add real capacity, give it
a **different** key from the one opencode uses.

*(Caveat worth verifying, not assuming: the 4 `opencode/*` free models may require an
opencode account login. You said you aren't logged in. If those are gated, bucket A is
empty and you effectively have two buckets. One command settles it — see §6, V1.)*

### C3 — Your no-collision rule uses the wrong key.

You said: *"not allowing the same agent+model combination to work in parallel."*

That rule permits the exact collision it's meant to stop:

```
task-1 → opencode + nvidia/nemotron-3-ultra:free   ┐ two different agent+model
task-2 → hermes   + nvidia/nemotron-3-ultra:free   ┘ combos … ONE key, ONE model
```

Two parallel slots, one OpenRouter key, one upstream model — double the rate-limit
pressure while the scheduler believes it diversified. Meanwhile this is genuinely safe
and the rule can't tell the difference:

```
task-1 → opencode + nvidia/nemotron-3-ultra:free   (openrouter key)
task-2 → kilo     + nvidia/nemotron-3-ultra:free   (kilo account)  ← fine, different wallet
```

**The correct parallelism key is `(bucket, upstream_model)`** — the account that pays and
the model as the *provider* sees it, with the agent stripped off. Agent is an
implementation detail of *how* you reach it.

This primitive does not exist anywhere in the codebase. `grep -riE 'bucket|quota|circuit'`
finds nothing but error-string matching. `runner.sh` schedules **agent-first** (LRU over
agents, with a weak "don't reuse last provider" bias) — which is precisely backwards, and
is why it will happily put opencode and hermes on OpenRouter back to back.

### C4 — Tokens are not your scarce resource. Requests-per-bucket are.

You said saving tokens is hard. On free models it's also **the wrong optimization target**.

- Tokens cost you **$0**. Spending 3× the tokens costs 3× nothing.
- What is actually finite: **requests/min and requests/day per bucket**, and the
  **context window of a single session**.

Multi-agent orchestration **increases** total tokens (every subagent re-reads its spec).
On paid models that's the cost you weigh against the benefit. On free models that cost is
approximately zero, so orchestration is close to a pure win — **but only if the parallel
tasks land on different buckets.** Two parallel tasks on one bucket don't go faster; they
race each other into the same 429.

So the objective function is not "minimize tokens." It is:

> **Maximize useful work per unit of bucket-quota, and never idle on a bucket that is cold.**

That single reframing decides most of the design below. It also means your instinct —
"benefits only show on big projects" — is right, but for a different reason than you
thought: not because tokens amortize, but because big projects have enough *independent*
tasks to keep 3 buckets busy at once. Small tasks can't, so orchestrating them is pure
overhead.

---

## 2. What you missed that's actually valuable

Ranked by how much they'll change your day.

### M1 — Bucket-level circuit breaker. **(biggest single win, doesn't exist)**

When a bucket is account-limited, **every** model in it fails. Today the fallback chain
would discover that one model at a time:

```
22 openrouter models × 120s ATTEMPT_TIMEOUT = up to 44 minutes
             …to learn one fact you knew after failure #2.
```

Fix: scope failures to the bucket. Two or three consecutive bucket-attributable 429s →
**freeze the whole bucket** for a cooldown and skip all its models instantly. Cost of
learning "OpenRouter is out" drops from ~44 min to ~4 min, and every later task skips it
for free. This is the difference between the thing being usable and not.

You described this exact scenario ("the limit is for the account, so all of them get
limited") — you just didn't name the mechanism. It's the most valuable thing in your
message and the codebase has no representation of it.

### M2 — Your own network dropping will poison the rankings. **(most dangerous)**

You named this and it's worse than you think. `classify-error.sh` has six classes —
`rate_limited / no_credits / dead / timeout / context_overflow / auth_error` — and **none
of them is "my internet is down."** So a 30-second outage looks like:

```
model 1 → unreachable → marked dead   → benched 72h
model 2 → unreachable → marked dead   → benched 72h
model 3 → unreachable → marked dead   → benched 72h
…
```

One bad minute of wifi permanently benches your good models for three days, and the
learned rankings — the part that's supposed to get smarter — get **actively worse**.

Fix, and it's cheap: add a `local_network` class for connect/DNS/TLS failures. On that
class: **record nothing**, pause the run, probe a known endpoint, resume when it returns.
A failure you caused is not evidence about a model. **Never let unattributable failures
write to the learning store** — that's the general principle, and it's the one rule that
protects everything else you build.

### M3 — Your "fresh Debian" story is only 1/3 automated.

`.env` holds exactly one key (`FREEMODEL_API_KEY`), and `bootstrap.sh` bridges it into
**opencode's** `auth.json` only. Kilo and hermes are authenticated by their own separate
flows that the skill neither performs nor reads.

For the install experience you described, pick one and commit to it:
- **(a)** the skill owns all three auth paths (`bootstrap` writes opencode + kilo + hermes
  config), or
- **(b)** the skill declares kilo/hermes user-authed, and *discovery* just detects what
  they can reach.

**(b) is the honest choice** — those CLIs own their config formats and will change them
without telling you. But then discovery has to **attribute each model to a bucket by
identity**, which is exactly the primitive from C3. Same work, twice the payoff.

### M4 — "cd into any folder" is blocked today by two defects, both known.

- **B1** — `runner.sh:417` `invoke_agent()` never `cd`s to the target. `PROJECT_PATH` is
  stored in `project.json` and never used. Builders write into the orchestrator's own
  directory. `JWT_AUTH_GUIDE.md` sitting in this repo root is that bug's output.
  (`dispatch.sh` gets it right — `--workdir`, then `cd`.)
- **A2** — `ORCH_DIR="${SCRIPT_DIR}/.orchestrator"` — state lives in the *tool's* folder,
  so exactly one project can be in flight, ever.

Your premise #2 is *literally the thing these two defects break.* They're not cleanup —
they're the feature.

The right split, which doesn't exist today:

```
<project>/.orch/         run journal, task graph, results   ← per project, disposable
~/.local/state/free-agents/   catalog, rankings, bucket health   ← global, LEARNED
```

Learning must be global (a model that's down is down for every project). Run state must
be local (two projects at once, delete a folder without losing what you learned).

### M5 — The coordinator's parallel gate should be structural, not keyword-based.

`AGENTS.md` today routes on phrases: *"big project"*, *"architecture"*, *"use agents"*.
That's brittle in both directions — it misses a genuinely parallel job phrased plainly,
and it fans out on a one-file change that happened to say "architecture."

You described the right gate yourself ("only when doing anything that would benefit from
having workers work in parallel"). Make it a test the coordinator can actually run:

> **Go parallel iff:** the work decomposes into **≥2 tasks with disjoint file sets** and
> no chain dependency between them, **AND ≥2 buckets are currently healthy.**
> Otherwise work directly.

The second clause is the one nobody writes and it matters: **on one healthy bucket,
parallelism buys you nothing and costs you rate-limit collisions.** Same job, more 429s.
The coordinator must know the *current* bucket health before choosing its own mode — which
means bucket health has to be a cheap local read, not a probe.

### M6 — Recovery must be per-project and crash-safe.

`resume.sh` exists but reads the single global state dir, so it can only resume "the"
project. With M4's split it becomes: append-only journal in `<project>/.orch/journal.ndjson`,
one line per state transition. Resume = replay the journal, re-dispatch anything not
`done`. Survives closed laptop, killed tmux, and OOM — none of which the current design does.

### M7 — Outcome-learned rankings are right; keep them, just seed them.

`capabilities: []` on the catalog entries — advertised model metadata is thin and often
lies, especially on free tiers. Learning from **observed** results (`promote.sh`) is the
correct approach and you should keep it. It only needs a **cold-start seed** so run #1
isn't random. Layer A already has `rankings-seed.json`; Layer B doesn't. Unify on A's.

---

## 3. What the thing should be

One skill. Not three layers. Four pieces, bottom-up — the bottom one is new and everything
else keys on it.

### Piece 0 — The bucket registry *(new; the missing primitive)*

```
bucket := (auth_identity, provider)      e.g. "openrouter:<key-fingerprint>"
model   := (bucket, upstream_model_id)   e.g. (openrouter:ab12, nvidia/nemotron-3-ultra:free)
route   := (model, agent)                HOW to reach it: opencode | kilo | hermes
```

Discovery emits buckets → models → `reachable_via: [agents]`. Health, cooldowns, circuit
breakers, and the parallel-collision key all live at the **bucket/model** level. Agent is
chosen last and is nearly free to swap. This inverts today's agent-first scheduling and
makes C3, M1 and M5 fall out naturally rather than needing special cases.

### Piece 1 — One dispatch engine

Generalize `oc.sh` (it's the best of the three) into `run(task, category) → result`, and
**delete the other two fallback implementations.** It owns:

- ranked candidate chain over `(bucket, model, agent)`
- cross-model session continuity (`opencode run -s <id> -m <other>` — already proven)
- error taxonomy **plus `local_network`** (M2)
- **bucket circuit breaker** (M1)
- inflight reservation under `flock`, keyed on **`(bucket, upstream_model)`** (C3)
- `--workdir` and an actual `cd` (M4/B1)
- one write path to the learning store — and **nothing writes to it on `local_network`**

`runner.sh`'s private retry/backoff engine and `orchestrator.sh`'s unguarded single-shot
planner both go away. The planner in particular must run **through** this engine — it's the
one call that most needs fallback and is currently the only one without it (defect B2).

### Piece 2 — The coordinator contract (`AGENTS.md`)

What makes any of the three agents behave the way you described:

- Default: **work directly**, like a normal agent. No ceremony, no fan-out.
- Run the **structural gate** from M5 before every non-trivial build.
- When it passes: plan → task graph, each task carrying its own self-contained spec **and
  an explicit disjoint file boundary** → dispatch → verify by tests/diff → journal.
- Integrate by diff and test output. Never re-read the whole repo per task.

Your existing `workflow-kit/skills/agent-coordinator/` is ~80% of this already. It needs
the structural gate and the bucket-health check bolted onto its Phase 0.

### Piece 3 — State split

```
~/.local/state/free-agents/     catalog.json  rankings.json  buckets.json   ← global, learned
<project>/.orch/                journal.ndjson  tasks.json  results/        ← per project
```

### What gets deleted

`runner.sh`'s fallback engine · `orchestrator.sh`'s bare planner · `.orchestrator/` as a
global state dir · the second rankings schema · root `scripts/`+`AGENTS.md`+`CLAUDE.md`
duplicate copies (H4) · `JWT_AUTH_GUIDE.md` (H5) · 442 stale backups (H1).

Net: **less code than today**, with the capability you actually asked for.

---

## 4. Honest expectations

- **Real parallel width is ~3, and unequal.** Buckets A(4 models) / B(21) / C(22). If the
  opencode account models are login-gated, it's 2. Don't design for 5-wide fan-out;
  design for 2–3 wide with fast, cheap failover. `MAX_PARALLEL=2` (dispatch.sh's current
  default) is about right — and should become *derived from healthy bucket count*, not a
  constant.
- **Orchestration will not save tokens.** It saves wall-clock and it keeps any single
  context from blowing up. On free models tokens are free, so this is fine — but don't
  measure success in tokens, measure it in **tasks completed before the buckets go cold.**
- **The learning store is the crown jewel.** It's the only thing here that compounds. That
  makes M2 (don't poison it) more important than any feature.
- **Free models are weak at long agentic loops.** Tight, self-contained, file-bounded task
  specs aren't just token discipline — they're what makes these models succeed at all.
  Your "rules that help agents work better" intuition is correct and load-bearing.

---

## 5. Build order

Blockers first — each step leaves the system working.

| # | Step | Why now |
|---|---|---|
| 1 | **Git init + commit.** | S2: zero version control today. Do this before touching anything. |
| 2 | **Bucket registry** — discovery attributes models to `(auth_identity, provider)`. | Everything below keys on it. |
| 3 | **`local_network` class; never write to the store on it.** | M2 — stop poisoning the only asset that compounds. |
| 4 | **Fix B1 (`--workdir` + `cd`) and A2 (state split).** | M4 — unblocks "cd into any folder". |
| 5 | **Bucket circuit breaker + `(bucket, model)` inflight key.** | M1 + C3 — the actual throughput win. |
| 6 | **Collapse to one engine**; route `orchestrator.sh`'s planner through it. | A1 + B2 — kills the last blocker. |
| 7 | **Structural parallel gate + bucket-health check in `AGENTS.md`.** | M5 — makes the coordinator behave as you described. |
| 8 | **Per-project journal + resume.** | M6. |
| 9 | **Package as one installable skill; hygiene sweep (H1–H5).** | A3. |

Steps 1–5 get you a system that is *stable and honest about its limits.* Steps 6–9 make it
the thing you described.

---

## 6. Verification items (cheap, do before step 2)

- **V1** — Are the 4 `opencode/*` free models usable without an opencode login?
  `opencode run -m opencode/mimo-v2.5-free 'say ok'`. Decides whether bucket A exists.
- **V2** — Is kilo's free tier its own account, or does it proxy your OpenRouter key?
  Determines whether bucket B is real. (Catalog says provider `kilo` — likely real, worth 30s.)
- **V3** — Do `kilo` and `hermes` actually read `AGENTS.md`? opencode does. If they don't,
  the coordinator contract needs a per-agent delivery mechanism, and that changes Piece 2.
- **V4** — Confirm hermes has no non-OpenRouter free provider on this install (`hermes models`).
  If a `nous` tier exists but discovery missed it, C2 changes and hermes becomes bucket D.

V3 is the one that could actually move the design. Worth doing first.

---

## 7. The one-line answer to "which layer do I productionize?"

**None of them as-is.** Keep **A's engine**, keep **C's contract**, throw away **B's
duplicate engine and global state**, and add the **bucket registry** underneath all of it —
the primitive none of the three layers has, and the one your goal actually depends on.
