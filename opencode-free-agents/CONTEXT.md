# opencode-free-agents — Project Context

## Session resume (last session: 2026-08-26)

**What was being done:** Production audit — hardening all scripts to production quality.

**Where we left off:**
- All 14 production audit issues fixed and E2E tested on Debian server
- 7/7 bash scripts pass `bash -n` syntax check
- classify-error.sh --self-test: 13/13 passed
- refresh.sh --self-test: PASSED
- refresh.sh --force: discovered 29 free models, 5 categories
- oc.sh "Reply OK" (general): OK via opencode/mimo-v2.5-free (4.1s)
- oc.sh -c coding "Reply OK": OK via openrouter/poolside/laguna-s-2.1:free
- models.json updated correctly after success (status=ok, successCount=1)
- EXIT trap cleans up temp files + lock files — verified clean
- Working tree has uncommitted changes (production audit fixes)
- **Deferred**: PowerShell validation on Windows (user will open in opencode on Windows)

**Immediate next step — resume here:**
Open project on Windows with opencode. Have it audit the .ps1 changes:
- oc.ps1 shell injection fix (Start-Oc now takes string[] argList)
- oc.ps1 PS5.1 ?? syntax replacement
- refresh.ps1 manual-overrides.txt support
- refresh.ps1 PS5.1 ?? syntax replacement

---

## What this is

A **portable, cross-platform opencode CLI skill** that enables any AI agent to run
opencode headlessly with automatic free-model fallback chains, session continuity,
token balance checking, and a self-maintaining list of working models.

Designed to be portable across projects and agent platforms (kilo, pi, hermes),
with both **Windows (PowerShell)** and **Linux (Bash)** ports.

---

## Key architectural decisions

- **auth.json** (`~/.local/share/opencode/auth.json`) is **opencode's own file**, never edited by this skill
- **.env** is the **only** file users maintain — universal format, git-ignored
- `bootstrap.sh` / `bootstrap.ps1` are one-way bridges: `.env` → merges into opencode's store
- No secrets anywhere in the repo (`.env.example` has empty placeholders only)
- Generated data (`data/models.json`, `data/rankings.json`) ships pre-warmed so new machines start smarter
- `opencode/big-pickle` excluded from chains (host agent's own model — avoid self-hijacking)
- `openrouter/nvidia/nemotron-3.5-content-safety:free` excluded (classifier, not task model)
- **No probing** — model discovery uses `opencode models --verbose` metadata (~2-3s), not live probes (~5min)
- **manual-overrides.txt** — users can declare free models not marked free in metadata
- **File locking** — flock (bash) prevents concurrent models.json corruption
- **EXIT trap** — temp files and lock files cleaned up on exit

---

## Verified behaviors (do not re-test unless refactoring)

- Cross-model session continuity: `opencode run -s <id> -m <other>` carries history ✅
- `openrouter/openrouter/free` works as last-resort auto-router ✅
- Error taxonomy: `temporarily rate-limited upstream` → rate_limited; `Unauthorized: Insufficient balance` → no_credits; `UnknownError` JSON → dead
- Exit codes: 0 success, 1 failure (but WinExitCode via Start-Process unreliable on PS 5.1 — judge success by response content)
- PS 5.1 quirk: `[pscustomobject]@{ x = @(genericList) }` throws "Argument types do not match" — use `[object[]]$list.ToArray()`
- PS 5.1 quirk: `$PID` is a reserved automatic variable — never use as loop variable name
- PS 5.1 quirk: `[ordered]@{}` has `.Contains()` but no `.ContainsKey()`
- `.env` resolution cascade: `$PWD/.env` → `<skill>/.env` → `$HOME/.config/opencode-free-agents/.env` → continue with existing auth.json
- classify-error.sh --self-test: 13/13 test cases pass ✅
- refresh.sh --self-test: validates JSON parsing in temp sandbox ✅
- refresh.sh --force on Debian: 29 free models, 5 categories, ~3s ✅
- oc.sh on Debian: fallback chain works, EXIT trap cleans up ✅

---

## Dependencies

| Platform | Requirements |
|---|---|
| **Windows native** | PowerShell 5.1+ (built-in), `opencode` via choco/scoop/npm |
| **Linux / Debian** | bash, jq, curl (`sudo apt install -y bash jq curl`) |

---

## File map (inside opencode-free-agents/)

```
SKILL.md                       opencode skill frontmatter + instructions
README.md                      porting guide + Linux/server quickstart
GETTING-STARTED.md             full setup runbook (new machine, from scratch)
CONTEXT.md                     this file — session continuity
.env.example                   credential template (generic PROVIDER_N blocks)

scripts/
  oc.ps1 / oc.sh               THE entry points (Windows / Linux)
  install.sh                   one-shot setup: deps + opencode + keys + skill install
  bootstrap.ps1 / bootstrap.sh .env -> auth.json bridge (Windows / Linux)
  refresh.ps1 / .sh            balance + discover models + rebuild rankings
  classify-error.sh            shared error classification (rate_limited, no_credits, etc.)
  get-balance.ps1 / .sh        provider credit/quota status (cached)
  find-free-providers.sh       discover new free providers via models.dev
  config.json                  intervals, timeouts, retry windows
  rankings-seed.json           curated initial per-category order

data/
  models.json                  free model metadata (discovered from opencode models --verbose)
  rankings.json                generated category chains
  balance-cache.json           cached provider balance (git-ignored)
  manual-overrides.txt         user manual free-model entries
```

---

## Git status

- Repo path: `C:\Projects\RCSoft\OpenCode-Headless-AI-Agents-Delegation-With-Free-Models-Skill\opencode-free-agents\`
- Branch: `master`
- 6 commits (previous session), plus uncommitted changes from production audit
- Working tree: **dirty** (production audit fixes not yet committed)
- `.gitignore`: `.env`, `.env.local`, `data/balance-cache.json`, `*.tmp`, `*.lock`, `data/.discovered.*.tsv`, `data/.filtered.*.tsv`, `data/.models.jsonl.*.tmp`
- Secret audit: clean (no real keys found)
- Remote: none configured yet (deferred until tests pass)

---

## What's working (tested)

| Feature | Status |
|---|---|
| bootstrap.ps1 self-test (sandbox, fake keys, alias + generic + duplicate) | ✅ PASS |
| bootstrap.sh self-test (sandbox, same coverage) | ✅ PASS — also verified on Debian server |
| classify-error.sh --self-test (13 test cases, all 5 error categories) | ✅ PASS — 13/13 |
| refresh.sh --self-test (JSON parsing validation in sandbox) | ✅ PASS |
| All 7 bash scripts pass `bash -n` syntax check | ✅ |
| Windows E2E: oc.ps1 fallback chain + cross-model continuation | ✅ PASS |
| find-free-providers.sh (discovered NVIDIA 98 free models, Kilo 24, GitLab 23...) | ✅ |
| Debian E2E: refresh.sh --force discovered 29 free models from metadata | ✅ PASS |
| Debian E2E: oc.sh general category — OK via mimo-v2.5-free (4.1s) | ✅ PASS |
| Debian E2E: oc.sh coding category — OK via poolside/laguna-s-2.1:free | ✅ PASS |
| models.json updated correctly after success | ✅ PASS |
| EXIT trap cleans up temp files + lock files | ✅ PASS |

---

## Bugs found and fixed during development

1. **`$val` not reassigned in second loop** of bootstrap.ps1 (and bootstrap.sh) — generic KEY entries all got the last alias key value. Fixed by adding `$val = $entries[$key]` at top of second loop.
2. **`$pid` is reserved** in PowerShell — renamed to `$providerId`.
3. **`[ordered]@{}` has no `.ContainsKey()`** — changed to `.Contains()`.
4. **`Set-Acl` per Merge-Key call** locks file before next read — moved ACL to end of main flow only.
5. **Self-test recursion via `$PSCommandPath`** hits real auth.json — replaced with inline merge logic.
6. **`${#CHAIN[@]:-0}` invalid syntax** in oc.sh:116 — `${#array[@]}` returns integer, can't apply `:-`. Fixed to `${#CHAIN[@]}`.
7. **Excluded models not filtered from seed** in refresh.sh and refresh.ps1 — `big-pickle` appeared in every category despite being in `excluded.models`. Fixed by adding excluded check inside seed loop.
8. **oc.sh file lock replaced temp file creation** — `outF/errF="$(mktemp)"` was deleted by the file lock edit. Fixed: lock moved before for-loop, temp files restored inside loop body.
9. **refresh.sh self-test logic bug** — `[[ $SELF_TEST -eq 0 ]] && command -v opencode || error` had wrong operator precedence; self-test always errored. Fixed to explicit `if` block.
10. **oc.ps1 shell injection** — `Start-Oc` took a pre-quoted string and passed it to cmd.exe, allowing argument injection. Fixed: now takes `[string[]]$argList` (array), builds safe command line per-argument.
11. **refresh.ps1 PS5.1 ?? syntax** — `$rec.context ?? 0` fails on PowerShell 5.1. Fixed to `if ($null -ne $rec.context) { ... } else { 0 }`.

---

## Production audit results (2026-08-26)

All 14 items from the production audit are resolved:

| # | Issue | Fix |
|---|---|---|
| 1 | oc.sh broken temp files + misplaced file lock | Moved lock before for-loop, restored mktemp inside loop |
| 2 | oc.sh EXIT trap missing lock cleanup | Added `$LOCK_FILE` to trap, initialized `LOCK_FILE=""` |
| 3 | refresh.ps1 no manual-overrides.txt | Added overrides merge (reads file, checks key, appends) |
| 4 | refresh.ps1 PS5.1 ?? syntax | Replaced with if/else |
| 5 | oc.ps1 shell injection | Start-Oc now takes string[] argList, builds safe cmd line |
| 6 | oc.ps1 PS5.1 ?? syntax | Replaced with if/else |
| 7 | oc.ps1 stale "probes" comment | Changed to "metadata queries" |
| 8 | oc.ps1 "first run may take several minutes" | Changed to "~2-3 seconds" |
| 9 | get-balance.sh stat -c %Y portability | Added `|| stat -f %m` fallback for macOS |
| 10 | .gitignore missing temp patterns | Added `*.tmp`, `*.lock`, `data/.discovered.*.tsv`, etc. |
| 11 | classify-error.sh no unit tests | Added `--self-test` with 13 test cases |
| 12 | refresh.sh self-test requires opencode | Fixed if-block to bypass opencode check in self-test mode |
| 13 | refresh.sh self-test logic precedence bug | Changed `[[ ... ]] && ... || ...` to explicit `if` |
| 14 | Error classification regex unification | classify-error.sh shared by oc.sh; oc.ps1 has inline patterns (same regex) |

---

## What's pending / next steps

1. **PowerShell validation on Windows** — open project in opencode on Windows, audit .ps1 changes
2. **Git commit** — commit all production audit changes
3. **Create private GitHub repo** and push:
   ```
   gh repo create opencode-free-agents --private
   git remote add origin git@github.com:<YOU>/opencode-free-agents.git && git push -u origin master
   ```
4. **Optional**: rename branch to `main` (`git branch -m main`)

---

## Provider catalog notes

- **models.dev** catalog shape: `{providerId: {id, env: [VAR_NAMES], api, name, models: {modelId: {cost: {input, output}, limit: {context}}}}}`
- **freemodel** is in catalog; all freemodel models show `no_credits` (user's account drained)
- **Kilo Gateway** is in catalog (366 models, `@ai-sdk/openai-compatible`, endpoint `https://api.kilo.ai/api/gateway`). 29 free tier models. No public balance endpoint → probe-only.
- **`openrouter/stealth/ox-alpha`** discovered automatically — user's "unlimited" model, free in metadata
- **Zen** free models work without any API key (no `opencode` entry in auth.json yet zen models respond)
- **Debian server discovered 29 free models** from metadata (opencode zen + openrouter :free models)

---

## User preferences (lock in)

- Fully generic `.env` support (any provider via `PROVIDER_N_ID/_KEY/_TYPE` blocks)
- Discovery of new free providers is desired
- Private git repo for distribution (user approved)
- Both bootstrap.ps1 and GETTING-STARTED.md added (user approved)
- Windows native support (not WSL-only) is important
- .env is the user's file; auth.json is opencode's internal file — user never touches auth.json
- API key prompts are optional — user might only have one key
- install.sh is the single entry point — handles deps, opencode, keys, and skill install in one shot
- **Skip Scenario 0** (uninstall opencode) — not worth the hassle, error paths proven by code
- **Debian server has no provider keys** — only zen free models; test oc.sh with zen-only first
