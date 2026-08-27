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

### Key findings — VERIFIED BY PROBE, not inferred (see `docs/ALIGNMENT.md` §8)

**4 independent buckets, 4 separate credentials, all live.** Parallel width 3–4.

| Bucket | Credential | Agent | Free models |
|---|---|---|---|
| openrouter | opencode auth.json key `28644a4b…` | opencode | 20 |
| kilo | none stored; gateway serves unauthenticated | kilo | 21 |
| opencode-account | opencode auth.json key `c48fc67f…` | opencode | 4 (3 usable) |
| nous | ~/.hermes/auth.json OAuth, free tier | hermes | 6 |

- **The rule, settled with the user:** a bucket is ONE lane no matter how many agents reach
  it. Parallel width = healthy buckets. One agent per bucket; others are failover, never
  concurrent load. Today the mapping is clean and 1:1.
- **`opencode` is the only agent spanning two buckets** (own account + OpenRouter key).
  Different wallets, so concurrent use is legitimate — proving the constraint is
  per-bucket, not per-agent.
- Nous publishes real quota in its token: **50 rpm / 2100 rph / 500k tpm / 6M tph**, free tier.

**New blocking defects found this session:**
- **D1** — `discover.sh` catalogs *advertised* models, not *authenticated routes*. It
  invented 7 phantom `hermes/openrouter` entries and missed the entire nous bucket
  (372 advertised / 6 usable). Discovery must prove reachability.
- **D2 — FIXED.** `hermes chat -m X -z P` was a usage error (rc=2); correct form is
  `hermes -m X -z P`. Was wrong in `runner.sh:428`, `compress.sh:101`,
  `orchestrator.sh:166`. **Layer B had never once invoked hermes successfully** — every
  attempt was scored as a model failure. **Hermes ranking history is poisoned; reset it.**
- **D3** — hermes exits **0** on HTTP 404 and on billing refusal. Exit codes are not a
  success signal; classification must be content-based.
- `opencode/mimo-v2.5-free` reproducibly hangs (>200s, no response) — blocklist it.
- `.env`'s `FREEMODEL_API_KEY` matches no key in opencode's auth.json — stale/unused.

**Earlier claim CORRECTED:** ANALYSIS/ALIGNMENT §1 said hermes has no `nous` provider.
Wrong — that came from the catalog, and the catalog was incomplete. Nous is hermes's
active provider and a real independent bucket.

**Built this session — `bin/buckets.sh` (step 2), working:**
`identify` / `discover` / `probe [--all|--bucket ID]` / `show`.
State: `~/.local/state/free-agents/buckets.json` (global; per-project run state comes later).
Live: **4 buckets, 58 free models, 0 phantom, all 4 health=ok.**

- Bucket id = `provider:credential_fp`, **derived from the credential, not the agent** —
  so shared keys collapse to one lane automatically and are flagged as SHARED WALLET.
- Identity is stable, not secret-derived: OAuth uses the JWT `sub` claim, because hermes's
  nous token rotates hourly and would otherwise mint a new bucket every hour.
- Health precedence implemented: `rate_limited`/`no_credits`/`auth_error` condemn the
  **bucket**; `timeout`/`dead` demote the **model only**; `local_network` is recorded
  **nowhere**. Proven in practice — the opencode wallet had 2 of 4 models hang for 90s each
  and still came out `health=ok` on the third. Naive logic would have discarded that lane.
- **D1 resolved by construction**: models enumerated per held credential, never from
  third-party metadata. Verified each CLI advertises only its authenticated providers.
- **Bug found + fixed: stdin drain.** `opencode run`/`kilo run`/`hermes` read stdin and
  swallowed the probe loop's input, so only one bucket was ever probed. All calls now use
  `</dev/null`. **`runner.sh` and `dispatch.sh` still need auditing for the same defect.**
- Blocklist: `opencode/mimo-v2.5-free` (hangs). `opencode/hy3-free` and
  `opencode/muse-spark-1.2-contributor-free` also hang — add them.

**Also done:** `git init` + baseline commit (89 files; `.env` and `.backups/` gitignored).
D2 fixed in all 3 call sites. 3 commits total.

**Correction:** `.env`'s `FREEMODEL_API_KEY` **IS** opencode's OpenRouter key (same
fingerprint `267745bc…`) — an earlier claim that it matched nothing came from a broken
fingerprint loop. The bootstrap bridge works.

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

**USER IS ABOUT TO ADD API KEYS TO ALL AGENTS.** After they do, run:
```
bin/buckets.sh identify && bin/buckets.sh discover && bin/buckets.sh probe
```
Watch for `** SHARED WALLET **` in `show`. If a key is reused across agents they collapse
into one bucket — one lane, never parallel. Distinct keys = genuinely new lanes. The
registry detects this automatically; no config needed.

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

