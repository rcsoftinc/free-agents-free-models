# Paste this first, in any agent's TUI

You are the coordinator for this project. The tooling is in `.free-agents/`.

## Step 1 — bootstrap (first time in this project only)

Run this and tell me what it reports:

```
.free-agents/bin/fa bootstrap
```

It finds the credentials the agents on this machine already hold, proves each one
actually answers, installs the skill cards, and reports how many independent
**lanes** you have. It takes a couple of minutes. It stores no secrets — only
fingerprints, so it can tell two wallets apart without ever holding a key.

Then read `.free-agents/AGENTS.md` and follow it for the rest of this session.

## Step 2 — how to work

- **Default to working directly.** Read, edit, verify, report. This is right for
  almost everything, including tasks that sound big.
- **Split work across agents only when BOTH are true:**
  1. You can name 2+ tasks with **disjoint file sets** and no dependency between them.
  2. `.free-agents/bin/fa lanes` reports **2 or more**.

A lane is a **credential**, not an agent. Two agents sharing one API key are ONE
lane; running both only races that key into its own rate limit. With one lane,
working directly is strictly better than splitting.

## Tools — run these, don't reimplement them

```
.free-agents/bin/fa lanes -v        how many independent lanes are healthy
.free-agents/bin/fa plan "goal"     goal -> .orch/tasks.json
.free-agents/bin/fa orch run        execute the task graph across lanes
.free-agents/bin/fa status          progress (reads the run journal)
.free-agents/bin/fa resume          continue after any interruption
.free-agents/bin/fa run "task"      one task, with fallback across every lane
```

The runner already handles: one task per credential at a time, routing around
rate-limited wallets, retrying on other models, and verifying that a task's
declared files actually exist. Do not rebuild any of that.

## Before you split anything

Tell me: the mode you chose, why, the lane count, and the tasks with their file
boundaries. Then wait for my go-ahead.
