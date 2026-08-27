# opencode-free-agents (portable)

Headless opencode delegation for AI agents, with an automatically maintained
list of working free models and best-in-class fallback behavior.

## Install into a project (opencode)

Windows (PowerShell):
```powershell
New-Item -ItemType Junction -Path "<project>\.opencode\skills\opencode-free-agents" -Target "<path-to>\opencode-free-agents"
```

Linux / macOS / Debian server (step zero for any project):
```bash
sudo apt install -y jq curl
bash opencode-free-agents/scripts/install.sh /path/to/project
# then fill in credentials:
cp .env.example .env && nano .env      # at the PROJECT ROOT, gitignored
bash <project>/.opencode/skills/opencode-free-agents/scripts/bootstrap.sh   # or re-run install.sh
```

### How credentials flow

```
.env (you maintain; universal format, git-ignored)
  └── bootstrap.sh merges ──> ~/.local/share/opencode/auth.json (opencode's own store)
                                   └── opencode uses it exactly like /connect did
```

- `auth.json` belongs to **opencode**, not this skill. You never edit it.
- No `.env` found? Bootstrap continues with whatever credentials already exist.
- Generic blocks support ANY models.dev provider: `PROVIDER_1_ID/_KEY/_TYPE`.
- Self-test without touching real files: `bootstrap.sh --self-test`
- Find new free providers to add: `scripts/find-free-providers.sh`

## Porting to other agent platforms (kilo, pi, hermes, ...)

The `scripts/` folder is agent-agnostic: it only wraps the `opencode` CLI.
For another platform, copy the whole folder there and write that platform's
equivalent of SKILL.md pointing at `scripts/oc.sh` / `scripts/oc.ps1` with its
own frontmatter and trigger description. Keep one shared data/ directory per
machine if you want all agents to share the same model-status knowledge.

## Requirements

- Windows: PowerShell 5.1+ | Linux: bash + jq + curl (stock apt packages)
- `opencode` on PATH with credentials via .env/bootstrap or `/connect`
- First run discovers free models from metadata (~2-3 seconds); later runs are incremental
- `classify-error.sh --self-test` validates error classification (13 test cases)

## Design guarantees

1. An agent only fails when literally every candidate free model is dead,
   rate-limited everywhere, or every provider is out of credits (exit 2).
2. Sessions survive model switches (`opencode run -s <id> -m <other>`).
3. The model list is self-healing: runtime failures are recorded instantly,
   periodic metadata refreshes keep the list current, rankings adapt to observed reliability.
