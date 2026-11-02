# Review Loop

Operational reference for `SKILL.md` Step 5. `review_loop.py` owns durable gate decisions and repair
history; `review_scope.py` owns immutable snapshots and repair deltas. This document does not
authorize bypassing a gate or replacing evidence with model-maintained counters.

## Durable state and fingerprint

Store the ledger in the worktree's private git directory, never in `workflow-state.json`:

```bash
LEDGER_DIR="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/makato-review-loop"
STATE="$LEDGER_DIR/<key>.json"
RUNTIME_STATE="$LEDGER_DIR/<key>/runtime.json"
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" init \
  --state "$STATE" --story "$KEY" --review-base "$REVIEW_BASE"
```

The runtime checkpoint is separate from the finding ledger. Use the canonical runtime helper and
`run-skill.py` wrapper described in `AUTONOMOUS-MODE.md`; never write orchestration state from a
reviewer or coder. An incompatible legacy ledger fails with an explicit migration requirement; do
not reset counters, history, or findings. Changed source, context, or contract fingerprints do not
reset repair history.

`init` persists validated soft/hard repair caps. Resumes retain them; omitted environment values
preserve them and later environment/CLI limits may only lower them. A changed fingerprint never
renews the budget or repair count. Raising a cap or importing an incompatible ledger requires
explicitly authorized evidence-preserving migration, not deletion/reinitialization.

Pin the complete non-empty authoritative AC ID set at initial dispatch, including a task checkpoint.
Later gates cannot replace/shrink that set, shrink context/contract coverage, or substitute the
evidence/contract root. New context files extend the manifest and invalidate stale evidence.

The run fingerprint includes the current worktree, fixed review base, evidence root, and the exact
context/contract paths supplied to the helper. Keep one reusable argument array for every gate and
fingerprint call:

```bash
CONTEXT_ARGS=(--context-path "$SPEC_REL/plan.md")
# Reuse the complete CONTRACT_ARGS array from SKILL.md Step 2.
# Its paths are relative to MAKATO_BUILD_ROOT, not the consuming repository.
GATE_ARGS=(--state "$STATE" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
  --evidence-root "$REPO_ROOT" --contract-root "$MAKATO_BUILD_ROOT"
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}")
```

Include every supplied context path and the complete canonical contract inventory in both calls. The
completion gate rejects even a non-empty but partial contract list. Compute and record the
fingerprint:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" fingerprint \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" --evidence-root "$REPO_ROOT" \
  --contract-root "$MAKATO_BUILD_ROOT" "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}"
```

Pass the emitted SHA-256 as `--fingerprint` to gate commands as an expected-value check, never as an
authority. The gate recomputes the live fingerprint from `GATE_ARGS`. On any mismatch or helper
error, stop non-successfully; do not trust stale citations, resume a stale child, or reset the
state.

## Persisted gate sequence

Before every reviewer/coder/manual-repair transition, follow the persisted `next_action`, `reason`,
`gate_id`, and current fingerprint. The persisted gate is the only transition authority; never
derive counters or convergence from model memory.

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event initial --fingerprint "$INPUT_FINGERPRINT" "${AC_GATE_ARGS[@]}"
```

After merging a complete diff-reviewer pass, persist its full R1 as evidence:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event review --fingerprint "$INPUT_FINGERPRINT" --evidence "$MERGED_R1" \
  "${AC_GATE_ARGS[@]}"
```

`AC_GATE_ARGS` supplies `--expected-ac-ids "$EXPECTED_AC_IDS"` for ordinary review, and the first
non-empty authoritative list is immutable for this run. Empty or unknown IDs are not a zero-AC
assertion; they block final completion. Omit `AC_GATE_ARGS` for the checkpoint event. The gate
persists a reason and history for every transition; a clean-looking R1 alone is never authority.

### Independent confirmation and repair authorization

Every currently raised blocking constituent in the latest ordinary pass's `constituent_ids` is
verified in one batched, read-only `diff-reviewer` confirmation dispatch against the same immutable
snapshot and fingerprint. Historical repaired constituents not re-raised wait for independent
`certify` closure; never relabel a real repaired bug as a false positive to advance confirmation.
Store one disposition per `finding_id` and `constituent_id`: `confirmed`, `rejected`, or
`uncertain`, with reachability, impact, introduction status, exact citations, and `repair_scope`
(`local`, `architectural`, `cross-boundary`, or `unknown`). Uncertain/missing evidence blocks.
Rejected constituents remain in the raw history and map to `false_positive`; no majority vote
suppresses findings. A local repair is authorized only if all currently raised blocking constituents
are independently confirmed `local`. Architectural, cross-boundary, or unknown scope requires a
short plan and independent `repair-plan` review; a second unsuccessful return of the same invariant
also requires redesign. Severity alone never selects planning.

After a complete confirmation batch, persist it with `gate --event confirm` and follow the returned
action. To reserve a bounded repair, call this **before** coder/manual edits, with no
caller-supplied round, blocker IDs, or evidence:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event repair-local --fingerprint "$INPUT_FINGERPRINT"
```

The returned `repair_attempt.round` and IDs authorize that one repair. Afterward record only IDs the
coder/manual repair actually claims fixed. For a coder, use its actual unique native dispatch
identity from R1 `data.coder_id`; never invent, rename, or reuse another agent's ID:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" repaired --state "$STATE" \
  --round "$REPAIR_ATTEMPT_ROUND" --ids "$CLAIMED_IDS" --coder-id "$CODER_ID"
```

The claim does not approve the repair; the gate requests a fresh review. For redesign, obtain a
no-edit plan and an independent `repair-plan` verdict, then persist the authorized transition before
implementation:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event redesign --fingerprint "$INPUT_FINGERPRINT"
```

When the gate requests closure, run a fresh final-full review on the current fingerprint and submit
exhaustive independent dispositions for each blocking constituent:

```json
{
  "reviewer_id": "<independent reviewer dispatch>",
  "independent": true,
  "dispositions": [
    {
      "finding_id": "F-001",
      "constituent_id": "F-001-C1",
      "disposition": "fixed",
      "evidence": "The reachable regression no longer occurs and its test passes",
      "citations": [{ "file": "src/example.py", "line": 42 }]
    }
  ]
}
```

Use only `fixed`, `false_positive`, or `uncertain`; every constituent needs non-empty evidence and
citations. Uncertain or omitted closure blocks. Persist with `gate --event certify`; use the
reviewer identity and evidence from the independent current-tree check.

## Immutable scope, lens sampling, and no-change completion

Normalize mechanical edits before freezing a review tree. Materialize the immutable snapshot with
`review_scope.py`; every reviewer, independent confirmation, and any independent smoke check that
runs in parallel reads the exact same snapshot. No writer may edit it. Do not start a repair while
read-only reviewers are still reading the live tree; either wait for their batch or isolate their
snapshot and writer ownership. Final-full always reviews the complete current branch and every AC.
Delta, background, or checkpoint evidence cannot replace it.

Use
`review_loop.py lenses --worktree PATH --review-base REF --mode auto|on|off --profile standard|deep --pass-kind initial|first-rereview|later`
for pass sizing. Risk-sample duplication is OFF by default. A released `review-eval-v2` artifact may
enable two samples only for error-handling and state/concurrency on the initial full pass and first
re-review. Pass `--qualification PATH --config-fingerprint SHA256 --model PINNED --settings JSON`
with `--profile deep`. The helper rederives current source/model/settings identity and verifies the
manifest/run/recovery artifact hashes and recomputed quality/performance/holdout/recovery gates;
report booleans or a claimed fingerprint are not sufficient. The experiment must show marginal
confirmed detections beyond baseline and lower whole-workflow time/tokens. Configuration identity is
distinct from the live source/context `input_fingerprint`. `--mode off` never duplicates; sampling
never replaces confirmation or final-full.

After the fresh successful final-full pass, run the mechanical check again and compute before/after
snapshots and fingerprints. Completion evidence is exactly the live input fingerprint plus a
no-change mechanical record:

```json
{
  "input_fingerprint": "<current SHA-256>",
  "mechanical": {
    "no_change": true,
    "evidence": "before_snapshot=<id>; after_snapshot=<id>; mechanical checks passed",
    "before_fingerprint": "<current SHA-256>",
    "after_fingerprint": "<current SHA-256>"
  }
}
```

Only identical snapshot IDs and fingerprints establish `no_change:true`. Then call
`gate --event complete` with that evidence and `AC_GATE_ARGS`. The gate reads the final-full pass,
all AC verdicts/citations, and constituent closures from the ledger. Missing/unknown evidence never
completes.

## Task-boundary checkpoint

A checkpoint is not final certification. The first checkpoint reviews the whole current
completed-task diff against the merge-base tree; later checkpoints review the delta from the last
accepted checkpoint snapshot plus affected callers and all applicable constraints/security rules.
Future ACs stay provisional. Do not author final AC verdicts, mark future ACs passed, fabricate an
empty delta, or write a final `ac-verification` entry.

Once the latest fresh scoped pass has no unresolved blockers, submit evidence with non-empty
summary/citations, current fingerprint, pass ID, task IDs, `scope:"delta"`,
`checkpoint_verified:true`, `final_review:false`, reviewer identity/independence, and exhaustive
constituent dispositions. Do not supply `snapshot`; the gate injects it into the durable receipt.
Call `gate --event checkpoint` without expected AC IDs. It returns `next_action:"review"`, never
`complete`, and a receipt with the accepted snapshot. Copy that receipt verbatim to R1
`data.checkpoint_receipt` and set `data.final_review:false`.

The scheduler must validate the durable receipt against the ledger and live fingerprint before
accepting IDs:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" checkpoint-receipt --state "$STATE" \
  --task-ids "$CHECKPOINT_TASK_IDS" --fingerprint "$INPUT_FINGERPRINT" \
  --pass-id "$PASS_ID" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
```

R1 success alone is insufficient. A later normal build-review still performs final-full, all AC
judgments, mechanical no-change validation, and the `complete` gate.
