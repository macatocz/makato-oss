# makato-fastapi — Contributor Guide

## Goal

Provide FastAPI-specific reference skills and conventions for building correct, production-ready Python HTTP APIs with the FastAPI framework.

**How:** Delivers a self-contained reference skill covering the modern FastAPI API surface — `Annotated` parameters and dependencies, routing, response models, streaming (JSON Lines / SSE / bytes), Pydantic conventions, and the recommended tooling ecosystem (uv, Ruff, ty, Asyncer, SQLModel, HTTPX).

**Why:** FastAPI knowledge is technology-specific and only relevant on projects that expose an HTTP API with the framework — keeping it in a dedicated plugin lets `makato-build` stay technology-agnostic and lets teams opt in only where FastAPI is actually used (e.g. sagibeast's `src/{body,brain}/api/` layer).

## What Belongs Here

- FastAPI API reference skills (path operations, routers, `Annotated`, `Depends`, response models)
- Streaming guidance for FastAPI (JSON Lines, Server-Sent Events, byte streaming)
- Pydantic conventions as used through FastAPI (no Ellipsis, no `RootModel`, `TypeAdapter` annotations)
- FastAPI tooling and adjacent-library guidance (uv, Ruff, ty, Asyncer, SQLModel, HTTPX)

## What Does NOT Belong Here

- General Python skills not specific to FastAPI
- Technology-agnostic build workflow steps (those stay in `makato-build`)
- Non-FastAPI web framework patterns (Django, Flask, Litestar, Starlette-only, etc.)
- Project management, planning, or shaping skills

## Decision Test

"Does this skill help a developer write correct FastAPI code?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`

## File Structure

```
plugins/makato-fastapi/
├── .claude-plugin/
│   └── plugin.json
├── config/
│   └── skill-bundles.yml       # Skill-routing bundle consumed by makato-build inject-skills (#144)
├── pre-commit/
│   └── validate-skill-bundles.sh  # Authoring gate: rejects wide globs without a contains: filter
├── skills/
│   └── fastapi/
│       ├── SKILL.md
│       └── references/
│           ├── path-operations.md
│           ├── dependencies.md
│           ├── streaming.md
│           ├── responses.md
│           ├── pydantic.md
│           └── other-tools.md
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

- [ ] Serves the plugin goal: helps a developer write correct FastAPI code
- [ ] Skill is FastAPI-specific (would not apply to other web frameworks)
- [ ] Skills are self-contained (no `../` paths)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-fastapi): description`
