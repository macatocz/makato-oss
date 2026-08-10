# Changelog — makato-contribute

Changes are grouped by skill/agent/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## Plugin-level

- **Removed** the `manage-pr` skill — its behaviour is fully covered by `makato-build:build-address-pr-comments` (superset: human + bot comments, CI failures, `--autonomous` mode). Dropped the `contribute-pr` skill bundle; retargeted the `review-pr` / `resolve-change-review` / `triage-pr-comments` / `address-pr-comments` archetypes in `makato-plan/config/task-skill-map.json` to `build-address-pr-comments`; updated the plugin description to drop "resolve PR review feedback".
- **Added** `config/skill-bundles.yml` (#145) — bundles `contribute-skills`, `contribute-plugin-creation` route plugin.json/marketplace files to the makato-plugin-creator/makato-skill-creator skills.

---

## harness-audit skill

**1.0.0**
- Relocated `harness-audit-smoke-tests.sh` into `scripts/tests/` (matching the makato-orchestrate convention) and wired it into `.github/workflows/validate.yml` — the suite previously ran in no workflow. Updated the AGENTS.md File Structure tree. Move-safe resolver (`git rev-parse`) unchanged; no test-logic change.
- Updated two source-comment references in `scripts/harness-audit.sh` (`lesson-prune.sh` → `lesson_prune.py`) to track the makato-orchestrate Python port. Comments only — no behaviour change.
- Added `skills/harness-audit/SKILL.md` — operator-gated audit skill that scans all `plugins/*/AGENTS.md` for line-count bloat (threshold: >150 lines) and sections lacking a `#NNN` or `specs/` cross-reference; classifies sections as `KEEP`, `BLOAT`, `REDUNDANT`, or `MOVE-TO-SKILL`. Also scans all `plugins/*/agents/*.md` frontmatter for `permissionMode`/`disallowedTools` inconsistencies, classifying each agent as `OK`, `MISSING_PM`, or `READ_WRITE_MISMATCH`. Human-gated (`[y/N]` approval before any report is expanded); `--non-interactive` flag exits 0 safely. Never mutates files.
- Added `scripts/harness-audit.sh` — pure classification helper (no mutation, stdout-only); accepts optional `REPO_ROOT` argument; emits one JSON finding per stdout line.
- Added `scripts/harness-audit-smoke-tests.sh` — 8 scenarios covering KEEP/BLOAT/OK/MISSING_PM/READ_WRITE_MISMATCH, known write-capable whitelist, `--non-interactive` flag, and empty-plugins-dir no-op.
- Routing decision: `harness-audit` is an interactive/meta skill (operator-gated, human-in-the-loop, never dispatched headlessly). Per `routing-registration.md`, neither glob-bundle nor task-archetype-map registration applies — interactive/meta skills are intentionally skipped on both routing paths. `config/skill-bundles.yml` is unchanged.

---

## `makato-plugin-creator` skill

- **2.2.1**
  - update `agents-template.md` skill-authoring rules to document the `shared/` symlink pattern for new plugins
- **2.0.0** (`[0.3.0]` — 2026-05-12)
  - interview-driven plugin creation with Plan→Present→Build workflow (replaces former `scaffold-plugin` skill)

## `makato-skill-creator` skill

- **1.3.0**
  - Declares `allowed-tools` in its own frontmatter (`Read Write Glob Bash(./scripts/*) Bash(./plugins/*/pre-commit/*) Bash(python3 *) Bash(cp *) Bash(open *) Bash(xdg-open *)`) — the skill runs validation scripts, a JSON parse check, `cp`, and a browser-open in its Build/Present phases, so under the D4 rule it now itself instructs, it must pre-approve those tools. Granular Bash globs (not bare `Bash`) keep the grant minimal.
  - Step 12 now registers a technical skill on **both** routing paths instead of one. Split into **12a** (glob bundle) and **12b** (task-archetype map). 12a fixes the prior default of appending only to the self-referential `<prefix>-skills` bundle (glob `plugins/<plugin>/skills/**/*.md`), which fires only when editing the makato plugin's own skill files and leaves the skill unroutable for real user-code work (the same reason makato-core skills route only during self-dev) — it now requires a **domain** bundle whose glob matches user-authored source files (append to an existing domain bundle like `langgraph`/`database-orm`/`fastapi` when present). 12b adds the fully-qualified `<plugin>:<skill-id>` entry to `plugins/makato-plan/config/task-skill-map.json` so `decompose` recommends the skill for green-field tasks. Interactive/meta skills are still skipped on both paths.
  - Step 9 (Create SKILL.md) now instructs authoring for skill-judge quality: declare `allowed-tools` when a step runs Bash (D4), use `AskUserQuestion` for choice-gathering instead of prose (D2), keep anti-patterns inline not in a trailing NEVER list (D3), and keep only knowledge-delta content in SKILL.md (D1). Reconciles the prior contradiction where `skill-authoring-rules.md` endorsed prose "ask the user" phrasing that skill-judge penalises.
  - Adds `references/routing-registration.md` (two-path model, domain-vs-self-dev bundle distinction, task-map schema). Step 14 gains a `task-skill-map.json` parse/registration check; Step 6 HTML plan section 7 and Step 16 summary now cover both routing paths. `skill-bundles-rules.md` reworded so it no longer implies task-skill-map is an unrelated lane.
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
