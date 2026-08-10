# Implementation Plan: Closed-model LLM-judge + manual model-switch of one role (#13)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #13
**Summary:** Closed-model LLM-judge + manual model-switch of one role

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Configure a Langfuse native LLM-judge evaluator on a closed-model endpoint (with its API key as an instance secret) and surface its score per trace. Verify the manual model-switch: editing one role's baseUrl in the `models` section of config/config.yml to a closed endpoint routes only that role to the closed endpoint on the next dispatch
- with every other role unaffected and the switch visible in workflow-state and the Langfuse trace.

## Acceptance criteria

- a judge score is visible on the trace attributed to the closed-model evaluator, not to any open-model step
- only that role's LLM calls hit the closed endpoint, all other roles stay on the open endpoint, and the switch shows in workflow-state and the Langfuse trace
- only that step fails or falls back per error-handling; all other steps complete on the open endpoint and the loop does not halt the queue
- the trace should show a judge score attributed to the closed-model evaluator
  - no open-model step should be credited with the judge score
- only that role's requests should go to the closed endpoint
  - all other roles should continue using the open endpoint
  - the role switch should be visible in the workflow state and the Langfuse trace
- all other steps should complete using the open endpoint
  - the dispatch queue should continue without halting
  - only the step using the unreachable endpoint should report an error

## Scope Flags

_To be enriched by build-refine at dispatch time._
