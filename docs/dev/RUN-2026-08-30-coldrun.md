# Run record — coldrun, 2026-08-30

Third real project, and the first designed to **fail** rather than succeed.

**Result:** it did not fail. 5 tasks, 1 lane, 0 failures — and the finding is a
correction to how the gate has been described.

Published at `github.com/noonelifecoach/coldrun` (private).

## Setup — what was induced, what was real

Three wallets were parked by writing cooldowns into a **copy** of the registry
(`FREE_AGENTS_STATE` pointed at a scratch dir; the real registry was untouched).
A fourth, `opencode`, was **genuinely** rate-limited at the time — 3 consecutive
failures, 8 minutes remaining, earned by the mdsite and fmtkit runs earlier the
same day.

That left exactly one usable wallet, `kilo:anon`, for five tasks. It also
deliberately violated the coordinator's own gate, which says to work directly
below two healthy lanes.

The starvation was induced. Everything that followed was real.

## What happened

```
5 tasks · 1 lane
14 dispatches · 9 no_lane requeues · 0 attempt_failed
5 done · 0 failed
```

Every task ran on `kilo:anon` via `kilo/meituan/longcat-2.0-free`. The engine
serialized onto the single wallet and backed off between attempts
(`requeue timefmt (no lane free; waiting 10s)`).

- **Starvation cost no retry budget.** Nine requeues, zero attempt failures — a
  task that cannot get a lane is not a task that failed. This is the property the
  `no_lane` exit code exists for, now observed outside the test suite.
- **The journal stayed intact** under repeated requeueing. That matters more than
  the code: it is the only record `resume` can read.
- **`resume` re-ran nothing**, correctly.

## The finding — a correction

The gate's `lanes >= 2` rule is about **throughput, not correctness**.

One lane produced the same five working modules; it merely serialized them. I had
been describing the rule as preventing a *mistake*, which overstates it: the
failure mode is slowness, not breakage. "Do not orchestrate on one lane" reads
like a warning about correctness and it is not one.

The rule is still right — orchestrating on one lane buys nothing and adds
coordination overhead — but the reason is efficiency.

## What three real runs still have not shown

`kilo:anon` finished at `state=ok, fails=0`. Five sequential builds never tripped
its rate limit.

So across mdsite, fmtkit and coldrun — 19 tasks, 3 projects — **not one real
provider failure occurred mid-build.** The breaker, cooldown escalation and
cross-wallet rerouting remain verified only by the 185-assertion suite.

That gap is now hard to close deliberately: this free tier is more generous than
expected. It will likely close by itself during a genuinely large build, and
should not be forced by hammering providers for the sake of a test.
