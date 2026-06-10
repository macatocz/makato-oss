# ADR-0005: No Build Step for Plugins

## Status

Accepted

## Date

2026-05-11

## Context

Build steps add complexity: toolchains, lockfiles, build artifacts, CI build stages, and "works on my machine" issues. Plugins are primarily markdown, JSON, and shell scripts.

## Decision

Plugins have no build step. The repository IS the installable artifact.

- No compilation, transpilation, or bundling for plugins
- No package manager lockfiles in plugin directories
- No generated files that need rebuilding
- `claude --plugin-dir ./plugins/makato-<name>` works directly from a clone

**Scope**: This decision applies to `plugins/` only. `packages/` may have build steps (see ADR-0008).

## Consequences

- Clone-and-use simplicity for contributors
- No build tool version drift
- CI only validates, never builds (for plugins)
- What you read in the repo is what gets installed
- Trade-off: no computed/generated content in plugins (acceptable for markdown-native skills)
