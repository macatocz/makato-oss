# makato-sagibeast — Contributor Guide

## Goal

Provide contract management skills for the Sagibeast (CMAI) platform.

**How:** Through structured prompts and workflows that guide contract creation, document sorting, reviewing contracts, lifecycle management, time evaluation, and financial claims evaluation within the CMAI platform.

**Why:** Reduces manual effort and errors in contract workflows by giving CMAI agents the skills to handle contracts end-to-end.

## What Belongs Here

- Drafting contracts and contract templates from structured inputs
- Summarizing contracts and generating manager-level briefings
- Evaluating financial claims, pricing, and cost items within contracts
- Analyzing facts (skutečnost) and critical paths in contract timelines
- Document extraction and recognition (OCR, PDF, Office documents) applied to contracts
- Citation and retrieval of contract knowledge from a vector database
- Price evaluation — querying price databases and validating typical market prices
- Sorting and classifying contract documents into structured categories

## What Does NOT Belong Here

- General-purpose UX creation or visual design skills
- Database schema definition or infrastructure provisioning
- Generic document editing tools with no contract-management context
- Skills that produce outputs not usable within a contract management workflow
- Skills already covered by other makato plugins (build, plan, change)

## Decision Test

"Does this skill help manage a contract lifecycle in the Sagibeast/CMAI platform?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version
- Skills using shared document utilities (OCR, PDF, Office) should reference `shared/`

## File Structure

```
plugins/makato-sagibeast/
├── .claude-plugin/
│   └── plugin.json
├── .mcp.json               ← placeholder for CMAI external system connections
├── shared/                 ← shared document utilities (OCR, PDF, Office)
├── skills/
│   └── (add skills here)
├── AGENTS.md
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: contract management for Sagibeast/CMAI
- [ ] Skills are self-contained (no `../` paths)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-sagibeast): description`
