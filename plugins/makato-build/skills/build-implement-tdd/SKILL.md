---
name: build-implement-tdd
description: >-
  Execute refined plans with targeted RED and GREEN test commands per task.
  Build-review and build-verify own whole-change verification, including the
  full suite, integration suite, coverage, and repo-wide lint. Tracer bullet
  for multi-layer stories. Autonomous loop. Use after refine to implement a
  story plan or run the core build loop.
version: "1.16.0"
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
- `ASSIGNED_TASK_IDS` — JSON array of 1-based plan task indices the PO-agent assigns to this pass (#153). When present it is the complete selection; see Step 1.
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

**NEVER run or acknowledge a coverage gate in this skill.** `build-verify` owns
coverage Gate 5 and enforces HALT-002 when coverage is below threshold. Carry
the Step 3 baseline and changed-file set to that gate; do not run coverage or
emit a bypass marker here.

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

When `ASSIGNED_TASK_IDS` is supplied, select exactly those tasks. Read `sub_tasks[]` once via `"$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" read "<key>" "<issue>"`. Each assigned task must be `mode: tdd` and not yet `complete`, and each of its `blockedBy` entries must be `complete` there (an earlier pass of either mode) or assigned to this pass. Otherwise stop before Step 2 and return R1 `failure` with `data.halt_code: "MISSING_INPUT"` naming the invalid IDs; never add or drop tasks.

Without `ASSIGNED_TASK_IDS`, extract all tasks where `mode: tdd`. If none exist: stop and tell the user all tasks are goal-mode — run `/implement-goal` instead. If the plan is mixed mode: note the goal-mode tasks and confirm scope with the user — "Tasks [N, M] are goal-mode and will be skipped here — run /implement-goal for those after this session."

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

Also skip it when any plan task is already `complete` in workflow-state (a later scheduled pass or a resumed run): stubs would replace accepted implementation. Log `step:"tracer-skipped", status:"warn", data:{reason:"prior-tasks-complete"}` and omit `TRACER_TEST_NAME` from coder dispatches.

Load @references/tdd-cycle-rules.md — the Tracer Bullet Phase section governs all decisions in this step.

Identify the topmost layer in the plan. Tie-break order: ui > controller > service > repository > persistence. If none of these standard layers are detected (e.g. microservice, event-driven, CLI tool), use the public entry point of the module as the topmost layer.

#### TRACER STUB — Write thin stubs for all non-topmost layers

For each non-topmost layer (working bottom-up), write a stub at the exact file path listed in that layer's task `**Files:**` field. Follow stub rules from `tdd-cycle-rules.md` (compiles, returns hardcoded valid value, carries `// TRACER STUB — replaced by Task <N> implementation`, no logic).

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-stub","status":"ok","data":{"stubs_written":<N>}}'`

#### TRACER TEST — Write one end-to-end integration test

Write one integration test in the topmost layer's test file following the
tracer integration test rules from `tdd-cycle-rules.md`. Validate it only in
the targeted check below.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-test","status":"ok","data":{"tracer_test_file":"<path>","tracer_test_name":"<name>","layers_covered":<N>}}'`

#### TRACER TEST CHECK — Targeted test

Build one targeted command from `GATE_COMMANDS`, preserve its runner prefix,
and run only the tracer integration test. It must pass before proceeding.
Apply the fix-vs-escalate threshold from `tdd-cycle-rules.md`.

Run: `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"…","skill":"build-implement-tdd","story":"<key>","step":"tracer-targeted-test","status":"ok","data":{"tracer_test_file":"<path>","tracer_test_name":"<name>","command":"<targeted command>","targeted_tests":1}}'`

**Optional batched flush** (#118 / `AUTONOMOUS-MODE.md` § *Batched logging*): the three Step 5 rows (`tracer-stub` → `tracer-test` → `tracer-targeted-test`) emit in tight succession at the end of the tracer phase. Skills MAY accumulate them into a heredoc and flush once via `"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" --batch` instead of three separate single-entry calls — that swaps three `bash` + `git rev-parse` + `find specs/` chains for one. The cross-step batching rule applies: do NOT carry rows past the next step boundary; a Step 5 failure before the flush would lose the audit trail.

### Step 6 — Execute targeted RED → GREEN for each tdd task (via coder agent)

**Pre-flight: validate blockedBy graph.** Before dispatching any coder agent, perform a topological sort of the selected tasks using their `blockedBy` fields. If a cycle is detected (Task A blocked by B, B blocked by A, or any longer chain), stop immediately:

> "Circular dependency detected in plan.md: Task <A> → Task <B> → … → Task <A>. Fix the `blockedBy` fields in `plan.md` to remove the cycle, then re-run `/build-implement-tdd`."

Only proceed once the dependency graph is confirmed acyclic.

For each selected task in topological order, dispatch the per-task `task-file-scout` agent first (GAP-013 / #29) — see § *Pre-flight scout dispatch* below — then dispatch the `coder` agent with:
- `TASK`: the task object (title, files, unit test spec, integration test spec, AC links, mode, blockedBy, commitMessage)
- `TASK_INDEX`: 1-based index of the task within the plan
- `STORY_KEY`: the work item key (e.g. DCP-1234)
- `JSONL_PATH`: absolute path to `build.jsonl` in the resolved spec folder
- `PLAN_CONTEXT`: the full Plan Analysis output from Step 4 (glossary constraints, layer classification, tracer_required flag, reusable patterns)
- `SCOUT_SUMMARY`: the `data` payload from the per-task scout dispatch (see § *Pre-flight scout dispatch*). Omit entirely when the scout returned `status: "failure"` — the fallback contract makes scout output advisory, not gating.
- `TRACER_TEST_NAME`: name of the tracer integration test if `tracer_required = true` and it was written in Step 5; otherwise omit
- `REPO_ROOT`: absolute path to the target repository root
- `MAKATO_BUILD_ROOT`: absolute installed build-plugin root
- `WORKTREE_PATH`: absolute per-run worktree path, forwarded verbatim (see § *Input* and `AUTONOMOUS-MODE.md` § *WORKTREE_PATH*). The coder enters this path before its targeted RED and GREEN commands. In interactive mode without a PO-agent, forward the resolved `$(git rev-parse --show-toplevel)`.
- `CI_FAILURES`: forward the assigned structured diagnostics and full-log paths verbatim when present. The shared recovery contract makes every assigned failure a repair obligation, never an acceptable baseline.
- `RECOMMENDED_SKILLS`: forwarded verbatim when the task object from `plan.md` carries a `recommended_skills[]` field (agent-skill-routing #146). When present and non-empty, the coder agent invokes each skill before Phase 1 RED (see `coder.md` § *Skill consultation prepend*). Omit this field from the dispatch bundle when the task's `recommended_skills` is absent — do NOT pass an empty array.
- `TEST_ORACLE`: forwarded verbatim when the Plan Analysis (from `plan-analyst`, Step 4) carries a non-empty `## Acceptance Test Oracle` section. Pass the whole section (all scenarios with their `(maps to AC-N)` annotations); the coder filters it to the task's own `**Satisfies:**` AC links and implements the matching scenarios as its RED tests (see `coder.md` § *Test oracle*). Omit this field from the dispatch bundle when the plan has no Acceptance Test Oracle section — do NOT pass an empty value. Source is the Plan Analysis output, never a re-read of `plan.md` or `stories.json`.
- `PRIOR_LESSONS`: forwarded verbatim when present in this skill's input bundle (see § *Input* and `plugins/makato-orchestrate/agents/po-agent.md`). A JSON array of the top-3 lessons recalled by the PO-agent (GAP-015 / #37). The coder reads them as advisory context, equal in weight to `SCOUT_SUMMARY` — they never override `PLAN_CONTEXT.Hard Constraints` (see `coder.md` § *Prior lessons*). Omit this field from the dispatch bundle when it is absent or `[]` — do NOT pass an empty array. Consumers tolerate a missing key and `[]` identically.
- `GATE_COMMANDS`: authoritative gate-scout command map; forward it verbatim so the coder builds one targeted command for RED and GREEN while preserving its runner prefix.
- `PRIOR_R1`: when the coder R1 was partial or failed caller detail validation and its edits remain in the worktree, forward that envelope so the coder adopts its edits and re-proves RED, then runs GREEN. Omit otherwise. Edits do not survive into a later run: `worktree.sh create` refuses to resume a dirty worktree.
- `DETAILS_REQUEST`: with `PRIOR_R1`, list every missing or inaccurate detail the coder must provide in the continuation R1.

**Serial dispatch**: dispatch at most one coder per worktree at a time, in topological order; the next coder starts only after the previous coder's R1 has been handled. Concurrent coders would share one worktree, so their commands could observe each other's half-finished edits or duplicate targeted runs. `blockedBy` constrains the order: a task blocked by Task N is dispatched only after Task N's coder returns `status: "success"` in this pass, or when Task N is already `complete` in workflow-state.

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

Each coder writes the task's tests and production code, runs only targeted RED
and GREEN commands, and appends its phase evidence to `build.jsonl`.

**Verification ownership**: the coder's Task `context` MUST contain the single
paragraph in `$MAKATO_BUILD_ROOT/config/verification-ownership.md` verbatim,
without markdown fences. Read it from that file; never paraphrase it.

Under OMP, `run-skill.py` also appends the same policy to this run's system
prompt. Task text alone does not override that generic hand-off guidance.

**MANDATORY — load test conventions before first coder dispatch:** if the project has no
established test conventions discoverable from the codebase (i.e. `PLAN_CONTEXT` or
`SCOUT_SUMMARY` returns no test-style hints), load @references/test-writing-guide.md
before dispatching the first `coder` agent in this step, and include the relevant sections
as advisory context in `PLAN_CONTEXT`. Do NOT load for projects where the scout or
plan-analyst already surfaced test conventions — redundant loading wastes context budget.

**On coder result (R1 envelope parsing):**

The coder agent emits an R1 envelope as the final fenced ` ```json ` block in its message (see `plugins/makato-build/agents/RETURN-CONTRACT.md`). Parse the **last** `json`-fenced block via `JSON.parse()` — do not scrape the prose Output Format section. The R1 envelope is the authoritative contract.

Validate each TDD R1 before accepting its status. `success` requires
`phases_executed` to contain both `"red"` and `"green"`, complete mandatory
`data.details`, RED and GREEN command entries with exit codes and results, and
`changes` that match the actual worktree. A valid `success` completes the task;
do not run a regression sweep or other tests in the coordinator.

`partial` means RED ran but GREEN was not reached or targeted tests still fail.
For either `partial` or invalid/missing details, dispatch exactly one fresh
coder continuation for the same `TASK_INDEX`, with the full Step 6 bundle and
`PRIOR_R1` set to the previous envelope. Add
`DETAILS_REQUEST: <missing items>` when details are missing, command evidence is
absent, or changed paths disagree with the worktree. The continuation must
re-prove RED and run GREEN. Mirror its R1 and apply the same checks; if it is
still partial or has invalid details, stop with `CODER_UNVERIFIED` or
`CODER_DETAILS_INCOMPLETE`. Never run coder tests on its behalf.

`failure` means a structural escalation or `VERIFICATION_UNAVAILABLE`. Use
`r1.errors[0]` (or `r1.summary` if empty) as the reason, stop the loop, report
the blocker, and recommend `/refine` for structural issues.

If the R1 envelope cannot be parsed (missing block, invalid JSON, `schema != "r1"`): treat as `status: "failure"` with reason `"R1 contract violation"` and surface the raw message to the user for diagnosis.

After every coder dispatch (success or otherwise), mirror the R1 envelope into `build.jsonl` so the audit trail captures the full machine contract verbatim:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"r1","status":"<r1.status>","task":<TASK_INDEX>,"data":<entire-r1-envelope-object>}'
```


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

### Step 7 — Hand off to build-verify

Carry the Step 3 baseline result forward for `build-verify`. Build a
deduplicated `CHANGED_FILES` set from the tracer stub and test paths written in
Step 5, plus `files_changed` and `tests_written` from every accepted coder R1.
Pass the Step 3 baseline and `CHANGED_FILES` to the downstream
`build-verify` dispatch. Do not run a suite, integration suite, coverage, or
repo-wide lint in this coordinator; `build-review` and `build-verify` own
whole-change verification.

### Step 8 — Log session end and hand off

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO-8601-ms>","skill":"build-implement-tdd","story":"<key>","step":"session","status":"ok","data":{"tdd_tasks":<N>,"completed_task_ids":[<IDs>],"goal_tasks_pending":<N>}}'
```

**Autonomous R1.** End with an R1 envelope (`agent: "build-implement-tdd"`) per `RETURN-CONTRACT.md`. `data.completed_task_ids` lists every plan ID accepted in this pass; `status: "success"` requires it to cover the whole selection (`ASSIGNED_TASK_IDS` when supplied).

**Session summary**: read `build.jsonl` for this story and collect all entries where `status` is `"warn"` or `"decision"`. Print a compact summary:

```
## Session Summary — <key>
Tasks completed: <N>/<total>
Decisions & warnings: <count>
<for each warn/decision entry: "  ⚠ <step>: <data summary in one line>">
```

If no warn/decision entries exist: print "No decisions or warnings logged — clean run."

Tell the user:
"<N> TDD tasks implemented with targeted RED/GREEN evidence; whole-change verification is pending `/build-verify`.
Pipeline remaining: `/build-simplify` → `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`
Next: run `/build-simplify` to check for unnecessary complexity, or `/build-implement-goal` if goal-mode tasks remain."
