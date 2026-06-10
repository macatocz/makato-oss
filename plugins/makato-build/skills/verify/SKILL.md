---
name: verify
description: >-
  Run the full quality gate pipeline — build, lint, unit tests,
  integration tests, conditional coverage check. Each gate runs
  separately so failures are attributable. Fixable failures are
  fixed and gates re-run; structural failures escalate to refine.
  Autonomous. Use after review, before push-to-git.
version: "1.0.0"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/review` and before `/push-to-git`. The code has been reviewed and simplified.
This step answers: *"Does it actually work?"* — build succeeds, lint passes, all tests
pass, coverage is met.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we verifying? (e.g. DCP-1234)"* — or use the passed argument.

Load `@references/gate-definitions.md`. Follow its instructions to discover the project's
build, lint, and test commands from config files (`package.json`, `pom.xml`, `Makefile`,
`build.gradle`, `pyproject.toml`, etc.).

Read `spec/<key>/design.md` if it exists and look for a declared coverage threshold.
If none is declared, the coverage gate is advisory — it reports figures but does not block.

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"session","status":"start","data":{"coverage_threshold":"<X>%|none"}}
```

---

### Step 3 — Gate 1: BUILD

Run the project's build command (compile / type-check).

Gate passes when: zero errors. Warnings are noted in the log but do not fail the gate.

On failure: classify.
- **Fixable** — typo, missing import, wrong type annotation → fix, re-run BUILD
- **Structural** — the chosen design doesn't fit the type system, fundamental interface
  mismatch → stop, report, recommend `/refine`

Log:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"gate-build","status":"ok"|"error","data":{"warnings":<N>}}
```

---

### Step 4 — Gate 2: LINT

Run the project's lint command (static analysis / style enforcement).

Gate passes when: zero errors. Warnings are noted but do not fail the gate.

Fix all lint errors before proceeding to tests — a lint failure that survives into a
test run contaminates the test log and makes failures harder to attribute.

On failure: fix lint errors, re-run LINT. Lint failures are almost always fixable.

Log:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"gate-lint","status":"ok"|"error","data":{"errors":<N>,"warnings":<N>}}
```

---

### Step 5 — Gate 3: UNIT TESTS

Run the unit test suite only — no integration tests.

Gate passes when: zero new failures vs. pre-session baseline (pre-existing failures do
not count against this session). Record total, passed, failed, skipped.

Running unit tests in isolation means a failure here is attributable to a unit boundary.
If the project's test runner does not distinguish unit from integration natively, use
the naming convention or directory structure described in `gate-definitions.md` to filter.

On failure: classify.
- **Fixable** — wrong assertion value, missing mock, test setup error → fix, re-run UNIT
- **Structural** — multiple tests fail because the interface contract was wrong → escalate

Re-run starts from UNIT after a fix (not from BUILD — BUILD and LINT already passed).

Log:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"gate-unit","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>}}
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
- **Fixable** — wrong expected state, missing test data, environment not properly reset
  → fix, re-run INTEGRATION
- **Structural** — the implementation approach doesn't work against real dependencies
  → stop, report, recommend `/refine`

Log:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"gate-integration","status":"ok"|"error","data":{"total":<N>,"passed":<N>,"failed":<N>,"skipped":<N>}}
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
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"gate-coverage","status":"ok"|"warn"|"error","data":{"conditional_coverage":"<X>%","threshold":"<Y>%|none","threshold_met":true|false}}
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

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"verify","story":"<key>","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"<X>%"}}
```

Tell the user: *"All gates passed. Next: run `/push-to-git`."*
