---
name: build-implement-goal
description: >-
  Execute goal-mode tasks from a refined plan — build first, verify
  runtime, write tests after. Autonomous. Use after refine for UI,
  config, or migration work, or when implement-goal tasks remain
  from a mixed plan.
version: "1.9.0"
argument-hint: "[work-item-key]"
allowed-tools: [Bash]
metadata:
  authors: [makato-build]
  last_updated: "2026-10-17"
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
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root, resolved from
  the runner plugin-root variables when not supplied.
- `GATE_COMMANDS` — optional gate-scout command map. When absent, dispatch
  gate-scout once before the baseline and use its commands verbatim.
- `--autonomous` — activation flag.
- `RECOMMENDED_SKILLS` *(optional)* — JSON array of `"plugin:skill-id"` strings. When present at skill entry, apply the **skill consultation prepend** rule: before the BUILD phase of the *first* goal task, invoke each listed skill sequentially and apply any hard constraints or conventions surfaced. This field is also available per-task via the task's `recommended_skills[]` field in `plan.md` — per-task values override the skill-level bundle. Per-task rule: before the BUILD phase of each goal task, check the task's `recommended_skills` field from `plan.md`; if present and non-empty, invoke those skills before BUILD (agent-skill-routing #146). If absent on the task — proceed to BUILD directly.
- `CI_FAILURES` — optional structured failed checks from `build-fix-ci` (head SHA, run/job/attempt, summary, full private log path).
- `CI_TASK_INDICES` — affected goal task indices, including completed tasks needing repair.
- `CI_RECOVERY_TASK` — optional scoped CI-configuration/metadata task supplied by `build-fix-ci` when no original task covers the diagnosed failure; contains concrete diagnosis, files, constraints and verification command, never a new product requirement.
- `ASSIGNED_TASK_IDS` — JSON array of 1-based plan task indices the PO-agent assigns to this pass (#153). When present it is the complete selection; see Step 1.
- `ISSUE_NUMBER`, `MAKATO_ORCHESTRATE_ROOT` — supplied with `ASSIGNED_TASK_IDS`; used read-only to check dependencies. The PO-agent, not this skill, records goal-task completion in `sub_tasks[]` from `data.completed_task_ids`.

When invoked by a developer interactively, `WORKTREE_PATH` is optional. If unset, the skill falls back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` before Step 1. In autonomous mode
an empty `WORKTREE_PATH` is a HALT with
`errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in
interactive mode the guard falls back to `git rev-parse --show-toplevel`.
After resolution, `cd "$WORKTREE_PATH"` so every BUILD / VERIFY RUNTIME / TEST
/ VERIFY command runs in the correct worktree.

Spec-folder reads use `MAKATO_TARGET_REPO_ROOT` when set and the common-dir fallback otherwise.

```bash
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)}"
```

Spec-artefact paths below resolve to `$REPO_ROOT/specs/<key>-*/...`.

### CI-failure recovery mode

When `CI_FAILURES` is supplied, load `$MAKATO_BUILD_ROOT/shared/ci-recovery.md` before the baseline. Select `CI_TASK_INDICES` even if those tasks are complete, or use the supplied `CI_RECOVERY_TASK` for a concrete CI-configuration/metadata repair. No selection means unresolved, never successful no-op.

For a supplied recovery task, retain the plan's hard constraints but do not require an original `mode: goal` task or alter `sub_tasks[]`. Run the existing BUILD → VERIFY RUNTIME → TEST → VERIFY phases against the diagnosed command; for docs/config/metadata, exercise the affected command or check rather than inventing source-wording tests. Existing goal tasks use plan-analyst as normal. In autonomous mixed-mode recovery, select only assigned goal tasks without a prompt.

Targeted CI failures are repair obligations, not an acceptable broken baseline. Read complete diagnostic files as needed. Leave source repairs uncommitted, return `data.resolved_checks`, `data.unresolved_checks` and local verification evidence; success requires every assigned failure resolved. The caller owns independent review, verification, push and remote CI confirmation. For a metadata-only repair, report the exact metadata mutation and its verification; never commit an empty change.

## Workflow

### Step 1 — Ask for work item key and load plan

If no `<work-item-key>` argument was passed (interactive mode): use `AskUserQuestion` with:
- question: `"Which work item are you implementing?"`
- options: `["Pass it directly, e.g. #123", "Run /build-implement-goal #123 to skip this prompt"]`

Load `@references/goal-driven-rules.md`. These rules govern all decisions in the goal loop
for this session.
**Do NOT load `references/goal-driven-rules.md` more than once per session.**

Resolve `SPEC_FOLDER` with
`python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"`,
then read `plan.md` from that folder. If the plan does not exist, stop and tell
the user to run `/refine` first.

Select this pass's tasks:

- `CI_RECOVERY_TASK` supplied — that task is the explicit selection.
- `CI_FAILURES` supplied — `CI_TASK_INDICES` as described in *CI-failure recovery mode*.
- `ASSIGNED_TASK_IDS` supplied — exactly those tasks. Read `sub_tasks[]` once via
  `"$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" read "<key>" "<ISSUE_NUMBER>"`.
  Each assigned task must be `mode: goal` and not yet `complete`, and each of its
  `blockedBy` entries must be `complete` there (an earlier pass of either mode) or
  assigned to this pass. Otherwise return R1 `failure` with
  `data.halt_code: "MISSING_INPUT"` naming the invalid IDs; never add or drop tasks.
- Otherwise — every `mode: goal` task. Interactive mode on a mixed plan asks whether
  to proceed with goal tasks only.

An empty selection in recovery mode returns failure with its unresolved CI failures;
ordinary mode stops with "All tasks in this plan are tdd-mode. Run /implement-tdd
instead." A nonempty selection continues below.

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"session","status":"start","data":{"goal_tasks":<N>,"tdd_tasks_skipped":<N>}}'
```

---

### Step 3 — Establish or reuse test baseline

Load `$MAKATO_BUILD_ROOT/shared/baseline-guide.md`. Before establishing a
baseline, dispatch gate-scout when `GATE_COMMANDS` is absent and retain its
exact `unit` command (including its runner prefix). Compute `branch` and
`base_sha` as specified in the guide. Reuse the latest matching implementation
baseline row when available; otherwise run the exact `unit` command once. Never
substitute a bare system-Python test command.

**Do NOT load the baseline guide more than once per session.**

If `unit` is `"not found"`, record a degraded-confidence skip and do not run a
test command. `BASELINE_FAILURES` is `data.failures` from the baseline row.

**Flakey test rule (ordinary implementation only)**: if a selected test fails
but no source code was changed between runs, re-run that single test once
before classifying. In CI recovery, follow ci-recovery.md instead: targeted
failures remain obligations, and the coordinator owns any diagnosed transient
rerun.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"failures":["<test id>",...],"branch":"<git branch>","base_sha":"<git merge-base HEAD $DEFAULT_REF>","cmd":"<exact unit command>","reused":<bool>,"source_ts":"<source row ts>"|null,"baseline_mode":"<proceed|halted>"}}
```

If a fresh baseline has pre-existing failures and the user chooses continue,
also log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"baseline-gate","status":"decision","data":{"pre_existing_failures":<N>,"user_choice":"continue"}}
```

---

### Step 4 — Read implementation context (via plan-analyst agent)

When `CI_RECOVERY_TASK` is supplied, use that exact diagnosed task and read its
target files/conventions; do not require plan-analyst to invent a goal task or
reject a plan containing only completed TDD tasks. Otherwise dispatch the
`plan-analyst` agent with:
- `PLAN_PATH`: absolute path to `plan.md` in the resolved spec folder
- `GLOSSARY_PATH`: absolute path to `glossary.md` in the resolved spec folder
- `REPO_ROOT`: absolute path to the target repository root
- `MAKATO_BUILD_ROOT`: absolute installed build-plugin root
The agent returns a structured Plan Analysis containing: task list with tdd/goal mode, layers detected, `tracer_required` flag, glossary constraints, and reusable codebase patterns. Use this output for all subsequent steps — do not re-read plan.md or glossary.md independently.

If the plan-analyst agent returns an error or empty task list: HALT with `errors: ["PLAN_ANALYST_FAILED: <agent error message>"]`. Do not attempt to infer task structure from plan.md directly — a failed analysis means the plan structure is ambiguous and the session must not proceed.

If `prototype.html` exists in the resolved spec folder: note it. It is the visual target for UI tasks in the BUILD phase. Read its structure to understand the intended component layout and interactions.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"load-context","status":"ok","data":{"prototype":<true|false>,"grill_context":<true|false>}}
```

---

### Step 5 — Execute per-task goal loop (autonomous)

Repeat for each selected task in plan order (dependencies first). Each task runs all four phases before
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
**Do NOT load `references/post-impl-test-guide.md` more than once per session.**

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

Run only the targeted tests: tests written in TEST plus existing test files
that directly exercise the task's changed production files. Use gate-scout's
`unit` command restricted to those paths, or its `integration` command
restricted to those paths for the task's own integration-lane tests (for
example, a migration test requiring the test database). A selected test
failing outside `BASELINE_FAILURES` is a new failure; zero new failures is the
gate.

Apply the same fix-vs-escalate threshold as in VERIFY RUNTIME. If fixing a
failure requires changing the implementation approach, escalate to the user
and recommend `/refine`.

Log:
```
{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"verify-task","task":<N>,"status":"ok","data":{"selected_tests":<N>,"new_failures":0}}
```

---

### Step 6 — Hand off to build-verify

Do not run a suite or coverage check here. If `design.md` in the resolved spec
folder specifies a coverage threshold, forward it as `COVERAGE_HINT`; otherwise
pass an empty string. `build-verify` owns whole-change verification and
coverage Gate 5.

Build a deduplicated `CHANGED_FILES` set from production files changed and test
files written by the selected goal tasks. Pass the Step 3 baseline result,
`BASELINE_FAILURES`, `CHANGED_FILES`, and `COVERAGE_HINT` to the downstream
`build-verify` dispatch.

---

### Step 7 — Log session end and hand off

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"session","status":"ok","data":{"goal_tasks":<N>,"tdd_tasks_pending":<N>}}'
```

**Session summary**: read `build.jsonl` for this story and collect all entries where `status` is `"warn"` or `"decision"`. Print a compact summary:

```
## Session Summary — <key>

Tasks completed: <N>/<total>
Targeted tests: 0 new failures
Decisions & warnings: <count>
<for each warn/decision entry: "  ⚠ <step>: <data summary in one line>">

```

If no warn/decision entries exist: print "No decisions or warnings logged — clean run."

Tell the user:
*"<N> goal tasks implemented; 0 new failures in targeted tests.*
*Pipeline remaining: `/build-simplify` → `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-simplify` to check for unnecessary complexity."*

If tdd-mode tasks remain in the plan:
*"Run `/build-implement-tdd` first for the remaining tdd tasks, then `/build-simplify`."*

---

## Anti-patterns

**NEVER write tests during the BUILD phase.**
WHY: Tests written before VERIFY RUNTIME will document broken behavior. Once a test is in the codebase asserting on a broken state, fixing the implementation causes a test failure — the test now appears to "fail the fix" and creates artificial pressure to weaken the acceptance criterion instead of completing the runtime fix.

**NEVER run the full suite, integration suite, or coverage inside goal tasks.**
WHY: Each task owns only its targeted tests; whole-change gates belong to
`build-verify`. Repeating broad test and coverage runs for every implementation
pass wastes CI-equivalent work, and running the complete integration lane
locally duplicates the consumer CI lane when CI owns it.

**NEVER loosen an acceptance criterion to avoid a VERIFY RUNTIME failure.**
WHY: The fix-vs-escalate threshold exists precisely because the temptation is to redefine success around what compiles. If the spec requires X and X is technically problematic, the plan is wrong — not the spec. Silently delivering Y while the AC still reads X creates an unfixable audit divergence that `diff-reviewer` will surface as a gap verdict, blocking the PR.

**NEVER re-read `plan.md` after dispatching `plan-analyst`.**
WHY: The plan-analyst agent is the sole reader of `plan.md` during a session. Re-reading it independently creates a divergence risk when `plan.md` is updated mid-session (rare but possible in concurrent PO-agent runs), and bypasses the glossary-constraint enrichment that only the agent applies.

**NEVER use `pwd` to derive `REPO_ROOT` in a worktree session.**
WHY: A per-run worktree is not always the selected target checkout; use
`MAKATO_TARGET_REPO_ROOT` when set or preserve common-dir sharing otherwise.

**NEVER skip the WORKTREE_PATH falsy-check in autonomous mode.**
WHY: In autonomous mode there is no user present to answer `AskUserQuestion`. If `WORKTREE_PATH` is empty and the falsy-check is skipped, Step 1 will invoke `AskUserQuestion` for the work-item-key, which blocks forever — the session deadlocks and the PO-agent loop stalls until the kill-switch TTL expires. The check must run before Step 1, not at Step 1.

**NEVER proceed past VERIFY RUNTIME with `status: "ok"` when compilation errors remain.**
WHY: A goal-mode test suite written against broken code is worse than no tests — it encodes the broken behavior as "passing" and will fail as soon as the runtime error is fixed. The entire value of the goal-driven cycle is that tests document *working* behavior, not aspirational behavior.

**NEVER apply `TEST_ORACLE` from the `build-implement-tdd` chain in this skill.**
WHY: `build-implement-goal` is intentionally excluded from the `TEST_ORACLE` propagation chain (TDD-only contract in `AGENTS.md`). Applying oracle scenarios here would create test stubs before VERIFY RUNTIME passes, violating the BUILD-first contract of goal-mode work.

## Autonomous Execution

Autonomous mode is activated per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` §
*Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key and session-end gates are bypassed per the rules above.
- **Log every bypass** to `build.jsonl` via
  `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"` with the `autonomous_bypass`
  event schema.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "status": "success | partial | failure",
  "summary": "<one-line summary>",
  "files_changed": ["<list of repo-relative paths changed>"],
  "tests_written": ["<list of test file paths written>"],
  "errors": [],
  "tool_calls_used": 0,
  "data": {
    "tasks_completed": 0,
    "completed_task_ids": [],
    "halt_code": null
  }
}
```

`agent` is `"build-implement-goal"`. On success, `summary` is
`"N goal tasks complete; 0 new failures in targeted tests."`.
`data.completed_task_ids` lists the plan IDs whose four phases passed in this
pass; `status: "success"` requires it to cover the whole selection
(`ASSIGNED_TASK_IDS` when supplied).

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `MISSING_PLAN`, `PLAN_ANALYST_FAILED`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.
