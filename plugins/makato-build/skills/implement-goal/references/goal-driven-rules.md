# Goal-Driven Cycle Rules

## The Four Phases

Each goal-mode task runs through all four phases in order.
Never skip a phase. Never proceed to the next phase until the current gate is met.

### BUILD — Write Production Code

**Gate:** All production code for the task is written. No tests yet.

Write code that serves the task's acceptance criteria. Follow the file targets and patterns
identified in `/refine`. Use existing dependencies in preference to introducing new ones.

For UI tasks with `prototype.html` available: match the intended structure and interactions.
The prototype is the visual spec — implement against it, not against an imagined design.

BUILD is complete when the code is written and logically complete, not when it compiles.
Compilation failures are resolved in VERIFY RUNTIME, not here.

### VERIFY RUNTIME — Confirm the Code Runs

**Gate:** No compilation errors. No runtime crashes. The implementation is alive.

Compile and run the new code before writing any test. Tests written against broken code
document broken behavior — that test burden then lives in the codebase forever.

Platform-specific gates:
- **Frontend/UI**: component renders in the browser/test renderer without errors
- **Config changes**: the system starts with the new configuration applied
- **Migrations**: the migration runs against the test database and the schema is correct
- **Backend additions**: the service/module loads; no import/startup errors

Fix all errors before moving to TEST. Apply the fix-vs-escalate threshold:
"Can I fix this without changing the implementation approach?"
- **Yes** → fix in place, re-run VERIFY RUNTIME
- **No** → stop, report the structural issue, recommend re-running `/refine`

Do not loosen an acceptance criterion to avoid a fix. If the spec requires X and X is
technically problematic, escalate — do not silently deliver Y.

### TEST — Write Tests That Document Observed Behavior

**Gate:** Tests describe what the implementation does — they pass against it.

Write tests after seeing the code run. The goal is documentation through assertion:
a future reader should understand the component/feature from the tests alone.

Tests must be:
- **Behavioral**: assert on observable outputs (rendered markup, returned values, written
  records, emitted events). Not on internal state.
- **Honest**: describe what the implementation actually does, not what was hoped.
- **Scoped**: match the integration boundary in the plan. Do not widen scope.

Tests must NOT be:
- Implementation-coupled: do not assert on private methods, internal variables, or
  implementation order
- Trivially happy-path only: cover the error paths and edge cases from the acceptance
  criteria

### VERIFY — Full Suite, Zero New Failures

**Gate:** All new tests pass. Pre-existing failure count has not increased.

Run unit + integration + all pre-existing tests. Compare failure count to the baseline
recorded at session start. Any new failure blocks progression to the next task.

Apply the same fix-vs-escalate threshold as VERIFY RUNTIME. If a failing test reveals a
design flaw that cannot be fixed without changing the approach: escalate to the user,
recommend `/refine`.

## Fix vs. Escalate Threshold

At any phase, ask: "Can I fix this without changing the implementation approach?"
- **Yes** → fix in place, re-run the current phase
- **No** → stop, report the structural issue, recommend re-running `/refine`

Structural issues that warrant escalation:
- The acceptance criteria require a plan of code that contradicts the codebase's
  existing patterns
- A dependency conflict prevents the task from being implemented as planned
- The prototype.html specifies behavior that cannot be achieved with the target tech stack
- Any fix that would require changing more than the task's planned file targets

## Conditional Coverage (Final Gate)

Coverage check at session end uses **conditional coverage** (branch/condition coverage).

Every branch of every conditional in the new code must be exercised by at least one test.
Line coverage is insufficient — a line can execute without exercising all its branches.

If a branch is genuinely unreachable: document it as such (comment in the test file noting
the unreachable branch) rather than contorting the system to reach it.
