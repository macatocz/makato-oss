# Implementation Plan: Per-step success metrics across an open-only run (#12)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #12
**Summary:** Per-step success metrics across an open-only run

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Emit per-step hard-signal flags to Langfuse: build-verify gate result
- CI green/red
- review CRITICAL count
- coder retry count
- resolve-pr-conflict HALT rate
- PR merged-without-override. Tag each step with its modelRole and endpoint. Derive the indirect plan-success signal (did the plan lead to a first-pass CI-green PR?). Requires the Langfuse container from sequence 8.

## Acceptance criteria

- each workflow-step trace carries the verify-gate result, CI green/red, review-CRITICAL count, coder-retry count, resolve-pr-conflict-HALT rate, and merged-without-override flag
- every step trace carries a modelRole and endpoint tag and open-tagged steps are >= 80% of total steps
- Langfuse shows whether the plan led to a first-attempt CI-green PR, countable across issues without manual PR-timeline inspection
- every workflow-step trace should carry the verify-gate result, CI green/red, review-CRITICAL count, coder-retry count, resolve-pr-conflict-HALT rate, and merged-without-override flag
- every step trace should carry both a modelRole tag and an endpoint tag
  - open-tagged steps should account for at least 80% of all step traces in the run
- Langfuse should show whether the plan for each issue produced a first-attempt CI-green PR, countable across all issues in the run

## Scope Flags

_To be enriched by build-refine at dispatch time._
