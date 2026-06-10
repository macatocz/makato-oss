# ADR-0008: Packages Alongside Plugins

## Status

Accepted

## Date

2026-05-11

## Context

The makato suite will eventually include non-plugin artifacts: a CLI tool, a dashboard, utilities. These need build steps, tests, and independent versioning — things explicitly excluded from plugins by ADR-0005.

## Decision

Packages live in `packages/` alongside `plugins/` in the same monorepo:
- Own build step, tests, and tooling
- Independently versioned (no suite aggregate version)
- Own CI workflow with path filters (added when first package is created)
- No coupling to plugin structure conventions

ADR-0005 ("no build step") is scoped to `plugins/` only. Packages may use any build tooling appropriate for their language/runtime.

## Consequences

- Single repo for the entire makato ecosystem
- Packages don't constrain plugin simplicity (different rules for different directories)
- CI workflows are additive (new package = new path-filtered workflow)
- Root CHANGELOG tracks all components chronologically
- Trade-off: repo grows larger over time (acceptable — governance stays centralized)
