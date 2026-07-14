# makato-fastapi

**Goal**: Provide FastAPI-specific reference skills and conventions for building correct,
production-ready Python HTTP APIs with the FastAPI framework.

**How**: Delivers a self-contained `fastapi` reference skill that covers the modern FastAPI
API surface — `Annotated` parameters and dependencies, router composition, return-type and
`response_model` filtering, streaming (JSON Lines, Server-Sent Events, bytes), Pydantic
conventions, and the recommended tooling ecosystem (uv, Ruff, ty, Asyncer, SQLModel, HTTPX) —
each with ready-to-use code patterns and explicit "do this / do not do this" guidance.

**Why**: FastAPI is a specific framework with its own API contracts and idioms. Bundling this
knowledge inside `makato-build` would pollute a technology-agnostic workflow with
framework-specific detail. A dedicated plugin lets teams opt in only on projects that expose an
HTTP API with FastAPI — for example sagibeast, whose `src/body/api/` and `src/brain/api/` layers
(routers, middleware, schemas, dependencies) are being built out on Python 3.14 with Ruff and
HTTPX already in place.

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

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `fastapi` | FastAPI best practices and conventions — `Annotated`, dependencies, routing, response models, streaming (JSON Lines / SSE / bytes), Pydantic idioms, and the tooling ecosystem. | 1.0.0 |

## Skill Routing

`config/skill-bundles.yml` routes FastAPI work to the `fastapi` skill. It matches Python files
whose text imports FastAPI (`from fastapi` / `import fastapi`), plus task-text hints such as
`FastAPI`, `APIRouter`, and `Server-Sent Events`, so green-field API tasks are covered even
before any FastAPI file exists in the diff. `makato-build`'s `inject-skills` resolver aggregates
this bundle alongside every other plugin's. The `pre-commit/validate-skill-bundles.sh` gate
enforces that any wide glob carries a `contains:` or `task_contains:` precision filter.

## Installation

```bash
claude --plugin-dir ./plugins/makato-fastapi
```

## Version

0.1.0
