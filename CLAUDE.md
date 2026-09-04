# Working on this repo

This file is for an agent **improving the tool**. If you are here to *use* it on
someone's project, you want `prompts/coordinator.md` instead — different job.

## What this is, in one paragraph

It runs AI coding agents (opencode, kilo, hermes, copilot, cursor) on **free
models** without ever blocking on a rate limit. The central idea: **a bucket is
one wallet — one `(provider, credential)` pair — and the wallet is the unit of
rate limiting, therefore the unit of scheduling.** Never the agent. Two agents
configured with the same API key are **one lane**, and running them in parallel
only races that wallet into its own limit. Parallel width = number of healthy
buckets, nothing else.

## Read in this order

1. **`docs/dev/SESSION.md`** — current state, the invariants, every bug the suite
   found, what is deliberately untested, and a ranked "next if resuming" list.
   Start here; it is the only file that is kept current on purpose.
2. **`docs/dev/ALIGNMENT.md`** — the design and why: bucket identity, error
   attribution, build order.
3. **`README.md`** — the user-facing story, and when a registry refresh is needed.
4. **`docs/SETUP.md`** — install, where each agent hides its credentials, and the
   full file layout (project side vs machine-wide).
5. **`test/`** — 245 assertions, 15 suites, offline against stubs. The most
   reliable specification here; prose can drift, these cannot.

`docs/dev/ANALYSIS.md` is historical — the original three-layer survey. Useful
for "why is it like this", not for what the code does now.

## Invariants — breaking one of these is a regression, not a refactor

- **One task per credential at a time.** Two agents on one key are not faster.
- **Attribution decides blast radius.** Wallet faults (rate limit / billing /
  auth) cool the **wallet**; a model hang demotes the **model** only;
  `local_network` is recorded **nowhere** — a failure we caused is not evidence
  about a provider, and it would poison the rankings, the one thing that compounds.
- **Cooldowns escalate.** A first failure is short (15m). A single transient 401
  once benched a healthy 21-model wallet for 24 hours.
- **Verify, do not trust.** A declared file must exist afterwards *and*, on an
  existing codebase, must have changed. An agent reporting success is not evidence.
- **These CLIs exit 0 on hard failures.** Classify on output, never on `rc`.
- **They ignore `cd`.** Containment is per-agent: `opencode --dir`, `kilo --dir`,
  hermes via `HOME` + `HERMES_HOME`. There is no uniform flag.
- **Staleness compares what discovery *examined*, not what it produced.** The
  registry records `identified` and `examined_agents` for exactly this reason: a
  credential that reached no free model yields no bucket, and would otherwise
  read as "new" on every single run.
- **One writer per artifact.** Two copies of one thing, and the wrong copy wins
  by ordering — this repo has been bitten twice (a stale coordinator playbook
  under `.opencode/`, and `.orch/.gitignore`). If you find yourself writing a
  second definition of something, don't.

## The tooling

```
bin/fa            single entry point (bootstrap | refresh | doctor | lanes | run | orch | findings)
bin/buckets.sh    credential registry      identify | discover | probe | lanes | show
bin/run.sh        dispatch engine          one task -> one result, with fallback
bin/orch.sh       per-project task graph   init | run | status | resume
bin/lib/classify.sh   the error taxonomy - has its own self-test
```

## Before you commit

```sh
bash test/run_all.sh          # must print ALL SUITES PASSED
bin/fa doctor                 # registry state must not have regressed
```

The suite is offline and runs against `test/stubs/`. It must stay that way — no
test may contact a provider or touch the real registry at
`~/.local/state/free-agents/`. `test/harness.sh` redirects `FREE_AGENTS_STATE` to
a temp dir at source time and asserts it is disposable; do not defeat that. A
test must also never write into the checkout it is testing.

## How real usage feeds back

Heavy use surfaces things no test suite can invent. Findings are how they get
back here:

```sh
fa findings                    # what the tool noticed it handled badly
fa findings --note "..."       # something only you or the coordinator saw
fa findings --issue            # format them as GitHub issues
fa findings --ack              # mark as seen
```

Six kinds, and the split matters:

| kind | what it means |
|---|---|
| `unclassified` | provider output no taxonomy rule matched — handled as `dead`, but the text is kept |
| `all_lanes_failed` | every healthy lane failed on one task, so the **task** is the suspect, not the credentials |
| `unverified_repeat` | a task claimed success without producing its files, more than once |
| `missing_handoff` | a task with dependents wrote no handoff line, so they ran blind. Nothing failed; the work quietly got worse |
| `deadlock` | a task graph could not progress |
| `note` | recorded by hand — the channel for what no heuristic reaches |

The first five are the tool noticing something about itself. **`note` is the one
that catches "the spec was ambiguous" or "the plan split this wrong"** — real
failures that no detector will ever see. If you are the coordinator and you
notice one, record it; otherwise it dies with the terminal session.

Findings are never auto-filed — the coordinator reports, the human decides.
Everything is redacted on the way in (keys, JWTs, bearer tokens, emails) so a
finding is safe to paste into a public issue. Repeats collapse by fingerprint,
so twenty occurrences are one row with a count.

**Real provider error text is the only source of truth for the taxonomy**: two of
the first four real messages we saw were misclassified, and no amount of invented
test data would have caught either.

## What is deliberately not tested

- **Real agent behaviour.** Everything runs against stubs; whether a free model
  can follow a spec is not assertable here.
- **A live provider failure mid-build.** Three projects, 19 tasks, not one
  genuine mid-flight failure yet. The breaker, cooldown escalation and cross-wallet
  rerouting are verified only by the suite. **Do not force this by hammering
  providers** — it will happen on its own during a large build.

## Working agreements

- The user runs this in **tmux and cannot read long terminal output.** Write any
  substantial answer, report or plan to a file under `docs/` and give the path.
  Keep the terminal reply short. (`docs/dev/TMUX-CHEATSHEET.md`)
- **Update `docs/dev/SESSION.md` whenever the state of the work changes**, so a
  closed window loses nothing.
- `AGENTS.md` decides *how* to work — direct vs orchestrate — and applies to
  every agent, including work on this repo. Its gate: **≥2 tasks with disjoint
  file sets and no interdependency, AND `fa lanes` ≥ 2.** Default is direct.
