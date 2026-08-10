# Implementation Plan: Offline continuation: local board mirror + bidirectional sync daemon (#9)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #9
**Summary:** Offline continuation: local board mirror + bidirectional sync daemon

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Add the mirror file (board item-Status snapshot on the persistent volume) and route loop.sh board reads through it
- sharing the gh board-read primitives with reconcile. Add the sync daemon: GitHub->mirror refresh plus queued mirror-write->GitHub push of status transitions
- last-writer-wins (single operator). Sync cadence + conflict rule are a tracked build-phase item (Q-mirror)
- the no-Status-lost assertion is locked once that is set.

## Acceptance criteria

- the loop reads from the local mirror (not GitHub) and dispatches the next Ready issue; no board-poll error halts the queue
  - loop-status.json shows the dispatch count incrementing during the partition
- the sync daemon pushes queued writes to GitHub, the board Status matches what the mirror recorded, and no update is silently dropped
- the mirror updates to Done and the loop does not re-dispatch the already-done issue
- the loop should dispatch the next ready issue without halting
  - the number of dispatched issues should increase while connectivity remains blocked
- the board should show the same Status for each issue that was recorded locally during the outage
- the local board copy should update to show the issue as Done
  - the loop should not dispatch that issue again

## Scope Flags

_To be enriched by build-refine at dispatch time._
