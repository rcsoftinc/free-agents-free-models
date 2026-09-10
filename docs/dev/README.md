# Developer notes

This directory holds design history and working notes for contributors. They are
kept for context on *why* decisions were made, not as current specifications.

For the current state of the tool, start at the repo root: `README.md` →
`CLAUDE.md` → `SESSION.md`.

## What's here

| File | Purpose |
|---|---|
| `ALIGNMENT.md` | The original design analysis — bucket identity, error attribution, and the build order. Source of truth for *why* the tool works the way it does. |
| `SESSION.md` | Current state, invariants, bugs the suite found, and next steps. The only file kept current on purpose. |
| `ANALYSIS.md` | The pre-rebuild survey (historical). |
| `RUN-2026-08-30-*.md` | Records from the first real unattended builds. |
| `TOKENS-AND-HANDOFFS.md` | Why handoffs were built cheap and token accounting was scoped out. |
| `TMUX-CHEATSHEET.md` | Terminal workflow reference (scrolling, copy-mode, output capture). |

These files are not the specification — `test/` is. Prose can drift; tests cannot.
