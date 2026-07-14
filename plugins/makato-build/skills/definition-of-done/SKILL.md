---
name: definition-of-done
description: >-
  Canonical, versioned, machine-checkable Definition of Done shared across
  the makato-build pipeline — 12 automated items enforced by build-verify,
  build-sensors, build-push-to-git, and the coder agent; 6 manual items
  asserted by the PO-agent from workflow-state. Use as the single source
  of truth that answers "is this task done?" — referenced from coder VERIFY,
  build-verify gate mapping, and PO-agent task-completion logic.
version: "2.1.0"
---

# Definition of Done

## Purpose

A canonical, versioned, machine-checkable list of done criteria shared across the
makato-build pipeline and the makato-orchestrate PO-agent. Without this skill, the same
DoD knowledge was duplicated across `agents/coder.md` (VERIFY phase prose),
`skills/build-verify/SKILL.md` (gate descriptions), and the PO-agent's task-completion
heuristics — drifting independently and forcing humans to re-derive what "done" means
each time. This skill is the **single source of truth** those consumers reference.

The list is split into two tiers:

- **Automated tier (13 items)** — each item is enforced by a named skill or agent in the
  pipeline. The verification-agent described in the AgenticSystem PRD is a future
  consolidation; today `build-verify` + `build-sensors` + `build-push-to-git` + the
  `coder` agent collectively cover the tier.
- **Manual tier (6 items)** — each item is asserted by the PO-agent
  (`plugins/makato-orchestrate/agents/po-agent.md`) from `workflow-state.json`. These
  items describe state the automated pipeline cannot verify alone (human review status,
  label state, outer-loop counters).

When a build session is autonomous, the PO-agent treats the union of both tiers as the
authoritative checklist: only when every item is satisfied is the task marked
`status: success` in workflow-state and the issue eligible for `Done` on the board.

## Automated Tier (13 items)

Each item lists the consumer skill/agent that enforces it. An item is "satisfied" when
its enforcer reports success in its R1 envelope (`status: "success"`) or the equivalent
gate log entry in `specs/<key>-<slug>/build.jsonl`.

1. **All unit + integration tests pass.** No new failures vs. the pre-session baseline
   recorded at `build-implement-tdd` / `build-implement-goal` Step 3.
   _Enforced by:_ `agents/coder.md` VERIFY phase; `skills/build-verify/SKILL.md` Gates 3
   and 4.

2. **Conditional coverage ≥ threshold.** Default 90% conditional (branch) coverage; the
   threshold is overridable per-story in `specs/<key>-<slug>/design.md`. Below threshold
   triggers HALT-002.
   _Enforced by:_ `skills/build-verify/SKILL.md` Gate 5.

3. **Zero lint errors.** Warnings are noted but do not fail the gate; errors do.
   Local-lint / CI-lint divergence is reconciled when `lint_ci_divergence: true`.
   _Enforced by:_ `skills/build-verify/SKILL.md` Gate 2.

4. **Zero type-check errors.** Build / typecheck gate reports zero errors. Structural
   type failures escalate to `/build-refine`.
   _Enforced by:_ `skills/build-verify/SKILL.md` Gate 1; per-finding repair via
   `skills/build-fix-types/SKILL.md`.

5. **Zero CRITICAL sensor findings.** Pre-commit sensors (`bandit`, `semgrep:security`,
   `gitleaks`, `detect-secrets`, etc.) exit clean within `MAX_LOOPS=5`. Residual
   non-critical findings may carry over to a draft PR.
   _Enforced by:_ `skills/build-sensors/SKILL.md`; per-finding repair via
   `skills/build-resolve-finding/SKILL.md`. Unmet ⇒ HALT-001 (sensor-fixer exhausted) or
   HALT-004 (same finding 5 times).

6. **Conventional commit format on every commit on the branch.** Title pattern
   `type(scope): description` validated by the repo's `validate.yml` workflow.
   _Enforced by:_ `skills/build-push-to-git/SKILL.md` (per-commit drafting) and the
   `pr-title` CI job.

7. **Branch rebased on `origin/main` at PR-open time.** No merge commits introduced;
   linear history maintained.
   _Enforced by:_ `skills/build-push-to-git/SKILL.md` push deny-list; mismatch ⇒ HALT-005.

8. **No `TODO` / `FIXME` introduced without a tracking issue reference.** A `TODO` line
   must be accompanied by a `#N` or `GAP-NNN` reference in the same line or its trailing
   comment.
   _Enforced by:_ sensor `todo-check` (part of `skills/build-sensors/SKILL.md`).

9. **No hard-coded credentials.** `gitleaks` and `detect-secrets` both clean.
   _Enforced by:_ `skills/build-sensors/SKILL.md` (security sensor lane).

10. **`build.jsonl` entry written for every skill step in the session.** Required fields
    per `plugins/makato-build/AGENTS.md` § Skill Authoring: `ts`, `skill`, `story`,
    `step`, `status`. Append-only.
    _Enforced by:_ every makato-build skill via `shared/build-log.sh` (bare relative
    path).

11. **R1 JSON block present as the last fenced ` ```json ` block in every agent return.**
    Schema and parsing rules per `plugins/makato-build/agents/RETURN-CONTRACT.md`.
    Callers parse the last `json`-fenced block via `JSON.parse()` — no prose parsing.
    _Enforced by:_ each agent's `## Output Contract (R1)` section. Violation ⇒ caller
    treats dispatch as `status: "failure"`.

12. **PR description includes `Closes #N`.** Where `#N` is the work-item issue. Drives
    auto-close on merge and board-status transition to `Done` via
    `makato-plan:issue-to-project sync-lifecycle`.
    _Enforced by:_ `skills/build-create-pr/SKILL.md` description draft (interactive
    review catches omission before PR is opened).

13. **Skill-provenance recorded and complete.** A `skill-passport.json` for the run
    exists (or a "skill usage tracking skipped" note was emitted when no passport is
    available), and every skill in `skills_expected` (resolved from the final git diff
    via `skill-bundles.yml`) is present in `skills_invoked_transitively` (computed by
    `compute_rollup` in `skill_passport.py`). When a skill is missing, one advisory
    warning per skill is emitted to `build.jsonl`; **the gate is advisory only and
    never fails the build** (NFR-R2). A detected concurrent-write race emits a warning
    and skips the diff — no passport corruption.
    _Enforced by:_ `skills/build-verify/SKILL.md` Step 9 (skill-provenance advisory
    gate).

## Manual Tier (6 items)

Each item is asserted by the PO-agent from `workflow-state.json` (the schema lives at
`plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json`).
These items describe state the automated pipeline cannot verify alone.

1. **All decomposed sub-tasks report `status: success` in their R1 envelopes.** Every
   entry in `plan.md` has a corresponding `r1` log line in `build.jsonl` with
   `data.status == "success"`.
   _Asserted by:_ PO-agent inner-loop bookkeeping per
   `plugins/makato-orchestrate/agents/po-agent.md`.

2. **No unresolved `MUST-FIX` PR comments.** Classified by
   `skills/build-address-pr-comments/SKILL.md`; the resulting JSONL log lists each
   `MUST-FIX` and its resolution status. The DoD requires zero unresolved.
   _Asserted by:_ PO-agent CI-failure / human-review outer-loop (GAP-010 / #34).

3. **`outer_iterations < 3`.** The re-plan-and-retry counter in `workflow-state.json`
   has not exceeded HALT-008's bound. If `>= 3`, the issue exits with
   `needs-human-review`.
   _Asserted by:_ PO-agent kill-switch (per
   `plugins/makato-orchestrate/halt-conditions.md` HALT-008).

4. **`human_review_cycles < MAX`.** Default `MAX = 3`. The issue has not bounced through
   `needs-human-review` more times than the operator-configured ceiling allows.
   _Asserted by:_ PO-agent kill-switch (HALT-010).

5. **No `needs-human-review` label on the PR or its source issue.** A `needs-human-review`
   label signals an unresolved escalation; the DoD requires the label absent.
   _Asserted by:_ PO-agent prior to marking the issue `Done` on the board.

6. **PR approved.** A reviewer has approved, OR the operator has set
   `skip-review: true` in `makato.config.json` (organization-level override for
   bootstrap repos / solo accounts).
   _Asserted by:_ PO-agent via `gh pr view --json reviewDecision` prior to board
   transition.

## Cross-references

The following consumers reference this skill as their authoritative checklist. Any change
to item count, numbering, or wording in this file is a contract change for all of them
and requires a coordinated update.

- `plugins/makato-build/agents/coder.md` § Phase 4 — VERIFY: enforces Automated-tier
  items 1, 10, 11.
- `plugins/makato-build/skills/build-verify/SKILL.md` § Definition-of-Done — Automated
  Tier Mapping: maps each of items 1–12 to its gate and the HALT code that fires when
  the item is unmet in autonomous mode.
- `plugins/makato-orchestrate/agents/po-agent.md` (when consumed): asserts the full
  Manual tier from `workflow-state.json` before transitioning the issue's board Status
  to `Done`.

## What this skill does NOT do

- This skill is a **checklist**, not an enforcer. It does not run tests, scan for
  credentials, or transition labels. Each item names the skill or agent that enforces
  it; this file's job is to keep that mapping in one place.
- It does not define the dispatching policy ("when should the PO-agent retry vs.
  halt?"). That policy lives in `plugins/makato-orchestrate/halt-conditions.md`.
- It does not own the R1 envelope schema. That contract is in
  `plugins/makato-build/agents/RETURN-CONTRACT.md`; item 11 of the Automated tier merely
  requires that R1 is present.

## Versioning

The Automated and Manual tiers each have a **fixed item count** that is part of this
skill's contract: 13 automated, 6 manual. Adding, removing, renumbering, or merging
items is a **breaking contract change** for every consumer in § Cross-references and
**must** bump this skill's `version` major (e.g. `1.0.0` → `2.0.0`) plus a coordinated
update to each consumer in the same PR.

Wording-only edits (clarifying a description without changing the item's enforcer or
gate) are minor bumps (`1.0.0` → `1.1.0`). Typo fixes are patch bumps
(`1.0.0` → `1.0.1`).
