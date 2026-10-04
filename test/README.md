# test/

Offline regression suite for `bin/`. No network, no real credentials: every suite
builds its own throwaway registry (`fixture_registry`) and runs against the stub
agent CLIs in `stubs/`.

```sh
bash test/run_all.sh          # everything
bash test/test_lease.sh       # one suite
bash bin/lib/classify.sh --self-test   # the error taxonomy, ~1s
```

| Suite | Proves |
|---|---|
| `test_lease.sh` | One task per credential at a time; unpinned tasks take different wallets |
| `test_ranking.sh` | Ranking is per-category and changes candidate order; wallet faults are not scored against a model |
| `test_requeue.sh` | "All lanes busy" (exit 5) is distinguished from "everything failed" (exit 2) |
| `test_resume.sh` | Resume replays the journal, respects dependency order, never re-runs a completed task |
| `test_verify.sh` | A task that claims success without producing its declared files is failed |
| `test_metered.sh` | Metered wallets are auto-included only when detected with a token and credits remain, hidden when anon or spent, force-off at `FA_METERED=0`, force-on at `=1`/`--allow-metered`, and always ranked last |
| `test_plan.sh` | A goal becomes a valid graph; JSON buried in prose is extracted; a model returning no plan is retried rather than fatal; boundary-violating plans are rejected |
| `test_discover.sh` | Models are attributed to the credential that pays for them; the SAME key in two agents collapses to one lane; no secret is ever stored |
| `test_handoff.sh` | A task with dependents is asked for a handoff and a task without one is not; the dependency's note reaches its dependents and leaks into nothing else; a missing handoff degrades to the old behaviour; every run reports an estimated prompt size and oversized prompts are called out |
| `test_concurrency.sh` | Under a 12-task fan-out over 3 lanes: every task finishes, no two tasks ever share a credential, lanes genuinely overlap, and no churn appears even when width is forced above the lane count |
| `test_bootstrap.sh` | `fa bootstrap` builds a registry from real credentials, installs skills into the project, stores no secret, and is idempotent; `fa doctor` refuses before bootstrap, passes after, and warns when only one lane exists |
| `test_deps.sh` | Cycles and unknown dependency ids terminate rather than hang; a task behind a failed dependency never starts while unrelated work still completes; diamonds run in order; the stall is recorded and surfaced |
| `test_breaker.sh` | A wallet fault cools the whole wallet; a model hang does not; a first cooldown is short; a cooled wallet is skipped; success resets the count |
| `test_adapters.sh` | The harness roster is single-sourced in `bin/lib/adapters.sh` (appears exactly once under `bin/`); each adapter's invoke contract loads; the dispatcher refuses an unknown harness; `fa doctor` version-checks the metered harnesses against their pins (read from the adapters) and the presence broom surfaces installed-but-unadapted CLIs (claude); `missing_deps()` and setup's `exit 3` guard work; every adapter's binary resolves to an offline stub, and no adapter reads a real credential file during a test |
| `test_schedule.sh` | `fa schedule` installs a daily `fa refresh` cron idempotently with the tool's absolute path, state-dir log and pinned state dir, saves the scheduling shell's `PATH`, replaces (never stacks beside) a line from an older copy, keeps a hand-picked time across re-installs, `unschedule` removes only its own line and the saved `PATH`, foreign crons survive both, `FA_NO_SCHEDULE=1` opts out safely, a missing crontab is a graceful note — and `fa bootstrap` wires it in automatically so a fresh clone needs no manual refresh step |
| `test_schedule_cron.sh` | The installed line actually WORKS when run the way cron runs it (`env -i`, bare system `PATH`, `/bin/sh -c`): the refresh restores the saved `PATH`, finds the agents, writes the registry, stamps start and finish in the log and leaves the crontab alone; without its saved `PATH`, and on the pre-fix line, it fails loudly with the cause and the `PATH` it searched; `fa doctor`'s daily refresh section reports each of these |

**Every suite has been mutation-tested** — the corresponding behaviour was
deliberately broken in `bin/` and each suite caught it. A passing test that does
not fail when the code is broken is worse than no test, so treat mutation-testing
as part of adding one.

## Not yet covered

Nothing structural. Every `bin/` script has a suite, and every suite has been
mutation-tested. What is NOT tested, deliberately:

- **Real agent behaviour.** Everything here runs against stubs. Whether a given
  free model can follow a spec is not a property this suite can assert.
- **Real provider failures.** The taxonomy is tested against captured error
  strings (`bin/lib/classify.sh --self-test`), not live 429s.

## How the concurrency test detects a violation

`test_concurrency.sh` cannot observe the lease from outside, so the stub agent
does it: each invocation takes an atomic `mkdir` lock keyed on its lane (the
fixture gives every bucket its own models, so the model prefix IS the lane) and
records a violation if a second call arrives while the first is still running.
Only the stub knows the true start and end of an invocation.

It also asserts the run was genuinely *concurrent* — a serial run would satisfy
the no-overlap invariant trivially — by checking that invocations on different
lanes overlapped in time.

## Safety by default

Sourcing `harness.sh` points everything a suite could damage or spend at
something disposable, before any suite body runs - a suite that forgets a
setting gets the safe one, not the developer's:

- **State** - `FREE_AGENTS_STATE` is a temp dir, and `begin_suite` refuses to
  run if the engine would resolve anything else.
- **Credentials** - every adapter's credential-file override (`OPENCODE_AUTH`,
  `PI_AUTH`, ... - read from the adapters themselves) points at nothing. A suite
  that needs one fabricates it, as `test_bootstrap.sh` does.
- **Agent CLIs** - every adapter's binary has a stub in `stubs/`, which
  `sandbox_on` puts first on `PATH`. `pi` once had none: every bootstrap in the
  suite drove the real `pi` with the real key, and nothing failed - the
  requests just quietly went out. `test_adapters.sh` now asserts both of these.
- **Crontab** - `FA_CRONTAB_CMD` is the stub, which keeps its "crontab" in
  `$FAKE_CRONTAB`.
- **Prompts** - `run_all.sh` gives every suite `</dev/null`, so a y/N prompt
  reads EOF instead of waiting on a terminal.

A new adapter needs a stub in `stubs/` named after its binary, in the same
commit.

## Writing a new suite

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"     # always call the engine as "$REPO/bin/..."
source "$HERE/harness.sh"
begin_suite "what it proves"
fixture_registry 3 || exit 1       # sets FREE_AGENTS_STATE; never call in $( )
sandbox_on                         # stub opencode/kilo/hermes on PATH
...
end_suite
final_report
```

Stub modes: `success ratelimit error hang slow plan`, set with
`mode_for opencode hang` (agent name lowercase — the stub reads `${basename}_STUB_MODE`;
the `pi` stub implements `success ratelimit error hang slow`).
