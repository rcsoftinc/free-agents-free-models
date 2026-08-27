# Project Rules

## Read first, every session
1. **`SESSION.md`** — current state of the work, open questions, next step.
2. **`docs/ANALYSIS.md`** — what this project is, all three layers, defect list.

## Working agreements
- The user runs this in **tmux and cannot read long terminal output.** Write any
  substantial answer, report, or plan to a file under `docs/` and give the path.
  Keep the terminal reply short.
- Update `SESSION.md` whenever the state of the work changes, so a closed window
  loses nothing. Scroll/copy help: `docs/TMUX-CHEATSHEET.md`.

## Mode routing
Read `AGENTS.md` — it is the single source of truth for the mode decision
(direct vs plan-first vs orchestrate). For orchestrate mode, the
`agent-coordinator` skill (in `.opencode/skills/agent-coordinator/`, loadable
directly at that path if your runtime has no skill loader) is the extended
playbook; if absent, follow the inline steps in AGENTS.md.
