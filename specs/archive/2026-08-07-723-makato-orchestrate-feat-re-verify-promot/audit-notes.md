# Codepath Audit: cfb1605 + 131dd89 for promote-ready (#723)

## Commits Audited

| Commit | Title | Merged via |
|--------|-------|-----------|
| `cfb1605` | fix(makato-orchestrate): reconcilers use --project-id in gh item-edit (#697) | PR #699 |
| `131dd89` | fix(makato-orchestrate): reset board card to Ready after api_error dispatch (#698) | PR #700 |
| `9aeba0e` | Merge pull request #698+#700 batch merge | — |

## cfb1605 — reconcilers use --project-id

### Affected functions in loop.sh

- `_reconcile_orphaned_in_progress` — previously called `gh project item-edit $proj_number --owner` (positional project number). Fixed to `gh project item-edit --project-id "$proj_node_id"`.
- `_reconcile_orphaned_stale` — same bug, same fix pattern.

Both functions now read `project_node_id` from `.github_project.project_node_id` in `$CONFIG_FILE` and guard on empty value.

### Affected functions in promote-ready.sh

**None.** `_reconcile_blocked_by_labels` in `promote-ready.sh` calls `gh issue edit`, NOT `gh project item-edit`. It is entirely outside the cfb1605 fix scope. The function removes stale `blocked-by:` labels from issues — it does not write to the project board.

### Smoke tests added by cfb1605

- `T-RECON-ARGSHAPE-1` — asserts `_reconcile_orphaned_in_progress` call uses `--project-id`
- `T-RECON-ARGSHAPE-2` — asserts `_reconcile_orphaned_stale` call uses `--project-id`

Both are in `loop-smoke-tests.sh` and pass on the current branch.

## 131dd89 — api_error board-reset

### New function in loop.sh

- `_reset_board_card_to_ready <ISSUE_NUMBER>` — called by `cmd_dispatch` after a non-zero exit from the claude subprocess when no `workflow-state-<N>.json` was written. Reads `project_node_id` from config, re-polls the board for the current item-id, guards `cur_status == "In progress"` to prevent oscillation, then calls `gh project item-edit --project-id "$project_node_id"` to set Status=Ready.

### Test hook

`MAKATO_LOOP_RESET_BOARD_TEST_FILE` — when set, `_reset_board_card_to_ready` writes `"reset #<N> → Ready"` to the file before making any `gh` call. Smoke tests T-RC-1/T-RC-2/T-RC-3 use this hook.

### Line numbers verified (current main)

- `_reset_board_card_to_ready` defined at loop.sh ~line 3045
- Called in `cmd_dispatch` at loop.sh ~line 3110
- `--project-id "$project_node_id"` confirmed present in both the helper definition and the call site

## Reachable Failure Modes After Fixes

| Function | Failure mode | Still reachable? | Status |
|----------|-------------|-----------------|--------|
| `_reconcile_orphaned_in_progress` | Missing `project_node_id` in config | Yes — WARN logged, returns 0, no board write | Expected (degraded gracefully) |
| `_reconcile_orphaned_stale` | Missing `project_node_id` in config | Yes — same guard as above | Expected (degraded gracefully) |
| `_reset_board_card_to_ready` | Missing `project_node_id`/config | Yes — returns 0 with WARN | Expected (best-effort, never blocks) |
| `_reconcile_blocked_by_labels` | `gh issue edit` failure | Yes — outside cfb1605 scope, separate concern | Out of scope for this fix |

## Conclusion

Both fixes landed correctly. The `--project-id` argument is present in all three affected call sites. The `_reset_board_card_to_ready` helper is wired into `cmd_dispatch` and guarded on config completeness. No still-reachable failure modes require additional fixes. The remaining unreachable-without-missing-config paths are best-effort degradations, not bugs.

**AC-1 status: CONFIRMED FIXED** — both failure modes are resolved. No gap identified.

## AC Coverage Summary (Issue #723)

| AC | Status | Evidence |
|----|--------|----------|
| AC-1 | CONFIRMED | Both failure modes fixed (cfb1605 + 131dd89). No gap. See table above. |
| AC-2 | CONFIRMED | T-RC-1/T-RC-2/T-RC-3 in loop-smoke-tests.sh (lines 7035–7093) cover the api_error board-reset path offline. T-RC-PROMOTE alias added as confirmation marker. |
| AC-3 | CONFIRMED | docs/makato-feature-audit.md promote-ready entry updated to ✅ confirmed-stable with commit refs cfb1605+131dd89. |
| AC-4 | CONFIRMED | promote-ready SKILL.md `last_updated` set to 2026-08-07. |
| AC-5 | CONFIRMED | promote-ready-smoke-tests.sh exits 0 with all T-reconcile scenarios plus boundary-scope comment added. |
