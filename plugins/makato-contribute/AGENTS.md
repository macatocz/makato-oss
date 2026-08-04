# makato-contribute — Contributor Guide

## Hard Constraints

- **Skills produced by this plugin must validate output against makato conventions before writing.** Never scaffold a plugin or skill without running the framework guardrails (frontmatter checks, file-structure checks, AGENTS.md presence).
- **Never add end-user workflow skills or domain-specific skills here.** This plugin exists solely to help contributors create correct suite content.
- **Do not add foundation/contract definitions.** Those belong in `makato-core`.
- **All scaffolded output must include required frontmatter** (`name`, `description`, `version`) — creator skills must reject stubs missing these fields.
- **Plugin scaffolds must include `AGENTS.md` with a `## Hard Constraints` section before line 30.** This is enforced by the pre-commit gate; generated files must comply on creation.
- **`sync-from-upstream` must apply naming remaps before writing any file.** Raw upstream content must never land in the repo without makato-convention validation.
- **Never create duplicate plugin or skill directories.** Creator skills must check for existing paths and halt on conflict.
- **Never auto-push scaffolded content** without an explicit user approval gate — the human reviews and merges.
- **No `bypassPermissions` agents in this plugin.** All scaffolding runs at the default permission level.

## Goal

Help contributors participate in makato suite development — scaffolding new plugins and skills to convention, resolving PR review feedback, and syncing content from upstream repos — all pre-validated against the framework's guardrails.

**How:** Provide skills and agents (shipped as a plugin) that create new plugins, skills, agents, and hooks, triage post-PR review comments, and migrate content from upstream sources — all pre-validated against suite conventions.

**Why:** Active participation in the framework should be easy and encouraged, but every contribution must fit together coherently. These tools encode the guardrails so contributors don't have to memorize them.

## What Belongs Here

- Skills that create or scaffold plugins, skills, agents, or hooks
- Validation helpers for contributors
- Tools that teach or enforce makato conventions

## What Does NOT Belong Here

- End-user workflow skills (those belong in toolkits)
- Foundation/contract definitions (those belong in core)
- Anything not directly helping contributors create correct plugins

## Decision Test

"Does this help a contributor produce correct, goal-aligned content for the makato suite?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. Cross-skill resources are exposed via a `shared/` symlink at the skill root that points to a `shared/` directory at the plugin root (see Claude Code's [marketplace symlink docs](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks)).
- References loaded at point of use, not front-loaded
- Templates produce output matching makato conventions

## File Structure

```
makato-contribute/
├── .claude-plugin/plugin.json
├── skills/
│   ├── harness-audit/            # Operator-gated audit: AGENTS.md bloat + permissionMode mismatches
│   │   └── SKILL.md
│   ├── makato-plugin-creator/    # Scaffold a new plugin from interview
│   │   ├── SKILL.md
│   │   └── references/
│   ├── makato-skill-creator/     # Scaffold a new skill inside an existing plugin
│   │   ├── SKILL.md
│   │   └── references/
│   └── sync-from-upstream/       # Migrate content from an upstream impact-market repo into makato
│       ├── SKILL.md
│       └── references/
├── scripts/
│   ├── harness-audit.sh          # Pure classifier: AGENTS.md sections + agent frontmatter (no mutation)
│   └── harness-audit-smoke-tests.sh  # 8 scenarios T1–T8
├── shared/             # Cross-skill references (optional)
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Helps contributors produce correct plugins
- [ ] Generated output matches current makato conventions
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-contribute): description`
