# R1 Return Contract — makato suite agents

> **Status**: Authoritative. Every agent in the makato suite that emits structured output MUST emit an R1 JSON block as the final element of its output. Callers MUST parse the last fenced ` ```json ` block in the agent message — no prose parsing.

## Why this exists

The build-* skills today read sub-agent output as prose ("Status: complete | blocked", "Findings: ..."). A future autonomous PO-agent (GAP-006 / #32) must `JSON.parse()` agent results to:

- update workflow-state without ambiguity
- gate retries on `status` rather than substring searches
- attribute token cost via `tool_calls_used`
- summarize a run by streaming `errors` arrays into a single triage list

The R1 envelope is the smallest schema that supports all of those use cases. Agents may still emit a human-readable prose summary before the R1 block — but the R1 block is the machine contract.

## R1 envelope schema

```json
{
  "schema": "r1",
  "agent": "<agent-name>",
  "status": "success | partial | failure",
  "summary": "<one-line synthesis, ≤ 240 chars>",
  "files_changed": ["<repo-relative path>", "..."],
  "tests_written": ["<repo-relative path>", "..."],
  "errors": ["<short error description>", "..."],
  "tool_calls_used": <integer ≥ 0>,
  "data": { /* agent-specific structured payload — see per-agent rules below */ }
}
```

### Field semantics

| Field | Required | Rule |
|---|---|---|
| `schema` | yes | Literal string `"r1"`. Versioning lever for future contract changes. |
| `agent` | yes | The agent's own `name:` from frontmatter (e.g. `"coder"`, `"diff-reviewer"`). |
| `status` | yes | One of three values. `success` = the agent's mission completed as specified. `partial` = the mission ran but a subset of the work could not be completed and is described in `errors` and `data`. `failure` = the mission could not be completed (structural blocker, missing input, escalation required). |
| `summary` | yes | One-line natural-language synthesis. Same content callers would otherwise scrape from the prose. |
| `files_changed` | yes | List of repo-relative file paths the agent modified or created. Empty list (`[]`) for read-only agents. Never `null`. |
| `tests_written` | yes | List of repo-relative test file paths the agent created or extended in this run. Empty list for non-coder agents. Never `null`. |
| `errors` | yes | List of short error/finding/blocker descriptions. Empty list (`[]`) when `status: "success"`. Each entry ≤ 240 chars. |
| `tool_calls_used` | yes | Integer ≥ 0. Best-effort count of tool invocations the agent made this run — used by the PO-agent's budget ceiling logic. If unknown, emit `0` (never omit the field). |
| `data` | yes | Agent-specific structured payload. Always an object (never `null`). See per-agent rules. |

### Emission rules

- The R1 block MUST be the **last** ` ```json ` fenced block in the agent's final message.
- The R1 block MUST be valid JSON parseable by `JSON.parse()` — no comments, no trailing commas, no JS expressions.
- Agents MAY emit additional ` ```json ` blocks earlier in the message (e.g. JSONL audit-log lines for human inspection). The contract is the **last** block.
- Agents MUST NOT emit prose after the R1 block.

### Caller parsing rule

```python
# Pseudocode for the canonical parse
last_json_block = re.findall(r"```json\n(.*?)\n```", agent_message, re.DOTALL)[-1]
r1 = json.loads(last_json_block)
assert r1["schema"] == "r1"
```

If `schema != "r1"` or the JSON does not parse: the caller MUST treat the dispatch as `status: "failure"` with `errors: ["R1 contract violation: <reason>"]`.

## Per-agent rules

### `coder.md` (model: sonnet, mutates files)

- TDD `status: "success"` — this coder ran targeted RED and GREEN commands;
  RED failed for the intended reason, every locally runnable targeted test
  passed in GREEN, and `data.details` is complete and matches the worktree.
- TDD `status: "partial"` — RED ran, but GREEN was not reached or targeted tests
  still fail. The caller dispatches one fresh continuation with `PRIOR_R1`.
- TDD `status: "failure"` — a structural blocker requires `/refine`
  (`data.escalation:"refine"`), or no targeted command can run
  (`VERIFICATION_UNAVAILABLE`).
- TDD `files_changed` — every production-code path actually edited or created.
- TDD `tests_written` — every new or extended test file path.
- TDD `errors` — `[]` on success; the concrete blocker on failure.
- TDD `data` keys: `{ "phase_reached":"red|green", "phases_executed":["red","green"], "targeted_tests":N, "escalation":"none|refine", "task_index":N, "details":{ "changes":[{"path":"<path>","summary":"<purpose>"}], "tests":[{"path":"<path>","covers":"<behavior>"}], "commands":[{"phase":"red|green","command":"<targeted command>","exit_code":N,"result":"<one-line result>"}], "assumptions":[], "risks":[], "deferred_to_verify":[] } }`. `targeted_tests` counts test cases in the targeted command.
- TDD `data.details` is mandatory and contains every actual changed path,
  added or changed test file, and targeted command run. `changes`, `tests`, and
  `commands` must not be empty; only `assumptions`, `risks`, and
  `deferred_to_verify` may be empty.
- A touched test that cannot run because a required external service is
  unavailable appears in `details.deferred_to_verify` with its reason; that
  alone does not fail the task. If no targeted command can run, return
  `failure` with `VERIFICATION_UNAVAILABLE: <reason>`.
- Every TDD R1 includes command evidence for RED and GREEN in
  `data.details.commands` when both commands ran. A caller does not accept
  missing details, missing RED or GREEN command evidence, or `changes` that
  disagree with the worktree. It dispatches exactly one fresh continuation for
  the same task with `PRIOR_R1` and `DETAILS_REQUEST: <missing items>`. A second
  detail-less R1 is `failure`. Caller test runs or earlier coder claims never
  substitute for this dispatch's evidence.
- Add `continued_from_partial: true` to `data` whenever the coder receives
  `PRIOR_R1`.

For a repair dispatch with `REVIEW_FINDINGS`, `VERIFY_FINDINGS`, or both, use
`data.mode:"review-repair"` for review-only and `"verify-repair"` for a
verification-loop dispatch. If both are supplied, report
`data.mode:"verify-repair"` and cover every supplied finding.
Both modes require `data.repair_round`, `data.repaired_findings`,
`data.unresolved_findings`, and `data.details:{per_finding:[{id,root_cause,
changes:[{path,summary}],verification:{command,exit_code,result}}],
assumptions:[],risks:[]}`. Include one `per_finding` result for every supplied
finding. For verify-repair, `VERIFY_FINDINGS` entries have `id`, `gate`,
`command`, `failing`, `excerpt`, and `log_path`. `success` requires every
supplied finding to be repaired and its verification command to pass.
Structural escalation is `partial` with
`data.escalation:"refine"`; unresolved findings remain listed. Coder success
does not approve a review or a verify gate: each caller independently
re-checks the repair.

Review-repair dispatches add the following (all additive; verify-repair is unchanged).
Repairs are invariant-level: each `REVIEW_FINDINGS` entry carries an `invariant` and
`sites`, and the coder fixes the invariant on every site.

- `per_finding[]` gains `sites_covered:[{file,line}]` and
  `sites_not_applicable:[{file,line,reason}]`. Every `sites` entry of the finding appears in one
  of them; the caller rejects a `per_finding` result that leaves a site unaccounted for.
- `per_finding[].needs_files:["<path>"]` — set when `ALLOWED_FILES` forbids an edit the
  finding needs. The finding stays in `unresolved_findings` and the caller runs one sequential
  continuation without `ALLOWED_FILES`. Without `ALLOWED_FILES` the field is omitted.
- A finding that no longer reproduces on the current tree is listed in `repaired_findings` with
  `root_cause:"already resolved: <how>"` and a `verification` command that proves it.
- `REPAIR_PHASE: plan` (default `apply`) makes no edits and runs no tests. R1 `status:"success"`,
  `files_changed` and `tests_written` are `[]`, and
  `data:{"mode":"review-repair","phase":"plan","repair_round":N,"plans":[{"id":"<finding id>",
  "invariant":"<rule>","sites":[{"file","line"}],"approach":"<how>",
  "compatibility":{"persisted_state":"<…>","versioning":"<…>","migration":"<…>"},
  "user_visible":"<…>","tests":["<test that proves the invariant>"]}]}`. The plan result has no
  `repaired_findings` or `unresolved_findings`. The caller confirms the worktree snapshot is
  unchanged; otherwise the plan phase is `failure`.
- `REPAIR_PHASE: apply` with `APPROVED_PLANS` (and optional `PLAN_CONSTRAINTS`) returns the
  usual repair R1 and lists any deviation from the approved plan in `data.details.assumptions`.

### `build-fix-ci` (skill, owns remote CI repair)

`data` contains `github_pr_number`, `head_sha`, `ci_status`
(`green|pending|blocked`), `repair_cycles`, `unresolved_checks`, and `halt_code`.
Only fresh current-head green with no unresolved checks permits `success`.
An interrupted wait/handoff is `partial`; blockers/timeouts/stalled repairs are
`failure`. PR creation and initial push propagate these fields and non-success
without losing the existing PR number. The PO-agent mirrors progress but never
runs a second CI loop. Existing-PR repair pushes return their head SHA without
invoking PR creation or nesting another CI coordinator.

### `diff-reviewer.md` (model: sonnet, read-only)

- `status: "success"` — review completed, zero CRITICAL and zero MAJOR findings.
- `status: "failure"` — review completed but CRITICAL or MAJOR findings remain; `build-review` dispatches the coder and re-reviews in both manual and autonomous mode.
- `status: "partial"` — review could not cover all CHANGED_FILES (e.g. a file could not be read).
- `files_changed: []`, `tests_written: []` (agent is read-only).
- `errors` — every CRITICAL and MAJOR finding as `"<file>:<line> — [<severity>][<category>] <description>"` (severity prefix lets the caller route CRITICAL vs MAJOR). Empty when `status: "success"`.
- `data` keys: `{ "pass_number": N, "review_scope": "full"|"delta", "critical_count": N, "major_count": N, "suggestion_count": N, "nitpick_count": N, "files_reviewed": N }` — `review_scope` is the scope actually applied (`full` after a widening); `files_reviewed` counts the files actually read.
- `data.lens` — the `LENS` the reviewer was dispatched with (`security-privacy`,
  `state-concurrency`, `error-handling`, `resources-performance` or `contract-ac`), or `null` for a
  whole-change review. A lens reviewer reports only its own concerns; only `contract-ac` emits
  `ac_verdicts`, the other lenses return `[]`.
- `data.findings[]` — every finding of every severity as `{"id":"<prior id>|new","severity",
  "category","lens","invariant","file","line","sites":[{"file","line","note"}],"evidence",
  "description"}`. For CRITICAL and MAJOR, `invariant` (one sentence stating the rule that must
  hold) and `sites` (every place, changed or not, where it must hold; at least one, the primary
  location included) are mandatory; `build-review` rejects a blocking finding without them. A
  re-raised prior finding keeps its `id`; a new one uses `"new"`. `errors[]` stays as above, so
  `build-verify` and other `errors[]` consumers are unaffected.
- `REVIEW_MODE: repair-plan` (inputs `REVIEW_FINDINGS` + `REPAIR_PLANS`; default `diff`) reviews
  the coder's plans, not the diff:
  `data:{"review_mode":"repair-plan","plan_verdicts":[{"id","verdict":"approve|revise",
  "required_changes":["<…>"]}],"critical_count":0,"major_count":0,"findings":[]}`, with no
  citation record and no `ac_verdicts`. `status:"success"` only when every plan is `approve`,
  otherwise `failure`. The caller reads `plan_verdicts`.

### `build-review` (skill, owns the repair loop)

- `success` requires a complete independent final review with zero CRITICAL and zero
  MAJOR findings, after all coder and mechanical changes.
- `partial`/`failure` means review or repair remains incomplete; `errors` identifies
  unresolved findings or the concrete blocker. Neither status permits verify or push.
- `files_changed` and `tests_written` accumulate actual repairs across passes.
- `data` includes `passes` (the review pass counter), `full_passes` and `delta_passes`
  (how many passes reviewed the whole change versus only a repair delta; `success`
  requires that the last repair was followed by a full pass), plus `critical_count` and
  `major_count` from the final reviewer R1. Without a complete reviewer result,
  report the blocker instead of fabricated zero counts. Both modes use this gate.
- Repair-round exhaustion is `failure` with `data.repair_rounds_exhausted:true` and
  `data.exhaustion_reason`: `recurring_finding` (a finding returned after its redesign round),
  `hard_cap` (`MAKATO_MAX_REPAIR_ROUNDS_HARD` reached) or `not_converging` (past
  `MAKATO_MAX_REPAIR_ROUNDS` with no drop in new blockers). `errors` lists the unresolved
  findings. On success `data` also carries `background_passes`, `lens_split_passes` and
  `repair_plan_reviews` (counts).

### `sensor-fixer.md` (model: sonnet)

- `status: "success"` — `residual == 0` after the loop finishes.
- `status: "partial"` — `residual > 0` but a draft-PR carry-over was emitted (the harness did not block the developer).
- `status: "failure"` — the harness could not run at all (e.g. missing inputs).
- `files_changed` — union of files touched by inner `build-resolve-finding` dispatches.
- `tests_written: []` (sensor-fixer does not write tests).
- `errors` — fingerprints (or `rule_id:file:line` strings) of unresolved findings.
- `data` keys: `{ "loops": N, "resolved": N, "escalated": N, "residual": N, "skills_used": [...] }`.

### `knowledge-scout.md` (model: haiku, read-only)

- `status: "success"` — synthesis returned (whether or not specs were found; `loaded: false` is a valid success).
- `status: "failure"` — agent could not run (missing REPO_ROOT, KEYWORDS, etc.).
- `files_changed: []`, `tests_written: []`.
- `errors: []` on `status: "success"`.
- `data` keys: `{ "loaded": true|false, "source": "local|none", "constraints_found": N, "standards_found": N }`.

### `plan-analyst.md` (model: haiku, read-only)

- `status: "success"` — Plan Analysis emitted; the prose block above the R1 envelope IS the synthesized output.
- `status: "failure"` — PLAN_PATH not found or unreadable.
- `files_changed: []`, `tests_written: []`.
- `errors` — `[]` on success; on failure: `["PLAN_PATH not readable: <path>"]` or similar.
- `data` keys: `{ "tdd_tasks": N, "goal_tasks": N, "layers_detected": [...], "tracer_required": true|false, "glossary_loaded": true|false, "knowledge_context_loaded": true|false }`.

### `gate-scout.md` (model: haiku, read-only)

- `status: "success"` — at least one gate command discovered.
- `status: "partial"` — config files read but no executable command extractable (project type unrecognized).
- `status: "failure"` — REPO_ROOT not readable.
- `files_changed: []`, `tests_written: []`.
- `errors: []` on success; on partial/failure: short reason strings.
- `data` keys: `{ "project_type": "...", "config_files_read": N, "build": "...", "lint": "...", "unit": "...", "integration": "...", "coverage": "...", "java_version_required": "...", "lint_ci_divergence": true|false }`.

### `runtime-qa.md` (model: haiku, read-only scorer)

- `status: "success"` — all exercised paths passed, OR the agent skipped cleanly (no runtime surface).
- `status: "failure"` — at least one CRITICAL finding (app crash, 5xx, or core AC outcome not achievable).
- `files_changed: []`, `tests_written: []` (agent is read-only — it observes but never edits source).
- `errors: []` on `status: "success"`; on `status: "failure"`: `["CRITICAL: <description>", …]` for each CRITICAL finding.
- `data` keys:

| Key | Type | Description |
|-----|------|-------------|
| `skipped` | `boolean` | `true` when no `## Runtime verification` section and no `health_check_cmd` — clean no-op. |
| `skip_reason` | `string\|null` | Why skipped (e.g. `"no-runtime-surface"`), or `null` when not skipped. |
| `paths_exercised` | `integer` | Number of AC-driven Playwright paths executed. 0 when skipped. |
| `findings_total` | `integer` | Total count of all findings (CRITICAL + MAJOR + ADVISORY). 0 when skipped. |
| `findings_critical` | `integer` | Findings that block push. 0 when skipped. |
| `findings_major` | `integer` | MAJOR findings (advisory, logged as warn). 0 when skipped. |
| `findings_advisory` | `integer` | ADVISORY findings (cosmetic, logged as warn). 0 when skipped. |
| `runtime_cmd` | `string\|null` | The shell command used to launch the app, or `null` when skipped. |

**Caller contract**: `build-runtime-qa` MUST tolerate `status: "success"` with `data.skipped: true` — this is not an error, it is the correct outcome for non-service builds. On `status: "failure"`: surface `errors[]` to the PO-agent as a HALT-002-equivalent (RUNTIME_QA_BLOCKED); do NOT push to git until CRITICAL findings are resolved.

### `task-file-scout.md` (plugin: `makato-orchestrate`, model: haiku, read-only)

- `status: "success"` — at least one file was read and the summary is non-empty.
- `status: "partial"` — some pre-read files could not be read AND the resulting summary covers fewer than half of `CHANGED_FILES`.
- `status: "failure"` — dispatch bundle missing a required field, OR every pre-read attempt failed (zero readable files).
- `files_changed: []`, `tests_written: []` (agent is read-only).
- `errors: []` on `status: "success"`; on `status: "partial"`: names of unreadable files; on `status: "failure"`: `["missing input: <field>"]` or `["no readable files"]`.
- `data` keys:

| Key | Type | Description |
|-----|------|-------------|
| `key_patterns` | `string[]` | ≤ 3 short sentences describing dominant existing patterns in the production files the coder should mirror. Empty array when `CHANGED_FILES` is empty or no files were readable. |
| `naming_conventions` | `object` | Observed naming convention categories (`class`, `method`, `test_class`, `test_method`, etc.) → 1-line description. Empty object when nothing observable. |
| `test_file_paths` | `string[]` | Project-relative paths of test files the coder should write to (one per production file in `CHANGED_FILES`). Includes predicted paths for not-yet-existing test files. |
| `existing_exports` | `string[]` | `"<file>::<symbol>"` strings listing top-level exported symbols from each production file read. Capped at 20 entries. |
| `warnings` | `string[]` | Anomalies: truncation, inconsistent naming, oversize files (>1500 lines), unexpected language mix. |
| `files_read` | `integer` | Count of files actually read this run (0 on failure). |
| `truncated` | `boolean` | `true` when `CHANGED_FILES` entries were dropped to stay within the 8-file cap. |

**Caller fallback contract**: callers MUST tolerate `status: "failure"` without halting. On failure: log a `warn` entry to `build.jsonl` (`step: "scout-skipped"`) and dispatch coder without `SCOUT_SUMMARY`. On `status: "partial"`: forward the partial `data` payload and log a `warn` entry naming unreadable files. The scout is advisory — a scout failure must never block a sub-task that `knowledge-scout` already greenlit at plan time.

## Examples

### Example — `coder` TDD success

```json
{
  "schema": "r1",
  "agent": "coder",
  "status": "success",
  "summary": "Task 3 implemented; targeted RED and GREEN passed.",
  "files_changed": ["src/main/java/com/example/order/OrderRepository.java"],
  "tests_written": ["src/test/java/com/example/order/OrderRepositoryTest.java"],
  "errors": [],
  "tool_calls_used": 28,
  "data": {
    "phase_reached": "green",
    "phases_executed": ["red", "green"],
    "targeted_tests": 1,
    "escalation": "none",
    "task_index": 3,
    "details": {
      "changes": [
        {
          "path": "src/main/java/com/example/order/OrderRepository.java",
          "summary": "Implemented customer lookup."
        }
      ],
      "tests": [
        {
          "path": "src/test/java/com/example/order/OrderRepositoryTest.java",
          "covers": "Customer lookup returns matching orders."
        }
      ],
      "commands": [
        {
          "phase": "red",
          "command": "uv run pytest src/test/java/com/example/order/OrderRepositoryTest.java",
          "exit_code": 1,
          "result": "1 failed: expected no matches before implementation."
        },
        {
          "phase": "green",
          "command": "uv run pytest src/test/java/com/example/order/OrderRepositoryTest.java",
          "exit_code": 0,
          "result": "1 passed."
        }
      ],
      "assumptions": [],
      "risks": [],
      "deferred_to_verify": []
    }
  }
}
```

### Example — `diff-reviewer` failure (CRITICAL + MAJOR findings remain)

```json
{
  "schema": "r1",
  "agent": "diff-reviewer",
  "status": "failure",
  "summary": "1 CRITICAL, 1 MAJOR: SQL string concat; unguarded null-deref on rare path.",
  "files_changed": [],
  "tests_written": [],
  "errors": [
    "src/api/UserController.java:42 — [CRITICAL][security] raw user-supplied id concatenated into JPQL query",
    "src/api/UserController.java:67 — [MAJOR][correctness] missing null-check before .toLowerCase() reachable when header absent"
  ],
  "tool_calls_used": 14,
  "data": {
    "pass_number": 1,
    "review_scope": "full",
    "critical_count": 1,
    "major_count": 1,
    "suggestion_count": 4,
    "nitpick_count": 1,
    "files_reviewed": 3
  }
}
```

### Example — `knowledge-scout` no-specs success

```json
{
  "schema": "r1",
  "agent": "knowledge-scout",
  "status": "success",
  "summary": "No specs root discovered for repo 'sandbox'; returning empty constraint set.",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 3,
  "data": {
    "loaded": false,
    "source": "none",
    "constraints_found": 0,
    "standards_found": 0
  }
}
```

## Audit-log integration

After emitting the R1 block, the agent (or, where the agent does not have Bash, the dispatching skill) MUST also append the envelope as a single JSONL line to `specs/<key>-*/build.jsonl` via `"$MAKATO_BUILD_ROOT/shared/build-log.sh"`, with `step: "r1"`:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"<dispatching-skill>","story":"<key>","step":"r1","status":"<r1.status>","data":<entire-r1-envelope>}'
```

This keeps the existing JSONL audit shape (`ts`/`skill`/`story`/`step`/`status`/`data`) while preserving the full R1 envelope verbatim under `data`. Downstream tooling that already reads `build.jsonl` does not need to be re-taught the line format.

## Versioning

- The `schema` field exists so that a future R2 contract can coexist with R1 during migration.
- Any breaking change MUST bump `schema` to `"r2"` (or higher) and document the new schema in this file.
- Backwards-compatible additions (new optional keys under `data`) do not bump the schema.

## What this contract does NOT cover

- `makato-plan` agents — tracked separately in GAP-013 (#29).
- Agent dispatch envelope (the prompt the caller sends in). That is per-agent, defined in each agent's `## Input` section.
- Token budget enforcement — `tool_calls_used` is the input signal; the ceiling logic lives in the PO-agent (GAP-006 / #32) and the kill-switch (GAP-004 / #30).
