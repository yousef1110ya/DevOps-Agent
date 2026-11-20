# tools/settings/ — hook wiring examples

The three hooks in `tools/hooks/` enforce the operating rules. Wire them at four lifecycle points:

| Lifecycle point | Hook | Purpose |
|-----------------|------|---------|
| Session start | `tools/hooks/git-sync.sh pull` | Pull latest knowledge (no-op until a remote exists) |
| Before a shell/Bash tool call | `tools/hooks/guard.sh` | Block unsafe kubectl (exit 2 = deny) |
| After a shell/Bash tool call | `tools/hooks/logger.sh` | Record command (+output local, metadata shared) |
| Session stop | `tools/hooks/git-sync.sh push` | Commit + push (no-op until a remote exists) |

## Claude Code
Copy [`claude-code.settings.json`](claude-code.settings.json) to `.claude/settings.json` at the repo
root, then restart Claude Code (or run `/hooks`) to approve the hooks.

## Any other harness
Map the four points above to your harness's equivalent (pre-exec / post-exec / session-start /
session-stop). The hooks read the command from a hook-JSON payload on stdin (`.tool_input.command`)
**or** from raw stdin / `$*`, so they work regardless of payload shape. Export
`AGENT_PROJECT_DIR=<repo root>` so `git-sync.sh` can locate the repo.

## No hooks? Manual gate
```bash
echo 'kubectl --context prod delete pod foo' | bash tools/hooks/guard.sh && echo ALLOWED || echo BLOCKED
```

Requirements: `bash` + `jq` on PATH.
