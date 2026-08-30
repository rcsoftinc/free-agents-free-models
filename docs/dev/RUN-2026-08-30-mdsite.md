# Run record — mdsite, 2026-08-30

The first real project built end to end with this tool. Recorded here because a
claim about a system like this is worth nothing without a run you can check.

**Ask:** *"a markdown-to-static-site generator: parser, template engine, cli, tests"*

**Result:** 6 tasks, 0 failures, 419 lines of Python, 29 passing tests, 7m38s.

## What ran where

The coordinator never named an agent or a model. The engine chose per attempt.

| Task | Wallet | Agent | Model | Time |
|---|---|---|---|---:|
| parser | kilocode | hermes | dots-studio/dots-3-note-preview:free | 294s |
| template | kilocode | hermes | dots-studio/dots-3-note-preview:free | 79s |
| test_template | openrouter.ai | kilo | openai/dots-studio/dots-3-note-preview:free | 27s |
| test_parser | nous | hermes | poolside/laguna-xs-2.1:free | 15s |
| build | kilo | kilo | kilo/inclusionai/ling-3.0-flash-fin:free | 48s |
| cli | openrouter.ai | kilo | openai/minimax/minimax-m3:free | 114s |

Four wallets, two agents, five distinct models. One agent served two different
wallets and one wallet served two tasks — both legitimate, because the lease is
per credential.

## Incidents

**None.** No rate limits, hangs, unverified tasks, requeues or retries. Prompt
sizes 281–492 tokens, far below the bloat threshold.

The previous run (the `bin/` test suite) hit four incidents. Two things changed
since: suitability filtering removed 10 models that were previously drawable but
could never have worked, and the specs were far more precise.

## Handoffs earned their place, provably

`template.py` implemented something the spec never asked for and said so:

```
---HANDOFF--- template.py exposes render(template, context) and
render_file(path, context) with {{ key }} (including dotted {{ user.name }})
substitution and {% for %} block iteration, missing keys render empty.
```

`build.py`, having received that line, then wrote:

```python
for part in key.split("."):
```

Dotted paths are not in the spec and are not visible from `build`'s side — a
worker receives a string, not a repository. Before handoffs, `build` would have
implemented flat keys only and silently lost the capability. This is the first
hard evidence the feature does what it was built for, and it was not planted.

## Independently verified

17 checks, none of which read the agents' reports:

- all 6 declared files exist and parse as Python
- all 4 modules import with no third-party dependencies
- every required interface exists with the specified signature
- both generated test files pass when executed (12 + 17 tests)
- `cli.py build content -o site` produces real HTML
- a page the models never saw renders correctly: headings, lists, links, inline
  code and front-matter titles

## What this does and does not show

**Does:** the scheduling, isolation, verification and handoff machinery works on
a real task graph with a genuine dependency chain, on free models, unattended.

**Does not:** prove free models are reliable. The earlier run went 1 of 4, then
4 of 4 once the specs named the exact failure modes; this went 6 of 6 first time.
Most of that difference is **spec quality** — precise interface contracts, which
I only knew to write because the earlier run failed — and some is the filtering.
The ceiling is still the spec, not the model.

**Caveat on parallelism:** width was never 6. Only two tasks had no dependencies,
so the graph set the pace, not the lane count — `build` waited 294s on `parser`
while three lanes sat idle. A wider graph would use the lanes better; this one
was shaped like a chain.

Project published separately at `github.com/noonelifecoach/mdsite` (private).
Its `.orch/tasks.json` is committed, so the build can be reproduced on any machine
with its own lanes — equivalent software from different models, which is the honest
form of reproducibility this design offers.
