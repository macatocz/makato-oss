---
name: build-verify
description: >-
  Run the full quality gate pipeline — build, lint, unit tests,
  integration tests, conditional coverage check. Each gate runs
  separately so failures are attributable. Fixable failures are
  fixed and gates re-run; structural failures escalate to refine.
  Autonomous (--autonomous, dispatched by PO-agent) or interactive.
  Use after review, before push-to-git. Triggers: verify, quality-gate,
  all-gates, build-pass, tests-pass, lint-clean, coverage-check,
  gate-pipeline, run-verify.
version: "1.13.0"
argument-hint: "[work-item-key]"
allowed-tools: [Bash, Read]
---

## When to Use

Use after `/review` and before `/push-to-git`. The code has been reviewed and simplified.
This step answers: *"Does it actually work?"* — build succeeds, lint passes, all tests
pass, coverage is met.

## Anti-patterns

These failure modes are only learnable from production incidents — they are non-obvious
and each has caused gate false-negatives or false-positives in real sessions.

**NEVER strip the Python runner prefix from gate-scout commands, and NEVER re-add it
manually.**
WHY: `uv run`/`poetry run` resolves dependencies from the project-local lockfile venv. A
bare `pytest` or `ruff` invocation uses the system Python, which lacks the locked
dependencies → `ModuleNotFoundError` or a different package version produces a spurious
pass or fail signal that does not reproduce in CI.

**NEVER substitute `pre-commit run --files <subset>` for `--all-files` in Gate 0.**
WHY: staged-subset scans miss repo-wide formatter nits and pre-existing debt that
`--all-files` (the exact CI command) surfaces. The silent consequence is a CI-only
failure — the build passes locally and goes red only after the PR is opened.

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

## Input

When dispatched by the PO-agent (`--autonomous` mode), this skill receives:

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). The skill MUST `cd "$WORKTREE_PATH"` before any build/lint/test/coverage gate command — gates that run from the wrong checkout produce nonsense pass/fail signals.
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root. Resolve from
  `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` when the caller does
  not supply it; use it for suite-owned helpers and contract references.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Gate 0. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` — every gate command below runs from this CWD.

## Workflow

### References

#### `references/gate-definitions.md` — toolchain command tables

**MANDATORY: load before Gate 1 (Step 4) or Gate 2 (Step 5) when** gate-scout returns a
toolchain not covered by the three-path hook/missing-hook/legacy command selection — for
example: Maven, Gradle, Go, Rust, Biome, or sqlfluff projects where the exact hook IDs,
unit/integration split flags, or runner conventions are not obvious from gate-scout output.

**Also load when** the unit/integration split convention for the detected toolchain is
ambiguous and gate-scout does not populate a separate `unit_cmd` / `integration_cmd`.

**Do NOT load** when gate-scout's `build_hook_cmd` or `lint_hook_cmd` is non-null and the
three-path command selection in Steps 4–5 already resolved the command unambiguously — the
hook is the authoritative CI-parity path and the reference adds no new information. Do NOT
load for Python or JS/TS projects where the runner prefix and hook path are already
populated in gate-scout output.

---

### Definition-of-Done — Automated Tier Mapping

The gates below collectively enforce the **Automated tier (13 items)** of
`plugins/makato-build/skills/definition-of-done/SKILL.md`. Each row maps a DoD item to
the gate that enforces it and the HALT code that fires when the item is unmet in
autonomous mode and the failure is structural.

| # | DoD item | Enforced by | HALT on unmet (autonomous mode) |
|---|----------|-------------|---------------------------------|
| 1 | All tests pass | Gate 3 (Unit) + Gate 4 (Integration) | structural → `/build-refine`; coverage-related → HALT-002 |
| 2 | Coverage ≥ threshold | Gate 5 (Coverage) | HALT-002 |
| 3 | Lint clean | Gate 2 (Lint) | fix-then-retry; structural lint debt → operator escalation |
| 4 | Type-check clean | Gate 1 (Build) | fix-then-retry; structural → `/build-refine` |
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

The agent scans config files (`package.json`, `pom.xml`, `Makefile`, `build.gradle`, `pyproject.toml`, etc.) and returns a structured command map with the exact build, lint, unit, integration, and coverage commands, and a `java_version_required` field for JVM projects. Use this command map for all subsequent gates — do not infer commands independently.

**Artifact handoff guard:** Read `local://` or `artifact://` only when that
exact URI was emitted by a preceding tool or agent in this run. Never invent a
placeholder such as `local://no-such`. If no URI was emitted, use the canonical
repository path already resolved in Step 1; if that path is missing, report the
missing artifact and stop the affected gate rather than probing guessed URIs.

**Coverage command contract:** use `coverage` from the command map as an
executable string only, and use `coverage_threshold` as separate metadata. Never
execute a command containing a human-readable suffix such as
`— threshold: 95%`. If a legacy gate-scout response contains that suffix, remove
the suffix before execution and log the threshold separately.

**MANDATORY: load `references/gate-definitions.md`** if gate-scout returns a toolchain
(Maven, Gradle, Go, Rust, Biome, sqlfluff) for which the three-path command selection in
Steps 4–5 does not cover the exact hook IDs, split flags, or runner conventions. For
Python/JS/TS with populated hook commands, skip the reference.

**Python runner prefix**: if `python_runner_prefix` is present and not `"none"` (e.g. `uv run`, `poetry run`), the gate-scout commands already include it. Run them verbatim — do NOT strip the prefix and do NOT re-add it. A bare `pytest`/`ruff` invocation in a lockfile-managed project resolves against the system Python and fails with `ModuleNotFoundError`.

**Extra linters**: if `lint_js` or `lint_sql` are present and not `"not found"`, run them as additional LINT-gate commands alongside the primary `lint` command. Each must pass independently; a failure in any is a LINT-gate failure. Log each under its own `data.linter` key.

**JVM version check** (Maven/Gradle projects only): if `java_version_required` is present in the gate-scout output, run `java -version` and compare the major version. If they differ, emit a WARNING:

> "[WARNING] JVM mismatch: project requires Java `<required>`, system default is Java `<actual>`. All build and test commands in this session will be prefixed with `JAVA_HOME=<java_home_path>` to ensure the correct version is used."

Resolve the correct `JAVA_HOME` path for the required version (e.g. via `$(dirname $(dirname $(readlink -f $(which java))))` or by checking common SDK manager paths). Prefix all gate commands with `JAVA_HOME=<resolved_path>` for the rest of this session.

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"start","data":{"coverage_threshold":"<X>%|none"}}'
```

---

### Step 3 — Gate 0: SENSORS

Run: `/makato-build:build-sensors all <key>`

**CI parity — always `all`, never a staged/changed subset.** The `all` scope maps
`build-sensors` onto `pre-commit run --hook-stage manual --all-files` — the *exact*
command CI runs. A local pre-commit hook typically lints only staged/changed files, so a
repo-wide lint finding (a formatter nit in a file the diff touched, or pre-existing debt in
an untouched file that a repo-wide `--all-files` pass surfaces) passes locally and only goes
red in CI. Gate 0 exists to close that gap: run it with `all` so `/build-verify` reproduces
the CI lint surface **before** the PR is opened. Do NOT substitute a hand-run
`pre-commit run --files …` here — that is the subset that lets CI-only failures through.

Thread the resolved `<key>` (the work-item key from Step 1) as the `spec_key` positional
argument — `build-sensors` marks it **required** and uses it to locate
`specs/<key>-<slug>/build.jsonl`. Omitting it breaks the Gate-0 audit write (#229): the
sensors run cannot append to the same `build.jsonl` as the rest of this session, and in
autonomous mode the DoD Gate-0 record (item 5) is lost. The `<key>` here MUST be the
identical key threaded into every `build-log.sh "<key>"` call elsewhere in this skill.

Expected: exit 0 after sensor-fixer loop completes (loops <= MAX_LOOPS=5).

On residual: continue but log to specs/<key>/build.jsonl as `gate-0-residual` and add residual findings to the verify report. Do NOT block subsequent gates — sensor harness is autonomous, not blocking.

---

### Step 4 — Gate 1: BUILD

Run the project's build command (compile / type-check).

**Command selection — three paths:**

1. **Hook path** — `gate-scout.data.build_hook_cmd` is non-null: use it as the Gate 1
   command. Log `data.gate_command_source: "hook"`. This is the authoritative CI-parity path.

2. **Missing-hook path** — `build_hook_cmd` is null and `gate-scout.data.build_hook_missing`
   is `true`: emit WARN `"Gate 1: no type-check pre-commit hook found — skipping BUILD gate
   (no authoritative command)"`. Record gate as `skipped` (not `pass`). Log
   `data.gate_command_source: "none"`. Do not fall back to a raw tool invocation.

3. **Legacy fallback path** — `build_hook_cmd` is null and `build_hook_missing` is absent or
   false (gate-scout pre-dates hook probing): fall back to `gate-scout.data.build` with WARN
   `"Gate 1: gate-scout pre-dates hook probing — falling back to raw tool (non-authoritative)"`.
   Log `data.gate_command_source: "raw"`.

**Pre-flight no-hooks-matched guard:**

Before recording a pass, detect the silent-skip case: `pre-commit run --hook-stage manual`
exits 0 with no output when no hooks match the `manual` stage. If stdout is empty (or
contains only whitespace/color codes) AND exit code is 0, emit WARN: `"Gate 1: pre-commit
ran but matched no hooks — pyright hook may be missing 'manual' stage. Treating as skipped."`
Record gate as `skipped`. This prevents a false-negative from a missing `manual` stage
declaration on the hook.

**Error-count parsing:**

After running the Gate 1 command, parse stdout for the pyright error-count summary:

- Pattern: `(\d+) errors?` (case-insensitive)
- Gate passes when: exit code 0 **AND** parsed error count == 0 (or pattern absent — no errors reported)
- Warnings (`(\d+) warnings?`) are logged but do not block the gate
- Exit code non-zero but parsed error count == 0: treat as pass with WARN (pre-commit infrastructure error, not a type error)
- Exit code 0 but parsed error count > 0: treat as FAIL (false-positive exit code)

On failure: classify.
- **Fixable** — typo, missing import, wrong type annotation → fix, re-run BUILD
- **Structural** — the chosen design doesn't fit the type system, fundamental interface
  mismatch → stop, report, recommend `/refine`

On any gate failure and retry, log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-retry","status":"warn","data":{"gate":"build","attempt":<N>,"error":"<first error line>"}}
```

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-build","status":"ok"|"error"|"skipped","data":{"gate_command_source":"hook|raw|none","parsed_errors":<N>,"parsed_warnings":<N>}}
```

---

### Step 5 — Gate 2: LINT

Run the project's lint command (static analysis / style enforcement).

**Command selection — three paths:**

1. **Hook path** — `gate-scout.data.lint_hook_cmd` is non-null: use it as the Gate 2
   command. Log `data.gate_command_source: "hook"`. This is the authoritative CI-parity path.
   When `lint_hook_cmd` is non-null, the hook path IS the CI path — bypass the
   `lint_ci_divergence` double-run check with informational note: "CI-parity via pre-commit
   hook — lint_ci_divergence check bypassed." Only run `lint_ci_command` when `lint_hook_cmd`
   is null (legacy fallback path).

2. **Missing-hook path** — `lint_hook_cmd` is null and `gate-scout.data.lint_hook_missing`
   is `true`: emit WARN `"Gate 2: no lint pre-commit hook found — skipping LINT gate
   (no authoritative command)"`. Record gate as `skipped` (not `pass`). Log
   `data.gate_command_source: "none"`. Do not fall back to a raw tool invocation.

3. **Legacy fallback path** — `lint_hook_cmd` is null and `lint_hook_missing` is absent or
   false (gate-scout pre-dates hook probing): fall back to `gate-scout.data.lint` with WARN
   `"Gate 2: gate-scout pre-dates hook probing — falling back to raw tool (non-authoritative)"`.
   Log `data.gate_command_source: "raw"`.

   In the legacy fallback path, if `lint_ci_divergence: true`, run **both** the local lint
   command (`lint`) and the CI lint command (`lint_ci_command`) and require both to pass. Emit
   an informational note: "Running local lint and CI lint — commands differ." If
   `lint_ci_command` is "not found" (CI config not readable), emit a WARNING: "[WARNING] Could
   not verify CI lint config — ensure local lint rules match your CI pipeline."

**Pre-flight no-hooks-matched guard:**

Before recording a pass, detect the silent-skip case: if stdout is empty (or contains only
whitespace/color codes) AND exit code is 0, emit WARN: `"Gate 2: pre-commit ran but matched
no hooks — ruff hook may be missing 'manual' stage. Treating as skipped."` Record gate as
`skipped`. This prevents a false-negative from a missing `manual` stage declaration.

**Error-count parsing:**

After running the Gate 2 command, parse stdout for the ruff error-count summary:

- Pattern: `Found (\d+) errors?`
- Gate passes when: exit code 0 **AND** parsed error count == 0

Fix all lint errors before proceeding to tests — a lint failure that survives into a
test run contaminates the test log and makes failures harder to attribute.

On failure: fix lint errors, re-run LINT. Lint failures are almost always fixable.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-lint","status":"ok"|"error"|"skipped","data":{"gate_command_source":"hook|raw|none","parsed_errors":<N>,"parsed_warnings":<N>,"ci_divergence":<true|false>,"ci_lint_run":<true|false>}}
```

---

### Step 6 — Gate 3: UNIT TESTS

Run the unit test suite only — no integration tests.

Gate passes when: zero new failures vs. pre-session baseline (pre-existing failures do
not count against this session). Record total, passed, failed, skipped.

Running unit tests in isolation means a failure here is attributable to a unit boundary.
If the project's test runner does not distinguish unit from integration natively, use
the naming convention or directory structure returned by the gate-scout agent to filter.

On failure: classify.
- **Flakey candidate** — test failed but no source code changed since last run → re-run the single failing test once. If it passes: log `status: warn, data: {gate: "unit", flaky_test: "<name>"}` and continue. If it fails again: classify below.
- **Fixable** — wrong assertion value, missing mock, test setup error → fix, re-run UNIT
- **Structural** — multiple tests fail because the interface contract was wrong → escalate

**Re-run scope rule**: re-run from BUILD (Gate 1) if the fix touched production code. Re-run from the failed gate only (UNIT) if the fix was test-only or config — BUILD and LINT do not need to re-run for test-file changes.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-unit","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>}}
```

---

### Step 7 — Gate 4: INTEGRATION TESTS

**Mandatory-gate determination.** Before running the suite, read `plan_analysis` from
`workflow-state.json` (path: `specs/<key>-*/workflow-state-<N>.json`). The field is optional
— absent on state files created before #581. Determine whether Gate 4 is mandatory:

```
MANDATORY = false  (default — backward-compatible non-blocking path)

if plan_analysis is present and not null:
    if plan_analysis.tracer_required == true:
        MANDATORY = true
    if plan_analysis.distinct_layer_count >= 3:
        MANDATORY = true
```

When `plan_analysis` is absent or null, `MANDATORY` stays `false` — Gate 4 runs the suite
advisory (existing behavior unchanged, single-layer changes are never blocked).

Run the integration test suite only.

Gate passes when: zero new failures vs. baseline. Record total, passed, failed, skipped.

Integration tests run against real dependencies. If the test environment requires setup
(test database, docker-compose, required env vars), perform it first. If environment
setup fails, report the blocker clearly — do not attempt to run tests against an
incomplete environment.

On failure: classify.
- **Flakey candidate** — test failed but no source code changed since last run → re-run the single failing test once. If it passes: log `status: warn, data: {gate: "integration", flaky_test: "<name>"}` and continue. If it fails again: classify below.
- **Fixable** — wrong expected state, missing test data, environment not properly reset
  → fix, re-run INTEGRATION
- **Structural** — the implementation approach doesn't work against real dependencies
  → stop, report, recommend `/refine`

**Mandatory vs non-mandatory failure handling:**

- When `MANDATORY == true` and Gate 4 fails: treat as a **blocking failure** — same severity
  as Gate 3 (Unit). Do not advance to Gate 5. Classify as Fixable or Structural per the rules
  above and block accordingly.
- When `MANDATORY == false` (default) and Gate 4 fails: **advisory only** — log the failure,
  continue to Gate 5. Do not block the pipeline for single-layer changes.

**Re-run scope rule**: re-run from BUILD (Gate 1) if the fix touched production code. Re-run from INTEGRATION only if the fix was test-only, test-data, or environment config — no need to re-run BUILD/LINT/UNIT for integration-test-only fixes.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-integration","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>,"mandatory":<bool>,"tracer_required":<bool|null>,"distinct_layer_count":<int|null>}}
```

---

### Step 8 — Gate 5: COVERAGE

Run the exact executable string from `gate-scout.data.coverage` against the
combined unit + integration results. `coverage_threshold` is metadata only and
must never be part of the shell command.

Check **conditional coverage** (branch/condition coverage, not line coverage): every
branch of every conditional in the new code must be exercised by at least one test.

If `coverage_threshold` is declared by gate-scout (or a story threshold was
declared in `design.md`), compare the measured conditional coverage against the
applicable threshold:
- Below threshold → identify the specific uncovered branches, add targeted tests, re-run
  from UNIT
- If filling the coverage gap requires rethinking the implementation structure → STRUCTURAL
  → escalate to `/refine`

If no threshold was declared:
- Report the coverage figure as advisory
- Note uncovered branches for the user's awareness
- Do not block the pipeline

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-coverage","status":"ok"|"warn"|"error","data":{"conditional_coverage":"<X>%","threshold":"<Y>%|none","threshold_met":true|false}}
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
Gate 4  INTEGRATION       ✓ PASS   N passed, 0 failed
Gate 5  COVERAGE          ✓ PASS   N% conditional (threshold: N%)
Gate 6  RUNTIME HEALTH    ✓ PASS   exit 0 in Ns  (advisory — warn does not block)
Advisory  SKILL-PROVENANCE  ⚠ WARN   N skills expected, M invoked (advisory only, never blocks)
```

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"<X>%"}}'
```

**(Optional) Lesson write (#473):** if this session produced a noteworthy lesson — a
bugfix/gotcha pattern (`tier:procedural`) or a durable technical fact (`tier:semantic`,
e.g. a dimension or socket override) — append it to the per-issue store so the po-agent's
local-lane promote step (`promote-lessons.sh`, run at the merge-success terminal, po-agent
Step 6 item 7) can lift `generalizable` records into `.makato/memory/`:

```bash
"$MAKATO_BUILD_ROOT/shared/write-lessons.sh" "<key>" "<tier>" "<scope>" "<text>" "[tags]"
#   tier  = procedural | semantic
#   scope = generalizable | local   (generalizable → eligible for promotion)
#   tags  = optional comma-separated list
```

This appends one record to `specs/<key>-*/change-lessons.jsonl`; it never writes to
`.makato/memory/` (promotion is `documentation-agent`'s job). Omit the call entirely when
there is nothing notable to record — it is optional and each call is an independent append.

Tell the user: *"All gates passed.*
*Pipeline remaining: `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-push-to-git` to commit and push."*
