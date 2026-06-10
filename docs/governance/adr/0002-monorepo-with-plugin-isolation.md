# ADR-0002: Monorepo with Plugin Isolation

## Status

Accepted

## Date

2026-05-26

## Context

We need a repository structure that supports multiple independent plugins, shared packages, and centralized governance — while keeping plugins isolated enough that they can be installed independently.

Options considered:

1. Multi-repo (one repo per plugin) — maximum isolation but fragmented governance
2. Monorepo with shared build — convenient but creates coupling
3. Monorepo with plugin isolation — centralized governance, independent installability

## Decision

Use a single monorepo with strict plugin isolation:

- All plugins live in `plugins/<name>/`
- All packages live in `packages/<name>/`
- CI enforces structural boundaries
- Root allowlist prevents directory sprawl
- Each plugin is independently installable via `--plugin-dir`

Root-level allowlist (CI rejects anything else):
`.claude-plugin/`, `.github/`, `plugins/`, `packages/`, `docs/`, `scripts/`, `CLAUDE.md`, `AGENTS.md`, `CHANGELOG.md`, `README.md`, `LICENSE`, `.gitignore`, `.editorconfig`, `.git/ .markdownlint .markdownlintignore`

## Consequences

- Single source of truth for governance and conventions
- CI can enforce cross-cutting rules (naming, structure, self-containment)
- Contributors clone once, see all plugins
- Plugins remain independently installable despite shared repo
- Root allowlist prevents organic growth of top-level directories
