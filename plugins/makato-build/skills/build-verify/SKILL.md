---
name: build-verify
description: >-
  Run the full quality gate pipeline — build, lint, unit tests,
  integration tests, conditional coverage check. Each gate runs
  separately so failures are attributable. Fixable failures are
  fixed and gates re-run; structural failures escalate to refine.
  Autonomous. Use after review, before push-to-git.
version: "1.7.0"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/review` and before `/push-to-git`. The code has been reviewed and simplified.
This step answers: *"Does it actually work?"* — build succeeds, lint passes, all tests
pass, coverage is met.

## Input

When dispatched by the PO-agent (`--autonomous` mode), this skill receives:

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). The skill MUST `cd "$WORKTREE_PATH"` before any build/lint/test/coverage gate command — gates that run from the wrong checkout produce nonsense pass/fail signals.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Gate 0. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` — every gate command below runs from this CWD.

## Workflow

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
| 8 | No `TODO`/`FIXME` without tracking issue | sensor `todo-check` | HALT-001 family |
| 9 | No hard-coded credentials | sensors `gitleaks` / `detect-secrets` | HALT-001 family |
| 10 | `build.jsonl` entry per skill step | every skill via `shared/build-log.sh` | contract — caller treats omission as agent failure |
| 11 | R1 JSON block as last fenced ` ```json ` in agent return | `plugins/makato-build/agents/RETURN-CONTRACT.md` | caller treats missing/invalid R1 as `status: "failure"` |
| 12 | PR description contains `Closes #N` | `build-create-pr` description draft | interactive review catches omission before PR is opened |
| 13 | Skill-provenance recorded and complete | Step 9 (skill-provenance advisory gate) in this skill | advisory only — never fails the build (NFR-R2) |

A failure to satisfy any item in this table **MUST** trigger the corresponding HALT code
at the gate that enforces it; the autonomous loop does not proceed past an unmet item.
When this skill runs, gates 0–5 cover items 1–5; items 6–9 and 12 are enforced by
sibling skills called later in the pipeline; items 10 and 11 are enforced at every
skill / agent boundary in the session, including by this skill on itself.

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we verifying? (e.g. #123, or pass it directly: `/makato-build:build-verify #123`)"* — or use the passed argument.

Read `design.md` from the resolved spec folder (`specs/<key>-*/`) if it exists and look for a declared coverage threshold.
If none is declared, the coverage gate is advisory — it reports figures but does not block.

Dispatch the `gate-scout` agent with:
- `REPO_ROOT`: absolute path to the target repository root
- `COVERAGE_HINT`: the coverage threshold extracted from `design.md` (or empty string if none declared)

The agent scans config files (`package.json`, `pom.xml`, `Makefile`, `build.gradle`, `pyproject.toml`, etc.) and returns a structured command map with the exact build, lint, unit, integration, and coverage commands, and a `java_version_required` field for JVM projects. Use this command map for all subsequent gates — do not infer commands independently.

**Python runner prefix**: if `python_runner_prefix` is present and not `"none"` (e.g. `uv run`, `poetry run`), the gate-scout commands already include it. Run them verbatim — do NOT strip the prefix and do NOT re-add it. A bare `pytest`/`ruff` invocation in a lockfile-managed project resolves against the system Python and fails with `ModuleNotFoundError`.

**Extra linters**: if `lint_js` or `lint_sql` are present and not `"not found"`, run them as additional LINT-gate commands alongside the primary `lint` command. Each must pass independently; a failure in any is a LINT-gate failure. Log each under its own `data.linter` key.

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

### Step 3 — Gate 0: SENSORS

Run: `/makato-build:build-sensors all <key>`

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

### Step 5 — Gate 2: LINT

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

### Step 8 — Gate 5: COVERAGE

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

### Step 9 — Skill-provenance advisory gate

After all quality gates pass (Gates 0–5), compute the skill-provenance diff for the run.
This gate is **advisory only** — it never fails the build (NFR-R2).

#### 9a — Compute `skills_expected`

Resolve the final git diff using `skill-bundles.yml` / `inject-skills`:

```bash
# collect changed files on the branch
git diff --name-only origin/main...HEAD > /tmp/changed_files.txt
# resolve expected skills via inject-skills
python3 plugins/makato-build/shared/inject_skills.py --files /tmp/changed_files.txt
```

The result is `skills_expected`: the ordered, deduplicated list of skills the changed
files should have triggered.

#### 9b — Read the skill passport and compute `skills_invoked_transitively`

Read `specs/<key>-*/skill-passport.json` for the current run. Call `compute_rollup` from
`plugins/makato-build/shared/skill_passport.py` to compute `skills_invoked_transitively`
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
Advisory  SKILL-PROVENANCE  ⚠ WARN   N skills expected, M invoked (advisory only, never blocks)
```

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-verify","story":"<key>","step":"session","status":"ok","data":{"all_gates_passed":true,"conditional_coverage":"<X>%"}}'
```

Tell the user: *"All gates passed.*
*Pipeline remaining: `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-push-to-git` to commit and push."*
