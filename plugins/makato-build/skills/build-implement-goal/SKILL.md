---
name: build-implement-goal
description: >-
  Execute goal-mode tasks from a refined plan — build first, verify
  runtime, write tests after. Autonomous. Use after refine for UI,
  config, or migration work, or when implement-goal tasks remain
  from a mixed plan.
version: "1.4.0"
model: opus
argument-hint: "[work-item-key]"
---

## When to Use

Use when the refined plan contains tasks with `mode: goal`. This covers:
- UI components and frontend work (component renders before meaningful tests can be written)
- Configuration changes (system must start before tests verify the config)
- Database schema migrations (migration must run before tests verify the schema)
- Any task where the implementation must exist and run before tests can document its behavior

For TDD-mode tasks, use `/implement-tdd` instead. Plans are often mixed — use this skill
for goal-mode tasks and `/implement-tdd` for tdd-mode tasks, in the order the plan specifies.

## Input

When dispatched by the PO-agent (`--autonomous` mode), this skill receives a context bundle containing at minimum:

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree the PO-agent owns. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). The skill MUST `cd "$WORKTREE_PATH"` before any file edit, build, or test command.
- `--autonomous` — activation flag.

When invoked by a developer interactively, `WORKTREE_PATH` is optional. If unset, the skill falls back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

At skill entry (immediately after Step 1 loads the plan), apply the falsy-check pattern from `AUTONOMOUS-MODE.md`: in autonomous mode an empty `WORKTREE_PATH` is a HALT (R1 `status: "failure"`, `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`). In interactive mode, resolve `WORKTREE_PATH="$(git rev-parse --show-toplevel)"` and continue. After resolution, `cd "$WORKTREE_PATH"` so every BUILD / VERIFY RUNTIME / TEST / VERIFY command runs in the correct worktree.

## Workflow

### Step 1 — Ask for work item key and load plan

Ask: *"Which work item are you implementing? (e.g. #123, or pass it directly: `/makato-build:build-implement-goal #123`)"* — or use the passed argument directly.

Load `@references/goal-driven-rules.md`. These rules govern all decisions in the goal loop
for this session.

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`). If the plan does not exist, stop and tell the user to run `/refine` first.

Extract all tasks where `mode: goal`. If none exist, stop and tell the user:
*"All tasks in this plan are tdd-mode. Run `/implement-tdd` instead."*

If the plan is mixed mode, note the tdd-mode tasks and confirm scope with the user:
*"Tasks [N, M] are tdd-mode and will be skipped here — run `/implement-tdd` for those."*

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"session","status":"start","data":{"goal_tasks":<N>,"tdd_tasks_skipped":<N>}}'
```

---

### Step 3 — Establish test baseline

Load @shared/baseline-guide.md. Follow its instructions to establish the baseline and handle the broken baseline gate.

**Flakey test rule**: if a test fails but no source code was changed between runs, re-run that single test once before classifying. If it passes on the second run, log it as flakey and continue. If it fails again, classify normally.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"baseline_mode":"<proceed|halted>"}}
```

If `pre_existing_failures > 0` and user chose continue, also log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"baseline-gate","status":"decision","data":{"pre_existing_failures":<N>,"user_choice":"continue"}}
```

---

### Step 4 — Read implementation context (via plan-analyst agent)

Dispatch the `plan-analyst` agent with:
- `PLAN_PATH`: absolute path to `plan.md` in the resolved spec folder
- `GLOSSARY_PATH`: absolute path to `glossary.md` in the resolved spec folder
- `REPO_ROOT`: absolute path to the target repository root

The agent returns a structured Plan Analysis containing: task list with tdd/goal mode, layers detected, `tracer_required` flag, glossary constraints, and reusable codebase patterns. Use this output for all subsequent steps — do not re-read plan.md or glossary.md independently.

If `prototype.html` exists in the resolved spec folder: note it. It is the visual target for UI tasks in the BUILD phase. Read its structure to understand the intended component layout and interactions.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"load-context","status":"ok","data":{"prototype":<true|false>,"grill_context":<true|false>}}
```

---

### Step 5 — Execute per-task goal loop (autonomous)

Repeat for each `mode: goal` task in plan order. Each task runs all four phases before
moving to the next task.

#### ⚙ BUILD

Write all production code for the task. Follow the plan's file targets, codebase patterns,
and existing dependencies identified during `/refine`.

For UI tasks: implement against `prototype.html` as the visual target if it exists.
The prototype shows intent — match structure and behavior, not pixel-perfect styling.

Do not write any tests during this phase.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"build","task":<N>,"status":"ok","data":{"files_written":<N>}}
```

#### ▶ VERIFY RUNTIME

Compile and run. The BUILD phase is not complete until the code compiles and runs without errors.

Fix all compilation errors and runtime crashes before writing any tests. A test written for
broken code tests the wrong thing.

- For UI tasks: verify the component renders without errors in the browser/test renderer
- For config tasks: verify the system starts with the new configuration
- For migrations: run against the test database and verify the schema is correct

Apply the fix-vs-escalate threshold: "Can this be fixed without changing the implementation
approach?" If no — stop, report the structural issue, recommend re-running `/refine`.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"verify-runtime","task":<N>,"status":"ok","data":{"runtime_errors":0}}
```

#### ✎ TEST

Load `@references/post-impl-test-guide.md`.

Write tests that document the observed behavior of the implementation. Tests must describe
what the implementation actually does — not what was hoped, and not internal implementation
details. Use the plan's acceptance criteria links to verify coverage.

The baseline is: could a future reader understand what this code does from the tests alone,
without reading the source?

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"test","task":<N>,"status":"ok","data":{"tests_written":<N>}}
```

#### ✓ VERIFY

Run the full suite: new tests + all pre-existing. Compare failure count to the baseline
recorded in Step 3. Zero new failures is the gate.

Apply the same fix-vs-escalate threshold as in VERIFY RUNTIME. If fixing a failure requires
changing the implementation approach — escalate to the user and recommend `/refine`.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"verify-task","task":<N>,"status":"ok","data":{"new_failures":0}}
```

---

### Step 6 — Final suite verification and conditional coverage check

Run the full suite one final time after all goal tasks complete.

If `design.md` in the resolved spec folder specifies a coverage threshold: check **conditional coverage**
(branch/condition coverage, not line coverage). Every branch of every conditional in the
new code must be exercised by at least one test.

Identify uncovered branches and add targeted tests. Do not proceed until the threshold is
met or the gap is explicitly acknowledged and logged as a known exception.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"final-verify","status":"ok","data":{"goal_tasks_complete":<N>,"conditional_coverage":"<X>%","threshold_met":<true|false>}}
```

---

### Step 7 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"session","status":"ok","data":{"goal_tasks":<N>,"tdd_tasks_pending":<N>}}'
```

**Session summary**: read `build.jsonl` for this story and collect all entries where `status` is `"warn"` or `"decision"`. Print a compact summary:

```
## Session Summary — <key>
Tasks completed: <N>/<total>
Decisions & warnings: <count>
<for each warn/decision entry: "  ⚠ <step>: <data summary in one line>">
```

If no warn/decision entries exist: print "No decisions or warnings logged — clean run."

Tell the user:
*"&lt;N&gt; goal tasks implemented. Full suite passing.*
*Pipeline remaining: `/build-simplify` → `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-simplify` to check for unnecessary complexity."*

If tdd-mode tasks remain in the plan:
*"Run `/build-implement-tdd` first for the remaining tdd tasks, then `/build-simplify`."*
