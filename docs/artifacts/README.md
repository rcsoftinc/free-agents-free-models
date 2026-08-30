# Artifacts

Two published pages, kept here because the source otherwise lives only in a
session scratchpad and would be lost.

| File | Published at | What it is |
|---|---|---|
| `routemap.html` | [68bc7de1](https://claude.ai/code/artifact/68bc7de1-6a06-4242-86f0-957904c09e1f) | Every route the tool can take — the mechanism, all branches, all outcomes |
| `trace.html` | [727f0341](https://claude.ai/code/artifact/727f0341-8a96-4e91-99fd-47ec5cdb7076) | A real recorded run, plus the wide and starved runs compared |

Both are self-contained HTML: no scripts, no external assets beyond Google Fonts,
theme-aware. To update a published page, edit the file and republish it to the
**same URL** — publishing without the URL creates a separate artifact.

## Keep them honest

These pages make claims about a live system, so they go stale silently. Two
things in particular must be re-checked whenever the tool changes:

- **Lane counts and model names** come from a specific machine on a specific day.
- **The findings mechanism** (added 2026-08-30) and the change-detecting
  verification are described in both pages; if either changes, both need it.
- **The evidence sections** distinguish what has been *observed* from what is only
  *tested*. As of the last update: three real projects, 19 tasks, and **no real
  provider failure mid-build** — so the breaker, cooldown escalation and
  cross-wallet rerouting remain suite-verified only. If that changes, both pages
  need it, because both currently say so prominently.
