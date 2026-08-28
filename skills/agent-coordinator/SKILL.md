# Agent Coordination Workflow

The coordinator playbook. `AGENTS.md` points here once its gate has been passed.
Works for any runtime (opencode, kilo, hermes, claude) — the coordinator is
whatever agent was started, and the steps are patterns you map onto your own
subagent facility or onto `bin/orch.sh`.

Load this skill ONLY after the gate in `AGENTS.md` says orchestrate. For anything
else, do the work directly — do not load this.

## The gate, restated (do not skip it)

Both must hold:

1. **≥2 tasks with disjoint file sets and no dependency between them.**
2. **`bin/buckets.sh lanes` reports ≥2.**

The second is the one that gets forgotten. Lanes are *credentials*, not agents:
three agents sharing one API key are **one** lane, and running them concurrently
does not go faster — it races the same wallet into the same rate limit. With one
healthy lane, orchestrating a perfectly-splittable job is strictly worse than
doing it directly.

Lane count is live state, not a property of the machine. A wallet that was healthy
this morning may be rate-limited now, so check at the moment you decide.

```sh
bin/buckets.sh lanes -v
```

## Phase 0 — Declare (one message)

One message, ≤10 lines. State:
- mode = ORCHESTRATE
- the components you foresee (list them)
- estimated task count

No code yet. If the user gave a vague goal, ask 1-3 sharp questions OR emit the
plan for approval. Do not start writing code until the plan is approved.

## Phase 1 — Research & planning (single context)

Do ALL thinking in this one context. Output:

1. **TODO list** (your runtime's todo/task tracker). Rules for every item:
   - Self-contained: `paths touched + interface contract + acceptance criteria + what NOT to touch`
   - Executable by a subagent with NO other context
   - Small enough that one item won't overflow one subagent context
   - Independent items get no interdependency; dependent items appear in order (write it in the item).
2. Plan doc at `docs/plan.md` only if the project has no plan file yet.

Do NOT spawn subagents to do research; research in your own context so the plan
is coherent. Keep plan ≤10 lines of prose.

## Phase 2 — Dispatch

Write the task graph, then hand it over. You specify; you do not schedule.

```json
{ "tasks": [
    { "id": "api", "deps": [], "files": ["src/api.js"], "category": "coding",
      "prompt": "<self-contained spec: what to build, the interface contract, what NOT to touch>" } ] }
```

```sh
bin/orch.sh run tasks.json      # width = healthy lanes; one lane per credential
bin/orch.sh status              # progress, derived from the journal
bin/orch.sh resume              # after ANY interruption - safe, replays the journal
```

What the runner guarantees, so you do not re-implement it:

- **One lane per credential.** Two tasks never share a wallet concurrently.
- **Routing around trouble.** Busy lanes are skipped; a wallet that returns a
  rate-limit, billing or auth error is put in cooldown and its remaining models
  are skipped rather than tried one at a time.
- **Attribution.** A model that hangs is demoted alone; a network failure of your
  own is recorded nowhere.
- **File boundaries.** Tasks with overlapping `files` never run concurrently.
- **Verification.** A task's declared `files` must exist afterwards or it is marked
  failed, whatever the agent claimed.

`files` is therefore load-bearing, not documentation. If you cannot write a task's
file boundary down, it is not an independent task.

## Phase 3 — Review & integrate

Per result:
- Run the declared verification. Trust test/lint output over prose.
- Inspect by DIFF only (not re-read whole files).
- Fix only integration seams, never re-architect the subagent's code.
- Update the TODO as tasks complete. Escalate only real blockers (wrong boundary,
  missing verification, dependency violation).

## Token discipline (a real goal)

- Phase 0/1: plan ≤10 lines; each spec ≤6 lines. Dense beats verbose.
- Never re-read a file a subagent already read. Ask the subagent for the facts.
- Compaction is wasted context: isolated subagent contexts avoid most compactions.
- If context pressure rises in your own context, delegate the oldest resolved
  section to a subagent and drop it from yours.

## Failure handling

- Subagent times out → bump the TODO item, re-dispatch with tighter scope, mark why.
- Subagent produces wrong boundary → revert its change, widen scope on the item.
- Tests keep failing → stop, diagnose in your context, fix at the seam, re-run.
- Rate-limited model → rely on the fallback chain; never block on one provider.

## Definition of done

- Every TODO item completed and verified by its acceptance criteria.
- One pass of integration verification (the repo's test/lint entry point).
- Report: summary of what each component does + where + how to run/verify.