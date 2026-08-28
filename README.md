# free-agents

Run real coding work on **free models** across several agent CLIs (opencode, kilo,
hermes) without a rate limit ever stopping you, and without two workers fighting
over the same API key.

## The one idea

A **bucket** is one wallet: `(provider, credential)`. It is the unit of rate
limiting, so it is the unit of scheduling — **not the agent**.

Three agents configured with the same OpenRouter key are **one lane**. Running them
together does not go faster; it races that one key into its own 429. Two agents with
*different* keys are two lanes even when running the same model. Bucket ids are
derived from the credential, so this is detected rather than assumed.

## Quick start

```sh
bin/buckets.sh discover && bin/buckets.sh probe    # once per machine
bin/buckets.sh lanes -v                            # how many independent lanes

bin/run.sh -w . "one task"                         # single task, with fallback
bin/plan.sh -w . "a goal"                          # goal -> .orch/tasks.json
bin/orch.sh run .orch/tasks.json                   # run it; width = healthy lanes
bin/orch.sh status                                 # progress
bin/orch.sh resume                                 # safe after ANY interruption
```

Install into another project:

```sh
bash workflow-kit/install.sh /path/to/project
```

## Layout

| Path | What |
|---|---|
| `bin/buckets.sh` | Credential registry: `lanes`, `discover`, `probe`, `show` |
| `bin/run.sh` | The dispatch engine — fallback chain, bucket lease, circuit breaker |
| `bin/plan.sh` | Goal → task graph (planning itself has fallback) |
| `bin/orch.sh` | Task graph per project, journal-based resume |
| `bin/lib/` | `common.sh` (paths, locking) · `classify.sh` (the error taxonomy) |
| `skill/SKILL.md` | Packaged skill card |
| `workflow-kit/` | Installer: routing gate + skills + `bin/` |
| `legacy/` | Layer B, retired — see `legacy/README.md` |
| `opencode-free-agents/` | Layer A: installer + provider discovery (its `oc.sh` is superseded) |

## State

```
~/.local/state/free-agents/buckets.json   wallets + health   GLOBAL (learned)
<project>/.orch/journal.ndjson            append-only log    PER PROJECT
```

Learning is global because a dead wallet is dead everywhere. Run state is local so
two projects can run at once. Resume replays the journal — there is no mutable
status field for a crash to leave lying.

## Tests

```sh
bash bin/lib/classify.sh --self-test    # error taxonomy, 19 cases, offline, ~1s
bash test/run_all.sh                    # 14 suites — NOTE: these cover legacy/
bin/buckets.sh lanes                    # smoke check: >0 means credentials work
```

`test/` currently exercises the **retired** Layer B, not `bin/`. The new engine is
verified by end-to-end runs, not by regression tests. That gap is the main reason
`legacy/` still exists.

## Docs

- **`docs/ALIGNMENT.md`** — the design, every finding, and the build log. Current.
- `docs/ANALYSIS.md` — the original survey. Historical.
- `SESSION.md` — where the work stands and what is next.
- `AGENTS.md` — when to work directly vs orchestrate (the gate).

## Things that cost real debugging time

- These CLIs **exit 0 on hard failures** (hermes returns 0 on HTTP 404 and on a
  billing refusal). Classify on output, never on exit code.
- **Containment differs per agent**: `opencode --dir`, `kilo --dir`, and hermes via
  `HOME` — it honours neither `cwd` nor `--in`.
- A route is `(agent, model, **provider**)`. `hermes -m X` resolves against its
  *active* provider only.
- A model can still write to an absolute path regardless of any flag. **Verify the
  files; an agent reporting success is not evidence.**
