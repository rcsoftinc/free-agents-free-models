# test/

What is here: stub `opencode`, `kilo`, `hermes` and `curl` binaries, plus
`harness.sh` (assertions, stub sandboxing, counters).

What is **not** here: a suite for `bin/`. The engine is currently verified by
end-to-end runs, not by regression tests. That is the biggest known gap in the
project.

The 14 suites that used to live here tested the retired Layer B — they guarded
code that no longer ships, so they were removed rather than left to imply
coverage that did not exist. They are in `git log` if any behaviour is worth
porting.

Worth testing first, offline, using these stubs:

- bucket lease exclusivity (two tasks, one wallet)
- the breaker (bucket-attributable failures cool the wallet; timeouts do not)
- `no_lane` requeue vs genuine exhaustion
- candidate ordering, including per-category ranking
- journal replay: resume runs each task exactly once
- verification: a task that claims success without writing its files must fail
