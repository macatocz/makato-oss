# makato-langgraph — Contributor Guide

## Goal

Provide LangGraph-specific reference skills and patterns for building Python AI agents with the LangGraph framework.

**How:** Delivers self-contained reference skills covering the LangGraph API, agent patterns, and advanced features (persistence, human-in-the-loop, reflexion).

**Why:** LangGraph skills are technology-specific and only relevant on projects using the framework — keeping them separate from `makato-build` lets that plugin stay technology-agnostic.

## What Belongs Here

- LangGraph API reference skills (StateGraph, nodes, edges, reducers, checkpointers)
- LangGraph agent pattern guides (ReAct, human-in-the-loop, reflexion, persistence)
- LangGraph-specific debugging or testing guidance
- Python-only LangGraph utilities and code patterns

## What Does NOT Belong Here

- General Python skills not specific to LangGraph
- Technology-agnostic build workflow steps (those stay in `makato-build`)
- Non-LangGraph AI framework patterns (LlamaIndex, CrewAI, AutoGen, etc.)
- Project management, planning, or shaping skills

## Decision Test

"Does this skill help a developer write correct LangGraph code?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`

## File Structure

```
plugins/makato-langgraph/
├── .claude-plugin/
│   └── plugin.json
├── config/
│   └── skill-bundles.yml       # Skill-routing bundles consumed by makato-build inject-skills (#144)
├── pre-commit/
│   └── validate-skill-bundles.sh  # Authoring gate: rejects wide globs without a contains: filter
├── skills/
│   ├── langgraph-fundamentals/
│   ├── langgraph-agent-patterns/
│   ├── langgraph-human-in-the-loop/
│   ├── langgraph-persistence/
│   └── langgraph-reflexion/
├── AGENTS.md
├── CLAUDE.md
├── README.md
└── CHANGELOG.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: helps a developer write correct LangGraph code
- [ ] Skill is LangGraph-specific (would not apply to other AI frameworks)
- [ ] Skills are self-contained (no `../` paths)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-langgraph): description`
