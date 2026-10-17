# TDD Cycle Rules

## Two Phases

Each TDD task has two phases, in order. The coder runs only targeted commands
for tests it added or changed; `build-verify` owns whole-change verification.

### RED — Write Failing Tests

**Gate:** Every new or changed task test fails for the intended reason before
production code is written.

Build one targeted command from `GATE_COMMANDS`, preserving its runner prefix.
Include only test files the coder added or changed for this task, plus
`TRACER_TEST_NAME` when set. Unit and integration test files are treated the
same: run the task's files together, not the whole integration or unit suite.

A test that passes without implementation is trivial; rewrite it until it fails
because the asserted behavior does not yet exist. A setup or compilation error
does not establish RED. If a required external service prevents a touched test
from running, record it in `data.details.deferred_to_verify` with the reason.

### GREEN — Targeted Tests Pass

**Gate:** The same targeted command passes every locally runnable test.

Write the minimum production code needed to pass those tests. Do not gold-plate
or refactor. Do not add unrelated tests to the command. If the tracer test is
set, it must pass in GREEN.

## Whole-Change Verification

`build-review` owns independent diff review. `build-verify` owns build, lint,
whole unit and integration suites, coverage, and other whole-change gates. The
coder and implement-tdd coordinator do not run those gates or a cross-task
regression sweep. The Step 3 baseline is carried forward for `build-verify`.

## Fix vs. Escalate Threshold

At any coder phase, if a failure cannot be resolved without changing the
implementation approach, escalate rather than accumulating workarounds.

Ask: "Can I fix this without changing the implementation approach?"
- **Yes** → fix in place and rerun the current targeted command
- **No** → stop, report the structural issue, recommend re-running `/refine`

## Conditional Coverage

Coverage belongs to `build-verify`, which checks the configured conditional
(branch/condition) threshold. Do not infer coverage from targeted test counts
or attempt to close a coverage gap in the coder's task loop.

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
- A replacement for either the RED or GREEN phase of a task

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
   implementation, the tracer test must continue to pass. If a task's GREEN
   targeted command breaks it, fix the regression before advancing.

### Stub Replacement Contract

Each task in the per-task loop owns the replacement of exactly one stub. When a task
reaches GREEN, the stub for its layer is replaced by the real implementation. The marker
comment (`// TRACER STUB`) is removed when the replacement is written.

After the final task completes, no stub markers should remain in the codebase. If any
`// TRACER STUB` comments remain after the final task: this is a plan coverage
gap — flag it to the user.

### Fix vs. Escalate for Tracer Phase

Apply the same threshold as the main loop:

- **Fix in place** — the stub wiring fails for a mechanical reason (wrong import, wrong
  constructor argument, interface mismatch that is trivially corrected)
- **Escalate** — the stub wiring fails because the planned interfaces between layers are
  fundamentally incompatible (the service method signature cannot satisfy the controller's
  contract, or the repository return type does not match the service's expectation).
  Escalate to the user; recommend re-running `/refine` to redesign the interface contracts
  before implementation continues.
