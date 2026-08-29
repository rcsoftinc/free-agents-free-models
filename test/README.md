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
| `test_breaker.sh` | A wallet fault cools the whole wallet; a model hang does not; a first cooldown is short; a cooled wallet is skipped; success resets the count |

**Every suite has been mutation-tested** — the corresponding behaviour was
deliberately broken in `bin/` and each suite caught it. A passing test that does
not fail when the code is broken is worse than no test, so treat mutation-testing
as part of adding one.

## Not yet covered

- `bin/plan.sh` — no coverage at all.
- `bin/buckets.sh discover` — needs fake agent config files to test credential
  attribution and the shared-wallet collapse.

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
