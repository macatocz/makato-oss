# Implementation Plan: Real Playwright E2E against the live sagibeast dev copy (#11)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #11
**Summary:** Real Playwright E2E against the live sagibeast dev copy

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Configure Playwright MCP against the live sagibeast dev copy (resolve the filterBrowser caveat from sequence 1). Dispatch a build skill whose runtime-QA step drives a Playwright E2E against seeded sagibeast
- and record the pass/fail result in Langfuse. Dev DB is an ephemeral fresh seed per run.

## Acceptance criteria

- Playwright MCP resolves from the sub-agent, the E2E runs against the live sagibeast endpoint, and a pass/fail result is recorded in Langfuse
- the browser session should reach a known page on the live sagibeast copy
  - the pass or fail outcome should appear as a new trace in Langfuse under the makato project
- the sub-agent should open a Playwright browser session against the sagibeast endpoint rather than falling back to the native browser tool

## Scope Flags

_To be enriched by build-refine at dispatch time._
