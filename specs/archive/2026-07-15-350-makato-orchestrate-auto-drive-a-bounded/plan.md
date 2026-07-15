# Implementation Plan: 350-makato-orchestrate-auto-drive-a-bounded

## Story

**Key:** 350-makato-orchestrate-auto-drive-a-bounded
**Title:** [makato-orchestrate] Auto-drive a bounded makato-plan re-shape from the Needs Planning signal
**Issue:** [#350](https://github.com/macatocz/makato/issues/350)
**Phase:** happy-path
**Dependencies:** #348 (Needs Planning signal + needs-reshape label, merged PR #410), #349 (reshape-request.json packet, merged PR #360)

## Context

`emit-needs-planning-signal.sh` (from #348) labels issues `needs-reshape` and sets board Status Needs Planning when `structural_halt_cycles >= MAKATO_STRUCTURAL_RESHAPE_THRESHOLD`. `emit-reshape-request.sh` (from #349) writes `specs/<key>/reshape-request.json` with the structural halt history and lessons trail.

This story closes the feedback loop by adding a **reshape pass** to `loop.sh` that:
1. Detects issues at board Status = Needs Planning (or `needs-reshape` label as degraded fallback).
2. Honours the kill-switch (HALT file + `claude-halt` label).
3. When `reshape_cycles < MAKATO_MAX_RESHAPE_CYCLES` (default 3): dispatches `makato-plan:decompose <slug> --autonomous` in Refine mode with `RESHAPE_REQUEST` pointing at `reshape-request.json`, then `to-issues --autonomous`. On full success increments `reshape_cycles`, removes `needs-reshape`, sets board Status Ready, logs to `orchestrate.jsonl`.
4. On failure or cycle ceiling: leaves Needs Planning, applies `needs-human-review`, logs failure.
5. Feature-flagged via `MAKATO_LOOP_RESHAPE_ENABLED` (default `0`).

## Implementation Mode

**Mode:** tdd
**Rationale:** The reshape pass has branching logic (flag check, kill-switch, cycle ceiling, dispatch, success/failure paths) that benefits from RED/GREEN/INTEGRATE coverage. The cmd_run wiring is a goal-mode change.
**runOrder:** sequential

## Tasks

### Task 1 — Add `_reshape_pass` function to `loop.sh`
**mode:** tdd
**Files:** `plugins/makato-orchestrate/scripts/loop.sh`
**What:**
- New internal function `_reshape_pass`.
- Guards in order: (1) `MAKATO_LOOP_RESHAPE_ENABLED` flag; (2) kill-switch; (3) board poll for Status=Needs Planning with `needs-reshape` label fallback.
- For each candidate (serial): read `reshape_cycles` via `workflow-state.sh read`; compare to `MAKATO_MAX_RESHAPE_CYCLES` (default 3); if at ceiling → `needs-human-review` + log; else dispatch decompose Refine + to-issues; on success increment counter + remove label + set Ready; on failure apply `needs-human-review` + leave Needs Planning.
- Test hooks: `MAKATO_LOOP_RESHAPE_TEST_CMD` (dispatch override), `MAKATO_LOOP_RESHAPE_OVERRIDE` (canned Needs Planning queue JSON).

### Task 2 — Wire `_reshape_pass` into `cmd_run`
**mode:** goal
**Files:** `plugins/makato-orchestrate/scripts/loop.sh`
**What:** In `cmd_run`, after HALT check and before auto-seed pass, add:
```bash
if [[ "${MAKATO_LOOP_RESHAPE_ENABLED:-0}" == "1" && -z "$dry_run" ]]; then
  _reshape_pass || true
fi
```
Skipped under `--dry-run`. Position preserves serial invariant.

### Task 3 — Write smoke tests for `_reshape_pass`
**mode:** tdd
**Files:** `plugins/makato-orchestrate/scripts/loop-smoke-tests.sh`
**What:** Add 7 scenarios:
- **T-reshape-disabled:** flag=0, no dispatch or board write.
- **T-reshape-halt-preempts:** HALT file present, pass returns 0, no dispatch.
- **T-reshape-happy-path:** candidate reshape_cycles=0, both dispatches succeed → needs-reshape removed, Status=Ready, orchestrate.jsonl status:ok.
- **T-reshape-decompose-fails:** decompose exits 1 → needs-human-review applied, Status stays Needs Planning, orchestrate.jsonl status:error.
- **T-reshape-cycle-ceiling:** reshape_cycles >= MAKATO_MAX_RESHAPE_CYCLES → needs-human-review, no dispatch.
- **T-reshape-label-fallback:** board poll empty but gh issue list --label needs-reshape finds candidate → dispatch proceeds.
- **T-reshape-toggle-position:** _reshape_pass call appears before _auto_seed_unprepared in cmd_run (structural grep check).

### Task 4 — Document in `SKILL.md` and env-var table
**mode:** goal
**Files:** `plugins/makato-orchestrate/skills/loop/SKILL.md`
**What:** Add "Pre-poll reshape pass (#350)" subsection to Process section (step 1.5, before auto-seed), add env-var rows (MAKATO_LOOP_RESHAPE_ENABLED, MAKATO_MAX_RESHAPE_CYCLES, MAKATO_LOOP_RESHAPE_TEST_CMD, MAKATO_LOOP_RESHAPE_OVERRIDE), and add smoke test entries for the 7 new scenarios.

## Acceptance criteria

- The loop reshape pass detects Needs Planning (board Status or `needs-reshape` label fallback) and honours the kill-switch first.
- When `MAKATO_LOOP_RESHAPE_ENABLED=1` and `reshape_cycles < MAKATO_MAX_RESHAPE_CYCLES`: successful reshape dispatches decompose Refine + to-issues, increments `reshape_cycles`, removes `needs-reshape`, sets Status=Ready, logs `step:"reshape", status:"ok"`.
- On decompose/to-issues failure: Needs Planning retained, `needs-human-review` applied, `orchestrate.jsonl` records `status:"error"`.
- When `reshape_cycles >= MAKATO_MAX_RESHAPE_CYCLES`: no dispatch, `needs-human-review` applied, logged.
- Feature flag defaults disabled (`MAKATO_LOOP_RESHAPE_ENABLED=0`); pass is no-op when disabled.
- Loop single-slot serial invariant preserved.
- Smoke tests T-reshape-disabled, T-reshape-halt-preempts, T-reshape-happy-path, T-reshape-decompose-fails, T-reshape-cycle-ceiling, T-reshape-label-fallback, T-reshape-toggle-position all pass.

## Acceptance Criteria Coverage

| AC | Description | Covered By |
|----|-------------|------------|
| AC-1 | Detects Needs Planning + honours kill-switch | Task 1, Task 3 T-reshape-halt-preempts |
| AC-2 | Successful reshape path | Task 1, Task 3 T-reshape-happy-path |
| AC-3 | Failed reshape path | Task 1, Task 3 T-reshape-decompose-fails |
| AC-4 | Cycle ceiling path | Task 1, Task 3 T-reshape-cycle-ceiling |
| AC-5 | Feature flag default disabled | Task 2 (guard), Task 3 T-reshape-disabled |
| AC-6 | Serial invariant preserved | Task 2 (position in cmd_run) |
| AC-7 | Smoke tests pass | Task 3 |
