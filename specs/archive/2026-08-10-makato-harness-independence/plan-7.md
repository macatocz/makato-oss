# Implementation Plan: One Ready issue -> merged PR, headless, open model (MVP independence proof) (#7)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #7
**Summary:** One Ready issue -> merged PR, headless, open model (MVP independence proof)

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Run the full loop against one Status=Ready issue and confirm build -> review -> PR -> merge with no approval-prompt stall (sub-agents included) and the board advancing to Done. Open-endpoint dependency (resolves the vLLM circularity): sequence 5 runs against an open-model endpoint that need not be the on-instance vLLM — a cloud open-model API is acceptable for the MVP proof
- since on-instance vLLM provisioning lives in sequence 8. Verify the production Claude Code makato is untouched and still functional (version fallback intact
- DoD).

## Acceptance criteria

- the issue is built, reviewed, and a PR is created and merged with no approval-prompt stall, and the board Status advances to Done
  - the loop log contains no approval / HALT-004 (AskUserQuestion) entries
  - every LLM call in the trace is tagged with an open-endpoint modelRole
- the smoke-test passes with the same result as pre-fork; no shared config or state path was mutated by makato-oss
- the sub-agent proceeds without blocking; yolo runtime-enforcement covers sub-agents as well as the po-agent
- the PR should be merged and the board Status for that issue should show Done
  - the loop log should contain no approval-prompt entries (no HALT-004 events) from the po-agent or any sub-agent
  - every LLM call recorded in the run trace should be tagged with an open-endpoint model role
- the smoke-test should produce the same passing result as before the run
  - no shared configuration file or runtime state path should have been changed by makato-oss
- the sub-agent should proceed without pausing or stalling
  - the loop log should show no approval-prompt entries attributed to any sub-agent

## Scope Flags

_To be enriched by build-refine at dispatch time._
