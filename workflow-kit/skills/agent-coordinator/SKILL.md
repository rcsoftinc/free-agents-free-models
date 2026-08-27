# Agent Coordination Workflow

This is the UNIVERSAL coordinator playbook for big projects. AGENTS.md points here
when a request must be orchestrated. Works for any agent runtime (opencode, kilo,
hermes, claude) — the coordinator is whatever agent was started. All steps are
pattern descriptions, not tool calls, so you can map them to your runtime's own
subagent/orchestration facility.

Load this skill ONLY when the project is genuinely big (see AGENTS.md). For small
bounded tasks, do the work directly — do not load this.

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

## Phase 2 — Assign & dispatch

Each TODO item = ONE executor subagent run. Input contract per subagent:
- The self-contained spec from the TODO item
- Explicit file boundary (`touch A..Z only, never modify B`)
- Explicit verification (tests/lint/build command to run)
- Explicit output contract: files changed + how to verify + blockers

Dispatch: independent items in parallel. Respect dependency order. If your
runtime supports per-subagent model choice AND a free-model fallback chain
(e.g. `oc.sh`/`oc.ps1` from the `opencode-free-agents` skill), wire it so a
rate-limited model never blocks a task.

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