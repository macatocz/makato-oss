---
name: definition-of-done
description: >-
  Canonical, versioned, machine-checkable Definition of Done shared across the
  makato-build pipeline — 13 automated items enforced by build-verify,
  build-sensors, build-push-to-git, and the coder agent; 6 manual items asserted
  by the PO-agent from workflow-state. Use as the single source of truth that
  answers "is this task done?" — referenced from coder R1/logging evidence,
  build-verify gate mapping, and PO-agent board transition to Done. Trigger
  keywords: DoD, done criteria, task-complete, all-items-satisfied,
  board-transition-Done, workflow-state assertion.
version: "2.5.0"
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
---

# Definition of Done

## Purpose

A canonical, versioned, machine-checkable list of done criteria shared across the
makato-build pipeline and the makato-orchestrate PO-agent. Without this skill, the same
DoD knowledge was duplicated across `agents/coder.md` (targeted RED/GREEN test and R1
evidence), `skills/build-verify/SKILL.md` (gate descriptions), and the PO-agent's task-completion
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

## When to Load This Skill

**MANDATORY** — load before evaluating task-completion in any of these situations:

- **Coder R1 evidence**: before reporting targeted RED/GREEN results or DoD-related
  items recorded by the coder
- **build-verify gate mapping**: before mapping DoD item numbers to gate outcomes or HALT
  codes
- **PO-agent board transition**: before reading `workflow-state.json` to confirm all 6
  manual items are met
- **Contributor updating items**: before adding, removing, or renumbering any item —
  the fixed-count contract and coordinated-update rule apply

**Do NOT Load** when your question is:

- *"When should the PO-agent retry vs. halt?"* → that policy lives in
  `plugins/makato-orchestrate/halt-conditions.md`
- *"What is the R1 envelope schema?"* → `plugins/makato-build/agents/RETURN-CONTRACT.md`
- *"What shell commands run each gate?"* → `skills/build-verify/SKILL.md` workflow steps

## Automated Tier (13 items)

Each item lists the consumer skill/agent that enforces it. An item is "satisfied" when
its enforcer reports success in its R1 envelope (`status: "success"`) or the equivalent
gate log entry in `specs/<key>-<slug>/build.jsonl`.

1. **All unit + integration tests pass.** No new failures vs. the pre-session baseline
   recorded at `build-implement-tdd` / `build-implement-goal` Step 3.
   _Enforced by:_ `skills/build-verify/SKILL.md` Gates 3 and 4.

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

8. **No `TODO` / `FIXME` introduced without a tracking issue reference, and no debug/stale
   artifacts left in staged files.** A `TODO` line must be accompanied by a `#N` or
   `GAP-NNN` reference in the same line or its trailing comment. Debug artifacts
   (`console.log(`, `debugger`, `pdb.set_trace()`, `breakpoint()`) and staged temp/log
   files (`*.log`, `*.tmp`, `tmp_*`, `temp_*`) introduced in the session diff are also
   blocked.
   _Enforced by:_ sensor `todo-check` (TODO/FIXME) and sensor `stale-artifact-check`
   (debug/temp artifacts), both part of `skills/build-sensors/SKILL.md`.

9. **No hard-coded credentials.** `gitleaks` and `detect-secrets` both clean.
   _Enforced by:_ `skills/build-sensors/SKILL.md` (security sensor lane).

10. **`build.jsonl` entry written for every skill step in the session.** Required fields
    per `plugins/makato-build/AGENTS.md` § Skill Authoring: `ts`, `skill`, `story`,
    `step`, `status`. Append-only.
    _Enforced by:_ every makato-build skill via
    `"$MAKATO_BUILD_ROOT/shared/build-log.sh"` (the installed build-plugin root).

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

**MANDATORY — load `references/workflow-state-quickref.md` before asserting items 3, 4,
or 6.** That quickref documents the exact field names, ceiling defaults, and the
authorization chain for `skip-review`.

1. **All decomposed sub-tasks report `status: success` in their R1 envelopes.** Every
   entry in `plan.md` has a corresponding `r1` log line in `build.jsonl` with
   `data.status == "success"`.
   _Asserted by:_ PO-agent inner-loop bookkeeping per
   `plugins/makato-orchestrate/agents/po-agent.md`.

2. **No unresolved `MUST-FIX` PR comments.** Classified by
   `skills/build-address-pr-comments/SKILL.md`; the resulting JSONL log lists each
   `MUST-FIX` and its resolution status. The DoD requires zero unresolved.
   _Asserted by:_ PO-agent CI-failure / human-review outer-loop (GAP-010 / #34).

3. **`outer_iteration < 3`.** The re-plan-and-retry counter in `workflow-state.json`
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

## How to Consume This Checklist

**Interpret strictly — do not substitute judgment for a named enforcer.** Each item names
the skill or data source that owns the verdict. If `build-verify` Gate 5 has not run, item
2 is unmet — do not infer coverage from test counts or file diffs.

**Evaluation order:**

1. Evaluate Automated-tier items **sequentially** (1 → 13). Stop and surface the first
   unresolved item rather than batch-evaluating all 13. This surfaces the root gate
   failure without the noise of downstream items that cannot be assessed yet.
2. Proceed to Manual-tier items **only after** all 13 Automated-tier items are satisfied.
   Manual-tier item 1 ("all sub-tasks `status: success`") subsumes the Automated tier —
   checking both tiers in parallel creates false positives (e.g., PR approved while
   HALT-001 is still firing).
3. For Manual-tier items, assert exclusively from `workflow-state.json` and live label/PR
   state via `gh` — never infer from source files alone.

**Item 13 is advisory only (NFR-R2):** An absent passport → warning to `build.jsonl`,
gate passes. An incomplete passport → warning, gate passes. Do NOT halt on item 13. This
is the only item in the Automated tier with this property; all others are blocking.

**Unverifiable items:** When an item cannot be verified (no CI run, no `build.jsonl`
written yet, no PR open), treat it as **unmet**, not as pending or unknown. Absence of
evidence is a failure signal — the item must be actively satisfied, not assumed satisfied.

### Decision tree: ambiguous build.jsonl state

Use this tree when evaluating Automated-tier items 1, 10, and 11 and the pipeline state
is incomplete.

```
build.jsonl exists?
├── NO  → ALL items 1, 10, 11 are UNMET (pipeline never started logging)
└── YES → does it contain a step entry for the relevant gate/skill?
    ├── NO  → that item is UNMET (step did not run OR crashed before its first log line)
    └── YES → does the entry carry status: "ok" or status: "success"?
        ├── YES → item is MET
        └── NO  (status: "error", "warn", or absent) → item is UNMET
```

`build.jsonl` absent vs. step entry absent are treated identically: both are UNMET.
A partial file (truncated, missing final step) means every step without a log entry is
UNMET. Never promote a step to "assumed complete" because an earlier step logged success.

### Decision tree: ambiguous lint state (item 3)

```
Did gate-scout discover lint_ci_divergence: true?
├── NO  → run local lint; zero errors = MET
└── YES → must run BOTH local-lint AND CI-lint command
    ├── Both zero errors → MET
    ├── Local zero, CI non-zero → UNMET (CI is the authoritative gate)
    └── Either not yet run → UNMET (cannot infer CI result from local result)
```

### Decision tree: unknown pipeline state (mid-session evaluation)

Use this when evaluating DoD during an incomplete session (some gates ran, some did not):

```
Which gates have produced build.jsonl entries with status:"ok"?
├── Gate 0 (sensors) run? → check item 5 (sensors), 8 (todo/stale), 9 (credentials)
├── Gates 1-2 (build, lint) run? → check items 3, 4
├── Gates 3-4 (unit, integration) run? → check item 1
├── Gate 5 (coverage) run? → check item 2
└── Push + PR steps logged? → check items 6, 7, 10, 12
Any gate NOT in the above set → its DoD items are UNMET regardless of source-file state.
```

The rule: only affirm "MET" from a logged gate result. Never back-infer from source files,
test-count heuristics, or "the code looks correct".

## Anti-patterns

**NEVER treat an absent `build.jsonl` R1 entry as implicitly satisfied (items 1, 10, 11).**
A step that didn't log is indistinguishable from a step that failed before it could emit
its log line. Silently passing unlogged items causes the pipeline to report "done" on work
that may not have run at all.

**NEVER evaluate Manual-tier items before the Automated tier is fully green.**
The Manual tier's item 1 subsumes the Automated tier. Checking both tiers simultaneously
means a `needs-human-review`-free PR (Manual item 5) can mask an active HALT-001 sensor
loop — the issue reaches `Done` while the build is broken.

**NEVER mark item 13 (skill-provenance) as a gate failure.**
NFR-R2 makes this gate advisory by design. A session that pre-dates the F3 passport
rollout, or that ran in an environment where `skill_passport.py` opted out of F4
telemetry, produces no passport — this is expected and must not block the build. Treating
advisory items as blocking defeats the two-tier gate model.

**NEVER skip Manual-tier item 6 (PR approved) without `skip-review: true` in `makato.config.json`.**
The override is an explicit operator opt-in, not a default. Autonomously treating an
unreviewed PR as meeting item 6 removes the only human correctness checkpoint from the
pipeline. The config key is the sole authorization mechanism — label state, commit
message, `--autonomous` flag, and inferred solo-account context do NOT substitute. When
in doubt, read `makato.config.json` directly; do not read `workflow-state.json` for this
value (the key is not propagated there).

**NEVER add heuristic done-criteria derived from "similar" items in this file.**
The item list has a fixed count that is part of this skill's versioned contract (§ Versioning).
Appending unlisted heuristics silently breaks the item-count invariant that consumers use
to detect contract drift — the discrepancy will not be caught until a coordinated update
triggers a version check.

**NEVER re-interpret item 11 (R1 last-fenced-block rule) to allow prose-embedded JSON.**
Callers locate R1 by scanning for the last ` ```json ` fence — any R1 embedded in prose
or earlier in the response is silently ignored. An agent that embeds valid JSON outside
the final fence will report `status: "failure"` to its caller even though it produced
correct output.

**NEVER use `outer_iteration` to infer test/lint/sensor status (items 1–9).**
`outer_iteration` counts PO-agent re-plan iterations, not quality-gate passes. A value of
`outer_iteration == 0` does not mean the automated tier passed — it means no re-plan has
occurred yet. Gate status comes only from `build.jsonl` entries.

## Cross-references

The following consumers reference this skill as their authoritative checklist. Any change
to item count, numbering, or wording in this file is a contract change for all of them
and requires a coordinated update.

- `plugins/makato-build/agents/coder.md` § Output Contract (R1): enforces Automated-tier
  items 10 and 11; item 1 is enforced by build-verify.
- `plugins/makato-build/skills/build-verify/SKILL.md` § Definition-of-Done — Automated
  Tier Mapping: maps each of items 1–13 to its gate and the HALT code that fires when
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
