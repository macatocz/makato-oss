# R1 Return Contract — makato suite agents

> **Status**: Authoritative. Every agent in the makato suite that emits structured output MUST emit
> an R1 JSON block as the final element of its output. Callers MUST parse the last fenced
> ` ```json ` block in the agent message — no prose parsing.

## Why this exists

The build-\* skills today read sub-agent output as prose ("Status: complete | blocked", "Findings:
..."). A future autonomous PO-agent (GAP-006 / #32) must `JSON.parse()` agent results to:

- update workflow-state without ambiguity
- gate retries on `status` rather than substring searches
- attribute token cost via `tool_calls_used`
- summarize a run by streaming `errors` arrays into a single triage list

The R1 envelope is the smallest schema that supports all of those use cases. Agents may still emit a
human-readable prose summary before the R1 block — but the R1 block is the machine contract.

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

| Field             | Required | Rule                                                                                                                                                                                                                                                                                                       |
| ----------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `schema`          | yes      | Literal string `"r1"`. Versioning lever for future contract changes.                                                                                                                                                                                                                                       |
| `agent`           | yes      | The agent's own `name:` from frontmatter (e.g. `"coder"`, `"diff-reviewer"`).                                                                                                                                                                                                                              |
| `status`          | yes      | One of three values. `success` = the agent's mission completed as specified. `partial` = the mission ran but a subset of the work could not be completed and is described in `errors` and `data`. `failure` = the mission could not be completed (structural blocker, missing input, escalation required). |
| `summary`         | yes      | One-line natural-language synthesis. Same content callers would otherwise scrape from the prose.                                                                                                                                                                                                           |
| `files_changed`   | yes      | List of repo-relative file paths the agent modified or created. Empty list (`[]`) for read-only agents. Never `null`.                                                                                                                                                                                      |
| `tests_written`   | yes      | List of repo-relative test file paths the agent created or extended in this run. Empty list for non-coder agents. Never `null`.                                                                                                                                                                            |
| `errors`          | yes      | List of short error/finding/blocker descriptions. Empty list (`[]`) when `status: "success"`. Each entry ≤ 240 chars.                                                                                                                                                                                      |
| `tool_calls_used` | yes      | Integer ≥ 0. Best-effort count of tool invocations the agent made this run — used by the PO-agent's budget ceiling logic. If unknown, emit `0` (never omit the field).                                                                                                                                     |
| `data`            | yes      | Agent-specific structured payload. Always an object (never `null`). See per-agent rules.                                                                                                                                                                                                                   |

### Emission rules

- The R1 block MUST be the **last** ` ```json ` fenced block in the agent's final message.
- The R1 block MUST be valid JSON parseable by `JSON.parse()` — no comments, no trailing commas, no
  JS expressions.
- Agents MAY emit additional ` ```json ` blocks earlier in the message (e.g. JSONL audit-log lines
  for human inspection). The contract is the **last** block.
- Agents MUST NOT emit prose after the R1 block.

### Caller parsing rule

````python
# Pseudocode for the canonical parse
last_json_block = re.findall(r"```json\n(.*?)\n```", agent_message, re.DOTALL)[-1]
r1 = json.loads(last_json_block)
assert r1["schema"] == "r1"
````

If `schema != "r1"` or the JSON does not parse: the caller MUST treat the dispatch as
`status: "failure"` with `errors: ["R1 contract violation: <reason>"]`.

## Per-agent rules

### `coder.md` (model: sonnet, mutates files)

- TDD `status: "success"` — this coder ran targeted RED and GREEN commands; RED failed for the
  intended reason, every locally runnable targeted test passed in GREEN, and `data.details` is
  complete and matches the worktree.
- TDD `status: "partial"` — RED ran, but GREEN was not reached or targeted tests still fail. The
  caller dispatches one fresh continuation with `PRIOR_R1`.
- TDD `status: "failure"` — a structural blocker requires `/refine` (`data.escalation:"refine"`), or
  no targeted command can run (`VERIFICATION_UNAVAILABLE`).
- TDD `files_changed` — every production-code path actually edited or created.
- TDD `tests_written` — every new or extended test file path.
- TDD `errors` — `[]` on success; the concrete blocker on failure.
- TDD `data` keys:

  ```text
  { "phase_reached":"red|green", "phases_executed":["red","green"], "targeted_tests":N, "escalation":"none|refine", "task_index":N, "details":{ "changes":[{"path":"<path>","summary":"<purpose>"}], "tests":[{"path":"<path>","covers":"<behavior>"}], "commands":[{"phase":"red|green","command":"<targeted command>","exit_code":N,"result":"<one-line result>"}], "assumptions":[], "risks":[], "deferred_to_verify":[] } }
  ```

  `targeted_tests` counts test cases in the targeted command.

- TDD `data.details` is mandatory and contains every actual changed path, added or changed test
  file, and targeted command run. `changes`, `tests`, and `commands` must not be empty; only
  `assumptions`, `risks`, and `deferred_to_verify` may be empty.
- A touched test that cannot run because a required external service is unavailable appears in
  `details.deferred_to_verify` with its reason; that alone does not fail the task. If no targeted
  command can run, return `failure` with `VERIFICATION_UNAVAILABLE: <reason>`.
- Every TDD R1 includes command evidence for RED and GREEN in `data.details.commands` when both
  commands ran. A caller does not accept missing details, missing RED or GREEN command evidence, or
  `changes` that disagree with the worktree. It dispatches exactly one fresh continuation for the
  same task with `PRIOR_R1` and `DETAILS_REQUEST: <missing items>`. A second detail-less R1 is
  `failure`. Caller test runs or earlier coder claims never substitute for this dispatch's evidence.
- Add `continued_from_partial: true` to `data` whenever the coder receives `PRIOR_R1`.

For a repair dispatch with `REVIEW_FINDINGS`, `VERIFY_FINDINGS`, or both, use
`data.mode:"review-repair"` for review-only and `"verify-repair"` for a verification-loop dispatch.
If both are supplied, report `data.mode:"verify-repair"` and cover every supplied finding. Both
modes require `data.repair_round`, `data.repaired_findings`, `data.unresolved_findings`, and
`data.details:{per_finding:[{id,root_cause, changes:[{path,summary}],verification:{command,exit_code,result}}], assumptions:[],risks:[]}`.
Include one `per_finding` result for every supplied finding. For verify-repair, `VERIFY_FINDINGS`
entries have `id`, `gate`, `command`, `failing`, `excerpt`, and `log_path`. `success` requires every
supplied finding to be repaired and its verification command to pass. Structural escalation is
`partial` with `data.escalation:"refine"`; unresolved findings remain listed. Coder success does not
approve a review or a verify gate: each caller independently re-checks the repair. For a
build-review apply repair, `data.coder_id` is REQUIRED and is the actual unique native dispatch
identity supplied by the harness; never invent or rename one. The ledger accepts a repair claim only
when `repaired --coder-id` matches this R1 identity and the reserved attempt; the closure verifier
must be a different native reviewer identity from every repair coder and reporter.

Review-repair dispatches add the following (all additive; verify-repair is unchanged). Repairs are
invariant-level: each `REVIEW_FINDINGS` entry carries an `invariant` and `sites`, and the coder
fixes the invariant on every site.

- `per_finding[]` gains `sites_covered:[{file,line}]` and
  `sites_not_applicable:[{file,line,reason}]`. Every `sites` entry of the finding appears in one of
  them; the caller rejects a `per_finding` result that leaves a site unaccounted for.
- For a universal invariant, `per_finding[].coverage_matrix` records each relevant input,
  entry/return/raise path, called helper, transaction boundary, async/cancellation path, required
  effect, existing test/evidence, and every unknown path. UI-state matrices additionally cover
  temporal/event ordering, pending and late responses, state owner, navigation, and draft
  preservation. Unknowns remain gaps; a universal wrapper is not presumed.
- `per_finding[].needs_files:["<path>"]` — set when `ALLOWED_FILES` forbids an edit the finding
  needs. The finding stays in `unresolved_findings` and the caller runs one sequential continuation
  without `ALLOWED_FILES`. Without `ALLOWED_FILES` the field is omitted.
- A finding that no longer reproduces on the current tree is listed in `repaired_findings` with
  `root_cause:"already resolved: <how>"` and a `verification` command that proves it.
- `REPAIR_PHASE: plan` (default `apply`) is allowed only after the persisted gate selects redesign
  for architectural, cross-boundary, or unknown repair scope, or a second unsuccessful return of the
  same invariant. CRITICAL severity alone never triggers planning. The plan makes no edits, writes
  no tests, and runs no tests. R1 `status:"success"`, `files_changed` and `tests_written` are `[]`,
  and

  ```text
  data:{"mode":"review-repair","phase":"plan","repair_round":N,"plans":[{"id":"<finding id>", "invariant":"<rule>","sites":[{"file","line"}],"approach":"<how>", "coverage_matrix":{"paths_checked":["<entry/return/raise/helper/transaction/async/effect paths>"], "evidence":["<source or test citations>"],"unknown_paths":["<uninspected paths, or none>"]}, "compatibility":{"persisted_state":"<effect on stored data, or none>","versioning":"<effect on versioned artifacts, or none>","migration":"<migration or tolerance for old data, or none>"}, "user_visible":"<changed messages, labels, or behaviour, or none>", "tests":["<test that fails while any site violates the invariant>"]}]}
  ```

  The plan result has no `repaired_findings` or `unresolved_findings`. The caller confirms the
  worktree snapshot is unchanged; otherwise the plan phase is `failure`.

- `REPAIR_PHASE: apply` with `APPROVED_PLANS` (and optional `PLAN_CONSTRAINTS`) returns the usual
  repair R1 and lists any deviation from the approved plan in `data.details.assumptions`.

### `build-fix-ci` (skill, owns remote CI repair)

`data` contains `github_pr_number`, `head_sha`, `ci_status` (`green|pending|blocked`),
`repair_cycles`, `unresolved_checks`, and `halt_code`. Only fresh current-head green with no
unresolved checks permits `success`. An interrupted wait/handoff is `partial`;
blockers/timeouts/stalled repairs are `failure`. PR creation and initial push propagate these fields
and non-success without losing the existing PR number. The PO-agent mirrors progress but never runs
a second CI loop. Existing-PR repair pushes return their head SHA without invoking PR creation or
nesting another CI coordinator.

### `diff-reviewer.md` (model: sonnet, read-only)

- `status:"success"` — ordinary diff completed with zero CRITICAL/MAJOR findings and complete
  required coverage. In `confirm-findings`, success means every supplied constituent has an
  evidence-backed disposition, not that the review is clean. In checkpoint mode, success means the
  scoped review is complete with no unresolved blocker, not final approval.
- `status:"failure"` — ordinary diff has CRITICAL/MAJOR findings, checkpoint has an unresolved
  blocker, or required confirmation results are malformed/missing.
- `status:"partial"` — immutable scope or source coverage is incomplete, or a confirmation is
  uncertain. Neither status permits clean completion.
- `files_changed:[]`, `tests_written:[]`; this agent is read-only.
- Merge validates every mandatory outer R1 field before recording reviewer evidence, including
  read-only path arrays and a non-negative integer `tool_calls_used` (not a boolean). Merged
  envelopes retain the sum of reviewer tool counts and bounded error summaries; full findings and
  raw evidence remain unabridged in the ledger.
- `errors[]` contains every blocking CRITICAL/MAJOR finding or concrete protocol/coverage gap.
- Ordinary `data` includes `pass_number`, `pass_kind`, actual `review_scope`
  (`full|delta|checkpoint`), actual unique native `reviewer_id`, exact `input_fingerprint`, severity
  counts, `files_reviewed`, one `file_citations[]` per reviewed scoped file, `findings[]`, and
  `ac_verdicts[]`. Deleted files cite their last line in `REVIEW_BASE`. Only a successful
  `final-full` sets `final_review:true`.

- **Final-full gate coverage** — require one citation for every file in the complete changed-file
  manifest (including deleted/untracked files) and `files_reviewed` at least the manifest count.
  Accept either one unscoped full reviewer with `lens:null`, or all five required lens results
  merged from the same immutable snapshot/pass. A `contract-ac`-only result cannot certify.
- `data.findings[]` retains every raw finding/site and includes `id`, `severity`, `category`,
  `lens`, `invariant`, `file`, `line`, `sites`, `evidence`, `citations`, and `description`. CRITICAL
  additionally requires `behavioral_reproduction` with reachable setup/action, expected and actual
  behavior, and executable evidence; hypothetical risks or missing tests alone cannot be CRITICAL.
  Universal invariants include `coverage_matrix` with checked paths, evidence/tests, and explicit
  unknown paths. Never merge findings or sites by proximity.
- Confirmation adds `data.review_mode:"confirm-findings"`, `data.reviewer_id`,
  `data.independent:true`, `data.input_fingerprint`, and exactly one `data.confirmations[]` per
  `finding_id` + `constituent_id`. Each has `status:"confirmed|rejected|uncertain"`,
  `repair_scope:"local|architectural|cross-boundary|unknown"`, reachability, impact, introduction
  status, evidence, and citations. The confirming reviewer differs from the finding reporter.
- Checkpoint has `data.final_review:false` and `data.ac_verdicts:[]`; the reviewer never authors a
  checkpoint receipt. The persisted gate is the sole receipt author.
- Only `diff-reviewer` authors AC judgments. Final-full rechecks every AC against code and tests;
  every `verified:true` retains non-empty, verbatim `ac_text` and exact implementation and test
  citations. Each citation has a positive integer `line`, a `file`, and an explicit
  `role:"implementation"` or `role:"test"`; both roles are required. Generic or one-sided citations
  cannot complete the final gate. Downstream skills transport the verdict array verbatim.
- `data.lens` is the supplied lens or `null`. Only `contract-ac` emits ordinary-pass AC judgments;
  other lenses return `[]`.
- `REVIEW_MODE: repair-plan` judges the coder plan, not the diff:
  `data:{"review_mode":"repair-plan","plan_verdicts":[{"id","verdict":"approve|revise", "required_changes":["<…>"]}],"critical_count":0,"major_count":0,"findings":[]}`,
  with no citations or `ac_verdicts`. The persisted gate must select
  architectural/cross-boundary/unknown redesign or a second unsuccessful return; severity alone
  never selects it. Success requires every plan to be approved.

### `build-review` (skill, owns the repair loop)

- Normal `success` requires a non-empty authoritative expected-AC set and the complete canonical
  contract-path closure, fresh complete final-full review of the current branch and every AC, zero
  CRITICAL/MAJOR blockers, independent closure of every blocker constituent, and a successful
  no-change `gate --event complete`, followed by successful ledger-owned `publish-audit`.
  Every `verified:true` AC has code and test citations. A clean delta, coder success, or mechanical
  change is not completion.
- Contract version 3 uses ledger version 3, runtime version 2 (`review-runtime.v2`),
  `review-input-fingerprint-v2`, and `review-eval-configuration-v2`; the R1 envelope stays `"r1"`.
  Consume `review_loop.py contract-paths` as its exact JSON array in canonical tuple order, not a
  handwritten inventory. Plain paths select build and `orchestrate:<rel>` selects orchestrate.
  Additional inputs cannot replace required entries; launcher/runtime/first durable bind enforce
  closure before any child executes.
- First durable gate/merge requires explicit frozen `contract_root` and `orchestrate_root`.
  Manual/installed callers must select/export `MAKATO_BUILD_ROOT` and `MAKATO_ORCHESTRATE_ROOT`;
  only the launcher may use the fully Git/marketplace-proved source-checkout fallback. No durable
  runtime-context/cache/consumer discovery is allowed. Fingerprint, merge, and gate forward
  `--contract-root B --orchestrate-root O`; launcher uses `--review-orchestrate-root O` and direct
  runtime launch uses `--orchestrate-root O`. Lenses uses `--state S` and both matching roots;
  absent/unbound/invalid binding keeps sampling OFF with `sampling_warning`.
- Ledger and runtime attempts freeze `contract_root`, `orchestrate_root`, and
  `root_bindings:{build:{path,dev,ino},orchestrate:{path,dev,ino}}` atomically. Every state command
  revalidates executing-code agreement and both live physical identities; identical bytes at a
  relocated/replaced directory do not authorize rebinding. Generic no-contract ledgers keep all
  three null and allow state/checkpoint operations, but neither durable execution nor final
  certification. Content identity is separately reproducible path/kind/mode/SHA-256 inventory:
  root paths/devices/inodes are not hashed, while source kind and executable permissions are.
  No old-state, identity/reboot/remount mismatch, or changed fingerprint authorizes automatic
  migration/reset or a fresh repair-cap budget. Preserve/export history and consumed budget before
  an explicitly authorized new ledger.
- `publish-audit --state PATH --worktree PATH --review-base REF` derives the canonical audit from
  the bound evidence root (fallback worktree); callers supply no audit path, fingerprint, rows,
  receipt, or success flag. It transports the persisted independent final-full AC verdicts verbatim
  and generates session statistics; checkpoints publish only a session row. Never perform a raw
  post-certificate success append or broadly exclude/untrack audits.
  The canonical audit must have exactly one hardlink; reject aliases before append, including
  pending-intent replay, without changing either canonical or collateral input bytes.
  Publication/receipt/recovery interfaces use validated ledger bindings and forward both roots
  through all internal source/delivery rechecks; they never rediscover or accept replacement roots.
- Checkpoint `success` is scoped and non-final: copy `data.checkpoint_receipt` verbatim from
  `publish-audit` after successful `gate --event checkpoint`, not directly from that gate.
  The returned delivery receipt preserves its reviewed `input_fingerprint`, `snapshot` and derived
  `checkpoint_scope:{pre_snapshot,scope_files}`, adding `delivery_fingerprint` and `audit_transition`.
  Scope includes source delta, affected callers/dependencies, prior invariant sites and explicit
  context/contract manifest labels; complete per-reviewer citation/count and lens coverage is
  rederived at publication and receipt validation. Missing scope evidence fails closed without
  resetting history/caps. Set `data.final_review:false` and
  `data.next_action:"review"`. It emits no final `ac-verification`, claims no future AC passed, and
  does not authorize verify/push. The scheduler independently validates the source certificate and
  transition against the ledger and actual live delivery hash, compares the exact returned delivery
  receipt, requires its scope baseline to match the last accepted snapshot (null initially), and
  retains the anchor snapshot for the next delta.
  The scheduler's actual installed script is hash-bound; the checkpoint command verifies its own
  executing build installation and frozen roots, not scheduler process identity.
- `partial`/`failure` means review or repair remains incomplete; `errors` identifies unresolved
  findings or the concrete blocker. Neither permits verify or push.
- `files_changed` and `tests_written` accumulate actual repairs across passes.
- Normal and checkpoint `data` transport the publication's immutable reviewed `input_fingerprint`,
  actual full live `delivery_fingerprint`, `audit_transition`, and `final_review` verbatim. Normal
  `data` also includes `passes`, `full_passes`, `delta_passes`, final severity counts, and
  `final_review:true`. Report counters only from durable history; never fabricate zero counts when
  a reviewer result is missing.
- Source and delivery fingerprints need not be equal. Acceptance/reuse independently validates the
  source certificate, canonical audit identity/prefix/exact ledger-derived append, complete
  manifests, and live delivery before evaluating coverage and mechanical proof at the unchanged
  reviewed anchor. External audit transitions are verified even when both hashes are equal.
  Delivery-only audit additions do not expand final-full coverage obligations. All other protected
  source/untracked/base/context/contract differences fail closed; operational writes after
  publication must remain outside every protected manifest input, including logs named as context.
  Durable narration must not read/migrate workflow-state on empty/failed private cache lookups.
  Resolve private logger/cache helpers from the exact active build root, not orchestrate's parent.
  Both helpers remain bound to the frozen build/orchestrate/shared identities: progress invokes
  read-only `verify-binding --state S --worktree W --build-root B --orchestrate-root O` using its
  own physical orchestrate root before transport/logging. Mismatch warns on stderr only, makes no
  GitHub/private-log write, and exits 0. Build-log verifies via its own physical review_loop and
  ledger before private ledger/audit writes; its preexisting temporary model cache is outside that
  promise. Neither durable helper uses discovery or workflow-state as a fallback.
- Completed-result reuse revalidates durable R1 and live certificate/transition without activating or
  spawning a child. It is not new-dispatch authority; retain invocation/context identity, HALT,
  coordinator/child epoch fencing, and activation authorization for new or waiting work.
- Gate cap exhaustion, HALT, timeout, uncertain evidence, incompatible state/root binding, stale
  fingerprint, or invalid audit transition fails closed with the persisted reason and unresolved
  constituents. Wrong-install runtime recovery returns blocked (exit 4), never dynamically executing
  code from a frozen root. Never reset counters, bypass approval, or treat a non-success
  reviewer/coder R1 as clean.

### `sensor-fixer.md` (model: sonnet)

- `status: "success"` — `residual == 0` after the loop finishes.
- `status: "partial"` — `residual > 0` but a draft-PR carry-over was emitted (the harness did not
  block the developer).
- `status: "failure"` — the harness could not run at all (e.g. missing inputs).
- `files_changed` — union of files touched by inner `build-resolve-finding` dispatches.
- `tests_written: []` (sensor-fixer does not write tests).
- `errors` — fingerprints (or `rule_id:file:line` strings) of unresolved findings.
- `data` keys: `{ "loops": N, "resolved": N, "escalated": N, "residual": N, "skills_used": [...] }`.

### `knowledge-scout.md` (model: haiku, read-only)

- `status: "success"` — synthesis returned (whether or not specs were found; `loaded: false` is a
  valid success).
- `status: "failure"` — agent could not run (missing REPO_ROOT, KEYWORDS, etc.).
- `files_changed: []`, `tests_written: []`.
- `errors: []` on `status: "success"`.
- `data` keys:
  `{ "loaded": true|false, "source": "local|none", "constraints_found": N, "standards_found": N }`.

### `plan-analyst.md` (model: haiku, read-only)

- `status: "success"` — Plan Analysis emitted; the prose block above the R1 envelope IS the
  synthesized output.
- `status: "failure"` — PLAN_PATH not found or unreadable.
- `files_changed: []`, `tests_written: []`.
- `errors` — `[]` on success; on failure: `["PLAN_PATH not readable: <path>"]` or similar.
- `data` keys:

  ```text
  { "tdd_tasks": N, "goal_tasks": N, "layers_detected": [...], "tracer_required": true|false, "glossary_loaded": true|false, "knowledge_context_loaded": true|false }
  ```

### `gate-scout.md` (model: haiku, read-only)

- `status: "success"` — at least one gate command discovered.
- `status: "partial"` — config files read but no executable command extractable (project type
  unrecognized).
- `status: "failure"` — REPO_ROOT not readable.
- `files_changed: []`, `tests_written: []`.
- `errors: []` on success; on partial/failure: short reason strings.
- `data` keys:

  ```text
  { "project_type": "...", "config_files_read": N, "build": "...", "lint": "...", "unit": "...", "integration": "...", "coverage": "...", "java_version_required": "...", "lint_ci_divergence": true|false }
  ```

### `runtime-qa.md` (model: haiku, read-only scorer)

- `status: "success"` — all exercised paths passed, OR the agent skipped cleanly (no runtime
  surface).
- `status: "failure"` — at least one CRITICAL finding (app crash, 5xx, or core AC outcome not
  achievable).
- `files_changed: []`, `tests_written: []` (agent is read-only — it observes but never edits
  source).
- `errors: []` on `status: "success"`; on `status: "failure"`: `["CRITICAL: <description>", …]` for
  each CRITICAL finding.
- `data` keys:

| Key                 | Type           | Description                                                                               |
| ------------------- | -------------- | ----------------------------------------------------------------------------------------- |
| `skipped`           | `boolean`      | `true` when no `## Runtime verification` section and no `health_check_cmd` — clean no-op. |
| `skip_reason`       | `string\|null` | Why skipped (e.g. `"no-runtime-surface"`), or `null` when not skipped.                    |
| `paths_exercised`   | `integer`      | Number of AC-driven Playwright paths executed. 0 when skipped.                            |
| `findings_total`    | `integer`      | Total count of all findings (CRITICAL + MAJOR + ADVISORY). 0 when skipped.                |
| `findings_critical` | `integer`      | Findings that block push. 0 when skipped.                                                 |
| `findings_major`    | `integer`      | MAJOR findings (advisory, logged as warn). 0 when skipped.                                |
| `findings_advisory` | `integer`      | ADVISORY findings (cosmetic, logged as warn). 0 when skipped.                             |
| `runtime_cmd`       | `string\|null` | The shell command used to launch the app, or `null` when skipped.                         |

**Caller contract**: `build-runtime-qa` MUST tolerate `status: "success"` with `data.skipped: true`
— this is not an error, it is the correct outcome for non-service builds. On `status: "failure"`:
surface `errors[]` to the PO-agent as a HALT-002-equivalent (RUNTIME_QA_BLOCKED); do NOT push to git
until CRITICAL findings are resolved.

### `task-file-scout.md` (plugin: `makato-orchestrate`, model: haiku, read-only)

- `status: "success"` — at least one file was read and the summary is non-empty.
- `status: "partial"` — some pre-read files could not be read AND the resulting summary covers fewer
  than half of `CHANGED_FILES`.
- `status: "failure"` — dispatch bundle missing a required field, OR every pre-read attempt failed
  (zero readable files).
- `files_changed: []`, `tests_written: []` (agent is read-only).
- `errors: []` on `status: "success"`; on `status: "partial"`: names of unreadable files; on
  `status: "failure"`: `["missing input: <field>"]` or `["no readable files"]`.
- `data` keys:

| Key                  | Type       | Description                                                                                                                                                                     |
| -------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `key_patterns`       | `string[]` | ≤ 3 short sentences describing dominant existing patterns in the production files the coder should mirror. Empty array when `CHANGED_FILES` is empty or no files were readable. |
| `naming_conventions` | `object`   | Observed naming convention categories (`class`, `method`, `test_class`, `test_method`, etc.) → 1-line description. Empty object when nothing observable.                        |
| `test_file_paths`    | `string[]` | Project-relative paths of test files the coder should write to (one per production file in `CHANGED_FILES`). Includes predicted paths for not-yet-existing test files.          |
| `existing_exports`   | `string[]` | `"<file>::<symbol>"` strings listing top-level exported symbols from each production file read. Capped at 20 entries.                                                           |
| `warnings`           | `string[]` | Anomalies: truncation, inconsistent naming, oversize files (>1500 lines), unexpected language mix.                                                                              |
| `files_read`         | `integer`  | Count of files actually read this run (0 on failure).                                                                                                                           |
| `truncated`          | `boolean`  | `true` when `CHANGED_FILES` entries were dropped to stay within the 8-file cap.                                                                                                 |

**Caller fallback contract**: callers MUST tolerate `status: "failure"` without halting. On failure:
log a `warn` entry to `build.jsonl` (`step: "scout-skipped"`) and dispatch coder without
`SCOUT_SUMMARY`. On `status: "partial"`: forward the partial `data` payload and log a `warn` entry
naming unreadable files. The scout is advisory — a scout failure must never block a sub-task that
`knowledge-scout` already greenlit at plan time.

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

After emitting the R1 block, the agent (or, where the agent does not have Bash, the dispatching
skill) MUST also log the envelope as a single JSONL line with `step:"r1"` via
`"$MAKATO_BUILD_ROOT/shared/build-log.sh"`.

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"<dispatching-skill>","story":"<key>","step":"r1","status":"<r1.status>","data":<entire-r1-envelope>}'
```

Ordinary steps append to `specs/<key>-*/build.jsonl`. During durable review, export
`MAKATO_REVIEW_LEDGER_STATE="$STATE"` and `WORKTREE_PATH` with the same frozen
`MAKATO_BUILD_ROOT`, `MAKATO_ORCHESTRATE_ROOT`, and matching `MAKATO_ORCHESTRATE_SHARED` for this
command: the helper verifies its own installation against the ledger before routing operational/R1
rows to the ledger run's private `operations.jsonl` through `operational-log`.
This also applies when the dispatching caller logs an already published review result. Never
append its envelope or progress rows to canonical audit after publication. Only `publish-audit`
owns the certificate-bound canonical AC/session rows; no extra raw tail is authorized.
Private logging refuses protected context/contract/source aliases (including otherwise ignored
logs), symlink or hard-linked destinations and has no canonical fallback. The JSONL envelope
shape remains unchanged; the full R1 envelope is preserved verbatim under `data`.

## Versioning

- The `schema` field exists so that a future R2 contract can coexist with R1 during migration.
- Any breaking change MUST bump `schema` to `"r2"` (or higher) and document the new schema in this
  file.
- Backwards-compatible additions (new optional keys under `data`) do not bump the schema.

## What this contract does NOT cover

- `makato-plan` agents — tracked separately in GAP-013 (#29).
- Agent dispatch envelope (the prompt the caller sends in). That is per-agent, defined in each
  agent's `## Input` section.
- Token budget enforcement — `tool_calls_used` is the input signal; the ceiling logic lives in the
  PO-agent (GAP-006 / #32) and the kill-switch (GAP-004 / #30).
