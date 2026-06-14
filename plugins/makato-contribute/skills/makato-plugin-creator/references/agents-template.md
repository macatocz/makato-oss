# AGENTS.md Template

Generate the following, filling ALL sections from interview data.
Do not leave placeholders — every section must be concrete and specific to this plugin.

```markdown
# <plugin-name> — Contributor Guide

## Goal

<goal-statement>

**How:** <how-sentence from interview>

**Why:** <why-sentence from interview>

## What Belongs Here

<2-5 bullet points from interview — what this plugin admits>

## What Does NOT Belong Here

<2-5 bullet points from interview — what this plugin rejects>

## Decision Test

"<custom decision test phrasing from interview>"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version

## File Structure

<generate actual tree for this plugin, include .mcp.json if declared>

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(<plugin-name>): description`
```

Rules:
- Must remain under 200 lines (CI enforced)
- The template above is ~45 lines — leave room for plugin-specific additions
- The decision test must reference the goal statement directly
- "What Belongs" bullets must be concrete (not "relevant things")
