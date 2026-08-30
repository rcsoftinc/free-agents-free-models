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

---

## 8. VERIFIED — real bucket map (probed 2026-08-27, supersedes §1 where they differ)

I probed every route instead of trusting the catalog. **Two of my §1 claims were wrong.**
Corrections first, then the true map.

### Corrections to §1

**C2 was WRONG. Hermes DOES have a `nous` provider, and it is its real free tier.**
`~/.hermes/auth.json` → `active_provider: nous`, OAuth device-code, and the token claims
say plainly:

```
paid_access: false        rate_limit_source: free_hermes_agent
rpm: 50    rph: 2100      tpm: 500 000    tph: 6 000 000
```

That is a genuinely independent bucket with **published quota numbers** — the only bucket
that tells us its limits up front. `discover.sh` never saw it. My "no nous provider" claim
came from reading the catalog; the catalog was incomplete.

**The catalog contains phantom routes.** Hermes's `credential_pool` holds **nous only** —
no OpenRouter credential, and `OPENROUTER_API_KEY` is unset in `~/.hermes/.env`. So the
**7 `hermes/openrouter` free models in `catalog.json` are unreachable.** `config.yaml`
documents openrouter as an *optional* fallback the user never configured. Discovery
listed catalog metadata as if it were a usable route.

> **New defect — D1 (blocking for scheduling): `discover.sh` catalogs advertised models,
> not authenticated routes.** It both invented 7 phantom hermes routes and missed the
> entire nous bucket. A scheduler built on this catalog would dispatch into nothing and
> would never use hermes's actual free tier. **Discovery must prove reachability, not read
> metadata.**

### The verified map

| Bucket | Credential | Reached via | Probe | Status |
|---|---|---|---|---|
| **openrouter** | opencode `auth.json`, key `28644a4b…` | `opencode` | `opencode run -m openrouter/nvidia/nemotron-3.5-lightning:free` → rc=0 `OK` | **live** |
| **kilo** | none stored (`kilo.db` account/credential tables are **empty**) — gateway serves it unauthenticated | `kilo` | `kilo run -m kilo/nvidia/nemotron-3.5-lightning:free --auto` → rc=0 `OK` | **live** |
| **nous** | `~/.hermes/auth.json`, OAuth, free tier | `hermes` | `hermes -m stepfun/step-3.7-flash:free -z '…'` → rc=0 `OK` | **live, 6 free models** |
| **opencode-account** | opencode `auth.json`, key `c48fc67f…` | `opencode` | `opencode run -m opencode/nemotron-3.5-lightning-free` → rc=0 `OK` | **live** |

**Four buckets, four separate credentials, all four confirmed LIVE.** Your independence
requirement is fully satisfiable — a better position than §1 estimated.

**One model inside bucket A is broken, and the bucket itself is fine.**
`opencode/mimo-v2.5-free` hung past 200 s on two separate attempts (killed, never answered),
while `opencode/nemotron-3.5-lightning-free` — *same key, same binary* — answered in seconds.

This is the cleanest possible demonstration of why **per-model and per-bucket health must be
separate state**: a scheduler that tripped the bucket breaker on that first 200 s hang would
have thrown away 3 working models and an entire independent lane over one bad endpoint. The
breaker (M1) must fire only on **bucket-attributable** signals — 429 / auth / billing — and
never on a single model's hang, which demotes **that model only**.

Also: `.env`'s `FREEMODEL_API_KEY` (fp `267745bc…`) **is** opencode's OpenRouter key —
identical fingerprint. The M3 bootstrap bridge **is** in effect for opencode. (An earlier
draft of this file claimed the opposite; that came from a broken fingerprint loop, and the
authoritative values are the ones `bin/buckets.sh identify` now prints.)

> **New defect — D2 (blocking): `runner.sh`'s hermes invocation is wrong.**
> `runner.sh:426` runs `hermes chat -m "$model" -z "$prompt"` → **exit 2, usage error**.
> `-z` is a top-level flag, not a `chat` argument. The working form is `hermes -z '<prompt>'`.
> Layer B has never successfully invoked hermes; every hermes attempt has been scored as a
> model failure and fed into the rankings. **The learning store is already poisoned** —
> exactly the M2 failure mode, from a bug rather than a network drop. Rankings must be
> reset for hermes once the call is fixed.

### What this means for your rule

You said: *if two agent/model routes come from the same API key, don't use both.* Confirmed
and now enforceable, with the stronger form:

> **A bucket is ONE lane, regardless of how many agents can reach it.**
> Parallel width = number of **healthy buckets** (today: **3**).
> Per bucket, pick the **single best-performing agent** and route all its traffic through
> that one; other agents are failover for that bucket, never concurrent load on it.

Today that assignment is trivial because each live bucket has exactly one working agent:

```
openrouter → opencode    kilo → kilo    nous → hermes    opencode-acct → opencode
```

**4 buckets, 4 credentials, zero overlap.** Note `opencode` is the only agent reaching two
buckets (its own account and your OpenRouter key). Those are different wallets, so running
both concurrently *is* legitimate — the constraint is per-bucket, not per-agent. That is
exactly the case an agent-keyed scheduler gets wrong in both directions and a bucket-keyed
one gets right for free.

Realistic parallel width: **3–4.** The scheduler's job
is to keep it that way and to notice when it stops being true (e.g. if you later add your
OpenRouter key to hermes, hermes and opencode collapse into one lane and must not run
concurrently).

### Effect on the build order

- **D1 goes into step 2** — the bucket registry must be built from *probed* reachability.
  Discovery emits a route only if a real call succeeded.
- **D2 goes into step 1.5** — one-line fix, plus reset hermes's poisoned ranking history.
- **Seed the model blocklist with `opencode/mimo-v2.5-free`** — it hangs rather than
  erroring, burning a full attempt timeout every time. It belongs in `catalog.json`'s
  `excluded_models` beside `opencode/big-pickle`.
- A hang demotes **the model**, never the bucket (above). This is the concrete case that
  pins down the M1 breaker's trigger conditions.

### 8b. The nous bucket, mapped properly

Discovery reported 7 phantom `hermes/openrouter` models. The truth, read from the live
inference API (`GET https://inference-api.nousresearch.com/v1/models` with hermes's own token):

- **372 models advertised.**
- **6 usable**, all suffixed `:free`. Verified `OK` on `stepfun/step-3.7-flash:free`,
  `tencent/hy3:free`, and the configured default `meituan/longcat-2.0:free`.
- The other 366 return **"model access is unavailable … subscribe or add credits"** —
  the account balance is `$0.00`.

```
meituan/longcat-2.0:free      poolside/laguna-s-2.1:free    stepfun/step-3.7-flash:free
poolside/laguna-xs-2.1:free   tencent/hy3:free              upstage/solar-pro4:free
```

Note `poolside/laguna-{s,xs}-2.1:free` also appear on openrouter and kilo — **same model
name, three different wallets.** Under your rule these are three legitimately parallel
lanes, which is exactly what a bucket-keyed scheduler permits and an agent-keyed one
cannot express.

> **New defect — D3 (blocking for error handling): hermes returns exit 0 on hard failures.**
> Verified: HTTP 404 (unknown model) → **rc=0**. Billing refusal ("model access is
> unavailable") → **rc=0**. Exit codes from hermes are worthless as success signals;
> classification must be **content-based**. `runner.sh` already suspects this for opencode
> (see its `RATE_LIMIT_PATTERNS` comment) but does not apply it to hermes. Add
> `model access is unavailable` and `not found` to the taxonomy, mapped to `no_credits`
> and `dead` respectively.

**Revised free-model inventory (reachable routes only):**

| Bucket | Free models | Agent | Was in catalog? |
|---|---:|---|---|
| openrouter | 20 | opencode | yes |
| kilo | 21 | kilo | yes |
| opencode-account | 4 (**3** usable; `mimo-v2.5-free` hangs) | opencode | yes |
| nous | **6** | hermes | **no — missed entirely** |
| ~~hermes/openrouter~~ | ~~7~~ **phantom** | — | yes, wrongly |

Real usable free routes: **50**, across 4 independent wallets — not the 52 the catalog
claims, and not composed of the same models it names.

### 8c. Fixes already applied

- **D2 fixed.** `hermes chat -m X -z P` → `hermes -m X -z P` in `runner.sh:428`,
  `compress.sh:101`, `orchestrator.sh:166`. All three pass `bash -n`. This call had **never
  worked**; every hermes attempt Layer B ever made was scored as a model failure. Hermes
  ranking history must be reset, not trusted.
- **Repo is now under git** (`git init`, baseline commit, `.env` and `.backups/` ignored).


---

## 9. BUILT — step 2: the bucket registry (`bin/buckets.sh`)

```
bin/buckets.sh identify           credential identities, no network
bin/buckets.sh discover [--probe] build registry from real credentials + model lists
bin/buckets.sh probe [--all] [--bucket ID]   prove reachability
bin/buckets.sh show               summary
```

State: `~/.local/state/free-agents/buckets.json` (override `FREE_AGENTS_STATE`).
Global on purpose — what's learned about a wallet is true for every project (M4).

### Identity is stable, not the secret

```
api key  -> sha256(key)[:12]
oauth    -> sha256(subject-claim)[:12]
none     -> "anon"
```

Hermes's nous token is OAuth and **rotates hourly**. Fingerprinting the raw token would
mint a brand-new bucket every hour and destroy all accumulated health history, so the
identity is the JWT's `sub` claim instead. Same wallet, same id, across rotations.

### Why this answers your independence rule mechanically

Bucket id is `provider:credential_fp` — **derived from the credential, never the agent.**
So when you add API keys to everything next, the collapse case handles itself: put your
OpenRouter key into hermes and both agents produce bucket id `openrouter:267745bca564`,
`reachable_via` becomes `["opencode","hermes"]`, and `show` prints

```
** SHARED WALLET: opencode + hermes hit the same credential - ONE lane, never run them in parallel **
```

No configuration, no manual bookkeeping. Give hermes a *different* key and it becomes a
genuinely separate bucket and a genuinely extra lane. **That is the difference your rule
depends on, and it is now detected rather than assumed.**

### Live output

```
buckets=4  free_models=58  phantom=0

opencode:14a1a2f827d5     health=?   opencode   4 free
openrouter:267745bca564   health=ok  opencode  24 free
nous:6b7db10dba77         health=ok  hermes     6 free
                          limits: rpm=50 tpm=500000 rph=2100 tph=6000000 paid=false
kilo:anon                 health=ok  kilo      24 free
```

58 free models across 4 wallets — more than the old catalog's 52, because that one applied
a 200k-context filter and simultaneously carried 7 phantom routes.

### D1 is fixed by construction

The registry enumerates models **per credential the agent actually holds**, never from
third-party metadata. Verified: `opencode models --verbose` advertises only `openrouter`
(356) and `opencode` (61) — exactly its two authenticated providers — and kilo only `kilo`
(301). The old catalog's phantom `hermes/openrouter` rows came from reading models.dev
instead of asking the CLI. `phantom_routes` is retained in the schema as a tripwire for
the day a CLI advertises something it cannot reach.

### Health rules, and the case that proves them

`probe` records the health precedence argued for in §8:

| Signal | Effect |
|---|---|
| `ok` | bucket healthy, failure counter reset |
| `rate_limited` / `no_credits` / `auth_error` | **bucket-attributable** → bucket state + counter (feeds the M1 breaker) |
| `timeout` / `dead` | **model only** — bucket keeps its prior state |
| `local_network` | **recorded nowhere** (M2) |

The opencode wallet exercised this for real: `opencode/hy3-free` hung for 90 s, the model
was marked `timeout`, and the bucket stayed uncondemned. Under a naive scheduler that one
hang would have written off an entire independent lane. Liveness now walks up to
`LIVENESS_TRIES` (3) models before judging a wallet, and stops early on a bucket-level
refusal because a limited wallet fails identically on every model.

### Two bugs found and fixed while building it

- **stdin drain.** `opencode run` / `kilo run` / `hermes` all read stdin, so the first
  probe swallowed the rest of the read-loop's input and only one bucket was ever probed.
  All invocations now use `</dev/null`. **This affects every agent call in the project** —
  `runner.sh` and `dispatch.sh` should be audited for the same defect before they run
  probes or loops over agent calls.
- **Blocklist.** `opencode/mimo-v2.5-free` and `opencode/hy3-free` hang rather than
  erroring, burning a full timeout per attempt. `mimo` is blocklisted by default
  (`BUCKETS_BLOCKLIST`); `hy3-free` is a candidate for the same.

### Next

Step 3: fold `classify()` (already written here, with `local_network` and the hermes
content rules for D3) into the single dispatch engine, and make the M1 breaker act on the
`health` field this registry now maintains.


---

## 10. After adding keys — 6 buckets, and what the additions actually bought

You added: OpenRouter to kilo, freemodel to opencode, kilo-gateway to hermes.
Re-ran `identify / discover / probe`. **All credentials are distinct — no shared wallets,
so these are genuine new lanes.**

| Bucket | Credential | Agent | Free models | Health |
|---|---|---|---:|---|
| `kilo:anon` | kilo gateway, unauthenticated | kilo | 24 | ok |
| `openrouter.ai:845a3f96` | `sk-or-v1-…` in kilo.jsonc | kilo | 21 | ok |
| `kilocode:fac9bae9` | `KILOCODE_API_KEY` (JWT) in `~/.hermes/.env` | hermes | 20 | ok |
| `nous:6b7db10d` | hermes OAuth, free tier | hermes | 6 | ok |
| `opencode:14a1a2f8` | opencode account | opencode | 4 | ok |
| `freemodel:40d72418` | `fe_oa_…` in opencode auth.json | opencode | **0** | — |

**75 free models across 5 usable wallets, 0 phantom** — up from 58 across 4.
Parallel width is now **5**, and `opencode` no longer reaches OpenRouter at all (adding
`freemodel` replaced that entry in its `auth.json`; the OpenRouter key now lives in kilo).

### Two things worth your attention

**1. `freemodel` exposes 10 PAID models, not free ones.** Despite the name, its catalogue
is Claude Opus 4.6/4.7/4.8, Sonnet 4.6, GPT-5.3/5.4/5.5 — advertised at real prices
(`cost.input: 2.5, cost.output: 15`). Zero models priced at 0, so the registry lists the
bucket with **0 free models and will never schedule to it**. That is the safe default and
I have left it there rather than guessing.

If that gateway actually serves those models free on your plan, the metadata does not say
so, and **nothing but a bill will tell us**. Decide explicitly: leave it excluded, or mark
it free via an override and accept the risk. I would leave it excluded — a wrong guess here
is the only failure mode in this whole design that costs money rather than time.

**2. `.env`'s `FREEMODEL_API_KEY` no longer matches anything in use.** It was opencode's
OpenRouter key; opencode's `freemodel` key is different (`40d72418…`). The file is now stale.

### Three defects this round surfaced

- **D4 — `IFS=$'\t'` collapses empty fields.** Tab is IFS *whitespace*, so consecutive tabs
  coalesce and a record with an empty middle field silently shifts its columns. This made
  hermes's `kilocode` wallet vanish (its pool entry has no token, only a base_url, so the
  URL slid into the token field). Every record that can carry an empty field now uses
  `\x1f`. **Worth auditing `runner.sh` and `dispatch.sh` for the same pattern.**
- **D5 — provider name ≠ wallet.** `kilo` calls OpenRouter `"openai"`, so joining models to
  credentials on the provider string alone produced 21 phantom routes. The registry now
  keeps the CLI's **local provider name** (the join key) separate from the **wallet
  namespace** (the API host). This is what lets the same key in two agents collapse to one
  bucket even when each agent labels it differently — the exact case your rule needs.
- **D6 — a route is (agent, model, provider), not (agent, model).** `hermes -m X` resolves
  only against its *active* provider, so every kilocode model returned HTTP 404 and was
  classified `dead`. With `--provider kilocode` the same model answers `OK`. Routes now
  carry the provider. **Without this the entire 20-model kilocode wallet would have been
  written off as broken.**

D6 is the same class of bug as D2 (the hermes `chat` misinvocation): **a wrong call shape
looks exactly like a dead model.** That is why probing must be able to distinguish "this
credential cannot serve this model" from "we asked incorrectly" — and why nothing should be
written to a learning store on a signal we cannot attribute.

### Flakiness observed, and why the health model absorbs it

`opencode/nemotron-3.5-lightning-free` answered `OK` in 48 s on one run and hung past 90 s
on the next. Its bucket stayed `ok` because liveness moved to `nemotron-3-ultra-free`.
Per-model state degrades; the wallet does not. Three opencode models now hang
(`mimo-v2.5-free`, `hy3-free`, `muse-spark-1.2-contributor-free`) and a fourth is
intermittent — that bucket is real but weak, and the rankings will learn to deprioritise it
without any manual list.

### `bin/kilo-add-openrouter.sh`

Your script, reworked. It had three bugs, one destructive:

1. **Scope.** `.provider // {} | .openai = …` rebinds `.` to `.provider`, so the inner
   `.provider.openai.models` read `.provider.provider.openai.models` — always null.
   Existing models, whitelist and blacklist were silently discarded, not merged.
2. **It dropped the apiKey.** The rewritten `options` had `baseURL` and `timeout` but no
   `apiKey`. Running it on your current config would have **wiped the key you just added.**
3. **`whitelist: ["*"]` + "assume all are free" spends money.** `"*"` exposes OpenRouter's
   whole catalogue through that provider, paid models included, while downstream we treat
   everything there as free. It now writes an explicit whitelist of the free ids, which
   makes that assumption true by construction. `--all` opts back into `"*"`, with a warning.

Also: free detection by zero pricing rather than a `test("free")` substring match (which
matches `freeform`), response validation, a timestamped backup, `chmod 600`, no-echo key
prompt, and the key reused from the config so re-runs need no argument.

Verified: 21 free models registered, apiKey preserved, whitelist scoped to those 21.


---

## 11. BUILT — step 3: the dispatch engine (`bin/run.sh`)

```
bin/run.sh [-c category] [-w workdir] [-b bucket] [-x exclude] [--dry-run] "prompt"
bin/lib/classify.sh --self-test        # 19 cases, all passing
```

One task in, one result out. stdout is the agent's output; a machine-readable footer
goes to stderr:

```
---RUN-META--- {"bucket":"openrouter.ai:845a3f96","model":"openai/cohere/north-mini-code:free",
                "agent":"kilo","provider":"openai","attempts":1,"ms":8343,"state":"ok"}
```

### Structure — one engine, one taxonomy

```
bin/lib/common.sh     paths, logging, registry_txn (flock-guarded read-modify-write)
bin/lib/classify.sh   THE error taxonomy + attribution + cooldown windows
bin/run.sh            candidate chain, bucket leasing, the breaker, recording
bin/buckets.sh        now sources both - the prober and the dispatcher cannot drift
```

That is A1 resolved: `buckets.sh` no longer carries its own copy of `classify()`.

### The three rules it enforces

**1. One lane per bucket.** The lease is `flock`-held on the *bucket*, never on the agent
or model. Verified: two tasks pinned to `kilo:anon` — the first ran, the second reported
`lane busy` once and moved on rather than queueing into the same 429.

**2. Lanes are used in parallel, automatically.** Three concurrent tasks, no configuration:

```
task1 -> nous:6b7db10d          hermes    meituan/longcat-2.0:free      11055ms
task2 -> opencode:14a1a2f8      opencode  opencode/nemotron-3-ultra     5073ms
task3 -> kilocode:fac9bae9      hermes    kilo-auto/free                5903ms
```

Three wallets, contention detected and routed around. Note tasks 1 and 3 both used
**hermes** — different wallets, same runtime. That is legitimate and an agent-keyed
scheduler could not express it: **the constraint is per-bucket, not per-agent.**

**3. The breaker (M1).** A bucket-attributable failure increments a counter; at
`BREAKER_TRIP` (default 2) the whole wallet goes into cooldown and every remaining
candidate on it is skipped for the rest of the run. Verified by putting two wallets into
cooldown: the candidate chain fell from **75 to 45** and a task routed to a healthy wallet
unprompted. This is the fix for "walk 22 models at 120 s each to learn the account is
limited" — now two attempts.

Cooldown windows: `rate_limited` 30 min · `no_credits` / `auth_error` 24 h ·
`timeout` 10 min · `dead` 72 h · `local_network` **none, and nothing recorded**.

### B1 is fixed, and it was worse than documented

The analysis said `runner.sh` "never `cd`s to the target project". Fixing the `cd` is
**not sufficient**. Launched from a temp dir with `cwd` correctly set, kilo still wrote
its file to `$HOME`:

```
prompt: "Create hello.txt containing BUCKET"   cwd = /tmp/.../wd
result: /root/hello.txt                        <-- cd was honoured; the agent ignored it
```

These CLIs decide their own working directory. Only the explicit flag governs it —
`opencode --dir`, `kilo --dir`, `hermes --in`. With those passed, the file lands in the
workdir and nothing leaks. **Any fix to `runner.sh` that only adds a `cd` will look
correct and still scatter files into the orchestrator's own repo** — which is exactly how
`JWT_AUTH_GUIDE.md` got here.

### Two bash defects worth remembering

- **`exec {FD}>&- 2>/dev/null` silences the whole script.** `exec` with no command applies
  its redirections to *the shell*, so that `2>/dev/null` permanently discarded stderr —
  every log line, the RUN-META footer, and `set -x` output vanished, and the failure
  presented as "the run does nothing and exits 1". No redirection may be attached to a
  bare `exec`.
- **`[[ cond ]] && cmd` as the last line of a sourced file aborts the caller.** When the
  test is false the line returns 1, and under `set -e` that kills the sourcing script.
  `buckets.sh` died silently the moment it began sourcing the shared library. Use `if`.

### Taxonomy self-test

19 cases, all passing, including the ones that motivated it: hermes exiting **0** on a
billing refusal and on HTTP 404; a malformed invocation (D2) that must read as `dead`
rather than as evidence about a wallet; precedence, so `"429 rate limit on model not
found"` classifies as `rate_limited` and not `dead`; and the three `local_network` forms
that must record nothing.

### Next

Step 4: per-project state (`<project>/.orch/`) and the journal-based resume (M6), then the
structural parallel gate in `AGENTS.md` (M5) so the coordinator consults live bucket health
before choosing to fan out.


---

## 12. BUILT — step 4: per-project state and resume (`bin/orch.sh`)

```
bin/orch.sh init                    create .orch/ here
bin/orch.sh run TASKS.json [--max-parallel N] [--dry-run]
bin/orch.sh resume                  re-dispatch whatever is unfinished
bin/orch.sh status                  progress, from the journal
```

### The state split (A2 / M4 resolved)

```
<project>/.orch/journal.ndjson   append-only record of every transition
<project>/.orch/tasks.json       the task graph
<project>/.orch/results/         per-task stdout/stderr
~/.local/state/free-agents/      buckets, health, model stats   <- GLOBAL
```

What is *learned* about a wallet is true everywhere, so it is global. What a *run*
is doing belongs to the project. Two projects can now be in flight at once, and
deleting one loses nothing — the old design kept run state in the tool's own
install directory, which is why only one project could ever run.

### Resume is replay, not bookkeeping

`completed_tasks()` derives from the journal every time; there is no mutable status
field a crash could leave lying. Verified by killing a run mid-flight:

```
killed after 1 task    journal: started alpha, started beta, done beta
status                 1/3 done, pending alpha, pending gamma
resume                 dispatched gamma only; 3 done, all files correct
```

Every task started exactly once across both runs. One honest caveat: killing the
parent does **not** kill in-flight children, so a resume may find work an orphaned
child completed after the interrupt. That is harmless precisely *because* the journal
is the source of truth rather than the parent's memory of what it launched.

### Parallel width is derived, not configured

`--max-parallel` defaults to **the number of healthy buckets**. On one healthy wallet
concurrency buys nothing and only manufactures 429s; on five, a hard-coded 2 wastes
three lanes. This is the mechanical half of the M5 gate — the coordinator's half comes
in step 5.

Two further constraints, both enforced rather than trusted:
- **File boundaries.** Tasks whose declared `files` overlap never run concurrently,
  however many lanes are free.
- **`no_lane` requeue.** `run.sh` now exits **5** when every candidate wallet is in use —
  distinct from exhaustion. Nothing was tried and nothing is broken, so the task is
  requeued instead of spending its retry budget on a busy moment.

### Containment: hermes needed a different fix entirely

Step 3 established that `cd` does not contain these agents and that explicit flags do.
That held for opencode and kilo. **It is false for hermes**, which honours neither `cwd`
nor `--in` — both wrote to `/root`. It resolves relative paths against `$HOME`.

The fix is to move `$HOME` and keep its config where it lives:

```
env HOME="$WORKDIR" HERMES_HOME="$HOME/.hermes" hermes ...
```

Verified clean: file lands in the workdir, credentials still work, and nothing is
symlinked into the user's project. **Each of the three agents needs a different
containment mechanism** — `opencode --dir`, `kilo --dir`, `hermes` via `HOME`. There is
no uniform flag, and assuming one is how files end up in the orchestrator's own repo.

### Verify, do not trust

Even with containment, a model can choose an absolute path. Observed: kilo, given
`--dir`, wrote to `/gamma.txt`. So there are two defences:

1. **A workdir contract in the prompt** — `run.sh` prepends the absolute working
   directory and instructs relative paths. This alone fixed the `/gamma.txt` case.
2. **Post-run verification** — a task's declared `files` must exist in the project
   afterwards. An agent's word is not evidence.

Verified against a task instructed to *claim* success without doing the work:

```
prompt: "Reply 'Done, I created the file.' Do not actually create any file."
run.sh:  state=ok, exit 0        <- the engine is satisfied
orch.sh: unverified liar: declared but absent: never_created.txt
         FAILED liar             <- the orchestrator is not
```

This is the single most important property in the file. On free models,
**"the agent said it worked" and "it worked" are different claims**, and only the
second one is worth journaling.

### Next

Step 5: the structural parallel gate in `AGENTS.md` (M5) — fan out only when the work
splits into ≥2 file-disjoint tasks *and* ≥2 wallets are healthy — so the coordinator
consults live bucket health before deciding to orchestrate at all.


---

## 13. BUILT — step 5: the coordinator gate (`AGENTS.md`)

The routing rules no longer key on wording. `AGENTS.md` was a keyword table —
*"big project"*, *"architecture"*, *"use agents"* — which is wrong in both
directions: it misses a genuinely parallel job phrased plainly, and it fans out on
a one-file change that happened to say "architecture".

**The gate is now structural, and it consults live machine state.** Orchestrate
only when **both** hold:

1. **The work splits** — ≥2 tasks with **disjoint file sets** and no dependency
   between them.
2. **There is somewhere to run them** — `bin/buckets.sh lanes` reports **≥2**.

Clause 2 is the one nobody writes, and it is the one your rule implies. **Lanes are
credentials, not agents.** Several agents on one API key are one lane; fanning out
onto them does not go faster, it races a single wallet into its own rate limit. With
one healthy lane, orchestrating a perfectly splittable job is *strictly worse* than
doing it directly. And lane count is **live state** — a wallet healthy this morning
may be cooled down now — so it is checked at the moment of the decision, not assumed.

```sh
bin/buckets.sh lanes      # -> 5      offline, cheap enough to call every time
bin/buckets.sh lanes -v   # which wallets, which agent, how many free models
```

`lanes` reads recorded health only and never touches the network — a gate that
needed a probe would not get called. The verbose listing shares the *exact* predicate
as the count, so the two cannot disagree (it labels `freemodel` `unusable`, since it
has 0 free models, while the count already excluded it).

A practical test the contract now states: **if you cannot write each task's file
boundary down, you have not found a split — you have found one task.** `files` is
load-bearing, not documentation: the runner refuses to run overlapping tasks
concurrently and verifies the declared files exist afterwards.

### The kit now ships the engine

`workflow-kit/install.sh` installs `bin/{buckets,run,orch}.sh` and `bin/lib/`
alongside the rules that reference them — reading from the repo's single `bin/`
rather than keeping a second copy, since duplicated copies are exactly the ambiguity
**H4** is about and a stale duplicate is worse than none.

`scripts/dispatch.sh` is **retired**. `bin/orch.sh` supersedes it: it schedules on
credentials rather than agents, and it journals for resume.

Verified end to end — a fresh install into an empty directory, driven only through
its own installed copy:

```
bash workflow-kit/install.sh /tmp/demo
cd /tmp/demo && ./bin/orch.sh run tasks.json

  done  config  <- kilo:anon                   kilo/cohere/north-mini-code:free
  done  notes   <- kilocode:fac9bae9           kilo-auto/free
  done  readme  <- openrouter.ai:845a3f96      openai/cohere/north-mini-code:free
  3/3 done, 0 failed        all files correct
```

Three tasks, three different wallets, no configuration — the thing you described in
your second message, working.

### Hygiene closed

- **H5** — `JWT_AUTH_GUIDE.md` removed. It was debris an agent wrote into this repo
  through B1, and it is fitting that it is the last thing to go.
- **H4** — root `AGENTS.md` resynced from the kit and marked generated in
  `CLAUDE.md`; duplicate root `scripts/` removed.
- **H1** — `.orchestrator/.backups/` pruned **489 → 20**, and `promote.sh` now prunes
  on write. It backed up `rankings.json` on every promotion and never cleaned up.

### Remaining

- **Steps 6–9**: retire `runner.sh`'s private fallback engine, route
  `orchestrator.sh`'s planner through `run.sh` (**B2** — the one call that most needs
  fallback is still the only one without it), package as an installable skill with
  frontmatter (**A3**), and close **H2** (`test_runner.sh` asserts PASS on `rc=124`)
  and **H3** (`.orchestrator/config.json` read but absent).
- **Reset hermes's ranking history.** Layer B never once invoked hermes successfully
  (D2), so every hermes entry in `.orchestrator/rankings.json` is a scored failure
  that never happened.
- **Audit `runner.sh`/`dispatch.sh`** for the stdin-drain and `IFS=$'\t'` defects, and
  for containment — remembering that each agent needs a *different* mechanism.


---

## 14. BUILT — steps 6–9: Layer B retired, planner fixed, packaged

### Step 6 — Layer B retired to `legacy/`

`runner.sh`, `orchestrator.sh`, `discover.sh`, `rankings.sh`, `promote.sh`,
`handoff.sh`, `compress.sh`, `resume.sh` and `.orchestrator/` now live in `legacy/`
behind a banner, with `legacy/README.md` giving the replacement map.

They are **kept, not deleted**, and their 14 suites still run there. A superseded
engine that stays on disk should not be allowed to rot silently, and those tests
encode real behaviour (backoff arithmetic, provider distribution, exhaustion,
dependency resolution) that is worth keeping honest. Nothing outside `legacy/` and
`test/` depends on any of it. **A1 is now fully resolved: one engine, one state store.**

The README also records the defects deliberately **not** fixed there — no workdir
containment (B1), the stdin drain, the `IFS=$'\t'` field collapse, and the missing
`config.json` (H3) — so a future reader knows the code is not merely old but wrong,
and ports behaviour rather than reviving a script.

### Step 7 — B2: `bin/plan.sh`

The old planner called **one model, once**, with stderr discarded: a single rate
limit produced invalid JSON and killed the run. The one call that most needed a
fallback chain was the only one without one.

`bin/plan.sh` goes through `bin/run.sh` like everything else, so it inherits the
chain, the leasing and the breaker for free. Two things it adds:

- **Validation as a retry signal.** A model that returns prose instead of a plan has
  *failed*, but the wallet has not — `run.sh` already recorded the call as `ok`, so
  planning simply retries and lands on a different model. It also extracts the first
  balanced JSON object, because small free models routinely wrap valid JSON in
  commentary and discarding those would waste a lane for nothing.
- **Boundary checking the model cannot be trusted to do.** Any two tasks with no
  dependency between them that share a file are rejected — the planner is where that
  error is cheapest to catch.

Verified end to end, plan → orchestrate → working software:

```
bin/plan.sh "Create a Python CLI notes app: storage module, CLI entrypoint, tests"
  -> 3 tasks, correct deps (cli and tests both depend on storage), disjoint files

bin/orch.sh run .orch/tasks.json
  storage-module  <- nous:6b7db10d          stepfun/step-3.7-flash:free
  cli-entrypoint  <- openrouter.ai:845a3f96 openai/cohere/north-mini-code:free
  test-file       <- ...

$ python3 cli.py add "First note" "hello world"
Added note with id: 785af7ae-...
$ python3 cli.py list
785af7ae-...: First note (created: 2026-08-28T04:49:06+00:00)
```

Three files, 361 lines, all parse, and the app runs. Written entirely by free models
across independent wallets, from one sentence.

### Step 8/9 — packaging (A3) and the last hygiene

- **`skill/SKILL.md`** — frontmatter + description, installed to
  `.opencode/skills/free-agents/SKILL.md`. `workflow-kit/install.sh` now ships
  `bin/{buckets,run,plan,orch}.sh`, `bin/lib/`, both skills and the routing rules.
- **H2** — `test_runner.sh` captured `rc` and never asserted on it, so a run **killed
  by the timeout** (`rc=124`) still reported PASS whenever an earlier task had been
  marked done. A killed run demonstrates nothing about the behaviour under test;
  silently green is worse than red. It now fails explicitly as inconclusive.
- **H3** — `.orchestrator/config.json` is shipped with its previously-silent defaults
  made explicit, plus the models observed to hang.
- The three hanging opencode models (`mimo-v2.5-free`, `hy3-free`,
  `muse-spark-1.2-contributor-free`) are now in the registry blocklist. A hang is the
  worst failure mode available: it costs a full timeout and teaches nothing.

### A correction

I twice flagged "hermes's ranking history is poisoned by D2 — reset it." **That was
wrong.** `legacy/.orchestrator/rankings.json` contains **zero** hermes entries; the
catalog has 43 hermes models but none were ever promoted, so the failed invocations
never reached the store. There was nothing to reset. The D2 fix still matters — Layer
B genuinely never invoked hermes successfully — but the damage I predicted did not
occur.

### Test suite

Moving Layer B broke two suites: `test/reset.sh` and `test/snapshot.sh` computed
`.orchestrator` from their own location rather than from the harness, so they missed
the move. Repointed; all suites pass again.


---

## 15. Findings — the feedback path (2026-08-30)

The taxonomy ended with a bare `echo dead`: any provider message no rule
recognised silently became a model failure and the text was discarded. **Both
classification bugs ever found in this project hid behind that default** — a
billing refusal read as `dead`, and a model 404 read as an auth failure that
cooled a 21-model wallet for 24 hours. Both surfaced only because the raw text
was pasted into a conversation by hand.

`classify()` now wraps `classify_ex()`, which reports `state<TAB>matched`.
Behaviour is unchanged; the silent default is merely no longer silent.

Recorded as findings: `unclassified` provider output, `unverified_repeat` (a task
that claimed success without producing its files more than once — a signal about
the *spec*), and `deadlock`. Not recorded: ordinary rate limits and timeouts,
which are handled correctly and would be noise.

Evidence is redacted (keys, JWTs, bearer tokens, emails) and fingerprinted, so a
finding is pasteable into a public issue and twenty occurrences are one row.
`orch.sh` prints new findings at the end of a run, the coordinator reports them,
`fa findings --issue` emits a complete issue body including the exact self-test
line to add. **Nothing leaves the machine automatically.**

## 16. Verification on an existing codebase (2026-08-30)

Existence was a sufficient check only because every project so far was
greenfield. On an existing codebase a task told to modify a file that is already
present would pass without touching it — precisely the failure verification
exists to catch.

Declared files are now checksummed before dispatch. Afterwards a file must either
have appeared, or have **changed**. Byte-identical counts as unverified.
