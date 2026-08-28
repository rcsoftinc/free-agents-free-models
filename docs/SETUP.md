# Setting up a new machine

The repo reproduces the **tool**. It cannot reproduce your **credentials** — those
are secrets and live in each agent's own config. This is the manual part, and it is
the part that is easy to get wrong, so it is written down exactly.

Everything here was established by inspecting a working machine, not from vendor
docs. Each agent stores credentials somewhere different, and none of them documents
it clearly.

## 0. Tool

```sh
git clone git@github.com:OWNER/free-agents-free-models.git ~/.local/share/free-agents-free-models
~/.local/share/free-agents-free-models/install.sh
```

## 1. Agent CLIs

Install whichever you want. **Each additional agent is only worth installing if you
give it a DIFFERENT credential** — the same key in two agents is one lane, not two.

Known-good versions (the ones this was built and verified against):

| Agent | Verified | Why it matters |
|---|---|---|
| opencode | 1.17.20 | `--dir` contains it; `run -m provider/model` |
| kilo | 7.5.5 | `--dir` contains it; needs `--auto` to act unattended |
| hermes | 0.20.5 | `-z`/`-m` are TOP-LEVEL flags, not `chat` args; needs `--provider` for non-active providers |

`fa doctor` warns if a version differs. These CLIs have already changed invocation
shape once during this project (`hermes chat -m X -z P` was a usage error), and a
wrong call shape is indistinguishable from a dead model.

## 2. Credentials — where each agent actually keeps them

### opencode → `~/.local/share/opencode/auth.json`

```sh
opencode auth login          # interactive, per provider
```

Produces `{"<provider>": {"type":"api","key":"..."}}`. Providers seen here:
`opencode` (its own account), `openrouter`, `freemodel`.

> The `freemodel` provider advertises **paid** frontier models (Claude Opus, GPT-5.x
> at real prices). The registry lists it with 0 free models and will never schedule
> to it. Leave it that way unless you know the gateway serves them free.

### kilo → two separate things

- **Native gateway**: needs nothing. `kilo.db`'s account tables are empty and it
  still works — the gateway serves this machine unauthenticated. That is a real,
  free wallet.
- **Extra providers**: `~/.config/kilo/kilo.jsonc`. For OpenRouter:

  ```sh
  OPENROUTER_API_KEY=sk-or-v1-... fa-repo/bin/kilo-add-openrouter.sh
  ```

  It registers only the zero-priced models and writes an explicit whitelist —
  `whitelist: ["*"]` would expose paid models that we then treat as free.

### hermes → two separate places

- **Nous (its own free tier)**: `hermes login` → OAuth, stored in
  `~/.hermes/auth.json` under `credential_pool`. The access token **rotates
  hourly**, which is why bucket identity uses the JWT `sub` claim rather than the
  token. Its free tier publishes real limits (50 rpm / 2100 rph).
- **Gateway keys**: `~/.hermes/.env`, e.g. `KILOCODE_API_KEY=...`. The matching
  `credential_pool` entry holds only a `base_url` and a pointer
  (`source: env:KILOCODE_API_KEY`) — not the secret.

## 3. Build the registry and verify

```sh
fa discover      # enumerate models per credential actually held
fa probe         # prove each wallet answers
fa doctor        # dependencies, agents, taxonomy self-test, lanes
fa lanes -v
```

`fa discover` reads each CLI's own model list per credential — never third-party
metadata, which produced 7 unreachable routes and missed an entire wallet.

## 4. What "reproducible" does and does not mean here

**Reproducible:** the tool, the install, the routing rules, the error taxonomy
(`bash bin/lib/classify.sh --self-test`), and the *shape* of a run — which wallet
served which task is recorded in `.orch/journal.ndjson`.

**Not reproducible, by nature:**

- **Model output.** Free models are nondeterministic; the same plan yields different
  code each run. This is why tasks declare `files` and the runner verifies them —
  the *contract* is checked even though the *output* varies.
- **Which model serves a task.** Depends on live wallet health. The journal records
  what actually happened; it is not a plan you can replay.
- **The free-model roster.** Providers add and remove free models constantly. This
  self-heals: re-run `fa discover && fa probe`. Models that hang are blocklisted;
  models that fail are demoted by observed results rather than by a static list.

The design treats the churn as the normal case rather than an error — which is why
health is learned and stored globally, and why nothing that cannot be attributed
(your network dropping) is ever written to it.
