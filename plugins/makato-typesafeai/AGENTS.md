# makato-typesafeai — Contributor Guide

## Hard Constraints

- **Never add general LLM text-generation patterns.** TypeSafe's System One model returns typed judgments and probabilities — skills must reflect this distinct paradigm, not generative text workflows.
- **Never import from other makato plugins at runtime.** Each plugin is independently installable; communicate through disk contracts only.
- **All skill frontmatter must include `name`, `description`, and `version` fields.**
- **Skills must direct users to live TypeSafe docs as the authoritative source.** The TypeSafe API and SDK evolve; skills that hardcode behavior without pointing to the authoritative source introduce drift.
- **No `bypassPermissions` agents in this plugin.**

## Goal

Provide reference skills and patterns for building AI-powered applications with TypeSafe's System One model API.

**How:** Shipping curated skills that guide developers through TypeSafe's judgment primitives (Choice, Noul, Score), composition patterns, and integration recipes, always pointing at the live docs as the authoritative source.

**Why:** TypeSafe's probability-weighted typed judgments are a distinct paradigm from generative text — integrations need specific design heuristics not covered by general LLM or AI agent guidance, and no other makato plugin addresses this paradigm.

## What Belongs Here

- Skills explaining TypeSafe's System One programming model and Jev model capabilities
- Skills guiding judgment question design (Choice, Noul, Score primitives) and state structure
- Integration patterns and cookbook walkthroughs for TypeSafe HTTP API and Python/JavaScript SDKs
- Skills for specific application categories (routing, ranking, extraction, verification, interactive experiences) built with TypeSafe
- Reference links to live TypeSafe documentation as the authoritative source

## What Does NOT Belong Here

- General generative LLM patterns (text generation, streaming, chat completions)
- LangGraph, LangChain, or other AI orchestration framework patterns (belongs in `makato-langgraph`)
- FastAPI or framework scaffolding not specifically about TypeSafe integration (belongs in `makato-fastapi`)
- LLM observability and tracing (belongs in `makato-observability`)
- Generic AI agent loop patterns not tied to TypeSafe's judgment API

## Decision Test

"Does this skill help a developer design, integrate, or optimize TypeSafe System One judgment calls in their application?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version
- Skills must direct users to read live TypeSafe docs; never replace the authoritative source

## File Structure

```
makato-typesafeai/
├── .claude-plugin/plugin.json
├── skills/
│   └── how-to-typesafe-ai/       # Design, integrate, and optimize TypeSafe System One judgments
│       └── SKILL.md
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves TypeSafe System One integration guidance
- [ ] Skills link to live TypeSafe docs as authoritative source
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-typesafeai): description`
