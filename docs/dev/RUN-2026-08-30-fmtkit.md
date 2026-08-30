# Run record — fmtkit, 2026-08-30

Second real project, designed to stress what the first one could not.

**Shape:** deliberately WIDE — seven tasks with no dependencies at all, so the
**lane count** rather than the dependency chain was the binding constraint, plus
one integrator depending on all seven.

**Result:** 8 tasks, 0 failures, 503 lines of Python, 309s, 4 wallets.
Published at `github.com/noonelifecoach/fmtkit` (private).

## What it proved that mdsite could not

| | mdsite (chain) | fmtkit (wide) |
|---|---|---|
| Tasks | 6 | 8 |
| Peak concurrency | 3 | **5 — full saturation** |
| Limiting factor | the dependency graph | **the lane count** |
| `no_lane` requeues | 0 | **4** |
| Wall clock | 458s | 309s |

mdsite showed the *graph* limiting throughput; fmtkit shows the *lanes* limiting
it, which is the healthier constraint — it means adding a sixth credential would
directly buy speed.

## The contention path, exercised for real

`difftext` was requeued **3 times** and `tabulate` once, when every wallet was
leased. Each requeue: no attempt spent, no retry budget consumed, both tasks
completed normally once a lane freed.

This is the fix from the churn work running under load it had never seen. In the
original churn incident a single task spun 9 times at a fixed interval; here the
free-lane check plus backoff meant four requeues total across a fully saturated
scheduler.

## Handoff injection at scale

The integrator depended on all seven modules and received all seven handoffs:

- 7 handoffs captured, **1,288 characters total**
- `cli` prompt: **636 tokens** — well under the 8,000 bloat threshold
- No bloat warning fired

It used them. `fmtkit.py` calls `csv_to_json`, `json_to_csv`, `ini_to_json`,
`xml_to_json`, `flatten`, `tabulate`, `diff_text` — **all seven exact names**,
none inferred from filenames, which its spec explicitly forbade.

## Verified independently

12 checks, none reading the agents' reports. Each converter was *executed*
against a real sample rather than merely imported:

```
csv2json  -> "Ada"          flatten   -> {'a.b': 1, 'c.0': 7}
ini2json  -> "8080"         unflatten -> round-trips
xml2json  -> "root"         difftext  -> non-empty on diff, empty on identical
json2csv  -> "name,age"     fmtkit --list -> all 7 commands
```

Plus three real conversions through the integrator.

## Still not shown

**Failure handling in a real project.** Two clean runs in a row means every
incident this system handles has been observed only in the test suite or in the
earliest development runs. The recovery paths are covered by 185 assertions and
mutation-tested, but no real project has yet hit a rate limit mid-build.

That is a good problem, but it is a gap in the evidence, not proof of
robustness.
