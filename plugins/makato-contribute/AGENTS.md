# makato-contribute — Contributor Guide

## Goal

Help contributors participate in makato suite development while keeping all content within the framework's guardrails.

**How:** Provide skills and agents (shipped as a plugin) that create new plugins, skills, agents, and hooks — all pre-validated against suite conventions.

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
│   ├── makato-plugin-creator/
│   │   ├── SKILL.md
│   │   └── references/
│   └── makato-skill-creator/
│       ├── SKILL.md
│       └── references/
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
