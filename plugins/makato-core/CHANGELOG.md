<!-- markdownlint-disable MD013 -->
# Changelog — makato-core

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

## [Unreleased]

### Changed — default pipeline has no post-verify sensors artifact (#164)

- **`create-workflow-schema` v1.3.1** — guidance and the field-reference example place custom
  artifacts before `push-to-git`; `build-verify` Gate 0 is the only default sensor sweep.

### Fixed — durable project learning (port of #123 from `development`)

- **`init` skill v1.1.1** — onboarding now installs the project learning contract into the consumer’s agent
  instructions: read `.makato/memory/`, review learning before handoff, persist
  verified discoveries immediately, and distinguish an empty review from failure.

### Changed — CI recovery audit contract

- Documented `build-fix-ci` poll/repair boundaries and implementation recovery
  events. Full diagnostic logs remain private; public audit entries identify
  checks, head SHAs and sanitized outcomes.

### Fixed — Root structure validation

- Allow the tracked `.joule/` directory in the repository-root directory allowlist.

### Added — Workflow skill execution configuration

- The workflow-schema wizard and field reference preserve and document `skill_execution`
  independently of artifact configuration, including roles, effort, and project overrides.

- **Changed** `create-issue` Step 5.5 — `plan-tier:full` inference is now a
  *decomposition* signal, aligned with the CI classifier
  (`.github/scripts/classify-plan-tier.sh`). `full` fires on an epic-scale
  sizing label (`effort:xl` / `points:>=13`) OR an epic-intent keyword
  (`architecture`, `migration`, `breaking`, `multi-phase`, `epic`,
  `multiple stories`); everything else feature/docs defaults to `light`. The
  anti-pattern note is updated: a long, well-written description of a single
  story is `light`, not `full`.

- **Added** `init` skill (v1.0.0, #566) — guided 3-phase onboarding wizard that
  installs `makato-core`, authenticates the GitHub CLI, and writes
  `.claude/config.json` with a `project` key (Phase 1 mandatory); presents a
  numbered menu for optional setup of a Projects board, context bundles, Langfuse
  credentials, and tech plugins (Phase 2, type `skip` to bypass); and prints a
  validation summary table of every configured and skipped item (Phase 3).
  Accompanied by `references/tech-plugins-menu.md` (all 10 installable plugins)
  and `docs/onboarding.md` (full flow documentation).
- **Added** `create-workflow-schema` skill (v1.0.0, #563) — interactive wizard
  that generates `.claude/workflow-schema.yml` via a guided interview. Presents
  the built-in default pipeline, lets the user mark optional artifacts as required,
  add custom artifacts at specific positions, and validates the result with
  `workflow-schema-loader.sh` before confirming. See `docs/workflow-schema.md`
  for the schema format reference.
- **Added** `core-skill-judge` bundle in `config/skill-bundles.yml` (#430) — routes any edit to
  `plugins/**/skills/**/SKILL.md` to the `skill-judge` skill so authors get quality-scoring
  context while working on a skill file.

## map-codebase-context skill (formerly zoom-out)

- **1.5.0** (#397)
  - Renamed `zoom-out` → `map-codebase-context`. The old name read as a UI action rather than
    code comprehension. Skill directory, frontmatter `name`, H1 title, and all references
    (`skill-bundles.yml`, `task-skill-map.json` archetypes, READMEs, AGENTS.md) updated. The
    `"zoom out"` user trigger phrase is retained in the `description` for discoverability.
    Breaking: the slash command is now `/makato-core:map-codebase-context`.

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
