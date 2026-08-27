# Project Rules

Read `AGENTS.md` — it is the single source of truth. Follow its mode decision
(direct vs plan-first vs orchestrate) exactly. For orchestrate mode, the
`agent-coordinator` skill (in `.opencode/skills/agent-coordinator/`, loadable
directly at that path if your runtime has no skill loader) is the extended
playbook; if absent, follow the inline steps in AGENTS.md.