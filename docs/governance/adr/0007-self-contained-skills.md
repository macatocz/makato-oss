# ADR-0007: Self-Contained Skills

## Status

Accepted

## Date

2026-05-26

## Context

Skills that reference files outside their directory create hidden dependencies. Moving or restructuring breaks them silently. Contributors can't understand a skill without tracing external references.

## Decision

Every skill is fully self-contained within its directory:

```
skills/<skill-name>/
├── SKILL.md              # Main skill definition
├── references/           # Read-only additional documentation like context files, technical reference
└── assets/               # templates, images, examples, schemas
└── scripts/              # helpful error messages, edge cases
```

Rules:

- All references loaded at point of use (not front-loaded into context)
- No `../` paths escaping the skill directory
- Exception: `../shared/` within the same plugin is allowed
- Two skills needing the same reference: each gets a copy OR use plugin-level `shared/`
- Plugin-level `shared/` directory is the only cross-skill resource path

## Consequences

- Skills are portable — move or copy without breaking
- Contributors understand a skill by reading its directory
- CI can validate self-containment (check for escaping paths)
- Some duplication in references (acceptable trade-off for independence)
- Plugin-level `shared/` provides an escape hatch for large shared resources
