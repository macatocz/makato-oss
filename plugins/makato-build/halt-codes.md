<!-- markdownlint-disable MD013 MD032 MD040 -->
# HALT Codes — makato-build skill registry

> **Authoritative reference** for skill-level HALT codes emitted by `build-*` skills in this plugin. Every code that appears as `errors: ["CODE: <reason>"]` or `data.halt_code: "CODE"` in a skill R1 envelope MUST be registered here.

## Scope and relationship to `makato-orchestrate/halt-conditions.md`

There are **two HALT registries** in the makato suite, with intentionally different domains:

| Registry | Codes | Origin | Consumer |
|---|---|---|---|
| `plugins/makato-orchestrate/halt-conditions.md` | `HALT-000` … `HALT-010`, `HALT-STRUCTURAL` | Orchestrator-level: outer-loop counters, budget ceilings, kill-switches, structural escalation | PO-agent |
| `plugins/makato-build/halt-codes.md` (this file) | Per-skill string codes (`MISSING_INPUT`, `BASELINE_BROKEN`, `PUSH_REJECTED`, …) | Skill-level: input validation, gate failures, infra errors caught inside one skill | PO-agent (via R1 `data.halt_code` or `errors[]`); skill-internal flow |

The two registries do not overlap: orchestrate codes are numeric `HALT-NNN`; build codes are uppercase-underscore tokens. A skill MAY surface BOTH (e.g. `build-address-pr-comments` sets `data.halt_code: "HALT-003"` for STRUCTURAL findings AND emits its own `CARRY_OVER_FAILED` token in `errors[]`). When both are present, the numeric HALT drives the PO-agent's recovery route; the string code is forensic context.

## Recovery routes

The PO-agent reads each skill's R1 envelope and selects a recovery route from the `Route` column below. The three routes are:

- **refine** — re-dispatch `/makato-build:build-refine <KEY> --autonomous`. Used when the failure is a planning problem (missing acceptance criteria, wrong file targets, dependency cycle) rather than a runtime problem.
- **operator-escalation** — apply `needs-human-review` to the issue + PR, retain the worktree, return R1 `failure`. Used when the failure cannot be repaired by any autonomous step (test runner crashed, push rejected by the deny-list, GitHub auth lost).
- **structural** — propagate as `HALT-STRUCTURAL` per `plugins/makato-orchestrate/halt-conditions.md`. The PO-agent re-dispatches `build-refine` once; if that also fails, escalates to `HALT-008`. Used when the structural assumption baked into the plan is wrong (acceptance criterion uncovered, file target invalid).

Routes are advisory for the PO-agent — operators can override per-issue. The table below documents the **default** route; deviations belong in the issue's lessons-learned audit, not in this registry.

## Registry

| Code | Origin skills | Route | Description |
|------|---------------|-------|-------------|
| `MISSING_INPUT` | `build-refine`, `build-implement-tdd`, `build-implement-goal`, `build-simplify`, `build-verify`, `build-push-to-git`, `build-create-pr`, `build-address-pr-comments` (Step 1a / entry guard) | refine | A required input field (`<work-item-key>`, `WORKTREE_PATH`, etc.) is absent from the autonomous dispatch bundle. Caller must re-dispatch with the missing field populated. |
| `MISSING_PLAN` | `build-refine` (Step 3, plan-only path), `build-simplify`, `build-implement-tdd`, `build-implement-goal` (Step 1) | refine | `plan.md` not found in `specs/<key>-*/`. On the `spec_tier:plan-only` path, `plan.md` is the sole acceptance source — caller must run the light-planner / `seed-issue` that materializes it. |
| `MISSING_ACCEPTANCE` | `build-refine` (Step 4, plan-only path) | refine | The work item is `spec_tier:plan-only` but `plan.md`'s `## Acceptance criteria` section is absent or empty (placeholder/whitespace treated identically to missing). Caller must add at least one concrete acceptance criterion to `plan.md` before re-dispatch. |
| `MISSING_ARTIFACTS` | `build-refine` (Step 3) | refine | Required spec artefacts (`stories.json`, `prd.md`, `design.md`) absent on the ticket path. Caller must complete `makato-plan` shaping before re-dispatch. |
| `SPEC_NOT_FOUND` | `build-refine` (Step 2) | refine | No `specs/<key>-*/` folder exists for the supplied key. Caller must run `makato-plan:decompose` to seed the folder. |
| `INVALID_FILE_TARGET` | `build-refine` (Step 8) | refine | A planned task references a file path outside the repository root. Plan needs correction. |
| `UNCOVERED_AC` | `build-refine` (Step 9) | refine | An acceptance criterion has no covering task in the plan. Plan needs an additional task or AC needs trimming. |
| `BASELINE_BROKEN` | `build-simplify` (Step 3), `build-implement-tdd` (Step 3) | operator-escalation | A test runner was discovered but crashed before producing pass/fail counts. Distinct from the no-runner skip path (Step 3 outcome (b) in `build-simplify`), which is **not** a HALT — that path sets `test_suite_present: false` and proceeds with `degraded_confidence`. |
| `VERIFY_FAILED` | `build-simplify` (Step 7), `build-verify` (Gates 1–5) | refine | The verify gate detected new failures introduced by applied changes AND revert did not restore green. The change set is fundamentally wrong; re-plan required. |
| `UNVERIFIED_HALT` | `build-simplify` (Step 7a, interactive only) | operator-escalation | Interactive prompt answered `n` — user rejected hand-off of unverified code-file changes (no test runner available to confirm). Applied diffs are reverted before exit. Autonomous mode does not emit this code; it emits `degraded_confidence: true` in the R1 `data` instead. |
| `BUILD_FAILED` | `build-address-pr-comments` (Step 7) | refine | Applying PR-review fixes broke the build or unit tests beyond what the fix-vs-escalate decision tree can recover. |
| `PROTECTED_BRANCH` | `build-push-to-git` (Step 1), `build-address-pr-comments` (Step 1) | operator-escalation | The branch is `main` or `master`. Commits and pushes must happen on a feature branch. |
| `NOTHING_TO_COMMIT` | `build-push-to-git` (Step 3) | operator-escalation | The working tree is clean. The dispatcher's mental model of "there are changes to ship" diverges from disk; the operator must reconcile. |
| `COMMIT_FAILED` | `build-push-to-git` (Step 5) | operator-escalation | `git commit` returned non-zero. Causes include pre-commit hook failures the sensor harness already failed to repair (so this code typically appears alongside `HALT-001`). |
| `PUSH_REJECTED` | `build-push-to-git` (Step 7), `build-address-pr-comments` (Step 8) | operator-escalation | `git push` rejected by the remote. Causes: pre-push hook denial, diverged remote requiring rebase (route through `resolve-pr-conflict` separately), auth failure. Surfaces as `HALT-005` at the PO-agent level. |
| `UNPUSHED_COMMITS` | `build-create-pr` (Step 1) | operator-escalation | Local commits ahead of the upstream tracking branch. Run `/makato-build:build-push-to-git` first. |
| `GH_AUTH_FAILED` | `build-create-pr` (Step 5) | operator-escalation | `gh pr create` returned an authentication error. Operator must run `gh auth login` (or refresh the token). |
| `PR_CREATE_FAILED` | `build-create-pr` (Step 5) | operator-escalation | `gh pr create` returned non-zero for a reason other than auth (template missing, branch-protection rejection, GitHub API outage). Operator must read the embedded error and resolve. |
| `STRUCTURAL_BLOCKER` | `build-address-pr-comments` (Step 5a) | structural | One or more PR comments classified as STRUCTURAL MUST-FIX in autonomous mode. The skill posts a summary reply, applies `needs-human-review`, and surfaces this token alongside `data.halt_code: "HALT-003"`. The PO-agent reads `HALT-003` and routes per `halt-conditions.md`; `STRUCTURAL_BLOCKER` is the forensic context. |
| `CARRY_OVER_FAILED: <comment_id>` | `build-address-pr-comments` (Step 6) | operator-escalation | `gh issue create` for an OUT-OF-SCOPE carry-over comment failed. The reply was suppressed to avoid posting a half-rendered template referencing a non-existent issue. Surfaces as `HALT-005`. |
| `RENDER_FAILED: <comment_id>` | `build-address-pr-comments` (Step 9) | operator-escalation | A placeholder in the reply template could not be filled (commit SHA unresolved, follow-up URL absent). The reply was suppressed. Surfaces as `HALT-005`. |

## Caller contract

A skill that emits one of these codes MUST:

1. Surface the token in `errors[]` (free-form: `"CODE: <one-line reason>"`) OR in `data.halt_code` (canonical bare token).
2. Append a `build.jsonl` entry with `status: "error"` AND a `data.halt_code` field naming the token verbatim.
3. Return R1 `status: "failure"` (no other status is valid alongside a HALT token).

The PO-agent's parsing rule is: read `data.halt_code` if present; otherwise parse the first `[A-Z_]+:` prefix from `errors[0]`. Either is acceptable; a skill SHOULD prefer `data.halt_code` for codes documented here (machine-friendly) and reserve `errors[]` for the human-readable explanation.

## Adding a new code

When a skill needs a new HALT code:

1. **Register here first** (PR adds the row). The row MUST name origin skill(s), route, and a one-sentence description.
2. **Update the skill** to surface the code per the caller contract above.
3. **Cross-link from the skill's `## HALT Codes` section** — the per-skill section is now a one-line forward reference to this registry plus skill-unique behavioural notes (e.g. "Step 3 also fires `BASELINE_BROKEN` when X" — narrative the registry's prose can't carry).

The CI smoke test in `plugins/makato-build/shared/halt-codes-smoke-tests.sh` parses every `errors: ["..."]` literal and every `data.halt_code` value in every `SKILL.md` and asserts each token is registered here. A new code that doesn't appear here fails the suite.
