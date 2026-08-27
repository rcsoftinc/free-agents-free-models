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

### Bucket map — VERIFIED BY PROBE (see `docs/ALIGNMENT.md` §8, §10)

User has added keys: OpenRouter->kilo, freemodel->opencode, kilo-gateway->hermes.
All credentials distinct; no shared wallets. **75 free models, 6 buckets, 0 phantom.**

| Bucket | Agent | Free | Health |
|---|---|---:|---|
| `kilo:anon` | kilo | 24 | ok |
| `openrouter.ai:845a3f96` | kilo | 21 | ok |
| `kilocode:fac9bae9` | hermes | 20 | ok |
| `nous:6b7db10d` | hermes | 6 | ok (rpm=50 rph=2100) |
| `opencode:14a1a2f8` | opencode | 4 | ok (weak: 3 models hang) |
| `freemodel:40d72418` | opencode | **0 — PAID** | excluded |

**Parallel width is now 5.** opencode no longer reaches OpenRouter (freemodel replaced
that auth entry); the OpenRouter key lives in kilo.

**OPEN DECISION for the user:** `freemodel` advertises 10 *paid* frontier models
(Claude Opus 4.6-4.8, GPT-5.3-5.5; cost.input 2.5 / output 15). Registry excludes it and
will never schedule there. If that gateway really serves them free, only a bill would tell
us. Recommend leaving it excluded — it is the only money-losing failure mode in the design.

**The rule, settled with the user:** a bucket is ONE lane no matter how many agents reach
it. Parallel width = healthy buckets. One agent per bucket; others are failover.

**Blocking defects found and FIXED this session:**
- **D2** — `hermes chat -m X -z P` was a usage error; correct is `hermes -m X -z P`.
  Fixed in `runner.sh:428`, `compress.sh:101`, `orchestrator.sh:166`. Layer B had NEVER
  invoked hermes successfully. **Hermes ranking history is poisoned; reset it.**
- **D4** — `IFS=$'\t'` collapses empty fields (tab is IFS whitespace), silently shifting
  columns. Hid an entire wallet. **`runner.sh`/`dispatch.sh` need auditing for this.**
- **D5** — provider name != wallet: kilo calls OpenRouter "openai". Join on local provider
  name; namespace bucket ids on the API host.
- **D6** — a route is (agent, model, **provider**). `hermes -m X` resolves only against the
  ACTIVE provider; kilocode models 404'd and looked `dead`. `--provider` fixes it. Would
  have written off a 20-model wallet.
- **D1** — resolved by construction: enumerate models per held credential, never metadata.
- **D3** — hermes exits 0 on HTTP 404 and on billing refusal; classification must be
  content-based (implemented in `classify()`).
- Stdin drain: `opencode run`/`kilo run`/`hermes` read stdin and swallowed loop input.
  All calls use `</dev/null`. **Same audit needed in runner.sh/dispatch.sh.**

**Built and working: `bin/buckets.sh`** — `identify` / `discover` / `probe [--all|--bucket ID]`
/ `show`. State `~/.local/state/free-agents/buckets.json`.
Bucket id = `wallet_host:credential_fp`, derived from the CREDENTIAL not the agent, so a
shared key collapses to one lane automatically and prints `** SHARED WALLET **`.
OAuth identity uses the JWT `sub` claim (nous tokens rotate hourly).
Health precedence: `rate_limited`/`no_credits`/`auth_error` -> bucket;
`timeout`/`dead` -> model only; `local_network` -> recorded nowhere.

**Built: `bin/kilo-add-openrouter.sh`** — user's draft, 3 bugs fixed (jq scope bug dropped
existing config; it erased the apiKey; `whitelist:["*"]` exposed paid models). Applied: 21
free models registered, whitelist scoped to exactly those.

### Done in earlier sessions
- Read entire repo; wrote `docs/ANALYSIS.md`.
- Fixed tmux: `~/.tmux.conf`, scrollback 200 000, mouse on. `docs/TMUX-CHEATSHEET.md`.

---

## Next step when resuming

1. Read `docs/ALIGNMENT.md`.
2. Run verification items §6 (**V3 first** — do kilo/hermes read `AGENTS.md`? It's the
   one that could change the design).
3. Continue the build order §5. **Steps 1 (git), 1.5 (D2) and 2 (bucket registry) are
   DONE** — see `docs/ALIGNMENT.md` §9. Next is **step 3**: fold `classify()` from
   `bin/buckets.sh` into the single dispatch engine and make the M1 bucket breaker act on
   the `health` field the registry now maintains. Then step 4 (B1 `--workdir`/`cd` +
   per-project state).

Keys have been added and re-discovered (6 buckets, 5 usable). After any further key
change: `bin/buckets.sh discover && bin/buckets.sh probe`, and watch for
`** SHARED WALLET **` in `show`.

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

