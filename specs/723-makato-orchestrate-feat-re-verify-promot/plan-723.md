# Implementation Plan: 723-makato-orchestrate-feat-re-verify-promot

<!-- issue: #723 -->

## Story
**Key:** 723-makato-orchestrate-feat-re-verify-promot
**Title:** [makato-orchestrate] feat: re-verify promote-ready after reconciler --project-id + api_error board-reset fixes
**Phase:** verification
**Dependencies:** none

## Implementation Mode
**Mode:** goal
**Rationale:** This is a verification and test-guard task. There is no new feature logic to implement via TDD — the work is to exercise existing codepaths, confirm or refute the audit's stability claim, and add regression guards for any failure mode that remains reachable. Goal mode is appropriate: verify first, add tests after.
**runOrder:** sequential

## Tasks

1. **Audit the three fix commits against promote-ready's codepath** (`plugins/makato-orchestrate/scripts/promote-ready.sh`, `scripts/loop.sh`). Read cfb1605 (reconcilers use `--project-id`), 131dd89 (api_error board-reset), and their merge 9aeba0e. For each commit, identify which functions in `promote-ready.sh` and `loop.sh` are on the affected codepath. Document whether any failure mode described in the audit concern — `_reconcile_orphaned_in_progress`, `_reconcile_orphaned_stale`, and `_reset_board_card_to_ready` — is still reachable after the fixes landed. **mode: goal**

2. **Reproduce or refute the board-reset failure mode** (`scripts/loop.sh` — `_reset_board_card_to_ready`, `cmd_dispatch`). Using the existing test-hook infrastructure (`MAKATO_LOOP_GH_OVERRIDE`, `MAKATO_LOOP_DISPATCH_DRY`), write a targeted offline scenario that simulates an `api_error` dispatch (non-zero exit before `workflow-state` write) and verifies the board card is returned to `Ready`. If the scenario demonstrates correct behavior, record it as T-RC-PROMOTE. If it exposes a gap, add a regression fix. **mode: goal**

3. **Add a regression smoke test for the `--project-id` reconciler argv shape on the promote-ready path** (`scripts/promote-ready-smoke-tests.sh`). Verify that `_reconcile_blocked_by_labels` in `promote-ready.sh` (which calls `gh issue edit`, not `gh project item-edit`) is unaffected by the `--project-id` fix landed in cfb1605. If the fix's scope is confirmed to be `loop.sh`-only, add a comment in `promote-ready-smoke-tests.sh` documenting the boundary and mark the audit entry as confirmed-green. **mode: goal**

4. **Update `docs/makato-feature-audit.md`** — re-evaluate the `promote-ready skill` entry at line 751. Based on the findings from Tasks 1–3, either confirm the ✅ status with a one-sentence rationale referencing the merged fix commits, or downgrade it to ⚠ with a specific failure mode and issue reference. Also fix the stale `last_updated: "2025-11-01"` date in `plugins/makato-orchestrate/skills/promote-ready/SKILL.md` frontmatter. **mode: goal**

## Acceptance Criteria Coverage

| AC | Description | Covered By |
|----|-------------|------------|
| AC-1 | Each documented failure mode (reconciler `--project-id` missing, api_error card not reset) is confirmed fixed or a still-reachable gap is identified with a test. | Task 1, Task 2 |
| AC-2 | At least one regression smoke test guards the api_error board-reset path so a future regression is caught offline before dispatch. | Task 2 |
| AC-3 | The `docs/makato-feature-audit.md` promote-ready entry is updated to ✅ confirmed-stable (with commit references) or ⚠ downgraded (with failure mode + issue ref). | Task 4 |
| AC-4 | `promote-ready` SKILL.md `last_updated` frontmatter reflects the current date. | Task 4 |

## Acceptance criteria

- Running `plugins/makato-orchestrate/scripts/promote-ready-smoke-tests.sh` exits 0 with all existing tests passing and any new regression test added by this issue also passing.
- The `docs/makato-feature-audit.md` promote-ready entry (line 751) is updated — either confirmed ✅ with reference to merged commits cfb1605 and 131dd89, or downgraded ⚠ with a specific, actionable failure mode statement.
- The api_error board-reset codepath (`_reset_board_card_to_ready` in `loop.sh`) is covered by at least one offline smoke test that exercises the scenario: dispatch exits non-zero before `workflow-state` is written, board card returns to `Ready`.
- `plugins/makato-orchestrate/skills/promote-ready/SKILL.md` frontmatter `last_updated` field is set to the current date (2026-08-07 or the actual date of the fix commit).
- No regression is introduced to the existing 15 promote-ready smoke scenarios (T1–T15) or the loop smoke suite.

## Scope Flags

- **In scope:** promote-ready.sh codepath verification, loop.sh api_error reset path, regression smoke tests, feature-audit document update, SKILL.md frontmatter fix.
- **Out of scope:** changes to the dependency-wave computation logic, changes to promote-ready.sh promotion behavior, changes to other loop.sh subsystems not on the audited codepath.
