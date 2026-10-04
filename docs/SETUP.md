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
~/.local/share/free-agents-free-models/setup.sh
```

## 1. Agent CLIs

Install whichever you want. **Each additional agent is only worth installing if you
give it a DIFFERENT credential** — the same key in two agents is one lane, not two.

Known-good versions - each last verified by a real probe through that adapter's
own invoke (the exact call real dispatch makes), on 2026-10-03. The pins live in
each `bin/lib/adapters/<agent>.sh` as `FA_<agent>_VERIFIED_VERSION`:

| Agent | Verified | Metered | Why it matters |
|---|---|---|---|
| opencode | 1.18.33 | | `--dir` contains it; `run -m provider/model` |
| kilo | 7.6.2 | | `--dir` contains it; needs `--auto` to act unattended |
| hermes | 0.21.3 | | `-z`/`-m` are TOP-LEVEL flags, not `chat` args; needs `--provider` for non-active providers |
| copilot | 1.0.86 | yes | allowance-based: auto-included once a token is detected, tried last; `FA_METERED=0/1` forces off/on |
| cursor | 2026.09.18 | yes | allowance-based: auto-included once a token is detected, tried last; `FA_METERED=0/1` forces off/on |
| agy | 1.2.16 | | `--add-dir` contains it, `--print` makes it non-interactive; it updates itself, so expect `differs` between re-verifications |
| pi | 0.85.1 | | `--add-dir` contains it, `--print` makes it non-interactive |

`fa doctor` warns if a version differs. These CLIs have already changed invocation
shape once during this project (`hermes chat -m X -z P` was a usage error), and a
wrong call shape is indistinguishable from a dead model.

## 2. Credentials — where each agent actually keeps them

### opencode → `~/.local/share/opencode/auth.json`

```sh
opencode auth login          # interactive, per provider
```

Produces `{"<provider>": {"type":"api","key":"..."}}`. Providers seen here:
`opencode` (its own account), `openrouter`.

### kilo → two separate things

- **Native gateway**: needs nothing. `kilo.db`'s account tables are empty and it
  still works — the gateway serves this machine unauthenticated. That is a real,
  free wallet.
- **Extra providers**: `~/.config/kilo/kilo.jsonc`. For OpenRouter, add
  an OpenAI-compatible provider entry to `kilo.jsonc` with your key. See
  https://github.com/glenng/kilo for the format.

### hermes → two separate places

- **Nous (its own free tier)**: `hermes auth upgrade` → OAuth, stored in
  `~/.hermes/auth.json` under **`.providers.nous`** (a flat object, hermes's own
  "singleton provider state" - what `hermes auth status nous` actually checks),
  mirrored into `.credential_pool.nous` (an array) for hermes's internal
  pool-select mechanism; `fa` prefers the singleton whenever it holds a real
  `access_token`, falling back to the pool copy otherwise (see
  `bin/lib/adapters/hermes.sh`). (Older hermes versions used `hermes login`
  for this - removed upstream at some point after v0.20.5; a v0.21.3 install
  refuses it outright and points at `auth`/`setup` instead. `auth upgrade` is
  the direct replacement, confirmed against a real v0.21.3 install's own
  `--help`, 2026-09-27.) The access token **rotates hourly**, which is why
  bucket identity uses the JWT `sub` claim rather than the token. Its free
  tier publishes real limits (50 rpm / 2100 rph).
  - **Known hermes quirk, not an `fa` bug**: `hermes auth upgrade` can print
    `Already signed in.` even when `.providers.nous` has no token at all -
    confirmed on two separate machines, and confirmed against `hermes`'s own
    installed source (`hermes_cli/anon_auth.py`'s `is_guest_state()` checks
    only an `auth_method` field, never whether a usable token actually
    exists; a leftover provider "shell" config with no token and no
    `auth_method` key reads as "not a guest" and short-circuits the whole
    login flow). `hermes auth status nous` is the trustworthy check - if it
    says `logged out` right after `auth upgrade` claimed success, believe
    `status`, not `upgrade`.
    - **First-party fix, confirmed by hermes's own runtime**: starting plain
      `hermes` in this exact state prints its own diagnosis and remedy -
      `No access token found for Nous Portal login. Run 'hermes model' to
      re-authenticate.` `hermes model --help` confirms it carries its own
      Nous OAuth login flags (`--portal-url`, `--client-id`, `--scope`,
      `--no-browser`, ...), so it performs the login inline as part of
      picking a provider/model, bypassing the buggy `auth upgrade`
      precondition entirely. This is hermes telling you the fix itself, at
      the point of failure - more trustworthy than the alternative below.
      **Confirmed working end to end, 2026-09-27**: a real second machine
      ran `hermes model`, completed the browser OAuth, and its very next
      `setup.sh` run reported `hermes: already logged in` - the whole
      diagnosis, from "fa says no but hermes says yes" through to a real
      fix, closed the loop on a real account.
    - Alternative if that doesn't work: `hermes auth add nous --type oauth`,
      hermes's generic pooled-credential OAuth path (also bypasses the
      buggy precondition) - not itself tested, since `hermes model` worked.
- **Gateway keys**: `~/.hermes/.env`, e.g. `KILOCODE_API_KEY=...`. The matching
  `credential_pool` entry holds only a `base_url` and a pointer
  (`source: env:KILOCODE_API_KEY`) — not the secret.

## 2b. Automating what can be automated (`keys.env`, optional)

Everything in step 2 above can be done by hand, but three of the seven agents
— opencode, kilo, pi — need nothing but a raw API key dropped into a JSON
file, with no OAuth and no browser. `setup.sh` will do that part for you:

```sh
cp .free-agents/keys.env.example .free-agents/keys.env
# edit keys.env: paste a DIFFERENT OpenRouter key on each line you want to use
.free-agents/setup.sh
```

`setup.sh` reads `keys.env` (gitignored, never committed, chmod'd to `600`
after it's read) and writes each key straight into that agent's own config
file — `~/.local/share/opencode/auth.json`, `~/.config/kilo/kilo.jsonc`,
`~/.pi/agent/auth.json` — in the exact shape each one's own parser expects.
It never touches this tool's own registry, which still never stores a raw
key. If `keys.env` doesn't exist, this step is a silent no-op; nothing about
setup breaks if you never create it.

**Use a different key on every line you fill in.** The same OpenRouter key
pasted into two lines is not two lanes — it's one wallet racing itself for
the same rate limit, which is the exact thing this whole tool exists to
avoid. `setup.sh` warns if it catches a repeat, but can only compare what you
gave it.

The remaining four agents — copilot, cursor, agy, and hermes — need a real
account login, which nothing here can safely do on your behalf: consenting
to an OAuth flow is a decision only you should make. `setup.sh` instead
**detects** who is already logged in (by running each agent's own identity
check, the same one `fa discover` uses), offers to run the one command each
still-missing agent needs, one at a time, and — this is the part that used
to be silent — **prints a final summary of every account still not logged
in**, with the command for each, so nothing gets lost just because it needed
a human:

```
[fa] copilot: already logged in
[fa] cursor: not logged in - cursor-agent login   (unverified guess...)
[fa]   attempt that now? [y/N]
[fa] accounts not yet logged in (2):
[fa]   cursor - cursor-agent login   (unverified guess at the subcommand...)
[fa]   agy - agy login   (unverified guess at the subcommand...)
```

Two of those four commands are verified (`gh auth login` for copilot,
`hermes auth upgrade` for hermes — both documented above). The other two
(`cursor-agent login`, `agy login`) are educated guesses at the CLI's own
subcommand name, never confirmed against a real machine — the hint text says
so, and if the guess is wrong, running the agent's own binary once and
following its prompt works instead.

**If an attempt above actually succeeds, `setup.sh` refreshes the registry
right then** instead of leaving a working credential invisible until the
daily cron (`fa schedule`, installed by the first `fa bootstrap` on this
machine) gets to it or you remember to run `fa refresh` yourself. This is
the one deliberate exception to registry health being otherwise entirely
reactive (it self-corrects at the first real dispatch attempt, never
proactively re-checked — see `bin/lib/common.sh`'s own `registry_status()`
comment) — scoped to exactly the moment a login was just watched succeeding,
never anything broader. Skipped when there is no registry yet at all (the
next step bootstraps unconditionally regardless) or under `--no-bootstrap`.

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
│   ├── keys.env.example  template - tracked, no secret in it
│   ├── keys.env           optional, YOUR keys - gitignored, chmod 600
│   └── (no state/ — the registry is machine-wide, see below)
├── .orch/                 this project's run state
│   ├── tasks.json         THE SPEC — commit this
│   ├── journal.ndjson     what happened here                gitignored
│   ├── learnings.md       patterns from past runs           gitignored
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
  ├── refresh.log                 the daily refresh's output, one stamped run each
  ├── schedule.path               the PATH `fa schedule` ran with - cron's own finds no agent
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

## 6. Maintenance — when and how to update

### When to refresh the registry

| Trigger | What to run |
|---------|-------------|
| Added or swapped a credential | `fa refresh` |
| Installed a new agent CLI | `fa refresh` |
| A model hangs or fails repeatedly | Check `fa findings` — the tool may already have blocklisted it |
| Provider changed its free-model list | `fa discover && fa probe` (daily cron handles this automatically) |
| Installed an agent CLI in a new directory | `fa schedule` — the daily refresh only sees the `PATH` it was scheduled with |
| `fa doctor`'s **daily refresh** section reports a problem | Do what that line says — usually `fa schedule` from the shell you run your agents in |

`fa doctor` reports `current` / `STALE` / `aged:<days>` / `MISSING` — trust it over
guessing.

### Is the daily refresh actually running?

`fa doctor` answers that in its own **daily refresh** section, and never fails
over it (like registry age, a stale refresh stops nothing today):

```
daily refresh
  ok      0 3 * * *  /path/to/.free-agents/bin/fa refresh  (finds all 7 installed agents)
  ok      last run: 2026-10-04T07:00:02Z scheduled refresh: finished rc=0
```

It flags, each with the fix: a line installed by an older copy of the tool
(which ran with cron's bare `PATH` and failed every night, silently — the reason
this section exists), a saved `PATH` that can no longer find an installed agent,
a last run that failed or never finished (details in
`~/.local/state/free-agents/refresh.log`), and a registry two or more days old
despite the schedule. That last one is usually not a failure at all: **cron
skips a run while the machine is off or asleep, and does not catch it up.** A
laptop or WSL machine that is rarely on at 03:00 should move the run to an hour
it is:

```sh
FA_SCHEDULE_HH=13 FA_SCHEDULE_MIN=0 fa schedule   # later refreshes keep this time
```

### When to add a new agent adapter

If you install a new CLI (claude, goose, aider, etc.), add a file in
`bin/lib/adapters/` following the existing patterns. The adapter needs:

1. A `detect()` function — checks if the CLI is installed and authenticated
2. An `invoke()` function — runs the CLI with a prompt and returns output
3. A `models()` function — lists available models for discovery

Register the adapter in `bin/lib/adapters.sh`. `fa doctor` will then surface it
as a healthy lane or flag it as installed-but-unadapted.

### When to update the error taxonomy

If a real provider response is misclassified (e.g., a billing refusal read as
`dead`), the wrong cooldown or ranking update happens. Add the pattern to
`bin/lib/classify.sh`. Real error text is the only source of truth — invented
test data won't catch the next surprise.

### When to add a test

If a bug surfaces in real use, add a test case to `test/` first (so it can't
regress), then fix. No test may touch the real registry — `test/harness.sh`
redirects state to a temp dir and refuses to run against live data.
