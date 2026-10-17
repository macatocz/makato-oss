---
name: build-implement-tdd
description: >-
  Execute a refined plan using TDD — RED failing tests, GREEN unit
  passing, INTEGRATE real dependencies, VERIFY full suite per task.
  Tracer bullet phase for multi-layer stories. Autonomous loop. Use
  after refine to implement-tdd a story plan, implement tdd tasks, or
  run the core build loop.
version: "1.14.0"
argument-hint: "[work-item-key]"
allowed-tools: ["Bash", "Read"]
metadata:
  last_updated: "2026-10-16"
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
- `ISSUE_NUMBER` — GitHub issue number (integer, no leading zeros). Used by the workflow-state patch call at the end of Step 6 (`workflow-state-<issue>.json`). **Mandatory in autonomous mode** when `makato-orchestrate` is present; ignored in interactive mode.
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root. Resolve from
  `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` when the caller does
  not supply it; never infer it from the target repository CWD.
- `MAKATO_ORCHESTRATE_ROOT` — optional absolute orchestrate-plugin root supplied
  by the PO-agent. When absent, skip workflow-state integration; the scout root
  is resolved separately in Step 6 without probing `$REPO_ROOT/plugins/...`.
- `--autonomous` — activation flag (also activated by `$AGENT_ID` or `task_id` bundle).

Optional fields (autonomous mode):

- `CI_FAILURES` — structured failed-check diagnostics from `build-fix-ci`: head SHA, check identity, run/job/attempt, summary and private full-log path. Activates CI recovery; never replace these with a truncated log tail.
- `CI_TASK_INDICES` — selected task indices in this skill's mode, including previously completed tasks that now require repair.
- `PRIOR_LESSONS` — JSON array of top-3 lessons recalled by the PO-agent (GAP-015 / #37). May be empty; consumers MUST tolerate `[]` and a missing key identically. Forwarded verbatim to each per-task `coder` dispatch in Step 6 as advisory context.
- `GATE_COMMANDS` — optional gate-scout R1 `data` command map. When absent,
  dispatch gate-scout once before the baseline and use its `unit`,
  `integration`, `coverage`, and `python_runner_prefix` fields verbatim.

When invoked interactively, `WORKTREE_PATH` is optional and defaults to the current repository. CI recovery inputs are supplied by `build-fix-ci`, not inferred from ordinary task completion.

### CI-failure recovery mode

When `CI_FAILURES` is supplied, load `$MAKATO_BUILD_ROOT/shared/ci-recovery.md` before the baseline. It overrides the ordinary broken-baseline and completed-task rules only for the supplied CI failures.

1. Use `CI_TASK_INDICES` to select affected TDD tasks, even when already complete. If absent, map the full diagnostics to the plan through `plan-analyst`; do not silently walk unrelated tasks or claim success for an empty selection. Return unresolved failures to `build-fix-ci` if none map to this mode.
2. Skip Step 5 (tracer bullet). Log `step:"tracer-skipped", status:"warn", data:{reason:"ci-failure-recovery"}`; existing implementation must never be replaced with a fresh scaffold.
3. Forward `CI_FAILURES` to each selected coder alongside the unchanged task, scout, constraints and gate commands. Read full diagnostic files when summaries are insufficient. Do not treat CI failures as an acceptable pre-existing baseline.
4. Log `step:"ci-recovery", status:"start"` with selected indices and check identities (no raw logs). Finish with `data.resolved_checks`, `data.unresolved_checks` and actual local verification evidence. Only every assigned failure repaired and locally verified permits success; the caller independently verifies remote CI.

All workspace, blockedBy, scout and R1 contracts still apply. This skill leaves repairs uncommitted; `build-fix-ci` owns review, verification and push.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` before Step 1 — Step 1 in interactive
mode calls `AskUserQuestion` for the work-item-key prompt and in autonomous
mode that prompt is bypassed, so the falsy-check must run at skill entry.
In autonomous mode an empty `WORKTREE_PATH` is a HALT with
`errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in
interactive mode the guard falls back to `git rev-parse --show-toplevel`. After
resolution, `cd "$WORKTREE_PATH"` so every subsequent git/test/file-edit lands
in the correct working tree.

Spec-folder reads and audit appends use the selected target root when
`MAKATO_TARGET_REPO_ROOT` is set, otherwise the common-dir fallback.

```bash
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)}"
```

`plan.md` and `build.jsonl` paths below resolve to `$REPO_ROOT/specs/<key>-*/...`. The `shared/build-log.sh` helper handles this for JSONL appends automatically; spec-artefact reads use `REPO_ROOT` explicitly.

## Anti-patterns

A dedicated list of failure modes this skill has encountered in production. Each NEVER has an
explicit WHY — these are the non-obvious ones.

**NEVER re-read `plan.md` or `glossary.md` after Step 4.** The `plan-analyst` agent is the
sole reader of those files — it returns a structured Plan Analysis that Step 4 stores as
`PLAN_CONTEXT`. Re-reading independently produces an inconsistent second parse, and any
ambiguity in `plan.md` prose will be resolved differently the second time. If you need a
field that the Plan Analysis did not surface, that is a gap in `plan-analyst` — file an
issue, do not bypass the contract.

**NEVER scrape the prose `Output Format` section of an R1 message.** The skill contract
specifies the last fenced ` ```json ` block as the authoritative source. The prose summary is
for human inspection only; its field names and structure may differ from the envelope (they
deliberately use a different style). Parsing prose leads to silent field mismatches when the
coder's summary diverges from the machine envelope.

**NEVER pass an empty array for `RECOMMENDED_SKILLS`, `TEST_ORACLE`, `SCOUT_SUMMARY`, or
`PRIOR_LESSONS`.** All four fields use "omit when absent" semantics — the coder and scout
agents tolerate a missing key, but an empty array can trigger type-coercion or no-op branches
that differ by agent version. Omit the field entirely; do not pass `[]`.

**NEVER retry a failed `task-file-scout` dispatch.** Scout failure is classified as an
advisory miss — the coder proceeds without `SCOUT_SUMMARY`. Retrying triggers the NEVER 6
anti-runaway rule and adds latency for zero gain, since a scout that fails once on the same
inputs will fail again. Log the miss and move on.

**NEVER run the tracer bullet step (Step 5) in CI-failure recovery mode.** The tracer is a
multi-layer scaffold for greenfield architectures; the CI-failure recovery path re-enters a
story that already has real implementation. Running the tracer a second time would overwrite
real code with hardcoded stubs. The recovery mode is explicitly a subset of the normal walk
(`ci-failure-recovery` decision JSONL is the gate). See § *CI-failure recovery mode*.

**NEVER acknowledge a coverage miss silently in autonomous mode.** No human is at the prompt.
Inventing an acknowledgement to continue is a contract violation that bypasses `build-verify`
Gate 5 (`HALT-002`). Log `threshold_met:false`, emit the `log-bypass.sh` marker, and defer
to Gate 5 — that is the authoritative coverage enforcement point.

**NEVER dispatch tasks outside topological order.** Even when two tasks appear independent,
the `blockedBy` graph in `plan.md` encodes constraints the user set during refinement. Out-of-
order dispatch creates file conflicts and can produce GREEN tests that pass on stub data from
a task that hasn't run yet. Topo-sort first, enforce strictly.

**NEVER patch `workflow-state.json` unconditionally.** The patch is guarded on both the
`makato-orchestrate` plugin being present AND `r1.status == "success"`. Patching on
`partial`/`failure` would record false task completion in the PO-agent's state machine,
causing the outer loop to skip the failed task on the next dispatch.

**Do NOT load `references/test-writing-guide.md` unless dispatching a coder in Step 6 for
a story with no established test conventions.** Do NOT load
`references/tdd-cycle-rules.md` outside Steps 1 and 5. Do NOT load the baseline
guide outside Step 3.

### Step 1 — Ask for work item key and load plan

Ask: "Which work item are you implementing? (e.g. #123, or pass it directly: `/makato-build:build-implement-tdd #123`)" — or use the passed argument directly.

Load @references/tdd-cycle-rules.md. These rules govern all decisions in the TDD loop for this session.

Resolve `MAKATO_BUILD_ROOT` from the installed-plugin-root contract in
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`, then resolve `SPEC_FOLDER` with
`"$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"`. Read
`plan.md` from that resolved folder. If it does not exist: stop and tell the
user to run `/refine` first.

Extract all tasks where `mode: tdd`. If none exist: stop and tell the user all tasks are goal-mode — run `/implement-goal` instead.

If the plan is mixed mode: note the goal-mode tasks and confirm scope with the user — "Tasks [N, M] are goal-mode and will be skipped here — run /implement-goal for those after this session."

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"session","status":"start","data":{"tdd_tasks":<N>,"goal_tasks_skipped":<N>}}'
```

### Step 3 — Establish test baseline

Load `$MAKATO_BUILD_ROOT/shared/baseline-guide.md`. Follow its instructions to
establish the baseline and handle the broken baseline gate.

If `GATE_COMMANDS` was not supplied, dispatch the registered `gate-scout`
agent once with `REPO_ROOT` and `COVERAGE_HINT`, parse its R1 `data`, and store
the command map for this session. Run the exact `data.unit` command (including
`python_runner_prefix`) for the baseline. If `data.unit` is `"not found"`,
record a degraded-confidence skip; never substitute a bare `pytest` command.
Forward the same map to every coder dispatch.

**Flakey test rule (ordinary implementation only)**: if a test fails but no source code was changed between runs, re-run that single test once before classifying. In CI recovery, follow ci-recovery.md instead: targeted failures remain obligations, and the coordinator owns any diagnosed transient rerun.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"baseline_mode":"<proceed|halted>"}}'`

If `pre_existing_failures > 0` and user chose continue, also log a decision entry:
`"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"baseline-gate","status":"decision","data":{"pre_existing_failures":<N>,"user_choice":"continue"}}'`

### Step 4 — Read implementation context (via plan-analyst agent)

Dispatch the `plan-analyst` agent with:
- `PLAN_PATH`: absolute path to `plan.md` in the resolved spec folder
- `GLOSSARY_PATH`: absolute path to `glossary.md` in the resolved spec folder
- `REPO_ROOT`: absolute path to the target repository root
- `MAKATO_BUILD_ROOT`: absolute installed build-plugin root
The agent returns a structured Plan Analysis containing: task list with tdd/goal mode, layers detected, `tracer_required` flag, glossary constraints, and reusable codebase patterns. Use this output for all subsequent steps — do not re-read plan.md or glossary.md independently.

**plan-analyst failure branch:** if the plan-analyst agent returns R1 `status:"failure"` or
its envelope cannot be parsed, stop immediately. Do not attempt to read `plan.md` directly
as a fallback — the sole-reader contract exists precisely because direct reads produce
ambiguous parses. Surface `r1.errors[0]` (or `"R1 contract violation"` on parse failure) to
the user and recommend re-running `/build-refine` to produce a fresh `plan.md` before
retrying this skill. Log:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"load-context","status":"error","data":{"reason":"<r1.errors[0]>"}}'
```

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"load-context","status":"ok","data":{"grill_context":<true|false>,"tracer_required":<true|false>}}'`

### Step 5 — Build tracer bullet (conditional: tracer_required = true)

Skip this step entirely if `tracer_required = false` (set in Step 4). Proceed directly to Step 6.

Load @references/tdd-cycle-rules.md — the Tracer Bullet Phase section governs all decisions in this step.

Identify the topmost layer in the plan. Tie-break order: ui > controller > service > repository > persistence. If none of these standard layers are detected (e.g. microservice, event-driven, CLI tool), use the public entry point of the module as the topmost layer.

#### TRACER STUB — Write thin stubs for all non-topmost layers

For each non-topmost layer (working bottom-up), write a stub at the exact file path listed in that layer's task `**Files:**` field. Follow stub rules from `tdd-cycle-rules.md` (compiles, returns hardcoded valid value, carries `// TRACER STUB — replaced by Task <N> implementation`, no logic).

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-stub","status":"ok","data":{"stubs_written":<N>}}'`

#### TRACER TEST — Write one end-to-end integration test

Write one integration test in the topmost layer's test file following the tracer integration test rules from `tdd-cycle-rules.md`. Run the test — it must pass before proceeding. Apply the fix-vs-escalate threshold from `tdd-cycle-rules.md`.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-test","status":"ok","data":{"tracer_test_file":"<path>","tracer_test_name":"<name>","layers_covered":<N>}}'`

#### TRACER VERIFY — Full suite gate

Run the full suite. Zero new failures allowed vs. the baseline from Step 3.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-verify","status":"ok","data":{"new_failures":0}}'`

**Optional batched flush** (#118 / `AUTONOMOUS-MODE.md` § *Batched logging*): the three Step 5 rows (`tracer-stub` → `tracer-test` → `tracer-verify`) emit in tight succession at the end of the tracer phase. Skills MAY accumulate them into a heredoc and flush once via `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" --batch` instead of three separate single-entry calls — that swaps three `bash` + `git rev-parse` + `find specs/` chains for one. The cross-step batching rule applies: do NOT carry rows past the next step boundary; a Step 5 failure before the flush would lose the audit trail.

### Step 6 — Execute RED → GREEN → INTEGRATE → VERIFY for each tdd task (via coder agent)

**Pre-flight: validate blockedBy graph.** Before dispatching any coder agent, perform a topological sort of all tdd tasks using their `blockedBy` fields. If a cycle is detected (Task A blocked by B, B blocked by A, or any longer chain), stop immediately:

> "Circular dependency detected in plan.md: Task <A> → Task <B> → … → Task <A>. Fix the `blockedBy` fields in `plan.md` to remove the cycle, then re-run `/build-implement-tdd`."

Only proceed once the dependency graph is confirmed acyclic.

For each `mode: tdd` task in topological order, dispatch the per-task `task-file-scout` agent first (GAP-013 / #29) — see § *Pre-flight scout dispatch* below — then dispatch the `coder` agent with:
- `TASK`: the task object (title, files, unit test spec, integration test spec, AC links, mode, blockedBy, commitMessage)
- `TASK_INDEX`: 1-based index of the task within the plan
- `STORY_KEY`: the work item key (e.g. DCP-1234)
- `JSONL_PATH`: absolute path to `build.jsonl` in the resolved spec folder
- `PLAN_CONTEXT`: the full Plan Analysis output from Step 4 (glossary constraints, layer classification, tracer_required flag, reusable patterns)
- `SCOUT_SUMMARY`: the `data` payload from the per-task scout dispatch (see § *Pre-flight scout dispatch*). Omit entirely when the scout returned `status: "failure"` — the fallback contract makes scout output advisory, not gating.
- `TRACER_TEST_NAME`: name of the tracer integration test if `tracer_required = true` and it was written in Step 5; otherwise omit
- `BASELINE_FAILURES`: pre-existing failure count from Step 3
- `REPO_ROOT`: absolute path to the target repository root
- `MAKATO_BUILD_ROOT`: absolute installed build-plugin root
- `WORKTREE_PATH`: absolute filesystem path to the per-run git worktree (forwarded verbatim from this skill's input — see § *Input* and `AUTONOMOUS-MODE.md` § *WORKTREE_PATH*). The `coder` agent `cd`s into this path before its RED→GREEN→INTEGRATE→VERIFY cycle. In interactive mode without an enclosing PO-agent, forward the resolved `$(git rev-parse --show-toplevel)` so the agent's contract is identical in both modes.
- `CI_FAILURES`: forward the assigned structured diagnostics and full-log paths verbatim when present. The shared recovery contract makes every assigned failure a repair obligation, never an acceptable baseline.
- `RECOMMENDED_SKILLS`: forwarded verbatim when the task object from `plan.md` carries a `recommended_skills[]` field (agent-skill-routing #146). When present and non-empty, the coder agent invokes each skill before Phase 1 RED (see `coder.md` § *Skill consultation prepend*). Omit this field from the dispatch bundle when the task's `recommended_skills` is absent — do NOT pass an empty array.
- `TEST_ORACLE`: forwarded verbatim when the Plan Analysis (from `plan-analyst`, Step 4) carries a non-empty `## Acceptance Test Oracle` section. Pass the whole section (all scenarios with their `(maps to AC-N)` annotations); the coder filters it to the task's own `**Satisfies:**` AC links and implements the matching scenarios as its RED tests (see `coder.md` § *Test oracle*). Omit this field from the dispatch bundle when the plan has no Acceptance Test Oracle section — do NOT pass an empty value. Source is the Plan Analysis output, never a re-read of `plan.md` or `stories.json`.
- `PRIOR_LESSONS`: forwarded verbatim when present in this skill's input bundle (see § *Input* and `plugins/makato-orchestrate/agents/po-agent.md`). A JSON array of the top-3 lessons recalled by the PO-agent (GAP-015 / #37). The coder reads them as advisory context, equal in weight to `SCOUT_SUMMARY` — they never override `PLAN_CONTEXT.Hard Constraints` (see `coder.md` § *Prior lessons*). Omit this field from the dispatch bundle when it is absent or `[]` — do NOT pass an empty array. Consumers tolerate a missing key and `[]` identically.
- `GATE_COMMANDS`: the authoritative gate-scout command map, including the
  runner prefix. Forward it verbatim so coder phases never fall back to
  system-Python commands.
- `PRIOR_R1`: when an earlier coder R1 in this run for this `TASK_INDEX` was
  unverified (see *On coder result*) and its edits remain in the worktree,
  forward that envelope verbatim so the coder adopts the edits and re-proves
  every phase. Omit it otherwise. Edits do not survive into a later run:
  `worktree.sh create` refuses to resume a dirty worktree.

**Serial dispatch**: dispatch at most one coder per worktree at a time, in topological order; the next coder starts only after the previous coder's R1 has been handled. Concurrent coders would share one worktree, so their phase runs would observe each other's half-finished edits and duplicate full-suite runs. `blockedBy` constrains the order: a task blocked by Task N is dispatched only after Task N's coder returns `status: "success"`.

#### Pre-flight scout dispatch (GAP-013 / #29)

Before each `coder` dispatch, resolve the task's bundle rules via the
`inject-context` skill and dispatch the registered `task-file-scout` agent by
name only when `SCOUT_ORCH_ROOT` (resolved below) is an existing installed
plugin root and `"$SCOUT_ORCH_ROOT/agents/task-file-scout.md"` exists. Never read an
agent file relative to this skill directory, the consumer repository, or the
current working directory. The scout is **advisory**, not a gate — a scout
failure must never block the coder dispatch.

1. **Resolve bundles.** Call the `inject-context` Python helper using only
   installed build-plugin paths:
   ```python
   import sys
   sys.path.insert(0, MAKATO_BUILD_ROOT + '/shared')
   from inject_context import resolve_bundles
   rules, warning = resolve_bundles(
       task['files'],
       yaml.safe_load(open(MAKATO_BUILD_ROOT + '/config/context-bundles.yml')),
   )
   ```
   The returned relative `rules` are target-repository paths; the scout
   resolves them beneath `REPO_ROOT` and only reads existing files. On
   `BundleResolutionError` with `halt_code == "HALT-006"`: skip the scout
   entirely, log a `warn` JSONL entry (`step: "scout-skipped"`,
   `reason: "halt-006-bundle-config"`), and dispatch `coder` without
   `SCOUT_SUMMARY`. The HALT-006 propagates to the PO-agent through
   `knowledge-scout`'s pre-existing Step 0 path; this skill does not re-emit it.
2. **Dispatch scout** with: `TASK_DESCRIPTION` (the task's title +
   one-line elaboration verbatim from `plan.md`), `CHANGED_FILES` (the
   task's `**Files:**` list), `BUNDLE_RULES` (the `rules` list from step 1,
   with `{repo}` substituted), `REPO_ROOT`, `WORKTREE_PATH` (forwarded
   verbatim — the scout resolves target files beneath this worktree), and
   `MAKATO_BUILD_ROOT` (forwarded so suite-owned contract references remain
   installed-root absolute). Missing predicted files are greenfield/advisory
   misses, not dispatch failures.
3. **Parse the scout R1 envelope** per
   `"$MAKATO_BUILD_ROOT/agents/RETURN-CONTRACT.md"` § Caller parsing rule
   (last fenced ` ```json ` block, `JSON.parse()`, assert `schema == "r1"`).
4. **Map scout R1 to coder input:**
   - `r1.status == "success"` — forward `r1.data` to coder as
     `SCOUT_SUMMARY`. Mirror the scout R1 to `build.jsonl` with
     `step: "r1"`, `data.scout_agent: "task-file-scout"`.
   - `r1.status == "partial"` — forward `r1.data` to coder, AND log a
     `warn` JSONL entry: `{"…","skill":"build-implement-tdd","story":"<key>","step":"scout-partial","status":"warn","data":{"task":<N>,"errors":<r1.errors>}}`.
   - `r1.status == "failure"` — do NOT forward `SCOUT_SUMMARY`. Log a
     `warn` JSONL entry: `{"…","skill":"build-implement-tdd","story":"<key>","step":"scout-skipped","status":"warn","data":{"task":<N>,"reason":<r1.errors[0]>}}`.
     The coder dispatch proceeds without scout context — this matches the
     GAP-013 fallback contract for the registered `task-file-scout` agent.
   - **R1 contract violation** (missing block, parse failure,
     `schema != "r1"`) — treat as `failure` per the table above. Per
     NEVER 6, do not retry the scout dispatch.

Resolve `SCOUT_ORCH_ROOT` from `MAKATO_ORCHESTRATE_ROOT`, or — when that is
unset, as in interactive sessions — with the canonical runtime resolver, which
checks the suite source sibling and the runner's plugin registry, never the
consumer repository's `plugins/`. Keep it a separate variable: the
workflow-state patch at the end of this step stays gated on the caller-supplied
`MAKATO_ORCHESTRATE_ROOT` only.

```bash
SCOUT_ORCH_ROOT="${MAKATO_ORCHESTRATE_ROOT:-}"
if [[ -z "$SCOUT_ORCH_ROOT" ]]; then
  SCOUT_ORCH_ROOT="$("$MAKATO_BUILD_ROOT/shared/runtime-context.sh" plugin-root makato-orchestrate 2>/dev/null || true)"
fi
```

When `SCOUT_ORCH_ROOT` is empty, is not a valid installed orchestrate-plugin
root, or lacks `agents/task-file-scout.md`, skip Step 6's scout dispatch
entirely and proceed straight to the coder dispatch without `SCOUT_SUMMARY`.
No warning is logged — absence is not a scout failure, and the build pipeline
remains operable without the orchestrate plugin. Reserve `scout-skipped` for
the HALT-006 and scout R1 `failure` paths above.

The coder agent runs the full RED→GREEN→INTEGRATE→VERIFY cycle for the task and appends JSONL entries directly to JSONL_PATH.

**Verification ownership**: the coder dispatch delegates phase execution
together with the edits. The dispatch prompt MUST tell the coder to run its
phase commands from `GATE_COMMANDS`. It MUST NOT carry edit-only, no-test,
"skip build/lint/tests mid-flight", or "caller verifies" instructions, whether
they come from caller context or from the harness's generic delegation
defaults. Those rules govern the coordinator's own redundant runs, never a
coder's phase gates. Do not run a coder's phase gates yourself to fill a gap:
coordinator test runs are never evidence for coder success. Under OMP,
`run-skill.py` appends the MAKATO VERIFICATION OWNERSHIP paragraph
(`config/verification-ownership.md`) to this run's system prompt; put it
verbatim in each coder dispatch's Task `context`. OMP renders that field into
the coder's system prompt, the level of its generic subagent hand-off
guidance, which task text alone does not override.

**MANDATORY — load test conventions before first coder dispatch:** if the project has no
established test conventions discoverable from the codebase (i.e. `PLAN_CONTEXT` or
`SCOUT_SUMMARY` returns no test-style hints), load @references/test-writing-guide.md
before dispatching the first `coder` agent in this step, and include the relevant sections
as advisory context in `PLAN_CONTEXT`. Do NOT load for projects where the scout or
plan-analyst already surfaced test conventions — redundant loading wastes context budget.

**On coder result (R1 envelope parsing):**

The coder agent emits an R1 envelope as the final fenced ` ```json ` block in its message (see `plugins/makato-build/agents/RETURN-CONTRACT.md`). Parse the **last** `json`-fenced block via `JSON.parse()` — do not scrape the prose Output Format section. The R1 envelope is the authoritative contract.

Map `r1.status` to action:
- `r1.status == "success"` (with all four phases in `r1.data.phases_executed` whenever that key is present) — task complete; run the cross-task regression sweep (see § *Cross-task regression sweep* below), then proceed to the next task. The prose Output Format remains for human inspection; the R1 envelope drives the loop.
- **Unverified result**: `r1.status == "partial"` where `verify` is missing from `r1.data.phases_executed` (or, when that key is absent, `r1.data.phase_reached != "verify"`), or a `success` with incomplete `phases_executed`. Do not resume the finished agent, and do not verify on its behalf. Dispatch exactly **one** fresh `coder` for the same `TASK_INDEX`, with the full Step 6 bundle plus `PRIOR_R1` set to this envelope. Log a `step: "coder-continuation"` `warn` entry with `data: {task, prior_status, phases_executed}`. Mirror the continuation's R1 and map it with these same rules. If the continuation is again unverified, treat it as `failure` with reason `"CODER_UNVERIFIED: task <N> phases not executed by coder after continuation"`.
- `r1.status == "partial"` with VERIFY executed — VERIFY did not reach zero new failures. Treat as soft failure: log a warn entry, then stop the loop unless `r1.data.new_failures` is explicitly within an acknowledged threshold for this story. Recommend `/build-simplify` to triage.
- `r1.status == "failure"` — structural escalation, or `VERIFICATION_UNAVAILABLE` when the coder could not run commands. The contents of `r1.errors[0]` (or `r1.summary` if empty) is the escalation reason. Stop the loop, report to user, recommend `/refine`.

If the R1 envelope cannot be parsed (missing block, invalid JSON, `schema != "r1"`): treat as `status: "failure"` with reason `"R1 contract violation"` and surface the raw message to the user for diagnosis.

After every coder dispatch (success or otherwise), mirror the R1 envelope into `build.jsonl` so the audit trail captures the full machine contract verbatim:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"r1","status":"<r1.status>","task":<TASK_INDEX>,"data":<entire-r1-envelope-object>}'
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
     Flush to `build.jsonl` via `"$MAKATO_BUILD_ROOT/shared/build-log.sh"`:
     ```bash
     "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"cross-task-verify","status":"ok","task":<TASK_INDEX>,"data":{"sweep_tests":<N>,"new_failures":0}}'
     ```
     You may batch-flush the `r1` mirror entry and this `cross-task-verify` entry together using `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" --batch` (see `AUTONOMOUS-MODE.md` § *Batched logging*) to minimize overhead.
   - **New failures detected** (`sweep_failures > BASELINE_FAILURES`): apply the fix-vs-escalate threshold:
     - *Fixable*: the regression is a straightforward consequence of the current task's changes. Fix the code in place, re-run the sweep, emit the JSONL on pass. Do not proceed until the sweep clears.
     - *Structural*: cannot fix without changing the implementation approach. Emit:
       ```bash
       "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"cross-task-verify","status":"error","task":<TASK_INDEX>,"data":{"sweep_tests":<N>,"new_failures":<M>}}'
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
if [[ -n "${MAKATO_ORCHESTRATE_ROOT:-}" ]] &&
   [[ -x "$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" ]]; then
  "$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" patch "<key>" "<issue>" ".sub_tasks[$((TASK_INDEX-1))].status" '"complete"'
  "$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" patch "<key>" "<issue>" ".sub_tasks[$((TASK_INDEX-1))].agent_result" '<r1-envelope-as-json-literal>'
fi
```

`<issue>` is threaded from the PO-agent context bundle (see `WORKTREE_PATH` /
`ISSUE_NUMBER` inputs in § *Input*) — post-#173 the state file is per-issue
(`workflow-state-<issue>.json`) so every mutating call must supply it.

**Note:** unconditional on autonomous mode (per `AUTONOMOUS-MODE.md` § Skills NOT in scope this skill always runs autonomously); conditional only on `r1.status == "success"`. On `partial` or `failure` the PO-agent reads the R1 envelope from `build.jsonl` and applies its own state mutation — that path lands in GAP-006 (#32).

For backward compatibility, also emit the existing step-specific log entry on escalation:
- `r1.status == "failure"` — `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"task-escalate","status":"warn","data":{"task":<N>,"reason":"<r1.errors[0] or r1.summary>"}}'`

If the coder agent applied a fix within the RED→GREEN cycle (a decision to fix rather than escalate), the coder appends its own decision entry to JSONL_PATH. The orchestrating skill does not need to re-log those decisions.

For stories where the tracer bullet ran (Step 5): each task's GREEN phase replaces the stub for its layer — the tracer integration test continues to pass throughout, evolving from stub-backed to real-implementation-backed. The coder agent enforces this via TRACER_TEST_NAME.

### Step 7 — Final suite verification and conditional coverage check

After all tdd tasks complete, run the full suite one final time.

If `design.md` specifies a coverage threshold: check **conditional coverage** (branch/condition coverage) — not line coverage. Conditional coverage verifies that every branch of every condition has been exercised, which is the meaningful signal for logic-heavy TDD work. Line coverage alone can be satisfied without testing all branches of conditional logic.

If conditional coverage is below threshold, first attempt to close the gap: identify uncovered branches and add targeted tests for those paths, then re-run. If coverage still falls short after that attempt, behaviour is **mode-dependent** — there is no silent-proceed path:

- **Autonomous mode** (`--autonomous`, `task_id` in the dispatch bundle, or `$AGENT_ID` exported — see `plugins/makato-build/AUTONOMOUS-MODE.md` § *Activation triggers*): a coverage miss CANNOT be "acknowledged" — no human is at the prompt to own the risk. Do NOT invent an acknowledgement. Log the miss with `threshold_met:false` (below) and hand off; the terminal coverage gate is **Gate 5** in `build-verify`, which enforces `HALT-002` on `threshold_met:false` before `build-push-to-git`. Step 7 defers to Gate 5 authoritatively — it neither blocks the intra-build flow itself nor waves the miss through. To make the deferral explicit rather than implied, also emit the audit marker:

  ```bash
  "$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-implement-tdd "<key>" coverage-floor defer-to-gate5 "$TRIGGER"
  ```

- **Interactive mode**: the gap may proceed only as an **explicitly acknowledged risk**, recorded as a structured entry — not a free-form "logged as known risk" note. Capture who acknowledged it and why, so the acknowledgement is auditable:

  ```bash
  "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"coverage-acknowledged","status":"decision","data":{"conditional_coverage":"<X>%","threshold":"<Y>%","acknowledged_by":"<user>","reason":"<one-line justification>"}}'
  ```

  An interactive acknowledgement is local to this build session; Gate 5 in `build-verify` still re-checks coverage independently and will HALT-002 if the miss is real.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"final-verify","status":"ok","data":{"tdd_tasks_complete":<N>,"conditional_coverage":"<X>%","threshold_met":<true|false>}}'`

### Step 8 — Log session end and hand off

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"session","status":"ok","data":{"tdd_tasks":<N>,"goal_tasks_pending":<N>}}'
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
