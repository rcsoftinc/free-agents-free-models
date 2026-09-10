# Validation Gate — Design Plan

## Problem

Agents report "done" on tasks that contain bugs, syntax errors, or failing tests. Currently `fa analyze` detects patterns post-hoc but does nothing to block bad work from reaching production. A validation gate would verify agent output before marking a task complete.

## Design Constraints

Must not break:
- Existing `fa run` / `fa orch` workflows (validation is opt-in)
- Journal format (append-only, crash-safe)
- Lane model (one lane per credential)
- Task graph structure (deps, file boundaries)
- `fa analyze` (stays post-hoc, non-blocking)

## Architecture

### Two-Phase Execution

```
Phase 1: BUILD  (existing)
  Lane A receives task prompt → builds → writes files → reports done

Phase 2: CHECK  (new, opt-in)
  Lane B (or same lane) receives validation prompt → reviews build output
    → PASS: task marked validated
    → FAIL + auto-fixable: fix loop (max N rounds)
    → FAIL + not auto-fixable: escalate to human
```

### Entry Point

```bash
fa run --validate "task prompt"        # single task with validation
fa orch run tasks.json --validate      # orchestrate with validation per task
```

`--validate` is the only new flag. Without it, behavior is identical to today.

### Validation Levels (progressive adoption)

| Level | Check | Auto-fix? | Blocking? |
|-------|-------|-----------|-----------|
| 1 | Syntax (`node --check`, `python3 -m py_compile`) | No | Yes |
| 2 | Tests (`npm test`, `pytest`, etc.) | Yes (retry) | After N retries |
| 3 | Lint (`eslint`, `shellcheck`, etc.) | Yes (retry) | After N retries |
| 4 | Review (subjective quality) | No | Escalate to human |

Start with Level 1 only. Add levels based on what actually catches bugs.

### Validation Prompt

The validator agent receives:
1. The original task prompt
2. The diff of what the builder changed
3. The validation level to apply
4. Instructions to output structured verdict: PASS / FAIL / ESCALATE

This is a **different prompt** from the builder — not self-verification.

### Fix Loop

```
validate → FAIL → builder gets feedback → rebuilds → validate → ...
```

- Max 3 rounds (configurable, env `FA_VALIDATE_MAX_ROUNDS`)
- Each round is a separate journal entry (crash-safe)
- If rounds exhausted → ESCALATE, pause for human
- Loop runs on the SAME lane (no extra credential cost)

### Journal Extensions

New event types (additive, existing events unchanged):

```json
{"ts":"...", "event":"validate", "task":"api", "round":1, "verdict":"fail", "reason":"syntax error in src/api.js:42"}
{"ts":"...", "event":"fix", "task":"api", "round":1, "trigger":"validate"}
{"ts":"...", "event":"validated", "task":"api", "rounds":2}
{"ts":"...", "event":"escalated", "task":"api", "reason":"3 validate rounds exhausted"}
```

### Task Graph Integration

In `tasks.json`, validation is a property of the task, not a separate task:

```json
{ "tasks": [
    { "id": "api",
      "prompt": "...",
      "validate": { "level": 1, "max_rounds": 3 },
      "deps": [],
      "files": ["src/api.js"] } ] }
```

Why not a separate task? Because validation needs the builder's diff and context. A separate task would re-read the repo cold — more tokens, less accurate.

### Lane Usage

- Builder uses Lane A
- Validator uses Lane A (after builder finishes) — sequential, no extra lane needed
- If all lanes are busy, validation waits (doesn't consume a second lane)
- In orchestration: validation of Task B can run while Task C builds (natural pipelining)

### Escalation Path

When validation fails and rounds are exhausted:
1. Task status = `escalated`
2. Journal records the failure reason + diff
3. `fa status` shows `escalated` tasks prominently
4. Human reviews, fixes manually, then `fa resume` continues
5. Or human provides feedback, `fa resume` re-runs the loop

### `fa analyze` Integration

`fa analyze` already reads the journal. It will automatically see:
- How many tasks required validation
- How many passed on first try vs needed rounds
- Which tasks escalated
- Common failure patterns across tasks

This feeds into `.orch/learnings.md` — "syntax errors in JS happen 40% of the time, mostly missing semicolons" → future builder prompts can include "always run node --check before reporting done."

## Implementation Phases

### Phase 1: `--validate` flag + Level 1 (syntax only)
- Add `--validate` to `run.sh` and `orch.sh`
- After builder completes, run syntax check on changed files
- If pass → mark `validated`
- If fail → escalate immediately (no auto-fix loop yet)
- Journal: new events `validate`, `validated`, `escalated`
- Effort: ~1 day

### Phase 2: Auto-fix loop
- On FAIL, send feedback to builder, retry
- Max rounds configurable
- Journal: `fix` event, round counter
- Effort: ~1 day

### Phase 3: Levels 2-3 (tests, lint)
- Detect test/lint commands from project config
- Run them as part of validation
- Auto-fix loop for test/lint failures
- Effort: ~2 days

### Phase 4: Level 4 (review)
- Subjective review prompt
- Always escalates (no auto-fix for subjective)
- Effort: ~1 day

## Risks

1. **Infinite loops** — mitigated by max_rounds + escalation
2. **False confidence** — syntax pass ≠ correct code. Be clear in docs what validation does and doesn't catch.
3. **Lane starvation** — validation holds a lane. If all lanes are validating, new builds queue. Mitigated: validation is fast (syntax check is seconds).
4. **Prompt diversity** — builder and validator use similar prompts → similar blind spots. Mitigated: validator prompt is explicitly adversarial ("find what's wrong with this code").

## Non-Goals

- Full CI pipeline replacement (no deployment, no integration tests)
- Multi-agent consensus (no "3 agents vote")
- Automatic merging (human always has the final say)
- Support for non-code tasks (validation is code-specific)

## Open Questions

1. Should validation be on by default for `fa orch` (multi-task) but off for `fa run` (single task)?
2. Should the validator be a different model than the builder (diversity), or same model (consistency)?
3. Should `fa status` show validation stats prominently, or only when there's a failure?
4. Should escalated tasks auto-create a GitHub issue, or is that over-engineering?
