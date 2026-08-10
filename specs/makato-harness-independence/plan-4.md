# Implementation Plan: loop.sh dispatches the po-agent via oh-my-pi instead of claude -p (#4)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #4
**Summary:** loop.sh dispatches the po-agent via oh-my-pi instead of claude -p

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Rename MAKATO_CLAUDE_BIN -> MAKATO_HARNESS_BIN (loop.sh:264) and re-point it to omp. Replace the claude -p --dangerously-skip-permissions --output-format stream-json invocation (loop.sh:5208) with omp --yolo -p. Re-express _parse_dispatch_result (loop.sh:2450) and _extract_session_id per the D16 contract from sequence 1. Preserve the watchdog liveness check and the MAKATO_HEADLESS=1 guard. Resume-handle contingency: if sequence 1 shows omp has no session-resume analogue
- stall-recovery is replaced by watchdog-timeout + reconcile with no resume (state-file path only) and this story is re-scoped and re-estimated accordingly.

## Acceptance criteria

- loop.sh invokes omp --yolo -p (not claude -p), the po-agent runs, and workflow-state-<N>.json is written to the config-driven state root
  - no reference to MAKATO_CLAUDE_BIN or claude -p remains in the dispatch code path
- the function returns complete, errored, or incomplete correctly and loop.sh advances workflow-state accordingly
- loop.sh invokes reconcile and the issue either resumes via the session-handle analogue or board-resets to Ready
- the loop should invoke omp --yolo -p, not claude -p
  - workflow-state should be written to the configured state directory
  - no reference to MAKATO_CLAUDE_BIN or claude -p should remain in the dispatch code path
- the loop should read the phase token as complete, errored, or incomplete and advance workflow-state to match the reported phase
- the loop should invoke reconcile and the issue should either resume from where it stopped or be reset to Ready on the board

## Scope Flags

_To be enriched by build-refine at dispatch time._
