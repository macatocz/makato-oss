# ADR-0003: Core as Foundation Plugin

## Status

Accepted

## Date

2026-05-26

## Context

Shared infrastructure (contracts, schemas, diagnostics) needs to live somewhere. Options:

1. Root-level `shared/` directory — no plugin structure, no versioning
2. Implicit convention — each plugin reinvents shared patterns
3. Dedicated foundation plugin — versioned, goal-driven, same structure as toolkits

## Decision

`makato-core` is a full plugin with goal: "Provide the shared foundation that makes the suite work as a coherent system."

It admits:

- Contract schemas (inter-toolkit data exchange definitions)
- Setup/initialization skills
- Mandatory MCP server declarations
- Guide/help skills for suite users
- Diagnostics and validation utilities

It rejects:

- Workflow logic for toolkit
- Domain-specific skills (belongs in a toolkit)

Decision test: "Does this serve ONE toolkit's goal, or the suite?" → If suite → core.

## Consequences

- Core is versioned and governed like any other plugin
- Clear admission criteria via the decision test
- Avoids "junk drawer" accumulation — core has a goal too
- Contract schemas have a canonical home
- Core can be installed independently (for contributors who only need contracts)
