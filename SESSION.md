# SESSION STATE — read this first on resume

**Last updated:** 2026-08-27 (Claude Code / Opus 5 session)

---

## Where we are right now

**Phase: SCOPE ANSWERED. Alignment written. Awaiting go-ahead on the build order.
No project code changed yet.**

Read in this order:
1. **`docs/ALIGNMENT.md`** ← the current source of truth: the user's goal as a spec,
   the factual corrections, the target architecture, the build order.
2. `docs/ANALYSIS.md` — repo inventory + defect list (still valid, except §7 which
   ALIGNMENT.md supersedes).

### The scope question is now ANSWERED
User stated the goal directly: fresh Debian, three agents installed, cd into any
folder, whichever agent starts becomes the coordinator, recruits the others as
parallel builders only when the work benefits, never collides, survives limits and
network drops, resumes unfinished work. Objective: maximize free.

**Answer to "which layer":** none as-is. Keep **A's engine** + **C's contract**,
delete **B's duplicate engine and global state**, and add a **bucket registry**
underneath — the primitive no layer has today.

### Key findings this session (evidence: `.orchestrator/catalog.json`)
- **Three agents ≠ three free pools.** Real buckets: `opencode-account` (4 free),
  `kilo-gateway` (21), `your-openrouter-key` (22, shared by opencode AND hermes).
- **Hermes adds no independent quota** — all 7 of its free models are openrouter,
  5 of them duplicates of opencode's. It's a third *runtime*, not a third wallet.
  No `nous` provider exists in the catalog.
- **The no-collision key must be `(bucket, upstream_model)`,** not agent+model.
  Today `runner.sh` schedules agent-first — backwards.
- **Tokens aren't the scarce resource; requests-per-bucket are.** Optimize for
  bucket diversity, not token count.
- **Missing and valuable:** bucket circuit breaker (M1), `local_network` error class
  so an internet drop doesn't poison rankings for 72h (M2), per-project state (M4),
  structural (not keyword) parallel gate (M5).

### Done in earlier sessions
- Read entire repo; wrote `docs/ANALYSIS.md`.
- Fixed tmux: `~/.tmux.conf`, scrollback 200 000, mouse on. `docs/TMUX-CHEATSHEET.md`.

---

## Next step when resuming

1. Read `docs/ALIGNMENT.md`.
2. Run verification items §6 (**V3 first** — do kilo/hermes read `AGENTS.md`? It's the
   one that could change the design).
3. Then execute the build order §5, starting with **step 1: `git init`** — this tree
   still has no version control.

---

## Top defects to fix (full detail + file:line in `docs/ANALYSIS.md` §6)

| ID | Severity | Summary |
|---|---|---|
| **B1** | **blocking** | `runner.sh:417` never `cd`s to the target project — agents write into the orchestrator repo. Evidence: `JWT_AUTH_GUIDE.md` at root. |
| **B2** | **blocking** | `orchestrator.sh:94` plan generation is a single model, single shot, no fallback → one rate-limit kills the run. |
| A1 | architectural | Three divergent fallback engines (`oc.sh`, `runner.sh`, `dispatch.sh`) + two unsynced state stores. |
| A2 | architectural | Orchestrator state is global (`SCRIPT_DIR/.orchestrator`), not per-project. |
| A3 | architectural | Layer B has no SKILL.md / installer / packaging. |
| H1 | hygiene | 442 unpruned files in `.orchestrator/.backups/`. |
| H2 | hygiene | `test_runner.sh` asserts PASS on `rc=124` (a timeout). |
| H3 | hygiene | `.orchestrator/config.json` read but missing. |
| H4 | hygiene | Root `scripts/` + `AGENTS.md` + `CLAUDE.md` are duplicate copies of workflow-kit output. |
| H5 | hygiene | `JWT_AUTH_GUIDE.md` at root is test debris. |
| S1 | stale | `opencode-free-agents/CONTEXT.md` claims pending Windows PS validation + uncommitted git work. |
| S2 | stale | **This directory is not a git repo.** No version control at all. |

---

## Environment facts (verified this session)

- CLIs present: `opencode` 1.17.20, `kilo` 7.5.5, `hermes` 0.20.5, `jq`, `curl`,
  `sqlite3`, `flock`, `timeout`.
- `.orchestrator/catalog.json`: 559 models, **52 free**.
- Test suite: **14/14 suites passing** (`bash test/run_all.sh`, results → `test/test.log`).
- All shell scripts pass `bash -n`.
- `.env` at root holds a real `FREEMODEL_API_KEY` and is gitignored.
- Running inside tmux; user cannot see long terminal output → **write long output to
  files, don't rely on scrollback.**

---

## User preferences (carry forward)

- Working in **tmux**; long answers must be saved to disk, not just printed.
- Wants a **personal-use production-ready skill**, not a demo.
- Reviews analysis before approving work — present findings, then wait.

