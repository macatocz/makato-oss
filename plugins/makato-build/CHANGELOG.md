<!-- markdownlint-disable MD013 -->

# Changelog — makato-build

Changes are grouped by skill/component. Within each group, latest version on top. Each version block
lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land
here on merge to main; release-please will date and version them at the next release cut.

---

## [Unreleased]

### Fixed — build-verify: test reports stay in the spec folder (v1.14.0)

- Step 1 adds a report-output contract. When a gate command copied from CI carries a JUnit
  option such as `--junitxml=results.xml`, build-verify rewrites the path to
  `specs/<key>-<slug>/<stem>-<N>.xml` before running it, so verify no longer creates or
  overwrites a report in the checkout root. Gates 4 and 5 log the path as `junit_report`.
### Changed — dependency-aware mixed-mode task scheduling (#153)

- **`build-implement-tdd` v1.16.0** accepts `ASSIGNED_TASK_IDS` from the PO-agent and runs
  exactly those tasks; a `blockedBy` task already `complete` in workflow-state (an earlier pass of
  either mode) satisfies the dependency, and an invalid assignment returns `MISSING_INPUT`. The
  tracer bullet is skipped once any plan task is complete, so stubs never replace accepted
  implementation. The R1 reports `data.completed_task_ids`.
- **`build-implement-goal` v1.8.0** gains the same `ASSIGNED_TASK_IDS` selection (dependencies
  checked read-only through `ISSUE_NUMBER`/`MAKATO_ORCHESTRATE_ROOT`) and reports
  `data.completed_task_ids`; the PO-agent records goal completion in `sub_tasks[]`.
- **`build-refine` v1.15.0** and `plan-schema.md`: `runOrder` only chooses which mode runs first
  among dependency-ready tasks; cross-mode `blockedBy` in either direction needs no exception.
### Changed — coders run targeted RED/GREEN; review and verify own testing with bounded repair loops (#148)

- **`agents/coder.md`** TDD mode runs only RED and GREEN, on only the test files
  the task added or changed (plus the tracer test). INTEGRATE, full-suite
  VERIFY, coverage and repo-wide lint move to `build-verify`. Every R1 must carry
  `data.details` (changes, tests, commands with exit codes and results,
  assumptions, risks, `deferred_to_verify`). Repair mode accepts
  `REVIEW_FINDINGS` or `VERIFY_FINDINGS` with `REPAIR_ROUND`/`MAX_REPAIR_ROUNDS`
  and reports per-finding root cause, change and verification.
- **`build-implement-tdd` v1.15.0** drops the per-task cross-task regression
  sweep and the final full-suite run, hands the baseline and changed-file set
  to `build-verify`, and re-asks the coder once (`DETAILS_REQUEST`) when R1
  details or RED/GREEN command evidence are missing.
- **`build-review` v1.8.0** caps coder repair → independent re-review at
  `MAKATO_MAX_REPAIR_ROUNDS` (default 3); unresolved CRITICAL/MAJOR findings fail
  closed (HALT-003).
- **`build-verify` v1.14.0** no longer edits source for code-level gate failures:
  it sends `VERIFY_FINDINGS` to the coder, re-reviews the repair delta with
  `diff-reviewer`, re-runs the scoped gates, and fails closed (HALT-002) after
  `MAKATO_MAX_REPAIR_ROUNDS` rounds.
- **`config/verification-ownership.md`**, **`agents/RETURN-CONTRACT.md`**,
  `definition-of-done`, `AUTONOMOUS-MODE.md`, the README and the TDD reference
  guides describe the same contract. On sagibeast#994 each serial coder ran the
  complete verification suite for its own task (10–15 min per task, 26 tasks).

### Fixed — durable project learning (port of #123 from `development`)

- **`shared/write-lessons.sh`** accepts `--issue N` (plus `--bundle`/`--label` recall
  metadata) and immediately persists generalizable procedures and facts into the
  selected checkout’s `.makato/memory/`, including interactive worktree sessions. Pass
  `--issue N` when several issues share one spec folder. Preserve issue/filter
  metadata; report promotion failures (exit 3) while retaining raw evidence.
- **`shared/write-lessons.sh`** resolves an exact `specs/<key>/` first, then a unique
  `specs/<key>-*/` match; ambiguous keys exit 2 instead of appending to the first match.
- **`build-verify` v1.13.1** and **`build-push-to-git` v1.7.2** require an
  evidence-based learning review at completion/handoff. Replace source-text tests
  with real CLI coverage.

### Fixed — coder verification ownership and unverified-result continuation (#141)

- **`agents/coder.md`** now owns every phase command it reports. Edit-only or
  "skip tests mid-flight" dispatch instructions no longer narrow its contract,
  and commands that cannot run return `failure` `VERIFICATION_UNAVAILABLE`
  instead of `partial`. The R1 now reports `data.phases_executed`. A new optional
  `PRIOR_R1` input adopts an earlier unverified attempt's edits and re-proves RED
  by temporarily stashing that task's production paths.
- **`build-implement-tdd` v1.14.0** dispatches coders one at a time per
  worktree and forbids suppressing coder verification. An unverified coder R1
  gets exactly one fresh-coder continuation (`PRIOR_R1`) instead of halting with
  CODER_PARTIAL; a second unverified result fails as `CODER_UNVERIFIED`.
  Coordinator test runs are never promoted to coder success.
- **`agents/RETURN-CONTRACT.md`** and **`references/tdd-cycle-rules.md`** document
  the same ownership rule.
- **`scripts/run-skill.py`** appends the new `config/verification-ownership.md`
  policy to every workflow-skill OMP run's system prompt
  (`--append-system-prompt`), and fails before launch if the file is missing.
  OMP's Task-tool guidance ("skip build/lint/tests mid-flight") is
  system-level, while the selected SKILL.md is user prompt. On sagibeast#994
  the fresh `build-implement-tdd` coordinator therefore dispatched coders
  edit-only, and after the text fixes it refused with
  `DISPATCH_CONTRACT_CONFLICT`. The coordinator copies the policy into each
  coder's Task context, which OMP also renders at system level.

### Fixed — target-checkout roots for worktree-dispatched skills and lessons

- **`shared/write-lessons.sh`** now writes per-issue lesson summaries under
  `MAKATO_TARGET_REPO_ROOT` when set and preserves common-dir sharing otherwise;
  a nested linked/per-run worktree regression covers both cases.
- **`build-verify-spec.sh`** resolves spec artifacts from the selected target root even when
  `REPO_ROOT` is already inherited, with linked/per-run worktree regression coverage.
- **`build-address-pr-comments` v1.7.1**, **`build-coordinate-repos` v1.0.1**,
  **`build-create-pr` v1.12.2**, **`build-grill-with-docs` v1.9.1**,
  **`build-implement-goal` v1.7.1**, **`build-implement-tdd` v1.13.2**,
  **`build-push-to-git` v1.7.1**, **`build-refine` v1.14.1**,
  **`build-review` v1.7.1**, **`build-runtime-qa` v1.0.3**, and
  **`build-simplify` v1.4.3** — spec/audit root instructions honor the
  override while preserving each skill's existing fallback behavior.
- `AUTONOMOUS-MODE.md` now documents the selected target root and its unchanged
  unset-override sharing fallback.

### Changed — build-refine: per-task budget (v1.14.0)

- Step 8 and `references/task-sizing-guide.md` now cap each task at what one `coder` dispatch can
  finish: 4 production files, 1 new module, 3 routes/commands in one concern, 2 integration scenario
  groups, 2 ACs and 2 external boundaries. Oversized tasks are split along tested concern
  boundaries, with shared groundwork first; splitting outranks the 2–6 task-count target.

### Changed — coder agent: turn budget 30 → 100

- Raise `agents/coder.md` `maxTurns` from 30 to 100 (matching `po-agent`). A full
  RED→GREEN→INTEGRATE→VERIFY task spanning schema, storage, routes and integration tests
  exhausted its budget before writing its first failing test (sagibeast #1274 Task 3).

### Fixed — build-implement-tdd: installed task-file-scout discovery (v1.13.1)

- When `MAKATO_ORCHESTRATE_ROOT` is unset, resolve the orchestrate plugin with
  `shared/runtime-context.sh plugin-root makato-orchestrate` (source sibling or OMP registry)
  instead of skipping the scout. Interactive sessions never set the variable, so the scout was
  never dispatched there. An absent orchestrate plugin still skips the scout without a
  `scout-skipped` warning.

### Fixed — host-qualified gh project-scope remediation

- **`build-start` skill v1.11.1** and **`build-create-pr` skill v1.12.1** — when a board update fails
  because the gh token lacks the `project` scope, log
  `gh auth refresh --hostname $HOST --scopes project,read:project` and the device-login URL
  instead of a generic WARN. `build-start` no longer discards `gh project item-list` stderr, so a
  scope failure is no longer reported as "issue not found on board".

### Changed — lightweight skill model roles

- Set makato-build:build-push-to-git and makato-build:build-create-pr to the built-in OMP
  `COMMIT` role (`@commit`), retaining inherited effort.
- Set makato-build:build-sensors, makato-build:inject-context, makato-build:inject-skills,
  makato-plan:issue-to-project, and makato-plan:manage-stores to the OMP `TINY` role (`@tiny`),
  retaining inherited effort.

### Added — autonomous current-head CI repair

- Added `build-fix-ci` and executable all-check inspection with exact run/job/attempt
  diagnostics. Unknown, missing, pending and inaccessible checks never pass silently.
- Autonomous PR creation waits for CI repair; existing-PR repair pushes do not
  recreate PRs or recurse. Review/comment repairs are reviewed and verified first.
- Added structured CI recovery to TDD and goal mode, including completed-task,
  configuration and metadata repair. Sensor residuals remain blocking in CI.
- Nested security/type repair receives explicit CI context: suppression, ignore
  and carry-over paths cannot turn unresolved CI failures into success.
- The stdlib inspector supports Python 3.10 and private logs under normal-clone
  git metadata; caller audits project sanitized fields instead of private paths.
- Resolve inspector test fixture roots before path comparisons so macOS symlinked
  temporary directories retain the same private-log containment checks as Linux.
- Replaced the fixed three-round CI ceiling with progress-based termination and
  an optional explicit cap; private checkpoints preserve interrupted work.
- Reconcile completed child results before resuming stale running checkpoints;
  consume host completion events instead of global waits, and return headless
  permission/configuration blockers without waiting for impossible prompt updates.
  Source-child restrictions remain role-scoped rather than leaking to the coordinator.
- Restore reproducible repository type checking with declared test dependencies,
  `.venv` and shared-module resolution, accurate `tmp_path` annotations, and
  explicit narrowing of optional build signals before assertions.
- Keep intentionally vulnerable security fixtures under a dedicated expected-findings
  gate, with missing/extra/incomplete scans rejected; use explicit synthetic values
  in parser redaction tests rather than realistic secret strings.
- Pin existing action versions to verified immutable commits and apply the mechanical
  formatting required by repository-wide verification.
- Serialize build audit entries compactly after timestamp, model and trace metadata
  handling, escaping Unicode separators so line-oriented consumers retain every
  event; add regression coverage for pretty JSON and metadata injection. Preserve authorized test-repair scope
  when constructing child contexts instead of inventing blanket editing bans.
- Keep saved reviewer/coder context separate from coordinator authorization on
  resume, so a historical read-only review prompt cannot prohibit authorized repairs.
- Reject malformed single-event audit input instead of appending corrupt records;
  preserve prior events and cover the failure path with a regression. Require sensor
  results to use the full fenced R1 contract, and avoid nested-shell JSON quoting.

### Fixed — blocking review repair in both execution modes

- `build-review` now sends every CRITICAL and MAJOR finding to the coder in manual
  and autonomous runs, then independently re-reviews until both counts are zero.
  Incomplete reviews and blocked repairs never permit verify/push.
- Review the merge-base-to-working-tree diff and untracked additions on every pass;
  retain unresolved findings instead of suppressing them on subsequent passes.
- Added the coder review-repair dispatch contract; final mechanical edits also
  require re-review before per-AC verdicts are persisted.
- Removed prompt-wording assertions from the default-branch smoke suite while
  retaining its executable stale-main regression and helper checks.

### Added — Per-skill roles and reasoning effort

- Use `xhigh` for build-review, stress-test-artifact, and all five makato-change skills.
- Added provider-neutral `skill_execution` defaults and overrides for all skills in
  makato-build, makato-plan, and makato-change, separate from the artifact DAG.
- Added `scripts/run-skill.py` to launch a fresh OMP process using `@default`, `@plan`,
  or `@review`, with explicit effort or inherited model-role thinking settings.
- Project overrides merge field by field; workflow-schema loading accepts execution-only
  configuration while preserving the built-in pipeline. Concrete providers stay in OMP.
- Removed Claude-specific skill model hints and documented the cross-plugin launcher,
  explicit context handoff, interactive interviews, and installed-plugin root overrides.

### Changed — build-runtime-qa: Verified local runtime origin (v1.0.2)

- Pass an optional `MAKATO_RUNTIME_URL` to runtime-qa; verify the provider
  port map and local response before using localhost, avoiding false app-down
  findings when the public address has no hairpin route.
- Record inaccessible browser transport/TLS as an explicit unverified skip,
  without disabling TLS verification globally or claiming AC coverage.

### Fixed — runner-neutral helper paths and greenfield exploration

- `build-create-pr` now resolves `SPEC_FOLDER` explicitly and validates
  `created-issues.json` only against an available `MAKATO_PLAN_ROOT` schema;
  unreadable or malformed artifacts remain advisory and never probe
  `"$REPO_ROOT/plugins/makato-plan"`.
- Active makato-build skills use `MAKATO_BUILD_ROOT` for suite-owned logging,
  worktree, default-branch, and lesson helpers. `build-grill-with-docs` uses
  the optional `MAKATO_ORCHESTRATE_ROOT` for workflow-state updates instead of
  a consumer-CWD-relative cross-plugin path.
- Removed legacy OMP two-level eager-load references to
  `AUTONOMOUS-MODE.md` and documented the installed plugin roots used by build
  skills.
- `build-refine`, `build-explore`, and `task-file-scout` now filter planned
  `create` targets and absent paths before `Read`/`tool.read` batches, avoiding
  unchecked OMP `Promise.all` failures when greenfield files are not present.
- Runtime path smoke coverage now checks the missing-file preflight contract and
  additional suite-owned helper paths.

### Fixed — ADR lookup, artifact handoff, and coverage command contracts

- `build-grill-with-docs` now loads `references/adr-criteria.md` exactly once at Step 1, resolves
  ADR directories with Glob under the target repository root (including `specs/ADR` first for
  SAGIBEAST), and rejects invented `@references/...` or `local://no-such` paths.
- `gate-scout` keeps `coverage` executable-only and emits `coverage_threshold` separately. Python
  projects without `pytest-cov` now use the declared `coverage run -m pytest && coverage report`
  fallback, preventing pytest's `unrecognized arguments: --cov` failure.
- `build-verify` consumes the separated coverage fields and guards artifact URI handoffs.

- `build-start` and `build-refine` now create or resume an interactive git worktree through
  `shared/interactive-worktree.sh`; interactive sessions no longer fall back to the main checkout,
  while autonomous sessions still fail closed when `WORKTREE_PATH` is missing.
### Changed — external consumer-repository runtime and spec resolution

Build skills now resolve installed plugin roots through OMP/Claude runner
variables instead of assuming the target repository CWD is the plugin root.
The shared spec resolver maps numeric issue keys to slug folders emitted by
`makato-plan:to-issues`, rejects ambiguous matches, and keeps audit logs in the
resolved folder. Gate-scout command maps are forwarded to implementation/test
phases, optional passport/cross-plugin artifacts degrade explicitly, and
`build-log.sh` repairs malformed timestamps with a warning. Added external-CWD,
numeric-issue, and runtime-reference smoke coverage.

### Docs — provider-neutral autonomous compatibility (`AUTONOMOUS-MODE.md`)

`AUTONOMOUS-MODE.md` § *Defensive-headless guard* now documents the harness-neutral
dispatch adapter (`plugins/makato-orchestrate/scripts/harness-command.sh`,
local-openai-gpt-macos-compatibility Task 3) instead of a literal
`claude --dangerously-skip-permissions -p …` invocation — both `loop.sh`'s
`cmd_dispatch` and `context-handoff.sh`'s `_emit_resume` build their permission flag
from the explicit `MAKATO_HARNESS_MODE` switch (`omp` default → `--yolo`; `claude` →
`--dangerously-skip-permissions`), never inferred from `MAKATO_HARNESS_BIN`'s name. Also
clarifies that the `MAKATO_HEADLESS=1` headless-caller contract is independent of which
model profile (`config/model-profiles.yml`: `openai` | `qwen-vllm` | `apple-ollama`,
selected via `MAKATO_MODEL_PROFILE`) is active. Documentation only — no skill/script
behavior change.

### Changed — script smoke tests relocated to `scripts/tests/` + wired into CI

Moved `scripts/workflow-schema-smoke-tests.sh` and `scripts/build-explore-smoke-tests.sh` into
`scripts/tests/` (matching the makato-orchestrate `scripts/tests/` convention) and added CI steps in
`.github/workflows/validate.yml` — these bash smoke suites previously ran in no workflow. Fixed the
co-located target resolvers (`$SCRIPT_DIR/../…`). No production-script or test-logic changes.

### `gate-scout` + `build-verify` — Gate 6 runtime health-check (#580)

Adds discovery and execution of a project-level health or smoke command so the verify pipeline can
surface runtime-health signals before a PR is pushed.

**`agents/gate-scout.md`** (v1.2.0 → **v1.3.0**):

- **Step 1e — Detect health/smoke command.** Probes `REPO_ROOT` in priority order: (a) `Makefile`
  containing a `health` target → `make health`; (b) `scripts/smoke.sh` file existence →
  `scripts/smoke.sh`; (c) `docker-compose.yml` / `docker-compose.yaml` with a `services:` block →
  `docker-compose up --wait`. When none of the three probes matches, `health_check_cmd` is `null`.
- **New `health_check_cmd` output field** (string|null) added to the `## Output Format` prose block
  and to the R1 `data` shape. Null (not the string `"null"`) when no command is discovered.

**`skills/build-verify/SKILL.md`** (v1.8.0 → **v1.9.0**):

- **Step 8b — Gate 6: RUNTIME HEALTH-CHECK** inserted between Gate 5 (Coverage) and the
  Skill-provenance advisory gate (Step 9).
- When `gate-scout.data.health_check_cmd` is non-null: run the command with a timeout controlled by
  `HEALTH_CHECK_TIMEOUT_SECONDS` (default 60 s); assert exit code 0 within timeout.
- When `health_check_cmd` is null: emit advisory skip message; record gate as `skipped`.
- Non-zero exit or timeout → gate status `warn`; log and continue — **gate is always advisory, never
  blocks**.
- `build.jsonl` log entry shape:
  `{"step":"gate-health","status":"ok"|"warn"|"skipped","data":{"health_check_cmd":...,"exit_code":N,"duration_seconds":N}}`
- DoD table gains an advisory Gate 6 row; gate summary table in Step 10 gains a Gate 6 row.

---

## `build-verify-spec` — spec-level verify skill (#568)

Adds a new post-`build-verify` skill that confirms the implementation actually satisfies the plan
artifacts before `build-push-to-git`. Closes a gap where a coder could pass all quality gates but
miss a requirement stated in `plan.md` or `stories.json`.

**`plugins/makato-build/skills/build-verify-spec/SKILL.md`** (new, v1.0.0):

- Three-dimensional verification: **COMPLETENESS** (plan.md checkboxes), **CORRECTNESS**
  (stories.json successScenarios keyword-matched against the diff), **COHERENCE** (spec-delta.md
  MODIFIED sections; absent spec-delta.md is a no-op).
- Exit 0 on all-pass; exit 1 on any CRITICAL finding (unchecked task, CORRECTNESS GAP, COHERENCE
  GAP). SUGGESTION findings surface in output but are non-blocking.
- Integrates into po-agent Step 6 between `build-verify` and `build-push-to-git`; a CRITICAL finding
  raises HALT-011 before push.

**`plugins/makato-build/skills/build-verify-spec/references/build-verify-spec.sh`** (new):

- Thin bash wrapper: resolves spec folder via `specs/<KEY>-*/` prefix-match glob, picks the latest
  `plan-<N>.md`, optionally captures `git diff HEAD`, then delegates to the Python module.
- Accepts `REPO_ROOT` and `PY_MODULE` env overrides for test isolation.

**`plugins/makato-build/shared/build_verify_spec.py`** (new):

- Importable Python module (stdlib only): `check_completeness`, `check_correctness`,
  `check_coherence`, `format_report`, and a `main()` CLI entry point.
- `check_completeness` counts checkboxes strictly within the `## Tasks` section — boxes in
  Background, Definition of Done, or other sections are ignored.
- `check_correctness` applies a keyword-matching heuristic against the diff; absent `stories.json`
  is skipped (no hard failure).
- `check_coherence` parses `## MODIFIED Requirements` from `spec-delta.md`; absent file is skipped;
  low-confidence matches are SUGGESTION (non-blocking), not GAP.

**`plugins/makato-build/shared/test_build_verify_spec.py`** (new, 25 tests):

- Direct import tests for all three verification functions and the report formatter.
- Bash wrapper subprocess tests cover spec-folder resolution, missing-key, and fixture scenarios
  matching the smoke-test suite.

**`plugins/makato-build/skills/build-verify-spec/references/build-verify-spec-smoke-tests.sh`**
(new):

- Three offline scenarios: S1 (full pass), S2 (unchecked task → exit 1), S3 (GAP scenario → exit 1).
- Mirrors the `mark-ac-checkboxes-smoke-tests.sh` sandbox pattern.

## `build-explore` — read-only thinking-partner skill (#564)

Adds a new skill that lets an agent (or user) explore a problem area and produce a structured
analysis report without writing any files — enforced by a restrictive `allowed-tools` frontmatter
that excludes `Write`, `Edit`, and all file-mutating tools.

**`plugins/makato-build/skills/build-explore/SKILL.md`** (new, v1.0.0):

- Read-only by design: `allowed-tools` lists only `Read`, `Glob`, `Bash(grep *)`, `Bash(find *)`,
  `Bash(ls *)`, `Bash(cat *)`, `Bash(head *)`, `Bash(tail *)`. `Write`, `Edit`, and git-commit tools
  are absent — enforced by the harness, not convention.
- Three-step workflow: identify the topic → survey the current implementation → produce the
  exploration report.
- Structured report format with five required sections: **Problem Summary**, **Current
  Implementation Overview**, **Solution Alternatives** (2–4, each with a trade-off table),
  **Recommended Approach**, and **Open Questions**.
- Closes with a `Ready to proceed? Run /build-start to begin implementation.` prompt so the
  exploration session hands off cleanly to the build pipeline.
- Carries `argument-hint: "[topic or file path]"` for inline invocation.

**`plugins/makato-build/scripts/build-explore-smoke-tests.sh`** (new):

- Six offline smoke scenarios (T1–T6): SKILL.md file exists, `allowed-tools` excludes `Write`,
  `allowed-tools` excludes `Edit`, alternatives section has ≥ 2 sub-headings, `/build-start` prompt
  present in body, missing SKILL.md exits 1 with a clear error. Exit code = failure count.

---

## `build-start` + `workflow-schema-loader.sh` — extensible workflow schema system (#563)

Introduces an optional `.claude/workflow-schema.yml` that lets teams customise the skill pipeline
assembled by `build-start`. When absent, the built-in default schema mirrors the current hardcoded
behaviour exactly (backward-compatible).

**`plugins/makato-build/config/default-workflow-schema.yml`** (new):

- Built-in default workflow schema listing all 11 pipeline artifacts in dependency order — matches
  the pipeline described in `AGENTS.md`.

**`plugins/makato-build/scripts/workflow-schema-loader.sh`** (new):

- Resolves `.claude/workflow-schema.yml` when present; falls back to the built-in default when
  absent (exit 0 in both cases).
- Parses the restricted YAML subset using Python 3 stdlib (no external deps — matches the
  `mark-ac-checkboxes.sh` / `write-lessons.sh` pattern).
- Detects direct cycles (`A→B→A`) and transitive cycles (`A→B→C→A`) via iterative DFS; exits 1 with
  the full cycle path in the error message.
- Exits 1 with a descriptive parse error on empty or malformed schema files.
- Prints one JSON object per line (`id`, `skill`, `required`, `description`) in topological order.

**`plugins/makato-build/scripts/workflow-schema-smoke-tests.sh`** (new):

- Six offline smoke scenarios (T1–T6): missing args, schema absent → default, valid custom schema
  with extra artifact, direct cycle, transitive cycle, empty schema file. Exit code = failure count.

**`skills/build-start/SKILL.md`** (v1.4.0 → **v1.5.0**):

- **New Step 4.5** (Resolve workflow schema): calls `workflow-schema-loader.sh` before the build log
  is initialised; logs `schema-resolved` JSONL entry with `source` (`default`/`custom`) and
  `artifact_count`; halts on non-zero exit with the loader's error message.
- **Step 5** (Initialize build log): `session-start` log now includes `schema_source` field.

---

## `build-refine` — autonomous ticket-path key-miss HALTs instead of prompting (#527)

Part of the autonomous build-refine materialization lane (makato-orchestrate #527): the po-agent's
new `materialize-refine` verdict dispatches `build-refine --autonomous <KEY>` to translate a
committed `stories.json` into `plan-<N>.md`. For that lane to be truly headless, the Step 4
key-resolution branch must not fire an interactive prompt.

**`skills/build-refine/SKILL.md`** (v1.9.0 → **v1.10.0**):

- **Step 4 (key resolution)**: split the "key not found in stories.json" branch by mode. Interactive
  mode still asks the user to confirm the key. **Autonomous mode** now HALTs with
  `MISSING_ARTIFACTS` (`data.reason: "unknown-key"`), writes the `build.jsonl` `session/error`
  entry + a `confirm-key` bypass log, and returns an R1 `failure` — never `AskUserQuestion`. This is
  the ticket-path counterpart to the plan-only `MISSING_ACCEPTANCE` guard. The po-agent re-validates
  deterministically and routes a full-tier key-miss to HALT-006.
- **`## HALT Codes`**: behavioural note on the Step 4 autonomous key-miss.

**`AUTONOMOUS-MODE.md`**:

- New per-gate table row for `build-refine` Step 4 (confirm-the-key → HALT `MISSING_ARTIFACTS`).
- New section documenting `build-refine` as the engine of the po-agent `materialize-refine` verdict
  — the three already-bypassed gates (Step 1 key, Step 4 key-miss, Step 11 plan-review) make it a
  pure `stories.json` → plan translation with no human gate.

**`halt-codes.md`**: `MISSING_ARTIFACTS` origin extended to Step 4 (unknown-key).

Gates 1 and 2 in `build-verify` ran raw tool invocations (`uv run pyright`, `uv run ruff check .`)
instead of the CI pre-commit hook, producing false-negative passes when the hook environment
differed from the raw-tool environment (e.g. pyright reported 0 errors via `uvx` in a fresh env
while CI reported 10 real errors on the same tree).

**`agents/gate-scout.md`** (v1.1.0 → **v1.2.0**):

- **Step 1d — pre-commit hook probe.** When `REPO_ROOT/.pre-commit-config.yaml` exists, parses it
  (YAML read, no shell execution) and extracts hook IDs for type-check tools (`pyright`, `mypy`) and
  lint tools (`ruff`, `flake8`, `pylint`). Constructs
  `pre-commit run --hook-stage manual <hook-id> --all-files` for each matched hook.
- **New R1 `data` fields** (additive — all existing fields preserved):
  - `build_hook_cmd` (string|null) — `pre-commit run --hook-stage manual pyright --all-files` or
    `null`
  - `lint_hook_cmd` (string|null) — `pre-commit run --hook-stage manual ruff --all-files` or `null`
  - `pyright_env` — `"hook"` when `build_hook_cmd` is non-null; `"raw"` otherwise
  - `build_hook_missing` (boolean) — `true` when no type-check hook found
  - `lint_hook_missing` (boolean) — `true` when no lint hook found
- **Deprecation note** on `lint_ci_command`: renamed to `lint_hook_cmd` for consumers;
  `lint_ci_command` preserved for backward compatibility and will be removed in the next major
  version.

**`skills/build-verify/SKILL.md`** (v1.7.0 → **v1.8.0**):

- **Gate 1 (Step 4)**: sources command from `gate-scout.data.build_hook_cmd` (hook path) instead of
  `data.build`. Three fallback paths: (a) hook cmd non-null → use it, log
  `gate_command_source: "hook"`, (b) null + `build_hook_missing: true` → WARN + skip, (c) null + no
  `build_hook_missing` → fallback to `data.build` with WARN. Pre-flight no-hooks-matched guard:
  empty stdout + exit 0 → `skipped`, not `passed`. Error-count parsing: `(\d+) errors?` from stdout;
  gate passes when exit 0 AND parsed errors == 0; warnings don't block. Log entries extended with
  `gate_command_source`, `parsed_errors`, `parsed_warnings`.
- **Gate 2 (Step 5)**: symmetric changes using `lint_hook_cmd`. When hook cmd is non-null, bypasses
  the `lint_ci_divergence` double-run check (hook path IS the CI path) with informational note. Ruff
  error-count parsed via `Found (\d+) errors?`.

**`.pre-commit-config.yaml`**:

- `pyright` hook: added `manual` to `stages` (`[pre-push]` → `[pre-push, manual]`).
- `ruff` and `ruff-format` hooks: added explicit `stages: [pre-commit, manual]` (previously
  inherited `default_stages: [pre-commit]`). Without `manual` stage,
  `pre-commit run --hook-stage manual` exits 0 with no output — the exact silent-skip false-negative
  the pre-flight guard detects.

---

## `parse-sarif.py` + `finding-routes.json` — biome "files were modified" autofix signal

When a `biome check` pre-commit hook runs in `--write` mode it rewrites files and pre-commit exits
non-zero with only `- files were modified by this hook` — no `path:line:` diagnostic rows. Two gaps
meant this never reached makato's deterministic autofix: (1) `parse-sarif.py` extracted **zero
findings** from that output (the modification line was not a recognised signal, and the hook header
`biome check` — with a space — failed the strict lower-case hook-id regex, so diagnostics stayed
attributed to the generic `pre-commit` tool); (2) even with a finding, no autofix route existed for
it. Result: the hook's own fix was left unstaged and CI stayed red.

**`shared/parse-sarif.py`:**

- **Hook-label map.** Added `"biome check"` / `"biome"` → `biome` to
  `_PRECOMMIT_HOOK_LABEL_TO_TOOL`, so the spaced hook header is attributed to the `biome` tool.
- **Autofix-signal detection.** New `_MODIFIED_SIGNAL_TOOLS` allowlist (currently `{"biome"}`) +
  `_PRECOMMIT_FILES_MODIFIED_RE`. When an allowlisted tool emits `files were modified by this hook`,
  the parser emits one synthetic
  `Finding(tool="biome", rule="files-modified", autofix_available=True)`. Non-allowlisted tools
  emitting the same line yield nothing (no spurious residuals).
- **Selftest.** Added Fixture 3b covering the real CI output (1 finding, correct tool/rule/autofix
  flag) and the non-allowlisted negative case.

**`shared/finding-routes.json`:**

- New exact route `biome:files-modified` → `action: autofix`, `cmd: biome check --write`.
  Exact-match beats the catch-all `biome:*` glob, so `sensor-fixer` Phase 0 re-runs the writer
  deterministically (no LLM round-trip) and stages the result. The existing `biome:lint/style/*` and
  `biome:*` routes are unchanged.

`gate-scout` only recognised bare `pytest` / `ruff` / `mypy` and a `[tool.ruff]`-in-pyproject world.
Lockfile-managed Python repos (`uv`, `poetry`, `pdm`) and repos that configure tools via standalone
top-level files went undiscovered, so `build-verify` ran commands that resolved against the system
Python and failed with `ModuleNotFoundError`, or missed whole linters.

**`agents/gate-scout.md`** (new frontmatter `version: "1.1.0"`):

- **Step 1b — package-manager prefix.** Detects `uv.lock` / `poetry.lock` / `pdm.lock` /
  `Pipfile.lock` and emits `python_runner_prefix` (`uv run`, …). Every Python command
  (build/lint/unit/integration/coverage) is prefixed with it. First lockfile wins; Python-only.
- **Step 1c — standalone tool configs.** Treats `ruff.toml`, `pyrightconfig.json`,
  `biome.json`/`biome.jsonc`, `.sqlfluff`, `mypy.ini`, `.flake8` as authoritative tool evidence even
  when `pyproject.toml` has no matching `[tool.*]` section.
- **Step 2 — Python extraction rewrite.** Build gate prefers `pyright` (or `mypy`) over the old
  `py_compile` placeholder; lint recognises standalone `ruff.toml`; **directory-based test lanes**
  (`tests/unit/`, `tests/integration/`) take precedence over the `integration` marker; coverage
  reads `[tool.coverage.run]` `source` for `--cov=` targets; new `lint_js` (biome) and `lint_sql`
  (sqlfluff, with `--dialect`) commands surface as extra linters.
- **Step 3 — threshold precedence.** `COVERAGE_HINT` → `[tool.coverage.report] fail_under` → `90%`
  default. A configured `fail_under = 0` is now honoured as a deliberate greenfield setting.
- **Output + R1 `data`** gained `python_runner_prefix`, `lint_js`, `lint_sql`; success example
  rewritten to a realistic uv/pyright/biome/sqlfluff project. Non-Python output is unchanged
  (`python_runner_prefix: "none"`, extra linters `"not found"`).

**`skills/build-verify/SKILL.md`** (1.6.1 → 1.7.0):

- Step 1 consumes `python_runner_prefix` (run commands verbatim — never strip/re-add the prefix) and
  runs `lint_js` / `lint_sql` as additional LINT-gate commands, each passing independently.

**`skills/build-verify/references/gate-definitions.md`**:

- Added the package-manager-prefix table, `pyright`/`mypy` build rows, standalone-`ruff.toml` lint
  row, and `biome`/`sqlfluff` extra-linter rows.

---

## `definition-of-done` — raise default conditional-coverage floor to 90%

**`skills/definition-of-done/SKILL.md`** (2.0.0 → 2.1.0): default conditional (branch) coverage
threshold raised 85% → **90%** (Automated item 2, enforced by `build-verify` Gate 5). Wording-only
edit — item counts (13 automated / 6 manual) and enforcer unchanged, so a minor bump per the skill's
own versioning policy. Per-story `design.md` override is unaffected. Aligned with the `gate-scout`
default (also 90%).

## `diff-reviewer` + `build-review` + `build-create-pr` — per-AC verified/gap verdict for post-merge checkbox marking

Acceptance-criteria checkboxes on a GitHub Issue were never checked by the pipeline — a merged PR
left every `- [ ]` untouched, and nothing recorded _whether_ each AC was actually verified. This
adds a per-AC verdict that travels from the adversarial review to the post-merge
`documentation-agent` (in `makato-orchestrate`), so a checked box means "the reviewer confirmed
code + test coverage", not merely "the PR merged". See `AGENTS.md` § _ac_verdicts propagation
chain_.

- **`agents/diff-reviewer.md`** (→ 1.1.0) — new Step 3.5 emits one
  `{ac_id, ac_text, verified, evidence, reason}` verdict per AC in `PLAN_CONTEXT`; `verified: true`
  requires BOTH implementing code AND a test exercising the AC in the diff. Returned in R1
  `data.ac_verdicts[]` and echoed in the review report's `## AC Verdicts` section. New rule + "does
  NOT do" clause (the agent emits verdicts; it never flips issue checkboxes).
- **`skills/build-review/SKILL.md`** (1.4.0 → 1.5.0) — new Step 4a copies `data.ac_verdicts[]`
  verbatim into a `step:"ac-verification"` `build.jsonl` entry on the final clean pass (the durable
  local record; workflow-state is gitignored). Absent/empty verdicts log `status:"warn"` so
  downstream falls back gracefully.
- **`skills/build-create-pr/SKILL.md`** (1.8.0 → 1.9.0) — Step 3 renders the last `ac-verification`
  entry into a `## AC Verification` PR-body block (fenced JSON behind a `makato:ac-verdicts` marker)
  — the sole cross-environment transport to the post-merge GHA runner. Omitted entirely when no
  verdict entry exists (no false `[x]`).
- **`AGENTS.md`** — new _ac_verdicts propagation chain_ section (parallel to `recommended_skills[]`
  and `TEST_ORACLE`), documenting the four-stage chain and its optional/transport-only/forward-only
  contract rules.
- Consumer: `plugins/makato-orchestrate/agents/documentation-agent.md` § _Step 4a — Mark verified AC
  checkboxes_ (Step 4a).

Two advisory quality gates let non-blocking-but-real problems reach the PR unblocked. Both are now
gated in autonomous mode without changing interactive ergonomics.

**(1) Advisory `diff-reviewer` — new MAJOR tier.** The old 3-tier rubric (CRITICAL / SUGGESTION /
NITPICK) meant a correctness bug misclassified as SUGGESTION reached the PR with no gate — only
CRITICAL blocked. Added a 4th tier, **MAJOR**, for correctness-adjacent defects below the CRITICAL
bar (lower-likelihood bugs, missing guards masked by a caller, degrading edge cases, untested
failure paths).

- **`agents/diff-reviewer.md`** — rubric expanded to CRITICAL / MAJOR / SUGGESTION / NITPICK with an
  explicit decision order; R1 `status:"failure"` now fires while `critical_count > 0` OR
  `major_count > 0`; `data.major_count` added; `errors[]` entries carry a `[<severity>]` prefix;
  zero-findings recheck and citation-omission rules now key off "zero CRITICAL and zero MAJOR";
  "does NOT do" list forbids downgrading a correctness concern to SUGGESTION.
- **`skills/build-review/SKILL.md`** (1.3.3 → 1.4.0) — Step 5 renamed to a mode-aware
  blocking-findings loop: CRITICAL always blocks; MAJOR re-triggers the fix loop **in autonomous
  mode only** (advisory in interactive, reported in Step 6). First MAJOR auto-fix per pass emits an
  `autonomous_bypass` audit entry. Log keys gained `major`, `majors_fixed`, `majors_open`.
- **`skills/build-review/references/review-criteria.md`** — classification table + per-category
  CRITICAL/MAJOR/SUGGESTION guidance updated; reserves SUGGESTION for pure maintainability.

**(2) Coverage-floor acknowledgement.** `build-implement-tdd` Step 7's "acknowledged and logged as a
known risk" wording read as a silent-proceed escape hatch and was undefined for autonomous mode.

- **`skills/build-implement-tdd/SKILL.md`** (1.10.0 → 1.11.0) — Step 7 rewritten: interactive mode
  requires a **structured** `coverage-acknowledged` entry (`acknowledged_by`, `reason`) — no
  free-form note; autonomous mode CANNOT acknowledge (no human owns the risk) and defers
  authoritatively to `build-verify` **Gate 5** (`HALT-002`), emitting a
  `coverage-floor defer-to-gate5` bypass marker. No new HALT code — terminal enforcement stays at
  Gate 5.

- **`agents/RETURN-CONTRACT.md`** — diff-reviewer R1 contract + example updated for the MAJOR tier
  and `major_count`.
- **`AUTONOMOUS-MODE.md`** — two default-taking rows added (build-review MAJOR loop;
  build-implement-tdd coverage-floor) plus two explanatory sections.
- **`README.md`** — build-review row/version and diff-reviewer tier list updated.

`build-implement-tdd/SKILL.md:36` documented that `PRIOR_LESSONS` (GAP-015 / #37 lesson-recall) is
"forwarded verbatim to each per-task coder dispatch in Step 6", but the Step 6 dispatch-bundle
enumeration and `coder.md`'s Input table both omitted it — so an LLM following the spec never sent
it and GAP-015 was silently ineffective.

- **`skills/build-implement-tdd/SKILL.md`** — added `PRIOR_LESSONS` to the Step 6 coder
  dispatch-bundle list, mirroring the optional-advisory contract of `RECOMMENDED_SKILLS` /
  `TEST_ORACLE` (forward verbatim when present; omit when absent or `[]`; advisory weight equal to
  `SCOUT_SUMMARY`; never overrides `PLAN_CONTEXT.Hard Constraints`).
- **`agents/coder.md`** — added a `PRIOR_LESSONS` (optional) row to the Input table and a new
  `## Prior lessons (GAP-015)` section describing how the coder consumes it before Phase 1 RED.
- **`shared/autonomous-propagation-smoke-tests.sh`** — new `T-PRIOR-LESSONS` block asserting the
  field appears in both the Step 6 dispatch bundle and coder.md's Input table (grep-based contract
  check, verified to fail without the wiring).

## `sensor-fixer` + repair skills — mark opus escalation / `model_override` as not-yet-wired (#287)

The HALT-004 sonnet→opus tier escalation was documented as live behaviour, but
`build-resolve-finding` (and the `build-fix-*` repair skills) run under the **Skill tool**, which
has no `model` parameter — so the `--model "opus"` retry and the `finding.model_override` field have
no runtime that consumes them. The escalation was a no-op. Docs now match reality; no code behaviour
changed.

- **`agents/sensor-fixer.md`** — frontmatter description, Phase-1 prose, and the escalation note
  reworded to flag the escalation as _intended but not yet wired_, with an explicit note that wiring
  it requires converting the per-finding dispatch to an Agent-tool sub-agent.
- **`skills/build-resolve-finding/SKILL.md`**, **`skills/build-fix-security/SKILL.md`**,
  **`skills/build-fix-types/SKILL.md`** — `model_override` annotated as reserved/inert at each
  Finding-shape definition. The field is retained (removing it would orphan the escalation
  narrative) but caveated as having no current effect.

Two `MAKATO_ORCH` / `MAKATO_ROOT` derivations in `build-implement-tdd/SKILL.md` (the scout-dispatch
guard and the post-coder `workflow-state.sh patch`) used a bare `git rev-parse --show-toplevel`
**after** the skill has already `cd`'d into `$WORKTREE_PATH`, so both resolved to the worktree root
instead of the main checkout. Line 61 of the same skill already used the correct
`git -C "$WORKTREE_PATH" rev-parse --git-common-dir` form; these two lagged behind it.

- **`skills/build-implement-tdd/SKILL.md`** — both bare `--show-toplevel` calls now resolve
  `MAKATO_ORCH` / `MAKATO_ROOT` via `git -C "$WORKTREE_PATH" rev-parse --git-common-dir`, matching
  line 61 and the sibling `workflow-state.sh` fix in #282. This keeps the scout-agent probe and the
  state-patch call pointed at the main checkout's `plugins/makato-orchestrate` regardless of the
  worktree CWD. Companion to the makato-orchestrate `workflow-state.sh` fix.

---

## F5 task-text routing — `task_contains` bundle key (#131)

Adds a task-text dimension to the inject-skills resolver alongside the existing file-path dimension.
A bundle that declares `task_contains` is now selected when at least one substring appears in the
caller-supplied task description (issue body + `plan.md`), independent of which files are in the
diff. This enables skill routing for green-field tasks where the relevant library files do not yet
exist. The change is purely additive: when no `task_text` is supplied, resolution is byte-for-byte
identical to the pre-F5 behaviour.

- **`shared/inject_skills.py`** — `_task_hint_ok(bundle, task_text) -> bool` helper added
  (D19-sibling for task text); `resolve_skills` extended with keyword-only `task_text=None`
  parameter; `resolve_skills_for_repo` extended with matching `task_text=None` forwarding parameter.
  Module docstring updated to document both.
- **`skills/inject-skills/SKILL.md` → 1.1.0** — Input table gains optional `task_text` field;
  Behavior section adds Step 3 (task-text routing), updates Step 4 (ordering with specificity-0 task
  matches), and adds authoring guidance for `task_contains`.
- **`agents/knowledge-scout.md`** — Step 0e documents the `task_text` opt-in: callers with access to
  the issue body / `plan.md` may pass it to enable F5 routing; absent it, routing degrades to
  today's file-only behaviour.
- **`plugins/makato-langgraph/config/skill-bundles.yml`** — `langgraph` bundle gains `task_contains`
  with 8 keywords (`langgraph`, `LangGraph`, `agent loop`, `state machine`, `state transitions`,
  `graph node`, `workflow orchestration`, `StateGraph`). Schema comment block updated to document
  `task_contains` and the new resolution contract.
- **`plugins/makato-database/config/skill-bundles.yml`** — `database-migrations` bundle gains
  `task_contains` for postgres/schema/migration keywords.
- **`plugins/makato-observability/config/skill-bundles.yml`** — `observability-otel` bundle gains
  `task_contains` for OpenTelemetry/Langfuse/tracing keywords.
- **`plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh`** — wide-glob rule extended: a
  bundle with a non-empty `task_contains` (and no file `contains`) now passes (task text is itself
  the precision filter). A wide glob with neither still fails. Error message updated to mention
  `task_contains` as a fix option.
- **`shared/test_inject_skills.py`** — 19 new tests across `TaskTextMatchTests` (AC-1, AC-2, AC-3),
  `TaskTextForRepoTests` (end-to-end forwarding, AC-3), `FileAndTaskCombinationTests` (AC-6),
  `ValidatorTaskContainsTests` (AC-5), and `TaskContainsBundleDataTests` (AC-4). All 37 tests pass.

## Finding schema unified across the sensor loop (#230)

Fixed field-name drift in the sensor loop's Finding contract. `shared/parse-sarif.py`
(`class Finding`) has long emitted the canonical shape
`{tool, rule, path, line, column, message, severity, autofix_available, raw}`, and the three fixer
consumers (`build-resolve-finding`, `build-fix-types`, `build-fix-security`) already read it — but
`build-sensors/SKILL.md` and `agents/sensor-fixer.md` documented a stale shape (`rule_id` / `file` /
`fixable`) that matched neither. The contract was documented three ways with only the code correct,
risking a reintroduced `rule_id → rule` remap bug. This converges the docs onto the code (no runtime
change), adds a single source of truth, and guards it with a CI contract test.

- **New `shared/finding-schema.md`** — canonical field table, emitter→consumer contract, the
  `fingerprint` note (sensor-fixer-_derived_, not a `parse-sarif.py` output), the
  severity-vocabulary divergence note (flagged out-of-scope), and the forbidden-field list. All four
  loop artefacts now link here instead of re-describing the shape inline.
- **`build-sensors` → 1.1.0** — Step 5 Finding-shape description rewritten to the canonical set with
  a link to `shared/finding-schema.md`.
- **`sensor-fixer` agent** — `FINDINGS` input, log-line example, and error-string format reconciled
  to the canonical shape; `fingerprint` documented as agent-derived, not received.
- **`build-fix-security`** — stale `(tool, rule_id)` prose corrected to `(tool, rule)`.
- **New `shared/finding-schema-smoke-test.sh`** — asserts the emitter's serialised keys equal the
  documented canonical set, the two rewritten artefacts carry no forbidden field names, the three
  consumers stay canonical, the reference doc is linked from all four artefacts, and
  `parse-sarif.py --selftest` still exits 0. Wired into `.github/workflows/validate.yml`.

## TEST_ORACLE — `acceptanceTestCases[]` drives coder RED tests (#235)

Gives the makato-plan `acceptanceTestCases[]` field (written by `create-acceptance-tests`) a real
downstream consumer. Previously it was an orphan — no build stage read it, so running
`create-acceptance-tests` had zero effect on build quality. Now the QA-refined acceptance scenarios
flow into the TDD build as the coder's test specification. Fully optional and backward-compatible: a
story with empty/absent `acceptanceTestCases[]` produces no oracle section and every stage behaves
byte-for-byte as before.

- **`build-refine` → 1.9.0** — Step 4 now distinguishes two acceptance sources: `successScenarios[]`
  → numbered AC-1, AC-2… (task decomposition, unchanged), and `description.acceptanceTestCases[]`
  (when non-empty) → a new `## Acceptance Test Oracle` section written into `plan.md` (Step 10),
  each scenario annotated `(maps to AC-N)`. New `oracle_scenarios` count in the extract-story and
  write-plan JSONL. Schema documented in `references/plan-schema.md` (optional section) and
  `templates/plan-template.md`.
- **`plan-analyst`** — reads the `## Acceptance Test Oracle` section and returns it verbatim in the
  Plan Analysis prose block, so `build-implement-tdd` gets it without re-reading `plan.md`.
- **`build-implement-tdd` → 1.10.0** — forwards the oracle as a new optional `TEST_ORACLE` field in
  the coder dispatch bundle when present; omitted when absent (never an empty value). CI-failure
  recovery matching (`**Tests:**`) untouched.
- **`coder`** — new § _Test oracle_: in Phase 1 RED, when `TEST_ORACLE` is present, filter scenarios
  by the task's `**Satisfies:**` AC links and implement the matching ones as RED tests (given →
  arrange, when → act, then/and → assert). Advisory — never overrides Hard Constraints; a coverage
  floor, not a ceiling. TDD-only; `build-implement-goal` unchanged.
- **`AGENTS.md`** — documents the full "TEST_ORACLE propagation chain".

Foundation slice of the Lightweight Planning Lane epic. Small features can enter the autonomous
pipeline with a hand-authored `plan.md` instead of the full `stories.json` + `prd.md` + `design.md`
set.

- **`build-refine` → 1.8.0** — Step 3 NEW-READs `seed-manifest.json` (build-refine read no manifest
  before) and parses the optional `spec_tier` field. When `spec_tier == "plan-only"`, the work item
  enters the **same** lightweight branch as the legacy `local-` KEY prefix (numeric-slug KEYs like
  `123-add-feature` never match `local-*`, which is why the manifest read is required). The
  plan-only path **bypasses the `design.md`-missing stop guard** and sources acceptance criteria
  from `plan.md` `## Acceptance criteria` — **not** the synthetic AC-1 the legacy local path emits.
  A missing entirely `plan.md` HALTs `MISSING_PLAN`; an absent-or-empty `## Acceptance criteria`
  section (placeholder / whitespace treated identically to missing) HALTs the new
  `MISSING_ACCEPTANCE` code. An absent/unparseable manifest or absent field is "no tier" — never a
  HALT, legacy behavior byte-for-byte.
- **`build-create-pr` → 1.8.0** — How-to-Test gains a plan-only branch (D11 enabler): with no
  `stories.json` but `spec_tier:plan-only`, test steps are sourced from `plan.md`
  `## Acceptance criteria` instead of falling through to the commit-message derivation.
- **`halt-codes.md`** — registers `MISSING_ACCEPTANCE` (build-refine Step 4, route `refine`) and
  extends `MISSING_PLAN` to build-refine's plan-only path.
- **`references/spec-artifacts-schema.md`** — documents the optional `seed-manifest.json`
  `spec_tier` field and the `plan.md` `## Acceptance criteria` plan-only source.
- **`shared/plan-only-tier-smoke-tests.sh`** (new) — 11 prose-level assertions covering the manifest
  read, shared lightweight branch, design.md-guard bypass, plan.md AC sourcing, `MISSING_ACCEPTANCE`
  on absent/empty, the create-pr D11 branch, and legacy/ticket-path regression guards.

---

F1 of agent-skill-routing. Replaces the `inject-skills` S1 stub with a real resolver and wires it
into `knowledge-scout` Step 0.

- **`shared/inject_skills.py`** (new) — cross-plugin skill-bundle resolver. `resolve_skills` is a
  stdlib-only pure core sharing `inject_context`'s glob-specificity ordering (D9); it adds
  OR-substring content hints (D19), a target-repo installed-skill subset filter (D10), and graceful
  missing-skill skip (D18 — dropped skills surface as a `missing-skills` warning, never an
  exception). Orchestration helpers `aggregate_bundles`, `discover_installed_skills`, and
  `resolve_skills_for_repo` merge every `plugins/*/config/skill-bundles.yml` and read file text for
  content hints. Raises `BundleResolutionError` (HALT-006) on a missing/duplicate/absent `default`
  bundle.
- **`shared/test_inject_skills.py`** (new) — 18 unit + integration cases covering the four #144
  acceptance scenarios (name+content match, content miss, missing-skill graceful skip, cross-plugin
  aggregation) plus dedup, ordering, empty-scope, and HALT-006 validation.
- **`skills/inject-skills/SKILL.md`** — **0.1.0 → 1.0.0.** Rewritten from the S1 stub to document
  real resolution behaviour, the authoring rules, and the content-hint / subset-filter /
  cross-plugin-aggregation contract.
- **`agents/knowledge-scout.md`** — Step 0 gains sub-step **0e** calling `inject-skills` for the
  same `CHANGED_FILES`. The R1 `data` block is extended **additively** with `recommended_skills`
  (defaults to `[]`); existing readers of `constraints_found` / `standards_found` / `rule_paths` are
  unaffected. HALT-006 from the skill resolver is handled identically to the context path.

---

## Cross-plugin caller update for per-issue workflow-state (#173)

Companion to `makato-orchestrate`'s per-issue workflow-state layout change. `build-implement-tdd`'s
Step 6 workflow-state patch calls now thread the PO-agent's `ISSUE_NUMBER` into the new positional
#3 required by `plugins/makato-orchestrate/shared/workflow-state.sh`. The guard on the caller path
(`[[ -x "$MAKATO_ROOT/shared/workflow-state.sh" ]]`) is preserved unchanged — consumer repos without
the orchestrate plugin see no behaviour change; the patch block is skipped silently as before.

- **`skills/build-implement-tdd/SKILL.md`** — Step 6 § _R1 mirror + state patch_ code block updated.
  Both `patch` calls now take `"<key>" "<issue>"` before the jq path. Prose clarifies that the issue
  number is threaded from the PO-agent's context bundle (`ISSUE_NUMBER` / `WORKTREE_PATH` inputs in
  § _Input_).

---

## `build-create-pr` mandatory audit contract around `gh pr create` (#169)

Fixes the silent-exit class first observed in #143: while driving that issue through the PO-agent
under `--autonomous`, `build-create-pr` recorded `pr-draft-approval bypassed` at 00:15:44 UTC and
then produced **no further audit events**. `workflow-state.json` remained at `current_phase: "pr"`,
the PO-agent claude subprocess terminated ~29 s later, and no PR was opened for the pushed branch.
The commit had been pushed cleanly — the failure was scoped to the `gh pr create` step.

Investigation ruled out the #160-style AskUserQuestion mid-skill hypothesis (there is no such prompt
between Step 4 bypass and Step 5 invocation). The real gap was in the SKILL.md contract itself: Step
5 said only _"On failure: report the exact `gh` error verbatim … Do not retry silently"_ and offered
no mandatory logging schedule for either branch. When `gh pr create` errored (or the surrounding
turn drifted / hit context ceiling), the last line in `build.jsonl` was the `pr-draft-approval`
bypass and the PO-agent had no `halt_code` to route on — the loop's autonomy guarantee was quietly
broken.

- **`skills/build-create-pr/SKILL.md`** (1.6.2 → 1.7.0) — Step 5 split into three mandatory
  sub-steps: (5a) pre-call `pr_created status:"start"` log so a silent process death is attributable
  to this step; (5b) `gh pr create` invocation capturing exit code and stderr to a tempfile; (5c)
  branch-specific post-processing. On success: `pr_created status:"ok"` with `pr_url` + `pr_number`.
  On failure: classify `halt_code` (`GH_AUTH_FAILED` on auth-related stderr, `PR_CREATE_FAILED`
  otherwise), emit `pr_created status:"error"` with verbatim stderr, emit the terminal
  `session status:"error"` line, emit R1 `status:"failure"` envelope, and do NOT retry or fall
  through. Return Format section now documents both success and failure envelope shapes with the
  failure envelope enumerating `"GH_AUTH_FAILED" | "PR_CREATE_FAILED"` for `data.halt_code`. New §
  _Audit invariant_ declares that the skill emits exactly one terminal `step:"session"` line per
  invocation (either `status:"ok"` or `status:"error"`, never neither) and anchors the contract to
  #169.
- **`shared/audit-contract-smoke-tests.sh`** — new grep-based smoke test asserting the mandatory
  audit contract in SKILL.md: version ≥ 1.7.0, `pr_created` events on both branches (`start`, `ok`,
  `error`), terminal `session` events on both branches, both HALT codes present, failure R1 envelope
  shape, "Audit invariant" section anchored to #169, and the failure envelope enumerating both HALT
  codes. 10/10 pass. Regression-detection verified by deleting the terminal `session status:"error"`
  line — T5 fails as expected.

---

## `build-refine` headless-context defensive guard, Step 1b (#163)

Prevents the deadlock class first observed in #160 — a headless `claude -p …` session forgetting to
thread any of the three autonomous triggers (`--autonomous`, `$AGENT_ID`, `task_id`) into a
`build-*` skill and then hanging silently when Step 1 or Step 11 fires `AskUserQuestion`. The #160
root-cause fix landed on the caller side (loop.sh now delegates to po-agent); this PR adds the
skill-side defence so any future headless caller that skips the delegation is refused loudly instead
of hanging.

- **`AUTONOMOUS-MODE.md`** — new § _Defensive-headless guard_. Documents `MAKATO_HEADLESS=1` as a
  caller-side "no human at the prompt" assertion, NOT a fourth autonomous trigger. Precedence rules:
  autonomous trigger + `MAKATO_HEADLESS` → autonomous wins; `MAKATO_HEADLESS` alone → HALT
  `MISSING_INPUT: headless-without-autonomous` before the first `AskUserQuestion`; `MAKATO_HEADLESS`
  unset → interactive path unchanged. Explains why tty auto-detection (`[[ ! -t 0 ]]`) is unsafe
  inside a Claude Code Bash tool. Names the two makato-orchestrate callers responsible for exporting
  the variable.
- **`skills/build-refine/SKILL.md`** — new _Step 1b — Headless-context defensive guard_ between Step
  1a and Step 2. HALTs with `build.jsonl` `session/error` entry and R1 `status:"failure"` envelope
  when `MAKATO_HEADLESS=1` AND no autonomous trigger fired. Cross-references #160 and #163.
- **`shared/headless-guard-smoke-tests.sh`** — new grep-based smoke test asserting the guard's prose
  contract (Step 1b heading, HALT payload, precedence documentation, ordering between Step 1a and
  Step 2) and the two caller-side wiring properties in the makato-orchestrate scripts. 5/5 pass.
- Existing `autonomous-propagation-smoke-tests.sh` continues to pass (guard is complementary, not
  conflicting).

---

## `build-simplify` Step 3 dispatches `gate-scout` authoritatively, baseline row carries `data.cmd` (#97)

Fixes the test-command-discovery hole surfaced during the #58 smoke test: Step 3 said _"Dispatch the
`gate-scout` agent (or follow `@shared/baseline-guide.md` discovery)"_, but `baseline-guide.md`
documented only the broken-baseline gate — it had no discovery algorithm to fall through to. The
makato monorepo has no `pyproject.toml`/`Makefile`/`pytest.ini` at the repo root (the harness
`pyproject.toml` lives there only since #64, and even then the unit-test command isn't pinned
anywhere a generic skill could find without `gate-scout`). An autonomous `build-simplify` run would
HALT here, and the #58 operator had to manually pick
`python3 -m pytest plugins/makato-build/shared/test_inject_context.py` and log it as a
`baseline-discovery: decision` event — the explicit failure mode this PR closes.

Picked option 1 from the issue (single-source the discovery via `gate-scout`) over option 2 (extend
`baseline-guide.md` with a discovery walker): `gate-scout` is already the single source of truth for
`build-verify` and exists precisely to avoid duplicating config-file discovery across skills.
Duplicating that map into `baseline-guide.md` would mean two places to keep in sync the next time a
project type is added.

- **plugins/makato-build/skills/build-simplify/SKILL.md** (1.4.1 → 1.4.2) — Step 3 rewritten. The
  parenthetical fallback (`"or follow @shared/baseline-guide.md discovery"`) is removed and Step 3
  now pins a hard contract: dispatch `gate-scout` with `REPO_ROOT` + empty `COVERAGE_HINT`, read
  `data.unit` from the agent's R1 envelope, run that command verbatim — do not paraphrase, do not
  pick alternatives, do not consult `baseline-guide.md` for discovery. The outcome-(a) `baseline:ok`
  row gains a `data.cmd` field carrying the exact `data.unit` string so the audit trail is
  reproducible from a fresh checkout (AC#1 of #97). Step 7 verify gate text updated to "re-run the
  same `baseline_cmd` captured in Step 3" so the verify run is provably the same command as the
  baseline. Outcome (b) text unchanged in contract but the explicit list of config files
  (`pyproject.toml`, `package.json`, …) trimmed — that list is `gate-scout`'s concern, not this
  skill's.
- **plugins/makato-build/shared/baseline-guide.md** — new § _Scope_ paragraph at the top declaring
  this guide is explicitly **not** a discovery algorithm and pointing readers at
  `agents/gate-scout.md` instead, with the #97 citation. Prevents the next contributor from
  re-introducing the same ambiguity by adding a discovery walker here.
- **tests/test_smoke_build_simplify.py** — new `test_full_arc_runner_discovered_emits_baseline_cmd`
  test reconstructing the outcome-(a) JSONL arc (runner discovered, `baseline:ok` row carries
  `data.cmd`, Step 7 verify runs with `test_suite_present:true`, Step 7a is a no-op). Asserts on
  `data.cmd` verbatim and on the absence of any `unverified-code-changes` autonomous-bypass row when
  the verify gate actually ran. With the existing `test_full_arc_no_test_runner_autonomous_mode`
  (outcome b) and `test_full_arc_doc_only_touch_is_status_success` (outcome b doc-only), the three
  tests together pin the full Step 3 contract. 42/42 pytest tests pass (39 prior + 3 here).

---

## Diff against `origin/<default-branch>`, never bare `main` (#98)

Fixes the silent stale-main pull-in surfaced during the #58 smoke test: every `build-*` skill that
diffs the feature branch resolved the integration target to the local literal `main`, but on a stale
checkout `main` lags `origin/main` between operator pulls. The triple-dot diff then pulled in
commits from already-merged PRs, so `build-simplify` would "simplify" code it did not author and
`build-review` would adversarially review code that already shipped. The reproducer in the issue
body produces 3 files-changed instead of 1 — the new smoke test pins that exact failure mode.

- **plugins/makato-build/shared/default-branch.sh** → new — resolves `origin/<default-branch>` via
  `git symbolic-ref refs/remotes/origin/HEAD`, with explicit fallbacks to `origin/main` /
  `origin/master` and a final degraded-mode fallback to the local default branch that warns to
  stderr. Callers `git fetch origin --quiet` first if they need absolute freshness; this script only
  resolves the ref name. Executable.
- **plugins/makato-build/shared/default-branch-smoke-tests.sh** → new — three sections: (1) runtime
  behaviour of the helper in an isolated sandbox repo, (2) bug reproduction proving
  `git diff main...HEAD --name-only` lists already-merged files on a stale local `main` and
  `git diff "$(default-branch.sh)...HEAD" --name-only` lists only the branch's own change, (3)
  static grep contract proving every build-\* skill / agent references the helper and contains no
  bare `git diff main...HEAD` literal. 15 checks, all green.
- **plugins/makato-build/skills/build-simplify/SKILL.md** (1.4.0 → 1.4.1) — Step 1 and Step 4
  resolve `DEFAULT_REF="$(shared/default-branch.sh)"` and run `git diff "$DEFAULT_REF...HEAD"`.
  Documents the stale-main failure mode inline so operators understand why the indirection exists.
- **plugins/makato-build/skills/build-review/SKILL.md** (1.3.2 → 1.3.3) — Step 1, Step 4
  (`CHANGED_FILES`), and Step 5 (LOC gate) all switched to `$DEFAULT_REF`.
- **plugins/makato-build/skills/build-create-pr/SKILL.md** (1.5.0 → 1.5.1) — Step 1 commit-listing
  switched to `git log "$DEFAULT_REF..HEAD" --oneline`.
- **plugins/makato-build/skills/build-push-to-git/SKILL.md** (1.4.0 → 1.4.1) — Step 6 pre-push
  commit display switched to `$DEFAULT_REF` with the `git fetch origin --quiet` prelude.
- **plugins/makato-build/agents/diff-reviewer.md** (1.2.0 → 1.2.1) — Behavior Rules and Process Step
  1 reference the helper. The diff-reviewer is dispatched by build-review and was reading the
  bare-main diff transitively.
- **plugins/makato-build/AUTONOMOUS-MODE.md** — `build-simplify` row in the WORKTREE_PATH section
  updated to reflect the new diff command.

`build-start/SKILL.md` was audited — it uses `upstream/main` for fork-distance detection, which is a
different upstream/origin axis and is left alone. `build-sensors/SKILL.md` already used
`origin/main` and is unchanged. CHANGELOG.md entries describing the historical commands are left
intact as audit trail.

---

## `build.jsonl` audit trail ships in-repo (#99)

Fixes the cross-contributor reproducibility hole surfaced while reviewing #58: every `build-*` skill
appends JSONL evidence to `specs/<key>/build.jsonl` via `shared/build-log.sh`, but `specs/` was
unconditionally gitignored — so the audit trail referenced from issue bodies and PR descriptions was
only ever visible in the original author's checkout. AC #2 of #58 ("reproducer commands work for any
reviewer") was structurally unsatisfiable.

- **`.gitignore`** — replaces the blanket `specs/` exclusion with a file-level rule: `specs/**/*`
  ignored, then `!specs/**/build.jsonl` re-includes only the audit trail. The `!specs/**/` directory
  negation alongside it lets git descend into the intermediate dirs (git can't re-include a file
  inside an excluded directory). Plan, stories, project-sync, fixtures, and every other artefact
  under `specs/<key>/` continues to stay local — only `build.jsonl` ships.
- **plugins/makato-build/AGENTS.md** § Skill Authoring — new bullet documenting the convention, plus
  an explicit safety reminder: treat `build.jsonl` as a committed evidence file, do not log secrets
  / credentials / out-of-repo paths / anything you would not paste into a public PR.
- **plugins/makato-build/README.md** § Logging — Repo policy paragraph added below the minimum log
  events list, mirroring the AGENTS.md wording so contributors reading either entry-point see the
  same rule.
- **specs/ISSUE-58-smoke/build.jsonl** + **specs/agentic-orchestration/build.jsonl** — the two
  evidence files cited in #58 and #99 ship as historical proof that the negation pattern works
  end-to-end from a fresh checkout. Both pre-date this PR; copying them in is a one-time backfill,
  not new evidence generation.

---

## Dogfood pytest harness for `build-simplify` (GAP-064 / #64 — Part B, also closes #58)

Lands the makato monorepo's own pytest harness scoped narrowly to skill smoke tests, plus the
`build-simplify` regression test that proves Part A's no-test-runner contract keeps working. With
Part A's SKILL.md contract and Part B's regression test merged, **#58** also closes — its Sub-issue
B target ("smoke-test `build-simplify` against a downstream consumer repo") was rerouted by #64 to
"dogfood inside the makato repo" once `dcp-specs` went away.

- **pyproject.toml** → new (top-level) — declares the harness scope, pytest as the sole dev
  dependency, the three `testpaths` (`tests/`, `plugins/makato-build/shared/`,
  `plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/`), and the `norecursedirs` glob that
  suppresses double-collection of stale worktree copies under `.claude/worktrees/**`. Inline
  rationale documents the explicit scope decision: this is the makato monorepo's own smoke-test
  harness, NOT a "makato is a Python package" declaration; plugin distribution remains via Claude
  Code's plugin marketplace.
- **tests/test_smoke_build_simplify.py** → new — two smoke tests that drive the full 7-step JSONL
  arc through `shared/build-log.sh` and assert (1) the on-disk JSONL audit trail matches the
  documented Step 3 / Step 7 / Step 7a shapes, (2) the synthesized R1 envelope carries the Part A
  `test_suite_present` and `degraded_confidence` fields and obeys the consistency rule
  `test_suite_present=False ⇒ degraded_confidence=True`. Test 1 covers the code-file-touch case
  (autonomous Step 7a bypass; R1 `status: "partial"`); test 2 covers the doc-only-touch case (Step
  7a no-op; R1 `status: "success"` with `degraded_confidence: true`). Why
  simulation-not-live-dispatch: the skill body is LLM-readable markdown — there is no Python
  entrypoint to import; the test validates the JSONL contract `build-log.sh` emits and the envelope
  schema downstream consumers parse, which is the actual cross-process contract Part A defines.
- **tests/fixtures/build-simplify-smoke/** → new — the synthetic `BSS-001` fixture: a `plan.md`
  describing the smoke story and a `synthetic/user_service_wrapper.ts` reproducing the "Wrapper for
  Wrapper's Sake" anti-pattern from `references/simplification-patterns.md`. Lives under
  `tests/fixtures/` rather than `specs/` directly because `specs/` is repo-level gitignored; the
  test materializes a temporary `specs/BSS-001-build-simplify-smoke/` at runtime inside a throwaway
  git repo so `build-log.sh`'s `--git-common-dir` resolver finds a real REPO_ROOT.
- **plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/conftest.py** → new — fixes the
  `ModuleNotFoundError: No module named 'fixtures'` collection error documented in #64 Part B's last
  AC. The conftest's mere presence adds the tests root to `sys.path` automatically; an explicit
  `sys.path.insert` is included as belt-and-braces so collection works regardless of the pytest
  invocation directory (repo root, plugin root, or the tests directory itself). 23
  dotx-schema-extractor tests now collect and pass cleanly from the repo-level harness.

---

## `build-simplify` no-test-runner handling (GAP-064 / #64 — Part A)

Closes the latent failure mode where `build-simplify` would crash mid-session when dispatched
against a project with no runnable test suite (docs-only repo, config-only repo, freshly scaffolded
project). Surfaced while trying to execute #58's smoke test against the makato repo itself. Part B
(dogfood pytest harness) ships in a follow-up PR.

- **skills/build-simplify/SKILL.md** → 1.4.0 — Step 3 now branches on the gate-scout outcome.
  Outcome (a) — test runner discovered — captures the baseline as before; outcome (b) — no runner —
  sets `test_suite_present: false`, skips baseline-capture, and logs a `status: "skip"` row with
  `reason: "no test runner discovered"`. Step 7 short-circuits when `test_suite_present == false`,
  skipping the test-run entirely and emitting a verify-skip log with `degraded_confidence: true`.
  New § _Step 7a — Unverified-change gate (no test runner)_ fires only when
  `test_suite_present == false` AND ≥1 applied simplification touched a file outside
  `**/*.{md,yaml,yml,json,toml}`: interactive mode prompts y/n before hand-off (n → revert +
  `UNVERIFIED_HALT`), autonomous mode skips the prompt and emits a per-AUTONOMOUS-MODE.md
  `autonomous_bypass` JSONL entry plus the upward `data.degraded_confidence: true` signal. Step 8
  hand-off message extended with a no-runner note in interactive mode. R1 envelope `data` adds
  `test_suite_present: bool` and `degraded_confidence: bool`; status mapping documents the
  autonomous-mode `partial` returned when code files were touched without a verify gate. HALT codes
  table extends with `UNVERIFIED_HALT` and clarifies `BASELINE_BROKEN` is distinct from the
  no-runner skip path.
- **AUTONOMOUS-MODE.md** — per-gate table grows a third `build-simplify` row for Step 7a (prompt
  skipped, `degraded_confidence: true` flows upward). New § _No-test-runner handling in
  `build-simplify` is a degraded-confidence path, not a HALT_ explains the design: `gate-scout`
  returning no runner is a deterministic environmental condition, not an error; the skill proceeds
  and surfaces the signal in R1 rather than halting. Names the doc/config glob
  (`**/*.{md,yaml,yml,json,toml}`) that suppresses the Step 7a gate as a no-op. Names the contrast
  with `BASELINE_BROKEN` (test runner exists but crashes — still a HALT).

---

## Headless PR-comment handling in autonomous mode (GAP-011 / #36)

Wires `build-address-pr-comments` for safe headless operation under `--autonomous`. The skill
already classified MUST-FIX / SHOULD-FIX / CONSIDER / OUT-OF-SCOPE and skipped the user-approval
gate; this entry covers the four edge cases that need extra care without a human at the prompt —
SHOULD-FIX scope creep, STRUCTURAL HALT, OUT-OF-SCOPE carry-over, and reply-text externalization.

- **skills/build-address-pr-comments/SKILL.md** → 1.4.0 — autonomous-mode policy refined. (AC2)
  SHOULD-FIX now applies only when every file the comment touches is inside the task's diff scope
  (`plan.md` `task[].file_targets[]`); out-of-scope SHOULD-FIX is marked DEFERRED with a
  `[DEFERRED]` reply, a `should-fix-scope-guard` `autonomous_bypass` entry, and an
  `out_of_scope_files[]` audit list. (AC3) STRUCTURAL MUST-FIX now triggers a dedicated Step 5a
  flow: post a single `[STRUCTURAL]` summary reply via `gh pr comment`, apply `needs-human-review`
  to PR + linked issue (auto-creating the label if absent), log per-comment + summary
  `autonomous_bypass` entries, and exit with R1 `failure` + `data.halt_code: "HALT-003"`. (AC4)
  OUT-OF-SCOPE comments now open a follow-up GitHub Issue via `gh issue create` with the
  `makato-carry-over` label (auto-created), reply with the new issue URL, and log
  `out-of-scope-carry-over` bypass; `gh issue create` failure HALTs `HALT-005` with
  `CARRY_OVER_FAILED: <comment_id>` rather than posting a half-rendered reply. (AC5) reply text
  moved entirely to the new shared template file — Step 9 renders each reply from
  `templates/pr-comment-replies.md`; hard-coded prose in the skill body is now a contract violation,
  and `RENDER_FAILED: <comment_id>` HALTs the skill rather than posting placeholders. R1 envelope
  extended with `should_fix_deferred`, `carry_over_issues[]`, and `halt_code` fields; `status`
  selection rules documented.
- **templates/pr-comment-replies.md** → new — plugin-level template directory introduced (deliberate
  exception to AGENTS.md § _Skill Authoring_ "self-contained skills" rule, pinned by AC5). One
  section per classification tier plus three autonomous-only sections (`[DEFERRED]` for scope-guard
  skips, `[OUT-OF-SCOPE]` autonomous with `<follow-up-issue>` URL, `[STRUCTURAL]` for the HALT-003
  summary). Placeholder vocabulary documented (`<commit-sha>`, `<fix-summary>`, `<reason>`, `<key>`,
  `<follow-up-issue>`, `<comment-summary>`); unsubstituted placeholders fail-loud rather than
  posting half-rendered replies. Bot-vs-human authorship treated uniformly at the reply layer
  (matches the classification guide's content-overrides-source rule). Versioning policy: adding a
  section is minor, removing/renaming is a coordinated major bump across consumers.
- **AUTONOMOUS-MODE.md** — per-gate table extended. `build-address-pr-comments` Step 5 row rewritten
  to capture the scope-guard + carry-over policy; new Step 5a row added for the STRUCTURAL HALT-003
  flow. New § _Shared reply templates — `templates/pr-comment-replies.md`_ explains the plugin-level
  template directory and why it overrides the skill-local convention. New § _Label-application
  exception — STRUCTURAL HALT-003_ documents that `build-address-pr-comments` applies
  `needs-human-review` itself (not the PO-agent) on the AC3 path and explains the idempotency
  guarantee that keeps the orchestrator's later label write a safe no-op. § _STRUCTURAL MUST-FIX is
  deliberately not auto-handled_ updated to reflect the new post-reply + label + HALT sequence.

## WORKTREE_PATH propagation hardening (GAP-017 / #46 follow-up, #85)

Follow-up hardening pass on PR #87. The 10-angle xhigh review of the initial propagation patch
surfaced 7 CRITICAL runtime bugs that block the autonomous pipeline end-to-end. This entry records
the fixes amended onto the same branch before merge.

- **shared/build-log.sh** — REPO_ROOT resolution now uses `git rev-parse --git-common-dir` instead
  of `git rev-parse --show-toplevel`. When the helper is invoked from inside a git worktree, the
  previous resolver returned the worktree path; combined with `specs/` being gitignored at the repo
  level, every JSONL entry from worktree-based sub-agents would have landed at
  `<worktree>/specs/<key>/build.jsonl` — a directory nobody else reads, splitting the audit trail
  across disconnected files. The new resolver derives the parent of the common `.git` directory and
  always points at the main checkout regardless of caller CWD.
- **AUTONOMOUS-MODE.md** — § _WORKTREE_PATH — workspace-isolation contract_ rewritten. (1) Removed
  the phantom `${AUTONOMOUS:-false}` env-var check from the falsy-check snippet — no callsite sets
  it; the canonical agent-level signal is `$AGENT_ID` plus SKILL.md-level enforcement of the
  `--autonomous` / `task_id` activation set. (2) Added § _Two roots, one contract — `WORKTREE_PATH`
  vs `REPO_ROOT`_ explaining why `specs/<key>-*/` (gitignored) must be read from the main checkout
  while source edits go to the worktree. Names the four artefact families (source edits, spec reads,
  audit-trail writes, tracked dot-files) and which root each uses. (3) Expanded the consumer-skill
  list to 8 entries — added `build-refine`, `build-simplify`, `build-address-pr-comments` plus the
  `coder` HALT-on-empty rule, matching the new entry-guard prose in those skills.
- **agents/coder.md** Phase 0 — added an autonomous-mode HALT branch. When `$AGENT_ID`,
  `$AUTONOMOUS_MODE`, or `$TASK_ID` is exported AND `WORKTREE_PATH` is empty, the agent appends a
  `step:"phase0", status:"error"` JSONL audit entry and emits R1 `failure` with
  `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]` — no silent fallback to the
  main checkout. Interactive-mode developer-hands callers keep the `git rev-parse --show-toplevel`
  fallback unchanged.
- **skills/build-push-to-git/SKILL.md** Step 8 — autonomous-mode hand-off now forwards
  `WORKTREE_PATH` alongside `--autonomous` when dispatching `/build-create-pr`. Previously the
  bundle carried only the CLI flag; `build-create-pr`'s entry guard would then HALT `MISSING_INPUT`,
  blocking the autonomous pipeline at the PR-creation hand-off. The hand-off-decision JSONL log
  entry now records `forwarded: ["--autonomous", "WORKTREE_PATH"]` for audit completeness.
- **skills/build-push-to-git/SKILL.md** + **skills/build-create-pr/SKILL.md** Step 1 — `plan.md`,
  `stories.json`, `prd.md`, `created-issues.json`, `.github/PULL_REQUEST_TEMPLATE.md` reads now
  resolve via `$REPO_ROOT/specs/<key>-*/` instead of the (empty) worktree-relative path. The
  entry-guard prose explains the rationale inline and shows the
  `git -C "$WORKTREE_PATH" rev-parse --git-common-dir` resolver. Both skills now declare REPO_ROOT
  alongside WORKTREE_PATH at the same entry-guard block.
- **skills/build-implement-tdd/SKILL.md** + **skills/build-implement-goal/SKILL.md** — entry guard
  relocated to BEFORE Step 1 (Step 1 calls `AskUserQuestion` in interactive mode; the previous
  "immediately after Step 1" prose was timing-fragile and would have deadlocked an autonomous
  dispatch with empty `WORKTREE_PATH` at the prompt). New prose also adds the `REPO_ROOT` resolution
  snippet alongside the worktree falsy-check.
- **skills/build-simplify/SKILL.md** + **skills/build-address-pr-comments/SKILL.md** +
  **skills/build-refine/SKILL.md** — added § _Input_ and § _Workspace-isolation entry guard_
  sections so the three additional autonomous-mode-callable skills behave consistently with verify /
  push-to-git / create-pr. Each declares `WORKTREE_PATH` as mandatory-in-autonomous, falls back to
  `git rev-parse --show-toplevel` in interactive mode, and resolves `REPO_ROOT` for spec-folder
  reads. The build-simplify version notes `sensor-fixer` as a separate autonomous-mode caller
  alongside the PO-agent.
- **shared/worktree-path-propagation-smoke-tests.sh** — extended from 31 to 70 contract assertions.
  New coverage: (1) all 8 consumer skills carry the entry-guard prose; (2) skills whose Step 1 calls
  `AskUserQuestion` declare "BEFORE Step 1" in the entry-guard; (3) every spec-reading consumer
  resolves `REPO_ROOT` via `git-common-dir`; (4) `build-log.sh` does NOT use bare `--show-toplevel`
  as the primary resolver; (5) `build-push-to-git` Step 8 forwards `WORKTREE_PATH` to
  `build-create-pr`; (6) `coder.md` Phase 0 declares MISSING_INPUT on empty WORKTREE_PATH and
  detects autonomous mode via `AGENT_ID`; (7) `AUTONOMOUS-MODE.md` documents the
  `Two roots, one contract` split and does NOT reference the phantom `$AUTONOMOUS` env var. Runs in
  <1s.

---

## WORKTREE_PATH propagation (GAP-017 / #46 follow-up, #85)

- **AUTONOMOUS-MODE.md** — new § _WORKTREE_PATH — workspace-isolation contract_ documents the
  dispatch-bundle field PO-agent injects on every autonomous-mode invocation. Specifies: mandatory
  in autonomous mode (HALT R1 `failure` with
  `MISSING_INPUT: WORKTREE_PATH required in autonomous mode` when empty), optional in interactive
  mode (fall back to `git rev-parse --show-toplevel`), forwarded explicitly through every hand-off,
  injected into every agent dispatch. Includes the canonical falsy-check bash snippet and the
  `git -C` vs `cd` rationale. Names the five consumer skills plus the `coder` agent.
- **skills/build-implement-tdd/SKILL.md** → 1.8.0 — new § _Input_ declares `WORKTREE_PATH` as
  mandatory-in-autonomous; new § _Workspace-isolation entry guard_ applies the falsy-check pattern
  before any plan-analyst / coder / scout dispatch. Step 6 coder-dispatch bundle and the per-task
  scout dispatch both forward `WORKTREE_PATH` verbatim.
- **skills/build-implement-goal/SKILL.md** → 1.4.0 — same pattern: § _Input_ + §
  _Workspace-isolation entry guard_; BUILD / VERIFY RUNTIME / TEST / VERIFY phases all run from
  `$WORKTREE_PATH`.
- **skills/build-verify/SKILL.md** → 1.5.0 — § _Input_ + § _Workspace-isolation entry guard_ added
  before Gate 0; gates 1–5 inherit the working directory.
- **skills/build-push-to-git/SKILL.md** → 1.4.0 — § _Input_ + § _Workspace-isolation entry guard_
  added before `git status`; ensures `git commit` / `git push` operate on the worktree's branch.
- **skills/build-create-pr/SKILL.md** → 1.5.0 — § _Input_ + § _Workspace-isolation entry guard_
  added before `git status -sb`; ensures `gh pr create` resolves the worktree's branch.
- **agents/coder.md** → 1.5.0 — new `WORKTREE_PATH` input (optional; populated by
  `build-implement-tdd` in every dispatch); new **Phase 0 — Workspace isolation** runs
  `cd "$WORKTREE_PATH"` (or the `git rev-parse --show-toplevel` fallback) before Phase 1 RED so
  every file edit, git invocation, and test command lands on the right branch.
- **shared/worktree-path-propagation-smoke-tests.sh** — new 31-check static contract test verifies:
  AUTONOMOUS-MODE.md anchors the section + falsy-check + HALT message + fallback; each of the five
  consumer skills declares the input, the entry-guard, the mandatory-in-autonomous note, and the
  fallback; coder.md declares the input + Phase 0 + the `cd` invocation; the producer→consumer chain
  (PO-agent → build-implement-tdd → coder) all reference the canonical key. Documentation/grep test
  because the consumer half is LLM instructions, not executable code — a runtime test would require
  booting the full dispatch chain and the markdown is the source of truth the LLM reads.

---

## Per-task scout wiring (GAP-013 / #29)

- **skills/build-implement-tdd/SKILL.md** → 1.7.0 — Step 6 grows a new § _Pre-flight scout dispatch
  (GAP-013 / #29)_ sub-section between the blockedBy enforcement clause and the coder dispatch. For
  every `mode: tdd` task in topological order, the skill now: (1) resolves bundles via
  `inject_context.resolve_bundles(task.files, yaml.safe_load(open('plugins/makato-build/config/context-bundles.yml')))`;
  (2) dispatches `plugins/makato-orchestrate/agents/scout.md` with `TASK_DESCRIPTION`,
  `CHANGED_FILES`, `BUNDLE_RULES` (after `{repo}` substitution), `REPO_ROOT`; (3) parses the scout's
  R1 per `RETURN-CONTRACT.md` § Caller parsing rule; (4) maps R1 status to coder input — `success`
  forwards `r1.data` as `SCOUT_SUMMARY` and mirrors R1 to `build.jsonl`; `partial` forwards the
  partial payload and emits a `scout-partial` warn entry; `failure` (or R1 contract violation) skips
  `SCOUT_SUMMARY` and emits a `scout-skipped` warn entry. Guarded: when
  `plugins/makato-orchestrate/agents/scout.md` is absent on disk (consumer repo running the build
  pipeline standalone), the scout dispatch is skipped silently and the coder is dispatched without
  `SCOUT_SUMMARY` — same cross-plugin guard pattern as the existing `workflow-state.sh patch` call
  at the end of Step 6. Scout output is **advisory**, never gating, per the GAP-013 AC.
- **agents/coder.md** → 1.4.0 — § _Input_ gets a new `SCOUT_SUMMARY` field (optional, GAP-013 / #29)
  documenting the five-field payload from `plugins/makato-orchestrate/agents/scout.md`:
  `key_patterns`, `naming_conventions`, `test_file_paths`, `existing_exports`, `warnings`.
  Absence-handling documented inline (scout failure, plugin absent, or dispatch skipped → proceed
  without it; `PLAN_CONTEXT` remains binding). New § _Behavior Rules_ clause requires the coder to
  apply `naming_conventions` for the exact `TASK.files` (overriding the broader
  `PLAN_CONTEXT.Standards` only when the two conflict for that specific file), write test files to
  the scout's `test_file_paths`, never duplicate or shadow `existing_exports`, mirror `key_patterns`
  in the RED test before introducing fresh patterns, and surface every `warnings` entry in its
  phase-end JSONL `data` so the audit trail records what the coder saw.

---

## Context bundle resolution skill (GAP-008 / #25)

- **config/context-bundles.yml** → 1.0 — new canonical bundle registry mapping changed-file globs to
  ordered rule-file paths. Defines four canonical bundles: `typescript` (`**/*.ts`, `**/*.tsx`,
  `**/*.mts`, `**/*.cts`), `python` (`**/*.py`, `**/*.pyi`), `sql` (`**/*.sql`, `**/migrations/**`,
  `**/schema/**`), and `default` (`**/*` catch-all). Rule paths use `{repo}` placeholder substituted
  by `knowledge-scout` at resolution time with the agent's `REPO_NAME` input. Schema requires every
  bundle to declare `name`, `globs[]`, and `rules[]`; the `default` bundle is mandatory — its
  absence raises HALT-006.
- **shared/inject_context.py** → 1.0 — pure-function resolver (stdlib only — no PyYAML dependency at
  the resolver layer; caller pre-parses the YAML).
  `resolve_bundles(changed_files, config) -> (rules, warning)` implements glob-specificity-first
  ordering (literal-segment count), config-declaration order tie-break, `default` bundle always
  appended last, dedup preserving first occurrence, no-match-fallback returning a
  `{"code": "no-match-fallback", "unmatched_files": [...]}` warning tuple, and
  `BundleResolutionError` carrying `halt_code="HALT-006"` when `default` is absent. Custom
  segment-wise globstar matcher (Python 3.12 stdlib `fnmatch` lacks `**` semantics;
  `pathlib.PurePath.full_match` would require 3.13+).
- **shared/test_inject_context.py** → 1.0 — 9 stdlib `unittest` cases: single-match, multi-match +
  dedup, two specificity cases (Python over default; SQL migration-path), empty input, no-match
  warning, missing-default → HALT-006, and two integration cases that load the real
  `context-bundles.yml` and exercise mixed workloads. Run via
  `python3 -m unittest discover plugins/makato-build/shared -p 'test_*.py'`.
- **skills/inject-context/SKILL.md** → 1.0.0 — new shared skill documenting the resolution contract
  (inputs, output tuple shape, warning dict schema, HALT-006 path), usage by `knowledge-scout`
  (parse → substitute `{repo}` → resolve → handle HALT/warning → pre-read up to 8 rule files), and
  the versioning policy (changes to the tuple shape, warning schema, or specificity semantics are
  major bumps coordinated with every consumer).
- **agents/knowledge-scout.md** → 1.3.0 — frontmatter description updated from 3-step to 4-step
  process; new `CHANGED_FILES` input documented; new **Step 0 — Resolve context bundles** inserted
  before the existing SPECS_ROOT discovery, with sub-steps 0a (parse `context-bundles.yml`), 0b
  (substitute `{repo}` placeholder), 0c (call `resolve_bundles`; handle HALT-006 by short-circuiting
  to R1 failure; append `no-match-fallback` warning to `build.jsonl` when surfaced), and 0d
  (pre-read up to 8 resolved rule files, tolerating missing paths). Bundle context supplements but
  does not replace dcp-specs synthesis.

---

## Semgrep route split: security vs style (#73)

- **shared/parse-sarif.py** — added `_semgrep_category()` helper and category-prefix logic in
  `parse_sarif()`. For any run whose `tool.driver.name` starts with `semgrep`, each finding's `rule`
  field is now emitted as `{category}.{original_rule_id}` (e.g.
  `security.python.lang.security.deserialization.use-of-pickle`). Category is resolved from (1)
  `result.properties.category`, (2) `rule_def.properties.tags`, (3) rule-id segment heuristic —
  first match wins, fallback is `style`. New Fixture 7 in `--selftest` covers all three resolution
  paths.
- **shared/finding-routes.json** — replaced single `semgrep:*` catch-all with two explicit routes:
  `semgrep:security.*` (fallback `build-fix-security`) and `semgrep:style.*` (fallback
  `build-simplify`). Removes incorrect routing of security findings to `build-simplify`.

---

## Definition-of-Done shared skill (GAP-009 / #28)

- **skills/definition-of-done/SKILL.md** → 1.0.0 — new canonical, versioned, machine-checkable
  Definition of Done shared across the makato-build pipeline and the makato-orchestrate PO-agent.
  **Automated tier (12 items)**: tests pass, conditional coverage ≥ threshold, lint clean,
  type-check clean, zero CRITICAL sensor findings, conventional commits, branch rebased on
  `origin/main`, no `TODO`/`FIXME` without tracking issue, no hard-coded credentials, `build.jsonl`
  entry per skill step, R1 JSON block in every agent return, PR description contains `Closes #N`.
  **Manual tier (6 items)**: all decomposed sub-tasks `status: success`, no unresolved `MUST-FIX` PR
  comments, `outer_iterations < 3` (HALT-008), `human_review_cycles < MAX` (HALT-010), no
  `needs-human-review` label, PR approved (or `skip-review` flag set). The skill is a checklist, not
  an enforcer — each item names the consumer skill/agent that enforces it. Item count is contract:
  adding, removing, renumbering, or merging items is a major bump (`1.0.0` → `2.0.0`) plus
  coordinated update to every consumer in § Cross-references.
- **agents/coder.md** → 1.3.0 — Phase 4 (VERIFY) now references `skills/definition-of-done/SKILL.md`
  Automated tier as the authoritative checklist. Items 1 (tests pass, zero new failures), 10
  (`build.jsonl` written), and 11 (R1 envelope emitted) are enforced directly in this agent; items
  2–9 and 12 are downstream. New Behavior Rules bullet forbids declaring VERIFY complete with items
  1, 10, 11 unsatisfied.
- **skills/build-verify/SKILL.md** → 1.4.0 — new `### Definition-of-Done — Automated Tier Mapping`
  section at the top of the Workflow, mapping each of the 12 automated items to its enforcing gate
  (or sibling skill) and the HALT code that fires when the item is unmet in autonomous mode
  (HALT-001/002/004/005 as applicable). Step 9 hand-off now requires every item 1–12 to be satisfied
  before printing PASS.

---

## Autofix-then-skill execution path (#60)

- **agents/sensor-fixer.md** → 1.1.0 — added Phase 0 batched-autofix pre-pass before the per-finding
  loop. The agent now groups findings by the autofix `cmd` declared in `finding-routes.json` for
  routes whose `action` is `autofix` or `autofix-then-skill`, runs each distinct cmd **once** on the
  union of touched files, re-parses, and drops resolved findings before Phase 1 dispatch begins.
  This collapses N redundant per-finding CLI invocations into one batched call and clears
  deterministic findings without any LLM round-trip. New `loop: 0` / `action: "autofix-batched"`
  audit-row shape documented in §5. R1 envelope §4a extended with `phase0_resolved` and
  `phase0_cmds_run` counters; `"autofix-batched"` joins `skills_used` when Phase 0 fires. New §3.1
  Helper Functions block defines the contracts for `finding_route_key`, `lookup_route`
  (exact-then-glob, first-match-wins — required for glob keys like `ruff:UP*` / `markdownlint:MD0*`
  / `semgrep:*` to actually match real findings), `reparse_after_autofix`, and `append_jsonl`.
  Pseudocode rewritten with quoted expansions and `read -ra cmd_argv` so multi-word route cmds
  (`"ruff check --fix --select UP"`) and file paths containing spaces are handled safely. Four new
  hard rules: NEVER skip Phase 0 when routes declare autofix; NEVER treat a Phase 0 cmd failure as
  fatal; NEVER put shell metacharacters in a route `cmd`; NEVER rely on literal `jq '.routes[$key]'`
  lookup (use `lookup_route`).
- **skills/build-resolve-finding/SKILL.md** → 1.1.0 — recognized `action: "autofix-then-skill"` as a
  valid route value in §3. New decision-tree branch routes `skill` and `autofix-then-skill` both
  into Branch 2, picking `route.skill` for the former and `route.fallback_skill` for the latter.
  Documented the post-Phase-0 invariants: a `autofix` finding arriving here is
  already-attempted-and-failed-by-the-CLI (Branch 1 runs a targeted single-file retry), and a
  `autofix-then-skill` finding arriving here goes straight to its `fallback_skill`. §4 output JSON
  now lists `autofix-then-skill` in the `action` enum. Skill-name examples extended to
  `makato-doc:markdown` for the residual MD0xx case wired by #59.

---

## Cross-plugin workflow-state hook (GAP-003 / #26)

- **skills/build-implement-tdd/SKILL.md** → 1.6.0 — added a guarded `workflow-state patch` call
  after the existing R1-mirror block on the `r1.status == "success"` branch. Cross-plugin path
  resolved via `git rev-parse --show-toplevel`; `-x` test on
  `plugins/makato-orchestrate/shared/workflow-state.sh` skips the block silently in consumer repos
  where the orchestrate plugin is absent. The call is unconditional on autonomous mode (this skill
  always runs autonomously per AUTONOMOUS-MODE.md) and conditional only on R1 success —
  `partial`/`failure` paths defer state mutation to the PO-agent (GAP-006 / #32), which reads from
  `build.jsonl`.

---

## Autonomous mode (cross-cutting, GAP-005 / #27)

- **AUTONOMOUS-MODE.md** — new convention doc at the plugin root: activation triggers (CLI
  `--autonomous`, context-bundle `task_id`, `$AGENT_ID` env var), per-gate default-taking rules,
  `autonomous_bypass` log-event schema, per-skill applicability matrix, cross-skill flag propagation
  rule, and the explicit list of skills NOT in scope (`build-sensors`, `build-verify`, the implement
  loops, the review/simplify skills, `build-resolve-finding`, `build-start`). Mirrors
  `plugins/makato-plan/skills/to-issues/SKILL.md` v3.4.0 mode-detection pattern verbatim so a
  contributor reading either plugin sees the same shape.
- **skills/build-refine/SKILL.md** → 1.6.0 — added Step 1a `Mode detection` block and Autonomous
  Execution section. In `--autonomous` mode the Step 1 work-item-key prompt requires the key as an
  argument (HALT `MISSING_INPUT` otherwise) and Step 11 plan-review (in-chat / in-browser) is
  bypassed entirely — `plan.md` is written and the skill proceeds straight to hand-off. R1 envelope
  documented; HALT codes: `MISSING_INPUT`, `SPEC_NOT_FOUND`, `MISSING_ARTIFACTS`,
  `INVALID_FILE_TARGET`, `UNCOVERED_AC`.
- **skills/build-push-to-git/SKILL.md** → 1.3.0 — added Step 1a `Mode detection` block and
  Autonomous Execution section. In `--autonomous` mode the Step 4 commit-grouping confirmation uses
  each plan task's `commitMessage` verbatim, the Step 6 push prompt is skipped (pre-push hook still
  fires), and the Step 8 hand-off auto-invokes `/build-create-pr <key> --autonomous` (flag is
  forwarded explicitly). R1 envelope documented; HALT codes: `MISSING_INPUT`, `PROTECTED_BRANCH`,
  `NOTHING_TO_COMMIT`, `COMMIT_FAILED`, `PUSH_REJECTED`.
- **skills/build-create-pr/SKILL.md** → 1.4.0 — added Step 1a `Mode detection` block and Autonomous
  Execution section. In `--autonomous` mode the Step 1 work-item-key prompt falls back to reading
  the most-recent `build.jsonl` session entry in the spec folder for `issue` and `branch` fields,
  and the Step 4 PR-draft approval is bypassed — the PR body is rendered entirely from spec
  artifacts and workflow-state with no human authoring. `Closes #<n>` injection from
  `created-issues.json` (D20) is the canonical issue-link source. R1 envelope documented; HALT
  codes: `MISSING_INPUT`, `UNPUSHED_COMMITS`, `GH_AUTH_FAILED`, `PR_CREATE_FAILED`.
- **skills/build-address-pr-comments/SKILL.md** → 1.3.0 — added Step 1a `Mode detection` block and
  Autonomous Execution section. In `--autonomous` mode the Step 5 classification approval is
  bypassed: MUST-FIX (non-STRUCTURAL) and SHOULD-FIX are auto-applied, CONSIDER and OUT-OF-SCOPE are
  skipped; STRUCTURAL MUST-FIX is deliberately NOT auto-handled — the skill HALTs with R1
  `status:"failure"` + `STRUCTURAL_BLOCKER` so the PO-agent (GAP-006 / #32) escalates to
  re-planning. Step 8 push-confirm is also skipped. R1 envelope documented; HALT codes:
  `MISSING_INPUT`, `PROTECTED_BRANCH`, `STRUCTURAL_BLOCKER`, `BUILD_FAILED`, `PUSH_REJECTED`.

---

## R1 return contract (cross-cutting, GAP-002 / #24)

- **agents/RETURN-CONTRACT.md** — new authoritative schema doc defining the R1 envelope
  (`schema`/`agent`/`status`/`summary`/`files_changed`/`tests_written`/`errors`/`tool_calls_used`/`data`).
  Per-agent rules, parsing pseudocode, and audit-log integration documented. Versioned via the
  `schema` field so future R2 can coexist during migration.
- **agents/coder.md** → 1.2.0 — added `## Output Contract (R1)` section with success/partial/failure
  mapping and the per-agent `data` keys (`phase_reached`, `unit_tests`, `integration_tests`,
  `new_failures`, `escalation`, `task_index`).
- **agents/diff-reviewer.md** → 1.2.0 — added R1 section; `status: "failure"` when CRITICAL findings
  remain; `errors[]` carries the CRITICAL finding text.
- **agents/sensor-fixer.md** — added R1 section (§4a) alongside the existing run-summary block;
  `status: "partial"` on residual carry-over; `errors[]` carries unresolved-finding fingerprints.
- **agents/knowledge-scout.md** → 1.2.0 — added R1 section; `loaded: false` graceful fall-through is
  a valid `status: "success"`.
- **agents/plan-analyst.md** → 1.3.0 — added R1 section; `data` mirrors the existing prose Plan
  Analysis metadata fields.
- **agents/gate-scout.md** → 1.3.0 — added R1 section; `data` mirrors the existing Gate Commands
  fields including `lint_ci_divergence` and `java_version_required`.
- **skills/build-implement-tdd/SKILL.md** → 1.5.0 — coder dispatch now parses the R1 envelope from
  the last `json`-fenced block via `JSON.parse()` instead of scraping prose. R1 envelope mirrored
  into `build.jsonl` under `step: "r1"` for full machine-contract preservation in the audit trail.
  Backward-compatible `task-escalate` warn entry preserved on `status: "failure"`.

---

## `build-grill-with-docs` skill

- **1.3.2**
  - sagibeast-alignment audit: flatten `description: >-` multiline folded scalar to a single-line
    string per frontmatter-spec
  - move two unkeyed prose paragraphs out of the YAML frontmatter block into a new `## When to Use`
    section in the body (the prose had no key binding and broke the YAML)

## Plugin-level

- **0.5.0**
  - Add Security Model section to README.md and AGENTS.md documenting `coder` agent's
    `bypassPermissions` scope, safeguards, and contributor rule against adding elevated permissions
    to new agents
  - Fix AGENTS.md `shared/build-log.sh` calling convention — remove stale symlink claim; document
    that skills call the script as a bare relative path from the plugin root context
  - Add `shared/baseline-guide.md` — canonical test baseline rules extracted from `implement-tdd`,
    `implement-goal`, and `simplify` skills to eliminate duplication

- **0.4.0**
  - Design Principle 4 extended: log every agent decision that deviates from the happy path using
    `status: "decision"` or `status: "warn"` — classification choices, escalations, retries, and
    workarounds must be persisted to `build.jsonl` so sessions are reconstructable

- **0.3.0**
  - Align all spec folder references from `spec/<key>/` to `specs/<key>-<slug>/` to match
    makato-plan's naming convention
  - Update `shared/build-log.sh` to resolve the spec folder via prefix-match (`find specs/<key>-*`)
    instead of an exact path
  - Update hooks to scan `specs/*/build.jsonl` and use `specDir='specs'` in embedded scripts

- **0.2.0**
  - Rename all 11 skills with `build-` prefix for unambiguous invocation
    (`/makato-build:build-refine` vs `/makato-build:refine`)
  - Add `shared/build-log.sh` script — all skills now call the script for JSONL appends instead of
    writing inline
  - Add `shared/` symlink in each skill directory so `shared/build-log.sh` is reachable without path
    escapes
  - Update hooks to match renamed skill names in JSONL `skill:` field checks

---

## `build-start` skill

- **1.3.1**
  - Step 3: remove ADR-0006 violation — `stories.json` absent path no longer invokes
    `/makato-plan:decompose` inline; now stops with a hard STOP directing the user to run
    makato-plan first and return

- **1.3.0**
  - Step 2b: upstream sync check — if an `upstream` remote exists, fetch it and warn if the branch
    base is N commits behind `upstream/main`; offer to rebase before proceeding
- **1.2.0**
  - `plan.md` already-exists path changed from hard-stop to interactive recovery: show plan summary
    and offer Continue / Start fresh (archive to `plan.md.bak`) / Implement now — applies to both
    ticket and local-work paths
  - `stories.json` absent path now checks for `prd.md` + `design.md` presence before stopping; if
    both exist, offer to run `/makato-plan:decompose` inline and continue to `/build-refine`
- **1.1.1**
  - Replace `spec/<key>/` paths with `specs/<key>-*/` prefix-match to align with makato-plan folder
    naming
- **1.1.0**
  - Add no-ticket path: user can enter a slug instead of a GitHub key; skill writes
    `spec/local-<slug>/design.md` via a 3-question interview
  - Add git pre-flight (Steps 2a–2c): clean working tree check, `git fetch + branch divergence`
    check, main/master → offer to create feature branch
  - Renamed from `start` to `build-start`
  - JSONL appends now use `shared/build-log.sh`
- **1.0.0**
  - Initial — pre-flight entry point for makato-build sessions; validates spec prerequisites,
    captures TDD vs goal mode, initializes build.jsonl session-start entry, and hands off to
    /build-refine

---

## `build-refine` skill

- **1.5.3**
  - Step 5.5 narration: drop `dcp-specs` term — knowledge graph is sourced from "project specs"
    (in-repo `<REPO_ROOT>/specs/` or `makato.config.json.specsRoot`); user-facing log line now reads
    "Knowledge graph: {N} hard constraints loaded from project specs ({source})"
  - Reflects knowledge-scout 1.1.0 contract: no sibling-directory fallback, no `dcp-specs` naming

- **1.5.2**
  - Step 8: add file target path validation — all `files` entries in each task must be relative
    paths within the repo root; skill stops and reports any path beginning with `/` or containing
    `..` before writing `plan.md`
  - Frontmatter: add `model: opus` hint

- **1.5.1**
  - Step 1: remind user of direct invocation pattern (`/makato-build:build-refine ISSUE-1234`) when
    asking interactively
  - Step 11: `AskUserQuestion` prompt reworded to "The plan is ready. How would you like to review
    it before implementation starts?" with option descriptions clarifying chat vs. interactive HTML
- **1.5.0**
  - Step 7: add mixed-mode sequencing rule — TDD tasks precede goal tasks by default; encoded as
    `runOrder: [tdd, goal]` in plan frontmatter; exception noted in Scope Flags if a goal task is a
    structural prerequisite
  - Step 8: task schema extended with `blockedBy` (list of task indices with compile-time
    dependency) and `commitMessage` (conventional commit draft pre-populated by refine); both fields
    are required in all plans
  - Step 12: add grill-with-docs recommendation rule — recommend when `glossary.md` has ≥3 terms or
    plan touches domain-specific field names; skip for infra/config-only changes
- **1.4.2**
  - Replace `spec/<key>/` paths with `specs/<key>-*/` prefix-match to align with makato-plan folder
    naming
- **1.4.1**
  - Add local-work path in Step 3: if key starts with `local-`, accept `design.md` alone (no
    `stories.json` required); derive synthetic AC-1 from goal
  - Renamed from `refine` to `build-refine`
  - JSONL appends now use `shared/build-log.sh`

---

## `build-grill-with-docs` skill

- **1.3.1**
  - Step 1: ADR path probe now loads `@references/adr-criteria.md` for the probe order instead of
    repeating the list inline
  - Step 7: ADR routing rule inline prose replaced by a reference load from `adr-criteria.md` —
    single source of truth for routing decisions
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - ADR path failure fallback: when the user skips ADRs or the directory cannot be created,
    ADR-worthy decisions are now written to `decisions.md` with `[ADR-PENDING]` marker instead of
    being silently dropped
- **1.2.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.2.0**
  - Renamed from `grill-with-docs` to `build-grill-with-docs`; JSONL appends now use
    `shared/build-log.sh`

## `build-implement-tdd` skill

- **1.4.1**
  - Step 3: replace verbose inline baseline prose with `@shared/baseline-guide.md` load; flakey test
    retry rule added — re-run single failing test once if no source code changed before classifying
  - Step 5: trim tracer bullet inline prose to load `@references/tdd-cycle-rules.md` directly;
    removes ~20 lines of duplication with the reference file
  - Step 6: add `blockedBy` cycle detection pre-flight — topological sort before first dispatch;
    stops with report if circular dependency detected
  - Frontmatter: add `model: opus` hint

- **1.4.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: baseline-gate decision logged with `status: "decision"` when user chooses to continue
    with broken baseline
  - Step 6: task escalation logged with `status: "warn"` when coder returns `escalation: refine`
  - Step 8: session summary printed from `build.jsonl` warn/decision entries at handoff; full
    remaining pipeline shown
- **1.3.0**
  - Step 3: broken baseline gate — if `pre_existing_failures > 0`, present
    Continue-with-broken-baseline vs Fix-baseline-first choice instead of silently proceeding;
    decision logged to `build.jsonl`
  - Step 5: tracer topmost-layer fallback for non-monolith — if no standard layer
    (ui/controller/service/repository/persistence) is detected, use the public entry point of the
    module being modified as the topmost layer
  - Step 6: `blockedBy` enforcement — tasks with a non-empty `blockedBy` list are not dispatched
    concurrently with their blocking tasks; hard sequencing replaces prose-only "prerequisite"
    description
  - Step 6: `commitMessage` and `blockedBy` now included in the TASK object passed to the coder
    agent
- **1.2.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.2.0**
  - Renamed from `implement-tdd` to `build-implement-tdd`; JSONL appends now use
    `shared/build-log.sh`

## `build-implement-goal` skill

- **1.3.1**
  - Step 3: replace inline baseline prose with `@shared/baseline-guide.md` load; flakey test retry
    rule added
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: baseline-gate decision logged with `status: "decision"` when user chooses to continue
    with broken baseline
  - Step 5: fix-vs-escalate decisions logged by coder agent
  - Step 7: session summary printed from `build.jsonl` warn/decision entries at handoff; full
    remaining pipeline shown
- **1.2.0**
  - Step 3: broken baseline gate — if `pre_existing_failures > 0`, present
    Continue-with-broken-baseline vs Fix-baseline-first choice instead of silently proceeding;
    decision logged to `build.jsonl`
- **1.1.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.1.0**
  - Renamed from `implement-goal` to `build-implement-goal`; JSONL appends now use
    `shared/build-log.sh`

## `build-simplify` skill

- **1.2.1**
  - Step 3: replace inline baseline prose with `@shared/baseline-guide.md` load
  - Step 4: security constraint guard added — removals of input validation,
    authentication/authorization checks, or security guards are classified as ESCALATE regardless of
    test pass/fail state

- **1.2.0**
  - Step 6: ESCALATE findings now logged to `build.jsonl` with `status: "warn"` before recommending
    re-plan
  - Step 8: handoff shows full remaining pipeline (`/build-review` → `/build-verify` → ...)
- **1.1.2**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.1.1**
  - Renamed from `simplify` to `build-simplify`; JSONL appends now use `shared/build-log.sh`

## `build-review` skill

- **1.3.2**
  - Workflow: add explicit no-commit guard — mechanical and CRITICAL fixes accumulate in the working
    tree; `git add`/`git commit` are forbidden during this skill
  - Step 5.5 (new): re-run mechanical fixes after the CRITICAL loop closes — catches formatting
    drift introduced by CRITICAL fixes before the working tree is handed to `/build-push-to-git`

- **1.3.1**
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 5: CRITICAL findings now logged to `build.jsonl` with `status: "warn"` before fixes are
    applied
  - Step 6: handoff shows full remaining pipeline (`/build-verify` → `/build-push-to-git` →
    `/build-create-pr`)
- **1.2.0**
  - Step 5: zero-findings trigger is now LOC-gated — only trigger recheck when
    `git diff main...HEAD --stat` LOC count > 50; diffs ≤ 50 LOC accept a clean first pass with
    citation record only
- **1.1.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.1.0**
  - Renamed from `review` to `build-review`; JSONL appends now use `shared/build-log.sh`

## `build-verify` skill

- **1.3.1**
  - Step 5: flakey test retry rule added — if a unit test fails but no source code changed, re-run
    once; log as flaky-pass if it passes, classify normally if it fails again
  - Step 6: same flakey retry rule applied to integration gate

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: gate-retry decisions logged with `status: "warn"` on every BUILD gate failure and retry
  - Step 4: CI lint divergence check — gate-scout `lint_ci_divergence` field consumed; both local
    and CI lint commands run when they differ; WARNING emitted if CI config is unreadable
  - Step 8: handoff shows remaining pipeline (`/build-push-to-git` → `/build-create-pr`)
- **1.2.0**
  - Step 1: JVM version mismatch detection — compare `gate-scout`'s `java_version_required` against
    `java -version`; prefix all commands with `JAVA_HOME=<path>` if they differ; emit WARNING to
    user
  - Step 5: re-run scope rule — re-run from BUILD (Gate 1) if fix touched production code; re-run
    from failed gate only if fix was test-only or config
  - Step 6: re-run scope rule applied to integration gate (same logic: BUILD re-run for production
    changes, INTEGRATION re-run for test/data/env changes)
- **1.1.1**
  - Replace `spec/<key>/` path with resolved spec folder reference to align with makato-plan folder
    naming
- **1.1.0**
  - Renamed from `verify` to `build-verify`; JSONL appends now use `shared/build-log.sh`

## `build-push-to-git` skill

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 8: after successful push, ask via `AskUserQuestion` whether to invoke `/build-create-pr`
    immediately; invokes it directly on confirmation
- **1.1.0**
  - Step 4: use `commitMessage` field from each plan task as the proposed commit message; present it
    alongside file grouping for user confirmation before Step 5
- **1.0.1**
  - Replace `spec/<key>/` path with resolved spec folder reference to align with makato-plan folder
    naming
- **1.0.0**
  - Renamed from `push-to-git` to `build-push-to-git`; JSONL appends now use `shared/build-log.sh`

## `build-create-pr` skill

- **1.3.0**
  - Auto-inject `Closes #N` into the PR body's Links section when `specs/<slug>/created-issues.json`
    is present and validates against the schema shipped by `to-issues` v3.0.0+ (path:
    `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`)
  - Dedupe against user-supplied `GH#N` references — artifact wins ties (D20)
  - Malformed or schema-invalid artifacts log a single warning and fall back to v1.2.0 behavior; PR
    creation is never blocked (D21)
  - Step 7 log entry adds `closes_injected` (count) and `artifact_status` (`valid` / `missing` /
    `malformed`) fields under `data`
  - Updated `references/pr-description-guide.md` Links Section table with the new artifact-driven
    row

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
- **1.1.0**
  - Step 5: auto-detect `GH_HOST` from `git remote get-url origin`; if hostname differs from
    `github.com`, prefix all `gh` commands with `GH_HOST=<hostname>`; prevents misleading "Head sha
    can't be blank" failure on internal GitHub instances
- **1.0.2**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan
    folder naming
- **1.0.1**
  - Renamed from `create-pr` to `build-create-pr`; JSONL appends now use `shared/build-log.sh`

## `build-address-pr-comments` skill

- **1.2.1**
  - Step 4: inline default-tier classification table removed; classification rules now loaded
    exclusively from `@references/comment-classification-guide.md`
  - Step 9: explicit `gh api` fallback commands documented for when `github-tools` MCP is
    unavailable

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
- **1.1.0**
  - Step 5: structural comment escalation flow defined — present 3-option choice (A: continue
    non-structural now, open `/build-refine` after; B: stop entirely; C: treat as regular MUST-FIX);
    after non-structural pass if (A) chosen, prompt to open `/build-refine`
- **1.0.0**
  - Initial — renamed from `address-pr-comments` to `build-address-pr-comments`; JSONL appends now
    use `shared/build-log.sh`; classify and resolve all PR comments (human and bot); four-tier
    MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE classification; posts reply per comment

---

## `knowledge-scout` agent

- **1.1.0**
  - Strip `dcp-specs` naming and remove sibling-repo fallback entirely — discovery is now strictly
    (1) `<REPO_ROOT>/makato.config.json` `specsRoot` field, (2) in-repo
    `<REPO_ROOT>/specs/index.yml`. No more `DSPEC_ROOT` variable, no
    `context/repository-registry.yml` lookup, no glob-scanning sibling directories
  - 4-step process collapsed to 3 steps: locate SPECS_ROOT → read index → synthesize. The former
    Step 2 (registry lookup) is removed; in-repo specs need no registry
  - Step 3 scoring is scope-agnostic: keyword overlap on index entries; entries whose `file` path
    contains `golden-rules`, `anti-patterns`, `harness`, `architecture`, `structure`, or `standards`
    are still preferred but not required
  - Description and mission text updated: "dcp-specs knowledge graph" → "project specs knowledge
    graph"

- **1.0.2**
  - Fix misleading description: "3-step discovery" → "4-step process" — the agent always performs 4
    steps (discover specs root, locate repo in registry, read index, synthesize); the "3-step"
    phrasing referred only to the DSPEC_ROOT sub-steps and confused callers
- **1.0.1**
  - Remove hardcoded GitHub fallback (Step 1c) — discovery is now makato.config.json specsRoot field
    → sibling scan → skip silently; project-specific GitHub URLs belong in `makato.config.json`, not
    in the agent definition
- **1.0.0**
  - Initial — read-only knowledge graph agent dispatched by plan-analyst, refine, and
    grill-with-docs; implements 4-step discovery sequence (makato.config.json → sibling scan →
    GitHub CLI → skip silently); returns Hard Constraints (golden rules, anti-patterns), Standards
    (naming/API/testing conventions), and Architecture Context for a named repository

## `coder` agent

- **1.1.0**
  - PLAN_CONTEXT input expanded to document Hard Constraints and Standards sections from the
    knowledge graph; added Behavior Rule requiring Hard Constraints to be respected as
    non-overridable project rules; Standards applied to all naming decisions

- **1.0.1**
  - Added STORY_KEY, TASK_INDEX, JSONL_PATH, TRACER_TEST_NAME to Input; coder now appends JSONL
    entries per phase (red/green/integrate/verify-task) directly to build.jsonl
- **1.0.0**
  - Initial — per-task TDD executor dispatched by implement-tdd; runs RED→GREEN→INTEGRATE→VERIFY for
    one task; enforces fix-vs-escalate threshold; returns structured result with phase reached, test
    counts, and escalation flag

## `diff-reviewer` agent

- **1.1.0**
  - Classify findings rule expanded to a 3-tier rubric with explicit decision criteria: CRITICAL =
    wrong output / security exposure / AC gap; SUGGESTION = structural improvement without
    correctness impact; NITPICK = style/clarity only; disambiguation guidance added for CRITICAL vs
    SUGGESTION borderline cases
- **1.0.1**
  - Added disallowedTools (Write, Edit, NotebookEdit); added STORY_KEY and PASS_NUMBER to Input;
    added pass-number re-review guard (PASS_NUMBER ≥ 2 only raises new findings); clarified agent is
    report-only — calling skill applies all fixes
- **1.0.0**
  - Initial — adversarial branch diff reviewer dispatched by review; applies seven quality
    categories (correctness, edge cases, error handling, security, contract, test coverage,
    optimizations); classifies findings as CRITICAL/SUGGESTION/NITPICK; produces source-anchored
    citation record on zero-CRITICAL passes

## `gate-scout` agent

- **1.2.0**
  - Step 2c (new): CI lint divergence detection — probes `.github/workflows/`, `Jenkinsfile`,
    `.gitlab-ci.yml`, `.circleci/config.yml` for lint commands; compares to locally-discovered lint
    command; emits `lint_ci_divergence` and `lint_ci_command` in output
  - Output format: added `lint_ci_divergence` and `lint_ci_command` fields
- **1.1.0**
  - Step 2: Maven unit command now surfaces Surefire `<groups>`/`<excludedGroups>` flags as distinct
    unit vs integration commands when both Surefire and Failsafe are configured
  - Step 2: pytest unit command derived from marker config — `pytest -m "not integration"` when
    `integration` marker is defined in `[tool.pytest.ini_options]`
  - Step 2b (new): JVM version detection for Maven/Gradle projects — reads `<java.version>` /
    `maven.compiler.source` (pom.xml) or `sourceCompatibility` / `java.toolchain.languageVersion`
    (build.gradle); emits `java_version_required` in output
  - Output format: added `java_version_required` field
- **1.0.1**
  - Default coverage threshold to 80% when COVERAGE_HINT is not provided — aligns with project
    standard for new code; story-specific threshold passed via COVERAGE_HINT still overrides
- **1.0.0**
  - Initial — read-only gate command discoverer dispatched by verify; scans package.json, pom.xml,
    build.gradle, Makefile, pyproject.toml for build/lint/unit/integration/coverage commands;
    coverage threshold passed via COVERAGE_HINT by the calling skill (not auto-read from design.md);
    returns structured command map with detected project types

## `plan-analyst` agent

- **1.2.0**
  - Step 2: `tracer_required` heuristic changed from layer-count (≥3 layers) to file-creation + new
    dependency edge — `true` only when at least one file is `create` AND the created file introduces
    a new cross-layer dependency edge; additive-only plans (`modify` only) default to
    `tracer_required: false`
- **1.1.1**
  - Remove duplicate `## Process` heading that split Step 0 from Steps 1–4 into two disconnected
    sections
  - Fix stale `github` value in `knowledge_context_source` output field — knowledge-scout v1.0.1
    removed GitHub discovery; valid values are now `local | none`
- **1.1.0**
  - Step 0: dispatch knowledge-scout agent before plan analysis; REPO_NAME derived from REPO_ROOT
    last segment; keywords extracted from task titles; Hard Constraints, Standards, and Architecture
    Context sections added to output; knowledge_context_loaded and knowledge_context_source added to
    output metadata
- **1.0.0**
  - Initial — read-only plan classifier dispatched by implement-tdd and implement-goal; reads
    plan.md and glossary.md; returns task list with tdd/goal mode, architectural layer detection,
    tracer_required flag, glossary constraints, and reusable codebase patterns; build tool
    identification uses config files (package.json, pom.xml, build.gradle, pyproject.toml) directly
    — no cross-agent dependency

## `post-implement` hook

- **1.1.1**
  - How It Works: document Node.js as a runtime prerequisite; list all silent-exit cases explicitly
    so users can diagnose when auto-continuation doesn't fire

- **1.0.1**
  - Add note that Stop hook stdout injection is an observed behavior, not a documented contract; if
    /simplify does not trigger automatically, run it manually
- **1.0.0**
  - Initial — fires on Stop event after implement-tdd or implement-goal session ends with status:
    ok; automatically invokes /simplify with the same work item key; hook command discovers active
    story by finding most recently modified build.jsonl; no user prompt required

## `pre-push` hook

- **1.1.1**
  - How It Works: document Node.js as a runtime prerequisite; list all silent-exit cases explicitly
    including JSON parse errors and missing push entries

- **1.0.2**
  - Tighten verify pass check: only skip warning when both an implementation session AND a verify
    session exist in build.jsonl and verify is after implementation; previously a verify-only file
    (no implementation history) would always pass silently
- **1.0.1**
  - Redesign from PreToolUse/Bash (blocking, relied on undocumented CLAUDE_TOOL_INPUT_COMMAND env
    var) to Stop hook (advisory); hook now detects a completed push-to-git session in build.jsonl
    and warns if no verify pass exists after the last implementation session; warning is injected as
    context, not a process exit
- **1.0.0**
  - Initial — fires on PreToolUse for Bash tool when command contains git push; checks build.jsonl
    for a verify session-end entry (status: ok) that is more recent than the last
    implementation/review session-end entry; story key discovered dynamically from most recently
    modified build.jsonl; halts with an error message if no valid verify pass is found

---

## `grill-with-docs` skill

- **1.2.0**
  - Step 3: dispatch knowledge-scout agent with candidate term list as keywords; learnings-based
    findings suppress re-raising resolved terminology conflicts; Hard Constraints and Standards from
    knowledge graph injected as conflict evidence
- **1.1.0**
  - Replace CONTEXT.md + context-snapshot.md with direct enrichment of `spec/<key>/glossary.md` (the
    feature vocabulary written by `/makato-plan:grill`); adds `_Code_:` annotations for codebase
    conflicts; removes repo-detection logic and per-story snapshot file — one glossary, one truth
  - `implement-tdd` and `implement-goal` updated to read `glossary.md` instead of
    `context-snapshot.md`
  - `context-md-format.md` reference updated to describe glossary enrichment (entry annotation
    rules, `_Code_:` format, purity rules)
- **1.0.0**
  - Initial — aligns implementation plan terminology to the codebase domain model; probes codebase
    for canonical names; conducts adversarial alignment interview (Q1/Q2/…); writes `CONTEXT.md`
    with repo-detection logic (single, monorepo, multi-repo); writes
    `spec/<key>/context-snapshot.md`; routes decisions to `decisions.md` vs ADR via three-criteria
    test; ADR path lookup with per-repo discovery and `docs/governance/adr/` default; complexity
    signals trigger Opus recommendation

## `address-pr-comments` skill

- **1.0.1**
  - Step 9: prefer `mcp__github-tools__add_reply_to_pull_request_comment` over raw `gh api` for
    posting replies; `gh api` kept as fallback when MCP is not configured
- **1.0.0**
  - Initial — classify and resolve all PR comments (human and bot); four-tier
    MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE classification with source-heuristic defaults for bot
    comments; presents classification for approval; implements fixes grouped by file; re-runs build
    and unit gates; commits and pushes with interactive confirmation; posts reply per comment

## `create-pr` skill

- **1.0.1**
  - Step 3: use `.github/PULL_REQUEST_TEMPLATE.md` (already loaded in Step 1) as the body structure
    instead of constructing a free-form body; maps each template section to a spec artifact source
- **1.0.0**
  - Initial — draft PR description from spec artifacts (ACs→How to Test, plan tasks→What changed,
    prd.md→Goal Alignment); optional GitHub `Closes #N` issue linking; interactive draft review
    before `gh pr create`

## `push-to-git` skill

- **1.0.0**
  - Initial — atomic conventional commits from plan task structure; one commit per task with tests
    bundled; staged per-file (never `git add -A`); interactive push confirmation before affecting
    remote; verbatim error reporting on push rejection

## `verify` skill

- **1.1.0**
  - Step 1: replace gate-definitions.md reference with gate-scout agent dispatch; agent receives
    REPO_ROOT and COVERAGE_HINT (threshold extracted from design.md) and returns exact
    build/lint/unit/integration/coverage commands; skill uses returned command map for all gates
- **1.0.0**
  - Initial — sequential gate pipeline (build → lint → unit → integration → conditional coverage);
    each gate runs separately so failures are attributable; re-runs from the failed gate after a
    fix; structural failures escalate to `/refine`

## `review` skill

- **1.1.0**
  - Step 4: replace inline adversarial analysis with diff-reviewer agent dispatch; agent receives
    STORY_KEY, PASS_NUMBER, CHANGED_FILES, PLAN_CONTEXT, REPO_ROOT and returns
    CRITICAL/SUGGESTION/NITPICK findings; skill handles CRITICAL fix loop and re-dispatch
- **1.0.1**
  - Step 4: add explicit `git diff main...HEAD -- <file>` command for reading per-file diffs;
    prevents agents from picking inconsistent diff ranges
- **1.0.0**
  - Initial — autonomous adversarial review loop; auto-fixes mechanical issues silently before
    reporting; CRITICAL findings loop until clean; zero-findings first pass triggers mandatory
    source-anchored recheck (every changed file must be cited with path, line range, and evidence)

## `simplify` skill

- **1.1.1**
  - Step 3: remove hard-stop on pre-existing test failures; record failing count as the
    pre-simplification baseline and proceed — only _new_ failures introduced during the session
    block in Step 7
- **1.1.0**
  - `repo-patterns-guide.md`: replace stale `CONTEXT.md` + `context-snapshot.md` references with
    `spec/<key>/glossary.md` (single glossary source since grill-with-docs 1.1.0)
- **1.0.0**
  - Initial — interactive complexity review post-implementation; checks against AI over-engineering
    anti-pattern catalog and local repo conventions; presents SIMPLIFY/KEEP/ESCALATE findings for
    approval before applying; verifies zero new failures after changes

## `implement-goal` skill

- **1.1.0**
  - Step 4: replace manual plan.md + glossary.md reads with plan-analyst agent dispatch; agent
    returns task list, layer classification, glossary constraints, and reusable patterns —
    implement-goal consumes the Plan Analysis output directly
- **1.0.0**
  - Initial — autonomous BUILD→VERIFY RUNTIME→TEST→VERIFY loop for UI, config, and migration work;
    post-implementation tests document observed behavior (not internal state); conditional branch
    coverage gate

## `implement-tdd` skill

- **1.2.0**
  - Step 4: replace manual plan.md + glossary.md reads with plan-analyst agent dispatch; agent
    returns structured Plan Analysis (task list, layers, tracer_required, glossary constraints,
    reusable patterns)
  - Step 6: replace inline TDD loop with coder agent dispatch per task; skill passes TASK,
    TASK_INDEX, STORY_KEY, JSONL_PATH, PLAN_CONTEXT, TRACER_TEST_NAME, BASELINE_FAILURES, REPO_ROOT;
    coder appends JSONL directly and returns status/escalation
- **1.1.0**
  - Tracer Bullet phase: conditional pre-loop step for plans spanning ≥ 3 distinct architectural
    layers; detects layers from plan file targets; writes thin stubs and one end-to-end integration
    test before the per-task loop; tracer test stays green throughout as stubs are replaced;
    `tdd-cycle-rules.md` extended with Tracer Bullet Phase section
- **1.0.0**
  - Initial — autonomous RED→GREEN→INTEGRATE→VERIFY loop per task; unit tests first (isolated,
    mocked), then integration tests against real dependencies; conditional branch coverage gate
    before advancing to next task

## `refine` skill

- **1.4.1**
  - Step 5.5: remove stale `→ GitHub` from discovery description and remove `github` from log schema
    source enum — knowledge-scout v1.0.1 removed GitHub discovery; valid source values are
    `local | none`
- **1.4.0**
  - Step 5.5 (new): dispatch knowledge-scout before local context/ exploration; REPO_NAME derived
    from target repo root last segment; Hard Constraints from knowledge graph applied as mandatory
    plan rules; Standards applied as naming/pattern conventions; constraint count surfaced in plan
    summary to user
- **1.3.0**
  - Step 1: use `AskUserQuestion` tool as fallback when no argument is passed, instead of a plain
    text prompt
  - Step 4: document that `stories.json` is the authoritative source over the GitHub issue when
    content diverges
  - Step 6: check for pre-built `context/` directory at the target repo root before direct file
    exploration; validate freshness via timestamp in `index.yml` / `index.md`; add optional
    `gh pr list` hint to surface recent merged changes
  - Step 11: add `AskUserQuestion` for terminal vs browser review choice; browser path generates
    `spec/<key>/plan-review.html` from `templates/plan-review-template.html` and opens it
  - New: `templates/plan-review-template.html` — 3-slide HTML review page (Story overview, Task
    list, AC coverage) with per-slide feedback textareas and "Copy All Feedback" button, consistent
    with makato-plan review templates
- **1.2.0**
  - Step 2: if `spec/<key>/` does not exist, stop and redirect the user to run
    `/makato-plan:decompose` before returning to `/refine`
- **1.1.0**
  - Read `AGENTS.md` and `CLAUDE.md` from the target codebase root at the start of Step 6; extracts
    project goal, decision test, naming conventions, and contributor constraints as hard constraints
    on the implementation plan
- **1.0.0**
  - Initial — bridges planned work items to implementable plans; reads GitHub issue and spec/
    artifacts (prd.md, design.md, decisions.md); produces plan.md with tasks, file targets,
    unit/integration test strategy, and AC mapping; interactive; entry point to the build pipeline

## Plugin-level (initial releases)

- **0.2.0**
  - add full build pipeline: refine, implement-tdd, implement-goal, simplify, review, verify,
    push-to-git, create-pr, address-pr-comments; all skills emit JSONL build audit log to
    `spec/<key>/build.jsonl`
- **0.1.0** — 2026-05-14
  - initial plugin with governance files, plugin manifest (`plugin.json`), contributor guide
    (`AGENTS.md`)
