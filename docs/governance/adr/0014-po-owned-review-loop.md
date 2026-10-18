# ADR-0014: PO-Agent Owns the Review Loop Decision

## Status

Accepted

## Date

2026-10-18

## Context

The autonomous pipeline needs an adversarial review between implementation and verification, with
a bounded number of repair rounds. Before this decision:

- The PO-agent's Step 6 went from implementation straight to `build-verify`; `build-review` was
  never dispatched in autonomous runs.
- `build-review`, when run, looped internally ("fix → re-review until clean") with no round cap.
  Any cap would have lived only in prompt text inside one child session.
- `diff-reviewer` returned findings as strings in `errors[]`, so a finding had no stable identity
  across passes. "Two fixed, two new" looked the same as "no progress", and a finding the repair
  step could not fix consumed every remaining round.
- A context handoff or crash mid-review lost all loop state.

The termination decision is safety-relevant (it bounds cost and decides whether unreviewed code can
reach verify and push), so it should be deterministic, auditable and owned by the outer loop that
already owns every other ceiling (kill-switch, budget, re-plan, merge-conflict cycles).

## Decision

1. **The PO-agent decides when review is done.** PO-agent Step 6 #0 dispatches
   `build-review --round <N>` once per round. After each round it calls
   `makato-build/shared/review_gate.py reconcile`, which returns `SUCCESS`, `CONTINUE` or `STOP`.
   The PO-agent executes that decision verbatim.
2. **`build-review --round` is single-round.** It repairs only the findings the ledger selects,
   runs one independent `diff-reviewer` pass on the merge-base-to-working-tree diff, and returns.
   A precondition (`review_gate.py assert-round`) refuses any round the gate did not allow.
3. **A ledger, not memory, carries finding identity.** `specs/<key>-*/review-ledger.json` holds
   stable IDs (`file|symbol|category|rule`), attempts, status (`open`/`verified`/`reopened`) and
   per-round decisions. Only `review_gate.py` writes it, invoked only by the PO-agent.
4. **Rules, first match wins:** `INVALID_REVIEW` → `STALE_REVIEW` → `SUCCESS` → `MAX_ROUNDS`
   (`MAKATO_MAX_REPAIR_ROUNDS`, 3) → `NO_PROGRESS` (`MAKATO_MAX_STAGNANT_ROUNDS`, 2 rounds without
   a drop in the open CRITICAL×3 + MAJOR×1 score) → `NO_ACTIONABLE_FINDINGS`
   (`MAKATO_MAX_FINDING_ATTEMPTS`, 2) → `CONTINUE`. Limits are frozen at `init`.
5. **No new HALT code.** Every `STOP` is HALT-003 with `data.review_stop_reason`.

Existing names are kept: `coder`, `diff-reviewer`, `build-review`, R1, HALT-003, `build.jsonl`. The
default (no `--round`) `build-review` path is unchanged for interactive use and other callers.

## Consequences

**Positive**

- Termination no longer depends on an LLM counting correctly; it is unit-tested code.
- Kill-switch, budget recording and progress narration run between review rounds.
- Review is resumable (`resume_point: review-round:<N>`).
- Operators get a per-finding audit trail (ledger + `review-round-<N>.json`) on every HALT-003.

**Negative**

- One child session per round instead of one per review (up to 4 with the default limits).
- Finding identity ignores line numbers; two distinct defects in the same symbol, category and
  rule merge. `prior_id` from the reviewer and the `rule` slug mitigate this.
- The gate does not run the full test suite per round; `build-verify` still owns whole-change
  gates after `SUCCESS`.

## Alternatives considered

- **Keep the loop inside `build-review` with a prompt cap.** Rejected: the cap is not enforced and
  the outer loop cannot observe or resume rounds.
- **PO-agent dispatches `coder` and `diff-reviewer` directly.** Rejected: breaks the hard
  constraint that the PO-agent never dispatches `coder`, and bypasses the skill boundary.
- **Harness hook (`before_subagent_spawn`) to block extra rounds.** Rejected: ties enforcement to
  one harness; the `assert-round` precondition works on every harness.

## Revisit when

- The same gate should bound `build-verify`'s repair loop (HALT-002).
- `build-address-pr-comments` or CI-failure repair should re-enter review through `--round`.
