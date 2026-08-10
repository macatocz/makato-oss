# Implementation Plan: Survive Vast.ai preemption: persistent volume + reconcile-before-resume (#8)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #8
**Summary:** Survive Vast.ai preemption: persistent volume + reconcile-before-resume

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Provision the persistent-volume layout for non-regenerable state and point the config-driven paths at it. Add the supervisor unit (systemd on Linux
- launchd on macOS) with Restart=always and boot-time auto-resume. Implement the D7 reconcile decision table before resume: PR+CI green->resume from merge
- PR+CI red->resume from fix
- PR+CI running->bounded-timeout wait then degrade
- PR absent/ambiguous->abort + board-reset to Ready (reuse issue-to-project reconcile + _reset_board_card_to_ready). Enforce the poison-pill invariant: an ambiguous phase=pr never permanently blocks the queue. The bounded-timeout value is a concrete build-phase parameter. Note: the destroy+recreate volume-reattach case (A4) must be drilled once manually before Phase 2 closes
- kill-9 + supervisor restart approximates the common preemption case.

## Acceptance criteria

- the supervisor restarts the loop, reconcile runs the D7 table, the in-flight work resumes, and the PR is eventually merged
  - the worktree and uncommitted branch files are intact on the persistent volume post-restart
- reconcile selects abort + board-reset, the issue Status returns to Ready, and the next tick picks it up
  - the loop log confirms the poison-pill was detected and reset, not skipped indefinitely
- the worktree directory and staged changes are accessible at the same config-driven path after recreate
- the build agent should resume the in-flight work and the pull request should eventually be merged
  - the uncommitted branch files in the worktree should still be present on the persistent volume after the restart
- the issue status on the board should return to Ready
  - the loop log should confirm the orphaned state was detected and reset, not skipped indefinitely
- the worktree directory and staged files should be accessible at the same configured path after the new instance starts

## Scope Flags

_To be enriched by build-refine at dispatch time._
