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

## Use it in a project

Go into your project — empty or existing — and clone the tool into it:

```sh
cd ~/projects/thing
gh repo clone noonelifecoach/free-agents-free-models .free-agents
.free-agents/setup.sh
```

Everything the tool owns lives in **two hidden directories**: `.free-agents/`
(the clone) and `.orch/` (this project's run state). `setup.sh` adds
`.free-agents/` to your `.gitignore`, so the tool never becomes part of your repo.

Then **start any agent's TUI** from that directory — `opencode`, `kilo`, `hermes`,
`claude` — and paste a prompt:

```
.free-agents/prompts/00-coordinator.md      set the working mode (paste this first)
.free-agents/prompts/01-plan-only.md        plan, don't build
.free-agents/prompts/02-build.md            execute the plan
.free-agents/prompts/03-resume.md           continue after an interruption
.free-agents/prompts/04-single-task.md      one task, no orchestration
```

Pasting is deliberate. Agents do not read `AGENTS.md` consistently — tested here,
kilo picks it up and quotes the gate exactly, hermes ignores it and falls back to
its own idea of when to parallelise. A pasted prompt works in all of them.

You can also drive it directly, without an agent:

```sh
.free-agents/bin/fa lanes -v          # how many independent credential lanes
.free-agents/bin/fa plan "a goal"     # goal -> .orch/tasks.json
.free-agents/bin/fa orch run          # execute across every healthy lane
.free-agents/bin/fa status            # progress
.free-agents/bin/fa resume            # safe after ANY interruption
```

## Once per machine: credentials

The registry is **machine state, shared by every project**, so cloning per project
does not mean rediscovering credentials per project.

```sh
.free-agents/bin/fa discover && .free-agents/bin/fa probe
.free-agents/bin/fa doctor
```

Where each agent keeps its keys: `docs/SETUP.md`.

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
