# Changelog — makato-contribute

Changes are grouped by skill/agent/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## Plugin-level

- **Removed** the `manage-pr` skill — its behaviour is fully covered by `makato-build:build-address-pr-comments` (superset: human + bot comments, CI failures, `--autonomous` mode). Dropped the `contribute-pr` skill bundle; retargeted the `review-pr` / `resolve-change-review` / `triage-pr-comments` / `address-pr-comments` archetypes in `makato-plan/config/task-skill-map.json` to `build-address-pr-comments`; updated the plugin description to drop "resolve PR review feedback".
- **Added** `config/skill-bundles.yml` (#145) — bundles `contribute-skills`, `contribute-plugin-creation` route plugin.json/marketplace files to the makato-plugin-creator/makato-skill-creator skills.

---

## `makato-plugin-creator` skill

- **2.2.1**
  - update `agents-template.md` skill-authoring rules to document the `shared/` symlink pattern for new plugins
- **2.0.0** (`[0.3.0]` — 2026-05-12)
  - interview-driven plugin creation with Plan→Present→Build workflow (replaces former `scaffold-plugin` skill)

## `makato-skill-creator` skill

- **1.2.0**
  - Build phase now conditionally registers the new skill in the plugin's `config/skill-bundles.yml` (new Step 12) — **only for technical/routable skills** (a skill a programmatically-dispatched agent can act on headless), applying a one-minute decision gate; interactive/meta skills (interview, scaffolding, orchestration, PR-triage) are intentionally skipped. Registration appends to the `<prefix>-skills` bundle or creates the registry from a template when absent. Adds `references/skill-bundles-rules.md` (schema + technical-vs-interactive criterion), `templates/skill-bundles.yml`, a Present-phase "Skill-Bundle Registration" section, and a `validate-skill-bundles.sh` validation step. Downstream steps renumbered (Validate → 14, Persist → 15, Summary → 16).
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
