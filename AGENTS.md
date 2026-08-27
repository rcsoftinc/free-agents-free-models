# Agent Workflow — Read This First

Every coding agent (opencode, kilo, hermes, claude) reads this file. It decides
**how** you work on a request. Follow it exactly.

## The golden rule: pick the cheapest tool that does the job

| Trigger in the first user message | Mode | What you do |
|---|---|---|
| Small, bounded task (one file, one function, a game, a script, "add X to Y") | **direct** | Work in your own context. Do NOT load skills, do NOT spawn subagents. Just do it. |
| "big project", "architecture", "full-stack", "multi-module", "design system" | **orchestrate** | See workflow below. |
| Explicit invocation phrase (any of): `use agents`, `orchestrate`, `coordinate`, `plan this`, `>>coordinator` | **orchestrate** | See workflow below. |
| "research", "plan", "compare options", "decide between A and B" | **plan-first** | Research in your own context, then present a plan + TODO list for approval before writing code. |

> When in doubt: a request that touches 3+ independent components, needs
> parallelizable work, or risks blowing one context = **orchestrate**.
> Everything else = **direct**.

## Orchestrate workflow (multi-agent, big projects)

This is where the `agent-coordinator` skill (if available) OR the steps below
apply. Both are equivalent; if your runtime has the `skill` tool, load
`agent-coordinator` for the extended detail. If not, follow these steps.

### Phase 0 — Decide & declare (cheap)
- One message: state mode = ORCHESTRATE, list the components you foresee,
  estimated task count. Do NOT write code yet.
- If the user hasn't approved a plan, outline it in ≤10 lines and ask.

### Phase 1 — Research & planning (single context)
- Do all research/architecture in YOUR context first. Produce:
  - `TODO`-list (todotool): one item per deliverable task, each item **self-contained**
    (path(s) touched, interface contract, acceptance criteria, what to NOT touch).
  - A short plan doc in `docs/plan.md` (only if project has no plan yet).
- Never re-read the whole repo per task. Task items carry their own spec.

### Phase 2 — Assign & dispatch (parallel, isolated)
- Each TODO item becomes ONE subagent invocation with the **executor role**:
  - input: the self-contained spec + explicit file boundary
  - output: implemented files + how to verify + any blockers
- Run independent tasks in parallel; respect dependency order only when needed.
- Use free-model fallback per subagent (`oc.sh`/`oc.ps1` skill) if available so a
  rate-limited model never blocks a task.

### Phase 3 — Review & integrate (cheap)
- For each subagent result: run the declared verification (tests/lint/build).
- Do NOT re-architect the subagent's code; fix only integration gaps.
- Update the TODO list as tasks complete. Escalate only real blockers.

### Token discipline (this is a goal too)
- Keep Phase 0/1 small: plan in ≤10 lines, specs in ≤6 lines each.
- Isolated subagent contexts = no compaction retries = fewer wasted tokens.
- Review by diff + test output, not by re-reading everything.

## Direct mode (default for small tasks)

Just do the work: read what you need, edit, verify with available tests/lint,
report done. No skills, no subagents, no ceremony.