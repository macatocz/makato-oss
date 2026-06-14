# Post-Implementation Test Guide

## The Core Rule

Tests written after implementation must document observed behavior — not prove that the
implementation was a good idea, and not test internal mechanics.

Ask before writing each test: *"If someone reads this test without reading the source code,
will they understand what this component/function/service does?"* If yes, write it. If not,
reframe the test.

## What Makes a Post-Impl Test Meaningful

**Meaningful:** Asserts on the observable boundary — what goes in, what comes out.
- Given these inputs (props, arguments, state, HTTP request)
- When this thing runs (render, call, apply migration)
- Then these outputs exist (rendered elements, return values, written records, schema shape)

**Not meaningful:** Asserts on internal state the caller cannot observe.
- Do not assert that a private field is set
- Do not assert that a specific internal method was called
- Do not assert on intermediate computed values that are not part of the output contract

## Documenting Behavior vs. Documenting Implementation

| Behavioral (write this) | Implementation-coupled (avoid this) |
|---|---|
| "renders a disabled button when loading" | "sets `isLoading` to true" |
| "returns 404 when item not found" | "calls `repository.findById` exactly once" |
| "applies migration adds column `status`" | "executes INSERT INTO migrations VALUES…" |
| "emits `change` event with updated value" | "calls `this.onChange` with the result of `transform()`" |

## What to Cover

Cover the acceptance criteria from the plan — not everything imaginable.

For each acceptance criterion in the task:
1. Write at least one test that confirms the criterion is met
2. Write tests for the edge cases specified in the criterion (not invented edge cases)
3. Write one test for the primary error path if the criterion implies one

Do not write tests for implementation decisions that have no observable effect on behavior.
Do not invent test scenarios that are not in the acceptance criteria or the plan.

## Test Naming

Tests are documentation — their names must read as sentences describing behavior.

Follow the codebase convention if one exists. If not:

```
describes/renders/returns <observable outcome> when <condition>
```

Examples:
- `renders an error message when the form is submitted with an empty field`
- `returns the created entity with an assigned ID`
- `applies the migration without data loss when existing rows have null status`
- `emits the change event with the new value after user input`

## Avoiding Over-Specification

Post-impl tests have a specific failure mode: they over-specify because the implementation
is already in front of you and it's tempting to just mirror it back.

Signs of over-specification:
- The test would fail if you refactored the implementation without changing its behavior
- The test mirrors the structure of the production code rather than the output
- The test imports and calls internal helpers directly

If refactoring the component without changing what it does would break the test, the test
is testing the wrong thing.

## Coverage Threshold

If the design.md specifies a coverage threshold, check **conditional coverage**
(branch/condition coverage, not line coverage). Every branch of every conditional added
by this task must be exercised by at least one test.

The goal is not to manufacture tests to hit a number — it is to ensure that every decision
point in the new code has been exercised and its behavior documented.
