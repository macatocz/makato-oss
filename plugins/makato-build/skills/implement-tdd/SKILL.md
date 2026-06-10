---
name: implement-tdd
description: >-
  Execute a refined plan using TDD — RED failing tests, GREEN unit
  passing, INTEGRATE real dependencies, VERIFY full suite per task.
  Tracer bullet phase for multi-layer stories. Autonomous loop. Use
  after refine to implement-tdd a story plan, implement tdd tasks, or
  run the core build loop.
version: "1.1.0"
argument-hint: "[work-item-key]"
---

# implement-tdd

## When to Use

Use after `/refine` has produced `spec/<key>/plan.md` and the plan contains tasks with `mode: tdd`. Runs autonomously through the full task list without interactive prompts, except to confirm scope on load and to escalate structural blockers.

**Do NOT use when:**
- No plan exists — run `/refine` first
- All tasks in the plan are `mode: goal` — run `/implement-goal` instead
- You are mid-implementation and need to resume — read the plan and the last `build.jsonl` entry to orient, then continue from the next incomplete task

## Workflow

### Step 1 — Ask for work item key and load plan

Ask: "Which work item are you implementing? (e.g. DCP-1234)" — or use the passed argument directly.

Load @references/tdd-cycle-rules.md. These rules govern all decisions in the TDD loop for this session.

Read `spec/<key>/plan.md`. If the plan does not exist: stop and tell the user to run `/refine` first.

Extract all tasks where `mode: tdd`. If none exist: stop and tell the user all tasks are goal-mode — run `/implement-goal` instead.

If the plan is mixed mode: note the goal-mode tasks and confirm scope with the user — "Tasks [N, M] are goal-mode and will be skipped here — run /implement-goal for those after this session."

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO-8601-ms>","skill":"implement-tdd","story":"<key>","step":"session","status":"start","data":{"tdd_tasks":<N>,"goal_tasks_skipped":<N>}}
```

### Step 3 — Establish test baseline

Run the full existing test suite. Record the count of pre-existing failures — this is the baseline. The contract for this session: zero new failures introduced. Pre-existing failures are not this session's responsibility.

If the test environment is unrunnable (build fails, test runner crashes): stop and report. Do not proceed without a working test baseline.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>}}`

### Step 4 — Read implementation context

Read `spec/<key>/plan.md` in full to internalize the task order, file targets, and any patterns or reusable dependencies noted from `/refine`.

If `spec/<key>/glossary.md` exists (produced by `/makato-plan:grill` and enriched by `/grill-with-docs`): read it now. The canonical term glossary constrains naming — use codebase terminology where `_Code_:` entries differ from the spec canonical term.

Classify the architectural layers present in this plan by scanning the `**Files:**` paths across all tasks. Map each path to at most one layer using these signals:
- **persistence** — path segment contains: `migration`, `schema`, `flyway`, `liquibase`, `entity`, `/model/`, `jpa`, `orm`
- **repository** — path segment contains: `repository`, `repo`, `dao`, `mapper` (DB-access context)
- **service** — path segment contains: `service`, `usecase`, `use-case`, `facade`
- **controller** — path segment contains: `controller`, `endpoint`, `resource`, `handler`, `router`, `rest`
- **ui** — path segment contains: `component`, `view`, `page`, `screen`, `template`, `.tsx`, `.vue`, `.svelte`

Paths matching no signal are ignored. Count distinct layers matched. Set `tracer_required = true` if distinct layer count ≥ 3.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"load-context","status":"ok","data":{"grill_context":<true|false>,"tracer_required":<true|false>}}`

### Step 5 — Build tracer bullet (conditional: tracer_required = true)

Skip this step entirely if `tracer_required = false` (set in Step 4). Proceed directly to Step 6.

Consult @references/tdd-cycle-rules.md Section "Tracer Bullet Phase" — all decisions in this step are governed by those rules.

Identify the topmost layer in the plan. Tie-break order: ui > controller > service > repository > persistence. The topmost layer holds the integration test; all other layers get stubs.

#### TRACER STUB — Write thin stubs for all non-topmost layers

For each non-topmost layer, working bottom-up (persistence → repository → service, or equivalent):

Write a stub at the exact file path listed in that layer's task `**Files:**` field. The stub must: compile and wire into the layer above it, return a hardcoded valid value of the expected type (e.g., `Optional.of(new Deal(...))`, `Mono.just(responseDto)`, `[]`), and carry the comment `// TRACER STUB — replaced by Task <N> implementation`. No logic, no conditionals, no side effects.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"tracer-stub","status":"ok","data":{"stubs_written":<N>}}`

#### TRACER TEST — Write one end-to-end integration test

Write one integration test in the topmost layer's test file. This test must: exercise the complete path from the topmost entry point through all stubs; assert on the observable outcome at the topmost boundary (HTTP response body, return value, or emitted event — not internal state); use real wiring with no mocks of the stubs themselves; follow naming conventions from `test-writing-guide.md`.

Run the test. It must pass before proceeding. Apply the fix-vs-escalate threshold from `tdd-cycle-rules.md`: mechanical wiring failures → fix in place; incompatible interface contracts → stop and escalate to the user, recommend re-running `/refine`.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"tracer-test","status":"ok","data":{"tracer_test_file":"<path>","tracer_test_name":"<name>","layers_covered":<N>}}`

#### TRACER VERIFY — Full suite gate

Run the full suite. Zero new failures allowed vs. the baseline from Step 3.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"tracer-verify","status":"ok","data":{"new_failures":0}}`

### Step 6 — Execute RED → GREEN → INTEGRATE → VERIFY for each tdd task

Repeat for each `mode: tdd` task in plan order. For stories where the tracer bullet ran (Step 5), each task's GREEN phase replaces the stub for its layer — the tracer integration test continues to pass throughout, evolving from stub-backed to real-implementation-backed.

Load @references/test-writing-guide.md before writing the first test. Apply its conventions throughout.

#### RED — Write failing tests

Write the unit test file and integration test file for this task following the conventions from `test-writing-guide.md`.

Run only the new tests. They **must fail** before any production code is written. If a test passes without implementation: it is trivial and proves nothing — rewrite it to be meaningful before proceeding. A test that passes vacuously is worse than no test.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"red","task":<N>,"status":"ok","data":{"unit_tests":<N>,"integration_tests":<N>}}`

#### GREEN — Implement until unit tests pass

Write the minimum production code to make unit tests pass. Follow the patterns identified during `/refine` and noted in the plan. Reuse existing library dependencies and internal utilities — do not introduce new dependencies unless the plan explicitly notes they are required.

Run unit tests only. Iterate until all pass. Do not move to INTEGRATE until unit tests are green.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"green","task":<N>,"status":"ok","data":{"unit_passing":<N>}}`

#### INTEGRATE — Make integration tests pass

Extend or adjust the implementation until integration tests pass against real dependencies. Do not loosen integration test assertions to force a pass — fix the implementation instead. If the integration test reveals the unit-level design is wrong: fix both the implementation and the unit tests, then re-run GREEN before proceeding.

Run integration tests only. Iterate until all pass.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"integrate","task":<N>,"status":"ok","data":{"integration_passing":<N>}}`

#### VERIFY — Full suite gate

Run the full suite: unit tests + integration tests + all pre-existing tests. Zero new failures allowed — compare against the baseline recorded in Step 3.

If new failures appear: fix them before moving to the next task. Apply the fix-vs-escalate threshold from `tdd-cycle-rules.md`: "Can this be fixed without changing the implementation approach?" If yes — fix in place and re-run. If no — stop, report the structural issue to the user, and recommend re-running `/refine`.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"verify-task","task":<N>,"status":"ok","data":{"new_failures":0}}`

### Step 7 — Final suite verification and conditional coverage check

After all tdd tasks complete, run the full suite one final time.

If `design.md` specifies a coverage threshold: check **conditional coverage** (branch/condition coverage) — not line coverage. Conditional coverage verifies that every branch of every condition has been exercised, which is the meaningful signal for logic-heavy TDD work. Line coverage alone can be satisfied without testing all branches of conditional logic.

If conditional coverage is below threshold: identify uncovered branches and add targeted tests for those paths. Do not proceed until coverage is met or the gap is explicitly acknowledged and logged as a known risk.

Log: `{"ts":"…","skill":"implement-tdd","story":"<key>","step":"final-verify","status":"ok","data":{"tdd_tasks_complete":<N>,"conditional_coverage":"<X>%","threshold_met":<true|false>}}`

### Step 8 — Log session end and hand off

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO-8601-ms>","skill":"implement-tdd","story":"<key>","step":"session","status":"ok","data":{"tdd_tasks":<N>,"goal_tasks_pending":<N>}}
```

Tell the user: "<N> TDD tasks implemented. Full suite passing. [If tracer bullet ran: Tracer bullet integration test persisted and fully backed by real implementation.] Next: run `/simplify` to check for complexity, or `/implement-goal` if goal-mode tasks remain."
