---
name: build-implement-goal
description: >-
  Execute goal-mode tasks from a refined plan — build first, verify
  runtime, write tests after. Autonomous. Use after refine for UI,
  config, or migration work, or when implement-goal tasks remain
  from a mixed plan.
version: "1.5.0"
model: opus
argument-hint: "[work-item-key]"
allowed-tools: [Bash]
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
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
- `RECOMMENDED_SKILLS` *(optional)* — JSON array of `"plugin:skill-id"` strings. When present at skill entry, apply the **skill consultation prepend** rule: before the BUILD phase of the *first* goal task, invoke each listed skill sequentially and apply any hard constraints or conventions surfaced. This field is also available per-task via the task's `recommended_skills[]` field in `plan.md` — per-task values override the skill-level bundle. Per-task rule: before the BUILD phase of each goal task, check the task's `recommended_skills` field from `plan.md`; if present and non-empty, invoke those skills before BUILD (agent-skill-routing #146). If absent on the task — proceed to BUILD directly.

When invoked by a developer interactively, `WORKTREE_PATH` is optional. If unset, the skill falls back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1 — Step 1 in interactive mode calls `AskUserQuestion` for the work-item-key prompt and in autonomous mode that prompt is bypassed, so the falsy-check must run at skill entry to prevent a deadlock against a prompt that can never resolve. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` so every BUILD / VERIFY RUNTIME / TEST / VERIFY command runs in the correct worktree.

Spec-folder reads (`plan.md`, `prototype.html`, `design.md`) operate on the MAIN checkout, not the worktree (`specs/` is gitignored). Resolve `REPO_ROOT` once at entry:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

Spec-artefact paths below resolve to `$REPO_ROOT/specs/<key>-*/...`.

## Workflow

### Step 1 — Ask for work item key and load plan

If no `<work-item-key>` argument was passed (interactive mode): use `AskUserQuestion` with:
- question: `"Which work item are you implementing?"`
- options: `["Pass it directly, e.g. #123", "Run /build-implement-goal #123 to skip this prompt"]`

Load `@references/goal-driven-rules.md`. These rules govern all decisions in the goal loop
for this session.
**Do NOT load `references/goal-driven-rules.md` more than once per session.**

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`). If the plan does not exist, stop and tell the user to run `/refine` first.

Extract all tasks where `mode: goal`. If none exist, stop and tell the user:
*"All tasks in this plan are tdd-mode. Run `/implement-tdd` instead."*

If the plan is mixed mode, note the tdd-mode tasks and present scope to the user with
`AskUserQuestion`:
- question: `"Tasks [N, M] are tdd-mode and will be skipped here. Proceed with goal tasks only?"`
- options: `["Yes — implement goal tasks now, I will run /implement-tdd separately", "No — cancel"]`

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-implement-goal","story":"<key>","step":"session","status":"start","data":{"goal_tasks":<N>,"tdd_tasks_skipped":<N>}}'
```

---

### Step 3 — Establish test baseline

Load @shared/baseline-guide.md. Follow its instructions to establish the baseline and handle the broken baseline gate.
**Do NOT load `shared/baseline-guide.md` more than once per session.**

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

If the plan-analyst agent returns an error or empty task list: HALT with `errors: ["PLAN_ANALYST_FAILED: <agent error message>"]`. Do not attempt to infer task structure from plan.md directly — a failed analysis means the plan structure is ambiguous and the session must not proceed.

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
met or the gap is explicitly acknowledged: use `AskUserQuestion` with
- question: `"Coverage threshold not met (<X>% vs required <Y>%). Acknowledge and log as known exception?"`
- options: `["Acknowledge — log as known exception and proceed", "Add more tests to meet threshold"]`

**Autonomous mode:** When running with `--autonomous`, skip the interactive coverage check. Log the bypass and proceed with available coverage.

A "yes" answer is logged as `status: "decision"` in `build.jsonl` and execution continues.

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

---

## Anti-patterns

**NEVER write tests during the BUILD phase.**
WHY: Tests written before VERIFY RUNTIME will document broken behavior. Once a test is in the codebase asserting on a broken state, fixing the implementation causes a test failure — the test now appears to "fail the fix" and creates artificial pressure to weaken the acceptance criterion instead of completing the runtime fix.

**NEVER loosen an acceptance criterion to avoid a VERIFY RUNTIME failure.**
WHY: The fix-vs-escalate threshold exists precisely because the temptation is to redefine success around what compiles. If the spec requires X and X is technically problematic, the plan is wrong — not the spec. Silently delivering Y while the AC still reads X creates an unfixable audit divergence that `diff-reviewer` will surface as a gap verdict, blocking the PR.

**NEVER re-read `plan.md` after dispatching `plan-analyst`.**
WHY: The plan-analyst agent is the sole reader of `plan.md` during a session. Re-reading it independently creates a divergence risk when `plan.md` is updated mid-session (rare but possible in concurrent PO-agent runs), and bypasses the glossary-constraint enrichment that only the agent applies.

**NEVER use `pwd` to derive `REPO_ROOT` in a worktree session.**
WHY: `pwd` inside a git worktree returns the worktree directory (e.g. `.claude/worktrees/<branch>`), not the main checkout. `specs/` is gitignored and lives only in the main checkout. Using `pwd` silently produces a path where `specs/<key>-*/plan.md` does not exist, causing a false "plan not found" error that wastes a full session before the root cause is discovered. Always use `git -C "$WORKTREE_PATH" rev-parse --git-common-dir` to derive `REPO_ROOT`.

**NEVER skip the WORKTREE_PATH falsy-check in autonomous mode.**
WHY: In autonomous mode there is no user present to answer `AskUserQuestion`. If `WORKTREE_PATH` is empty and the falsy-check is skipped, Step 1 will invoke `AskUserQuestion` for the work-item-key, which blocks forever — the session deadlocks and the PO-agent loop stalls until the kill-switch TTL expires. The check must run before Step 1, not at Step 1.

**NEVER proceed past VERIFY RUNTIME with `status: "ok"` when compilation errors remain.**
WHY: A goal-mode test suite written against broken code is worse than no tests — it encodes the broken behavior as "passing" and will fail as soon as the runtime error is fixed. The entire value of the goal-driven cycle is that tests document *working* behavior, not aspirational behavior.

**NEVER apply `TEST_ORACLE` from the `build-implement-tdd` chain in this skill.**
WHY: `build-implement-goal` is intentionally excluded from the `TEST_ORACLE` propagation chain (TDD-only contract in `AGENTS.md`). Applying oracle scenarios here would create test stubs before VERIFY RUNTIME passes, violating the BUILD-first contract of goal-mode work.

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key, coverage check, and session-end gates are bypassed per the rules above.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema.
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
    "halt_code": null
  }
}
```

`agent` is `"build-implement-goal"`. `summary` is `"N goal tasks complete; 0 new failures."` on success.

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `MISSING_PLAN`, `PLAN_ANALYST_FAILED`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.
