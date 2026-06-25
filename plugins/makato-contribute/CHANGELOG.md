# Changelog — makato-contribute

Changes are grouped by skill/agent/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## `manage-pr` skill

- **1.1.0**
  - (no detail recorded — see git history)
- **1.0.0**
  - Initial — post-PR-creation review-bot triage: validates each bot comment against the actual code, rates severity/quality, waits for approval, applies fixes, posts gh CLI replies, and resolves threads via GraphQL `resolveReviewThread`; supports enterprise hosts like github.tools.sap

## `makato-plugin-creator` skill

- **2.2.1**
  - update `agents-template.md` skill-authoring rules to document the `shared/` symlink pattern for new plugins
- **2.0.0** (`[0.3.0]` — 2026-05-12)
  - interview-driven plugin creation with Plan→Present→Build workflow (replaces former `scaffold-plugin` skill)

## `makato-skill-creator` skill

- **1.1.2**
  - sagibeast-alignment audit (content-integrity restore): Step 12 was truncated mid-sentence and Step 13 (Validate) was missing — both restored from git history (commit fb09341). No behavioral change beyond the original Step 13 contract.
- **1.1.1**
  - update `self-containment-rules.md` to document the `shared/` symlink pattern (symlinks resolving within the plugin are preserved by the plugin cache)
  - add "Constraint Placement" section to `skill-authoring-rules.md` reference (prohibits end-of-file NEVER sections, Composes With, and pipeline diagrams)
- **1.0.0** (`[0.2.0]` — 2026-05-11)
  - Initial — creates complete, working skills in existing plugins

## `scaffold-plugin` skill (removed)

- **Removed** (`[0.3.0]` — 2026-05-12) — replaced by `makato-plugin-creator`
- **1.1.0** (`[0.2.0]` — 2026-05-11)
  - added `.mcp.json` as optional plugin file in generated structure
- **1.0.0** (`[0.1.0]` — 2026-05-11)
  - Initial — generates new plugins with correct structure

## Plugin-level

- **0.1.0** — 2026-05-11
  - initial plugin scaffold, plugin manifest (`plugin.json`)
  - AGENTS.md skill-authoring rules — replace `../shared/` exception with within-plugin `shared/` symlink pattern (Claude Code preserves symlinks resolving inside the plugin's own directory)
