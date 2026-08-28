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
Read `AGENTS.md` for the mode decision. It is **generated** — the source is
`workflow-kit/AGENTS.md`; edit there and re-run `bash workflow-kit/install.sh .`
rather than editing the copy.

Default is direct. Orchestrate only when the gate passes: **≥2 tasks with disjoint
file sets and no interdependency, AND `bin/buckets.sh lanes` ≥ 2.** Lanes are
credentials, not agents — several agents on one API key are one lane, and running
them together only races that wallet into its own rate limit.

## The tooling
```
bin/buckets.sh   credential-bucket registry   (lanes | discover | probe | show)
bin/run.sh       the dispatch engine          (one task -> one result, with fallback)
bin/orch.sh      per-project task graph       (run | status | resume)
```
Design, findings and build order: `docs/ALIGNMENT.md` (current source of truth).
