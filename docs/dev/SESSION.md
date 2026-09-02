# SESSION STATE — read this first on resume

**Last updated:** 2026-09-02

---

## Where we are

**Complete, working, and proven on a real project.** Published privately at
`github.com/noonelifecoach/free-agents-free-models`. Full suite green:
**210 assertions, 14 suites, ~4m, offline.**

**It has built real software unattended, three times.** All on 2026-08-30, all
independently verified against what the code does rather than what the agents
reported:

| Project | Shape | Tasks | Peak lanes | Time | Result |
|---|---|---|---|---|---|
| [mdsite](https://github.com/noonelifecoach/mdsite) | chain | 6 | 3 | 7m38s | 419 lines, 29 tests |
| [fmtkit](https://github.com/noonelifecoach/fmtkit) | wide | 8 | **5** | 5m09s | 503 lines, 8 modules |
| [coldrun](https://github.com/noonelifecoach/coldrun) | starved | 5 | **1** | — | 5 modules, 9 requeues, 0 failures |

Records: **`docs/dev/RUN-2026-08-30-{mdsite,fmtkit,coldrun}.md`**.
The three together matter more than any one: mdsite showed the dependency GRAPH
limiting throughput, fmtkit showed the LANE COUNT limiting it — the healthier
constraint, since another credential then buys speed directly — and coldrun
showed that below the gate's threshold the system slows rather than breaks.

## Documentation map

| Where | What |
|---|---|
| **[Route map](https://claude.ai/code/artifact/68bc7de1-6a06-4242-86f0-957904c09e1f)** | Visual: every route the tool can take — discovery, the gate, the dispatch loop, the taxonomy, and what is deliberately absent |
| **[One run, end to end](https://claude.ai/code/artifact/727f0341-8a96-4e91-99fd-47ec5cdb7076)** | Visual: a real recorded build, with the wide and starved runs compared |
| `docs/dev/ALIGNMENT.md` | The design and every finding — **the source of truth** |
| `docs/dev/RUN-2026-08-30-*.md` | One record per real project, including what each did NOT show |
| `docs/artifacts/README.md` | What to re-check in the published pages when the tool changes |
| `docs/dev/TOKENS-AND-HANDOFFS.md` | Why handoffs were built cheap and token accounting was scoped |
| `docs/SETUP.md` | Where each agent keeps its credentials (the non-reproducible part) |
| `README.md` | User-facing: install, use, invariants |
| `docs/dev/ANALYSIS.md` | Historical — the pre-rebuild survey |

Artifact **sources are vendored** in `docs/artifacts/`, because they otherwise
live only in a session scratchpad. Editing one and republishing to the **same
URL** updates the published page; publishing without the URL creates a duplicate.

**Both artifacts make claims about a live system and go stale silently.**
`docs/artifacts/README.md` lists what must be re-checked — chiefly the lane
counts, the model names, and the statement that no real provider failure has yet
occurred mid-build. If that last one changes, both pages need it.

## The core idea

**A bucket is one wallet: `(provider, credential)`. It is the unit of rate
limiting, so it is the unit of scheduling — never the agent.** Two agents sharing
one API key are ONE lane. Bucket ids derive from the credential, so a shared key
collapses automatically.

**Give each agent a DIFFERENT free key** — that is what multiplies lanes.

## How it is used

```sh
cd myproject
gh repo clone noonelifecoach/free-agents-free-models .free-agents
.free-agents/setup.sh
opencode                                    # or kilo / hermes / cursor / copilot
> paste .free-agents/prompts/coordinator.md # one prompt; it routes on intent
```

`setup.sh` bootstraps by itself when the machine has no registry — it announces
the ~2 min network step first, and `--no-bootstrap` skips it. On a machine that
has already run it, setup just reports the registry's state and there is nothing
to do. The tool lives in `.free-agents/`, this project's run journal in `.orch/`,
and the registry + leases are **machine-wide** at
`~/.local/state/free-agents` (override with `FREE_AGENTS_STATE`).

**Refreshing is event-driven, never scheduled.** `setup.sh` and `fa doctor` both
report `current` / `STALE` / `aged:<days>` / `MISSING`, and `fa refresh` (alias
for `bootstrap`) is the fix. Staleness is measured by **credential fingerprint**,
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
bin/fa            entry point: bootstrap doctor lanes run plan go orch status resume
bin/buckets.sh    credential registry      lanes | discover | probe | show
bin/run.sh        dispatch engine          fallback chain, bucket lease, breaker
bin/plan.sh       goal -> task graph       planning itself has fallback
bin/orch.sh       per-project task graph   run | status | resume (journal replay)
bin/lib/          common.sh (paths, flock) + classify.sh (taxonomy + self-test)
prompts/          coordinator.md - the single pasted prompt
skills/           skill cards, linked into the project by bootstrap
test/             13 suites, stub agents, fixture registry - fully offline
```

## Lanes on this machine

| Lane | Agent | Free models |
|---|---|---:|
| `kilo:anon` | kilo | 24 |
| `openrouter.ai:845a3f96` | kilo | 21 |
| `kilocode:fac9bae9` | hermes | 20 |
| `nous:6b7db10d` | hermes | 6 |
| `opencode:14a1a2f8` | opencode | 3 |
| `copilot:*` / `cursor:*` | copilot / cursor | METERED — opt-in, tried last |
| `freemodel:40d72418` | opencode | 0 — advertises PAID models, excluded |

Metered wallets need `FA_ALLOW_METERED=1`. They cannot bill you
(`overage_permitted: false`) and renew monthly; `fa lanes -v` shows credits left.

## Invariants that must not regress

- **One task per credential at a time.** Two agents on one key do not go faster.
- **Attribution.** Wallet faults (rate limit / billing / auth) cool the WALLET;
  a model hang demotes the MODEL only; `local_network` is recorded NOWHERE.
- **Cooldowns escalate.** A first failure is short (15m) — a single transient 401
  once benched a healthy 21-model wallet for 24h.
- **Verify, do not trust.** A task's declared `files` must exist afterwards AND,
  on an existing codebase, must have **changed** — a file left byte-identical is
  as unverified as one never written. An agent reporting success is not evidence.
- **Findings are the feedback path.** Unrecognised provider output is kept rather
  than swallowed by the taxonomy default. Never auto-filed; the coordinator
  reports, the user decides.
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
9. **The freshness check cried wolf twice while being built** — first by comparing
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

## Next, if resuming

Nothing is outstanding and the tool has been proven on a real project. Options,
roughly in order of value:

0. **IN PROGRESS: a half-built real project**, on another server (no SSH from
   here). Bring back: `fa findings --issue` output, any task that repeats as
   `unverified`, and whether a real rate limit finally lands mid-build. This is
   the first run against an existing codebase rather than a greenfield one. Watch
   for: tasks that declare a file and leave it unchanged (now caught), specs that
   assume context the worker does not have, and any findings the run produces.
1. **A real provider failure mid-build — still unobserved.** Three projects,
   19 tasks, and not one genuine mid-flight failure. coldrun was built to force
   one by starving the scheduler to a single lane; it completed 5/5 anyway. The
   breaker, cooldown escalation and cross-wallet rerouting remain verified only by
   the test suite. **Do not force this by hammering providers** — it will close by
   itself during a genuinely large build.
2. **Token accounting, scoped.** Assessed in `docs/dev/TOKENS-AND-HANDOFFS.md` and
   deliberately not built: worth it only for the two lanes that publish a budget
   (`nous` tph, `copilot` credits), where it turns the reactive breaker into a
   predictive one. A general ledger for the five lanes with no budget changes no
   decision.
3. **Retire `opencode-free-agents/oc.sh`** — already removed from the tree; its
   cross-model session-continuity trick was never ported and remains the only
   capability lost in the rewrite.

**Do not** add: token budgets on unmetered lanes, live leaderboard fetching (see
ALIGNMENT for why gateway metadata beats it), or a summariser-based handoff — each
was evaluated and rejected with reasons recorded.
