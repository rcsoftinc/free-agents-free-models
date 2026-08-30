# What token accounting and handoffs would actually buy

Written 2026-08-30, after checking what data is obtainable rather than assuming.

---

## 1. Is the data even there?

Yes, and better than expected.

| Agent | Mechanism | Verdict |
|---|---|---|
| kilo | `kilo.db` → `message.data` JSON: `tokens{input,output,reasoning,cache}`, `cost` | **available** |
| opencode | same schema (`opencode.db`) — kilo is opencode-derived | **available** |
| hermes | `--usage-file PATH` writes JSON after a one-shot run | **available** |
| copilot | `--usage-output-file`, plus `--max-ai-credits` as a hard cap | **available + enforceable** |
| cursor | nothing | **none** |

**Free models do report real counts.** Of the last 200 assistant messages in kilo's
store, **193 carried nonzero token counts**. An earlier assumption that free tiers
report zeros was wrong — it came from one unlucky sample.

One observed call used **31,875 input tokens**. Today that is completely invisible.

## 2. What token accounting buys

Ranked by how much it actually changes behaviour.

### a. Predictive lane health — the only *protective* win

`nous` publishes real budgets in its own token: `tpm=500000`, `tph=6000000`.
Today the tool discovers exhaustion the only way it can — by getting refused, then
cooling the wallet for 15 minutes.

With accounting, that lane becomes **predictable**: at ~5M of 6M tokens in the hour,
route away *before* the 429. This converts a reactive breaker into a predictive one
for that lane. It is the single most valuable thing on this list.

`copilot` is the same shape with a different unit: 193/200 credits, and
`--max-ai-credits` can enforce a ceiling per session.

**Scope check: 2 of 7 lanes have a published budget.** For the other five, accounting
is diagnostic only. That is a narrower win than "token accounting" sounds like.

### b. Catching prompt bloat

A 31,875-token input on a free model is slow, failure-prone, and usually a spec that
accidentally swallowed a file listing. Accounting surfaces which tasks do this. This
is the main upstream cause of `context_overflow` and of unexplained slow calls.

### c. Efficiency-aware ranking

Ranking is currently `ok` / `fail`. It could become "succeeds *and* cheaply" — a model
that burns 30k tokens for what another does in 3k is worse even when both succeed.
Cheap to add once the numbers exist: one more term in the existing score.

### d. Honest reporting

"This project cost 480k tokens across 6 tasks" — useful for judging whether
orchestration paid, which is currently unanswerable.

### What it does NOT buy

- Nothing on the five lanes with no published budget. Tokens there are free and
  unmetered; counting them changes no decision.
- It does not prevent rate limits. Requests-per-minute, not tokens, is what most
  providers actually limit.

**Effort:** three different extraction mechanisms plus a per-lane budget model.
Call it a day's work, most of it plumbing.

## 3. What handoffs buy

### The cheap version (recommended)

A task writes a short `handoff` string as part of its result; the orchestrator injects
the handoffs of tasks named in `deps[]` into the dependent's prompt. Bounded by
construction, no extra model call, degrades to today's behaviour when absent.

Concretely, in the notes-api example: `auth` depends on `config`, and today it waits
for it but never learns what it decided — only what file appeared. With handoffs,
`config` says *"settings load from env with a CONFIG_ prefix; defaults live in
DEFAULTS dict"* and `auth` stops guessing.

Where it changes outcomes:

- **Interface matching.** B must use what A invented. The signature is in the file;
  the reasoning is not.
- **Constraints discovered once.** A found the API needs a version pin; B rediscovers
  it the hard way.
- **Chains deeper than two,** where drift compounds silently.
- **Research → build splits,** where A's entire output *is* B's context. Today this
  shape barely works.

### The expensive version (not recommended yet)

Summarising raw transcripts with a model, as the retired `compress.sh` did. Costs a
lane call per dependency edge, on the resource that is actually scarce, and a summary
is a lossy claim by an agent whose account of itself we already decided not to trust.
Only worth it on long chains.

**Effort:** the cheap version is small — a field in the task result, a lookup over
`deps[]`, an injection alongside the workdir contract.

## 4. Recommendation

**Do handoffs (cheap version) first.** Higher value, lower cost, and it addresses a
real structural limit: the system currently cannot do research-then-build well.

**Then token accounting, but scoped to the two lanes that have budgets** — `nous` and
`copilot`. Predictive routing on `nous` is worth having. Building a general token
ledger for five lanes that have no budget is effort spent where no decision changes.

**Do the bloat detector regardless.** Reading `tokens.input` and warning above a
threshold is a few lines and would have caught that 31,875-token call.

## 5. What neither fixes

Neither addresses the finding from the real-project run: free models produce
structurally correct output with subtle defects, and the yield went 1/4 → 4/4 when
specs named the exact failure modes. **The ceiling is spec quality.** Handoffs help
a worker know more; they do not make it follow instructions better.
