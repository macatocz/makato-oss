# Coverage-Raise Guide

## Scope

Use this guide when coverage data that covers every test lane is below its threshold. Two callers own the measurement:

- `build-verify` Gate 5, when it enforces the threshold locally. The `coder` writes the tests in verify-repair mode.
- `build-fix-ci`, when the PR's CI coverage-threshold check fails. `build-implement-goal` writes the tests as a CI recovery task.

Never rank files from a partial measurement. When CI runs the integration lane, local data is unit-only. It ranks
integration-covered code lowest, and new unit tests for that code would duplicate the integration tests. The CI
coverage check owns that case.

## Select the targets

Read the per-file rows and the total from the coverage report:

1. **Gap.** Estimate the units still needed:
   `needed = ceil((threshold − total%) / 100 × total coverable units)`. Coverable units are statements, plus branches
   when the tool measures them. When `needed <= 0`, the threshold is met; stop. The estimate only sizes the round,
   because every round re-measures.
2. **Candidates.** Production files with at least one missed unit. Exclude test files, and lines an earlier round
   of this run reported as unreachable.
3. **Rank.** Lowest coverage percentage first; on a tie, more missed units first.
4. **Select.** Take files in rank order until their combined missed units reach `needed`, at most 5 files per round.
   The cap keeps one round within a single test writer's context.

Record `{threshold, total, needed, targets:[{file, percent, missed, missing}]}`. `missing` holds the report's missing
lines or branches, or `null` when the source does not list them.

## Write the tests

- **Test-only.** Add or extend tests. Never change production code, coverage configuration (`omit`, `exclude`,
  `fail_under`, `source`), coverage pragmas, skip markers, or the threshold.
- **Edge cases that reach the missing lines.** Cover boundary values, empty, `None` and zero inputs, invalid input,
  error and exception paths, early returns, and the untaken side of each conditional. When `missing` is `null`, find
  the paths that the file's existing tests leave unexercised.
- **Assert behavior.** Every test asserts an observable outcome: a return value, a raised error, a state change, or a
  call at a real boundary. A test that only executes code to move the number is not acceptable.
- **Respect the lane.** Follow the file's existing test location, fixtures and conventions. Use unit tests for pure
  logic and the integration lane for code that needs a real dependency. Never mock a layer boundary to reach lines
  that integration tests own.
- **Unreachable code.** A missing line that no input can reach is reported as `unreachable`, with the reason. Never
  suppress it.
- **Run the new tests.** Run the new and changed test files; they must pass.

## Re-measure

- **Local (`build-verify`).** When the round changed only test files, and no shared fixture or `conftest`, run
  `coverage_append` with those files, then `coverage_report`. The earlier data stays valid because production code
  did not change. Otherwise collect again from Gate 3. Without split commands, run the all-in-one `coverage` command.
- **CI (`build-fix-ci`).** The coverage check on the pushed head re-measures.

When the threshold is still unmet, select again from the new report, within the caller's round budget.
