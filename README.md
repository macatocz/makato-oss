# makato
Development AI Suite

## Contributor onboarding

This repo is a monorepo of Claude Code plugins. Each plugin under `plugins/` owns its own
`AGENTS.md` with the rules that govern that plugin's surface. Before editing files under
`plugins/<name>/`, read that plugin's `AGENTS.md` first.

A repo-root **routing index** is generated on demand from each plugin's `AGENTS.md`. It lives at
the repo root as `AGENTS.md` / `CLAUDE.md` and is intentionally **gitignored** — the file is a
per-checkout local artefact, not part of the plugin distribution.

```bash
./scripts/regenerate-agents.sh
```

Run after adding or removing a plugin. The output is idempotent — re-running produces
byte-identical content unless a plugin's `AGENTS.md` or `plugin.json` description changed.

To have it run on every Claude Code SessionStart, add a hook to your own
`.claude/settings.local.json` (gitignored, so it is your personal preference and does not impose
on other contributors):

```jsonc
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command",
                  "command": "${CLAUDE_PROJECT_DIR}/scripts/regenerate-agents.sh"}]}
    ]
  }
}
```
