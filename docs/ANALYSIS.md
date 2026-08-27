# Project Analysis — `/root/opencode_tests`

> Written 2026-08-27 by Claude Code (Opus 5) after a full read of the repo.
> Purpose: reconstruct the complete context of this in-progress OpenCode project
> so it can be finished as a production-ready personal skill.

---

## 1. What this repo actually is

It is **not one project — it is three overlapping layers**, all aimed at the same goal:

> *Let AI coding agents do real work using only free models, never blocking on a
> rate limit, without burning the orchestrator's own context.*

```
/root/opencode_tests
├── opencode-free-agents/     LAYER A: the skill (headless opencode + free-model fallback)
├── *.sh + .orchestrator/     LAYER B: the orchestrator engine (plan → run → rank → hand off)
├── workflow-kit/             LAYER C: the installable "routing rules" kit
├── test/                     14-suite offline test harness for Layer B
└── AGENTS.md / CLAUDE.md     Layer C output, installed into this repo itself
```

---

## 2. Layer A — `opencode-free-agents/` (the actual SKILL; most mature)

**Purpose:** a portable, cross-platform skill any agent (opencode, kilo, hermes,
Claude Code) can call to delegate a task to `opencode` **headlessly**, and never
fail unless every free model everywhere is dead.

| Component | What it does |
|---|---|
| `scripts/oc.sh` / `oc.ps1` | **THE entry point.** Prompt + `-c category` (coding / reasoning / research / general / fast). Walks a ranked chain of free models, switches model mid-session on failure. Emits machine-readable `---OC-META---` footer (`session`, `model`, `attempts`, `category`). |
| `scripts/bootstrap.sh` / `.ps1` | One-way bridge `.env` → opencode's own `~/.local/share/opencode/auth.json`. Additive-only, backups kept, chmod 600. |
| `scripts/refresh.sh` / `.ps1` | Discovers free models from `opencode models --verbose` **metadata** (~2–3 s — deliberately NOT live probing, which took ~5 min). Rebuilds per-category rankings. |
| `scripts/classify-error.sh` | Shared error taxonomy. `--self-test` = 13 cases. |
| `scripts/find-free-providers.sh` | Scans models.dev for new free providers (found NVIDIA ~98 free models, Kilo 24, GitLab 23). |
| `scripts/install.sh` | One-shot: deps + opencode + keys + skill install. |
| `data/models.json` | Live per-model status: `ok / rate_limited / no_credits / timeout / context_overflow / auth_error / dead` + latency + rolling success counters. |
| `data/rankings.json` | Ordered candidates per category, rebuilt from `rankings-seed.json` + observed stats. |
| `data/manual-overrides.txt` | User-declared free models not marked free in metadata. |

**Exit codes:** `0` success · `2` ALL models exhausted · `3` bootstrap error.

**The clever part:** cross-model session continuity. `opencode run -s <id> -m <other>`
carries full history, so a quota failure silently moves the *same conversation* to a
different provider. Verified working.

**Error taxonomy / retry windows**

| stderr pattern | Meaning | Auto-retry after |
|---|---|---|
| `temporarily rate-limited upstream` / 429 | `rate_limited` | 30 min |
| `Unauthorized: Insufficient balance` | `no_credits` | 24 h |
| `UnknownError` / unexpected server error | `dead` | 72 h |
| killed after timeout | `timeout` | 10 min |
| context length / too large | never retried | — |

**Status:** genuinely well-hardened. 14 production-audit items closed, 11 documented
bug fixes, all 7 bash scripts pass `bash -n`, self-tests pass, E2E verified on Debian.

---

## 3. Layer B — the root orchestrator (biggest, least finished)

**Purpose:** a full **multi-agent project runner** across *three different CLI agents*
(opencode + kilo + hermes) with rankings that learn from observed results.

| Script | Lines | Role |
|---|---:|---|
| `discover.sh` | 404 | Probes installed agents, builds `catalog.json`. Currently **559 models, 52 free**. |
| `rankings.sh` | 103 | Builds chains per **role × task_type** (researcher/coder/reviewer/debugger/planner × analysis/implementation/…). |
| `orchestrator.sh` | 256 | Analyzes a project, asks the top-ranked model for a JSON phase/task plan → `project.json`. |
| `runner.sh` | 869 | **The engine.** Dependency resolution, parallel execution, per-attempt + per-task timeouts, exponential backoff honoring `Retry-After`, agent/provider distribution under `flock`, exhaustive combo fallback. |
| `promote.sh` | 110 | Feeds `success` / `failure` / `rate_limited` back into rankings. |
| `handoff.sh` | 214 | Captures completed-task output as a handoff for downstream tasks. |
| `compress.sh` | 137 | AI-summarizes a handoff so downstream tasks get context without the full transcript. |
| `resume.sh` | 122 | Restarts an interrupted project from its incomplete tasks. |

**Runner tunables (env):** `ATTEMPT_TIMEOUT=120`, `TASK_TIMEOUT=1800`,
`BACKOFF_BASE=5`, `BACKOFF_CAP=60`, `BACKOFF_FACTOR=2`, `MAX_PARALLEL`.

**`test/`** is a real harness: stub `opencode` / `kilo` / `hermes` / `curl` binaries on
`PATH`, 14 suites, **all currently passing** (backoff math, provider distribution,
exhaustion, parallel, edge cases, live run).

---

## 4. Layer C — `workflow-kit/`

**Purpose:** the cheap, universal front-end. `install.sh` drops into any project:

- `AGENTS.md` — mode router: **direct** (small bounded task) / **plan-first**
  (research, compare options) / **orchestrate** (big project, or the phrases
  `use agents`, `orchestrate`, `coordinate`, `plan this`, `>>coordinator`).
- `CLAUDE.md` — bridge so hermes / claude-code read AGENTS.md.
- `skills/agent-coordinator/SKILL.md` — the orchestrate playbook:
  Phase 0 declare → Phase 1 plan (single context) → Phase 2 dispatch (isolated
  subagents, self-contained specs) → Phase 3 review by diff + test output.
  Includes an explicit **token discipline** section.
- `scripts/dispatch.sh` — isolated-session task-graph runner. **This one does call
  `oc.sh`.** Produces `dispatch-report.json` (per task: id, executor, model, session,
  attempts, status, exit, tokens, elapsed).
- `scripts/measure.sh` — reads tokens + cost straight from opencode's sqlite store.

---

## 5. The through-line (the actual thesis)

> Run big multi-component projects on cheap/free models by
> **(1)** never letting one context blow up — isolated sessions + compressed handoffs,
> and **(2)** never letting a rate limit stop you — ranked fallback chains across
> models, providers, *and* agent runtimes, that learn from what actually works.

---

## 6. Defects and gaps found

### Blocking

**B1. `runner.sh` never `cd`s into the target project.**
`invoke_agent()` (`runner.sh:417`) runs `opencode run` in whatever cwd the runner was
launched from. `PROJECT_PATH` is stored in `project.json` and then never used for
execution.
*Evidence:* `JWT_AUTH_GUIDE.md` in the repo root — a test-run artifact an agent wrote
into the orchestrator instead of into the target project.
`dispatch.sh` gets this right (`--workdir`, `scripts/dispatch.sh:40`); `runner.sh` does not.
**This is the #1 blocker to "production ready."**

**B2. `orchestrator.sh` planning has no fallback.**
`generate_plan()` (`orchestrator.sh:94`) calls exactly one model, once, with `2>/dev/null`.
Rate-limited → invalid JSON → `exit 1`, whole run dead. The one place that most needs
the fallback chain is the one place that doesn't use it.

### Architectural

**A1. Three separate, divergent fallback engines.**
`oc.sh` (chain + session continuity) · `runner.sh` (its own retry/backoff/distribution,
**never calls `oc.sh`**) · `dispatch.sh` (calls `oc.sh`).
Two independent state stores with different schemas:
`.orchestrator/{catalog,rankings}.json` vs `opencode-free-agents/data/{models,rankings}.json`.
Nothing syncs them.

**A2. State is global, not per-project.**
`ORCH_DIR="${SCRIPT_DIR}/.orchestrator"` — only one project can be in flight, and its
state lives inside the tool's own directory.

**A3. Layer B has no packaging.** No SKILL.md, no installer, no frontmatter.
`workflow-kit/install.sh` installs Layer C only. There is no way to *use* the
orchestrator as a skill.

### Hygiene

- **H1.** `.orchestrator/.backups/` has **442 unpruned files** — `promote.sh:38` copies
  `rankings.json` on every call and never cleans up.
- **H2.** `test_runner.sh` passes on a timeout: logged `live run rc=124 attempts=13
  status=done`. rc 124 = `timeout` killed it, yet it asserted PASS. Weak assertion on
  the only live-agent suite.
- **H3.** `.orchestrator/config.json` is read by `discover.sh:26` but does not exist
  (silently defaults). Undocumented.
- **H4.** Root `scripts/` + `AGENTS.md` + `CLAUDE.md` are byte-identical copies of
  workflow-kit output installed into the repo itself — ambiguous source of truth.
- **H5.** `JWT_AUTH_GUIDE.md` at root is test debris, not a deliverable.

### Stale context

- **S1.** `opencode-free-agents/CONTEXT.md` says PowerShell validation on Windows is
  still pending and the git commit never happened.
- **S2.** **This directory is not a git repo at all.** The "6 commits on master" and the
  `C:\Projects\RCSoft\...` path in CONTEXT.md refer to a copy that is not here.
  Nothing in this working tree is under version control.

---

## 7. The open question

**Which layer is "the skill" to make production-ready?**

Read: **A is nearly there. B is the ambitious half-finished one.** The highest-value
move is likely collapsing B onto A's engine (one fallback implementation, one state
store) rather than maintaining both — but that is the user's call.
