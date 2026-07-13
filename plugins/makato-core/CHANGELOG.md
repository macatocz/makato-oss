<!-- markdownlint-disable MD013 -->
# Changelog — makato-core

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## Plugin-level

- **Changed** extracted the documentation-authoring skills (`context7`, `crafting-effective-readmes`, `markdown`, `writing-clearly-and-concisely`) into the new sibling `makato-doc` plugin via `git mv`. makato-core now scopes to suite infrastructure (`create-issue`, `makato-guide`, `zoom-out`). `config/skill-bundles.yml` trimmed: `core-skills` keeps only the three retained skills; `core-readme` and `core-markdown` removed (relocated to makato-doc as `doc-readme` / `doc-markdown`). plugin.json description, AGENTS.md, and README.md updated.
- **Added** `config/skill-bundles.yml` (#145) — bundles `core-skills`, `core-readme`, `core-markdown`, `core-governance` route README files, markdown files with lint markers, AGENTS/CLAUDE governance files, and core skill files to the documentation and navigation skills.

---

## `hooks/` directory — shared Claude Code hooks

- **Added** `hooks/pre-commit-sensors.md` — PreToolUse gate blocking `git commit` on sensor failure
- **Added** `hooks/pre-push.md` — PreToolUse blocking gate for `git push` + Stop advisory
- **Added** `hooks/post-implement.md` — Stop hook auto-continuing to `/build-simplify`
- AGENTS.md updated: `hooks/` added to What Belongs Here and File Structure

---

## `create-issue` skill

- **1.1.0**
  - Fully autonomous — repo and project name resolved from `.claude/config.json` (fallback: `sagibeast`); removed all human confirmation gates. `TARGET_REPO` derived from git remote; `PROJECT_NAME` read silently from `<REPO_ROOT>/.claude/config.json`.
- **1.0.0**
  - Initial — file structured issues against the makato repo with `[plugin-name]` title prefix, body assembled from `.github/ISSUE_TEMPLATE/`, and auto-resolved type + plugin labels. AI-agent path so backlogs stay consistent without manual triage.

## `makato-guide` skill

- **Initial** (`[0.2.0]` — 2026-05-11) — discover plugins, list skills, find the right tool

## Plugin-level

- **0.2.0** — 2026-05-11
  - Prerequisites / MCP Servers section updated — makato-core uses gh CLI, no MCP servers
- **0.1.0** — 2026-05-11
  - initial plugin scaffold, plugin manifest (`plugin.json`)
  - contracts directory (empty, schemas added with first toolkit)
