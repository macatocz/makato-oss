# Task Sizing Guide

## The Single-Session Constraint

Every task list produced by /refine must fit an autonomous session: each coder
finishes its targeted RED and GREEN work, then build-verify runs whole-change
gates after implementation.

**Target task count**: 2–6 tasks per story.
- Fewer than 2: the story may need only one focused change; that is fine.
- More than 6: the story is likely too large. Flag it and ask the user to split.

## Per-Task Budget (one coder dispatch)

Each task is executed by one `coder` dispatch with a fixed turn budget, and its
RED → GREEN work must finish inside it. A task that exhausts the budget before
RED leaves nothing behind. Keep every task inside **all** of these limits:

| Limit | Maximum per task |
|---|---|
| Production files created or modified (a manifest + its lockfile count as one) | 4 |
| New production modules created | 1 |
| New endpoints, commands or routes | 3, all in one concern |
| Integration-test scenario groups (bold sub-bullets under **Integration Test**) | 2 |
| Acceptance criteria covered | 2 |
| External boundaries crossed in its integration test (DB, object store, HTTP, queue, browser…) | 2 |

Tests and fixtures do not count toward the file limit, but a task that needs more than two new
test files is a sign that it bundles several concerns.

When a task exceeds any limit, split it **before** writing the plan:

1. Split along concern boundaries that each end in a tested, observable behavior — for example
   "store and complete an upload", then "retry and identity conflict", then "quarantine", then
   "download and preview" — never into a production half and a test half.
2. Put shared groundwork (migration, configuration, dependency pin, shared helper) in its own
   earlier task, with the later slices listing it in `blockedBy`.
3. Give each slice its own AC links and integration scenarios. An AC that spans slices is linked
   from each slice that proves part of it, and Step 9 coverage must still be complete.

Splitting oversized tasks takes precedence over the task-count target. If the split pushes the
story past 6 tasks, apply the "More than 6" rule above (flag and ask the user to split the story;
in autonomous mode, record the scope risk in the plan rather than re-merging tasks). Never merge
tasks back over the per-task limits to meet the count.

## What Makes a Task Right-Sized

A task is right-sized when:
1. It can be implemented and tested independently from other tasks in the list
2. It represents a single logical change (one layer, one concern)
3. Its unit tests can be written before implementation (for TDD tasks)
4. It has a clear "done" state determinable by tests alone

## Task Title Format

`<Verb> <Subject>`

Good examples:
- "Add OrderStatus enum to persistence layer"
- "Implement DealService.cancel() with business rule validation"
- "Update DealController cancel endpoint to accept cancellation request"
- "Add integration test for deal cancellation workflow"

Avoid vague verbs: "Handle", "Process", "Update X and other things"

## How to Split When a Story Is Too Large

1. Look for tasks that span multiple stories within a theme — keep them, they belong together
2. Look for tasks that could be a separate story entirely (e.g., optional enhancements
   the acceptance criteria do not strictly require) — defer them
3. Never split a task mid-layer: a service method and its tests are one task, not two

## Ordering Rules

Tasks must be ordered by implementation dependency:
- Database/schema changes before repository changes
- Repository changes before service changes
- Service changes before controller/endpoint changes
- Shared utilities or enums before the code that uses them

## Anti-Patterns

- Tasks with "and" in the title representing two unrelated concerns
- Tasks with no file targets ("set up the feature")
- Tasks that cannot be tested in isolation
- Tasks that depend on other tasks not yet in the list
- Tasks so large they would take multiple hours to implement, or that break any per-task limit
  above (e.g. one task owning an upload pipeline, its retry, quarantine, preview, download and
  every route at once)
