# TDD Cycle Rules

## The Four Phases

Each task in the plan runs through all four phases in order.
Never skip a phase. Never proceed to the next phase until the current gate is met.

### RED — Write Failing Tests

**Gate:** All new tests must fail before any production code is written.

A test that passes without implementation is trivial — it proves nothing. Rewrite it until
it fails for the right reason. "Right reason" means the test fails because the behavior it
asserts does not yet exist, not because of a compilation error or missing import.

Acceptable RED failures:
- Assertion failure (expected X, got Y / got nothing)
- Method/class not found (the thing being tested does not exist yet)

Not acceptable as RED:
- Test passes immediately → trivial test, rewrite it
- Test errors on test setup (bad mock, bad fixture) → fix the test setup first

### GREEN — Unit Tests Pass

**Gate:** All unit tests for this task pass. Integration tests may still fail.

Write the minimum production code needed to make unit tests pass. Do not gold-plate.
Do not refactor. Do not implement behavior that no unit test currently asserts.

### INTEGRATE — Integration Tests Pass

**Gate:** All integration tests for this task pass against real dependencies.

If integration tests expose a flaw in the unit-level design (e.g., the interface is wrong):
fix the implementation AND the unit tests, then re-run GREEN before continuing.
Do not loosen integration test assertions to force a pass.

### VERIFY — Full Suite Passes

The VERIFY contract has two levels. Both gates must clear before a task is marked complete.

#### Level 1 — Per-task full suite (inside coder, Phase 4)

**Gate:** Zero new failures vs. the baseline recorded at session start.

Run unit + integration + all pre-existing tests. Compare failure count to baseline.
Any new failure blocks progression to the next task.

Level 1 is satisfied only by commands the coder itself ran. A coordinator's
test run never satisfies it: an unverified coder result gets one fresh-coder
continuation (see `build-implement-tdd/SKILL.md` § *On coder result*).

#### Level 2 — Cross-task regression sweep (outer loop, between tasks)

**Gate:** After each task's coder R1 returns `status:"success"`, the outer loop
(`build-implement-tdd` Step 6) re-runs the union of `tests_written[]` from all
**prior** completed tasks. If any of those previously-passing tests now fail, the
regression is attributed to the task that just completed — detected at O(1 task)
localisation cost rather than O(whole diff) at the terminal `build-verify` gate.

Rules:
- **Task 1 skip**: the first task has no prior tasks, so the accumulated set is empty.
  Skip the sweep for task 1; no log entry is emitted. The first cross-task sweep
  occurs after task 2 completes.
- **Set deduplication**: if two tasks write to the same test file path, that path
  appears once in the accumulated set (no double-counting).
- **Accumulator update timing**: a task's `tests_written[]` is added to the accumulator
  AFTER the sweep for that task passes — ensuring the sweep at task N covers tasks 1…N-1
  only, never task N's own tests.
- **Same BASELINE_FAILURES gate**: sweep failures are compared against `BASELINE_FAILURES`
  from Step 3 (same formula: `sweep_failures − BASELINE_FAILURES == 0`).
- **Fix-vs-escalate**: apply the same threshold as Level 1. A sweep regression that can
  be fixed without changing the implementation approach is fixed in place and the sweep
  is re-run. A structural regression escalates via R1 `status:"failure"`.

See `build-implement-tdd/SKILL.md` § *Cross-task regression sweep* for the outer-loop
implementation contract.

## Fix vs. Escalate Threshold

At any phase, if a failure appears that cannot be resolved without changing the
implementation approach, escalate to the user rather than accumulating workarounds.

Ask: "Can I fix this without changing the implementation approach?"
- **Yes** → fix in place, re-run the current phase
- **No** → stop, report the structural issue, recommend re-running `/refine`

## Conditional Coverage (Final Gate)

Coverage check at session end uses **conditional coverage** (branch/condition coverage).

- Every branch of every conditional expression must be exercised by at least one test
- Line coverage is insufficient — a line can execute without all its branches being tested
- If a branch is genuinely unreachable: document it as such rather than writing a test that
  contorts the system to reach it

## Tracer Bullet Phase

### Purpose

When a plan spans ≥ 3 distinct architectural layers, a tracer bullet runs before the
per-task loop. Its purpose is to prove the architecture works end-to-end before any layer
is fully implemented. The thin path catches wiring failures early — before 3+ completed
tasks need to be unwound.

### What the Tracer Is and Is Not

**Is:**
- Production code — stubs and the integration test stay in the codebase
- The earliest possible detection of architectural incompatibility between layers
- A scaffold that the per-task loop fills in task by task

**Is not:**
- A spike or throwaway prototype
- A test of business logic (that is the per-task loop's job)
- A replacement for any step of the RED → GREEN → INTEGRATE → VERIFY cycle

### Stub Rules

Each stub must satisfy all of these:

1. **Compiles and wires** — the layer above it can be constructed and called without error
2. **Returns a valid hardcoded value** — the return type matches; the value is plausible
   (e.g., a populated DTO with empty strings, a count of 0, an empty list)
3. **Carries a marker comment** — `// TRACER STUB — replaced by Task <N> implementation`
   so that the per-task loop knows which task owns the replacement
4. **Contains no logic** — no conditionals, no assertions, no side effects

Do not write a stub for the topmost layer. The topmost layer holds the integration test.

### Tracer Integration Test Rules

1. **One test only** — the tracer writes exactly one integration test. Breadth over depth.
2. **Asserts the observable outcome** — what the caller of the topmost layer would see:
   an HTTP response body, a return value, an event emission. Not internal state.
3. **Uses real wiring** — the test instantiates the full stack (stubs included) as it would
   run in production. No mocks of the stubs themselves.
4. **Must pass before the per-task loop begins** — this is a hard gate. A failing tracer
   test means the wiring design is wrong. Fix or escalate before proceeding.
5. **Stays green throughout the per-task loop** — as each task replaces its stub with real
   implementation, the tracer test must continue to pass. If a task's GREEN or INTEGRATE
   phase breaks the tracer test: fix the regression before advancing.

### Stub Replacement Contract

Each task in the per-task loop owns the replacement of exactly one stub. When a task
reaches GREEN, the stub for its layer is replaced by the real implementation. The marker
comment (`// TRACER STUB`) is removed when the replacement is written.

After the final task completes, no stub markers should remain in the codebase. If any
`// TRACER STUB` comments remain after the final VERIFY: this is a plan coverage gap —
flag it to the user.

### Fix vs. Escalate for Tracer Phase

Apply the same threshold as the main loop:

- **Fix in place** — the stub wiring fails for a mechanical reason (wrong import, wrong
  constructor argument, interface mismatch that is trivially corrected)
- **Escalate** — the stub wiring fails because the planned interfaces between layers are
  fundamentally incompatible (the service method signature cannot satisfy the controller's
  contract, or the repository return type does not match the service's expectation).
  Escalate to the user; recommend re-running `/refine` to redesign the interface contracts
  before implementation continues.
