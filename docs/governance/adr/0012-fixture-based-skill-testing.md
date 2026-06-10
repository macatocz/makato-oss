# ADR-0012: Fixture-Based Skill Testing

## Status

Review

## Date

2026-05-13 (revised 2026-05-17)

## Context

Shaping skills form a sequential pipeline where each skill's output feeds the next as input. Testing a downstream skill (e.g., `create-architecture`) requires all upstream artifacts to exist (brainstorm.md, decisions.md, prd.md). Running the full upstream chain for every test is expensive (tokens, time, human interaction) and non-deterministic.

Skills also have "update mode" paths that require their own output to already exist. Testing these paths is impossible without pre-existing artifacts.

This pattern is not unique to makato-plan — any plugin with sequential skills (where one skill's output is another's input) benefits from the same testing infrastructure.

## Decision

Every plugin with sequential skill dependencies SHOULD maintain a committed fixture directory (`scripts/fixtures/<plugin-name>/`) containing a fully-enriched spec/workspace folder for a fictional feature. A manifest file (`manifest.yml`) declares the dependency graph:

```yaml
fixture: ITDB-TEST-checkout-redesign
spec_folder_name: ITDB-TEST-checkout-redesign

skills:
  create-architecture:
    requires: [brainstorm.md, decisions.md, prd.md]
    optional: [repositories.yml, reference/]
    produces: [design.md]
```

A shared test script (`scripts/test-skill.sh`) reads the manifest and copies only the appropriate input files into a working directory, enabling isolated skill testing without running upstream phases.

Fixtures grow incrementally: when a new skill is built, its output is committed back to the fixture folder, making it available as input for downstream skills.

Key properties:

- Fixtures are committed (deterministic, reviewable)
- The working directory is gitignored (transient)
- The manifest is the single source of truth for skill I/O contracts
- Supports flags: `--minimal` (omit optionals), `--update` (include skill's own output), `--reset` (clean slate), `--list` (show all skills)
- The test script currently serves makato-plan; when additional plugins adopt fixtures, it will be extended to accept a plugin argument

## Applicability

- **Required**: Plugins with 3+ sequential skills where outputs feed inputs (e.g., makato-plan)
- **Recommended**: Plugins with 2 sequential skills
- **Not needed**: Plugins with only independent skills (no I/O chain)

## Consequences

- Any skill can be tested in isolation with a single command
- Fixture content validates the artifact format (schema drift is caught in review)
- New contributors can test skills without understanding the full pipeline
- The manifest doubles as documentation of skill dependencies
- Fixtures must be maintained — when a skill's output format changes, its fixture must be updated in the same PR
- Fictional content (ITDB-TEST) avoids leaking real project data into the repo
