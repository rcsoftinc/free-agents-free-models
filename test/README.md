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
| `test_metered.sh` | Metered wallets are opt-in, counted only when allowed, and always ranked last |
| `test_plan.sh` | A goal becomes a valid graph; JSON buried in prose is extracted; a model returning no plan is retried rather than fatal; boundary-violating plans are rejected |
| `test_discover.sh` | Models are attributed to the credential that pays for them; the SAME key in two agents collapses to one lane; no secret is ever stored |
| `test_concurrency.sh` | Under a 12-task fan-out over 3 lanes: every task finishes, no two tasks ever share a credential, lanes genuinely overlap, and no churn appears even when width is forced above the lane count |
| `test_helpers.sh` | `kilo-add-openrouter.sh` preserves the credential it depends on, merges rather than replaces, registers only zero-priced models behind an explicit whitelist, and refuses a commented jsonc; `find-free-providers.sh` ranks by free-model count and omits paid-only providers |
| `test_bootstrap.sh` | `fa bootstrap` builds a registry from real credentials, installs skills into the project, stores no secret, and is idempotent; `fa doctor` refuses before bootstrap, passes after, and warns when only one lane exists |
| `test_deps.sh` | Cycles and unknown dependency ids terminate rather than hang; a task behind a failed dependency never starts while unrelated work still completes; diamonds run in order; the stall is recorded and surfaced |
| `test_breaker.sh` | A wallet fault cools the whole wallet; a model hang does not; a first cooldown is short; a cooled wallet is skipped; success resets the count |

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
`mode_for opencode hang` (agent name lowercase — the stub reads `${basename}_STUB_MODE`).
