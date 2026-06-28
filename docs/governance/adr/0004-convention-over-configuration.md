# ADR-0004: Convention Over Configuration

## Status

Review

## Date

2026-05-26

## Context

Configuration files proliferate quickly in plugin systems. A `makato.config.json` or similar would add cognitive load, require documentation, and create another surface for drift.

## Decision

No configuration file in the plugin repository. Plugins rely on conventions:

- Directory structure implies purpose (skills/, contracts/, shared/)
- Naming conventions encode metadata (plugin prefix, skill naming)
- plugin.json has minimal required fields
- SKILL.md frontmatter carries skill metadata
- Configuration values are stored in user proflle like in .zshrc (MAC)
  that are set during makato installation when user decide how to configure it.
- Configuration values does not define structure. It define secrets values (used by MCP, packages),
  enabling/disabling features and their configuration,

Configuration is set per user not per project, not in the plugin source.

## Consequences

- Zero configuration burden for plugin authors
- Conventions are enforced by CI (validation scripts)
- Less surface area for bugs and misconfiguration
- New contributors learn structure by reading existing plugins
- Trade-off: less flexibility for edge cases (acceptable — we value coherence over customization)
