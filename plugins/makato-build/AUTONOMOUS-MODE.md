<!-- Retain legacy long-line/list layout; fenced examples always declare their language. -->
<!-- markdownlint-disable MD013 MD032 -->

# Autonomous Mode — makato-build approval-gate bypass convention

> **Status**: Authoritative for all `build-*` skills in this plugin. When a skill takes a runtime
> decision via `AskUserQuestion`, autonomous mode replaces that decision with the documented
> default. Interactive runs are unaffected.

## Runtime root input

All `build-*` skills receive or resolve `MAKATO_BUILD_ROOT`, the absolute installed makato-build
plugin root. Suite-owned helpers in this document must be invoked through that root; never assume
the consumer repository's current directory is the plugin root.

## Why this exists

Every `build-*` skill that transitions between pipeline phases calls `AskUserQuestion` for approval.
This is intentional for interactive use — but it structurally prevents headless operation by a
PO-agent. The PO-agent (GAP-006 / #32) drives the build pipeline end-to-end without a human at the
prompt, parsing R1 envelopes (GAP-002 / #24) from each skill's last `json`-fenced block. For that to
work, every gate that today waits on a human must take a deterministic, documented default in
autonomous mode.

`plugins/makato-plan/skills/to-issues/SKILL.md` v3.4.0 already proves the bypass pattern (see its §
_Mode detection (D10)_ and § _Autonomous Execution_). This document is the build-plugin equivalent —
same shape, same activation triggers, same logging contract.

## Activation triggers

A `build-*` skill runs in **autonomous mode** when ANY of the following holds:

1. `--autonomous` is passed on the CLI (e.g. `/makato-build:build-refine GAP-005 --autonomous`).
2. The caller provides a context bundle whose payload includes a `task_id` field (the convention
   agent-dispatch infrastructure uses to mark a downstream invocation).
3. The `$AGENT_ID` environment variable is exported (set by makato agent dispatch infrastructure).

If none of those hold the skill runs in **interactive mode**, exactly as it did before this
convention existed. Interactive mode is the default — autonomous mode is opt-in by infrastructure or
CLI flag.

**Precedence:** the three triggers are OR-equivalent. Once any one is true the skill is autonomous;
further checks are unnecessary.

## Defensive-headless guard (`MAKATO_HEADLESS`)

`MAKATO_HEADLESS=1` is **not a fourth autonomous trigger** — it is the opposite. It is a caller-side
assertion of "no human is at the prompt" that lets a skill refuse to hang when the caller has
forgotten to set any of the three autonomous triggers above.

Semantics:

- If `MAKATO_HEADLESS=1` is set AND at least one autonomous trigger fired → run autonomous
  (autonomous wins; the env var is redundant but harmless).
- If `MAKATO_HEADLESS=1` is set AND no autonomous trigger fired → HALT with
  `MISSING_INPUT: headless-without-autonomous` before the first `AskUserQuestion`. Write a
  `build.jsonl` `session/error` entry with `halt_code: "MISSING_INPUT"` and return an R1
  `status:"failure"` envelope. Do NOT auto-fall-back to autonomous mode — the caller violated the
  contract and must be told, not papered over.
- If `MAKATO_HEADLESS` is unset → normal interactive path, no guard fires.

**Why an explicit env var and not tty auto-detection:** inside a Claude Code Bash tool
`stdin`/`stdout` are always pipes, even in a fully interactive human-driven session. A
`[[ ! -t 0 ]]` auto-detector would false-positive and kill legitimate interactive runs.
`MAKATO_HEADLESS=1` is the caller's declaration; the skill trusts it.

**Callers that MUST export `MAKATO_HEADLESS=1`:** any script that spawns
`claude --dangerously-skip-permissions -p …`. Currently:

- `plugins/makato-orchestrate/scripts/loop.sh` — `cmd_dispatch`
- `plugins/makato-orchestrate/scripts/context-handoff.sh` — `_emit_resume`

Both call sites belong to the makato-orchestrate plugin and are the only headless entry points into
build-\* skills today. Any new headless caller must export the variable on its side of the boundary.

Skill-side detection lives in the `build-*` skill's Step 1b (see `build-refine/SKILL.md` § _Step 1b
— Headless-context defensive guard_ for the canonical shape). Other `build-*` skills that fire
`AskUserQuestion` in Step 1 or later gates SHOULD add an equivalent Step 1b when they are dispatched
by a headless caller — track via the skill's own PR when the need arises.

## Default-taking rules per gate

| Skill                       | Gate (line ref to the `AskUserQuestion` site)                                                        | Interactive behavior                                                                    | Autonomous default                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-refine`              | Step 1 — work-item-key prompt                                                                        | Asks for key                                                                            | If no arg passed: HALT `MISSING_INPUT`. If arg passed: use it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `build-refine`              | Step 4 — confirm-the-key prompt (key absent from stories.json)                                       | Asks user to confirm the key                                                            | HALT `MISSING_ARTIFACTS` (unknown-key); never prompt. The po-agent re-validates and routes to the tier fallback (#527).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `build-refine`              | Step 11 — plan-review (in-chat vs in-browser)                                                        | Asks how to review                                                                      | Write `plan.md`, skip review entirely, proceed to hand-off.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `build-push-to-git`         | Step 4 — commit-grouping confirmation                                                                | Asks user to confirm grouping & messages                                                | Use plan task `commitMessage` fields verbatim; no confirmation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `build-push-to-git`         | Step 6 — push confirmation                                                                           | Asks "Ready to push N commits?"                                                         | Push immediately. Pre-push hook still fires.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `build-push-to-git`         | Step 8 — hand-off                                                                                    | Ask whether to create a PR                                                              | Initial push invokes create-pr; EXISTING_PR_NUMBER + CI_REPAIR_ACTIVE updates that PR only, without nesting creation or another CI loop.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `build-create-pr`           | Step 1 — work-item-key prompt                                                                        | Asks for key (optional)                                                                 | Use arg if passed; otherwise read `issue_number`/`branch` from most-recent `build.jsonl` session in the spec folder. HALT `MISSING_INPUT` only if neither yields a value.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `build-create-pr`           | Draft approval and post-create gate                                                                  | Approve draft, create PR and return                                                     | Create/reuse PR, then wait for build-fix-ci; preserve PR number and propagate non-green results.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `build-address-pr-comments` | Step 5 — classification approval                                                                     | Asks user to confirm/adjust classification + handles STRUCTURAL flow                    | Auto-apply MUST-FIX (non-STRUCTURAL). SHOULD-FIX is **scope-guarded** (apply only if all touched files are inside the task diff; otherwise mark DEFERRED with a `[DEFERRED]` reply). Skip CONSIDER. OUT-OF-SCOPE: open a follow-up issue via `gh issue create` with the `makato-carry-over` label and reply with the new issue URL. STRUCTURAL MUST-FIX: HALT (see below).                                                                                                                                                                                                                                                                                                                     |
| `build-address-pr-comments` | Step 5a — STRUCTURAL handling                                                                        | Asks user A/B/C and waits                                                               | Post a single summary reply on the PR (template § _STRUCTURAL MUST-FIX_), apply `needs-human-review` to PR + linked issue, log per-comment + summary `autonomous_bypass`, return R1 `failure` with `data.halt_code: "HALT-003"`. The skill applies the label itself — see _Label-application exception_ below.                                                                                                                                                                                                                                                                                                                                                                                 |
| `build-address-pr-comments` | Step 8 — push-fix confirmation                                                                       | Asks before push                                                                        | Push immediately.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `build-address-pr-comments` | Step 6a — `recurring-pattern-check`                                                                  | Fires unconditionally when recurrence threshold is met                                  | Auto-approve harness issue creation; surface `harness_issues_opened` in R1 envelope                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `build-simplify`            | Step 5 — per-finding approval                                                                        | Asks user to approve/reject each SIMPLIFY finding                                       | Auto-approve every `SIMPLIFY` finding (apply in Step 6). KEEP findings remain KEEP (no action). ESCALATE findings are not auto-applied — they are logged and surfaced in the R1 envelope so the PO-agent can decide whether to open a `/build-refine` session for the structural piece.                                                                                                                                                                                                                                                                                                                                                                                                        |
| `build-simplify`            | Step 5 — zero-findings confirmation                                                                  | Asks user to confirm zero findings                                                      | Proceed without confirmation. Log `step: "review"` with `data.zero_findings: true`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `build-simplify`            | Step 7a — unverified-code-changes prompt (no test runner discovered AND ≥1 code-file change applied) | Prompts y/n before hand-off                                                             | Skip prompt entirely; emit R1 with `data.test_suite_present: false` + `data.degraded_confidence: true` so the PO-agent routes the run for elevated scrutiny. See § _No-test-runner handling in `build-simplify` is a degraded-confidence path, not a HALT_.                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `build-review`              | Durable review gate and runtime                                                                      | Persist every review/repair/confirmation transition; fail closed on incomplete evidence | Identical to interactive mode; no approval bypass. `review_loop.py gate` owns decisions, persisted caps, receipts, and convergence; final-full/all-AC review plus no-change completion gate are mandatory.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `build-grill-with-docs`     | Step 1 — work-item-key prompt                                                                        | Asks for key                                                                            | If no arg passed: HALT `MISSING_INPUT`. If arg passed: use it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `build-grill-with-docs`     | Step 5a — alignment interview (term conflicts, fuzzy/overloaded names, ADR-worthy choices)           | Asks the user one question at a time, with a recommendation each                        | Settled or cheap-to-reverse → take the recommended option (`gate: "term-resolution"`, `default_taken: "take-recommended"`), `assumed` in `decisions.md` + `data.assumed`. Costly and unsettled → ONE batched comment on the issue (lettered options, one recommendation each), card → `Blocked`, marker `awaiting-answers-<N>.json`, R1 `partial` with `data.awaiting_answers`; this is a park, not a HALT. Human answers + moves the card to `Ready`/`In progress` → `loop` resumes. No board / no `ISSUE_NUMBER` / refused board write / round cap (`MAKATO_GRILL_MAX_QUESTION_ROUNDS`, default 3) / `MAKATO_GRILL_MODE=decide` → take the recommendation (`gate: "questions-unavailable"`). |
| `build-grill-with-docs`     | Step 1 — ADR directory missing                                                                       | Asks which directory to use                                                             | Skip ADR writing (`gate: "adr-dir-missing"`, `default_taken: "skip-adrs"`); the decisions stay in `decisions.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `build-grill-with-docs`     | Step 7 — ADR approval                                                                                | Asks whether to write each ADR                                                          | Write the ADR when the decision is hard to reverse, surprising and a real trade-off; no approval prompt.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

### Open questions: the ticket is the human channel (`build-grill-with-docs`)

An autonomous run never prompts in chat, but some questions are not the agent's to settle. For those
the skill uses the ticket the way an interactive session uses the chat — the same question shape
(lettered options, exactly one recommendation), asked **once, all at the same time**:

1. Settled, cheap-to-reverse or unanswerable questions are **decided**: the recommended option is
   taken, marked `assumed` in `decisions.md` and listed in `data.assumed` for review.
2. Every remaining question goes into ONE comment (`shared/human_questions.py post`); the card is
   moved to **Blocked** and `awaiting-answers-<N>.json` is written to the spec folder. The skill
   returns R1 `partial` with `data.awaiting_answers`. This is a **park, not a HALT**: no
   `needs-human-review`, no HALT code, the worktree and workflow-state are retained
   (`current_phase: "refine"`, `resume_point: "grill-awaiting-answers"`).
3. The human replies in the issue (`Q1: B`, `all: recommended`) and moves the card to **Ready** or
   **In progress** — that move is the "I answered" signal. `loop` notices it on its next tick
   (`_resume_answered_questions`) and resumes the run with `--resume`; the skill collects the
   replies (`shared/human_questions.py collect`), applies them and carries on.
4. A follow-up round is asked only when an answer creates new questions, at most
   `MAKATO_GRILL_MAX_QUESTION_ROUNDS` (default 3) rounds; after that the recommendations are taken.

Fallbacks that keep the run moving: no `ISSUE_NUMBER`, an unobservable board or a refused board
write → decide instead of wait; `MAKATO_GRILL_MODE=decide` forces decide-recommended everywhere (the
po-agent skips the grill gate altogether under `MAKATO_GRILL_MODE=skip`); a wait longer than
`MAKATO_QUESTIONS_MAX_WAIT_SECS` expires and the run resumes with the recommendations. See
`plugins/makato-orchestrate/halt-conditions.md` § _Awaiting answers_ for the loop-side rules
(guards, resume budget, escalation).

### Current-head CI repair ownership

`build-fix-ci` is the single shared CI coordinator. Autonomous create-pr waits for it; PO-agent
delegates to it after later repair pushes and on `ci-poll` resume. Manual PR creation stays
unchanged. Standalone autonomous contexts carry `AUTONOMOUS_MODE:true` and a stable `task_id` when
no inherited `AGENT_ID` exists.

Long-running role-runner calls use managed background jobs without a short shell deadline. Prefer
host-delivered completion events without polling; otherwise observe only the owned job/result at
intervals of at most 60 seconds. Never globally wait for a coordinator that is itself waiting on
that child. Read and validate terminal R1, persist its outcome and clear the running-child marker
before advancing. On resume, reconcile saved results before dispatching again. On a tool
interruption, settle the owned child before resuming the checkpoint; never launch a concurrent
replacement or treat partial output as a skill outcome. A headless permission/configuration blocker
returns terminal R1 immediately: an immutable prompt cannot receive later approvals. The caller may
resume with an amended context after the previous process exits. This applies throughout the
autonomous push → create-pr → CI-repair dispatch chain.

The executable `shared/ci_checks.py` inspects all current-head check/status contexts and
required-check rules, retrieves exact failed run/job/attempt logs, and fails closed on unknown
requirements or inaccessible diagnostics. Optional skips may pass; required skips do not.
Empty/missing checks are not green. TDD and goal-mode receive structured `CI_FAILURES`, not
truncated log tails. Targeted CI failures must be repaired rather than accepted into a broken
baseline. Source repairs pass blocking review and verification before the existing-PR push.

The default `MAKATO_MAX_CI_FAILURE_CYCLES=0` removes the arbitrary three-round ceiling. Positive
values opt into a cap. No-progress, external blockers, operator cancellation and pending timeout
remain non-success exits. Poll interval defaults to 60 seconds; `MAKATO_CI_WAIT_SECS` defaults
to 600. Full diagnostics and the atomic PR-scoped checkpoint live under the worktree's git metadata;
public logs contain only sanitized outcomes. PO-agent alone writes workflow-state and mirrors
returned repair counts. Old `flake_rerun_pending` is removed; when upgrading an in-flight state
file, remove that obsolete key before schema validation/resume. No PR merge, protection-rule change,
workflow disabling or failure suppression is authorized by this gate.

### `build-refine` is the engine of the po-agent `materialize-refine` verdict (#527)

`makato-orchestrate`'s `should-materialize-spec.sh` gate has a fourth verdict, `materialize-refine`:
when a full-tier (or any-tier) issue reaches Step 1a with a missing/stub `plan-<N>.md` but a
**git-tracked `stories.json`** (≥ 1 story) sits in its spec folder, the po-agent dispatches
`build-refine --autonomous <KEY>` to translate that committed `stories.json` into the plan. This is
a pure `stories.json` → `plan-<N>.md` translation, not a second planning pass:

- **Step 1** (work-item-key) — uses the KEY the po-agent supplies (autonomous default, per the table
  above); never prompts.
- **Step 4** (key resolution) — the KEY selects the matching story; a key-miss HALTs with
  `MISSING_ARTIFACTS` (autonomous default, per the table above) rather than firing the interactive
  confirm-the-key prompt.
- **Step 11** (plan-review) — writes the plan and skips review (autonomous default, per the table
  above).

Neither key (identity) nor plan-review (output-control) asks about content, so the autonomous lane
never blocks on a human. The po-agent re-validates the written plan deterministically via
`validate-plan-body.sh` — build-refine's R1 is not trusted as the source of truth — and a full-tier
key-miss routes to HALT-006 (`needs-human-review`). Precedence, the untracked-stories.json degrade,
and the light-planner fallback (`plan-tier:light`, no committed stories.json) are documented in
`plugins/makato-orchestrate/agents/po-agent.md` § _Step 1a_ and
`plugins/makato-orchestrate/halt-conditions.md` (HALT-006).

`build-address-pr-comments` classifies a MUST-FIX as **STRUCTURAL** when it requires changing the
fundamental implementation approach (data model redesign, API contract reversal, algorithm
replacement). In autonomous mode the skill does NOT attempt to auto-fix structural items — it posts
a single summary reply on the PR (template `templates/pr-comment-replies.md` § _STRUCTURAL MUST-FIX
(autonomous HALT — AC3)_), applies the `needs-human-review` label, and halts with R1
`status: "failure"`, `errors: ["STRUCTURAL_BLOCKER: <first comment summary>"]`, and
`data.halt_code: "HALT-003"`. The PO-agent reads the R1 envelope and escalates (e.g. opens a fresh
`/build-refine` session or surfaces to the human operator).

This is a deliberate gap, not an oversight. Re-planning is a judgment call the build pipeline does
not attempt headlessly.

### Label-application exception — STRUCTURAL HALT-003

The general rule in `plugins/makato-orchestrate/agents/po-agent.md` § _Label application_ assigns
`needs-human-review` labelling to the PO-agent. `build-address-pr-comments` is a deliberate
exception in two ways:

1. **Sub-skill side applies the label.** AC3 of GAP-011 (#36) requires the skill itself to apply
   `needs-human-review` to the PR at the moment of STRUCTURAL detection. This is so the PR's
   reviewer sees the label even on runs where the PO-agent crashes between the sub-skill's exit and
   its own HALT-audit write (a small but non-zero window). The skill also labels the linked issue
   for redundancy.
2. **PO-agent's later `gh issue edit` is a no-op.** Per `gh issue edit --add-label` semantics,
   adding an already-present label is idempotent. The PO-agent's HALT-003 path therefore safely runs
   its own labelling step without conflict — the contract (single source of truth = the label set,
   not the number of writers) is preserved.

Operators reading `orchestrate.jsonl` will see the label write attributed to both the skill
(`source: "build-address-pr-comments"` in the `gh` event log if captured) and the PO-agent
(`halt_audit[].code: "HALT-003"` entry). Both records are expected; neither is duplicate work.

### ESCALATE findings in `build-simplify` are deliberately not auto-applied

`build-simplify` Step 4 classifies a finding as **ESCALATE** when the complexity is structural — it
cannot be resolved without changing the implementation approach — OR when the simplification would
remove a security guard (input validation, auth check, CSRF token, rate limiter). In autonomous mode
these findings are NOT auto-applied; they are logged with `step: "escalate", status: "warn"` and
surfaced in the R1 envelope's `data.escalated` array so the PO-agent can decide whether to open a
`/build-refine` session for the structural piece.

This mirrors `build-address-pr-comments` STRUCTURAL-MUST-FIX handling: deterministic-and-safe is
auto-applied; judgment-required is surfaced upward, never silently skipped.

A `build-simplify` session that produced zero SIMPLIFY findings AND any ESCALATE findings returns R1
`status: "partial"` (work remains for the PO-agent). A session with zero ESCALATE findings (any
SIMPLIFY count, including zero) returns `status: "success"`.

### No-test-runner handling in `build-simplify` is a degraded-confidence path, not a HALT

When `build-simplify` Step 3 dispatches `gate-scout` against a project with no runnable test command
— a docs-only repo, a config-only repo, or a freshly scaffolded project where tests haven't been
written yet — the skill does NOT HALT. The session proceeds with `test_suite_present: false` and
skips both the Step 3 baseline-capture and the Step 7 verify gate. The R1 envelope's
`data.degraded_confidence: true` is the upward signal the PO-agent reads to route the run for
elevated scrutiny — accept-as-is for a low-risk docs-only diff, open `/build-refine` to add a test
runner, or surface to the human operator.

The non-autonomous prompt (Step 7a y/n before hand-off when code files were touched) is replaced in
autonomous mode by the `degraded_confidence` signal. This mirrors the ESCALATE pattern:
judgment-required decisions are surfaced upward via the R1 envelope, never silently dropped. The
`BASELINE_BROKEN` HALT code remains for the **distinct** case where a test runner exists but crashes
before producing pass/fail counts — that is an error, the no-runner case is not.

Step 7a is a no-op when the only files touched are doc/config (`**/*.{md,yaml,yml,json,toml}`); the
diff is auditable from the file list itself and no scrutiny gate is needed. `status` remains
`"success"` with `degraded_confidence: true`. Any code-file touch in autonomous mode bumps the
envelope to `status: "partial"` so the PO-agent treats the run as "completed, needs review."

### Durable `build-review` gate and runtime

`build-review` is mandatory before verify in the PO-agent pipeline. The shared review ledger owns
every state transition, evidence receipt, repair attempt, and recurrence history. Store it in the
worktree's private git directory at
`$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/makato-review-loop/<key>.json`; runtime
state is separate at `<ledger-dir>/<key>/runtime.json`. Never use or mutate `workflow-state.json`
for review-local receipts. An incompatible legacy ledger requires explicit migration; never reset
its history or counters.

The autonomous launcher pins a complete expected AC list and the installed plugin's contract paths
before dispatching the child. Context paths are repo-relative to `REPO_ROOT`; contract paths are
plugin-relative to the active `MAKATO_BUILD_ROOT`, so installed plugins work in consuming
repositories that have no `plugins/makato-build` directory:

```bash
ATTEMPT_ID="$(printf '%s\0%s\0%s' "$KEY" initial "$INPUT_FINGERPRINT" | sha256sum | cut -c1-64)"
"$MAKATO_SKILL_RUNNER" --repo-root "$REPO_ROOT" --cwd "$WORKTREE_PATH" \
  --context-file "$CONTEXT_FILE" --harness "$CLAUDE_BIN" --approval-mode yolo \
  --review-ledger-state "$STATE" --attempt-id "$ATTEMPT_ID" \
  --input-fingerprint "$INPUT_FINGERPRINT" --gate-event initial \
  --review-worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" \
  --review-evidence-root "$REPO_ROOT" --review-expected-ac-ids "$EXPECTED_AC_IDS" \
  --review-context-path "$SPEC_REL/plan.md" \
  --review-contract-path skills/build-review/SKILL.md \
  --review-contract-path skills/build-review/references/review-loop.md \
  --review-contract-path skills/build-review/references/review-criteria.md \
  --review-contract-path skills/build-review/references/mechanical-fixes.md \
  --review-contract-path agents/diff-reviewer.md \
  --review-contract-path agents/coder.md \
  --review-contract-path agents/RETURN-CONTRACT.md \
  --review-contract-path AUTONOMOUS-MODE.md \
  --review-contract-path config/default-workflow-schema.yml \
  --review-contract-path config/verification-ownership.md \
  --review-contract-path shared/review_loop.py \
  --review-contract-path shared/review_scope.py \
  --review-contract-path shared/review_runtime.py \
  --review-contract-path shared/review_eval.py \
  --review-contract-path shared/skill_execution.py \
  --review-contract-path scripts/run-skill.py \
  makato-build:build-review -- "$KEY" --autonomous [--checkpoint-task-ids "$IDS"]
```

Repeat `--review-context-path` for every file actually supplied to `PLAN_CONTEXT`, and keep the
complete expected AC ID set pinned across all gates, including checkpoint launches. Omit
`--next-action` to let the runtime select the current stage; supplying it is an assertion, not an
override. `initial` starts a coordinator; `checkpoint` is an evidence-bearing core event after a
successful delta pass, never a launcher event. `run-skill.py` bootstraps the initial gate using the
active installed plugin root and passes its receipt to the child. The child validates the live
fingerprint and resumes the returned stage; it must not repeat an initial full scan when `confirm`,
repair, or `certify` is already next. Do not run a second initial gate out of band. Later core gates
inherit the persisted `contract_root`; `--review-contract-path` remains relative to
`MAKATO_BUILD_ROOT`.

The run-specific `input_fingerprint` binds branch bytes, merge base, spec/context, and exact review
contracts. It is not the evaluation `configuration_fingerprint`, which identifies model, prompt,
review contract, and policy across corpus snapshots. Never substitute one for the other.

`review_loop.py gate --state PATH` persists `initial`, `review`, `confirm`, `repair-local`,
`redesign`, `certify`, `checkpoint`, `complete`, and `blocked` transitions with a reason. Its
`next_action` is authoritative. A timeout, coder R1, manual edit, or clean-looking reviewer response
is never approval. HALT, budgets, approvals, and persisted caps remain enforced.

Both CRITICAL and MAJOR block in manual and autonomous modes. Severity is evidence-based: CRITICAL
requires an actual reachable behavioral regression with concrete impact and executable evidence;
every confirmed CRITICAL gets a durable behavioral regression test. MAJOR requires a concrete
reachable correctness-adjacent defect and targeted reproduction. Every new or unconfirmed blocking
constituent is independently verified in a batched read-only reviewer mode on the same immutable
snapshot, with `confirmed|rejected|uncertain`, citations, and
`repair_scope: local|architectural|cross-boundary|unknown`. Uncertain, missing, or minority
confirmed evidence remains blocking; no majority suppresses a finding. Only all-active-constituent
`local` scope authorizes a bounded repair, regardless of severity. Architectural, cross-boundary, or
unknown scope and a second unsuccessful return of the same invariant require a short reviewed plan;
CRITICAL severity alone does not. Confirmation and repair authorization cover raw blocking
`constituent_ids` of the latest ordinary pass, not every historical site in an aggregate invariant.
Repaired constituents not re-raised retain their history and independent final-certification
obligations.

Universal invariants require explicit input/entry/return/raise/helper/transaction/async/effect/test
coverage and unknown-path matrices. UI state additionally covers temporal order, pending/concurrent/
late responses, state owner, navigation, and draft preservation. Unknown paths are gaps. A wrapper
is not the default fix. Keep every raw finding, site, and history; do not merge by proximity.
Mechanical normalization occurs before freezing the immutable review snapshot. Parallel smoke and
review are allowed only on the same identical immutable tree; do not begin repair until all
read-only reviewers finish or have isolated snapshots. Every final run requires a fresh final-full
review of the complete branch and all ACs, citations, independent blocker closure, and the
mechanical no-change `complete` gate.

Risk-sample duplication is OFF by default. `deep` requires a `review-eval-v2` report bound to actual
manifest/run/recovery hashes, the current pinned model/settings/canonical source inventory, the
immutable pre-change baseline tree and resolved executable/script bytes of all three adapters. The
helper recomputes qualification, including whole-workflow cost, marginal recall, holdout coverage,
repetitions, recovery and transport safety; report booleans cannot opt in. If qualified, duplicate
only error-handling and state/concurrency on the first full review and first re-review. Never
replace mandatory reviewers, independent confirmation or final-full.

### Durable review runtime recovery

`run-skill.py` persists a launch receipt before dispatch. Re-entering the same attempt is
idempotent: wait/reconcile/accept the existing process and return its actual non-empty R1; never
start a duplicate coder. The runtime state and durable receipts remain review-local, separate from
the ledger contents and workflow state.

- `review_runtime.py status --state PATH [--attempt-id ID]` inspects the attempt.
- `reconcile` and `resume` require the attempt ID and expected epoch and only reconcile an existing
  child; they do not launch or replay.
- `accept` revalidates the receipt and fresh gate even for an already accepted result; successful
  whole reviews require current final-full certification, and checkpoints require their durable
  nonfinal receipt. A syntactically valid R1 is insufficient.
- `recover-worktree --worktree PATH` discovers/reconciles one outstanding attempt only; it never
  relaunches or replays it.
- A wait timeout is not cancellation: the child continues. Retry/wait only on the same attempt.
  Cancel only after explicit authorization and only the identity-checked owned process group.
- A durable worktree ownership record fences orphaned writer groups even if their worker is
  SIGKILLed and its flock disappears. A new ledger cannot write until that group is provably gone.
  Authorized cancellation may retire a never-started or provably dead attempt without signalling;
  live ambiguous or unrelated processes remain protected.
- Malformed or empty R1, stale input fingerprint, fenced epoch, or ambiguous writer state blocks
  completion. Never infer success from process exit or boolean alone.
- Before a new launch or resumed authorization, the **PO-agent** runs its existing kill-switch,
  approval and budget gates and records the returned work in its existing budget flow. Build
  skills/runtime never invoke the PO-only state-writing kill-switch or create a second budget
  tracker. A rejected authorization records a blocked review reason and cancels only a proven owned
  writer; it never starts another attempt or raises a repair cap.
- Adopt an existing attempt with its original ID, launch fingerprint, invocation and context. The
  runtime recomputes the new live fingerprint separately; do not replace the original launch
  identity after legitimate repair edits. Ambiguous ownership requires explicit resolution.

### Coverage is a build-verify gate only

Implementation skills never measure or acknowledge coverage (#290): `build-implement-tdd` and
`build-implement-goal` forward the recorded baseline, the changed-file set, and any `design.md`
threshold (as `COVERAGE_HINT`) to `build-verify`. Gate 5 reports coverage from the data Gates 3/4
collected — it never re-runs the suites when gate-scout finds the split coverage commands — and
enforces `HALT-002` on `threshold_met:false` only when the integration lane ran locally, so the data
covers every lane. When CI owns the integration lane, the local unit-lane figure is advisory: a CI
coverage gate (repaired by `build-fix-ci`) owns the threshold when one exists. Below the threshold,
either owner adds edge-case tests for the lowest-covered files of its complete data, as
`shared/coverage-raise-guide.md` specifies. With no implementation-time acknowledgement in either
mode, autonomous mode has nothing to bypass and no `coverage-floor` bypass event exists.

## Cross-skill propagation

When an autonomous-mode skill auto-invokes the next skill in the pipeline, the canonical bash-level
autonomous-mode signal is **`$AGENT_ID`** — the PO-agent exports it once at session start and it
crosses every subprocess boundary the dispatch chain creates. Each skill's Step 1a falsy-check reads
it via the documented enum (Trigger #3 in § _Activation triggers_).

**Skills MUST NOT forward `--autonomous` on cross-skill dispatch.** Earlier drafts required explicit
forwarding "for symmetry"; in practice that produced redundant plumbing and silent fallback when a
forwarding site was missed. With `$AGENT_ID` propagating implicitly, the explicit flag adds nothing
— and a `--autonomous` argument on the CLI of an internally-dispatched skill is a contract smell (it
duplicates state the env already carries).

The CLI flag stays in place for **developer-driven** invocations: a human at the prompt can still
run `/makato-build:build-refine GAP-005 --autonomous` to opt into autonomous mode without setting
`$AGENT_ID`. The skill MUST continue to recognise the flag at that boundary. The rule only applies
to skill-initiated dispatches.

**Context bundle fields are different from the CLI flag.** `WORKTREE_PATH` and `PRIOR_LESSONS`
(etc.) MUST still be forwarded explicitly in the downstream context bundle — they carry state the
env cannot, and the falsy-check in each downstream skill HALTs on a missing required field. See §
_WORKTREE_PATH — workspace-isolation contract_ for the rationale.

## WORKTREE_PATH — workspace-isolation contract (GAP-017 / #46, follow-up #85)

Every autonomous-mode dispatch from the PO-agent carries a `WORKTREE_PATH` field in the dispatch
context bundle. This is the absolute filesystem path to the per-run git worktree the PO-agent owns
(see `plugins/makato-orchestrate/agents/po-agent.md` § _Worktree Lifecycle_ § _Inheritance_).
Sub-agents MUST `cd "$WORKTREE_PATH"` (or pass `-C "$WORKTREE_PATH"` to git) before any file edit,
`git`, test, or build command, so the work lands in the worktree's branch and never on the main
checkout.

**Contract:**

- `WORKTREE_PATH` is **mandatory** in every `--autonomous` invocation initiated by the PO-agent. If
  autonomous mode is active and `WORKTREE_PATH` is empty, the skill MUST HALT with R1
  `status: "failure"` and `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]` —
  silently falling back to the main checkout defeats Layer 1 workspace isolation.
- Interactive `build-start` and `build-refine` are worktree-producing entry points. When
  `WORKTREE_PATH` is unset they MUST create or resume one with
  `"$MAKATO_BUILD_ROOT/shared/interactive-worktree.sh"`; they MUST NOT use the main checkout as the
  implementation checkout.
- Other non-autonomous skills consume the path created by those entry points. When invoked
  standalone, their existing interactive fallback to `git rev-parse --show-toplevel` remains
  permitted unless that skill's own contract says otherwise.
- Skills that auto-dispatch other skills MUST forward `WORKTREE_PATH` in the downstream context
  bundle. Implicit env propagation is not relied on for context-bundle fields — they stay explicit
  in every hand-off. (The `--autonomous` CLI flag itself is NOT forwarded; `$AGENT_ID` propagation
  in the env handles activation. See § _Cross-skill propagation_.)
- Skills that dispatch agents (e.g. `build-implement-tdd` → `coder`) MUST inject `WORKTREE_PATH`
  into the agent's input bundle. The agent then `cd`s into that path before its inner cycle.

**Autonomous-mode detection in the falsy-check:** the canonical signal is the same as elsewhere in
this doc — `$AGENT_ID` exported in the env (set by makato agent dispatch infrastructure) OR the
caller's CLI carries `--autonomous` OR the context bundle has a `task_id` field. There is no
separately-set `$AUTONOMOUS` env var; the snippet below tests `$AGENT_ID` only because it is the
single signal the bash level can observe (CLI flags are arguments the skill has already parsed;
bundle fields live in the prompt). Earlier drafts of this section referenced `${AUTONOMOUS:-false}`
— that branch never fires in practice; do not rely on it in new code.

**Falsy-check pattern:**

```bash
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  # Autonomous mode without WORKTREE_PATH is a contract violation — HALT.
  # Interactive build-start/build-refine invoke interactive-worktree.sh here.
  if [[ -n "${AGENT_ID:-}" ]]; then
    # Emit R1 failure with MISSING_INPUT and stop.
    exit 1
  fi
  # Other standalone interactive skills may retain their legacy fallback.
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
cd "$WORKTREE_PATH"
```

The skill-level guard is the more important enforcement point: a skill running in `--autonomous`
mode (from CLI flag or `task_id` bundle) MUST treat empty `WORKTREE_PATH` as `MISSING_INPUT`
regardless of whether `$AGENT_ID` was exported. The bash snippet covers the agent-dispatched case;
the SKILL.md prose covers the full `--autonomous` activation set.

**Why `git -C` over `cd`:** for one-shot git invocations, `git -C "$WORKTREE_PATH" <cmd>` is
preferred — it does not mutate the surrounding shell's CWD and avoids leaking the worktree path into
pwd-relative downstream commands. For test runners and longer subprocess sequences (pytest, npm,
build commands that read relative config), `cd "$WORKTREE_PATH"` once at skill entry is fine.

**Concurrency rationale:** two concurrent PO-agent runs each get their own worktree (different
branches, different HEADs). Without `WORKTREE_PATH` propagation both runs would serialise on the
main checkout's HEAD — a silent race that defeats the per-run isolation guarantee.

### Two roots, one contract — `WORKTREE_PATH` vs `REPO_ROOT`

Spec files under `specs/<key>-*/` are gitignored, so spec/audit artifacts use
`MAKATO_TARGET_REPO_ROOT` when set and the common-dir main checkout otherwise.

| Artefact                                                                 | Lives in                                                                                                  | Why                                                                                                                                                     |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source-tree edits, `git commit`, `git push`, test runs                   | `WORKTREE_PATH`                                                                                           | The branch HEAD only moves in the worktree; commits to the main checkout would target the wrong branch.                                                 |
| `specs/<key>-*/plan.md`, `stories.json`, `prd.md`, `created-issues.json` | Selected target checkout (`REPO_ROOT`) when `MAKATO_TARGET_REPO_ROOT` is set; otherwise the main checkout | The target override keeps state with the root scanned by the loop; the common-dir fallback shares gitignored specs across per-run worktrees.            |
| `specs/<key>-*/build.jsonl`, `orchestrate.jsonl`                         | Selected target checkout (`REPO_ROOT`) when `MAKATO_TARGET_REPO_ROOT` is set; otherwise the main checkout | The audit trail is single-writer across all worktrees of a run; `build-log.sh` uses the target override first, then `git rev-parse --git-common-dir`.   |
| `.github/PULL_REQUEST_TEMPLATE.md`                                       | Whichever checkout has it tracked — both, in this repo's setup                                            | Tracked file; `git -C "$WORKTREE_PATH"` reads it fine. The point is that _reading the spec artefact next to it (`plan.md`)_ still requires `REPO_ROOT`. |

```bash
# Worktree path — workspace isolation (file edits, git ops, test runs).
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  if [[ -n "${AGENT_ID:-}" ]]; then exit 1; fi
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
# Repo root — spec/audit-trail reads (plan.md, stories.json, build.jsonl).
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)}"
```

`build-log.sh` uses the target override or common-dir fallback; direct spec readers MUST use
`$REPO_ROOT/specs/<key>-*/...`, not `$WORKTREE_PATH/specs/...`.

**Skills that consume this contract:**

The autonomous-mode pipeline has two cohorts of consumers. Both honour the falsy-check / fallback.
The second cohort also reads spec artefacts and therefore resolves `REPO_ROOT` separately.

- `build-implement-tdd` — Step 6 dispatches `coder` per task; forwards `WORKTREE_PATH` in the coder
  bundle. Plan reads via `REPO_ROOT`.
- `build-implement-goal` — same pattern; goal-mode build steps `cd` before file edits and
  verification. Plan reads via `REPO_ROOT`.
- `build-verify` — gate runner; lint/test/coverage commands run from `WORKTREE_PATH`.
- `build-push-to-git` — `git commit` / `git push` operate against the worktree's branch. Plan reads
  via `REPO_ROOT`. Forwards `WORKTREE_PATH` to `build-create-pr` when auto-dispatching at Step 8.
- `build-create-pr` — `gh pr create` resolves the right branch from the worktree's `.git`. Spec
  artefact reads (`stories.json`, `prd.md`, `plan.md`, `.github/PULL_REQUEST_TEMPLATE.md`,
  `created-issues.json`) via `REPO_ROOT`.
- `build-refine` — produces `plan.md`; reads spec folder via `REPO_ROOT`. Honours the falsy-check
  when dispatched by the PO-agent on a re-plan cycle (Step 4f of `po-agent`).
- `build-simplify` — runs `git diff "$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")...HEAD"`
  (resolves `origin/<default-branch>` to avoid stale-main pull-in — #98) and applies fixes in
  `WORKTREE_PATH`. Plan reads via `REPO_ROOT`.
- `build-address-pr-comments` — `gh pr` calls + per-comment fix-apply operate from `WORKTREE_PATH`.
  Spec artefact reads via `REPO_ROOT`.
- `coder` agent — receives `WORKTREE_PATH` in its input bundle and `cd`s before working. In TDD mode
  it executes RED/GREEN only: write or extend the task's tests, then run only the test files this
  coder added or changed (plus `TRACER_TEST_NAME` when set) with one targeted command built from
  `GATE_COMMANDS`, preserving any runner prefix. Confirm the RED failure is for the intended reason;
  in GREEN, add minimum production code and rerun the same command; all targeted tests must pass. It
  does not run INTEGRATE, full-suite VERIFY, coverage, or repo-wide lint; `build-verify` owns
  whole-change verification. In autonomous mode, the agent MUST HALT R1 `failure` with
  `MISSING_INPUT: WORKTREE_PATH required in autonomous mode` when the field is empty — silently
  falling back to the main checkout defeats Layer 1 isolation. Detection: any of `$AGENT_ID`, an
  `AUTONOMOUS_MODE` field in the dispatch bundle, or the absence of an interactive prompt context.

The PO-agent's Step 2b creates the worktree and Step 6 #6 cleans it up; see
`plugins/makato-orchestrate/agents/po-agent.md` § _Worktree Lifecycle_ for the full lifecycle.

## Shared reply templates — `templates/pr-comment-replies.md`

`build-address-pr-comments` renders every PR reply from the shared template file at
`plugins/makato-build/templates/pr-comment-replies.md`. The template file defines one section per
classification tier plus three autonomous-only sections (DEFERRED, OUT-OF-SCOPE autonomous,
STRUCTURAL). Placeholders are filled at render time; hard-coded prose in the skill body is a
contract violation.

This is the first cross-skill template directory in the plugin. The exception to AGENTS.md § _Skill
Authoring_ ("Self-contained: all references/templates inside the skill directory") is intentional
and pinned by AC5 of GAP-011 (#36) — putting reply text under a plugin-level `templates/` dir keeps
the reply vocabulary in one place when future skills (e.g. a follow-up `build-resolve-review`) need
to mirror the same marker conventions.

## Logging contract

Every gate that the skill bypasses in autonomous mode MUST emit a `build.jsonl` entry by invoking
`"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"` (which assembles the canonical 5-field shape and
delegates the actual file append to `"$MAKATO_BUILD_ROOT/shared/build-log.sh"`). The helper is the
single source of truth for the schema; inline JSON literals are a contract violation.

```bash
"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" <skill> <key> <gate> <default_taken> <trigger> [extra-json-object]
```

Run `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" --help` for the full signature.

The emitted entry has this shape (which audit consumers should grep for):

```json
{
  "ts": "<ISO-8601-ms>",
  "skill": "<skill-name>",
  "story": "<key>",
  "step": "decision",
  "status": "decision",
  "data": {
    "event": "autonomous_bypass",
    "gate": "<short-name-from-table-above>",
    "bypassed": true,
    "default_taken": "<value-from-table>",
    "trigger": "agent_id" | "cli_flag" | "task_id_bundle"
  }
}
```

Notes on the shape:

- `step: "decision"` and `status: "decision"` are the existing convention for non-happy-path agent
  decisions (see plugin AGENTS.md Design Principle 4). The `data.event: "autonomous_bypass"`
  discriminator is what makes these entries machine-searchable.
- `gate` matches the short name from the per-gate table (e.g. `"plan-review"`, `"commit-grouping"`,
  `"push-confirm"`, `"pr-draft-approval"`, `"comment-classification"`).
- `default_taken` is the actual value applied — e.g. `"approve"`, `"plan-as-drafted"`, `"push"`,
  `"open-pr-as-drafted"`, `"auto-apply"`, `"halt"`.
- `trigger` records which activation source fired. Useful when a session was driven by a
  misconfigured CI step (`cli_flag` when expected was `agent_id`).

### Skill-specific context (`extra`)

When a bypassed gate carries skill-specific context that a downstream auditor needs to interpret
correctly (counts, comment IDs, follow-up issue URLs, file-set diffs), pass an `extra` JSON object
as the 6th positional argument to `log-bypass.sh`. It is merged into `data` alongside the canonical
5 fields.

```bash
"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-address-pr-comments "$KEY" out-of-scope-carry-over open-followup-issue cli_flag \
  '{"comment_id":"42","follow_up_issue":"https://github.com/o/r/issues/99"}'
```

Contract:

- `extra` MUST be a JSON object (not array, not string, not number). The helper rejects malformed
  values with exit 3.
- `extra` keys are merged into `data`; canonical keys (`event`, `gate`, `bypassed`, `default_taken`,
  `trigger`) cannot be overridden — they always win.
- `extra` is purely additive — there is no documented enum of valid keys. A skill is free to add
  fields it considers useful for its own audit. The convention is to keep keys lowercase-snake-case
  and to surface concrete identifiers (IDs, URLs, file paths) rather than free-form prose.

A session that visited N autonomous gates MUST produce N `autonomous_bypass` entries. A future
reader running `jq 'select(.data.event=="autonomous_bypass")' build.jsonl` reconstructs every
decision the pipeline took without a human.

### Batched logging — `build-log.sh --batch` (#118)

A skill step that emits multiple log rows (e.g. session-start + intermediate decisions +
session-end) MAY flush them in a single subprocess invocation rather than forking once per row. Each
`build-log.sh` call costs a `bash` startup + `git rev-parse --git-common-dir` + `find specs/`
resolution; an autonomous run across 12 skills with 3–5 rows per step is 50–150 fork-execs of pure
overhead.

```bash
{
  "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<KEY>" '{"ts":"…","step":"a","status":"ok"}'
  "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<KEY>" '{"ts":"…","step":"b","status":"ok"}'
  "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<KEY>" '{"ts":"…","step":"c","status":"ok"}'
}
```

becomes

```bash
cat <<NDJSON | "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<KEY>" --batch
{"ts":"…","step":"a","status":"ok"}
{"ts":"…","step":"b","status":"ok"}
{"ts":"…","step":"c","status":"ok"}
NDJSON
```

Contract:

- `--batch` reads newline-delimited JSON from stdin and appends each parsed entry to `build.jsonl`.
- Blank lines are skipped. Lines that don't parse as JSON are silently dropped — the audit-log
  "never crashes" invariant is preserved. Audit consumers do not see corrupted rows.
- Batch output is **byte-for-byte identical** to per-row single-entry output for the same set of
  entries (verified by `shared/build-log-batch-smoke-tests.sh` T3).
- The single-entry form (legacy: `build-log.sh <key> '<json>'`) is unchanged — skills migrate
  opportunistically; no flag day.

Recommended migration pattern: accumulate log rows in a bash array (or heredoc) for the duration of
a single step (e.g. Step 3 baseline capture, Step 6 coder dispatch, Step 7 verify gates), then flush
once at the step boundary. Cross-step batching is NOT recommended — a long-running step that fails
before the flush would lose its audit trail. Per-step batching is the sweet spot.

## Reference R1 return envelope

In autonomous mode every modified skill returns R1-shaped output (GAP-002 / #24). The shape is
documented in `plugins/makato-build/agents/RETURN-CONTRACT.md` and applies verbatim to skills as
well as agents. The minimum fields a build-\* skill emits at session end:

```json
{
  "schema": "r1",
  "agent": "<skill-name>",
  "status": "success" | "partial" | "failure",
  "summary": "<one-line synthesis>",
  "files_changed": [...],
  "tests_written": [...],
  "errors": [...],
  "tool_calls_used": 0,
  "data": { /* skill-specific — see each skill's Autonomous Execution section */ }
}
```

In interactive mode this envelope is OPTIONAL — interactive output is for a human and prose
suffices. In autonomous mode it is MANDATORY and must be the final `json`-fenced block in the
skill's output.

## Skills with no separate approval gate

These pipeline skills have no approval prompt to bypass; their normal execution and autonomous
repair behavior still apply:

- `build-sensors` — already halts on non-zero pre-commit exit; no human gate to bypass. Its
  `max_loops` is the single sensor repair budget shared with every sensor-fixer dispatch;
  sensor-fixer escalates via tier-up to opus; no `AskUserQuestion` site.
- `build-verify` — owns whole-change gate verification and sends code-level failures through the
  bounded coder verify-repair loop (`MAKATO_MAX_REPAIR_ROUNDS`, default `3`). It fails closed with
  HALT-002 on exhaustion. Gate 0 uses CI's pre-commit scope; Gates 1/2 reuse Gate 0's hook results.
  Integration tests run locally only when gate-scout finds no CI integration lane, and the coverage
  threshold blocks locally only when they did; otherwise the PR's CI checks own them.
- `build-implement-tdd` / `build-implement-goal` — their implementation loops already run
  autonomously; TDD coders and goal tasks run targeted tests only and reuse the branch's recorded
  baseline. `build-verify` owns whole-change verification.
- `build-review` is mandatory before verify in the PO-agent pipeline. Its persisted gate owns repair
  caps and convergence in both modes; exhaustion fails closed to HALT-003 and the loop cannot be
  skipped as an approval bypass.
- `build-resolve-finding` — driven by sensor-fixer with deterministic branches already.
- `build-start` — the entry skill; it must remain interactive because it captures the implementation
  mode and confirms branch state. The PO-agent does not invoke `build-start` — it invokes the
  post-start skills directly with workflow-state already populated.

> `build-simplify` was previously listed here on the grounds that "its interactivity is the work
> itself." That reasoning pre-dated `finding-routes.json` routing sensor findings into the skill via
> `sensor-fixer` → `build-resolve-finding` (#59 / #60). Once the skill is dispatched headlessly the
> per-finding approval prompt becomes a real gate, and v1.3+ honors autonomous mode per the table
> above.

Shaping skills in `makato-plan/` are also out of scope: they require human judgment by design
(brainstorming, PRD authoring, architecture decisions, story slicing). The PO-agent operates on
stories that have already been shaped.

## Reference implementation

`plugins/makato-plan/skills/to-issues/SKILL.md` (v3.4.0) is the canonical reference for the bypass
pattern. When in doubt about phrasing, mirror what `to-issues` does:

- Mode-detection block lives right after the first orientation step (Step 0 / Step 1).
- Bypass logic is described inline at each gate as a conditional ("In autonomous mode, …"), never as
  a separate "if autonomous" branch at the top of the skill.
- The skill ends with a § _Autonomous Execution_ section listing activation triggers, behavior, R1
  return format, and HALT codes.

## Backward compatibility

This convention is purely additive. Skills retain every existing `AskUserQuestion` call; they only
learn to skip it when autonomous mode is active. A skill that has not yet been updated to this
convention continues to run interactively under all activation triggers — autonomous activation is
per-skill, not a global mode. The PO-agent (GAP-006) only dispatches updated skills.

## Versioning

This document is referenced (not embedded) by each updated skill. When the convention changes:

- Patch / minor edits (clarifications, new gates added, log-field additions): bump each consuming
  skill's `version` minor when its behavior changes; this doc itself carries no version field.
- Breaking change (activation trigger removed, log shape changed): rename the file to
  `AUTONOMOUS-MODE-v2.md` and migrate skills one at a time. The PO-agent reads the version from the
  skill's frontmatter, not from this file.
