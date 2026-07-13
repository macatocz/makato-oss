---
name: build-implement-tdd
description: >-
  Execute a refined plan using TDD — RED failing tests, GREEN unit
  passing, INTEGRATE real dependencies, VERIFY full suite per task.
  Tracer bullet phase for multi-layer stories. Autonomous loop. Use
  after refine to implement-tdd a story plan, implement tdd tasks, or
  run the core build loop.
version: "1.10.0"
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

## Input

When dispatched by the PO-agent (`--autonomous` mode), this skill receives a context bundle containing at minimum:

- `<work-item-key>` — positional argument (e.g. `#123`, `GAP-085`).
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree the PO-agent owns. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). The skill MUST `cd "$WORKTREE_PATH"` before any `git`, `pytest`, or file-edit operation, and forward this value to every nested `coder` dispatch in Step 6.
- `--autonomous` — activation flag (also activated by `$AGENT_ID` or `task_id` bundle).

Optional fields (autonomous mode):

- `CI_FAILURE_LOG` — tail of `gh run view --log-failed` (≤ 4000 chars), forwarded by the PO-agent's CI-failure fix loop (Step 6a of `plugins/makato-orchestrate/agents/po-agent.md`). When present, activates *CI-failure recovery mode* — see § *CI-failure recovery mode* below. Absent on a normal first-pass dispatch.
- `PRIOR_LESSONS` — JSON array of top-3 lessons recalled by the PO-agent (GAP-015 / #37). May be empty; consumers MUST tolerate `[]` and a missing key identically. Forwarded verbatim to each per-task `coder` dispatch in Step 6 as advisory context.

When invoked by a developer at the prompt (interactive mode), `WORKTREE_PATH` is optional. If unset, the skill falls back to `git rev-parse --show-toplevel` of the current `$PWD` — the original developer-driven behaviour, unchanged. `CI_FAILURE_LOG` is never set in interactive mode.

### CI-failure recovery mode

When `CI_FAILURE_LOG` is present in the input bundle, the skill is being re-entered to fix a CI failure on a PR that was already pushed by a prior dispatch. The skill MUST:

1. Parse the failing test name(s) from `CI_FAILURE_LOG` (typical pytest/unittest patterns: `FAILED <path>::<test>`, `AssertionError`, `Traceback`). When the failing test maps to a known `mode: tdd` task in `plan.md` (match by `**Unit Test:**`/`**Integration Test:**` or `**Files:**` paths), restrict Step 6 to that task plus any task it blocks (transitively). When the log is ambiguous or matches no task, fall through to the full task walk — the baseline-failure gate in Step 3 will still bound work to actual failures.
2. Skip Step 5 (tracer bullet) entirely — the tracer is a multi-layer scaffold for greenfield stories, not for incremental CI fixes. A `warn` JSONL entry is logged: `{"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-skipped","status":"warn","data":{"reason":"ci-failure-recovery"}}`.
3. Forward `CI_FAILURE_LOG` to each selected coder dispatch as an additional input field of the same name. The coder reads it as advisory diagnostic context — it does not override the per-task `description` or test specs from `plan.md`.
4. Log a `decision` JSONL entry on entry so the audit trail records that this dispatch is a recovery rather than a fresh implementation walk:
   ```bash
   shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"ci-failure-recovery","status":"decision","data":{"log_tail_chars":<N>,"tasks_selected":[<indices>]}}'
   ```

All other contracts (workspace-isolation guard, baseline gate, blockedBy graph check, scout pre-flight, R1 envelope, workflow-state carve-out) are unchanged. The recovery mode is a subset of the normal walk, not a parallel path.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1 — Step 1 in interactive mode calls `AskUserQuestion` for the work-item-key prompt and in autonomous mode that prompt is bypassed, so the falsy-check must run at skill entry (before either branch of Step 1 begins) to prevent a deadlock against a prompt that can never resolve. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` so every subsequent `git`/`pytest`/file-edit lands in the correct working tree.

Spec-folder reads (`plan.md`, `build.jsonl` audit appends) operate on the MAIN checkout, not the worktree (`specs/` is gitignored). Resolve `REPO_ROOT` once at entry:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

`plan.md` and `build.jsonl` paths below resolve to `$REPO_ROOT/specs/<key>-*/...`. The `shared/build-log.sh` helper handles this for JSONL appends automatically; spec-artefact reads use `REPO_ROOT` explicitly.

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

**Optional batched flush** (#118 / `AUTONOMOUS-MODE.md` § *Batched logging*): the three Step 5 rows (`tracer-stub` → `tracer-test` → `tracer-verify`) emit in tight succession at the end of the tracer phase. Skills MAY accumulate them into a heredoc and flush once via `shared/build-log.sh "<key>" --batch` instead of three separate single-entry calls — that swaps three `bash` + `git rev-parse` + `find specs/` chains for one. The cross-step batching rule applies: do NOT carry rows past the next step boundary; a Step 5 failure before the flush would lose the audit trail.

### Step 6 — Execute RED → GREEN → INTEGRATE → VERIFY for each tdd task (via coder agent)

**Pre-flight: validate blockedBy graph.** Before dispatching any coder agent, perform a topological sort of all tdd tasks using their `blockedBy` fields. If a cycle is detected (Task A blocked by B, B blocked by A, or any longer chain), stop immediately:

> "Circular dependency detected in plan.md: Task <A> → Task <B> → … → Task <A>. Fix the `blockedBy` fields in `plan.md` to remove the cycle, then re-run `/build-implement-tdd`."

Only proceed once the dependency graph is confirmed acyclic.

For each `mode: tdd` task in topological order, dispatch the per-task `scout` agent first (GAP-013 / #29) — see § *Pre-flight scout dispatch* below — then dispatch the `coder` agent with:
- `TASK`: the task object (title, files, unit test spec, integration test spec, AC links, mode, blockedBy, commitMessage)
- `TASK_INDEX`: 1-based index of the task within the plan
- `STORY_KEY`: the work item key (e.g. DCP-1234)
- `JSONL_PATH`: absolute path to `build.jsonl` in the resolved spec folder
- `PLAN_CONTEXT`: the full Plan Analysis output from Step 4 (glossary constraints, layer classification, tracer_required flag, reusable patterns)
- `SCOUT_SUMMARY`: the `data` payload from the per-task scout dispatch (see § *Pre-flight scout dispatch*). Omit entirely when the scout returned `status: "failure"` — the fallback contract makes scout output advisory, not gating.
- `TRACER_TEST_NAME`: name of the tracer integration test if `tracer_required = true` and it was written in Step 5; otherwise omit
- `BASELINE_FAILURES`: pre-existing failure count from Step 3
- `REPO_ROOT`: absolute path to the target repository root
- `WORKTREE_PATH`: absolute filesystem path to the per-run git worktree (forwarded verbatim from this skill's input — see § *Input* and `AUTONOMOUS-MODE.md` § *WORKTREE_PATH*). The `coder` agent `cd`s into this path before its RED→GREEN→INTEGRATE→VERIFY cycle. In interactive mode without an enclosing PO-agent, forward the resolved `$(git rev-parse --show-toplevel)` so the agent's contract is identical in both modes.
- `CI_FAILURE_LOG`: forwarded verbatim when present in this skill's input bundle (see § *CI-failure recovery mode*). Omit when absent — the coder treats it as optional advisory diagnostic context, not a gate.
- `RECOMMENDED_SKILLS`: forwarded verbatim when the task object from `plan.md` carries a `recommended_skills[]` field (agent-skill-routing #146). When present and non-empty, the coder agent invokes each skill before Phase 1 RED (see `coder.md` § *Skill consultation prepend*). Omit this field from the dispatch bundle when the task's `recommended_skills` is absent — do NOT pass an empty array.
- `TEST_ORACLE`: forwarded verbatim when the Plan Analysis (from `plan-analyst`, Step 4) carries a non-empty `## Acceptance Test Oracle` section. Pass the whole section (all scenarios with their `(maps to AC-N)` annotations); the coder filters it to the task's own `**Satisfies:**` AC links and implements the matching scenarios as its RED tests (see `coder.md` § *Test oracle*). Omit this field from the dispatch bundle when the plan has no Acceptance Test Oracle section — do NOT pass an empty value. Source is the Plan Analysis output, never a re-read of `plan.md` or `stories.json`.

**blockedBy enforcement**: before dispatching a task, check its `blockedBy` list. Do not dispatch a task concurrently with any task whose index appears in its `blockedBy` list. A task blocked by Task N must wait until Task N's coder agent returns `status: complete` before being dispatched.

#### Pre-flight scout dispatch (GAP-013 / #29)

Before each `coder` dispatch, resolve the task's bundle rules via the
`inject-context` skill (`plugins/makato-build/skills/inject-context/SKILL.md`)
and dispatch the per-task `scout` agent (`plugins/makato-orchestrate/agents/scout.md`).
The scout is **advisory**, not a gate — a scout failure must never block
the coder dispatch.

1. **Resolve bundles.** Call the `inject-context` Python helper:
   `from inject_context import resolve_bundles; rules, warning = resolve_bundles(task['files'], yaml.safe_load(open('plugins/makato-build/config/context-bundles.yml')))`.
   On `BundleResolutionError` with `halt_code == "HALT-006"`: skip the
   scout entirely, log a `warn` JSONL entry (`step: "scout-skipped"`,
   `reason: "halt-006-bundle-config"`), and dispatch `coder` without
   `SCOUT_SUMMARY`. The HALT-006 propagates to the PO-agent through
   `knowledge-scout`'s pre-existing Step 0 path; this skill does not
   re-emit it.
2. **Dispatch scout** with: `TASK_DESCRIPTION` (the task's title +
   one-line elaboration verbatim from `plan.md`), `CHANGED_FILES` (the
   task's `**Files:**` list), `BUNDLE_RULES` (the `rules` list from step 1,
   with `{repo}` substituted), `REPO_ROOT`, `WORKTREE_PATH` (forwarded
   verbatim — the scout is read-only but resolves `CHANGED_FILES` relative
   to the worktree).
3. **Parse the scout R1 envelope** per `RETURN-CONTRACT.md` § Caller
   parsing rule (last fenced ` ```json ` block, `JSON.parse()`, assert
   `schema == "r1"`).
4. **Map scout R1 to coder input:**
   - `r1.status == "success"` — forward `r1.data` to coder as
     `SCOUT_SUMMARY`. Mirror the scout R1 to `build.jsonl` with
     `step: "r1"`, `data.scout_agent: "scout"`.
   - `r1.status == "partial"` — forward `r1.data` to coder, AND log a
     `warn` JSONL entry: `{"…","skill":"build-implement-tdd","story":"<key>","step":"scout-partial","status":"warn","data":{"task":<N>,"errors":<r1.errors>}}`.
   - `r1.status == "failure"` — do NOT forward `SCOUT_SUMMARY`. Log a
     `warn` JSONL entry: `{"…","skill":"build-implement-tdd","story":"<key>","step":"scout-skipped","status":"warn","data":{"task":<N>,"reason":<r1.errors[0]>}}`.
     The coder dispatch proceeds without scout context — this matches
     the GAP-013 fallback contract (`plugins/makato-orchestrate/agents/scout.md`
     § *Caller fallback contract*).
   - **R1 contract violation** (missing block, parse failure,
     `schema != "r1"`) — treat as `failure` per the table above. Per
     NEVER 6, do not retry the scout dispatch.

The scout dispatch is conditional on the `makato-orchestrate` plugin
being installed (the scout agent lives there). Detect via:

```bash
MAKATO_ORCH="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)/plugins/makato-orchestrate"
if [[ ! -f "$MAKATO_ORCH/agents/scout.md" ]]; then
  scout_dispatched=false  # consumer repo without makato-orchestrate; skip scout silently
fi
```

When the scout file is absent (the build pipeline is running standalone
without the orchestrator), skip Step 6's scout dispatch entirely and
proceed straight to the coder dispatch without `SCOUT_SUMMARY`. No
warning is logged — the build pipeline must remain operable in a
developer's hands without the orchestrate plugin present (mirrors the
guarded `workflow-state.sh patch` pattern at § Step 6 end of this skill).

The coder agent runs the full RED→GREEN→INTEGRATE→VERIFY cycle for the task and appends JSONL entries directly to JSONL_PATH.

**On coder result (R1 envelope parsing):**

The coder agent emits an R1 envelope as the final fenced ` ```json ` block in its message (see `plugins/makato-build/agents/RETURN-CONTRACT.md`). Parse the **last** `json`-fenced block via `JSON.parse()` — do not scrape the prose Output Format section. The R1 envelope is the authoritative contract.

Map `r1.status` to action:
- `r1.status == "success"` — task complete; run the cross-task regression sweep (see § *Cross-task regression sweep* below), then proceed to the next task. The prose Output Format remains for human inspection; the R1 envelope drives the loop.
- `r1.status == "partial"` — VERIFY did not reach zero new failures. Treat as soft failure: log a warn entry, then stop the loop unless `r1.data.new_failures` is explicitly within an acknowledged threshold for this story. Recommend `/build-simplify` to triage.
- `r1.status == "failure"` — structural escalation. The contents of `r1.errors[0]` (or `r1.summary` if empty) is the escalation reason. Stop the loop, report to user, recommend `/refine`.

If the R1 envelope cannot be parsed (missing block, invalid JSON, `schema != "r1"`): treat as `status: "failure"` with reason `"R1 contract violation"` and surface the raw message to the user for diagnosis.

After every coder dispatch (success or otherwise), mirror the R1 envelope into `build.jsonl` so the audit trail captures the full machine contract verbatim:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"r1","status":"<r1.status>","task":<TASK_INDEX>,"data":<entire-r1-envelope-object>}'
```

#### Cross-task regression sweep

After a successful coder R1 and after mirroring it to `build.jsonl`, run the accumulated prior-task test sweep before patching workflow-state or dispatching the next task.

**Initialization**: before the first task dispatches, initialize an empty list:
`ACCUMULATED_TEST_FILES=()` — this is a session-scoped in-memory list, carried as a variable across all task iterations in this outer loop.

**Per-task sweep logic** (runs on every `r1.status == "success"` result):

1. **Snapshot prior tests** — capture the current `ACCUMULATED_TEST_FILES` as `ACCUMULATED_PRIOR_TEST_FILES` (the tests from tasks 1…N-1). This snapshot is what the sweep runs against for task N.

2. **Guard** — if `ACCUMULATED_PRIOR_TEST_FILES` is empty (task 1 has no prior tasks), skip the sweep entirely and go directly to step 4. No JSONL entry is emitted for the skip.

3. **Run sweep** — execute the unit test command (from `gate-scout` output, already available via `PLAN_CONTEXT`) with the accumulated prior-task test files as explicit arguments:
   ```
   <unit_command> <ACCUMULATED_PRIOR_TEST_FILES[0]> <ACCUMULATED_PRIOR_TEST_FILES[1]> …
   ```
   Count the sweep failure count. Compare against `BASELINE_FAILURES` (from Step 3):
   - **Zero new failures** (`sweep_failures − BASELINE_FAILURES == 0`): sweep passes.
     Flush to `build.jsonl` via `shared/build-log.sh`:
     ```bash
     shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"cross-task-verify","status":"ok","task":<TASK_INDEX>,"data":{"sweep_tests":<N>,"new_failures":0}}'
     ```
     You may batch-flush the `r1` mirror entry and this `cross-task-verify` entry together using `shared/build-log.sh "<key>" --batch` (see `AUTONOMOUS-MODE.md` § *Batched logging*) to minimize overhead.
   - **New failures detected** (`sweep_failures > BASELINE_FAILURES`): apply the fix-vs-escalate threshold:
     - *Fixable*: the regression is a straightforward consequence of the current task's changes. Fix the code in place, re-run the sweep, emit the JSONL on pass. Do not proceed until the sweep clears.
     - *Structural*: cannot fix without changing the implementation approach. Emit:
       ```bash
       shared/build-log.sh "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"cross-task-verify","status":"error","task":<TASK_INDEX>,"data":{"sweep_tests":<N>,"new_failures":<M>}}'
       ```
       Stop the outer loop. Return R1 `status:"failure"` with `summary:"Cross-task regression detected at task <TASK_INDEX>: <M> new failure(s) in prior-task tests"`. Recommend `/refine`.

4. **Accumulate** — after the sweep passes (or was skipped for task 1), add `r1.tests_written` to `ACCUMULATED_TEST_FILES` using set semantics (deduplicate by exact path). Tasks with an empty `tests_written:[]` contribute nothing.

   ```
   for path in r1.tests_written:
     if path not in ACCUMULATED_TEST_FILES:
       ACCUMULATED_TEST_FILES.append(path)
   ```

   The ordering (snapshot before sweep, accumulate after sweep) ensures the sweep for task N tests tasks 1…N-1 only — never task N's own tests.

5. **Continue** — proceed to the `workflow-state.sh patch` call and next-task dispatch as before.

When `r1.status == "success"`, also patch workflow-state so the PO-agent (GAP-006) can resume from accurate task state without re-parsing `build.jsonl`. The call is guarded — it skips silently when running in a consumer repo without the `makato-orchestrate` plugin present:

```bash
MAKATO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)/plugins/makato-orchestrate"
if [[ -x "$MAKATO_ROOT/shared/workflow-state.sh" ]]; then
  "$MAKATO_ROOT/shared/workflow-state.sh" patch "<key>" "<issue>" ".sub_tasks[$((TASK_INDEX-1))].status" '"complete"'
  "$MAKATO_ROOT/shared/workflow-state.sh" patch "<key>" "<issue>" ".sub_tasks[$((TASK_INDEX-1))].agent_result" '<r1-envelope-as-json-literal>'
fi
```

`<issue>` is threaded from the PO-agent context bundle (see `WORKTREE_PATH` /
`ISSUE_NUMBER` inputs in § *Input*) — post-#173 the state file is per-issue
(`workflow-state-<issue>.json`) so every mutating call must supply it.

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
