---
name: build-implement-tdd
description: >-
  Execute a refined plan using TDD — RED failing tests, GREEN unit
  passing, INTEGRATE real dependencies, VERIFY full suite per task.
  Tracer bullet phase for multi-layer stories. Autonomous loop. Use
  after refine to implement-tdd a story plan, implement tdd tasks, or
  run the core build loop.
version: "1.6.0"
model: sonnet
argument-hint: "[work-item-key]"
---

# implement-tdd

## When to Use

Use after `/refine` has produced `plan.md` in the spec folder and the plan contains tasks with `mode: tdd`. Runs autonomously through the full task list without interactive prompts, except to confirm scope on load and to escalate structural blockers.

**Do NOT use when:**
- No plan exists — run `/refine` first
- All tasks in the plan are `mode: goal` — run `/implement-goal` instead
- You are mid-implementation and need to resume — read the plan and the last `build.jsonl` entry to orient, then continue from the next incomplete task

## Workflow

### Step 1 — Ask for work item key and load plan

Ask: "Which work item are you implementing? (e.g. #123, or pass it directly: `/makato-build:build-implement-tdd #123`)" — or use the passed argument directly.

Load @references/tdd-cycle-rules.md. These rules govern all decisions in the TDD loop for this session.

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`). If the plan does not exist: stop and tell the user to run `/refine` first.

Extract all tasks where `mode: tdd`. If none exist: stop and tell the user all tasks are goal-mode — run `/implement-goal` instead.

If the plan is mixed mode: note the goal-mode tasks and confirm scope with the user — "Tasks [N, M] are goal-mode and will be skipped here — run /implement-goal for those after this session."

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"session","status":"start","data":{"tdd_tasks":<N>,"goal_tasks_skipped":<N>}}'
```

### Step 3 — Establish test baseline

Load @shared/baseline-guide.md. Follow its instructions to establish the baseline and handle the broken baseline gate.

**Flakey test rule**: if a test fails but no source code was changed between runs, re-run that single test once before classifying. If it passes on the second run, log it as flakey and continue. If it fails again, classify normally.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"baseline_mode":"<proceed|halted>"}}'`

If `pre_existing_failures > 0` and user chose continue, also log a decision entry:
`shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"baseline-gate","status":"decision","data":{"pre_existing_failures":<N>,"user_choice":"continue"}}'`

### Step 4 — Read implementation context (via plan-analyst agent)

Dispatch the `plan-analyst` agent with:
- `PLAN_PATH`: absolute path to `plan.md` in the resolved spec folder
- `GLOSSARY_PATH`: absolute path to `glossary.md` in the resolved spec folder
- `REPO_ROOT`: absolute path to the target repository root

The agent returns a structured Plan Analysis containing: task list with tdd/goal mode, layers detected, `tracer_required` flag, glossary constraints, and reusable codebase patterns. Use this output for all subsequent steps — do not re-read plan.md or glossary.md independently.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"load-context","status":"ok","data":{"grill_context":<true|false>,"tracer_required":<true|false>}}'`

### Step 5 — Build tracer bullet (conditional: tracer_required = true)

Skip this step entirely if `tracer_required = false` (set in Step 4). Proceed directly to Step 6.

Load @references/tdd-cycle-rules.md — the Tracer Bullet Phase section governs all decisions in this step.

Identify the topmost layer in the plan. Tie-break order: ui > controller > service > repository > persistence. If none of these standard layers are detected (e.g. microservice, event-driven, CLI tool), use the public entry point of the module as the topmost layer.

#### TRACER STUB — Write thin stubs for all non-topmost layers

For each non-topmost layer (working bottom-up), write a stub at the exact file path listed in that layer's task `**Files:**` field. Follow stub rules from `tdd-cycle-rules.md` (compiles, returns hardcoded valid value, carries `// TRACER STUB — replaced by Task <N> implementation`, no logic).

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-stub","status":"ok","data":{"stubs_written":<N>}}'`

#### TRACER TEST — Write one end-to-end integration test

Write one integration test in the topmost layer's test file following the tracer integration test rules from `tdd-cycle-rules.md`. Run the test — it must pass before proceeding. Apply the fix-vs-escalate threshold from `tdd-cycle-rules.md`.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-test","status":"ok","data":{"tracer_test_file":"<path>","tracer_test_name":"<name>","layers_covered":<N>}}'`

#### TRACER VERIFY — Full suite gate

Run the full suite. Zero new failures allowed vs. the baseline from Step 3.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-verify","status":"ok","data":{"new_failures":0}}'`

### Step 6 — Execute RED → GREEN → INTEGRATE → VERIFY for each tdd task (via coder agent)

**Pre-flight: validate blockedBy graph.** Before dispatching any coder agent, perform a topological sort of all tdd tasks using their `blockedBy` fields. If a cycle is detected (Task A blocked by B, B blocked by A, or any longer chain), stop immediately:

> "Circular dependency detected in plan.md: Task <A> → Task <B> → … → Task <A>. Fix the `blockedBy` fields in `plan.md` to remove the cycle, then re-run `/build-implement-tdd`."

Only proceed once the dependency graph is confirmed acyclic.

For each `mode: tdd` task in topological order, dispatch the `coder` agent with:
- `TASK`: the task object (title, files, unit test spec, integration test spec, AC links, mode, blockedBy, commitMessage)
- `TASK_INDEX`: 1-based index of the task within the plan
- `STORY_KEY`: the work item key (e.g. DCP-1234)
- `JSONL_PATH`: absolute path to `build.jsonl` in the resolved spec folder
- `PLAN_CONTEXT`: the full Plan Analysis output from Step 4 (glossary constraints, layer classification, tracer_required flag, reusable patterns)
- `TRACER_TEST_NAME`: name of the tracer integration test if `tracer_required = true` and it was written in Step 5; otherwise omit
- `BASELINE_FAILURES`: pre-existing failure count from Step 3
- `REPO_ROOT`: absolute path to the target repository root

**blockedBy enforcement**: before dispatching a task, check its `blockedBy` list. Do not dispatch a task concurrently with any task whose index appears in its `blockedBy` list. A task blocked by Task N must wait until Task N's coder agent returns `status: complete` before being dispatched.

The coder agent runs the full RED→GREEN→INTEGRATE→VERIFY cycle for the task and appends JSONL entries directly to JSONL_PATH.

**On coder result (R1 envelope parsing):**

The coder agent emits an R1 envelope as the final fenced ` ```json ` block in its message (see `plugins/makato-build/agents/RETURN-CONTRACT.md`). Parse the **last** `json`-fenced block via `JSON.parse()` — do not scrape the prose Output Format section. The R1 envelope is the authoritative contract.

Map `r1.status` to action:
- `r1.status == "success"` — task complete; proceed to the next task. The prose Output Format remains for human inspection; the R1 envelope drives the loop.
- `r1.status == "partial"` — VERIFY did not reach zero new failures. Treat as soft failure: log a warn entry, then stop the loop unless `r1.data.new_failures` is explicitly within an acknowledged threshold for this story. Recommend `/build-simplify` to triage.
- `r1.status == "failure"` — structural escalation. The contents of `r1.errors[0]` (or `r1.summary` if empty) is the escalation reason. Stop the loop, report to user, recommend `/refine`.

If the R1 envelope cannot be parsed (missing block, invalid JSON, `schema != "r1"`): treat as `status: "failure"` with reason `"R1 contract violation"` and surface the raw message to the user for diagnosis.

After every coder dispatch (success or otherwise), mirror the R1 envelope into `build.jsonl` so the audit trail captures the full machine contract verbatim:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"r1","status":"<r1.status>","task":<TASK_INDEX>,"data":<entire-r1-envelope-object>}'
```

When `r1.status == "success"`, also patch workflow-state so the PO-agent (GAP-006) can resume from accurate task state without re-parsing `build.jsonl`. The call is guarded — it skips silently when running in a consumer repo without the `makato-orchestrate` plugin present:

```bash
MAKATO_ROOT="$(git rev-parse --show-toplevel)/plugins/makato-orchestrate"
if [[ -x "$MAKATO_ROOT/shared/workflow-state.sh" ]]; then
  "$MAKATO_ROOT/shared/workflow-state.sh" patch "<key>" ".sub_tasks[$((TASK_INDEX-1))].status" '"complete"'
  "$MAKATO_ROOT/shared/workflow-state.sh" patch "<key>" ".sub_tasks[$((TASK_INDEX-1))].agent_result" '<r1-envelope-as-json-literal>'
fi
```

**Note:** unconditional on autonomous mode (per `AUTONOMOUS-MODE.md` § Skills NOT in scope this skill always runs autonomously); conditional only on `r1.status == "success"`. On `partial` or `failure` the PO-agent reads the R1 envelope from `build.jsonl` and applies its own state mutation — that path lands in GAP-006 (#32).

For backward compatibility, also emit the existing step-specific log entry on escalation:
- `r1.status == "failure"` — `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"task-escalate","status":"warn","data":{"task":<N>,"reason":"<r1.errors[0] or r1.summary>"}}'`

If the coder agent applied a fix within the RED→GREEN cycle (a decision to fix rather than escalate), the coder appends its own decision entry to JSONL_PATH. The orchestrating skill does not need to re-log those decisions.

For stories where the tracer bullet ran (Step 5): each task's GREEN phase replaces the stub for its layer — the tracer integration test continues to pass throughout, evolving from stub-backed to real-implementation-backed. The coder agent enforces this via TRACER_TEST_NAME.

### Step 7 — Final suite verification and conditional coverage check

After all tdd tasks complete, run the full suite one final time.

If `design.md` specifies a coverage threshold: check **conditional coverage** (branch/condition coverage) — not line coverage. Conditional coverage verifies that every branch of every condition has been exercised, which is the meaningful signal for logic-heavy TDD work. Line coverage alone can be satisfied without testing all branches of conditional logic.

If conditional coverage is below threshold: identify uncovered branches and add targeted tests for those paths. Do not proceed until coverage is met or the gap is explicitly acknowledged and logged as a known risk.

Run: `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"final-verify","status":"ok","data":{"tdd_tasks_complete":<N>,"conditional_coverage":"<X>%","threshold_met":<true|false>}}'`

### Step 8 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"session","status":"ok","data":{"tdd_tasks":<N>,"goal_tasks_pending":<N>}}'
```

**Session summary**: read `build.jsonl` for this story and collect all entries where `status` is `"warn"` or `"decision"`. Print a compact summary:

```
## Session Summary — <key>
Tasks completed: <N>/<total>
Decisions & warnings: <count>
<for each warn/decision entry: "  ⚠ <step>: <data summary in one line>">
```

If no warn/decision entries exist: print "No decisions or warnings logged — clean run."

Tell the user: "<N> TDD tasks implemented. Full suite passing. [If tracer bullet ran: Tracer bullet integration test persisted and fully backed by real implementation.]
Pipeline remaining: `/build-simplify` → `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`
Next: run `/build-simplify` to check for unnecessary complexity, or `/build-implement-goal` if goal-mode tasks remain."
