---
name: build-verify
description: >-
  Run the full quality gate pipeline — build, lint, unit tests,
  integration tests, conditional coverage check. Each gate runs
  separately so failures are attributable. Fixable failures are
  fixed and gates re-run; structural failures escalate to refine.
  Autonomous. Use after review, before push-to-git.
version: "1.3.1"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/review` and before `/push-to-git`. The code has been reviewed and simplified.
This step answers: *"Does it actually work?"* — build succeeds, lint passes, all tests
pass, coverage is met.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we verifying? (e.g. DCP-1234, or pass it directly: `/daff-build:build-verify DCP-1234`)"* — or use the passed argument.

Read `design.md` from the resolved spec folder (`specs/<key>-*/`) if it exists and look for a declared coverage threshold.
If none is declared, the coverage gate is advisory — it reports figures but does not block.

Dispatch the `gate-scout` agent with:
- `REPO_ROOT`: absolute path to the target repository root
- `COVERAGE_HINT`: the coverage threshold extracted from `design.md` (or empty string if none declared)

The agent scans config files (`package.json`, `pom.xml`, `Makefile`, `build.gradle`, `pyproject.toml`, etc.) and returns a structured command map with the exact build, lint, unit, integration, and coverage commands, and a `java_version_required` field for JVM projects. Use this command map for all subsequent gates — do not infer commands independently.

**JVM version check** (Maven/Gradle projects only): if `java_version_required` is present in the gate-scout output, run `java -version` and compare the major version. If they differ, emit a WARNING:

> "[WARNING] JVM mismatch: project requires Java `<required>`, system default is Java `<actual>`. All build and test commands in this session will be prefixed with `JAVA_HOME=<java_home_path>` to ensure the correct version is used."

Resolve the correct `JAVA_HOME` path for the required version (e.g. via `$(dirname $(dirname $(readlink -f $(which java))))` or by checking common SDK manager paths). Prefix all gate commands with `JAVA_HOME=<resolved_path>` for the rest of this session.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"start","data":{"coverage_threshold":"<X>%|none"}}'
```

---

### Step 3 — Gate 1: BUILD

Run the project's build command (compile / type-check).

Gate passes when: zero errors. Warnings are noted in the log but do not fail the gate.

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
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-build","status":"ok"|"error","data":{"warnings":<N>}}
```

---

### Step 4 — Gate 2: LINT

Run the project's lint command (static analysis / style enforcement).

Gate passes when: zero errors. Warnings are noted but do not fail the gate.

Fix all lint errors before proceeding to tests — a lint failure that survives into a
test run contaminates the test log and makes failures harder to attribute.

On failure: fix lint errors, re-run LINT. Lint failures are almost always fixable.

**CI lint divergence check**: if the gate-scout output includes `lint_ci_divergence: true`, run **both** the local lint command (`lint`) and the CI lint command (`lint_ci_command`) and require both to pass. Emit an informational note: "Running local lint and CI lint — commands differ." If `lint_ci_command` is "not found" (CI config not readable), emit a WARNING: "[WARNING] Could not verify CI lint config — ensure local lint rules match your CI pipeline."

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-lint","status":"ok"|"error","data":{"errors":<N>,"warnings":<N>,"ci_divergence":<true|false>,"ci_lint_run":<true|false>}}
```

---

### Step 5 — Gate 3: UNIT TESTS

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

### Step 6 — Gate 4: INTEGRATION TESTS

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

**Re-run scope rule**: re-run from BUILD (Gate 1) if the fix touched production code. Re-run from INTEGRATION only if the fix was test-only, test-data, or environment config — no need to re-run BUILD/LINT/UNIT for integration-test-only fixes.

Log:
```
{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"gate-integration","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>}}
```

---

### Step 7 — Gate 5: COVERAGE

Run the coverage tool against the combined unit + integration results.

Check **conditional coverage** (branch/condition coverage, not line coverage): every
branch of every conditional in the new code must be exercised by at least one test.

If a threshold was declared in `design.md`:
- Compare the measured conditional coverage against the threshold
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

### Step 8 — Present gate results and hand off

Present the gate summary table:

```
Gate 1  BUILD        ✓ PASS   0 errors, N warnings
Gate 2  LINT         ✓ PASS   0 errors
Gate 3  UNIT         ✓ PASS   N passed, 0 failed
Gate 4  INTEGRATION  ✓ PASS   N passed, 0 failed
Gate 5  COVERAGE     ✓ PASS   N% conditional (threshold: N%)
```

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"<X>%"}}'
```

Tell the user: *"All gates passed.*
*Pipeline remaining: `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-push-to-git` to commit and push."*
