# Agent Workflow — Read This First

Every coding agent (opencode, kilo, hermes, pi, copilot, cursor, agy) reads this file. It decides **how** you work on a request.

## Default: work directly

Read what you need, edit, verify, report. No skills, no subagents, no ceremony.
**This is the right answer for almost everything**, including tasks that sound big.

Fanning out is not free: every worker re-reads its own spec, and workers that land
on the same credential race each other into the same rate limit. Orchestration pays
only when the work genuinely splits.

## The gate: when to orchestrate instead

Do **not** decide from the wording of the request. "Big project", "architecture" and
"full-stack" are not evidence, and a plainly-worded request can be perfectly
parallel. Decide from the structure of the work and the state of the machine.

Orchestrate only when **both** hold:

1. **The work splits.** You can name **≥2 tasks** that
   - touch **disjoint sets of files**, and
   - do **not** depend on each other's output.
2. **There is somewhere to run them.** `fa lanes` reports **≥2**.

If (1) fails, parallelism has nothing to do — work directly.
If (2) fails, parallelism has nowhere to go: with one healthy lane, concurrent
tasks queue behind one credential and simply collide. **Work directly.**

```sh
fa lanes        # -> integer; offline, cheap, safe to call every time
fa lanes -v     # which wallets, which agents, how many free models
```

(If `fa` is not on PATH this project was installed `--standalone`; use
`bash bin/buckets.sh lanes` instead.)

A useful check before committing to a split: if you cannot write each task's file
boundary down, the tasks are not actually independent and you have not found a
split — you have found one task.

## Orchestrate workflow

### Phase 0 — Declare (cheap)
State: mode = ORCHESTRATE, the tasks you foresee with their file boundaries, and
the lane count you got. Do not write code yet. If the user has not approved a plan,
outline it in ≤10 lines and ask.

### Phase 1 — Plan in ONE context
Produce a task graph. Every task is **self-contained**: it carries its own spec and
never assumes the worker has seen the repo, the conversation, or another task.

```json
{ "tasks": [
    { "id": "api",
      "prompt": "<self-contained spec: what to build, the interface contract, what NOT to touch>",
      "deps": [],
      "files": ["src/api.js"],
      "category": "coding" } ] }
```

`files` is not documentation — the runner refuses to run overlapping tasks
concurrently, and it verifies afterwards that the declared files exist.

### Phase 1b — Keep the small work

Do not dispatch everything. Take the small, quick, context-heavy tasks yourself
and give the lanes the substantial, self-contained ones. Your context is already
loaded; a worker starts cold, on a weaker model, and cannot ask you anything.
**If writing the spec would take as long as doing the work, do the work.**

### Phase 2 — Dispatch
```sh
fa orch run tasks.json     # parallel width = healthy lanes, automatically
fa status                  # progress, from the journal
fa resume                  # after any interruption
```
The runner holds **one lane per credential**, routes around busy and rate-limited
wallets, and journals every transition. You do not schedule; you specify.

### Phase 3 — Review and integrate
Run the declared verification (tests, lint, build). Review by **diff and test
output**, not by re-reading the repo. Do not re-architect a worker's code — fix
integration gaps only. Escalate real blockers.

## Task categories

Every task has a `category` that determines its verification:

| Category | Output | Verification |
|----------|--------|--------------|
| `coding` (default) | Code changes | Files exist, tests pass (if `--validate`) |
| `research` | Investigation report | Report file exists in `docs/` or `.orch/reports/`, no code modified |
| `reasoning` | Analysis or design | Files exist, logic is sound |
| `general` | Mixed output | Files exist |
| `fast` | Quick task | Files exist |

If `category` is omitted, it defaults to `coding`.

## Project modes

Projects can set an autonomy mode in `.orch/config.yaml`:

```yaml
# .orch/config.yaml
mode: strict      # verify after every change (default)
# mode: push      # can push and create PRs
# mode: local     # no remote operations

automerge: false  # allow autonomous merging (only with push mode)
```

- **strict** (default): Run verification after every change.
- **push**: You can push and create PRs.
- **local**: No remote operations. Do not push or create PRs.

In `local` mode, any push or PR creation is a violation of the task.

## Parallel isolation

When the orchestrator runs multiple tasks with disjoint file sets, it may run each
in its own git worktree (enabled with `--isolate` or auto-detected). In isolation:

- You work in a separate copy of the repository, branched from HEAD.
- You do NOT have access to push, pull, or interact with remote repositories.
- Focus ONLY on the task you were given.
- Your changes will be merged back when you complete successfully.

## Exit report

Before ending your session, you MUST report:
- **Files changed**: list every file you created or edited
- **Verification status**: did tests/build/lint pass? what was the result?
- **Remaining work**: what's left to do (if anything)

No silent exits. If you end without reporting, you have failed the task.

## User instruction precedence

A current, explicit, concrete user instruction overrides any standing rule
within its exact scope. Ambiguity requires clarification first.
Destructive, irreversible, or security-sensitive actions still need explicit
user approval — no standing rule overrides this.

## What actually costs you

The scarce resource is **requests per credential**, not tokens. Free tokens cost
nothing, so the goal is not to minimise words — it is to keep independent wallets
busy and never to stack work onto one.

- Keep Phase 0/1 small: plan ≤10 lines, specs ≤6 lines each.
- Never re-read the whole repo per task; the spec carries what the task needs.
- A task that fails on every lane is a bad task, not a bad wallet. Rewrite the spec.

## Working on free models

These models are weaker at long agentic loops than frontier models. Tight,
file-bounded, self-contained specs are not token discipline — they are the
difference between a task succeeding and failing.

An agent reporting success is **not** evidence the work happened. Check the files.
