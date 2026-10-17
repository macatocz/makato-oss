---
name: build-verify
description: >-
  Run the whole-change quality gate pipeline — build, lint, unit tests, and
  locally or CI-owned integration and coverage checks. Code-level failures go
  to bounded coder repair and independent re-review (default 3 rounds);
  structural failures escalate to refine. Autonomous (--autonomous, dispatched
  by PO-agent) or interactive. Use after review, before push-to-git. Triggers:
  verify, quality-gate, all-gates, build-pass, tests-pass, lint-clean,
  coverage-check, gate-pipeline, run-verify.
version: "1.15.0"
argument-hint: "[work-item-key]"
allowed-tools: [Bash, Read]
---

## When to Use

Use after `/review` and before `/push-to-git`. The code has been reviewed and simplified.
This step answers: *"Does it actually work?"* — build succeeds, lint passes, unit tests
pass, and integration/coverage are verified by the local gates or required CI checks.

`build-verify` owns whole-change gate verification. It runs integration locally only
when gate-scout finds no CI integration lane; otherwise the required CI check owns
Gate 4. TDD coders run only task-targeted checks. This skill consumes the reusable
baseline recorded by either implementation skill and never treats a caller's test
run as coder verification.

All audit writes use `"$MAKATO_BUILD_ROOT/shared/build-log.sh"`. Construct dynamic
JSON with `jq -cn` and pass `"$ENTRY"` as one argument without another shell-parsing
layer; never interpolate JSON inside an outer quoted `bash -c` command. Check the
helper exit code and fix rejected quoting instead of appending raw text.

Each child must read the R1 return contract and end with its fenced JSON envelope,
including `tool_calls_used`. Preserve already measured gate evidence when fixing a
return-format error; never invent a child result or count invalid returns as passes.

## Anti-patterns

These failure modes are only learnable from production incidents — they are non-obvious
and each has caused gate false-negatives or false-positives in real sessions.

**NEVER strip the Python runner prefix from gate-scout commands, and NEVER re-add it
manually.**
WHY: `uv run`/`poetry run` resolves dependencies from the project-local lockfile venv. A
bare `pytest` or `ruff` invocation uses the system Python, which lacks the locked
dependencies → `ModuleNotFoundError` or a different package version produces a spurious
pass or fail signal that does not reproduce in CI.

**NEVER choose a Gate 0 scope narrower than the CI sensor lane.**
WHY: a changed-file CI lane requires `branch` so the local scan covers the branch
diff plus uncommitted work; an `--all-files` CI lane requires `all`. Selecting a
smaller staged subset lets CI-only failures through, while scanning all files
when CI scopes to the diff spends time on unrelated repository debt.

**NEVER treat exit code 0 as a gate pass without error-count parsing (Gates 1 and 2).**
WHY: pyright and ruff both have known exit-code bugs where errors are printed but exit
code is 0. The inverse also occurs: `pre-commit run --hook-stage manual` exits 0 with no
stdout when no hooks match the `manual` stage — a silent skip that looks like a pass.
Always parse the error-count pattern AND detect empty stdout before recording a pass.

**NEVER infer gate commands independently of gate-scout output.**
WHY: the project may use a lockfile runner prefix (uv/poetry), CI-divergent flags, or a
non-standard hook ID. Independent inference produces commands that differ from what CI
runs. Gate-scout's runtime discovery (config scan + hook probe) is the only authoritative
source.

**NEVER run integration tests against an environment that failed setup.**
WHY: a partial environment causes tests to either skip silently or fail for infrastructure
reasons unrelated to the code change. The failure signal is unattributable — it looks like
an integration failure but is an environment failure. Fail hard on setup and report the
blocker before entering the test run.

**NEVER re-run all gates when the fix is test-only or config-only.**
WHY: re-running BUILD and LINT after a test-file change wastes time and risks surfacing
pre-existing lint debt as new failures. The re-run scope rule (Steps 6 and 7) applies: re-
run from BUILD only if production code changed; re-run from the failed gate only for test-
only or environment-only fixes.

**NEVER edit source to repair a code-level gate failure.** Only deterministic
formatter/autofix commands supplied by gate-scout may edit files before coder
dispatch. Remaining BUILD, LINT, UNIT, mandatory INTEGRATION, or blocking
COVERAGE failures go through the bounded verify-repair loop below; environment
and setup failures remain blockers.

## Input

When dispatched by the PO-agent (`--autonomous` mode), this skill receives:

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). The skill MUST `cd "$WORKTREE_PATH"` before any build/lint/test/coverage gate command — gates that run from the wrong checkout produce nonsense pass/fail signals.
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root. Resolve from
  `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` when the caller does
  not supply it; use it for suite-owned helpers and contract references.
- `--autonomous` — activation flag.
- `BASELINE_FAILURES` — `data.failures` from the reusable baseline row recorded by
  `build-implement-tdd` or `build-implement-goal`; preserve it when comparing
  whole-suite results and dispatching coder repairs. Never capture a post-change
  run as the baseline.
- `GATE_COMMANDS` — gate-scout's command map, with runner prefixes unchanged.
- `PLAN_CONTEXT` — the resolved task list, acceptance criteria, and constraints.
- `STORY_KEY` and `JSONL_PATH` — the work-item key and
  `$SPEC_FOLDER/build.jsonl`.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Gate 0. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` — every gate command below runs from this CWD.

## Workflow

### References

#### `references/gate-definitions.md` — toolchain command tables

**MANDATORY: load before Gate 1 (Step 4) or Gate 2 (Step 5) when** gate-scout returns a
toolchain not covered by the four-path Gate-0 reuse/direct-hook/missing-hook/legacy
command selection — for example: Maven, Gradle, Go, Rust, Biome, or sqlfluff projects
where exact hook IDs, unit/integration split flags, or runner conventions are not
obvious from gate-scout output.

**Also load when** the unit/integration split convention for the detected toolchain is
ambiguous and gate-scout does not populate a separate `unit_cmd` / `integration_cmd`.

**Do NOT load** when gate-scout's `build_hook_cmd` or `lint_hook_cmd` is non-null and the
four-path command selection in Steps 4–5 already resolved the command unambiguously —
the hook is the authoritative CI-parity path and the reference adds no new information.
Do NOT load for Python or JS/TS projects where the runner prefix and hook path are
already populated in gate-scout output.

---

### Definition-of-Done — Automated Tier Mapping

The gates below collectively enforce the **Automated tier (13 items)** of
`plugins/makato-build/skills/definition-of-done/SKILL.md`. Each row maps a DoD item to
the gate that enforces it and the corresponding fail-closed outcome in autonomous mode,
including bounded repair exhaustion.

| # | DoD item | Enforced by | HALT on unmet (autonomous mode) |
|---|----------|-------------|---------------------------------|
| 1 | All tests pass | Gate 3 (Unit) + Gate 4 (Integration; local or required CI check) | bounded coder verify-repair for local new failures; CI failures → `build-fix-ci`; exhaustion → HALT-002 |
| 2 | Coverage ≥ threshold | Gate 5 (local threshold or required CI threshold) | coverage-raise repair rounds (edge-case tests for the lowest-covered files) when the local data covers every lane; CI-owned threshold is advisory locally and `build-fix-ci` raises it; exhaustion → HALT-002 |
| 3 | Lint clean | Gate 2 (Lint) | deterministic gate-scout autofix, then bounded coder verify-repair; exhaustion → HALT-002 |
| 4 | Type-check clean | Gate 1 (Build) | bounded coder verify-repair; exhaustion → HALT-002; structural escalation → `/build-refine` |
| 5 | No CRITICAL sensor findings | Gate 0 (Sensors) | HALT-001 (sensor-fixer exhausted) / HALT-004 (same finding 5×) |
| 6 | Conventional commits | `build-push-to-git` (per-commit drafting) | denied push → HALT-005 |
| 7 | Rebased on `origin/main` | `build-push-to-git` push deny-list | denied push → HALT-005 |
| 8 | No `TODO`/`FIXME` without tracking issue; no debug/stale artifacts introduced | sensors `todo-check` + `stale-artifact-check` | HALT-001 family |
| 9 | No hard-coded credentials | sensors `gitleaks` / `detect-secrets` | HALT-001 family |
| 10 | `build.jsonl` entry per skill step | every skill via `"$MAKATO_BUILD_ROOT/shared/build-log.sh"` | contract — caller treats omission as agent failure |
| 11 | R1 JSON block as last fenced ` ```json ` in agent return | `plugins/makato-build/agents/RETURN-CONTRACT.md` | caller treats missing/invalid R1 as `status: "failure"` |
| 12 | PR description contains `Closes #N` | `build-create-pr` description draft | interactive review catches omission before PR is opened |
| 13 | Skill-provenance recorded and complete | Step 9 (skill-provenance advisory gate) in this skill | advisory only — never fails the build (NFR-R2) |
| — | Runtime health-check passes | Step 8b (Gate 6: advisory) in this skill | advisory only — non-zero exit logged, build continues |

A failure to satisfy any item in this table **MUST** trigger the corresponding HALT code
at the gate that enforces it; the autonomous loop does not proceed past an unmet item.
When this skill runs, gates 0–5 cover items 1–5; items 6–9 and 12 are enforced by
sibling skills called later in the pipeline; items 10 and 11 are enforced at every
skill / agent boundary in the session, including by this skill on itself.

### Step 1 — Ask for work item key and load context

**Interactive mode** (no argument passed): use `AskUserQuestion` with two options:

1. **Auto-detect from current branch** — run `git branch --show-current | grep -oE '[0-9]+'` and use the leading numeric segment as the key
2. **Enter manually** — free-text prompt: "Which work item are we verifying? (e.g. #123)"

**Autonomous mode** (`--autonomous`): use the passed `<work-item-key>` argument directly — do not prompt.

Read `design.md` from the resolved spec folder (`specs/<key>-*/`) if it exists and look for a declared coverage threshold.
If none is declared, the coverage gate is advisory — it reports figures but does not block.

**Runtime verification — read from plan**: read `plan-<N>.md` from the resolved spec folder (match `plan-<ISSUE_NUMBER>.md` where `ISSUE_NUMBER` is the leading numeric segment of the work-item key, or fallback to `plan.md` if the per-issue file is absent). Look for a `## Runtime verification` section. Extract the shell command from the first fenced code block inside that section and set `PLAN_RUNTIME_CMD` to that value. When the section is absent, empty, or contains no fenced code block, set `PLAN_RUNTIME_CMD` to empty string. This extraction is the only place plan-command reading happens — `gate-scout` MUST NOT be modified to read `plan.md`.

```bash
# Example extraction (pseudo-code):
PLAN_FILE="$(ls specs/<key>-*/plan-<ISSUE_NUMBER>.md 2>/dev/null | head -1)"
PLAN_FILE="${PLAN_FILE:-$(ls specs/<key>-*/plan.md 2>/dev/null | head -1)}"
# Extract the command inside the fenced block that follows ## Runtime verification
PLAN_RUNTIME_CMD="$(awk '/^## Runtime verification/{found=1} found && /^```/{if(++fence==1){next} else {exit}} found && fence==1{print}' "$PLAN_FILE" 2>/dev/null | head -1)"
```

Dispatch the `gate-scout` agent with:
- `REPO_ROOT`: absolute path to the target repository root
- `COVERAGE_HINT`: the coverage threshold extracted from `design.md` (or empty string if none declared)

The agent scans config files and CI definitions, then returns a structured command map with the exact build, lint, unit, integration, coverage, CI ownership, sensor scope, and JVM-version fields. Use this map for all subsequent gates — do not infer commands independently.

**Artifact handoff guard:** Read `local://` or `artifact://` only when that
exact URI was emitted by a preceding tool or agent in this run. Never invent a
placeholder such as `local://no-such`. If no URI was emitted, use the canonical
repository path already resolved in Step 1; if that path is missing, report the
missing artifact and stop the affected gate rather than probing guessed URIs.

**Coverage command contract:** use `unit_coverage` for fresh unit collection,
`integration_coverage` to append local integration coverage, `coverage_append`
to append named test files during a coverage-raise round, and `coverage_report`
to report collected data without running tests. Use `coverage` only as the legacy
all-in-one fallback when the split commands are absent. Treat each command as an
executable string and `coverage_threshold` as separate metadata; never execute a
command containing a human-readable suffix such as `— threshold: 95%`.

**Report-output contract:** test reports belong in the resolved spec folder, never in
the repository root. gate-scout may copy CI report options such as
`--junitxml=results.xml`. CI writes them into a disposable runner workspace, but run
verbatim from `WORKTREE_PATH` they create or overwrite a file in the checkout root.
Before executing any gate command, rewrite every test-report path that is relative or
inside `WORKTREE_PATH` (`--junitxml=<path>`, `--junitxml <path>`, `--junit-xml=<path>`)
to `<spec-folder>/<stem>-<ISSUE_NUMBER><ext>`. For example, `--junitxml=results.xml`
becomes `--junitxml=specs/<key>-<slug>/results-<N>.xml`. Without an `ISSUE_NUMBER`,
keep the basename. Leave the rest of the command, and report paths outside the
workspace, unchanged. Gates 4 and 5 log the rewritten path as `junit_report`.

**MANDATORY: load `references/gate-definitions.md`** if gate-scout returns a toolchain
(Maven, Gradle, Go, Rust, Biome, sqlfluff) for which the four-path command selection in
Steps 4–5 does not cover the exact hook IDs, split flags, or runner conventions. For
Python/JS/TS with populated hook commands, skip the reference.

**Python runner prefix**: if `python_runner_prefix` is present and not `"none"` (e.g. `uv run`, `poetry run`), the gate-scout commands already include it. Run them verbatim — do NOT strip the prefix and do NOT re-add it. A bare `pytest`/`ruff` invocation in a lockfile-managed project resolves against the system Python and fails with `ModuleNotFoundError`.

**Extra linters**: if `lint_js` or `lint_sql` are present and not `"not found"`, run them as additional LINT-gate commands alongside the primary `lint` command. Each must pass independently; a failure in any is a LINT-gate failure. Log each under its own `data.linter` key.

**JVM version check** (Maven/Gradle projects only): if `java_version_required` is present in the gate-scout output, run `java -version` and compare the major version. If they differ, emit a WARNING:

> "[WARNING] JVM mismatch: project requires Java `<required>`, system default is Java `<actual>`. All build and test commands in this session will be prefixed with `JAVA_HOME=<java_home_path>` to ensure the correct version is used."

Resolve the correct `JAVA_HOME` path for the required version (e.g. via `$(dirname $(dirname $(readlink -f $(which java))))` or by checking common SDK manager paths). Prefix all gate commands with `JAVA_HOME=<resolved_path>` for the rest of this session.

---

### Step 2 — Resolve the repair-round cap and log session start

Set `MAX_REPAIR_ROUNDS` from `MAKATO_MAX_REPAIR_ROUNDS`. It must be a positive
integer; if unset, use `3`; if invalid, log a warning and use `3`. This cap
applies to this build-verify loop only, independently of build-review. One round
is a coder repair dispatch followed by independent diff review and the scoped
gate re-check. Initialize `repair_rounds` to `0`.

For an invalid value, log:

```json
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"verify-repair","status":"warn","data":{"reason":"invalid MAKATO_MAX_REPAIR_ROUNDS","fallback":3}}
```

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"start","data":{"coverage_threshold":"<X>%|none","max_repair_rounds":<MAX_REPAIR_ROUNDS>}}'
```

---

### Step 2a — Bounded coder verify-repair loop

Build `VERIFY_FINDINGS` from every blocking code-level gate failure using this
shape:

```json
{"id":"UNIT-test_name","gate":"unit","command":"<exact gate-scout command>","failing":["test_name"],"excerpt":"<relevant command output>","log_path":"<actual retained gate log>"}
```

Use one stable ID per finding; `gate` is exactly `build`, `lint`, `unit`,
`integration`, or `coverage`; `command` is the exact executable gate-scout
command, including its runner prefix. `failing` contains test IDs, file:line
locations, or uncovered branch identifiers as applicable; for a coverage finding
it lists the target files, and the finding adds a `coverage` object with the
guide's `{threshold,total,needed,targets}` record. Retain each gate's
raw output in a per-run file under `$SPEC_FOLDER` and set `log_path` to that
file's actual path; never invent an excerpt, failure, or path. Compare UNIT and
INTEGRATION failures against `BASELINE_FAILURES`. A UNIT test or mandatory
local INTEGRATION test becomes a finding only after its one allowed single-test
flaky re-run still fails. CI-owned integration is skipped locally; its required
CI check is owned by `build-fix-ci`, not this coder loop. Only mandatory local
INTEGRATION failures block; non-mandatory local failures remain advisory. The
loop starts with at least one gate finding; if a repair-delta review adds
blockers after a gate re-check passes, continue the already-active loop with an
empty `VERIFY_FINDINGS` array and those findings separately in `REVIEW_FINDINGS`.

Before creating a finding, separate code-attributable failures from command,
tooling, external-service, and setup errors for every gate. Preserve the actual
output and report environment/setup failures as blockers without coder dispatch;
they are never passes or `VERIFY_FINDINGS`.

Gate 0 remains separate: sensor-fixer repairs use the shared Phase 1 budget from
build-sensors; sensor findings never become coder `VERIFY_FINDINGS`.

For each repair round:

1. Before each coder dispatch, capture the current changed/untracked file set and
   contents as a pre-repair snapshot. Dispatch `coder` in verify-repair mode with
   `VERIFY_FINDINGS`, `WORKTREE_PATH`, `REPO_ROOT`, `MAKATO_BUILD_ROOT`,
   `JSONL_PATH`, `STORY_KEY`, `PLAN_CONTEXT`, `GATE_COMMANDS`,
   `BASELINE_FAILURES`, `REPAIR_ROUND` (the next round number), and
   `MAX_REPAIR_ROUNDS`. Include any blocking findings from the previous
   independent diff review as a separate `REVIEW_FINDINGS` field; do not
   mislabel review findings as gate failures. Read the verification-ownership
   paragraph from `$MAKATO_BUILD_ROOT/config/verification-ownership.md` at
   dispatch time and place it verbatim in the coder Task context. The coder runs
   targeted commands covering the supplied findings and tests touching repaired
   files; build-verify owns local integration/full-suite gates, while required
   CI-owned integration checks remain with `build-fix-ci`.
2. Require coder R1 `data.mode:"verify-repair"`, matching `repair_round`,
   `repaired_findings`, `unresolved_findings`, and `data.details.per_finding`. A
   successful response must report every supplied finding repaired, no
   unresolved findings, and passed verification. Each finding entry must include
   `id`, `root_cause`, `changes`, and a passed
   `verification:{command,exit_code,result}`; changed paths must agree with the
   actual worktree. If required details are missing or disagree with the
   worktree, dispatch exactly one fresh continuation for this same round with
   `PRIOR_R1` and `DETAILS_REQUEST:<missing or inconsistent items>`. A second
   incomplete response is a failure. If coder reports a structural escalation,
   log this round as `step:"verify-repair",status:"warn"` with the Step 5 fields
   (`round`, `findings`, `repaired`, `unresolved`; `repaired:[]` and all
   supplied IDs unresolved), then return R1 `partial` with
   `data.escalation:"refine"` for the existing PO Step 4f route. On coder R1
   failure or a second incomplete response, log the same fields with
   `status:"error"` and return R1 `failure`; use `repaired:[]` and list every
   supplied ID as unresolved. Environment/setup blockers do not enter coder
   repair.
3. After coder success, compute `REPAIR_DELTA` against the pre-repair snapshot
   and dispatch the read-only `diff-reviewer` to independently review only that
   delta against `PLAN_CONTEXT`. Supply `REPAIR_DELTA`, the pre-repair snapshot
   and changed-file set, the current `WORKTREE_PATH`, `REPO_ROOT`, and prior
   relevant findings. Retain any new CRITICAL/MAJOR findings as
   `REVIEW_FINDINGS` for the next round. Coder success is not a review or gate
   pass.
4. Re-run gates under the existing scope rule: if production code changed,
   start at BUILD and run applicable gates forward; if changes are test-only,
   test-data, or config-only, start at the first affected gate and run applicable
   downstream gates. Any re-check that includes Gate 5 MUST start at Gate 3 to
   collect fresh coverage data, then run the applicable Gate 4 lane before the
   report. Exception: a coverage-raise round re-measures as § *Re-measure* in
   `$MAKATO_BUILD_ROOT/shared/coverage-raise-guide.md` specifies. Apply the single
   flaky-test re-run rule again. Never count coder targeted tests as a
   substitute for these gates.
5. Log each completed independent re-check:

   ```json
   {"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"verify-repair","status":"ok|warn|error","data":{"round":<N>,"findings":["<IDs>"],"repaired":["<IDs>"],"unresolved":["<IDs>"]}}
   ```

   `findings`, `repaired`, and `unresolved` contain IDs for gate and independent
   review findings. `repair_rounds` advances once when that round's first coder
   dispatch starts; a details-only continuation remains in the same round.

If the scoped gates and independent repair-delta review are clean, resume the
normal pipeline at its first gate not yet run (Step 8b when Gate 5 coverage has
already completed); continue the remaining steps before reporting success. If
any gate failure or CRITICAL/MAJOR review finding remains after the final
allowed round, fail closed: return R1 `failure` with `data.repair_rounds`,
`data.repair_rounds_exhausted:true`, and `data.unresolved_findings`; log the
final `verify-repair` record with `status:"error"`. The PO-agent maps this to
HALT-002 and `needs-human-review`. Never suppress an assertion, accept an
unresolved finding, or convert an environment blocker into a coder repair.

---

### Step 3 — Gate 0: SENSORS

Select the scope from gate-scout:

- When `gate-scout.data.sensors_ci_scope == "changed"`, run
  `/makato-build:build-sensors branch <key>`.
- Otherwise (`"all-files"` or `"not found"`), run
  `/makato-build:build-sensors all <key>`.

This is never narrower than CI: `branch` mirrors a changed-file CI sensor lane
and includes the current branch diff plus uncommitted/untracked work; `all`
mirrors CI's `--all-files` lane or is the conservative fallback when scope is
unknown. The selected scope is passed to build-sensors with the default shared
repair budget of five Phase 1 passes for the whole Gate 0 invocation.

Thread the resolved `<key>` (the work-item key from Step 1) as the `spec_key`
positional argument — `build-sensors` marks it **required** and uses it to
locate `specs/<key>-<slug>/build.jsonl`. Omitting it breaks the Gate-0 audit
write (#229): sensors cannot append to the same `build.jsonl` as the rest of
this session, and in autonomous mode the DoD Gate-0 record (item 5) is lost.
The `<key>` here MUST be identical to the key threaded into every
`build-log.sh "<key>"` call elsewhere in this skill.

Retain the R1 `data.scope`, `data.hooks`, and `data.final_run_log` from the
final pre-commit run; Gates 1 and 2 use those first-pass results when their
hook IDs are present. Expected: exit 0 after sensor-fixer completes within the
shared budget. On residual, continue but log `gate-0-residual` and include the
residuals in the verify report; the sensor loop returns the findings for
orchestration rather than adding them to coder `VERIFY_FINDINGS`.

---

### Step 4 — Gate 1: BUILD

Run the project's build command (compile / type-check).

**Command selection — Gate-0 reuse, direct hook, missing hook, or legacy fallback:**

1. **Gate-0 hook path** — when `gate-scout.data.build_hook_cmd` is non-null,
   extract its hook ID. On the first pass, use that hook's status from Gate 0
   `data.hooks` and parse its section in `data.final_run_log` with the same
   error-count rule below. Do not re-run the hook; log
   `data.gate_command_source: "gate-0"`.

2. **Direct hook re-run** — run the hook command when Gate 0's final run lacks
   that hook ID or after a coder repair. Restrict it to Gate 0's scope:
   `all` uses `--all-files`; `branch` uses `--files` with the merge-base branch
   diff plus current untracked files registered with `git add -N`, as in Step 3.
   Recompute this set after repair so newly changed/untracked files are included.
   Use the hook ID from `build_hook_cmd` and log `data.gate_command_source: "hook"`.

3. **Missing-hook path** — `build_hook_cmd` is null and
   `gate-scout.data.build_hook_missing` is `true`: emit WARN
   `"Gate 1: no type-check pre-commit hook found — skipping BUILD gate (no authoritative command)"`.
   Record gate as `skipped` (not `pass`) and log
   `data.gate_command_source: "none"`. Do not fall back to a raw tool invocation.

4. **Legacy fallback path** — `build_hook_cmd` is null and `build_hook_missing`
   is absent or false (gate-scout predates hook probing): fall back to
   `gate-scout.data.build` with the existing non-authoritative warning. Log
   `data.gate_command_source: "raw"`.

**Pre-flight no-hooks-matched guard:**

Before recording a pass, detect the silent-skip case: `pre-commit run --hook-stage manual`
exits 0 with no output when no hooks match the `manual` stage. If stdout is empty (or
contains only whitespace/color codes) AND exit code is 0, emit WARN: `"Gate 1: pre-commit
ran but matched no hooks — pyright hook may be missing 'manual' stage. Treating as skipped."`
Record gate as `skipped`. This prevents a false-negative from a missing `manual` stage
declaration on the hook.

**Error-count parsing:**

After obtaining Gate 1 output (from Gate 0's final run or a direct command), parse
the pyright error-count summary:

- Pattern: `(\d+) errors?` (case-insensitive)
- Gate passes when: exit code 0 **AND** parsed error count == 0 (or pattern absent — no errors reported)
- Warnings (`(\d+) warnings?`) are logged but do not block the gate
- Exit code non-zero but parsed error count == 0: classify as an environment/setup blocker; do not treat it as a pass or create a coder finding
- Exit code 0 but parsed error count > 0: treat as FAIL (false-positive exit code)

On a code-level failure, record a `gate:"build"` item in `VERIFY_FINDINGS`
and enter Step 2a; do not edit source or locally retry the gate. A failed
command caused by unavailable tooling or environment/setup is a blocker, not a
coder finding. Preserve the gate result in the log, and do not count it as a
pass.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-build","status":"ok"|"error"|"skipped","data":{"gate_command_source":"gate-0|hook|raw|none","parsed_errors":<N>,"parsed_warnings":<N>}}
```

---

### Step 5 — Gate 2: LINT

Run the project's lint command (static analysis / style enforcement).

**Command selection — Gate 0 reuse, direct hook, missing hook, or legacy fallback:**

1. **Gate-0 hook path** — when `gate-scout.data.lint_hook_cmd` is non-null,
   extract its hook ID. On the first pass, use that hook's status from Gate 0
   `data.hooks` and parse its section in `data.final_run_log` with the same
   error-count rule below. Do not re-run the hook; log
   `data.gate_command_source: "gate-0"`. This Gate-0 result is the CI-parity
   path, so do not run the `lint_ci_divergence` double-check.

2. **Direct hook re-run** — run the hook command when Gate 0's final run lacks
   that hook ID or after a coder repair. Restrict it to Gate 0's scope:
   `all` uses `--all-files`; `branch` uses `--files` with the merge-base branch
   diff plus current untracked files registered with `git add -N`, as in Step 3.
   Recompute this set after repair so newly changed/untracked files are included.
   Use the hook ID from `lint_hook_cmd` and log `data.gate_command_source: "hook"`.

3. **Missing-hook path** — `lint_hook_cmd` is null and
   `gate-scout.data.lint_hook_missing` is `true`: emit WARN
   `"Gate 2: no lint pre-commit hook found — skipping LINT gate (no authoritative command)"`.
   Record gate as `skipped` (not `pass`) and log
   `data.gate_command_source: "none"`. Do not fall back to a raw tool invocation.

4. **Legacy fallback path** — `lint_hook_cmd` is null and `lint_hook_missing`
   is absent or false (gate-scout predates hook probing): fall back to
   `gate-scout.data.lint` with the existing non-authoritative warning. Log
   `data.gate_command_source: "raw"`. If `lint_ci_divergence: true`, retain
   the existing behavior: run both local and CI lint commands and require both
   to pass. If the CI command is unavailable, emit the existing warning.

**Pre-flight no-hooks-matched guard:**

Before recording a pass, detect the silent-skip case: if stdout is empty (or contains only
whitespace/color codes) AND exit code is 0, emit WARN: `"Gate 2: pre-commit ran but matched
no hooks — ruff hook may be missing 'manual' stage. Treating as skipped."` Record gate as
`skipped`. This prevents a false-negative from a missing `manual` stage declaration.

**Error-count parsing:**

After obtaining Gate 2 output (from Gate 0's final run or a direct command), parse
the ruff error-count summary:
- Pattern: `Found (\d+) errors?`
- Gate passes when: exit code 0 **AND** parsed error count == 0

Run only deterministic formatter/autofix commands explicitly supplied by
gate-scout. Any remaining code-level LINT failure becomes a `gate:"lint"`
finding for Step 2a; do not edit source or locally retry LINT. Retain the
command output and gate result for the coder and audit log.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-lint","status":"ok"|"error"|"skipped","data":{"gate_command_source":"gate-0|hook|raw|none","parsed_errors":<N>,"parsed_warnings":<N>,"ci_divergence":<true|false>,"ci_lint_run":<true|false>}}
```

---

### Step 6 — Gate 3: UNIT TESTS

Run the unit suite only — no integration tests. When both
`gate-scout.data.unit_coverage` and `gate-scout.data.coverage_report` are found,
run `unit_coverage` instead of `unit`: it collects into a fresh coverage data
set without reporting. Otherwise run `unit`. This is one unit-lane run; do not
run the all-in-one `coverage` fallback here.

Gate passes when there are zero new failures relative to `BASELINE_FAILURES`
from the reusable baseline row; pre-existing failures in that exact baseline
do not count. Record total, passed, failed, and skipped.

Use gate-scout's lane selector (directory, marker, or naming convention) to
exclude integration tests. For a failed test with no source change since its
prior run, apply the existing single-test flaky check; if coverage collection
was used, run that one-test check without coverage collection so it cannot
replace the fresh full-unit coverage data.

**Re-run scope rule**: after coder repair, re-run from BUILD (Gate 1) if
production code changed. For test-only or config-only repair, start at the
first affected gate and run applicable downstream gates; BUILD and LINT need
not re-run for test-file-only changes. If Gate 5 must be checked again, start
at Gate 3 to collect a fresh coverage data set, except after a coverage-raise
round (Gate 5 below).

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-unit","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>}}
```

---

### Step 7 — Gate 4: INTEGRATION TESTS

**Mandatory-gate determination.** Before selecting the owner, read
`plan_analysis` from `workflow-state.json` (path:
`specs/<key>-*/workflow-state-<N>.json`). The field is optional — absent on
state files created before #581:

```
MANDATORY = false  (default — backward-compatible non-blocking path)

if plan_analysis is present and not null:
    if plan_analysis.tracer_required == true:
        MANDATORY = true
    if plan_analysis.distinct_layer_count >= 3:
        MANDATORY = true
```

When `plan_analysis` is absent or null, `MANDATORY` stays `false`; non-mandatory
local integration failures remain advisory, so single-layer changes are never
blocked by this optional gate.

If `gate-scout.data.integration_ci != "not found"`, CI owns Gate 4. Do not run
integration tests locally. Log `status:"skipped"` with `owner:"ci"`, the
`integration_ci` value as `ci_ref`, and the computed `mandatory` value. The
required CI check is the gate; `build-fix-ci` owns its failure repair.

Otherwise run the integration lane locally, using `integration_coverage` when
gate-scout found it and `integration` otherwise. The append command MUST append
to Gate 3's fresh coverage data without reporting. Integration tests run against
real dependencies; complete required setup first, and report setup failures
without running tests against an incomplete environment or dispatching coder.

For local runs, compare failures against `BASELINE_FAILURES` and apply the
single-test flaky check from Step 2a. A remaining failure blocks only when
`MANDATORY == true`; otherwise log it as advisory and continue to Gate 5.
After repair, rerun applicable downstream gates; if Gate 5 is needed, restart
at Gate 3 so unit and local integration coverage are fresh.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-integration","status":"ok"|"error"|"skipped","data":{"owner":"local|ci","ci_ref":"<repo-relative CI file>:<line>|null","total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>,"mandatory":<bool>,"tracer_required":<bool|null>,"distinct_layer_count":<int|null>,"junit_report":"<repo-relative path>|null"}}
```

---

### Step 8 — Gate 5: COVERAGE

Gate 5 never re-runs tests when the split commands exist: Gate 3 (and a local
Gate 4) already collected the data, so run only the report-only
`coverage_report`. `coverage_threshold` is metadata only and must never be part
of a shell command. Select the action from this matrix ("split" = both
`unit_coverage` and `coverage_report` found):

| Split | Gate 4 owner | `coverage_ci` | Action | Threshold result |
|---|---|---|---|---|
| yes | local or none | any | `coverage_report` over unit + integration data | blocking (`enforced:true`) |
| yes | ci | found | `coverage_report` over unit data | advisory; the required CI threshold check blocks |
| yes | ci | not found | `coverage_report` over unit data | advisory; a miss logs `warn` — the local data lacks the CI-owned integration lane |
| no | local or none | any | legacy all-in-one `coverage` command | blocking (`enforced:true`) |
| no | ci | any | skip — never run the all-in-one command, it would run integration tests locally | not measured |

Compare the report's total (branch-inclusive when the project measures branches)
with the threshold. A non-zero exit caused by the tool's own fail-under check is
a below-threshold result, not a command failure.

An advisory result reports the local figure and the measured `lanes`, and adds
nothing to `VERIFY_FINDINGS`. Unit-only data never selects files for new tests.
A red CI threshold check is raised by `build-fix-ci` from CI's combined data.

A blocking below-threshold result starts a coverage-raise round. Load
`$MAKATO_BUILD_ROOT/shared/coverage-raise-guide.md` and select up to 5
lowest-coverage files from this report. Add one `gate:"coverage"` finding with
the selected files in `failing` and the guide's record in `coverage`, then enter
Step 2a. Each later round re-measures as the guide specifies and selects again
from the new report. Rounds share `MAX_REPAIR_ROUNDS` with the other gate
findings; a threshold still unmet after the final round fails closed
(HALT-002). List the target files and any lines the coder reported unreachable
in `unresolved_findings`.

If no threshold was declared, report coverage as advisory and add no finding.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-coverage","status":"ok"|"warn"|"error"|"skipped","data":{"owner":"local|ci","ci_ref":"<repo-relative CI file>:<line>|null","lanes":["unit","integration"],"enforced":true|false,"conditional_coverage":"<X>%|not measured","threshold":"<Y>%|none","threshold_met":true|false|null,"raise_round":<N>|null,"targets":["<file>"],"junit_report":"<repo-relative path>|null"}}
```

---

### Step 8b — Gate 6: RUNTIME HEALTH-CHECK

Run the project's health or smoke command when one is available. The command source follows a strict precedence order:

**Command selection (precedence order):**

1. **Plan command** (`PLAN_RUNTIME_CMD` from Step 1, non-empty): use `PLAN_RUNTIME_CMD`. Set `runtime_cmd_source: "plan"`. This takes precedence over gate-scout discovery — the plan author's explicit declaration overrides any auto-discovered command.

2. **Gate-scout discovery** (`PLAN_RUNTIME_CMD` is empty AND `gate-scout.data.health_check_cmd` is non-null): use `gate-scout.data.health_check_cmd`. Set `runtime_cmd_source: "gate-scout"`. This is the fallback when no plan command was declared (existing behavior preserved).

3. **Neither source** (`PLAN_RUNTIME_CMD` is empty AND `health_check_cmd` is null): emit
   `"Gate 6: no health command found in plan or gate-scout — gate is advisory (skipped)"` and record gate as `skipped`. Set `runtime_cmd_source: "none"`. No further action is needed.

**Gate execution** (when a command is available from source 1 or 2):

The timeout is controlled by the `HEALTH_CHECK_TIMEOUT_SECONDS` environment variable (default: 60 seconds). Use a wrapper such as `timeout $HEALTH_CHECK_TIMEOUT_SECONDS <cmd>` to enforce the limit.

**Gate result mapping:**

- Exit code 0 within timeout → gate status `ok`.
- Non-zero exit code OR timeout exceeded → gate status `warn`. Log the failure details and
  **continue** — this gate is ADVISORY. Do NOT block subsequent steps or fail the build.

**This gate is always advisory.** A failing health check surfaces a runtime signal for the
operator but never halts the pipeline. If the command is slow, noisy, or unavailable in the
current environment, the `warn` status is the expected degraded outcome.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-health","status":"ok"|"warn"|"skipped","data":{"health_check_cmd":"<cmd>|null","exit_code":<N>,"duration_seconds":<N>,"runtime_cmd_source":"plan"|"gate-scout"|"none"}}
```

---

### Step 9 — Skill-provenance advisory gate

**This step is fully automated — no judgment or user interaction required.** Execute sub-steps 9a–9c mechanically. The only conditional branches are whether the passport file is valid (9b) and whether expected skills are covered (9c). Do not prompt the user at any point in this step.

After all quality gates pass (Gates 0–5), compute the skill-provenance diff for the run.
This gate is **advisory only** — it never fails the build (NFR-R2).

#### 9a — Compute `skills_expected`

Resolve the final git diff using `skill-bundles.yml` / `inject-skills`:

```bash
# collect changed files on the branch
git diff --name-only origin/main...HEAD > /tmp/changed_files.txt
# resolve expected skills via inject-skills
python3 "$MAKATO_BUILD_ROOT/shared/inject_skills.py" --files /tmp/changed_files.txt
```

The result is `skills_expected`: the ordered, deduplicated list of skills the changed
files should have triggered.

#### 9b — Read the skill passport and compute `skills_invoked_transitively`

Read `specs/<key>-*/skill-passport.json` for the current run. Call `compute_rollup` from
`"$MAKATO_BUILD_ROOT/shared/skill_passport.py"` to compute `skills_invoked_transitively`
— the flat union of all skill nodes in the passport tree.

**When no passport exists** (the session predates F3, or the agent opted out of F4
telemetry): emit a "skill usage tracking skipped" note to `build.jsonl` and proceed:

```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"skill-provenance","status":"warn","data":{"reason":"no passport found","action":"skipped"}}
```

**When a concurrent-write race is detected** (the passport file exists but its
`schema_version` field is absent, the JSON is malformed, or it was last-modified within
the same second as another write): skip the diff and emit a warning to `build.jsonl`
rather than risk reading a partially-written file — no passport corruption (v1
single-session fallback):

```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"skill-provenance","status":"warn","data":{"reason":"concurrent-write race detected","action":"skipped"}}
```

#### 9c — Diff expected vs invoked; emit advisory warnings

For each skill in `skills_expected` that is **not** present in
`skills_invoked_transitively`, emit one advisory warning line to `build.jsonl`:

```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"skill-provenance","status":"warn","data":{"advisory":"skill not invoked","skill":"<skill-id>","expected_from":"<bundle-or-glob>"}}
```

When all expected skills are covered (or no skills are expected): emit a single `"ok"`
entry:

```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"skill-provenance","status":"ok","data":{"skills_expected":<N>,"skills_invoked_transitively":<M>}}
```

**This gate never fails the build.** Advisory warnings are surfaced in the gate summary
table (Step 10) but do not block the pipeline.

---

### Step 10 — Present gate results and hand off

Every Automated-tier DoD item (1–13) above must be satisfied before this step prints
PASS. Items 1–5 are this skill's direct responsibility (Gates 0–5); item 13
(skill-provenance) is advisory and is reported but never blocks; items 6–9 and 12 will
be enforced by `build-push-to-git` and `build-create-pr` further down the pipeline;
items 10 and 11 are session-wide contracts already in effect. If any item is unmet and
not fixable in-session, escalate to the appropriate HALT code per the table at the top
of this workflow.

Present the gate summary table:

```
Gate 1  BUILD             ✓ PASS   0 errors, N warnings
Gate 2  LINT              ✓ PASS   0 errors
Gate 3  UNIT              ✓ PASS   N passed, 0 failed
Gate 4  INTEGRATION       <PASS (local) | CI-OWNED (required check)>  N passed, 0 failed
Gate 5  COVERAGE          <PASS (local threshold) | ADVISORY (CI threshold)>  N% conditional
Advisory  SKILL-PROVENANCE  ⚠ WARN   N skills expected, M invoked (advisory only, never blocks)
```

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"<X>%"}}'
```

**Required learning review:** before handing off (including a failed or paused run),
review discoveries and persist every evidence-backed reusable procedure or technical
fact. Record each discovery once; do not invent lessons to fill a quota. If none
qualify, log `learning-review` with `status: ok` and a concrete `no_new_lessons` reason.
The writer immediately promotes `generalizable` records into the main checkout’s
`.makato/memory/`; it does not wait for a merge or CI. Run from the consumer repo,
not the plugin checkout. Pass `--issue <N>` for shared feature spec folders.
A nonzero write is a persistence failure: retain the raw source and report it,
not a successful or empty learning review.

```bash
"$MAKATO_BUILD_ROOT/shared/write-lessons.sh" "<key>" "<tier>" "<scope>" "<text>" "[tags]"
#   tier  = procedural | semantic
#   scope = generalizable | local   (generalizable → eligible for promotion)
#   tags  = optional comma-separated list
```

This retains the source in `specs/<key>/change-lessons.jsonl` and persists reusable
records in `.makato/memory/{procedural,semantic}.jsonl`. `local` records stay only
in the spec. Optional `--bundle` and `--label` preserve filtered recall metadata.
Verify the captured record using `workflow-state.sh recall-lessons <owner/repo>`.

Tell the user: *"All locally owned gates passed; CI-owned required checks remain with CI.*
*Pipeline remaining: `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-push-to-git` to commit and push."*
