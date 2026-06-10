# ADR-0006: Cross-Plugin Contracts via Disk

## Status

Accepted

## Date

2026-05-11

## Context

Plugins need to produce artifacts that other plugins can consume (e.g., one plugin produces a spec, another consumes it for code generation). 

Options:

1. Direct skill-to-skill invocation — creates runtime coupling, breaks if target plugin isn't installed
2. Shared in-memory state — no persistence, fragile
3. Disk-based contracts — files conforming to schemas, loosely coupled

## Decision

Cross-plugin communication happens via disk contracts:

- `makato-core/contracts/` defines artifact schemas (what a valid artifact looks like)
- Producing plugins write files conforming to these schemas
- Consuming plugins read files matching these schemas
- No runtime imports between plugins
- No assumption that any other plugin is installed

Contracts are design-time definitions. Skills use local templates to produce/consume artifacts — they don't import from core at runtime.

## Consequences

- Plugins remain independently installable
- Adding a new plugin doesn't break existing ones
- Contracts are versioned with core (breaking changes = MAJOR bump)
- Users can mix-and-match plugins freely
- Trade-off: no type-safety at boundaries (acceptable — schemas provide documentation and CI validation)
