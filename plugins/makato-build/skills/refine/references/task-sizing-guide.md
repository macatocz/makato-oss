# Task Sizing Guide

## The Single-Session Constraint

Every task list produced by /refine must be completable by an autonomous agent in a
single session — from first file change through /verify passing. Plan accordingly.

**Target task count**: 2–6 tasks per story.
- Fewer than 2: the story may need only one focused change; that is fine.
- More than 6: the story is likely too large. Flag it and ask the user to split.

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
- Tasks so large they would take multiple hours to implement
