<!-- markdownlint-disable MD013 -->
# Changelog — makato-core

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## `create-issue` skill

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
