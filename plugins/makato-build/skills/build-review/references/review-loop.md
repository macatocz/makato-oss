# Review Loop

Operational reference for `SKILL.md` Step 5. `review_loop.py` owns durable gate decisions and repair
history; `review_scope.py` owns immutable snapshots and repair deltas. This document does not
authorize bypassing a gate or replacing evidence with model-maintained counters.

## Durable state and fingerprint

Before these commands, use `SKILL.md` Step 1 to select, canonicalize, and export the exact
`MAKATO_BUILD_ROOT` and `MAKATO_ORCHESTRATE_ROOT`; manual/installed binding requires both explicitly.
An exported `MAKATO_ORCHESTRATE_SHARED` must physically equal the selected orchestrate `shared`
directory. Empty exports are unset. No runtime-context/cache/current-directory/consumer discovery
may fill a durable binding. Only the launcher may use the fully proved source-checkout fallback
specified in `AUTONOMOUS-MODE.md`; `review_loop.py` never rediscovers roots.

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
reviewer or coder. Contract version 3 uses `review-input-fingerprint-v2`, ledger version 3,
runtime version 2 (`review-runtime.v2`), and `review-eval-configuration-v2`. Old/incompatible
schemas or physical binding mismatches fail closed, including directory replacement or
reboot/remount identity changes. Never automatically migrate, delete/reinitialize, or reset
counters/history/findings. The owner must preserve/export history and consumed repair-round/cap
budget before an explicitly authorized new ledger.

The ledger freezes `contract_root`, `orchestrate_root`, and
`root_bindings:{build:{path,dev,ino},orchestrate:{path,dev,ino}}` atomically at first durable bind;
every runtime attempt stores the same triple. These physical invocation identities are immutable.
Every state-using command revalidates the executing build installation and both live bindings.
All three fields are null in an unbound ledger. Generic no-contract state operations, including
gate/merge, repaired, background, operational-log, checkpoint publication and receipt validation,
remain legal while unbound, but authorize neither durable execution nor final certification.
First actual durable gate/merge requires explicit `--contract-root` and `--orchestrate-root` and
the full canonical closure; no closure check applies when `contract_paths` is absent and no
binding exists.

Physical roots/devices/inodes are not hashed into review or qualification content identity.
Canonical inventories include path, kind, mode, and SHA-256 with stable-read/root-identity checks.
Explicitly selecting and rehashing relocated roots with identical bytes and kind/mode can reproduce
content identity, but does not authorize rebinding an existing ledger. Permission changes
invalidate configuration identity; metadata cannot assert source equivalence.

`init` persists validated soft/hard repair caps. Resumes retain them; omitted environment values
preserve them and later environment/CLI limits may only lower them. A changed fingerprint never
renews the budget or repair count. Raising a cap or importing an incompatible ledger requires
explicitly authorized evidence-preserving migration, not deletion/reinitialization.

Pin the complete non-empty authoritative AC ID set at initial dispatch, including a task checkpoint.
Later gates cannot replace/shrink that set, shrink context/contract coverage, or substitute the
evidence/build/orchestrate roots. New context files extend the manifest and invalidate stale evidence.

The run fingerprint covers current worktree/base bytes and the exact context/contract files
selected at the bound roots, not physical root locations. Keep one reusable argument array for every
initial/delta/final/delivery fingerprint and gate; merge receives the same roots and path arrays:

```bash
CONTEXT_ARGS=(--context-path "$SPEC_REL/plan.md")
# Reuse CONTRACT_ARGS populated once from review_loop.py contract-paths in SKILL.md Step 2.
# Plain paths select MAKATO_BUILD_ROOT; orchestrate:<rel> selects MAKATO_ORCHESTRATE_ROOT.
GATE_ARGS=(--state "$STATE" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
  --evidence-root "$REPO_ROOT" --contract-root "$MAKATO_BUILD_ROOT"
  --orchestrate-root "$MAKATO_ORCHESTRATE_ROOT"
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}")
```

Include every supplied context path and the complete canonical contract inventory in both calls.
`contract-paths` prints exactly the canonical JSON array in tuple order, without extra keys;
never copy its list by hand. Plain build-relative POSIX paths and exactly `orchestrate:<rel>` are
the only contract argument forms. Reject other namespaces/colons, empty components, absolute
paths, `.`/`..`, backslashes, non-regular files, and below-root symlinks; canonicalize symlinked
ancestors. Required entries use canonical shared paths, never the in-tree build-review/shared alias.
Manifest labels are `contract:<rel>` for build inputs and `orchestrate:<rel>` for orchestrate;
the canonical shared `contract_input`/`contract_inventory` dispatch is used for hashing and
physical alias/source-map protection across both roots, never a second handwritten closure.
Extra paths may extend, not replace, the closure. The launcher, runtime, first durable bind and
completion gate reject partial lists; failure is not permission to omit an input. Compute the
fingerprint:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" fingerprint \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" --evidence-root "$REPO_ROOT" \
  --contract-root "$MAKATO_BUILD_ROOT" --orchestrate-root "$MAKATO_ORCHESTRATE_ROOT" \
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}"
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

Merge the complete reviewer batch with the same frozen roots and path coverage before persisting
its full R1 as gate evidence. `PASS_SCOPE` is `full`, `delta`, `final-full`, or `background-full`;
use the ledger-authorized pass/round, immutable snapshot, and actual R1 file array:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" merge \
  --state "$STATE" --pass "$PASS_NUMBER" --scope "$PASS_SCOPE" --after-round "$AFTER_ROUND" \
  --snapshot "$PASS_SNAPSHOT" --fingerprint "$INPUT_FINGERPRINT" \
  --evidence-root "$REPO_ROOT" --contract-root "$MAKATO_BUILD_ROOT" \
  --orchestrate-root "$MAKATO_ORCHESTRATE_ROOT" \
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}" "${AC_GATE_ARGS[@]}" \
  "${R1_FILES[@]}" >"$MERGED_R1"
```

Then record the review transition:

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

Every snapshot producer captures the complete raw tracked/untracked working tree, including
Git-clean committed files, staged deletions, executable modes and symlinks. Materialization uses
a no-checkout linked worktree and writes raw blobs directly: clean/smudge, text/eol and encoding
transforms must not run again. The materializer verifies the complete byte/kind/mode inventory
before returning success and leaves the source index untouched. Unsupported tree entries fail
closed rather than producing a partial consumer. Git-clean raw baseline differences are included
in checkpoint scope and must match the live source; stale snapshots are rejected.

Every retained final-full reviewer independently cites the complete authoritative changed-file set
with sufficient `files_reviewed`: either one unscoped reviewer or all five lenses, including each
additional sample. Merged maximum counts and citation unions are summaries, not coverage authority.
The same checks protect checkpoint and final gates, publication, receipt verification, first and
repeated runtime acceptance, and completed-result reuse. Each boundary revalidates the full retained
R1 contract, original run/pass/repair-round/input binding, raw finding occurrences, and derived
status/coverage/lens/AC summaries. Missing, malformed or inconsistent raw evidence requires recovery
or fresh review; neither a cached pass nor an earlier successful receipt can establish completion.

For pass sizing, use the live validated ledger bindings:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" lenses \
  --state "$STATE" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" \
  --contract-root "$MAKATO_BUILD_ROOT" --orchestrate-root "$MAKATO_ORCHESTRATE_ROOT" \
  --mode "$MAKATO_REVIEW_LENSES" --profile standard --pass-kind "$RISK_SAMPLE_PHASE"
```

Risk-sample duplication is OFF by default. Absent/unbound/invalid state or unresolved bindings keeps
it OFF with `sampling_warning`; explicit root flags must match the validated bindings. A released
`review-eval-v2` artifact may enable two samples only for error-handling and state/concurrency on the
initial full pass and first re-review. Pass
`--qualification PATH --config-fingerprint SHA256 --model PINNED --settings JSON` with
`--profile deep`. The helper rederives current model/settings and canonical kind/mode/byte inventory
at both exact bound roots and verifies the manifest/run/recovery artifact hashes and recomputed
quality/performance/holdout/recovery gates;
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

## Certificate-bound audit publication

The successful `complete` or `checkpoint` gate preserves an immutable reviewed-input certificate:
its full fingerprint manifest, pass, snapshot, closures, and any mechanical before/after proof.
It also binds this story's canonical audit identity and existing byte prefix. Do not append raw
`ac-verification` or terminal success session rows after that gate. Publish through the ledger:

```bash
AUDIT_PUBLICATION="$(python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" publish-audit \
  --state "$STATE" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE")" || exit 1
```

The Python API is `review_loop.publish_audit(state_path, worktree, review_base)`. Neither interface
accepts a caller path, fingerprint, arbitrary rows, receipt, or success flag. It requires the
persisted successful source certificate. Final publication generates the independent final-full
`ac_verdicts[]` verbatim plus a minimal ledger-derived session row; checkpoint publication generates
only the session row, never AC verdicts. Rows retain story, run, and pass identity and the public
audit schema/privacy constraints.

Canonical resolution uses `spec_folder.resolve_spec_folder` beneath the bound `evidence_root`'s
`specs`, falling back to the worktree root only when no evidence root is bound. Never redirect
publication to another worktree copy. Reject symlink components, containment violations, changed
physical path/inode/mode, and physical aliases of any explicit context or contract input, including
aliases across roots. The canonical audit must have exactly one hardlink, checked at capture,
open, and immediately before append (including pending-intent replay); rejection must leave both
canonical and collateral bytes untouched. Do not drop, rebind, or normalize protected inputs.
An external audit still requires identity/prefix/transition verification even when source and
delivery hashes are equal. Missing or ambiguous resolution leaves ordinary unchanged-tree gates
unchanged but grants no publication exemption: a required publication must fail explicitly.

Publication serializes writers and durably persists/fsyncs the exact intended append bytes before
writing, freezing timestamps and statistics. On retry, reconcile the pending intent before requiring
unchanged pre-publication equality. An unchanged prefix permits the intended append; an already
complete intended tail permits receipt completion without duplicate rows. An interrupted partial
write may be completed only when its bytes are a proven prefix of that exact intent; otherwise
fail closed without truncating foreign bytes. Never invent new rows or timestamps to recover a
pending publication.

The result exposes `input_fingerprint` (the immutable reviewed anchor), `delivery_fingerprint`
(the actual complete live hash), `audit_transition`, and `final_review`; checkpoint publication
also returns `checkpoint_receipt`. Copy these fields verbatim. Never replace source fields, the
anchor snapshot, constituent closures, or mechanical proof with delivery values.

Later gates, receipt verification, runtime acceptance, and completed-result reuse independently
validate the persisted source certificate and transition against live inputs. Reconstruct expected
rows from ledger evidence and bound run/pass, not caller receipt claims; recompute manifest hashes
and check canonical identity, the entire unchanged prefix, exact appended tail, and live delivery.
Only the derived canonical worktree audit entry and its necessary changed-file membership
adjustment may normalize back to the reviewed prefix. Evaluate final-full coverage and mechanical
evidence at that reviewed anchor, never against delivery-only additions. Every other manifest
difference, unreceipted/extra/malformed tail, prefix rewrite/truncation, path substitution, or forged
transition fails closed. Full fingerprint scope remains intact under the v2 manifest: no generic
audit exclusions, untracking, or caller-authoritative hashes.

Any later operational write must occur before publication or outside **every protected manifest
input**, not just outside `build.jsonl`. Even `orchestrate.jsonl` or another normally ignored log
is protected if explicitly supplied as context. Do not mutate the delivery while accepting it.

During durable review, `build-log.sh` routes operational rows (including full R1 transport and
progress success/warnings) through `operational-log` while `MAKATO_REVIEW_LEDGER_STATE` and
`WORKTREE_PATH` are exported. The derived destination is
`<worktree-git-dir>/makato-review-loop/<run-id>/operations.jsonl`, never canonical `build.jsonl`.
The helper rejects physical aliases of protected context/contract/source paths, symlinks and
hard-linked destinations before writing; there is no fallback to a protected audit on failure.
Progress comment identities are cached in that private log without reading or patching
workflow-state during review. Empty or failed cache reads never invoke legacy state migration;
failures warn without falling back to protected state or canonical audit. Select the logger/cache
reader from exact `MAKATO_BUILD_ROOT`, not a guessed orchestrate sibling, while retaining both
frozen root bindings. Durable progress invokes the executing build's
`verify-binding --state S --worktree W --build-root B --orchestrate-root O`, with O derived from
its own physical helper directory, before transport/logging. This read-only command verifies the
executing review_loop, passed roots, and any shared override, prints verified binding JSON on
success, and never appends audit. On mismatch progress warns on stderr only, performs no GitHub
call/private-log write, and exits 0; it never enters discovery or workflow-state branches.
Durable build-log validates its own physical installation through its own review_loop before
private ledger/audit writes, using the ledger's orchestrate binding rather than new helper flags.
Its preexisting temporary model cache is outside that private-write promise. This is narration
metadata, not a second orchestration-state writer.

## Task-boundary checkpoint

A checkpoint is not final certification. The first checkpoint reviews the whole current
completed-task diff against the merge-base tree; later checkpoints review the delta from the last
accepted checkpoint snapshot plus affected callers and all applicable constraints/security rules.
Future ACs stay provisional. Do not author final AC verdicts, mark future ACs passed, fabricate an
empty delta, or write a final `ac-verification` entry.

The gate derives `checkpoint_scope:{pre_snapshot,scope_files}` from retained source snapshots and
fingerprint manifests, never caller-provided scope assertions. It includes deleted/untracked
paths, affected callers/dependencies and previous invariant sites. Cite explicit inputs using
their `context:`, `contract:` or `orchestrate:` manifest labels. Context/contract changes invalidate
previous source coverage; uncertain/truncated impact expands scope. One unscoped reviewer or all
five lenses must each cite the complete required set with sufficient `files_reviewed`; a positive
count or an aggregate union masking an unread lens is insufficient.

Checkpoint snapshots store the raw reviewed bytes, not Git-cleaned blobs: text/eol attributes and
clean filters must not change their identity. The gate overlays every branch-changed path, including
committed paths whose raw working-tree bytes differ from their Git blobs. Manifest SHA-256 and
kind/mode comparisons remain exact; even a raw change with an identical cleaned blob invalidates
publication or acceptance and must appear in the next reviewed delta. Snapshot construction leaves
the real index and source bytes untouched.

Once the latest fresh scoped pass has no unresolved blockers, submit evidence with non-empty
summary/citations, current fingerprint, pass ID, task IDs, `scope:"delta"`,
`checkpoint_verified:true`, `final_review:false`, reviewer identity/independence, and exhaustive
constituent dispositions. Do not supply `snapshot` or `checkpoint_scope`; the gate derives both.
Call `gate --event checkpoint` without expected AC IDs. It returns `next_action:"review"`, never
`complete`, and a source receipt with the accepted snapshot. Then call `publish-audit` as above.
Copy its returned `checkpoint_receipt` verbatim to R1 `data.checkpoint_receipt`, not the earlier
gate receipt. The delivery copy retains the source `input_fingerprint` and `snapshot` and adds
`delivery_fingerprint` and `audit_transition`. Also transport those publication fields at R1
`data` level with `final_review:false` and `next_action:"review"`.

The scheduler's actual selected installed script is hash-bound in the closure; the ledger's
checkpoint command validates its own executing build installation and frozen roots, not the
scheduler's process identity. The scheduler must independently validate the source certificate and
audit transition against the ledger and actual live full delivery fingerprint before accepting IDs:

```bash
DELIVERY_FINGERPRINT_JSON="$(python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" fingerprint \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" --evidence-root "$REPO_ROOT" \
  --contract-root "$MAKATO_BUILD_ROOT" --orchestrate-root "$MAKATO_ORCHESTRATE_ROOT" \
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}")" || exit 1
DELIVERY_FINGERPRINT="$(printf '%s' "$DELIVERY_FINGERPRINT_JSON" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" || exit 1
SOURCE_FINGERPRINT="$(printf '%s' "$AUDIT_PUBLICATION" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["input_fingerprint"])')" || exit 1
CHECKED_RECEIPT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" checkpoint-receipt --state "$STATE" \
  --task-ids "$CHECKPOINT_TASK_IDS" --fingerprint "$SOURCE_FINGERPRINT" \
  --pass-id "$PASS_ID" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE")" || exit 1
printf '%s' "$CHECKED_RECEIPT" | python3 -c \
  'import json,sys; assert json.load(sys.stdin)["delivery_fingerprint"] == sys.argv[1]' "$DELIVERY_FINGERPRINT" || exit 1
```

The argument is the reviewed source identity, never the delivery hash. The verifier independently
checks the live publication and returns the exact delivery receipt; compare its delivery hash
separately as above and the whole receipt verbatim before acceptance. An unpublished source
receipt is never deliverable. Scope coverage is rederived again at publication and receipt
validation, including repeated acceptance. The scheduler requires the scope's `pre_snapshot` to
match its last accepted source snapshot (null initially). Missing historical scope evidence blocks
for explicit evidence-preserving migration, never resetting roots, history or consumed repair
budget. Persist the anchor snapshot for the next delta.

Publication, operational-log and checkpoint-receipt commands recover both roots from the validated
ledger and internally forward them through every source/delivery recheck; they do not rediscover
roots or accept root override flags. A later normal build-review still performs final-full, all AC
judgments, mechanical no-change validation, the `complete` gate, and final audit publication.
