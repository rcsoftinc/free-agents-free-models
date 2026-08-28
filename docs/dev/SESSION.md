# SESSION STATE — read this first on resume

**Last updated:** 2026-08-27 (Claude Code / Opus 5 session)

---

## Where we are right now

**Phase: BUILD ORDER COMPLETE (steps 1-9). All blocking + architectural + hygiene
defects closed.** Read `docs/ALIGNMENT.md` — it is the source of truth (supersedes
`docs/ANALYSIS.md` §7).

### The system

```
bin/buckets.sh   credential-bucket registry   lanes | discover | probe | show
bin/run.sh       THE dispatch engine          one task -> one result, with fallback
bin/plan.sh      goal -> task graph           planning WITH fallback (B2 fixed)
bin/orch.sh      per-project task graph       run | status | resume
bin/lib/         common.sh (paths, flock) + classify.sh (THE taxonomy, self-test)
skill/SKILL.md   packaged skill card (A3)
workflow-kit/    installer: AGENTS.md gate + CLAUDE.md + both skills + bin/
legacy/          Layer B, retired behind a banner; see legacy/README.md
```

**The core rule:** a bucket is one wallet `(provider, credential)` and it is the unit
of scheduling — NOT the agent. Two agents on one API key are ONE lane. Bucket ids
derive from the credential, so a shared key collapses automatically.

**Current lanes: 5** (`bin/buckets.sh lanes -v`). 75 free models, 0 phantom.

### Verified end to end
One sentence -> `bin/plan.sh` -> 3-task graph (correct deps, disjoint files) ->
`bin/orch.sh run` across 3 different wallets -> 361 lines of Python that parse, and
a CLI that actually runs. Fresh `workflow-kit/install.sh` into an empty dir also runs
a 3-task graph entirely through its own installed copy.

### What remains (nothing blocking)
- `opencode-free-agents/` (Layer A) still has its own `oc.sh`; the new engine does not
  use it. Either port its cross-model session-continuity trick into `bin/run.sh` or
  retire it to `legacy/` too. **This is the last duplicate engine.**
- `legacy/` can be deleted once its suites are ported to the new engine; there is
  currently NO test suite for `bin/` beyond `classify.sh --self-test`.
- `freemodel:40d724…` is excluded (advertises 10 PAID models). User decision if that
  gateway actually serves them free.
- S1: `opencode-free-agents/CONTEXT.md` still claims pending Windows PS validation.

## Defect table — ALL CLOSED (historical; detail in `docs/ANALYSIS.md` §6 and `docs/ALIGNMENT.md`)

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

