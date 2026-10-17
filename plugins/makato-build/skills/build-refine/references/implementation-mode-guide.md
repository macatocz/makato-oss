# Implementation Mode Guide

## Two Modes

### implement-tdd

TDD cycle per task: **RED → GREEN** with targeted test files.

- **RED**: Write or extend this task's unit and integration tests, then run only
  those changed test files; confirm new tests fail for the intended reason.
- **GREEN**: Implement the minimum code and rerun the same targeted command until
  every locally runnable task test passes.

Integration tests stay in the task's targeted test set; they are not a separate
whole-suite coder gate. `build-verify` owns the full unit and integration suites,
coverage, lint, and other whole-change gates.

**Use for:**
- Backend service logic, business rule validation
- API endpoint handlers
- Data transformations, mapping functions
- Repository / DAO methods
- Any behavior that can be precisely specified as assertions before writing code

**Signal**: "I can write the test before the code, and the test will be precise."

### implement-goal

Goal-driven execution: implement first, write tests after.

**Use for:**
- UI components, templates, views
- Configuration changes (application properties, feature flags)
- Schema migrations (behavior is the resulting DB state, not logic)
- Tasks where TDD would require mocking so heavily that tests prove nothing
- Tasks where the correct output is best verified visually or by running the system

**Signal**: "I need to see what it looks like before I can meaningfully test it."

## Mixed Stories

If a story has tasks in both categories, mark each task individually:

```
Task 1 (tdd):  Implement CancellationService.cancel()
Task 2 (goal): Update CancellationView component
Task 3 (tdd):  Add CancellationController endpoint
```

The `implement-tdd` and `implement-goal` skills each process only their typed tasks.

## When in Doubt

Default to TDD. It is always possible to write a meaningful test for backend logic first.
If you find yourself writing elaborate mocks with assertions that prove nothing about real
behavior, switch to goal-driven for that specific task.
