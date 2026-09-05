# Setting up a new machine

The repo reproduces the **tool**. It cannot reproduce your **credentials** — those
are secrets and live in each agent's own config. This is the manual part, and it is
the part that is easy to get wrong, so it is written down exactly.

Everything here was established by inspecting a working machine, not from vendor
docs. Each agent stores credentials somewhere different, and none of them documents
it clearly.

## 0. Tool

The repo is **private**, so clone with `gh` (which carries your GitHub auth).
Plain `git clone` over SSH only works if that machine has an SSH key on your
GitHub account — it does not by default.

```sh
gh auth login                                    # once per machine
gh repo clone rcsoftinc/free-agents-free-models \
   ~/.local/share/free-agents-free-models
~/.local/share/free-agents-free-models/install.sh
```

## 1. Agent CLIs

Install whichever you want. **Each additional agent is only worth installing if you
give it a DIFFERENT credential** — the same key in two agents is one lane, not two.

Known-good versions (the ones this was built and verified against):

| Agent | Verified | Metered | Why it matters |
|---|---|---|---|
| opencode | 1.17.20 | | `--dir` contains it; `run -m provider/model` |
| kilo | 7.5.5 | | `--dir` contains it; needs `--auto` to act unattended |
| hermes | 0.20.5 | | `-z`/`-m` are TOP-LEVEL flags, not `chat` args; needs `--provider` for non-active providers |
| copilot | 1.0.83 | yes | allowance-based: auto-included once a token is detected, tried last; `FA_METERED=0/1` forces off/on |
| cursor | 2026.09.02 | yes | allowance-based: auto-included once a token is detected, tried last; `FA_METERED=0/1` forces off/on |

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

`.free-agents/setup.sh` does this for you on a machine with no registry — it runs
bootstrap rather than printing the command. Run the pieces by hand only if you
want to see them individually:

```sh
fa discover      # enumerate models per credential actually held
fa probe         # prove each wallet answers
fa doctor        # dependencies, agents, taxonomy self-test, lanes
fa lanes -v
```

Later, when you add a key or install another agent:

```sh
fa refresh       # alias for bootstrap
```

`fa doctor` tells you when that is needed, so you do not have to track it. It
reports one of:

| Status | Meaning |
|---|---|
| `ok ... credentials unchanged` | the registry matches what this machine holds |
| `STALE  your credentials changed` | a key was added or swapped — it is invisible until you refresh |
| `STALE  an agent ... has no lane yet` | an agent was installed after discovery |
| `note  N days old` | advisory only, never a failure; provider model lists drift |
| `MISSING` | no registry — run `fa bootstrap` |

Staleness is measured by **credential fingerprint**, not file timestamps. The
nous OAuth token rotates hourly and kilo writes its database on every run, so
mtimes report both as changed constantly; the fingerprints do not move. See
README, "When to refresh".

`fa discover` reads each CLI's own model list per credential — never third-party
metadata, which produced 7 unreachable routes and missed an entire wallet.

## 3b. Where every file lives

```
myproject/
├── .free-agents/          the tool clone                    ~458 KB
│   ├── bin/ prompts/ skills/ data/ docs/ test/ AGENTS.md setup.sh
│   └── (no state/ — the registry is machine-wide, see below)
├── .orch/                 this project's run state
│   ├── tasks.json         THE SPEC — commit this
│   ├── journal.ndjson     what happened here                gitignored
│   ├── results/           raw agent output                  gitignored
│   └── handoffs/          one line per task                 gitignored
├── .opencode/skills/      ABSOLUTE symlinks to the skill cards in the clone
├── .gitignore             gains `.free-agents/` — only if this is a git repo
└── ...your code
```

`skills/` inside the clone is the **only** copy. A second one under
`.opencode/skills/` is not merely redundant: opencode reads `.opencode/skills/`
relative to the directory it is started in, so a stale duplicate in the clone
silently outranks the real one. The repo tracked exactly that for a while — the
pre-cleanup coordinator playbook, with the superseded orchestrate gate — until a
test was added to keep it out.

**Credentials are always outside the project, under every configuration.** The
tool only ever *reads* these — it never writes them and never copies them in:

```
~/.local/state/free-agents/       THE REGISTRY — shared by every project
  ├── buckets.json                wallets, models, health, rankings  ~260 KB
  ├── findings.ndjson
  └── leases/                     one lock per wallet, machine-wide

~/.local/share/opencode/auth.json      credentials — read only, never written
~/.config/kilo/kilo.jsonc      ~/.local/share/kilo/kilo.db
~/.hermes/auth.json   ~/.hermes/.env   ~/.hermes/config.yaml
```

### The registry is global by default

It lives at `~/.local/state/free-agents`, **not** inside the clone. Only `state/`
sits outside the project:

| Moves out | Stays in the project |
|---|---|
| `buckets.json`, `findings.ndjson` | `.orch/tasks.json` — the spec |
| `leases/` | `.orch/journal.ndjson`, `results/`, `handoffs/` |
| | `.opencode/skills/`, the `.gitignore` entry |

`.orch/` never moves — it records what happened *here*.

Two consequences:

- **Why:** leases live in the registry, so a machine-wide one lets two projects
  running at the same time see each other's locks. Per-clone registries could
  not, making simultaneous projects a real collision hazard — the exact thing
  this design exists to prevent.
- **Cost:** deleting `.free-agents/` no longer removes everything. Set
  `FREE_AGENTS_STATE="$PWD/.free-agents/state"` for per-project isolation.

## 4. Per machine vs per project

What you actually run, and how often:

| | Once per machine | Once per project |
|---|---|---|
| clone the repo into `.free-agents/` | | ✓ |
| `.free-agents/setup.sh` | | ✓ |
| `fa bootstrap` (~2 min, network) | ✓ | |
| `fa refresh` | when a credential or agent changes | |

`setup.sh` runs bootstrap itself when the machine has no registry, so from the
second project onward there is nothing to wait for — it reports the registry
state and finishes.

The split is deliberate, and it is the same one `docker login`, `aws`, and `gh`
make: you reproduce **capability** per machine and **specification** per project.

| | Lives in | Travels with |
|---|---|---|
| The tool | `.free-agents/` in each project (a clone) | this repo |
| Credentials | each agent's own config | **nothing — set up per machine** |
| Learned wallet health | `~/.local/state/free-agents/buckets.json` | nothing (rebuilt by `fa bootstrap`) |
| Routing rules | `AGENTS.md`, `CLAUDE.md`, `.opencode/skills/` | **your project's git** |
| Task graph | `.orch/tasks.json` | **your project's git** |
| Run journal | `.orch/journal.ndjson` | nothing (gitignored) |

So a **project** *is* reproducible in the sense that matters: commit the 6 files
from `fa init` plus `.orch/tasks.json`, and anyone with their own lanes can run
`fa orch run .orch/tasks.json` and get equivalent work. What they will not get is
byte-identical output — free models are nondeterministic — or the same wallets.

`.orch/journal.ndjson` is deliberately **not** committed. It records which wallet
served which task on one machine; that is a property of that machine at that
moment, not of the project, and committing it would conflict on every run while
reproducing nothing.

## 5. What "reproducible" does and does not mean here

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
