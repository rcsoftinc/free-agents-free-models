# Visual Guide

## 1. What is a lane?

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

### Credential collapse

```
  hermes ──▶ nous:9162a7f63a81 ──┐
                                 ├──▶ SAME LANE (one wallet)
  opencode ──▶ nous:9162a7f63a81 ─┘

  opencode ──▶ openrouter:845a3f963b8a ──┐
                                          ├──▶ DIFFERENT LANES (parallel)
  pi ──▶ openrouter:131083dc00f2 ────────┘
```

## 2. What happens when you run a task?

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

## 3. How does the orchestrator think?

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

## 4. Concrete scenario: "Build a React dashboard"

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

## 5. Failure handling: "Keep things running no matter what"

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

## 6. Metered lanes: when they're used

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
