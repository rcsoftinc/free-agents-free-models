# Linkbox: from an empty folder to a shipped tool

*A short story about directing software with free agents. It follows one small
project from `mkdir` to production, from your chair: what you type, what you
decide, what the machines do, and what you check them with.*

> **What is real and what is story.** Every command, and every line the tool
> prints, is what free-agents-free-models (`fa`) does today, October 2026. The
> project, the conversations and the mistakes are invented, but each mistake is a
> kind that free models really make. Where the story needs something fa does not
> do yet, it says so. Appendix D lists the seams.

---

## The cast

- **You**, the director. You decide what gets built, approve plans, read the
  tests and approve what ships. You do not write the code.
- **The coordinator**, the one agent you talk to all week, in a herdr pane. It
  turns your decisions into instructions, does the small jobs itself, sends the
  big ones to workers and reviews what comes back.
- **The workers**, free models on your seven lanes. Fast, free, a little
  careless. Each one sees a single written task, never your conversation, and
  cannot ask questions.
- **The referees**, the things that decide whether work is done, so nobody has
  to take a worker's word for it: tests, the type checker, the linter, CI, a
  security scanner, and your own eyes.

## The project

Your operations team keeps the company's important links in a spreadsheet: the
onboarding guide, the vacation form, the VPN instructions. Every week someone
asks for one of them in chat. You want **Linkbox**, a short-link service for the
intranet: `http://go/onboarding` takes you straight to the real page.

It is small on purpose: a little web server, a database file, a command-line
tool and one web page. Small enough to finish in a week, big enough that the
work splits.

---

## Chapter 1: Monday, 8:40. An empty folder

You open a terminal in WSL and make a home for it:

```sh
mkdir ~/linkbox && cd ~/linkbox
git init -b main
git clone https://github.com/rcsoftinc/free-agents-free-models.git .free-agents
.free-agents/setup.sh
```

The tool lives in `.free-agents/`. It is a copy of fa just for this project.
Its memory of your machine (keys, lane health, rankings) is shared by every
project, so this machine already knows its seven lanes. Setup only checks and
prints:

```
[fa] project: /home/you/linkbox
[fa] tool:    /home/you/linkbox/.free-agents
[fa] copilot: already logged in
[fa] cursor: already logged in
[fa] agy: already logged in
[fa] hermes: already logged in
[fa] added .free-agents/ to your .gitignore
[fa] registry: 7 healthy lane(s), 0 days old
[fa]           /home/you/.local/state/free-agents

Ready.

  1. Start any agent from here:  opencode | kilo | hermes | copilot | cursor-agent | agy | pi
  2. Paste this into it:         .free-agents/prompts/coordinator.md
  3. Then just talk normally - it picks the mode itself.
```

It also created `.orch/`, where this project keeps its plan (`tasks.json`), its
settings (`config.yaml`) and its run history. The settings already mark the
usual test folders and CI files **read-only** for workers - you will see why on
Monday morning. One line you fill in yourself once the project has tests:
`verify: npx vitest run`, the project's own check, which fa runs after every
run.

> **Decision 1: may this code go to free providers?** Free tiers often log
> prompts, and some reserve the right to train on them. Linkbox is internal,
> has no secrets and no client data, so yes. For a client project you would run
> `fa lanes -v` first and look for lanes flagged `[TOS:...]`. You would read
> those providers' terms, or keep that repository away from fa entirely.

> **Decision 2: where does the code live?** On GitHub, as a private repository:
>
> ```sh
> gh repo create linkbox --private --source . --remote origin
> git add -A && git commit -m "chore: empty project with fa"
> git push -u origin main
> ```

## Chapter 2: 9:00. The one document you write yourself

Before any agent touches anything, you spend ten minutes on `BRIEF.md`. It is
the only document in this story that no machine writes:

```markdown
# Linkbox v1
Short links for the intranet: http://go/<slug> redirects to a long URL.

Must
- Create a link: a slug and a target URL, optionally an expiry date. Slugs are unique.
- /<slug> redirects (302) and counts a click. Unknown or expired: 404.
- A command-line tool: linkbox add <slug> <url>, linkbox list, linkbox stats <slug>.
- One web page listing every link and its clicks.

Not in v1
- Logins (it is internal only), custom domains, analytics beyond a click count.

Constraints
- Node 22 and TypeScript. One SQLite file.
- No new dependency without asking me.
```

Why bother? Every task a worker receives will quote it, and a cold worker
cannot ask you what you meant. The last line will matter by lunchtime.

## Chapter 3: 9:15. Choosing who sits in the coordinator's chair

You open herdr and start a pane in `~/linkbox`.

> **Decision 3: which agent coordinates?**
> - **A strong paid model** (Claude Code, say) writes better plans, better task
>   instructions and better reviews. fa sees it is not one of its lanes, so all
>   seven free lanes go to workers.
> - **A free agent** (opencode on its free lane) costs nothing. fa
>   automatically keeps workers off that agent's own key so your conversation
>   is never rate-limited, which leaves six lanes for workers. Plans and reviews
>   will be weaker.
>
> You choose the strong model. The quality of the instructions is the ceiling
> on what free workers deliver, and reviews are where their mistakes get
> caught. Free compute is for volume, not judgment.

You paste the contents of `.free-agents/prompts/coordinator.md` as your first
message. Its first instruction makes the coordinator check the machine, so its
first reply is a status report:

> *"I ran `fa doctor`: dependencies ok, all seven agents ok at their verified
> versions, 7 healthy lanes, registry current, daily refresh ok. Ready. What are
> we building?"*

## Chapter 4: 9:20. From an idea to options

You type:

> Read BRIEF.md. Propose how to build Linkbox v1: the architecture, the pieces,
> and how we will know each piece works. Give me options only where there is a
> real choice, with your recommendation.

The answer comes back in under a minute. Shortened:

> *"**Shape:** an Express server (`src/api.ts`), a storage module over SQLite
> (`src/store.ts`) behind an interface in `src/contract.ts`, a CLI that talks
> to the API (`src/cli.ts`), and one static page (`public/`).*
>
> *Option A (recommended): contract and tests first. I write `contract.ts` and
> the acceptance tests myself, now. That's small work that needs our
> conversation. Then workers implement the pieces in parallel, and each piece
> counts as done only when its own tests pass.*
>
> *Option B: workers write code and tests together. It starts faster, but then
> the tests only prove what each worker believed the task was.*
>
> *How we'll know it works: vitest for the server, store and CLI; Playwright for
> the page; the TypeScript compiler in strict mode and ESLint over everything;
> GitHub Actions running all of it on every push."*

> **Decision 4: the approach.**
> "Option A. Two additions: creating a link with a slug that already exists
> must return 409, and the expiry date is optional."

## Chapter 5: 9:40. The small work the coordinator keeps

Writing instructions for this part would take longer than doing it, so the
coordinator does it itself, in front of you:

- `package.json`, a strict `tsconfig.json`, ESLint, vitest and Playwright
  configuration, and the folder layout. Playwright needs a browser even inside
  WSL, so it runs `npx playwright install --with-deps chromium` once.
- `src/contract.ts`: the types and the `Store` interface, so every piece agrees
  on names.
- The acceptance tests: `tests/store.test.ts`, `tests/api.test.ts`,
  `tests/cli.test.ts` and `tests/ui.spec.ts`.
- `.github/workflows/ci.yml`:

  ```yaml
  name: ci
  on: [push, pull_request]
  jobs:
    check:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: actions/setup-node@v4
          with: { node-version: 22, cache: npm }
        - run: npm ci
        - run: npx tsc --noEmit
        - run: npx eslint .
        - run: npx vitest run
        - run: npx playwright install --with-deps chromium
        - run: npx playwright test
  ```

> *"Scaffold and acceptance tests are in: 23 tests, all failing, because nothing
> is implemented yet. That's the point. Please read the test names below. They
> are the contract you're approving."*

This is the most important review of your week, and it is the cheapest one:
test names, not code.

> **Decision 5: approve the contract.** Reading the list, you notice a gap:
> "Nothing tests an expired link. Add one: an expired slug returns 404 and does
> not count a click."

The coordinator adds it (24 tests). Then it starts a branch, `git switch -c v1`,
because nothing reaches `main` without your review, and workers' commits least
of all. It commits ("contract and failing acceptance tests") and pushes the
branch. CI goes red, as it should. Red is the starting line.

## Chapter 6: 10:05. The first dispatch

> Good. Build it.

The coordinator writes the plan, `.orch/tasks.json`. Each task carries its own file boundary and its own
**verify** command: the command that decides "done".

```json
{"tasks":[
  {"id":"store", "deps":[], "files":["src/store.ts"], "category":"coding",
   "verify":"npx vitest run tests/store.test.ts",
   "prompt":"Implement the Store interface below in src/store.ts on SQLite ... (the interface, quoted) ... Touch no other file."},
  {"id":"api", "deps":[], "files":["src/api.ts"], "category":"coding",
   "verify":"npx vitest run tests/api.test.ts",
   "prompt":"Implement the HTTP API in src/api.ts ... duplicate slug -> 409 ... the tests use an in-memory Store, quoted below ..."},
  {"id":"cli", "deps":[], "files":["src/cli.ts"], "category":"coding",
   "verify":"npx vitest run tests/cli.test.ts",
   "prompt":"Implement the CLI in src/cli.ts: add, list (with --json), stats ..."},
  {"id":"ui", "deps":["store","api"], "files":["public/index.html","public/app.js"], "category":"coding",
   "verify":"npx playwright test tests/ui.spec.ts",
   "prompt":"One static page listing links and click counts from GET /api/links ..."},
  {"id":"import", "deps":["store"], "files":["scripts/import-links.ts"], "category":"coding",
   "blocked":"waiting on the old-links export from Operations",
   "prompt":"Import the operations spreadsheet ..."}
]}
```

The last task, `import`, is **blocked** on purpose. It needs the spreadsheet
export Operations promised for Wednesday, and nobody can write a good
instruction for a file they haven't seen. A blocked task is never sent to a
worker and never counted as a failure.

Then the coordinator runs:

```sh
.free-agents/bin/fa dispatch --detach
```

```
[fa] job j1 started in the background: fa dispatch
[fa]   follow it:  fa jobs j1        log: /home/you/linkbox/.orch/jobs/j1/log
[fa]   watching it in herdr pane w1:p2 - it says in the sidebar when it ends
[fa]   tasks:      fa status
[fa]   hands off these files until it ends: public/app.js public/index.html scripts/import-links.ts src/api.ts src/cli.ts src/store.ts
```

Its reply to you is one line, as its instructions require:

> *"Job j1 started: store, api and cli in parallel, ui after them; import waits
> on you. Those six files are off-limits to both of us until it ends. What's
> next?"*

A pane opens to the right of yours. herdr split it that way because your pane
is wide, and your cursor stays where it was. The new pane streams the job:

```
[fa] SPLIT EVALUATION: tasks=5  disjoint_pair=true  lanes=7  trivial=0  -> ORCHESTRATE
[fa] background job j1: running the plan through orch (in the foreground this would be ORCHESTRATE)
[orch] auto-enabled isolation for parallel disjoint tasks
[orch] project=/home/you/linkbox  parallel=7  mode=strict  isolate=1
[orch] isolated store in pool slot 1 (/home/you/linkbox/.orch/worktrees/pool-1)
[orch] dispatch store (pid 48211)
[orch] isolated api in pool slot 2 (/home/you/linkbox/.orch/worktrees/pool-2)
[orch] dispatch api (pid 48230)
[orch] isolated cli in pool slot 3 (/home/you/linkbox/.orch/worktrees/pool-3)
[orch] dispatch cli (pid 48249)
```

Each worker gets its own copy of the repository (a git worktree), so three of
them can write at once without touching each other's files. In herdr's sidebar,
the new pane shows as **fa · working**.

## Chapter 7: 10:10. While it runs, you keep talking

This is the part of the week that used to be waiting time.

> While that runs: how do we deploy this? Docker on the intranet box?

> *"Yes. A two-stage Dockerfile, the SQLite file on a mounted volume so it
> survives updates, a /health endpoint for monitoring. The deploy itself I'll do
> with you, directly. It needs the server's credentials, and those never go into
> a worker's instructions."*

> **Decision 6: deployment.** Docker on the intranet server. The credentials
> stay with you.

Half an hour later:

> How's it going?

The coordinator runs `fa status`:

```
project: /home/you/linkbox
2/5 done, 0 failed, 0 skipped

  done    cli  <- antigravity:3c41a9e0d211  claude-opus-4-6-thinking  (verified)
  done    store  <- kilo:anon  kilo/cohere/north-mini-code:free  (verified)
  WAITING  import  — waiting on the old-links export from Operations
  pending api
  pending ui
```

`(verified)` means the task's own verify command passed. The worker saying
"done" is not what counts.

## Chapter 8: 10:30. What goes wrong (something always does)

You see none of the next three scenes as they happen. They are in the files
under `.orch/results/`, and the coordinator will read them for you.

**A rate limit nobody notices.** The api task first landed on the opencode
lane, which answered "429, too many requests". `.orch/results/api.err` shows
fa moving on without ceremony:

```
[run] attempt 1: opencode:zen  opencode  opencode/fledge-alpha-free  -> rate_limited
[run]   opencode:zen is at fault (rate_limited) - skipping its remaining models
```

The task went to another lane. A second refusal in a row would have benched
that key for an hour, or as long as the provider asked, and every task would
have stayed off it until then.

**A fix round.** The cli worker's first attempt printed a table where the test
expected JSON. Its verify command failed, and fa sent the same worker, on the
same lane, the whole task again, plus the failing test output:

```
[run] its verify command, `npx vitest run tests/cli.test.ts` failed - fix round 1/2, same agent, same lane
[run] verified: npx vitest run tests/cli.test.ts
```

Second try, green. Nobody had to step in.

**The worker that tries to cheat.** The api worker's code answered 500 to a
duplicate slug instead of 409, and its first attempt failed its verify. On its
fix round it took the shortcut free models sometimes take: it changed the test
to expect 500.

It didn't work. Linkbox's `.orch/config.yaml` marks the tests read-only, so
after every worker call fa puts back any change to them, *before* any check
runs:

```
[run] its verify command, `npx vitest run tests/api.test.ts` failed - fix round 1/2, same agent, same lane
[run] put back read-only files the worker changed: tests/api.test.ts
[run] its verify command, `npx vitest run tests/api.test.ts` failed - fix round 2/2, same agent, same lane
[run] verified: npx vitest run tests/api.test.ts
```

The check ran against the real test and failed again. The worker's next round
was told plainly: *its changes to these files were undone - they are read-only
for this task, part of the check, not part of the work.* On the third try it
fixed the code. Verified, honestly.

It also changed `src/contract.ts`, adding an `error` field it fancied - a file
its task never declared. In its own copy of the repository that change was
simply dropped at merge (only declared files come back), but not silently: fa
kept it as a patch and noted it.

At 11:02 a herdr notification slides in, **fa j1 done**, with its "done" sound,
and the sidebar badge turns to **done**.

## Chapter 9: 11:05. Review: trust, but run it

You come back from a call:

> Back. Anything new?

The coordinator's reply starts with the check it runs at the beginning of
every reply:

```
$ fa jobs --news
ended: j1 done after 57m12s - fa dispatch
       review it: fa jobs j1 (its log), fa status (its tasks), the diff and the tests
```

Then it reviews, and you watch:

1. `fa status`: four tasks done, all **(verified)**; import waiting; and two
   notes about the api worker:

   ```
     note    api: read-only files it changed were put back: tests/api.test.ts
     note    api: changed files it did not declare (dropped, not merged; patch: .orch/results/api.undeclared.patch): src/contract.ts
   ```
2. The full suite already ran: Linkbox's config says `verify: npx vitest run`,
   so fa ran it once the run's tasks had landed, and `fa status` says
   `` check   passed  `npx vitest run` ``. All green - the edited test never
   landed anywhere. (Had it failed, fa would have sent one worker to fix it,
   with the suite's output, before telling you.)
3. It reads the patch: an optional `error` field nobody asked for. It leaves it
   out, and says so.
4. The attempt to edit the test is already on record: fa wrote a
   `protected_edit` finding naming the model, without anyone asking.
5. `npx tsc --noEmit`, `npx eslint .`, `npx playwright test`: clean.
6. `git log --oneline` shows the workers' commits: `fa: store`, `fa: cli`,
   `fa: api`, `fa: ui`.

Its report to you is four lines long, and ends with a question: *"Wednesday's
import will need a test of its own. Should a worker be allowed to write it?"*

> **Decision 7: who may write tests.** "The tests are the contract, so I'd
> rather you write them. But if a task is meant to write one, it declares that
> file in its `files` - read-only means *not yours to change*, not
> *untouchable*."

## Chapter 10: 11:30. The page that passes and still looks wrong

Playwright passed: the table exists, the rows render, the counts show. But
tests check structure, not looks. You open the report anyway:

```sh
npx playwright show-report
```

It opens in your Windows browser. The screenshot shows long URLs pushing the
table off the right edge of the screen.

> **Decision 8: the look.** "Truncate long URLs with an ellipsis and show the
> full one on hover."

One CSS rule, so the coordinator does it directly. It also adds a visual check
to the test, `await expect(page).toHaveScreenshot()`. The first run records a
baseline image, you look at it once and approve it, and from then on any change
that breaks the layout fails the test. Your eyes, written down as a test.

## Chapter 11: 11:50. The question no tool asked

Reviewing the security pass (`semgrep scan --config auto`: no findings; a
secret scan with gitleaks: clean), you think like an attacker for a minute:

> What stops someone from creating a link to `javascript:alert(1)`? It's a
> redirect service.

> *"Nothing, right now. No scanner flagged it, because the code is 'correct'.
> It does exactly what it was asked."*

> **Decision 9: security.** "Only http and https targets. Add the test first."

The coordinator writes the test (red), then the fix (green). It takes five
minutes, and only because a person asked.

## Chapter 12: 12:10. The dependency nobody asked for

Part of every review is `git diff main --stat`. It shows that
`package.json` changed. The cli worker added a package called
`tablefy-cli-pro` to draw its table. The coordinator checks it:

```sh
npm view tablefy-cli-pro
```

The package is three weeks old, has one version, no source repository and
eleven downloads. Free models sometimes invent package names, and people
register those names to plant malware there. That's called "slopsquatting".
Your brief said *no new dependency without asking me*.

> **Decision 10: dependencies.** "Remove it." The coordinator rewrites the eight
> lines that used it. On GitHub you also turn on Dependabot alerts and add the
> dependency-review check to CI, so the next one gets flagged before review.

## Chapter 13: 13:30. The pull request

```sh
git push -u origin v1
gh pr create --title "Linkbox v1" --body-file .github/pr-v1.md
gh pr checks --watch
```

The coordinator wrote the description: what each piece does, how each was
verified, what is not done (import, blocked), and the two incidents (the
test a worker tried to edit, the stray dependency). CI goes green: types, lint, every unit
and API test, the browser tests and one screenshot comparison.

> **Decision 11: merge.** You read the description and the test list, open
> the diff of `src/api.ts` (the file with history), and merge.

## Chapter 14: Wednesday, 16:00. The file arrives

Operations sends `old-links.csv`. You drop it into `data/`.

> **Decision 12: is this data safe to show a free worker?** Internal URLs and
> titles, no personal data: yes. If it had held client or employee data, the
> coordinator would have done the import itself, locally.

> The export is in data/old-links.csv. Unblock the import.

The coordinator opens the file, because it can see its real columns and a
worker can't, and writes `tests/import.test.ts` around them. It quotes the
column names into the task's instructions, removes `"blocked"` and adds the
verify command. Then it commits the CSV itself: each worker works in a copy of
the repository made from the last commit, so a file that only sits in your
folder is invisible to them. Then it dispatches the plan again:

```sh
.free-agents/bin/fa dispatch --detach
```

fa replays the journal: four tasks are already done, so only `import` runs.
Twenty minutes later, `fa jobs --news` reports `ended: j2 done`. The review
turns up a nice surprise: 143 links imported, and 2 rejected, one a
`javascript:` link and one a duplicate slug. Your Monday security question just
earned its keep.

## Chapter 15: Thursday. Shipping

Shipping is never a worker's job, because it needs keys. You and the
coordinator do it together:

```sh
docker build -t linkbox:1.0 .
# copy the image to the intranet server (registry or docker save | ssh ... docker load)
docker run -d --name linkbox --restart unless-stopped -p 80:8080 -v /srv/linkbox:/data linkbox:1.0
curl -sI http://go/onboarding        # HTTP/1.1 302 Found, Location: https://...
curl -s  http://go/health            # {"ok":true}
```

The smoke test is three real links and one expired one (404, as promised in
Chapter 5). You post `go/onboarding` in the team chat. Nobody asks for the
spreadsheet again.

## Chapter 16: Friday. Looking back

```sh
.free-agents/bin/fa findings
```

One finding: `protected_edit`, the api worker's attempt on Monday to edit a test,
recorded by fa itself. It is a lesson about free models, not a bug in fa, so
you keep it. If it had been fa's fault, `fa findings --issue
--post` would file it on the tool's own GitHub repository, after listing it and
asking you once.

What the week cost you:
- **Your time:** roughly a day of attention spread over four days, almost all of
  it decisions and reviews.
- **Money:** nothing for the workers. The coordinator's subscription for the
  conversation.
- **Decisions:** twelve, all yours. The machines made none of them. They wrote
  code, ran checks and reported back.

---

## Epilogue: if Linkbox had been something else

**An Android app.** The verify commands become Gradle runs, for example
`./gradlew testDebugUnitTest --tests '*LinkStore*'`. Verify commands run where
fa runs: if that is WSL and your JDK is installed on the Windows side, Gradle
finds only `java.exe`, so install a JDK inside WSL too (`sudo apt install
openjdk-21-jdk`). For looks: Paparazzi or Roborazzi
screenshot tests, which run without a device, and Maestro flows on the emulator
(which runs on Windows). Release signing keys never go into a task, just like
the server credentials here.

**A .NET API with SQL Server.** Verify with `dotnet test --filter LinkStore`.
From WSL with .NET installed on the Windows side, that is `dotnet.exe test
...`, or install the .NET SDK inside WSL. Integration tests run against SQL
Server in a container, which also spares you a Windows-only `sqlcmd`. Database migrations make a
good task of their own, with a verify command that applies them to a throwaway
database.

**A client's project.** Before the first task, read the data terms of each
free provider you would use. When in doubt, the confidential parts stay with
the coordinator, which never sends code to a free lane.

---

## Appendix A: the commands, in order

```sh
# Monday morning: the project
mkdir ~/linkbox && cd ~/linkbox && git init -b main
git clone https://github.com/rcsoftinc/free-agents-free-models.git .free-agents
.free-agents/setup.sh
gh repo create linkbox --private --source . --remote origin
# (write BRIEF.md; start the coordinator in herdr; paste prompts/coordinator.md)

# The coordinator, as the week goes on ("fa" is .free-agents/bin/fa)
fa doctor                       # first thing
git switch -c v1                # all work on a branch; main only through review
fa dispatch --detach            # the plan in .orch/tasks.json, in the background
fa jobs --news                  # at the start of every reply: what finished?
fa status                       # tasks done, (verified), waiting
fa jobs j1                      # one job: state and the end of its log
fa findings --note "..."        # what only a person noticed

# The referees
npx tsc --noEmit                # types
npx eslint .                    # lint
npx vitest run                  # unit and API tests (the contract)
npx playwright test             # the page, including the screenshot comparison
npx playwright show-report      # your eyes
semgrep scan --config auto      # security patterns
npm view <package>              # who is this new dependency?
gh pr checks --watch            # CI: all of the above, on every push
```

## Appendix B: your decisions

| # | When | Decision |
|---|---|---|
| 1 | Mon 8:40 | Internal code may go to free providers. Client code: read their terms first. |
| 2 | Mon 8:40 | A private GitHub repository. |
| 3 | Mon 9:15 | A strong model in the coordinator's chair; free models for the volume. |
| 4 | Mon 9:20 | Contract and tests first; 409 on duplicates; optional expiry. |
| 5 | Mon 9:40 | Approve the tests as the contract; add the expired-link test. |
| 6 | Mon 10:10 | Docker on the intranet server; credentials stay with you. |
| 7 | Mon 11:05 | The tests are yours; a task meant to write one declares it in `files`. |
| 8 | Mon 11:30 | Truncate long URLs; approve the screenshot baseline. |
| 9 | Mon 11:50 | Only http and https targets, test first. |
| 10 | Mon 12:10 | No unrequested dependencies; Dependabot and dependency review. |
| 11 | Mon 13:30 | Merge v1 after reading the description, tests and one diff. |
| 12 | Wed 16:00 | The export is safe to show a free worker; unblock the import. |

## Appendix C: the referees, and what each one caught

| Referee | What it decides | In this story |
|---|---|---|
| Acceptance tests, written first | Does each piece do what you approved? | The contract every worker built against |
| A task's `verify` command | Is this task done? | Sent cli back for a fix round |
| Read-only files (`readonly:`) | Can a worker change the check? | Put back the edited 409 test before verify ran |
| The project check (`verify:`) | Does it still work all together? | Ran the full suite once the run landed; the cheat never had |
| Declared-files-only merges | What a worker may change | Dropped the undeclared contract change, kept as a patch |
| `tsc` and ESLint | Types and obvious mistakes | Quiet guards on every task |
| Playwright and screenshots | Does the page work, and look right? | The overflowing table, then a baseline |
| Semgrep, gitleaks | Known security patterns, leaked secrets | Clean, and blind to the `javascript:` link |
| `npm view`, Dependabot, dependency review | Who is this package? | The three-week-old table package |
| CI (GitHub Actions) | All of the above, on every push | The red start, the green finish |
| **You** | The questions no tool asks | `javascript:` links, the look, what ships |

## Appendix D: what's real and what's story

- **Real, as printed today:** setup's output, the read-only default in a new
  project's config, the put-back and fix-round lines, the `fa status` notes,
  `fa doctor`, `fa dispatch
  --detach` and its job messages, the herdr pane and its sidebar state and
  notification, `fa status` with `(verified)` and `WAITING`, `fa jobs --news`,
  the fix-round and rate-limit lines, worktree isolation, declared-files-only
  merges, blocked tasks, the journal replay that runs only the unblocked task,
  and `fa findings --note` / `--issue --post`.
- **Story:** Linkbox itself, every conversation, the timings, the specific
  models in `fa status`, and every mistake. The mistakes are typical (a test
  edited to pass, an invented dependency, a missing security check), but these
  particular ones are made up.
- **Built after the first draft of this story:** read-only files and the
  report of undeclared changes (Chapters 8 and 9) - the first draft's version
  of that scene had the edited test slip through to the review; the project
  check (Chapter 9), which the first draft had you run by hand; and push mode,
  which Linkbox does not use: its runs land in the working tree, as in the
  default `mode: strict`. With `mode: push` each run would arrive as a pull
  request instead, with CI's failures sent back to a worker before you look.
