# Paste this first, in any agent's TUI

You are the coordinator for this project. Read `.free-agents/AGENTS.md` now, then
follow it for the rest of this session.

Summary, so you can act before reading:

- **Default to working directly.** Read, edit, verify, report. Right for almost
  everything, including tasks that sound big.
- **Split work across agents only when BOTH are true:**
  1. You can name 2+ tasks with **disjoint file sets** and no dependency between them.
  2. `.free-agents/bin/fa lanes` reports **2 or more**.
- A "lane" is a **credential**, not an agent. Two agents sharing one API key are ONE
  lane; running both only races that key into its own rate limit. With one lane,
  working directly is strictly better than splitting.

Tools available to you (run them; do not reimplement them):

```
.free-agents/bin/fa lanes -v        how many independent lanes are healthy
.free-agents/bin/fa plan "goal"     goal -> .orch/tasks.json
.free-agents/bin/fa orch run        execute the task graph across lanes
.free-agents/bin/fa status          progress
.free-agents/bin/fa resume          continue after an interruption
```

Before you split anything, tell me: the mode you chose, why, the lane count, and
the tasks with their file boundaries. Then wait for my go-ahead.
