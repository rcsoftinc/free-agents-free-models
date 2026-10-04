# SESSION STATE — read this first on resume

**Last updated:** 2026-10-03

---

## Where we are

**Complete, working, and proven on a real project.** Published (public) at
`github.com/rcsoftinc/free-agents-free-models`. Full suite green:
**564 assertions, 32 suites, offline.**

**It has built real software unattended.** All independently verified against what
the code does rather than what the agents reported:

| Project | Shape | Tasks | Peak lanes | Time | Result |
|---|---|---|---|---|---|
| [mdsite](https://github.com/noonelifecoach/mdsite) | chain | 6 | 3 | 7m38s | 419 lines, 29 tests |
| [fmtkit](https://github.com/noonelifecoach/fmtkit) | wide | 8 | **5** | 5m09s | 503 lines, 8 modules |
| [coldrun](https://github.com/noonelifecoach/coldrun) | starved | 5 | **1** | — | 5 modules, 9 requeues, 0 failures |



## Documentation map

| Where | What |
|---|---|
| **[Route map](https://claude.ai/code/artifact/68bc7de1-6a06-4242-86f0-957904c09e1f)** | Visual: every route the tool can take — discovery, the gate, the dispatch loop, the taxonomy, and what is deliberately absent |
| **[One run, end to end](https://claude.ai/code/artifact/727f0341-8a96-4e91-99fd-47ec5cdb7076)** | Visual: a real recorded build, with the wide and starved runs compared |
| `docs/dev/ALIGNMENT.md` | The design and every finding — **the source of truth** |
| `docs/SETUP.md` | Where each agent keeps its credentials (the non-reproducible part) |
| `README.md` | User-facing: install, use, invariants |

## The core idea

**A bucket is one wallet: `(provider, credential)`. It is the unit of rate
limiting, so it is the unit of scheduling — never the agent.** Two agents sharing
one API key are ONE lane. Bucket ids derive from the credential, so a shared key
collapses automatically.

**Give each agent a DIFFERENT free key** — that is what multiplies lanes.

## How it is used

```sh
cd myproject
gh repo clone rcsoftinc/free-agents-free-models .free-agents
.free-agents/setup.sh
opencode                                    # or kilo / hermes / cursor-agent / copilot
> paste .free-agents/prompts/coordinator.md # one prompt; it routes on intent
```

`setup.sh` bootstraps by itself when the machine has no registry — it announces
the ~2 min network step first, and `--no-bootstrap` skips it. On a machine that
has already run it, setup just reports the registry's state and there is nothing
to do. The tool lives in `.free-agents/`, this project's run journal in `.orch/`,
and the registry + leases are **machine-wide** at
`~/.local/state/free-agents` (override with `FREE_AGENTS_STATE`).

**Refreshing is event-driven AND self-maintained.** `setup.sh` and `fa doctor`
both report `current` / `STALE` / `aged:<days>` / `MISSING`, and `fa refresh`
(alias for `bootstrap`) is the fix. `bootstrap` also installs a **daily cron**
(`fa schedule` / `fa unschedule`, idempotent, `FA_NO_SCHEDULE=1` opts out) so a
fresh clone + `setup.sh` needs no manual refresh step and a spent copilot budget
drops off on its own. The cron line carries the `PATH` it was scheduled from -
cron's own finds no agent CLI, which kept it from ever working until 2026-10-03
(see that entry below) - and `fa doctor`'s **daily refresh** section says
whether it can actually work. Staleness is measured by **credential fingerprint**,
because that is what actually invalidates a registry:

| Cause | Detected |
|---|---|
| credential added or swapped | exactly — live fingerprints vs `identified` |
| agent installed | exactly — installed but absent from `examined_agents` |
| provider changed its free-model list | only a soft age note (default 14 days) |
| health, cooldowns, rankings | never stale; self-correcting at runtime |

`mtime` was the obvious implementation and is wrong: the nous OAuth token rotates
hourly and kilo rewrites its db every run, so both configs read as "changed"
constantly. Fingerprints do not move — the nous one is the token's `sub` claim.

## What the real run showed

- **Handoffs work, provably.** `template.py` implemented dotted paths
  (`{{ user.name }}`) that the spec never asked for, reported it in its handoff,
  and `build.py` matched it with `key.split(".")`. Without the handoff that
  capability would have been silently lost — a worker receives a string, not a
  repository.
- **Zero incidents**, against four in the previous run. Two things changed:
  suitability filtering removed 10 drawable-but-useless models, and the specs were
  far more precise.
- **The ceiling is spec quality, not model capability.** The earlier run went 1/4,
  then 4/4 once specs named the exact failure modes; this went 6/6 first time.
  Do not read the 6/6 as free models becoming reliable.
- **The gate is about THROUGHPUT, not correctness.** coldrun orchestrated on one
  lane — which the gate forbids — and produced identical working output, merely
  serialized. Orchestrating below 2 lanes buys nothing; it does not break.
- **Parallelism was limited by the GRAPH, not the lanes.** Only two tasks had no
  dependencies, so `build` waited 294s on `parser` while three lanes sat idle. A
  wider graph would use the lanes better; a chain-shaped one cannot.

## Layout

```
bin/fa            entry point: bootstrap doctor lanes run plan dispatch/go rank profile quota orch status resume findings
bin/buckets.sh    credential registry      lanes | discover | probe | show | profile | quota
bin/run.sh        dispatch engine          fallback chain, bucket lease, breaker, agent/harness ranking, exclusion trace
bin/plan.sh       goal -> task graph       planning itself has fallback, rejects malformed graphs locally
bin/orch.sh       per-project task graph   run | status | resume (journal replay), "when" conditional edges
bin/lib/          common.sh, deps.sh, adapters.sh, classify.sh, quota.sh, schedule.sh + adapters/ (one file per harness)
data/model-seed.json      OPTIONAL cold-start opinion per model/category - hand-edit or delete, nothing breaks
data/provider-notes.json  OPTIONAL ToS/evidence note per provider - same rules as model-seed.json
prompts/          coordinator.md - the single pasted prompt
skills/           skill cards, linked into the project by bootstrap
test/             32 suites, a stub for every agent, fixture registry - fully offline
```

## Lanes on this machine

As of the 2026-10-04 refresh (the first scheduled one that ever worked):

| Lane | Agent | Usable free models |
|---|---|---:|
| `kilo:anon` | kilo | 23 |
| `antigravity:e08c2f2bdf11` | agy | 14 |
| `nous:9162a7f63a81` | hermes | 9 |
| `opencode:zen` | opencode | 9 - `[TOS:avoid]`, see `data/provider-notes.json` |
| `openrouter:016cd6da3edd` | pi | 90 listed, health `unknown` - the three it probed were `:batch` models, all `dead` (see the 2026-10-03 entry) |
| `copilot:*` / `cursor:*` | copilot / cursor | METERED - opt-in, tried last |

Metered wallets are auto-included once detected with a token and credits remain;
`FA_METERED=0/1` forces them off/on (`--no-metered` / `--allow-metered`). They
cannot bill you (`overage_permitted: false`) and renew monthly; `fa lanes -v`
shows credits left, and a spent allowance drops off the lane list on its own.

## Invariants that must not regress

- **One task per credential at a time.** Two agents on one key do not go faster.
- **Attribution.** Wallet faults (rate limit / billing / auth) cool the WALLET;
  a model hang demotes the MODEL only; `local_network` is recorded NOWHERE.
- **Cooldowns escalate.** A first failure is short (15m) — a single transient 401
  once benched a healthy 21-model wallet for 24h.
- **Verify, do not trust.** A task's declared `files` must exist afterwards AND,
  on an existing codebase, must have **changed** — a file left byte-identical is
  as unverified as one never written. An agent reporting success is not evidence.
- **Findings are the feedback path**, and cover eight kinds: `unclassified`,
  `all_lanes_failed`, `unverified_repeat`, `missing_handoff`, `deadlock`,
  `orphan_abandoned`, `malformed_result`, `note`. The first seven are the tool
  noticing something about itself; **`note` is the manual channel** for what no
  heuristic reaches (an ambiguous spec, a plan that split the work wrong) —
  without it that class of failure dies with the terminal session. Never
  auto-filed; the coordinator reports, the user decides. Everything is
  redacted on the way in, and repeats collapse by fingerprint.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, hermes via
  `HOME` (it honours neither `cwd` nor `--in`). There is no uniform flag.
- **These CLIs exit 0 on hard failures.** Classify on output, never on rc.
- **Staleness is measured against what discovery EXAMINED, not what it produced.**
  The registry records `identified` (every credential inspected) and
  `examined_agents` (every agent inspected, unauthenticated ones included).
  Comparing against buckets instead would report a key that reached no free
  model, or an agent with no login, as "new" forever.
- **Age never fails `doctor`.** It is advisory. Only credential and agent changes
  are hard staleness.
- **`skills/` at the repo root is the ONLY copy.** opencode reads
  `.opencode/skills/` relative to the directory it is started in, so a duplicate
  inside the clone silently outranks the real one. The repo tracked exactly that
  — the Aug-27 pre-cleanup coordinator playbook, with the superseded orchestrate
  gate — for five days. `.opencode/` and `.npm/` are now gitignored and a test
  asserts neither is tracked.

## Bugs the test suite found (all fixed)

1. **Shared keys did not collapse** — the design's core promise. opencode names
   the provider `openrouter`, kilo reports host `openrouter.ai`, so identical
   fingerprints made two buckets from one wallet.
2. **A transient `auth_error` benched a healthy wallet for 24h.**
3. **`plan.sh` wrote an empty plan and called it success** (`jq -e` exits 0 on
   empty input).
4. **`fa doctor` aborted mid-check** — `grep` exiting 1 under `set -e` skipped the
   registry check, the one people rely on.
5. Deadlocked runs left **no journal entry**, and `status` called permanently
   blocked tasks "pending".
6. Stub `curl` ignored `-o`, making downloads look like network failures.
7. `lanes -v` disagreed with `lanes` (twice — display and count now share a
   predicate).
8. **12.3 MB of npm cache and a broken symlink were committed** — found while
   recapping what a fresh clone gives you, before cloning on the second server.
   `.npm/_cacache` was 96% of the tracked tree, and
   `.opencode/skills/opencode-free-agents` pointed at a directory deleted in the
   Aug-28 cleanup, landing broken in every clone. History rewritten
   (`filter-branch`, force-pushed): 217 files / 12.8 MB → 52 files / 458 KB,
   `.git` 9.8 MB → 588 KB. Three hygiene assertions now guard it.
9. **`CLAUDE.md` pointed at six files that do not exist** — the entry point an
   agent reads automatically on landing in the repo. Four docs moved to
   `docs/dev/` in the Aug-28 cleanup and the links never followed; two named a
   `workflow-kit/` directory that was never shipped. Rewritten as the contributor
   entry point (distinct from `prompts/coordinator.md`, which is for an agent
   *using* the tool), with a test asserting every path it names resolves.
10. **The freshness check cried wolf twice while being built** — first by comparing
   live fingerprints to bucket keys (a credential that reached no model has no
   bucket, so it looked new on every run), then by treating an installed-but-
   unauthenticated agent as never examined. Both fixed by recording what the
   discovery pass *looked at*, which is a different set from what it *produced*.

## What is deliberately NOT tested

- **Real agent behaviour.** Everything runs against stubs; whether a free model
  can follow a spec is not assertable here.
- **Live provider failures.** The taxonomy is tested against captured error
  strings. **Real error text from the user is the only source of truth for this
  layer** — two of four messages they pasted were misclassified.

## Recent additions

**Validation gate (Phase 1 + 2, 2026-09-10):** optional post-build syntax check
with auto-fix loop. `fa run --validate` runs `node --check`, `python3 -m py_compile`,
`shellcheck` on changed files; on failure the same agent gets the errors and retries
(default 3 rounds). Exhaustion fails the task. `fa orch run --validate` applies this
per task. Flag `--validate-all` reserved for tests + lint (future phases).
Journal records `validation_failed` events for `fa analyze`.

**Agent/harness ranking + graph conditionals (2026-09-21)** — see the session
section below for the full build and the bugs it surfaced.

## This session: the ranking axis + graph conditionals

The user's original idea from before this project started — rank and switch
between model/agent/harness combinations per task type, defaulting to the
next-best on failure — was only half-built: model ranking existed per
category, but the *agent/harness* axis did not, and cold-start behaviour
gated on overall history instead of per-category history. Both are now built:

- **Per-category cold-start seed opinion.** `data/model-seed.json` can carry
  an optional per-category `tiers` override (context size + name heuristics
  otherwise), consulted only until real per-category evidence exists — the
  moment it does, the seed opinion stops competing with it. Deliberately
  **not** live-fetched from a leaderboard (evaluated and rejected — see
  ALIGNMENT-style reasoning: a hand-edited/generated static file is
  reproducible and auditable, a live fetch is neither).
- **Agent/harness ranking.** The same model reachable through two CLIs on one
  wallet is now ranked between them too (Beta-smoothed per-category success
  rate), with automatic fallback to the next-best harness on the *same*
  wallet and model before ever trying a different model or wallet. Exposed
  read-only via `fa profile` (per-agent/harness rate) and `fa rank <category>`
  (the full candidate chain) — no request spent to see either.
- **`fa dispatch`** — the orchestrate-vs-direct gate, previously prose in
  `AGENTS.md` that a coordinator had to compute correctly by hand, is now
  real code: it plans (if given a goal) or reads the existing `tasks.json`,
  checks for a genuinely disjoint task pair and `fa lanes ≥ 2`, prints a
  `SPLIT EVALUATION`, and dispatches `fa orch run` itself when it decides to.
  `AGENTS.md`'s gate section now points at it instead of restating the rule.
- **`when` conditional graph edges.** A task can declare
  `{"when": {"dep", "path", "equals"}}` to run only if a finished dependency's
  captured `result:` line matches — the first real branch in the task graph,
  distinct from a plain `deps` entry (wait for it vs. run only if it says so).
  Built on the existing handoff transport: `result: <one-line JSON>` is an
  optional extra line in the same `---HANDOFF---` block, requested only when
  some other task's `when` actually reads it. A new terminal journal event,
  `skipped`, is distinct from `done`/`failed` — nothing attempted, nothing
  wrong — and `deps_met()` treats it as resolved so downstream tasks are never
  stuck behind a skip.
- **Soft-injected handoff caution.** A dependency that leaves no handoff no
  longer produces a silent gap — its dependent's prompt gets a fixed caution
  line telling it to verify that dependency's output directly.
- **`fa dispatch`/`fa go` no-goal mode.** Evaluating an existing `tasks.json`
  no longer requires re-planning from scratch.

**Real bugs the work surfaced, all fixed and covered by new tests** (not an
exhaustive list — see `git log` for the full sequence):
- The `--validate` gate and `run_task()`'s worktree merge-back each crashed on
  their own success path — both were `set -e` plus a plain assignment of a
  function whose last statement can legitimately return non-zero on success.
  The merge-back bug additionally **silently reverted earlier tasks' work**
  on every successful worktree merge — the most serious bug found this
  session, caught only by an end-to-end test asserting file content survived
  a second task's merge, not by reading the code.
- `discover()` silently wiped all learned per-model and per-agent ranking
  evidence on every refresh — the exact data the whole ranking system exists
  to protect — fixed by forward-carrying `.stats`/`.cat_stats`/
  `.cooldown_until` and the new root-level `.agent_stats` across a refresh.
- `fa lanes` always counted a cooling-down bucket as live (jq compared a
  number to a string and the comparison silently never matched).
- Resume could dispatch a duplicate `run_task()` for an orphaned task whose
  previous process had died mid-run but left no terminal journal event —
  fixed with a new `orphan_abandoned` finding and liveness check via
  `$BASHPID` (not `$$`, which stays the parent shell's PID inside a
  backgrounded subshell).
- The auto-isolate heuristic guessed at file overlap instead of checking it;
  replaced with a real pairwise `comm -12` check.
- Three `classify.sh` regex patterns were over-broad enough to misclassify
  real provider text, and the cooldown escalation loop was capped at a fixed
  3 iterations instead of continuing to the real cap.

`until` (loop-until-converged, the third axis of the Graph/Loop/Harness
framework in `docs/dev/PARADIGMS.md`, alongside the now-built Graph
conditionals and the Harness ranking above) was discussed and **deliberately
deferred, not started** — it would be a genuine new primitive (not covered by
the existing per-task fallback chain, which retries a single task, not a
subgraph), but its value was judged narrow without a concrete real-project
need driving it. That discussion was not persisted to a file or commit; if
resuming this thread, re-evaluate fresh rather than hunting for it.

## Next, if resuming

The ranking system (the user's original idea) and the Graph/Harness halves of
the paradigm framework are now built and tested. Options, roughly in order of
value:

0. **A real provider failure mid-build — still unobserved.** Three projects,
   19 tasks, and not one genuine mid-flight failure. coldrun was built to force
   one by starving the scheduler to a single lane; it completed 5/5 anyway. The
   breaker, cooldown escalation and cross-wallet rerouting remain verified only by
   the test suite. **Do not force this by hammering providers** — it will close by
   itself during a genuinely large build.
1. **`until` (loop-until-converged)** — the deferred Loop axis. Evaluated and
   set aside this session; worth re-evaluating if a real project surfaces a
   concrete convergence-style need (e.g. "retry until tests pass" across a
   whole subgraph, not just one task's fallback chain).
2. **BATCH mode for trivial tasks.** `fa dispatch` already surfaces when every
   task in a batch is `"complexity": "trivial"` but does not yet group them
   onto one lane — noted as roadmap, not built, in the README's Workers
   section.
3. **Project modes (strict/push/local) do not yet change dispatch behavior.**
   `mode` and `automerge` are read from `.orch/config.yaml` but every task
   goes through the same isolated-worktree-and-commit merge-back regardless.
   Documented as an honesty note in both READMEs; closing the gap is
   unstarted.
4. **Token accounting** was assessed and deliberately not built: worth it only
   for the two lanes that publish a budget (`nous` tph, `copilot` credits).
   A general ledger for the five lanes with no budget changes no decision.
5. Smaller should-do items raised but not built this session: a known-bad
   demotion band (distinct from cold-start), and deciding whether to trust
   cached wallet health vs. re-probing before a large dispatch.
6. **Catch up missed scheduled refreshes.** Cron skips a 03:00 run while the
   machine is off or asleep and never makes it up - 2 runs in 13 days on the
   dev machine. `fa doctor` now says so and how to move the hour. The real fix
   is an hourly cron that refreshes only once the registry is ~20h old, but
   that moves refreshes into working hours, while builds run - and
   `discover` and `record_probe` write the registry WITHOUT `REGISTRY_LOCK`
   (only `run.sh`'s `registry_txn` takes it), so a refresh racing a build can
   lose a cooldown it just recorded. Build it together with that lock, or
   skip a run while any lease is held.

**Do not** add: token budgets on unmetered lanes, live leaderboard fetching (see
ALIGNMENT for why gateway metadata beats it), or a summariser-based handoff — each
was evaluated and rejected with reasons recorded.

## This session: the adapter list

The harness roster was copied in six places ("opencode kilo hermes copilot cursor"
was open-coded in buckets.sh, common.sh, run.sh and fa), so copilot and cursor were
never version-checked and a machine with claude/aider/goose installed was reported
healthy while those harnesses could never run.

Fixed by making `bin/lib/adapters.sh` the single source: one list, one loader that
sources one file per harness in `bin/lib/adapters/`, one dispatcher
(`adapter_invoke`) shared by run and probe. The presence broom in `fa doctor` now
surfaces installed-but-unadapted harnesses. Two more gaps closed in passing:

- `setup.sh` swallowed a missing `jq` and declared "Ready." with a silent
  half-install; it now fails loudly (`exit 3`) with the apt line. `missing_deps()`
  in `bin/lib/deps.sh` is consulted by setup, `fa bootstrap` and `fa doctor`.
- `kilo-add-openrouter.sh` was removed — it was a setup helper, not part of the tool flow.

`fa doctor` checks all five harnesses against their pins (opencode 1.17.20,
kilo 7.5.5, hermes 0.20.5, copilot 1.0.83, cursor 2026.09.02); metered lanes are
marked. New `test/test_adapters.sh` pins the single-source invariant and the
broom; full suite is 16 suites / 269 assertions, offline.

## This session: fresh-machine credential setup (`keys.env` + guided logins)

Prompted by a user question about simplifying setup on a brand-new Ubuntu/
Debian box with nothing but git installed: the seven agents split cleanly
into two tiers, and only one of them was actually automatable.

- **Tier A — opencode, kilo, pi.** Each needs nothing but a raw API key
  dropped into its own JSON/JSONC config file. New `bin/lib/keys.sh` reads
  an optional, gitignored `keys.env` (template: `keys.env.example`, tracked)
  and calls a new `<agent>_provision_key` function per adapter, which writes
  the key via a new shared `json_merge_file()` helper in `common.sh` —
  atomic read-modify-write, refuses (never corrupts) a target that isn't
  plain JSON, chmod 600 after writing. `setup.sh` runs this automatically;
  absent `keys.env` it's a silent no-op.
- **Tier B — copilot, cursor, agy, hermes.** Real OAuth/account login, which
  nothing here will ever auto-consent to on the user's behalf. New
  `adapter_logged_in()` in `adapters.sh` reuses each agent's own
  `_identify()` (no second detection path) to answer "is this one already
  logged in", and `guided_logins()` in `keys.sh` offers each still-missing
  agent's login step interactively, then — the part that used to be
  silent — prints a final summary of every account still not logged in,
  with the exact command for each.

**Real bug caught by the test suite before it shipped (fresh-machine setup)**: `kilo_provision_key`
was first written with signature `(key, baseURL)`, but the generic
dispatcher in `keys.sh` calls every `*_provision_key` function uniformly as
`(provider, key)` — silently swapping the two, so the real key landed in
`baseURL` and the literal string `"openrouter"` landed in `apiKey`. Would
have produced a completely dead, unrecoverable "provisioned" credential that
looked fine at a glance. Caught only by writing the file and reading the
actual JSON back with `jq`, not by re-reading the code — the same lesson as
the worktree merge-back bug earlier this session. `test/test_provision.sh`
pins this shape directly (test 3) so it can't regress silently again.

**Honesty, not a guess presented as fact**: `gh auth login` (copilot) and
`hermes login` (hermes) are verified commands, already documented in
`docs/SETUP.md` before this session. `cursor-agent login` and `agy login`
are educated guesses at each CLI's own subcommand name, never confirmed
against a real machine — their hint text says so explicitly, and falls back
to "run the agent once and follow its own prompt" if wrong. Worth
confirming on a real machine and tightening if resuming this thread.

Full suite: 24 suites / 426 assertions, offline.

## This session: ToS/evidence notes, live quota check, exclusion trace (2026-09-27)

Prompted by studying a third-party project (OmniRoute, an unrelated LLM-API
gateway) for ideas worth borrowing. Three landed, each scoped down from the
original idea to what this tool's actual architecture supports:

- **`data/provider-notes.json`** - hand-maintained ToS/evidence notes per
  provider, same spirit as `data/model-seed.json` (optional, never fetched
  at runtime, deleting it breaks nothing). Matched case-insensitively against
  a bucket's `provider`/`local_providers` at discover time; attaches
  `tos`/`tos_evidence`/`tos_note` to the bucket. `fa show` prints a
  `** TOS CAUTION/AVOID: ... **` line and `fa lanes -v` a terse `[TOS:...]`
  tag - only for `caution`/`avoid`, never for `ok`/`unknown`, so the line
  stays meaningful instead of becoming wallpaper. Seeded from a third party's
  independent ToS catalog, cited as such, never asserted as this project's own
  legal read - including a caution on fa's own `opencode`/`agy` lanes,
  which the source catalog rates the same way it rates a third-party proxy
  reaching through those CLIs' own free gateways.
- **`fa quota` / `bin/buckets.sh quota`** (`bin/lib/quota.sh`) - the one place
  this tool ever asks a provider directly, ahead of time, how much of its own
  published budget is left, instead of inferring it from a failed attempt
  after the fact. One provider only: OpenRouter's real `GET /api/v1/auth/key`
  endpoint. Opt-in and separate from every hot path - `run.sh`'s `candidates()`
  and `cmd_lanes` stay offline-only, exactly as before; only `fa show` displays
  the last recorded check. Deliberately honest in its own label: OpenRouter's
  `usage`/`limit` are its DOLLAR-CREDIT ledger, not a free-tier token count,
  and the tool says so rather than implying more than the data supports. A
  second provider with an equally real endpoint is what would turn this into a
  per-adapter contract function; one case today is a flat, explicit function,
  same reasoning `keys.sh` gives for `FA_TIERA_KEYS` staying three hardcoded
  lines instead of a generic mechanism.
- **`explain_exclusions()` in `run.sh`** - when a bucket/model/route does not
  make the candidate chain, `--dry-run` now prints an `excluded:` section and
  the empty-chain guard prints `why:`, both grouped and counted by reason
  (`bucket cooling down`, `excluded via -x`, `model unsuitable: <reason>`,
  `<agent> lacks capability for <category>`, etc.). Every field it reads
  already existed (`unsuitable_reason`, `health.state`, `cooldown_until`) -
  this adds visibility, not a new signal, and never fires on an ordinary
  successful run.

**Real bug caught while building this, not by inspection**: the first version
of `explain_exclusions()`'s jq double-nested the per-model branch inside an
extra `[...]`, so the bucket-level branch produced flat objects while the
model-level branch produced an array of arrays. `group_by(.reason)` failed
with `Cannot index array with string "reason"` - but only on the `--dry-run`
call site, because that call site's `2>/dev/null` (correctly protecting
ordinary runs from a jq regression) also hid the error from the very testing
that was trying to find it. Diagnosed by temporarily removing the suppression
in a live repro rather than reading the jq harder - the same lesson this
project has hit before (the kilo `_provision_key` argument-order bug, the
worktree merge-back bug): read the actual output back, don't trust that the
code looks right.

Full suite: 27 suites / 456 assertions, offline.

## This session: `fa findings --issue --post` (2026-09-27, later same day)

Prompted by the user asking whether the tool had anything like a bug/issue
catcher that could feed back into maintaining it. It did, mostly: the
findings system already detected, redacted and deduplicated, and `--issue`
already formatted a ready-to-paste GitHub issue - it just stopped at the
clipboard. This closes that last step, without touching the "human decides"
invariant that already existed.

- `_finding_rows()` in `bin/lib/findings.sh` - the ONE place a grouped
  finding becomes a `{title, body}` pair, so the text a human reviews before
  saying yes can never drift from the text that actually gets filed.
  `findings_issue()` (the existing `--issue` display path) is now a thin
  formatter over it - refactor only, same output, all 22 pre-existing
  `test_findings.sh` assertions passed unchanged before a single new test
  was written.
- `findings_post()` - resolves this clone's own `origin` remote (never the
  project `fa` happens to be run from; `FINDINGS_REPO_SLUG` overrides it,
  which is also how a fork ends up filing against itself for free), lists
  every NEW finding's title, asks once (`read -rp`, so a non-interactive
  caller with closed stdin gets EOF -> declines by default, never files
  blind), then calls `gh issue create` per finding on an explicit yes.
- `_mark_filed()` - every entry sharing a fingerprint is marked once filed
  (same locked read-modify-write shape as the existing `findings_ack`), so a
  repeat occurrence of the same failure never opens a second issue. A `gh`
  failure is reported per-finding and does NOT mark it filed, so a retry
  picks it back up.
- `test/stubs/gh` (new) - offline stub, `GH_STUB_MODE=success|fail`, logs the
  title of every `issue create` call so a test can assert exactly what would
  have been filed without ever reaching the network.

Real fact surfaced while building this, not before: the repo is now
**public** (`gh repo view` confirms `PUBLIC`) - the "Published privately"
note earlier in this file is stale. Worth knowing since `--post` makes that
concretely actionable: anyone with a `gh` login can now open an issue
against it, from any machine running this tool, once they say yes.

Full suite: 28 suites / 479 assertions, offline.

## Fix: `hermes login` removed upstream (2026-09-27, same day)

Real-usage report from the user: cloning onto a second, unrelated project
(`Raimundo-Araujo-Avatar`) and running `setup.sh` there, `guided_logins()`'s
hermes case failed outright -

```
[fa] hermes: not logged in - hermes login   (starts Nous OAuth...)
  attempt that now? [y/N] y
The 'hermes login' command has been removed.
Use 'hermes auth' to manage credentials,
'hermes model' to select a provider, or 'hermes setup' for full setup.
[fa] hermes: still not logged in
```

Not a false alarm - `hermes login` really is gone upstream, sometime after
the pinned `FA_hermes_VERIFIED_VERSION="0.20.5"` (this machine's own hermes is
already on 0.21.3, so `fa doctor` had been showing `differs` on it for a
while without anyone chasing why). Confirmed the replacement directly against
a real v0.21.3 install rather than guessing: `hermes auth upgrade` ("Sign in
with a Nous account, keeping your connectors") is the exact same scope as the
old `login` - pure OAuth, no side effects. `hermes setup --portal` also signs
in, but additionally sets Nous as the default inference provider and picks a
model - out of scope for a login hint, so not used here.

Fixed in `hermes_login_hint()` (adapters/hermes.sh) and the actual attempted
command in `guided_logins()` (keys.sh); `docs/SETUP.md` and
`test_provision.sh`'s pinned hint text updated to match. Deliberately did
NOT bump `FA_hermes_VERIFIED_VERSION` - only the login subcommand was
verified, not the full `hermes_invoke()` call shape real dispatch depends on,
and CLAUDE.md's own caution applies here (a wrong shape reads as a dead
model). `fa doctor` should keep flagging hermes `differs` until someone
actually verifies invoke against 0.21.3, not just login.

This is exactly the class of thing `docs/dev/SESSION.md`'s own "what real
usage showed" sections exist to catch, and exactly what `fa findings --note`
+ `--issue --post` (built earlier today) is for on a report that isn't
already fixed by the time it's read - this one was fixed same-session, so
recorded here instead of filed as an issue against itself.

## Fix: `setup.sh`'s "Ready." banner silently missed agy and pi (2026-09-27, same day)

Same real-usage report, second bug in it: the user noticed `agy: already
logged in` printed one line above a final banner that only listed five of
the seven agents. `setup.sh:140` was a hand-typed string, never updated when
agy/pi were added to `FA_AGENTS` - the exact bug class `adapters.sh`'s own
header already warns about ("A new harness is exactly two things... a copy
of the agent list in any other file is a regression"), just in a spot
(plain print text) that earlier cleanup didn't reach because nothing
functional exercises it. Now built from `FA_AGENTS` at runtime. Checked
`docs/dev/ALIGNMENT.md`'s similar-looking `opencode | kilo | hermes` -
that one's an illustrative example inside a notation diagram, not a claim to
be exhaustive, left alone. New assertion in `test_bootstrap.sh` pins all
seven names in the real banner output.

## Fix: hermes's real nous credential lives in `.providers.nous`, not `.credential_pool.nous` (2026-09-27, same day)

Re-running `setup.sh` on the same second machine after the `hermes auth
upgrade` fix above surfaced a THIRD, more interesting bug from the same
report: hermes itself replied **"Already signed in"** to the auth-upgrade
attempt, yet fa immediately reported `hermes: still not logged in`
afterward - hermes and fa disagreeing about the exact same credential.

Diagnosed without needing the second machine at all: hermes is a git
install (`Install directory: /home/rcsoft/.hermes/hermes-agent`), so its own
source was readable directly. `hermes_cli/auth_nous.py`'s
`persist_nous_credentials()` docstring says it outright: *"Nous credentials
are read from `providers.nous` (401 recovery, pool seeding) AND
`credential_pool.nous` (runtime `pool.select()`); a pool-only write broke
expiry recovery."* The singleton (`.providers.nous`, a flat object) is
written first and is what hermes's own login check trusts;
`credential_pool.nous` (an array - what `hermes_endpoints()` in
`bin/lib/adapters/hermes.sh` exclusively read) is a secondary mirror that
hermes's own maintainers have already found ways to leave stale. Confirmed
the singleton's real shape directly against this machine's own
`~/.hermes/auth.json` (`.providers.nous` keys: `client_id`,
`inference_base_url`, `last_auth_error`, `portal_base_url`, `scope`, `tls`,
`token_type` - `access_token`/`refresh_token` present only when actually
logged in) - this machine's own nous is CURRENTLY logged out too
(`credential_pool.nous` is `array(len=0)`, confirmed via `hermes auth status
nous`), which is a separate, likely-harmless staleness note in itself: this
machine's registry still shows a healthy `nous:9162a7f63a81` lane from a
past `fa discover`, and `registry_status()`'s freshness check only detects
a credential being ADDED, never one disappearing - deliberately not chased
further this session, since health/cooldowns are documented as
self-correcting at runtime (a real dispatch attempt would hit an auth error
and cool the bucket down the normal way) and nobody asked for this axis to
be hardened.

`hermes_endpoints()` now reads `.providers.nous` too, preferring it over
`credential_pool.nous` whenever it holds a real `access_token` - exactly
matching which one hermes's own login check trusts - and falls back to the
pool entry otherwise, so a pre-singleton hermes install (or any other
provider, e.g. kilocode gateway keys) is completely unaffected. New
`test/test_hermes_nous.sh` (13 assertions, fully offline, unsigned fake
JWTs) pins: singleton-only, both-empty, both-populated-singleton-wins,
pool-only-still-works, end-to-end `hermes_identify()`, and other-providers-
unaffected.

Three real bugs found from one user trying the tool on a second project, in
one afternoon - the found-by-actually-using-it kind of feedback this whole
findings system exists for, arriving faster than any of it could have been
guessed at a desk.

Full suite: 29 suites / 493 assertions, offline.

## Not a bug: hermes's own "Already signed in" can lie (2026-09-27, same day)

The same second machine hit the exact same symptom again *after* the
`.providers.nous` fix above, which briefly looked like the fix hadn't
landed. It had (confirmed: `git log -1` showed `c6ed2bf`). The real
diagnosis, this time entirely from hermes's own source, without needing
anything from the second machine beyond two safe, secret-free commands:
`hermes auth status nous` (hermes's own authoritative check) agreed with fa
exactly - both said logged out, no token anywhere, on both machines. The
`Already signed in.` from `hermes auth upgrade` was hermes's OWN
inconsistency: `anon_sign_in.py`'s precondition check
(`state and not is_guest_state(state)`) calls something "already signed in"
based only on whether `.providers.nous.auth_method` is missing the
anonymous-tier marker - it never checks whether a token actually exists.
Both machines have a leftover `.providers.nous` "shell" (host/scope/client_id
config with no token, presumably from an interrupted `hermes setup`) that
happens to trip exactly this gap.

**No fa code changed** - its detection was already correct, and loosening it
to agree with the misleading message would mean trusting a credential that
provably doesn't work. Documented as a known hermes quirk in `docs/SETUP.md`.

Better remedy surfaced right after, straight from hermes itself: starting
plain `hermes` in this state prints its own diagnosis - "No access token
found for Nous Portal login. Run `hermes model` to re-authenticate." -
`hermes model --help` confirms it carries its own Nous OAuth login flags, so
it logs in inline while picking a model/provider, bypassing the buggy
precondition the same way `auth add nous --type oauth` does. Led with this
in SETUP.md (hermes's own first-party suggestion, printed at the point of
failure) and kept `auth add` as the fallback.

**Confirmed working end to end**: the same second machine ran `hermes
model`, completed the browser OAuth, and its very next `setup.sh` reported
`hermes: already logged in` - closing the loop on a real account. Four
messages, one real machine, one afternoon: a removed CLI subcommand, a
hand-typed roster that drifted, a credential fa was reading from the wrong
field, and a hermes-side false positive correctly told apart from an fa bug
- each one found from evidence (real output, real installed source, a real
second machine), not guessed, and the last one ends with independent
confirmation that the fix actually works.

## Fix: the banner's fix for the LAST bug introduced a fifth (2026-09-27, same day)

Same real-usage thread, one more: running `cursor` (the banner's own literal
suggestion, from the agy/pi fix earlier today) on the second machine failed
outright - `Error: No Cursor IDE installation found. Use 'cursor agent' or
'agent' to run the agent.` The adapter name "cursor" (fa's own internal key,
`FA_AGENTS`) and the actual command a human types are the same string for
six of the seven agents, but NOT for cursor: `FA_cursor_VERSION_BIN` has
always been `cursor-agent`, with bare `cursor` listed in
`FA_cursor_BINARY="cursor-agent,cursor"` only as an alternate presence-
detection signal - `cursor_identify`/`cursor_invoke` have only ever shelled
out to `cursor-agent`, never bare `cursor`. This exact wrong suggestion
existed in the OLD hand-typed banner string too (it also said plain
`cursor`) - today's fix just made all seven agents visible, which is what
finally got a real human to try the wrong one.

`setup.sh`'s banner now joins `adapter_field "$agent" VERSION_BIN` per
agent instead of the bare `FA_AGENTS` name - identical output for six
agents, `cursor-agent` instead of `cursor` for the seventh. Same fix applied
to the one other place a literal invocation was suggested (this file's own
quick-start snippet, three sections up). `test_bootstrap.sh` now pins
`cursor-agent` in the banner and asserts the bare, non-working `cursor`
never appears there again.

## Feature: `setup.sh` refreshes right away when a login just succeeded (2026-09-27, same day)

Prompted by discussing the hermes/nous saga above: since the registry
correctly did NOT flag itself stale when a broken-then-fixed credential kept
the same fingerprint, the user asked whether `setup.sh` could refresh
proactively, and what the real drawbacks would be beyond wait time. Landed
on a deliberately narrow answer rather than "always refresh": the real cost
of an unconditional refresh is quota, not time (`fa refresh` PROBES every
bucket with a real API call, and state is machine-wide, so N project
folders would mean N redundant probe rounds against the same credentials
for no benefit) - and the tool already self-heals within 24h for free via
the existing daily cron. The one genuine gap was "I just watched a login
succeed, right now, in this exact run" - a signal only `setup.sh` itself
has, that the cron and a later manual `fa refresh` both miss until the next
tick.

- `guided_logins()` (`bin/lib/keys.sh`) now sets a GLOBAL `NEWLY_LOGGED_IN`
  array (reset every call) naming exactly which agent(s) went from
  not-logged-in to logged-in during THIS run.
- `setup.sh` reads it right after the `registry_status()` case block's
  status is computed (not after, so the case block's own report reflects
  the refresh) and calls `fa refresh` when it is non-empty - skipped when
  there is no registry yet (the `missing` branch already bootstraps
  unconditionally; refreshing twice would double-probe for nothing) or under
  `--no-bootstrap`.

**Real bug caught while testing this, not by inspection**: the obvious way
to simulate "hermes was logged out, then a login attempt succeeded" in an
offline test is a counter variable incremented inside a stubbed
`hermes_identify()`. It silently never worked - `adapter_logged_in()` calls
`*_identify()` through a pipe (`"$fn" | awk ...`), and bash forks a subshell
for each stage of a pipeline, so the increment happened in a subshell copy
and was lost the instant it exited; every call saw the same starting value.
Fixed by using a marker FILE instead of a shell variable - filesystem state
survives across subshells the same way the registry itself does. New tests
in `test_provision.sh` (#12: a login that succeeds populates
`NEWLY_LOGGED_IN`; #13: nothing to attempt leaves it empty).

Full suite: 29 suites / 497 assertions, offline.

## Policy: no external project names in runtime output (2026-09-27, same day)

`fa refresh`'s own printed output surfaced the earlier ToS-notes feature's
`note` text naming the outside project its ratings were seeded from
directly in `fa show`'s `** TOS AVOID/CAUTION: ... **` line. The user's
policy, stated plainly: adapt ideas from other projects freely, never large
chunks of code, no runtime credit is ever needed for that, and if
provenance is worth keeping at all it belongs in dev docs/comments -
never in what the tool actually says to whoever is running it.

Rewrote every `note` field in `data/provider-notes.json` to drop the name
while keeping the same facts and caution level ("external research flags
this as risky" instead of naming who). The specific provenance (which
project, what date, methodology) now lives in exactly one place structurally
guaranteed to never print: the file's own `_README` key, already filtered
out (`startswith("_")`) before anything loads into the registry. This
session's own build-history mention above (search "OmniRoute") is left
alone on purpose - this is a dev log, never something `fa` runs or prints.

## `agent-coordinator/SKILL.md` gets frontmatter (2026-09-28)

The user asked about surveying the wider "Claude Skills" ecosystem
(anthropics/skills, and vercel-labs/skills - which turned out to actually
BE the `npx skills` install CLI itself, not a skills collection; the real
content repo is vercel-labs/agent-skills). That CLI's own source
(`src/skills.ts:100`) confirmed a real, latent gap: `free-agents-free-
models/SKILL.md` has always had proper `name`/`description` frontmatter,
but `agent-coordinator/SKILL.md` never did - a plain markdown file with no
`---` block at all. The CLI gates on both fields and silently skips (with
a warning) any SKILL.md missing them, so installing fa's skills through it
would install one and silently drop the other.

Fixed with frontmatter that states plainly what this skill already says in
its own first paragraph - load manually, after AGENTS.md's gate, never by
auto-triggering on the description:
```yaml
---
name: agent-coordinator
description: The free-agents-free-models coordinator playbook, loaded ONLY after AGENTS.md's own gate (>=2 disjoint tasks AND `bin/buckets.sh lanes` >=2) has already passed - never load this speculatively or to decide whether to orchestrate; that decision is AGENTS.md's, made before this file is ever opened.
---
```
Checked both other references to this file (`docs/dev/ALIGNMENT.md`'s
historical mention, `test_bootstrap.sh`'s directory-existence check) -
neither depends on the file's content, so nothing else needed to change.

## `--isolate` worktrees are now a persistent POOL, not create-then-destroy (2026-09-28)

Same survey turned up a second, unrelated repo doing something genuinely
relevant: a git worktree pool manager that reuses a clean, already-warmed
worktree instead of paying full checkout/teardown cost per task. `run_task()`
was doing exactly that per-task cost every time under `--isolate` - create
a worktree from `$PROJECT`'s HEAD, use it once, destroy it and its
throwaway branch. Adapted the IDEA (never the code, never named in
anything fa prints - see the no-runtime-attribution policy above): a
git worktree pool.

- **`wt_pool_claim`/`wt_pool_prepare`** (orch.sh) replace the old per-task
  `wt_dir="${ORCH_DIR}/worktrees/${id}"`. One slot per possible lane
  (`pool-1..pool-$width`), flock-guarded (mirroring `run.sh`'s own bucket
  `lease_acquire`/`lease_release` idiom, not shared code - different
  resources in different files). A returned slot is `reset --hard` +
  `clean -fdx` to the CURRENT project HEAD before reuse, never destroyed;
  branches are `fa-pool-N` (persistent, per-slot) instead of `fa-task-<id>`
  (throwaway, per-task) - nothing to delete after a task anymore, just a
  lease to release. Slots persist across SEPARATE `orch.sh run`
  invocations too, not just within one, since nothing ever tears them down;
  a manual `rm -rf .orch/worktrees/` is the escape hatch if anyone wants
  the disk space back.

**Two real bugs caught while building this, neither by inspection:**

1. `wt_slot="$(wt_pool_get ...)"` - the first version acquired the flock
   lease and returned the slot number from the SAME function, called via
   command substitution. Command substitution forks a subshell to run the
   command and collect its output; the instant that subshell exits (as
   soon as the command finishes), every FD it opened - including the
   flock'd lease FD - closes, releasing the lock. Two concurrent tasks
   both "successfully" claimed slot 1, because the first task's lock was
   already gone by the time the second even asked. Fixed by splitting
   `wt_pool_claim` (acquires the lease - MUST be called directly, never via
   `$(...)`) from `wt_pool_prepare` (reuses or creates the actual worktree
   content - safe to substitute, holds no state that needs to outlive its
   own return). Caught by making a test suite assertion ("two independent
   concurrent tasks land on two distinct slots") actually force real
   overlap via `STUB_CONC_DIR`/`STUB_HOLD` (see test_concurrency.sh's own
   established pattern) instead of hoping instant stub commands happened
   to race - the bug was invisible without forcing genuine concurrency.
2. `git worktree add`'s own stdout ("Preparing worktree...", "HEAD is now
   at ...") was leaking into the captured return value (only stderr was
   redirected), corrupting `$wt_slot` with multi-line git status noise on
   every fresh slot creation.

**A third thing, not a bug, discovered while writing the corruption-
recovery test**: `git worktree remove --force` refuses outright
("validation failed... is not a .git file") when a worktree's own `.git`
pointer file is corrupted - `--force` overrides a dirty or locked
worktree, not a broken one. Confirmed directly before trusting it. The
actual recovery is `rm -rf` the directory first, then `git worktree
prune`, which clears git's now-dangling admin record for a path that no
longer exists - only then does a fresh `add` succeed.

New `test/test_worktree_pool.sh` (14 assertions): cross-invocation reuse,
a stray file from a prior task actually gets cleaned before the next task
sees it, corrupted-slot recovery, and slot count staying flat across four
separate runs. Existing `test_worktree_merge.sh` updated in place for the
new persistent-pool reality (a sequential dependency pair reuses one slot;
two genuinely concurrent tasks claim two distinct ones, forced via the
same `STUB_CONC_DIR` mechanism).

Full suite: 31 suites / 516 assertions, offline.

## Fix: the daily refresh never ran, and the suite spent real requests (2026-10-03)

Commits `9f3856f` (tests), `fc96516` (schedule + timing), `32574b0` (pins).

Found while re-reading this machine's state at the start of a session, not from
a report: `fa doctor` called the registry 6 days old although a daily refresh
was installed. `refresh.log` held two runs in 13 days, each a lone `[fa]
discovering credentials...` line, and `buckets.json` had not changed since
2026-09-27. The daily refresh (`ab78b31`, 2026-09-05) had never once succeeded.

**Two stacked causes, reproduced exactly before anything changed** (`env -i`,
cron's PATH, a scratch `FREE_AGENTS_STATE`):

1. **Cron's PATH finds no agent.** A cron job gets system directories only (here
   `/etc/environment` via `pam_env`; Debian's cron runs `-P`), while all seven
   agent CLIs live in per-user ones (`~/.local/bin`, `~/.opencode/bin`,
   `~/.kilo/bin`). Every `<agent>_identify` stops at `command -v`.
   `schedule.sh`'s own header said the absolute path "survives PATH changes" -
   true of `fa`, not of anything `fa` runs.
2. **The failure was silent.** `cmd_discover` opened with
   `_ident="$(cmd_identify 2>/dev/null || true)"`. `cmd_identify` dies - `exit`,
   not `return` - which ends the substitution's subshell before the inner
   `|| true` runs; the failed assignment then killed discover under `set -e`,
   its only error message already in `/dev/null`. Swept every
   `$(... || true)` in `bin/`: no other instance.

Nothing would ever have said so: `schedule_status()` existed and was never
called. It also quietly undercut `ae1bae4`'s reasoning (no unconditional
refresh in setup.sh *because* the cron self-heals within 24h).

**Fixed:**
- `fa schedule` saves the PATH it runs with (`<state>/schedule.path`), and the
  line is now `FREE_AGENTS_STATE='<state>' '<root>/bin/fa' refresh --scheduled
  >> '<state>/refresh.log' 2>&1` - the state dir pinned too, so an overridden
  location is the one refreshed and its saved PATH is the one found. `fa refresh
  --scheduled` restores the PATH, stamps `start` and `finished rc=N` in UTC, and
  never re-installs its own line (a re-install from there would write identical
  bytes, so the test checks the install message never appears).
- `|| true` moved outside the substitution, and `no_identities_reason()` says
  "no agent CLI found on PATH (looked for: ...; PATH=...)" or "found X but no
  credential any of them can use" - the line that would have named this bug on
  its first night.
- `fa doctor` gained a **daily refresh** section - advisory, never fails doctor,
  same rule as age: what the scheduled run will find on its saved PATH, the last
  run's outcome, a line installed the old way, a scheduled copy of the tool
  that is gone, stacked lines, and a registry 2+ days old despite the schedule.
- An old-shape line is replaced, not stacked beside (one `SCHEDULE_LINE_RE` for
  install/uninstall/status); a time set via `FA_SCHEDULE_HH/MIN` now survives
  re-installs (every `fa refresh` used to reset it to 03:00 - harmless only while
  the cron could not run); a failed crontab write no longer prints "scheduled".

**Second bug, found running the suite to verify the first: the tests spent real
requests.** `pi` was the only adapter without a stub, `sandbox_on` keeps the
real PATH behind `test/stubs/`, and `PI_AUTH` defaults to the real
`~/.pi/agent/auth.json` - so every `fa bootstrap` in `test_bootstrap.sh` probed
real models through the real `pi` with the real OpenRouter key. pi's own
session files (cwd = this checkout) show 9 per full run and ~600 since
2026-09-20. Nothing failed; the requests just went out. Fixed in layers: a `pi`
stub; `harness.sh` points every adapter credential override (read from the
adapters themselves) and `FA_CRONTAB_CMD` at nothing by default;
`test_adapters.sh` asserts every adapter's binary resolves to a stub and that
no adapter path - discovered by loading the adapters under a fake HOME, not by
the harness's own pattern - resolves under the real HOME. A full run now
creates zero pi sessions, and dropped from 4m19s to 2m42s.

**Third, found in the real run's own output: every recorded duration was
nonsense.** `date +%s%3N` is GNU-only; this machine's `date` is uutils coreutils
0.8.0 (Ubuntu 26.04), which ignores the `3` and prints nine nanosecond digits,
so a probe "took" `1611968496035662536ms`. Display-only (`.probe.ms`, logs - no
ranking reads it), but it is exactly what a person checking `refresh.log` sees.
`now_ms()` in `common.sh` uses bash 5's `EPOCHREALTIME` (digits only - its
decimal mark follows the locale); a source guard keeps `%N` out of `bin/`.

**Smaller, same session:** `test_adapters.sh` ran `setup.sh` with jq hidden and
setup asked "install them now? [y/N]" on stdin - from a terminal the suite sat
on a prompt it had captured into a file. `</dev/null` there and on every suite
in `run_all.sh`.

**Verified for real on this machine, not just in the suite:** `fa schedule`
replaced the old line (which pointed at the `~/Raimundo-Araujo-Avatar` clone -
whichever clone last ran setup owns the machine-wide cron), then the installed
line was run verbatim the way cron runs it (`env -i`, the PATH from
`/etc/environment`, `/bin/sh -c`): 7 identities, 739 model rows, registry
rewritten, `finished rc=0` in 3m37s. Its probes went through every adapter's
real invoke on the installed versions, which is what the version pins were
waiting for: opencode 1.18.33, kilo 7.6.2, hermes 0.21.3 (the invoke check
`hermes auth upgrade`'s fix deliberately left open), copilot 1.0.86, cursor
2026.09.18 and agy 1.2.16 all answered `ok`, and their pins moved (agy updates
itself - 1.2.12 to 1.2.16 within this session - so it was re-probed on 1.2.16
alone). `fa doctor` is clean: every harness `ok`, the daily refresh section
`ok` with the last run's `rc=0`.

**Seen, deliberately not acted on:**
- `pi_models` counts any `:batch` model as free. All three models the pi lane
  probed were `anthropic/claude-sonnet-*:batch`, all `dead` - here and on
  2026-09-27 - so that lane sits at health `unknown` with batch models first in
  its chain. Whether `:batch` ever means free is unverified; check pi's own
  model list before changing the rule.
- Catching up missed runs: see item 6 under "Next, if resuming".
- Other clones on the same machine still carry the old `schedule.sh` until
  updated, and their setup would install the old line again; `fa doctor` now
  flags an old-shape or stacked line, and `fa update` in that clone fixes it.
- `test_concurrency.sh`'s "width above lane count does not cause churn" sits ON
  its threshold: 12 standalone runs gave exactly 2 `no_lane` events every time
  (limit <= 2), with the old timing and the new alike, and one full-suite run
  got 3 and failed. A pre-existing flake, not this session's change; worth
  understanding why it is always exactly 2 before touching the limit.

Full suite: 32 suites / 564 assertions, offline.
