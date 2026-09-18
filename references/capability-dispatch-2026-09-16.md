# Capability-Aware Dispatch

*September 2026*

## What it does

Each agent declares its capabilities via `<agent>_caps()`. The scheduler in
`bin/run.sh:candidates()` filters dispatch candidates by matching the task
category's required capabilities against each agent's declared capabilities.

This prevents sending research tasks to coding-only agents that would fail or
hallucinate web results.

## Architecture

```
Task category → category_caps() → "web,research"
Agent         → adapter_caps()  → "code,reasoning,shell,git,file"

Filter: does agent_caps contain ANY of the required caps?
  YES → include in candidate chain
  NO  → exclude (don't waste the dispatch)
```

## Category → Capability Mapping

| Category | Required | Rationale |
|----------|----------|-----------|
| `coding` | `code` | Must be able to write/edit code |
| `research` | `web,research` | Must be able to search/browse the web |
| `reasoning` | `reasoning` | Must be able to analyze, trace logic |
| `fast` | `code` | Simple code changes (same as coding) |
| `general` | `code` | Mixed work, code is baseline |

## Agent Capabilities

| Agent | Caps | Notes |
|-------|------|-------|
| **opencode** | `code,reasoning,shell,git,file` | No web |
| **kilo** | `code,reasoning,shell,git,file` | No web |
| **hermes** | `web,browser,code,research,reasoning,shell,git,file` | Full suite |
| **copilot** | `code,reasoning,shell,git,file` | No web |
| **cursor** | `web,code,reasoning,shell,git,file` | Has web via `--context web` |
| **agy** | `web,code,research,reasoning,file` | Google-backed, has search |
| **pi** | `code,reasoning,file` | No web |

## Fallback behavior

If no agent has the required capability (e.g., research task but hermes/cursor/agy
are all down), the filter produces zero candidates and the task exits with
"no candidates" — a clear failure instead of a silent hallucination.

This is correct: better to fail immediately than waste a lane on an agent that
can't do the job.
