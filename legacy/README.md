# legacy/ — Layer B, retired

These scripts were the original multi-agent runner. They are **superseded** and are
kept only so their test suites keep running: a superseded engine that stays on disk
should not be allowed to rot silently, and its tests still encode real behaviour
(backoff arithmetic, provider distribution, exhaustion, dependency resolution).

**Do not build on anything in here.** Nothing outside `legacy/` and `test/` depends
on it.

## What replaced what

| Retired | Replaced by | Why |
|---|---|---|
| `runner.sh` (fallback engine) | `bin/run.sh` | It was one of **three** divergent fallback implementations (A1). It also retried per *agent+model*, which cannot express that two agents sharing one API key are one wallet. |
| `runner.sh` (task execution) | `bin/orch.sh` | Global state in the tool's own directory (A2), so only one project could ever run. No journal, so no crash-safe resume. |
| `orchestrator.sh` (planning) | `bin/plan.sh` | Planning called a single model once with no fallback (B2) — the one call that most needs a chain was the only one without one. |
| `discover.sh` | `bin/buckets.sh discover` | Catalogued *advertised* models from third-party metadata rather than *authenticated routes* (D1): it invented 7 unreachable entries and missed an entire wallet. |
| `rankings.sh` / `promote.sh` | `bin/run.sh` (records outcomes) | Second state store with a different schema, unsynchronised with the first (A1). |
| `handoff.sh` / `compress.sh` | `bin/orch.sh` results + task specs | Self-contained task specs replace transcript hand-off. |
| `resume.sh` | `bin/orch.sh resume` | Resume now replays an append-only journal instead of reading mutable status. |

## Defects fixed here before retirement

- **D2** — `hermes chat -m X -z P` was a usage error, so Layer B never once invoked
  hermes successfully. Every hermes attempt was scored as a model failure.
- **H1** — `promote.sh` backed up `rankings.json` on every call and never pruned
  (489 files). It now prunes to `KEEP_BACKUPS` (20).

## Known defects NOT fixed (deliberately — the code is retired)

- Agent invocations do not pass a working directory, so agents write wherever they
  please. This is **B1**, and `JWT_AUTH_GUIDE.md` in this repo's history was its output.
- Agent CLIs read stdin and drain the caller's read-loop input.
- `IFS=$'\t'` collapses empty fields, silently shifting columns.
- `.orchestrator/config.json` is read but never shipped (**H3**).

`bin/` has all four fixed. If you ever need something from here, port the behaviour
rather than reviving the script.
