---
name: build-review
description: >-
  Adversarial review with an immutable evidence gate. Blocking findings are independently confirmed,
  repaired locally when bounded or redesigned only for architectural/cross-boundary work and
  recurrence, then independently re-reviewed. Every transition is checkpointed. Final success
  requires a fresh full-branch/all-AC review and a no-change mechanical gate. Supports explicit
  task-boundary checkpoint reviews without claiming final certification. Risk-sample duplication
  stays off unless promoted by release evaluation. Use after simplify, before verify. Trigger
  keywords: review, adversarial, diff-review, code-review, quality-gate, build-review, check
  implementation.
version: "1.11.0"
argument-hint: "[work-item-key] [--checkpoint-task-ids <comma-separated task ids>]"
allowed-tools:
  - Bash
metadata:
  last_updated: "2026-11-02"
---

# Build Review

**Do NOT load this skill when:** reviewing human PR comments (use `build-address-pr-comments`);
simplifying complexity without correctness review (use `build-simplify`). Use after implementation
for adversarial review and the CRITICAL/MAJOR coder repair loop before verify.

Use after `/simplify` and before `/verify`. The implementation is working, tested, and simplified.
This step reads the branch diff adversarially — its job is to find problems and improvements, not to
confirm correctness.

## Expert Constraints (read before every step)

Non-obvious rules that cannot be inferred from context:

1. **Merge-base to working tree, not HEAD alone.** Resolve the integration target after fetching
   origin, then use `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"`. Review
   `git diff "$REVIEW_BASE"` plus untracked files. This preserves three-dot merge-base semantics
   without hiding uncommitted implementation or coder repairs. Never use bare local `main` (#98).

2. **Every pass needs evidence, independent of diff size.** Require exact source citations for each
   changed file in a clean full pass, behavioral evidence for findings, and code/test citations for
   each final verified AC. There is no LOC-based clean-pass exemption or blanket severity downgrade.
   See Step 4 and `references/review-criteria.md`.

3. **`ac_verdicts[]` transport: `build.jsonl` is the only durable record.** `workflow-state.json` is
   gitignored and never reaches the post-merge GHA runner. `build.jsonl` is the only
   cross-environment path the `build-create-pr` PR-body renderer and the `documentation-agent`
   checkpoint flipper can read. Write the verdict entry on the final clean pass — not on
   intermediate passes, not to any other file.

4. **Both blocking tiers are mode-independent.** CRITICAL and MAJOR must be repaired and
   independently re-reviewed in manual and autonomous runs. Never defer a MAJOR to the user,
   downgrade it to SUGGESTION, or mark it resolved merely because the coder returned success.

5. **`diff-reviewer` is the sole verdict judge.** `build-review` and `build-create-pr` are
   transport-only — they copy `ac_verdicts[]` verbatim. Re-evaluating verdicts here diverges
   silently from the diff-reviewer's reasoning and corrupts the downstream Issue checkbox chain.

6. **Checkpoint context is role-scoped, not renewed authorization.** On resume, use the current
   invocation and user authorization for the coordinator; historical child prompts are evidence, not
   coordinator instructions. Keep coordinator context separate from reviewer/coder dispatch bundles.
   A reviewer's read-only or no-test-edit restriction must never become a coordinator or coder
   restriction through a checkpoint. Preserve actual findings and input fingerprints, but reconcile
   stale role-scoped constraints before dispatch.

7. **A delta pass proves the repair, not the change.** Post-repair delta reviews check the repair
   and its affected callers. They never certify the full branch or replace the mandatory fresh
   final-full pass covering every changed file and AC. The persisted review gate controls each
   transition; `review_scope.py` may size a gate-authorized pass but cannot waive final-full, infer
   completion, or reset repair history. A completed background pass is not final certification.
   Never derive deltas with `git diff` — only snapshot helpers can separate exact uncommitted tree
   states.

8. **Background and lens passes never read the live worktree during a repair.** A background review
   reads only the materialized snapshot of the pre-repair tree (`review_scope.py materialize`), in
   its own checkout. Lens reviewers run while nothing edits the tree. A reviewer that reads files a
   coder is editing reviews a tree that never existed.

---

## Workflow

> **This skill does not commit.** Mechanical fixes and coder repairs stay in the working tree for
> `/build-push-to-git`. Neither the skill nor its coder dispatch may stage, commit, or push.

### Step 1 — Ask for work item key and load context

If no argument was passed, invoke `AskUserQuestion`:

- question: _"Which work item are we reviewing?"_
- hint: `e.g. #123 — or pass directly: /makato-build:build-review #123`

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables. Apply the workspace entry guard
in `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`: `WORKTREE_PATH` is required in autonomous mode; manual
mode defaults to the current git worktree. Missing autonomous workspace returns R1 failure, never a
fallback to the main checkout.

```bash
cd "$WORKTREE_PATH"
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git rev-parse --git-common-dir)/.." && pwd)}"
SPEC_FOLDER="$(python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>")"
```

Read `plan.md` from that folder if it exists. Extract the full acceptance-criteria list from the
authoritative plan or caller-provided story context. Set `PLAN_CONTEXT_PRESENT=true` only when that
source exists, assign stable IDs from it (or `AC-1`, `AC-2`, … in document order), and encode the
complete, non-empty set in `EXPECTED_AC_IDS` as comma-separated IDs. Unknown or empty IDs are not a
zero-AC assertion: return non-success rather than launch a normal review or claim completion. The
runtime pins this first complete set in the ledger; later gates cannot shrink it. A checkpoint still
pins the full story AC set, but its `checkpoint` event omits `--expected-ac-ids` and judges only the
completed-task scope.

An optional task checkpoint is selected by explicit `--checkpoint-task-ids 1,2,3` or
`REVIEW_CHECKPOINT_TASK_IDS`; the explicit argument takes precedence. Normalize IDs as unique
positive decimal plan-task IDs. The caller supplies `CHECKPOINT_COMPLETED_TASK_IDS` and the previous
accepted `REVIEW_CHECKPOINT_BASE_SNAPSHOT` when one exists. Require every requested ID to exist in
`plan.md` and belong to the caller's completed-task set; reject missing, unknown, or incomplete IDs
before review. Never read or write `workflow-state.json`.

With no checkpoint IDs, this is the normal final review: all story ACs are in scope. With checkpoint
IDs, scope `PLAN_CONTEXT` to those completed tasks and their AC links, but carry all applicable
project hard constraints, security rules, and caller contracts into every reviewer prompt. Future
task ACs remain explicitly provisional and are not judged verified; omit `ac_verdicts[]` and the
`ac-verification` build-log entry for the checkpoint. A checkpoint can return only a non-final
receipt; it never replaces the later fresh full-branch/all-AC review.

For the first checkpoint, use the merge-base tree as the pre-snapshot so the review covers the whole
current completed-task diff; do not assume a previous accepted snapshot or invent an empty delta.
Later checkpoints use the exact `REVIEW_CHECKPOINT_BASE_SNAPSHOT` from the last accepted receipt. In
either case build `REPAIR_DELTA` with `review_scope.py delta`, including changed callers/neighbours
and current constraints; if no relevant diff exists, the scheduler skips the checkpoint, and
build-review must not fabricate an empty receipt.

Fetch origin (`git fetch origin --quiet`), then resolve
`DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"`. If origin is unreachable, use the
helper's local fallback. Set `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"` once for this
run. Before **every** review pass, refresh `CHANGED_FILES` as the deduplicated union of
`git diff --name-only "$REVIEW_BASE"` and `git ls-files --others --exclude-standard`. Use
NUL-delimited output when processing paths programmatically. Read untracked files directly;
`git diff` does not include them. All code reads and commands run in `WORKTREE_PATH`; only spec
reads and audit writes use the selected `REPO_ROOT`-rooted `SPEC_FOLDER`.

`CHANGED_FILES` is the whole-change set. Full passes review all of it; delta passes receive
`REPAIR_DELTA` (Step 5) and re-read only the repair and its neighbours.

---

### Step 2 — Persist the repair caps, open the loop state, and log session start

On first `review_loop.py init`, the helper reads `MAKATO_MAX_REPAIR_ROUNDS` (soft cap, default `3`)
and `MAKATO_MAX_REPAIR_ROUNDS_HARD` (hard cap, default `8`), validates them, and persists the
effective caps with the ledger. Read `MAX_REPAIR_ROUNDS` and `MAX_REPAIR_ROUNDS_HARD` from the
helper's persisted state, not from model memory.

On resume, stored caps are authoritative. Missing environment values preserve them; later
environment values or `gate --soft-cap` / `--hard-cap` may only lower them. A higher cap requires an
explicitly authorized migration; never raise limits automatically. Repair history and caps survive
changed fingerprints and resumes. These limits never override HALT, approval, budget, or uncertain
evidence.

The persisted `gate` is the only transition and convergence authority. Never derive counts from
`PASS_NUMBER`, supply caller-maintained counters, or invoke a separate counter-policy command. If
initialization reports invalid configuration or an incompatible ledger, preserve its warning or
migration error and fail closed rather than resetting state.

`MAKATO_REVIEW_SCOPE` (`delta` default or `full`) sets the initial review preference. The persisted
gate authorizes every subsequent transition; `review_scope.py` can size only an authorized pass and
cannot override a gate action or satisfy final certification. A task checkpoint is always a genuine
delta relative to its pre-checkpoint snapshot: first checkpoint uses the merge-base tree; later
checkpoints use `REVIEW_CHECKPOINT_BASE_SNAPSHOT` from the last accepted receipt. In checkpoint mode
the coordinator constructs `REPAIR_DELTA` with `review_scope.py delta` and reviewers inspect its
scope and all affected callers; do not relabel a whole branch pass as a delta. Invalid/missing
checkpoint scope blocks receipt creation.

`MAKATO_REVIEW_LENSES` is `auto` (default), `on`, or `off`: whether a full pass is split into one
reviewer per lens. Log the effective mode and each helper-returned `sample_counts` value.
`review_loop.py lenses` receives `--profile standard|deep` and
`--pass-kind initial|first-rereview|later`. Use `standard` by default; risk-sample duplication is
OFF.

No release-qualified `review-eval-v2` artifact is promoted for this configuration. Keep every
`sample_counts` value at one. A future deep qualification requires verified source/config hashes,
rollout eligibility, quality and workflow-performance passes, holdout verification, repeated corpus
runs, and positive paired marginal recall benefit; no caller-supplied boolean or claimed fingerprint
qualifies it. The configuration fingerprint is derived from exact model, explicit settings, and
canonical prompt/helper source inventory; it is distinct from run `input_fingerprint`
(branch/base/spec/context). The helper verifies the artifact against its live plugin source
inventory and recalculates policy before enabling two samples for error-handling and
state-concurrency on only the initial full pass and first re-review. Sampling never replaces
ordinary review, independent blocker confirmation, or mandatory final-full.

Open the loop state. It records every finding with the passes that raised it and the repair rounds
that claimed to fix it — the only way to see that one invariant keeps coming back. It lives in the
worktree's git directory, so it is never committed:

```bash
LEDGER_DIR="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/makato-review-loop"
STATE="$LEDGER_DIR/<key>.json"
RUNTIME_STATE="$LEDGER_DIR/<key>/runtime.json"
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" init --state "$STATE" --story <key> --review-base "$REVIEW_BASE"
# {"state":"…","resumed":false,"next_id":1}
```

`resumed:true` means the same story and `REVIEW_BASE` already has history; retain all finding IDs,
constituent evidence, gate history, and repair/recurrence counters. A changed fingerprint
invalidates stale review evidence but never resets counts. A legacy/incompatible state that needs
migration fails with an explicit migration error; never reset it and continue. If `init` fails, log
terminal `step:"session"`, `status:"error"` and return non-success: never review without the ledger.

Compute the run input fingerprint before the first review and again before every state-changing
dispatch and completion check. It binds the merge base, tracked/untracked worktree bytes, every
spec/context file actually supplied to reviewers, and the review/runtime contract files:

```bash
SPEC_REL="${SPEC_FOLDER#"$REPO_ROOT"/}"
CONTEXT_ARGS=()
if [[ -f "$SPEC_FOLDER/plan.md" ]]; then
  CONTEXT_ARGS+=(--context-path "$SPEC_REL/plan.md")
fi
for context_file in spec-delta.md glossary.md; do
  if [[ -f "$SPEC_FOLDER/$context_file" ]]; then
    CONTEXT_ARGS+=(--context-path "$SPEC_REL/$context_file")
  fi
done
# Add each other repo-relative source file actually supplied to PLAN_CONTEXT.
CONTRACT_ARGS=(
  --contract-path skills/build-review/SKILL.md
  --contract-path skills/build-review/references/review-loop.md
  --contract-path skills/build-review/references/review-criteria.md
  --contract-path skills/build-review/references/mechanical-fixes.md
  --contract-path agents/diff-reviewer.md
  --contract-path agents/coder.md
  --contract-path agents/RETURN-CONTRACT.md
  --contract-path AUTONOMOUS-MODE.md
  --contract-path config/default-workflow-schema.yml
  --contract-path config/verification-ownership.md
  --contract-path shared/review_loop.py
  --contract-path shared/review_scope.py
  --contract-path shared/review_runtime.py
  --contract-path shared/review_eval.py
  --contract-path shared/skill_execution.py
  --contract-path scripts/run-skill.py
)
FINGERPRINT_JSON="$(python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" fingerprint \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" --evidence-root "$REPO_ROOT" \
  --contract-root "$MAKATO_BUILD_ROOT" "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}")"
INPUT_FINGERPRINT="$(printf '%s' "$FINGERPRINT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
if [[ "$PLAN_CONTEXT_PRESENT" == "true" && -n "$EXPECTED_AC_IDS" ]]; then
  AC_GATE_ARGS=(--expected-ac-ids "$EXPECTED_AC_IDS")
else
  AC_GATE_ARGS=()
  EXPECTED_AC_IDS_BLOCKED=true # Return R1 failure; never pass an empty expected-AC set.
fi
GATE_ARGS=(--state "$STATE" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
  --evidence-root "$REPO_ROOT" --contract-root "$MAKATO_BUILD_ROOT"
  "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}")
```

If the fingerprint helper fails or any required context/contract path is unavailable, stop
non-successfully; never omit an input to make the hash succeed. In autonomous mode the
`run-skill.py` wrapper owns the durable `initial` gate and passes its receipt into the skill;
validate its fingerprint and follow its action. A fresh run normally starts with `review`;
`confirm`, `repair-local`, `redesign`, or `certify` resumes that stage instead of repeating the
initial scan. Do not run a second out-of-band initial gate before the wrapper launches. In manual
mode, record the same gate directly:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event initial --fingerprint "$INPUT_FINGERPRINT" \
  "${AC_GATE_ARGS[@]}"
```

The gate's JSON `next_action`, `reason`, `gate_id`, and `input_fingerprint` are authoritative. Every
later reviewer/coder launch is preceded by the persisted gate action that authorizes it; every
returned result is reconciled and gated before proceeding. A result, timeout, resumed process,
manual fix, or clean-looking reviewer message is never authority by itself.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>,"pass":1,"max_repair_rounds":<MAX_REPAIR_ROUNDS>,"max_repair_rounds_hard":<MAX_REPAIR_ROUNDS_HARD>,"review_scope_mode":"<delta|full>","review_lenses":"<auto|on|off>"}}'
```

---

### Step 3 — Auto-fix mechanical issues

Load `@references/mechanical-fixes.md`.

Apply all applicable fixes silently — these are never findings:

- Formatting drift (indentation, spacing) — run the project's formatter if one is configured
- Import ordering and unused import removal
- Trailing whitespace

Log:

```text
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 4 — Review an immutable snapshot

**MANDATORY: Load `@references/review-criteria.md` before dispatching a reviewer.** Before each
pass, apply mechanical normalization (Step 3), refresh the changed-file set and fingerprint, then
capture and materialize one immutable snapshot:

```bash
PASS_SNAPSHOT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" snapshot \
  --worktree "$WORKTREE_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])')"
PASS_PATH="$(dirname "$STATE")/snapshots/pass-<N>"
python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" materialize --worktree "$WORKTREE_PATH" \
  --snapshot "$PASS_SNAPSHOT" --path "$PASS_PATH"
```

All reviewers in a pass, the independent confirmation batch, and any independent smoke run must read
the same snapshot ID. No writer edits it. Reviewers receive `WORKTREE_PATH: PASS_PATH`; coders
always receive the live `WORKTREE_PATH`. If snapshot creation/materialization fails, stop
non-successfully; never silently review a moving tree. Release the materialized checkout after the
pass and all confirmation evidence have been merged.

Before each dispatch, call the persisted gate for the current transition and proceed only when its
`next_action` authorizes that role. The outer autonomous `run-skill.py` call owns the initial gate;
the skill gates every later dispatch/result, including clean, manual-fix, resume, and repair
transitions. Recompute `INPUT_FINGERPRINT` after any byte/context/contract change; stale citations
and results cannot be carried across a changed fingerprint. If the bootstrap receipt says `certify`,
start directly with fresh final-full scope. If it says `confirm`, `repair-local`, or `redesign`,
resume the corresponding Step 5 transition. Do not re-run a full initial scan merely because the
coordinator process restarted.

Dispatch `diff-reviewer` with:

- `STORY_KEY`, `PASS_NUMBER`, `CHANGED_FILES`, `PLAN_CONTEXT`, `REPO_ROOT`, `REVIEW_BASE`, and
  immutable `WORKTREE_PATH: PASS_PATH`;
- `REVIEWER_ID`: the actual unique native identity assigned to this reviewer dispatch; never invent
  or rename an identity. Independent confirmation uses a different reviewer identity;
- `INPUT_FINGERPRINT` and `CITATION_CONTRACT` on the very first dispatch and every re-dispatch;
- `PRIOR_FINDINGS`, `REVIEW_SCOPE`, `REPAIR_DELTA`, and (delta only) `PRIOR_AC_VERDICTS`;
- `PASS_KIND: initial|delta|final-full|checkpoint`; checkpoint mode also supplies
  `CHECKPOINT_TASK_IDS`, `CHECKPOINT_COMPLETED_TASK_IDS`, `REVIEW_CHECKPOINT_BASE_SNAPSHOT` when one
  exists, and all applicable `CHECKPOINT_CONSTRAINTS`;
- `LENS` when the lens helper schedules a lens.

The citation contract requires exact path/line/source evidence for findings and sites, code-and-test
citations for every verified AC, and the exact `INPUT_FINGERPRINT`. Every ordinary reviewer R1
includes `data.file_citations` with exactly one `{file,line,excerpt?}` citation for each file it
actually reviewed in scope; cite deleted files against `REVIEW_BASE`. `files_reviewed` must match
the scoped files covered. Unknown paths are gaps, not clean citations. For final-full, freshly
review the whole changed-file manifest and every authoritative AC; cite every changed file, cover
the complete manifest, and start all AC verdicts from scratch. A final-full pass is certifiable only
with all five lens results or one unscoped full reviewer (`lens:null`); a single `contract-ac` lens
cannot certify the branch. Do not inherit prior AC verdicts or background citations as final
evidence.

**Lens-split full pass.** Before each full pass run `review_loop.py lenses` for the current
worktree, review base, mode, profile, and risk-sample phase. Standard sampling:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" lenses \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" \
  --mode "$MAKATO_REVIEW_LENSES" --profile standard \
  --pass-kind "$RISK_SAMPLE_PHASE"
```

Use `standard` by default. Only a release-promoted configuration may use `deep`; derive its
configuration fingerprint from the exact model, explicit settings, and installed plugin source
inventory:

```bash
REVIEW_CONFIGURATION_JSON="$(python3 "$MAKATO_BUILD_ROOT/shared/review_eval.py" configuration \
  --model "$REVIEW_MODEL" --settings "$REVIEW_SETTINGS_JSON" \
  --source-root "$MAKATO_BUILD_ROOT")"
REVIEW_CONFIGURATION_FINGERPRINT="$(printf '%s' "$REVIEW_CONFIGURATION_JSON" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
```

The configuration command returns the derived fingerprint, model/settings, and canonical
`source_inventory`; never provide a claimed fingerprint in place of this computation. A promoted
schema-v2 artifact is produced from real manifest, scanner runs, and recovery evidence:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_eval.py" qualify \
  --manifest "$EVAL_MANIFEST" --runs "$EVAL_RUNS" --recoveries "$EVAL_RECOVERIES" \
  --model "$REVIEW_MODEL" --settings "$REVIEW_SETTINGS_JSON" \
  --source-root "$MAKATO_BUILD_ROOT"
```

`lenses` re-derives and verifies the current model/settings/source inventory, artifact hashes, the
pinned pre-change baseline tree and resolved executable/script bytes of all three adapters;
`--config-fingerprint` is an expected-value check only:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" lenses \
  --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" \
  --mode "$MAKATO_REVIEW_LENSES" --profile deep \
  --pass-kind "$RISK_SAMPLE_PHASE" --qualification "$REVIEW_EVALUATION_ARTIFACT" \
  --config-fingerprint "$REVIEW_CONFIGURATION_FINGERPRINT" \
  --model "$REVIEW_MODEL" --settings "$REVIEW_SETTINGS_JSON"
```

`RISK_SAMPLE_PHASE` is `initial` for the first full pass, `first-rereview` for the first re-review,
and `later` otherwise. Never use `INPUT_FINGERPRINT` for `--config-fingerprint`.

When `split:true`, dispatch the helper-returned `sample_counts` for each lens in one read-only
batch. All copies share identical snapshot, input fingerprint, pass number, scope, changed files,
and prior findings, but are separate reviewer identities. Preserve the union of their findings and
all raw constituent/site history; disagreement is resolved only by the separate confirmation
workflow, never a majority. Duplicate risk samples are not blocker confirmation. A delta pass uses
one reviewer. No repair starts until the read-only batch finishes or all readers have isolated
immutable snapshots and writers have disjoint ownership.

Long error-handling review may be divided only at coordinator-identified operation boundaries, with
one shared coverage map, cross-slice relationships, and bounded resource budget. Do not claim
automatic operation partitioning or add reviewers merely to increase count.

Save each reviewer R1 to `"$(dirname "$STATE")/pass-<N>-<lens|single>.json"`, merge the whole batch,
then call `review_loop.py gate --event review` with the merged evidence and current fingerprint. The
helper's `next_action` and persisted `reason` decide the next step. Reject missing/malformed R1,
`partial`, inconsistent severity counts, missing citations, or an R1 with errors as clean. Preserve
raw reviewer envelopes and every constituent finding. Merge only verified identical findings;
proximity of lines/sites is never evidence that two invariants are the same and must not discard
either.

If the gate selects `confirm`, dispatch one independent read-only `diff-reviewer` batch in
`REVIEW_MODE: confirm-findings` for every blocking new or unconfirmed constituent. Supply a fresh
`REVIEWER_ID`, immutable `PASS_PATH`, `INPUT_FINGERPRINT`, original findings, and the citation
contract. It returns one `confirmed|rejected|uncertain` result per finding with reachability,
impact, introduction status, and citations. A confirmed CRITICAL must include actual behavioral
regression evidence. Map `rejected` to ledger `false_positive`, preserve the original finding, and
persist every result:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event confirm --fingerprint "$INPUT_FINGERPRINT" --evidence "$CONFIRMATION_EVIDENCE" \
  "${AC_GATE_ARGS[@]}"
```

An uncertain or missing disposition blocks; there is no majority vote. Do not start repairs before
this batch completes unless reviewers used isolated immutable snapshots and the writer partitions
are disjoint.

The diff reviewer returns CRITICAL, MAJOR, SUGGESTION, or NITPICK, source-anchored evidence, and the
universal-invariant coverage matrix where applicable. For a checkpoint, it reviews only the
requested completed task delta plus affected callers and constraints; future ACs remain provisional
and it emits no `ac_verdicts[]`.

After merge and any confirmation, write the complete merged R1 and gate output as ledger evidence. A
helper error, incomplete review, unknown action, fingerprint mismatch, or uncertain finding is a
non-success/blocking transition. Release `PASS_PATH` only after preserving receipts.

#### Step 4a — Preserve final AC verdicts without re-judging them

Only `diff-reviewer` authors `data.ac_verdicts[]`; build-review and downstream skills transport them
verbatim. On ordinary delta passes, retain the most recent live-tree verdict set only as
intermediate evidence. A `final-full` pass freshly checks every AC against code and tests; every
`verified:true` verdict includes explicit code and test citations. A checkpoint emits no
`ac-verification` entry and never marks any current or future AC passed.

After the final mechanical no-change gate and `review_loop.py gate --event complete` returns
`next_action:"complete"` for the same fingerprint, copy the final `ac_verdicts[]` verbatim into the
`build.jsonl` `ac-verification` entry. Missing, empty, false, or uncited AC verdicts block final
completion; never substitute a build-review judgment.

---

### Step 5 — Gate findings, confirm blockers, and converge

Both CRITICAL and MAJOR block in manual and autonomous modes. A reviewer or coder R1 with `partial`,
`failure`, malformed/missing data, non-empty errors, an unreviewed file, or unresolved citation is
never clean. Missing evidence, cap exhaustion, timeout, or disagreement is recorded as `blocked`,
not converted to zero findings.

Every state transition is decided and persisted by `review_loop.py gate --state "$STATE"`. The
helper returns `next_action`, `reason`, `gate_id`, and `input_fingerprint`; obey its action and
never derive counters or convergence from model memory. The persisted gate is the sole transition
authority; use its action at every boundary.

- `initial`: before the first review (owned by `run-skill.py` in autonomous mode);
- `review`: after merging a complete diff-reviewer pass;
- `confirm`: after persisting a complete independent confirmation batch;
- `repair-local`: before a gate-authorized bounded repair; it reserves the attempt and returns the
  authoritative round and blocker IDs for the coder/manual repair;
- `redesign`: after an architectural, cross-boundary, unknown-scope, or recurrence plan is
  independently approved and before implementation;
- `certify`: after the required fresh final-full result and independent closure evidence for every
  blocking constituent;
- `checkpoint`: after a successful scoped task-checkpoint review;
- `complete`: after the final no-change mechanical check;
- `blocked`: whenever a cap, HALT, uncertain result, invalid fingerprint, or missing evidence
  prevents the next action.

For example, after merge:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event review --fingerprint "$INPUT_FINGERPRINT" --evidence "$MERGED_R1" \
  "${AC_GATE_ARGS[@]}"
```

The gate recomputes the current fingerprint from `GATE_ARGS`; `--fingerprint` is only an
expected-value check, never an authority. Use `--evidence` with the complete R1 or
confirmation/repair evidence appropriate to that transition. Every helper mutation appends durable
history and its reason. If the helper fails, state version is incompatible, or action is unexpected,
return non-success; never reset state or bypass it.

**Blocking findings:** retain every active constituent, stable ID, invariant, all sites, raw
evidence, current fingerprint, and recurrence history. Gate action `confirm` requires a separate
read-only `diff-reviewer` confirmation batch for every new or currently unconfirmed blocker
constituent. Store one `confirmed|rejected|uncertain` result per `finding_id` + `constituent_id`,
with evidence, reachable-path reasoning, impact, introduction status, citations, and `repair_scope`
(`local|architectural|cross-boundary|unknown`). `repair_scope` is the safe repair boundary, not line
count. Map `rejected` to `false_positive` only in the ledger disposition while preserving the raw
finding. A rejected finding remains auditable; uncertain or missing confirmation blocks. Never
resolve a finding by majority vote. If confirming reviewers cannot share the same immutable
snapshot, finish the read-only batch before any repair.

**Repair choice:** obey the gate's next action, not severity:

- `repair-local`: a clearly bounded local repair goes directly to coder, even when CRITICAL.
  Reproduce the reachable behavior first. Every confirmed CRITICAL gets a durable behavioral
  regression test for a plausible failure; every MAJOR gets a concrete reproduction and targeted
  verification.
- `redesign`: architectural, cross-boundary, or unknown repair scope, or a second unsuccessful
  return of the same invariant, requires a short plan and independent `repair-plan` review before
  editing. A CRITICAL severity alone never triggers planning. Do not attempt another local repair
  after the gate has selected redesign.
- Any cap/HALT, uncertain confirmation, unavailable verification, incomplete path matrix, or
  incompatible state returns non-success with the concrete reason and unresolved constituents.

For each invariant such as "every X", require the reviewer/coder to account for entry points,
returns, raises, helpers, transaction boundaries, async/cancellation paths, required effects,
existing tests, and unknown paths. For UI state include temporal order, pending/concurrent/late
responses, owner (component/store/API/project), navigation, and draft preservation. Unknown paths
remain gaps. AST/CFG inventory can aid discovery but cannot prove completeness. A wrapper is one
possible repair, not a default: it must respect the real operation boundary, early refusals,
audit-on-rollback, error/result semantics, and authorization.

Load `@references/review-loop.md` for the full repair-round commands. A round is one coder repair
dispatch followed by independent confirmation/re-review; use file-disjoint coder partitions only
after read-only reviewers finish and only when edits are disjoint. Validate each coder R1 and every
site's accounting; coder success is not approval. Normalize mechanical changes before re-review,
then refresh the fingerprint and freeze one immutable snapshot. Independent smoke and review may run
in parallel only against that identical frozen snapshot; defer all repairs until both read-only
activities finish. Use `review_scope.py delta` for a repair delta. The final-full pass is still
mandatory.

Before dispatching a coder or applying a manual repair, call `gate --event repair-local` only when
the persisted action authorizes it:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event repair-local --fingerprint "$INPUT_FINGERPRINT"
```

Supply no caller-supplied round, blocker list, or evidence. The gate derives blockers from the
latest current-fingerprint pass and independent confirmations, reserves the attempt, and returns
`repair_attempt:{round,ids,...}`. If `next_action` is not `repair-local`, do not repair.

After coder/manual repair, persist only the IDs actually claimed fixed and the writer's actual
unique native dispatch identity (the coder R1 `data.coder_id` for an agent repair):

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" repaired --state "$STATE" \
  --round "$REPAIR_ATTEMPT_ROUND" --ids "$CLAIMED_IDS" --coder-id "$CODER_ID"
```

This records the claim and requests fresh review; coder success is not approval. For redesign,
create a short no-edit coder plan and obtain a separate read-only `repair-plan` verdict. Once
approved, persist the transition before implementation:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event redesign --fingerprint "$INPUT_FINGERPRINT"
```

The gate authorizes implementation only after the plan is approved; never infer recurrence or
boundary scope from severity. Persist every completed reviewer pass with event `review`. When its
action is `certify`, run the required fresh final-full pass if it has not occurred on the current
tree. Then gate `certify` with the independent reviewer ID and one disposition per blocker
constituent:
`{finding_id,constituent_id,disposition:"fixed"|"false_positive"|"uncertain",evidence,citations}`.
An omitted or uncertain constituent blocks:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event certify --fingerprint "$INPUT_FINGERPRINT" --evidence "$CERTIFY_EVIDENCE" \
  "${AC_GATE_ARGS[@]}"
```

The gate's next action decides whether to continue or proceed to the no-change check.

**Zero findings do not imply completion.** A clean delta is repair evidence only. For a normal final
run, keep following the gate until a fresh `final-full` pass reviews the complete current branch
diff, all tracked and untracked files, all acceptance criteria, and all prior constituents in new
context. It is not satisfied by a background pass, carried citations, a prior clean pass, or a coder
result. Any source/context/contract byte change invalidates the result and requires the
scope-appropriate review, including another final-full when final evidence changed.

**Task checkpoint mode:** when `--checkpoint-task-ids` is supplied, do not run final-full or author
AC verdicts. Review the whole current completed-task diff on the first checkpoint (using the
merge-base tree as the pre-snapshot), or the delta since the last accepted checkpoint snapshot, plus
all affected callers and applicable constraints. Future ACs remain provisional. When the latest
successful pass is a fresh `delta` with no unresolved blockers, write the checkpoint evidence below
and call `gate --event checkpoint`:

```json
{
  "task_ids": ["1", "2"],
  "input_fingerprint": "<current SHA-256>",
  "pass_id": "P-3",
  "scope": "delta",
  "checkpoint_verified": true,
  "final_review": false,
  "reviewer_id": "<independent reviewer identity>",
  "independent": true,
  "evidence": "Fresh completed-task delta reviewed with affected callers and constraints; no unresolved blockers",
  "citations": [{ "file": "src/changed_file.py", "line": 42 }],
  "dispositions": []
}
```

When blockers were repaired, `dispositions` closes every still-open constituent as `fixed` or
`false_positive`, with non-empty evidence and file/line citations; `uncertain` blocks. Call:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event checkpoint --fingerprint "$INPUT_FINGERPRINT" --evidence "$CHECKPOINT_EVIDENCE"
```

The gate recomputes and checks the fingerprint, latest successful delta pass, pass ID, citations,
and constituent closure. The durable receipt contains `task_ids`, `input_fingerprint`, `pass_id`,
`scope:"delta"`, `checkpoint_verified:true`, `final_review:false`, and the gate-injected `snapshot`;
do not supply `snapshot` in checkpoint evidence. The gate returns `next_action:"review"` and never
`complete`. Copy the receipt verbatim to the build-review R1 `data.checkpoint_receipt`, set
`data.final_review:false`, and return `success` only if the gate validated it. Do not emit
`ac-verification`. The scheduler must validate the receipt against the actual ledger and current
fingerprint before accepting task IDs. Its authoritative validation command is:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" checkpoint-receipt --state "$STATE" \
  --task-ids "$CHECKPOINT_TASK_IDS" --fingerprint "$INPUT_FINGERPRINT" \
  --pass-id "$PASS_ID" --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
```

The scheduler compares the returned receipt verbatim before accepting; R1 success alone is
insufficient.

---

### Step 5.5 — Final mechanical no-change gate

Mechanical normalization belongs before each immutable review snapshot and before tests. After the
successful fresh final-full pass, take a final worktree snapshot and re-apply the mechanical check.
It must leave the source tree unchanged. If any byte changes, recompute the fingerprint, invalidate
final citations/AC evidence, review the changed delta, then perform a new final-full pass before
trying completion again. Do not accept a formatter-only delta as final certification.

```bash
fingerprint_current() {
  python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" fingerprint \
    --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE" --evidence-root "$REPO_ROOT" \
    --contract-root "$MAKATO_BUILD_ROOT" "${CONTEXT_ARGS[@]}" "${CONTRACT_ARGS[@]}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])'
}
FINAL_SNAPSHOT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" snapshot \
  --worktree "$WORKTREE_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])')"
BEFORE_FINGERPRINT="$(fingerprint_current)"
# Re-run the configured mechanical checks; then capture the tree and fingerprint again.
POST_SNAPSHOT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" snapshot \
  --worktree "$WORKTREE_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])')"
AFTER_FINGERPRINT="$(fingerprint_current)"
```

Only identical snapshot IDs and fingerprints prove `mechanical.no_change:true`. Persist the current
fingerprint and no-change evidence. `complete` evidence has these required fields; the gate reads
the successful final-full pass, AC citations, and blocker closures from the ledger:

```json
{
  "input_fingerprint": "<current SHA-256>",
  "mechanical": {
    "no_change": true,
    "evidence": "before_snapshot=<FINAL_SNAPSHOT>; after_snapshot=<POST_SNAPSHOT>; mechanical checks passed",
    "before_fingerprint": "<BEFORE_FINGERPRINT>",
    "after_fingerprint": "<AFTER_FINGERPRINT>"
  }
}
```

Then request:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" gate "${GATE_ARGS[@]}" \
  --event complete --fingerprint "$INPUT_FINGERPRINT" --evidence "$COMPLETE_EVIDENCE" \
  "${AC_GATE_ARGS[@]}"
```

Return final `success` only when this gate returns `next_action:"complete"` and the current
fingerprint still matches. Otherwise follow its action or return blocked. The final `build.jsonl`
`ac-verification` entry copies the diff-reviewer's final-full `ac_verdicts[]` verbatim; every AC
must be `verified:true` with code and test citations. Checkpoint mode exits before this step.

---

### Step 6 — Present final report and hand off

For a validated task checkpoint, report only the completed task IDs, scoped review result, remaining
provisional ACs, and that final review is pending. Return the R1 success envelope with
`data.checkpoint_receipt` copied verbatim from the gate, `data.final_review:false`, and
`data.next_action:"review"`; do not report overall story completion or emit `ac-verification`. The
scheduler must independently accept the receipt against the ledger and current fingerprint.

For normal completion, present the clean-run findings to the user:

- **CRITICAL and MAJOR findings** — list the verified repairs and pass count. Both open counts must
  be zero. Any surviving or regressed finding returns to Step 5.
- **SUGGESTION findings** — list with file, line, description. The user may address these before
  `/verify` if desired; they do not block.
- **NITPICK findings** — list with file, line, description. Purely informational.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"full_passes":<N>,"delta_passes":<N>,"background_passes":<N>,"lens_split_passes":<N>,"repair_plan_reviews":<N>,"criticals_fixed":<N>,"majors_fixed":<N>,"criticals_open":0,"majors_open":0,"suggestions":<N>,"nitpicks":<N>}}'
```

`passes`, `full_passes`, and `delta_passes` count live-tree review passes; a lens-split pass is one
pass. `background_passes` counts completed background full passes, `lens_split_passes` counts
full-scope passes (live or background) merged from more than one lens reviewer, and
`repair_plan_reviews` counts `diff-reviewer` dispatches in `REVIEW_MODE: repair-plan`.

Tell the user: _"\<N\> criticals and \<N\> majors fixed across \<N\> passes. No blocking findings
remain. \<N\> suggestions and \<N\> nitpicks noted above._ _Pipeline remaining: `/build-verify` →
`/build-push-to-git` → `/build-create-pr`_ _Next: run `/build-verify` to confirm all quality gates
pass."_

Return the R1 envelope from `$MAKATO_BUILD_ROOT/agents/RETURN-CONTRACT.md` with
`agent:"build-review"`, `status:"success"`, accumulated `files_changed`/`tests_written`,
`errors:[]`, and

```text
data:{passes,full_passes,delta_passes,background_passes,lens_split_passes,repair_plan_reviews,critical_count:0,major_count:0,final_review:true,input_fingerprint:<current SHA-256>}
```

A caller must not infer success from a prose report or a coder result.

---

## Anti-patterns

### NEVER diff against bare local `main` — WHY: PR-bleed

Diff against the merge-base with the fetched integration target, not the local branch tip. Include
working-tree repairs and untracked files; reviewing `HEAD` alone repeatedly reviews the old bug and
misses the uncommitted fix.

### NEVER commit during this skill — WHY: atomic-commit model

`/build-push-to-git` owns the commit step. Each commit must map to exactly one plan task and carry a
conventional commit message derived from the plan. Ad-hoc commits during review produce
un-attributable changesets that bisect incorrectly and confuse the post-merge documentation-agent
that reads `build.jsonl` to reconstruct the session.

### NEVER accept "reviewed and found nothing" without source-anchored citations — WHY: non-falsifiable claim

Every changed file in a clean full pass needs an exact source citation regardless of diff size. A
file without one is not reviewed. Record what concern was checked and the reachable source evidence;
"reviewed and found nothing" is not evidence.

### NEVER re-evaluate `ac_verdicts` in this skill or in `build-create-pr` — WHY: chain integrity

`diff-reviewer` is the only agent that reads both the diff AND the acceptance criteria
simultaneously with the adversarial lens. Re-evaluating verdicts here or in `build-create-pr` uses
only partial context (e.g., no diff, or no AC text) and silently diverges from the diff-reviewer's
reasoning. The downstream `documentation-agent` in `makato-orchestrate` uses `build.jsonl` as the
authoritative verdict source to flip Issue checkboxes; a re-evaluated verdict that contradicts the
diff-reviewer's corrupts the audit trail irrecoverably.

### NEVER downgrade a correctness concern to SUGGESTION to avoid blocking — WHY: silent PR escape

SUGGESTION and NITPICK are informational in both modes. Anything touching correctness, security, or
a real failure path is MAJOR or CRITICAL and must enter the coder repair loop. See
`references/review-criteria.md` for the classification boundary.

### NEVER accept a clean delta pass as final approval — WHY: delta review cannot see unrelated defects

A clean delta pass proves only the repair scope. The persisted gate must still authorize and record
a fresh final-full review of the complete branch and all ACs before completion.

### NEVER build the repair delta from `git diff` — WHY: repairs are uncommitted

Coder repairs and mechanical fixes stay in the working tree beside the original implementation, so
`git diff "$REVIEW_BASE"` shows both and `git diff HEAD` shows the whole implementation.
`review_scope.py snapshot` / `delta` compare two exact working-tree states with a throw-away index
and never touch the real index or working tree.

### Resolve background findings against the current snapshot — WHY: background scope is pre-repair

The background pass reviews `PRE_REPAIR_SNAPSHOT`, which still holds the defect the coder is fixing
in the same round. Do not count a pre-repair finding as an open live-tree blocker solely because it
recurs in the background result. Preserve its constituent and snapshot evidence, then independently
compare it against the current snapshot. Never discard findings by proximity or drop a whole ID
without proving the same underlying invariant and current disposition; anything unresolved on the
live tree remains blocking.
