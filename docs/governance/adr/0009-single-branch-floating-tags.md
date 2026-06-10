# ADR-0009: Single Branch with Floating Tags

## Status

Review

## Date

2026-05-11

## Context

The two-branch model (`development` for integration, `main` for releases) adds ceremony without proportional benefit at the current team size. Contributors must maintain two local branches, PRs target `development` then require a second merge to `main`, and there is no automated release tooling. The separate integration branch primarily exists for larger teams with multiple in-flight features needing pre-release testing — a scenario that doesn't apply here.

Additionally, there was no way for end users to choose between stable and bleeding-edge versions of the plugins.

## Decision

Collapse to a single branch (`main`) with floating git tags for release channels:

- **`latest`** — moved by CI on every merge to `main`. Represents the newest integrated code.
- **`stable`** — moved automatically when release-please creates a GitHub Release. Represents proven releases.
- **Permanent version tags** (`v1.0.0`, `v1.1.0`, ...) — created by release-please for historical reference.

Automation:

- release-please in manifest mode manages CHANGELOG.md and creates version tags from conventional commits.
- No manual workflow dispatches; all automation is event-driven.
- No `version` field in plugin.json — Claude Code uses commit SHA for cache invalidation.

Consumer channels:

- Stable: `/plugin marketplace add ...#stable`
- Latest: `/plugin marketplace add ...#latest`
- Local (contributors): directory source via `.claude/settings.json`

## Consequences

- Simpler contributor flow: fork → feature branch → PR to `main` → done.
- Three consumer tiers with clear update semantics.
- Professional release history via GitHub Releases page and permanent version tags.
- `development` branch is deleted; no longer referenced in documentation or CI.
- release-please creates Release PRs automatically; merging one = stamping a new version.
- If a release is bad, `stable` can be rolled back by re-releasing from an older commit.
- Supersedes the two-branch strategy established at repo creation.
