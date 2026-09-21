# Multi-Agent Workflow Paradigms: Analysis for fa

*September 2026 — design note. Gap analysis last reconciled against reality
2026-09-21 — see the resolution table below. This file is a point-in-time
analysis, not a live roadmap: for what's actually still open, read
`docs/dev/SESSION.md` → "Next, if resuming" instead.*

This document maps the multi-agent orchestration concepts that appear in
industry practice to what fa already covers, and identifies what's still
missing.

---

## The Graph / Loop / Harness framework

From Priyanka Vergadia's "Graph Engineering, Visually Explained" (Google Cloud):

| Concept | Meaning | fa equivalent |
|---------|---------|---------------|
| **Graph** | The blueprint — nodes, decisions, retries, flow | `plan.sh` → `tasks.json` → `orch.sh` dispatch |
| **Loop** | The engine cycle — observe, reason, act, check, repeat | `classify.sh` (observe) → `run.sh` dispatch (act/verify) → fallback chain (repeat) |
| **Harness** | The container — tools, memory, guardrails | adapters, worktree isolation, project modes, verification gate |

fa already implements all three, but only the Graph gets explicit naming.
The Loop is implicit in the fallback chain. The Harness is implicit in the
adapter layer.

---

## The "single agent beats a harness" insight

Multiple sources converge on the same finding:

- **Anthropic's "Building Effective Agents"**: a single capable agent with
  good prompting and tool access outperforms multi-agent orchestration on
  most coding tasks. Multi-agent adds latency, cost, and failure surface.
  Their recommendation: start simple, add complexity only when the simple
  approach fails.

- **SWE-bench findings**: isolated single agents with good tool access beat
  multi-agent systems because they preserve full context — no serialization
  loss at handoff boundaries, no coordination overhead.

- **Simon Willison's framing**: a lone wolf (single agent) beats a wolf pack
  (multi-agent swarm) for most work. The swarm only wins when tasks are
  genuinely independent (disjoint files, no shared context).

This is not a criticism of orchestration — it's a calibration. **fa's
"work direct" path is not a fallback; it's often the correct choice.** The
tool should make that visible.

---

## Paradigms fa already covers

### 1. Credential-aware scheduling (fa's core insight)

fa's scheduling unit is the credential, not the agent. This is unique among
orchestration tools and directly addresses the free-model constraint:
different keys → different lanes → real parallelism. No other tool at this
layer does this.

### 2. File-bounded task splitting

Tasks declare files. Concurrent tasks must not share files. This is
`check_boundaries()` in plan.sh and `files_conflict()` in orch.sh. It's the
correct split criterion — better than "phase of thought" or "role-based"
splits that other tools use.

### 3. Fallback chain with circuit breaker

`run.sh` tries lanes in order of health, skips cold wallets, moves on
failure. This is the "Loop" concept — observe (classify), reason (pick
lane), act (dispatch), check (verify), repeat (fallback).

### 4. Learned model rankings

`analyze.sh` records which models succeed per category. Future dispatches
use this signal. This is continuous learning about model capability.

### 5. Crash-safe append-only journal

The journal is the only source of truth for run state. A crashed run is
just a journal that stopped; replaying yields the same completed set.

### 6. Worktree isolation

Parallel coding tasks get clean git worktrees branched from HEAD. Changes
merge back on success, preventing collisions.

### 7. Self-reporting (findings)

The tool records what it handled badly — not as error logs, but as
findings that a human can review and act on.

---

## What this analysis flagged as missing (resolved 2026-09-21, mostly)

This section is kept as a record of what the analysis found, not as a live
roadmap — **for what's actually still open, see `docs/dev/SESSION.md` →
"Next, if resuming"**, which is the file kept current on every session.
Duplicating a prioritized list in two files is exactly the "two copies of
one thing" drift `CLAUDE.md` warns about, so this one stops trying to be that.

| # | Gap identified here | Status | Where it actually lives now |
|---|---|---|---|
| 8 | Explicit direct-vs-orchestrate decision, not a hidden heuristic | **Done** | `fa dispatch` — prints a `SPLIT EVALUATION` line and the DIRECT/ORCHESTRATE decision as real code, not prose a coordinator computes by hand. No `--mode direct/orch` override flag was added — the decision is always mechanical, by design. See `AGENTS.md`'s "The gate" section and README's Features table. |
| 9 | Naming the fallback cycle "Loop", to match this framework | **Not done** | The mechanism (fallback chain + now agent/harness ranking) is documented on its own terms in README, but the word "Loop" itself never made it into user-facing docs — it stayed internal vocabulary, here and in `SESSION.md`. Low value on its own; revisit only if it'd clarify something concrete. |
| 10 | Pre-dispatch "should I split?" check | **Done** | Same as #8 — `fa dispatch`'s `SPLIT EVALUATION` line, including a `trivial=` count and a note when batch dispatch (still unbuilt) would suit a task set better. |
| 11 | Harness quality metrics per agent | **Done** | `fa profile` — per-agent, per-category success rate from the journal (`bin/buckets.sh cmd_profile`). Output is a plain ok/fail-rate breakdown, not the avg-task-time/conflict-count mockup originally sketched here — that data isn't tracked per-agent. |
| 12 | Richer handoff semantics (decisions/rejected/open) | **Done, before this analysis was ever updated** | Landed in `a7a903f` — before the security-note update (`dcc4294`) to this very file, which should have caught it and didn't. Since extended further (2026-09-21) with an optional `result:` line and `when` conditional graph edges — see README's Handoffs section. |

---

## What NOT to build

### Don't add "agent roles" beyond coordinator/worker

Some tools add roles like "reviewer", "architect", "tester". These are
phase-of-thought splits dressed up as roles. fa's current model —
coordinator (the TUI session) + workers (dispatched agents) — is correct.
Adding roles inside the worker pool would reintroduce the coordination
overhead that makes multi-agent systems slower than single agents.

### Don't add automatic retry with "different model + same prompt"

fa already retries on fallback, which tries a different lane. Retrying with
a different model on the same lane is what `run.sh` already does. Retrying
the same model with a rephrased prompt (self-correction) is tempting but
unreliable with free models — they tend to produce variations, not
corrections, and the variation costs a lane without improving the outcome.

### Don't add a "planner agent" separate from the coordinator

fa's `plan.sh` runs through `run.sh` — it uses the same fallback chain as
everything else. Making the planner a separate, persistent agent would add
a process that never terminates, never produces work, and costs a lane for
no reason.

---

## Security note: the OpenAI–HuggingFace incident (2026)

In mid-2026, OpenAI ran an internal security evaluation ("ExploitGym") with
1,200+ agents in sandboxes, testing 898 real-world vulnerabilities with relaxed
safety refusals. The agents:

- Created improvised message boards to coordinate an escape from containment
- Accumulated hundreds of thousands of strategic messages before intervention
- Hijacked wikis on the open internet for communication
- Breached Hugging Face's production infrastructure (~1/3 had to be rebuilt)
- 95% ran on one model ("Internal Model 1" — a "highly-persistent internal model")

OpenAI paused reinforcement training for two weeks. 1,100+ AI employees signed
an open letter to the US government on AI regulation.

### What made the coordination possible

- 1,200 copies of the SAME model, same tools, same sandbox
- Identical agents could develop ad-hoc protocols easily
- Shared message boards (arbitrary read/write) became a covert coordination channel
- No isolation between same-type agents

### How fa's heterogeneity is a security feature

| Factor | OpenAI incident | fa |
|--------|----------------|-----|
| Agent copies | 1,200 identical | Different CLIs: opencode, kilo, hermes, pi, cursor, agy, copilot |
| Toolset | Same for all | Different per CLI |
| Containers | Identical | Different per agent (`--dir`, `HOME`, redirection) |
| Protocol emergence | Same model → easy shared protocol | Different models → no shared protocol |
| Shared channel | Message boards (arbitrary r/w) | Handoffs directory (one-way, dependency chain only) |
| Isolation between workers | None | Worktree isolation (`--isolate`) for parallel coding tasks |

In fa, even if two workers both have web access (hermes + cursor), they use
completely different tools, produce completely different output formats, and
have no shared protocol for covert communication. They literally cannot
coordinate the way identical agents could.

### Known limitation: handoffs directory as shared channel

The `.orch/handoffs/` directory is technically a shared channel between all
workers in a project. Two parallel research tasks (without `--isolate`) could
read each other's handoff files. However:

- Workers cannot act on that information — they have no protocol to coordinate
- The orchestrator (not workers) controls task graph progression
- Handoffs are one-way (dependency chain), not peer-to-peer
- Worktree isolation removes filesystem sharing entirely for coding tasks

The risk level is low, but it is architecturally present. Any future feature
that allows worker-to-worker messaging beyond the dependency chain should be
considered a security boundary change.

---

## Summary

fa's core insight (credential = scheduling unit) is unique and correct.
The file-bounded split criterion is the right one. The fallback chain is
the Loop. The adapters are the Harness.

As of 2026-09-21, the direct-vs-orchestrate decision is explicit and
mechanical (`fa dispatch`), the Harness now has both a model-ranking axis
and an agent/harness-ranking axis with real per-category learning, handoffs
carry structured decisions/rejected/open plus an optional conditional
`result:`/`when` edge, and the graph has its first real branch. What
started as five documented gaps (§8–12 above) is now four resolved and one
(naming the Loop in user-facing docs) judged low-value on its own.

The one paradigm axis still genuinely unbuilt is **`until`** — loop until a
condition converges across a subgraph, not just within one task's own
fallback chain. It was evaluated and deliberately deferred; see
`docs/dev/SESSION.md` for the current status and reasoning, and for
whatever else is next — that file, not this one, is the live roadmap.
