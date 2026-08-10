# Implementation Plan: modelRoles config; drop haiku/sonnet/opus across all agents (#5)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #5
**Summary:** modelRoles config; drop haiku/sonnet/opus across all agents

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Add a `models` section to config/config.yml mapping all 10 oh-my-pi roles (default/task/smol/tiny/plan/advisor/designer/commit/slow/vision) to the open baseUrl per the D15 role->tier table — there is NO separate models.yml file
- model config lives in the existing loop-tunables config.yml. This requires extending config/parse-config.py: today it parses a flat `{var
- env
- default}` list
- so a new nested `models:` block (role -> {provider/modelId
- baseUrl
- thinking-level}) is a new schema branch the parser must read without breaking the existing flat-list contract. Rewrite the ~25 agent frontmatter files to use modelRoles
- removing every haiku/sonnet/opus reference. Verify the harness routes each role to the open endpoint (subset live-dispatch smoke per role type). Confirm the per-step modelRole->endpoint tag is emittable (integration point needed by sequence 10).

## Acceptance criteria

- zero results are returned for any haiku, sonnet, or opus string in agent frontmatter
- each LLM call hits the open endpoint and no call reaches a closed-provider URL
  - no role in config.yml's models section points at a closed endpoint at Phase-1 start (the LLM-judge closed role arrives in sequence 11)
- every LLM call in the dispatch trace should resolve to the open endpoint URL
  - no call in the trace should resolve to a closed-provider URL
- all ten oh-my-pi roles should be listed and each should point to the open endpoint base URL
  - no separate models.yml file should exist in the repository
- the search should return zero matches across all agent frontmatter
- the ten model role mappings should be readable from the models section
  - all pre-existing configuration values should remain accessible without change
- each LLM step in the trace should emit a tag recording the modelRole name and the endpoint it was routed to

## Scope Flags

_To be enriched by build-refine at dispatch time._
