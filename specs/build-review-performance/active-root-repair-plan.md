# R2-002 active-root closure repair (T5 / T7)

Status: revision 2 approved with C1–C7 and locally implemented.
Independent implementation review and remote CI remain pending.
Scope: CI repair task indices 6 and 8 only. Preserve retained F-001–F-004 and R1/R2 repairs.
No qualification run, sampling activation, downstream workflow, commit or push.

## Source-backed invariant and review history

The bytes executing review and its operational logging/narration must be the bytes bound by
review and qualification. An inactive consumer copy cannot certify an installed helper.
`review_scope.py:45-64,95-175` hashes only build-relative contracts. `run-skill.py:94-106`
can select environment build roots although imports come from its own installation;
`:413-443` independently resolves an unbound progress helper. Runtime gates use own-install
review_loop (`review_runtime.py:376-408`) but hash an environment root (`:838-839`).
`progress-comment.sh:53-82` can discover a different build root. Eval hashes one root
(`review_eval.py:66-93`); lenses assumes its own root (`review_loop.py:319-365`). Audit alias
guards recognize only worktree/context/contract (`review_audit.py:32-66,296-309`).

Independent reviewer ActiveRootPlanVerdict REJECTED revision 1, with source evidence and nine
blocking corrections B1–B9 (persisted separately with the actual R1). This revision resolves those
corrections as exact contract below. No production edits preceded either review. A throwaway
pre-repair runtime probe over independent temporary installs observed an unchanged qualification
fingerprint after active progress-helper mutation (exit 1); this is not an LLM qualification run.

## B1: Exact path grammar and manifest

Extend existing review_scope, not a second resolver module. A contract argument is either a
plain build-relative POSIX path or exactly `orchestrate:<rel>`. Reject other namespaces, colons
in relative components, empty strings/components, absolute paths, `.` or `..` components and
backslashes. Preserve existing build manifest labels `contract:<rel>`; orchestrate records use
`orchestrate:<rel>`. Manifest schema becomes `review-input-fingerprint-v2`, contract version 3.

Name the shared namespace dispatcher `review_scope.contract_input`: it returns source label,
relative path and selected root for one contract argument. It rejects an orchestrate entry with
no orchestrate_root. `review_scope.contract_inventory` uses it for ordered canonical records
(path, kind, mode, SHA-256) with stable-read checks. Both fingerprint and evaluation consume that
function, with no handwritten second closure. `review_loop.py contract-paths` prints exactly the
canonical REVIEW_CONTRACT_PATHS JSON array, in tuple order, with no additional keys.

Required inputs are regular files, contained below canonical roots, with no symlink component
below the root. Symlinked ancestors such as macOS /tmp are canonicalized, not rejected. The
in-tree skills/build-review/shared alias is not a valid contract input; use canonical shared paths.
Custom additional contract inputs remain supported but cannot replace a required closure entry.
Any durable contract binding requires explicit contract_root; never fall back to evidence_root.
Stateless generic fingerprint calls without durable bindings keep unrelated scope behavior.
Audit alias checks use contract_input, and manifest-source protection includes orchestrate;
unknown source mapping raises AuditError rather than KeyError.

## B2: Exact state schemas and two kinds of identity

Physical binding is separate from source-content fingerprint. Do NOT hash root paths, devices
or inodes into the review manifest or qualification configuration. Ledger state version 3 adds:

```text
contract_root: str | null                 # existing field
orchestrate_root: str | null
root_bindings: {build:{path:str,dev:int,ino:int},
                orchestrate:{path:str,dev:int,ino:int}} | null
```

Validate all three in _load_state, including exact dictionary shape, valid directory identities,
and consistency with canonical root fields. Unbound initial state has all three null. Bind them
atomically on first durable input bind; afterward they cannot change. Every state-using command
revalidates the executing install and live physical bindings. The same triple is stored on every
runtime attempt. Runtime VERSION becomes 2 and SCHEMA `review-runtime.v2`; old schemas fail closed.
Configuration schema becomes `review-eval-configuration-v2`.

`review_scope.root_bindings` captures realpath plus root-directory stat identity; inventory/fingerprint
captures identity immediately before and after reading bytes in the same process and rejects a
changed directory. The ledger/runtime compare those identities with frozen ones. Same bytes in
a different directory are a binding violation, not a source change. Recomputed qualification
content identity may remain equal after relocation, but only after explicitly selecting and
rehashing every required source byte at the new roots; metadata cannot assert equivalence.

An identity/schema mismatch, including reboot/remount renumbering, blocks the old ledger. No
automatic reset/migration or budget reset is authorized. The owner must preserve/export history
and consumed repair-round/cap budget before an explicitly authorized new ledger; existing review-3
history remains intact and is not reset by this invocation.

## B3: One exact active-root resolver

Name the Python resolver `review_scope.resolve_active_roots`. It takes the executing build
installation (derived by the caller from its own __file__), an environment mapping and optional
explicit orchestrate root. It returns canonical build/orchestrate/shared paths and physical
bindings. Explicit build environment must physically equal the executing installation; explicit
orchestrate CLI and environment values must agree. Shared override must physically equal the
selected orchestrate root's shared directory. Validate manifest names and regular canonical
required inputs; explicit roots need no Git checkout or marketplace.

If orchestrate is not explicit, permit a sibling ONLY when ALL these source-checkout proofs pass:

1. Executing build root realpath has basename makato-build and parent basename plugins.
2. Suite is build.parent.parent. `git -C suite rev-parse --show-toplevel` realpath equals suite.
3. `git -C suite ls-files --error-unmatch` succeeds for `.claude-plugin/marketplace.json`,
   `plugins/makato-build/.claude-plugin/plugin.json` and
   `plugins/makato-orchestrate/.claude-plugin/plugin.json`.
4. Marketplace name is makato-suite and its makato-build/makato-orchestrate entries have exactly
   sources ./plugins/makato-build and ./plugins/makato-orchestrate.
5. Both plugin manifests have their expected plugin names.
6. Sibling realpath equals suite/plugins/makato-orchestrate with no below-suite symlink component.

Run those Git calls with GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE and
GIT_CEILING_DIRECTORIES removed only for those calls. Linked worktree .git files are valid.
Cache/tarball/rsync installs require explicit orchestrate selection. Never search cache globs,
registry, PWD or consumer vendored copies in this durable resolver. Bash helpers invoke Python
binding verification rather than implement another resolver. Non-durable resolvers stay unchanged.

## B4–B5: Named enforcement choke points

- Launcher detects durable flags or runtime-child BEFORE build_command. Resolve/freeze roots,
  then pass an environment copy exporting MAKATO_BUILD_ROOT, MAKATO_ORCHESTRATE_ROOT and
  MAKATO_ORCHESTRATE_SHARED to build_command. Add makato-orchestrate to prompt metadata.plugin_roots
  for durable dispatch (not to dispatchable _PLUGINS). Invocation digest therefore covers both.
  Durable --dry-run exposes these frozen roots. Add --review-orchestrate-root to launcher; reject
  conflicting overrides. Runtime-child re-entry cannot replace persisted bindings.
- Runtime launch derives build root from its own __file__, never environment authority, and
  compares any exported build root. Authorize_child, reconcile, accept, recover-worktree and
  direct review_runtime CLI verify the executing install and persisted physical bindings before
  acting. Recovery validates those roots but NEVER dynamically loads code from a frozen path.
  Pass exact orchestrate_root through _gate and every gate call, attempt, snapshot and reuse check.
- review_loop _load_state checks the executing own installation against bound build identity and
  validates both live roots before EVERY state-using command: init/resume, gate, merge, repaired,
  background, publish-audit, operational-log, checkpoint-receipt and binding verification.
  Explicit contract/orchestrate arguments must equal frozen identities. Stateless fingerprint
  and configuration may hash explicit source roots without asserting code executes there.
- New CLI `verify-binding --state S --worktree W --build-root B --orchestrate-root O` checks
  executing review_loop plus passed roots and any exported shared directory against the ledger.
  It is read-only, prints verified binding JSON on success, exits nonzero on mismatch, and never
  appends audit. Root identity helpers are shared with the existing _load_state checks.
- In durable progress-comment, BUILD_ROOT is exported MAKATO_BUILD_ROOT only. Before transport or
  logging invoke that CLI with build root and the helper's physical SCRIPT_DIR/.. as orchestrate
  root. Both exported root and shared directory must agree with helper self-identity. On failure
  print stderr warning ONLY, perform no gh call/private log, exit 0 (preserve best effort).
  Durable helper never reaches sibling/cache/repository discovery or workflow-state.sh.
- Durable build-log uses its own physical HERE/review_loop and the ledger's verification before
  private writes. It needs no new orchestrate CLI flags: arbitrary child skills already call it
  directly; bound state supplies orchestrate identity. Reject before writes on mismatch.
- Any fixture-only execution-root injection is keyword-only `_execution_root` in-process, never
  exposed as CLI option or environment input. Prefer real source-root fixtures where feasible.

## B6: Exact canonical closure and historical baseline

Retain all 18 current REVIEW_CONTRACT_PATHS entries. Add build-relative
`.claude-plugin/plugin.json`, `shared/build-log.sh`, `shared/default-branch.sh`, plus
`orchestrate:.claude-plugin/plugin.json`, `orchestrate:shared/progress-comment.sh` and
`orchestrate:scripts/task_schedule.py`.

The manifests define root identity. build-log and progress are actual durable operational
helpers. default-branch.sh and task_schedule.py are caller-executed gate/checkpoint inputs
(po-agent.md:907 and :1011), not review-child imports. runtime-context.sh is EXCLUDED: the new
durable resolver removes its only durable caller; its unchanged non-durable behavior is not
claimed as an active durable dependency. workflow-state.sh and its transitive helpers are
EXCLUDED because durable progress returns through private ledger branches before executing them
(progress-comment.sh:179-208). Root verification must not invoke those non-durable branches.
Existing review imports/prompt/ownership/schema inputs remain covered. OS tools/runtime remain
under existing command/environment responsibilities, not a recursive external installation hash.

Eval uses an explicit frozen BASELINE_REQUIRED_CONTRACT_PATHS constant: the OLD 18 build-relative
v2 paths minus shared/review_eval.py, shared/review_runtime.py and shared/review_audit.py. Do not
derive this from the newly extended candidate tuple. No namespaced or newly required candidate
file is required of the immutable old release. Preserve its complete existing tree inventory.

## B7–B8: Sampling and closure gates

Lenses adds --state and reads both roots from validated live ledger bindings; any explicit root
flags must match. Without state or with unresolved/invalid bindings, sampling remains OFF with
sampling_warning (not an exception). Verify qualification with exact bound roots, never assumed
own-source or caller-claimed content identity. No qualification report is created by this repair.

Require REVIEW_CONTRACT_PATHS subset of contract_paths at `_durable_review`, runtime `launch`
and durable `_bind_inputs` before any child can execute. Incomplete input is blocked before
spawn, never accepted until final certification. Generic unbound ledger unit fixtures may use
only the named in-process seam, never a production CLI/env bypass. Keep no-child completed
attempt reuse, epoch/cap/recurrence and all audit/source-anchor/delivery safeguards.

## B9: Complete caller and closure matrix

| Boundary / current source | Required cutover and proof |
| --- | --- |
| review_scope fingerprint | contract_input/inventory dispatch, roots stable before/after read, v2 manifest; traversal and active mutation probes. |
| run-skill launcher and runtime-child | Pre-build_command frozen roots, prompt metadata, strict installed resolver, shared override checks, dry-run visibility and duplicate invocation identity. |
| review_loop ledger | Schema v3, atomic initial binding, full closure in durable bind, _load_state identity on all state operations; stateless fingerprint has explicit roots. |
| Runtime launch/authorize/reconcile/accept | Attempt v2 triple, exact namespace inventory and all gate calls; root switch/helper mutation rejects reuse with no new child. |
| Runtime direct CLI and recover-worktree | Propagate orchestrate parameter for launch; recovery uses persisted identities and executing-code agreement, no rediscovery/import from frozen root. |
| build-log/progress | Validate own installation and frozen roots before every durable side effect; preserve private narration identity and protected legacy context. |
| Audit capture/publication/recovery/receipt | Pass both roots through every fingerprint; use contract_input for physical alias checks and orchestrate manifest-source map; preserve hardlink and exact-prefix safeguards. |
| Checkpoint scheduler | Binding check lives in ledger command invoked via --review-loop; scheduler cannot itself know binding. Wrong executing helper fails there; keep post-decision launch fingerprint order. |
| Eval configuration/run/qualify/verify | Same canonical inventory, both explicit roots on every recheck; content-only config v2, frozen old baseline set; adapter payload carries exact candidate roots when applicable. |
| Lenses | --state validated binding; deep sampling OFF without valid bound qualification; explicit root overrides must match. |
| functions.sh:4119-4125 exporter | Export MAKATO_ORCHESTRATE_ROOT with existing SHARED, consistently with actual executing orchestrate root; no consumer-root inference. |
| loop.sh:126-129 exporter | Preserve/verify actual own orchestrate root/shared and selected build root; do not rediscover conflicting roots later. |
| context-handoff.sh:267 exporter | Verify both exact roots survive handoff unchanged; update only if source reveals a real gap. |
| po-agent.md:881-915,944-946,1000-1002,1011 | Consume contract-paths once, all three fingerprints and runtime/checkpoint gates carry frozen orchestrate root. |
| build-review SKILL.md:226-248 | Replace handwritten inventory with canonical JSON command, pass frozen roots and state to applicable commands. |
| references/review-loop.md:42-55,287-288 | Both initial/gate and delivery fingerprints forward exact roots; lenses state and merge interface updated. |
| AUTONOMOUS-MODE.md:283-316 and README.md:261-293 | Exact installed/source layout CLI examples and canonical namespace inventory; no independent sibling rediscovery claim. |
| RETURN-CONTRACT / AUTONOMOUS / CHANGELOG | Contract 3, ledger 3, runtime 2, config v2 and fail-closed mismatch/budget handling; implementation review still pending. |
| test_review_eval.py:22,211 | Namespace-aware two-root fixtures, valid manifests, source-content relocation and active-helper stale qualification. |
| test_review_loop.py:137-139,1745-1747 | Canonical fixture source roots or in-process seam; preserve source/audit receipt tests and explicit context/hardlink negatives. |
| test_run_skill_runtime.py:55,89,118 and review_runtime_child.py | Actual launcher copies, both root bindings/inventory passed through fresh children; installed roots plus inactive decoy proof. |
| test_review_runtime.py:275-276 | Both-root attempt fixtures, incompatible schema/root/missing binding negatives, retain Darwin and writer-fence behavior. |

## Implementation order and required evidence

One implementing coder at a time per worktree. Canonical scope/ledger/audit contract first;
runtime/launcher and helper enforcement consume it; evaluator/caller consumers consume that
contract. Docs may run in parallel after approval. Production BUILD and a real runtime probe
precede permanent tests. Each coder preserves a disposable preimage, runs its own new tests RED
against it and focused GREEN against current production; never restore old code into this tree.
No suite/integration/coverage run. Reuse recorded branch evidence with unknown baseline failures,
so every focused failure blocks. No rerun of unchanged original macOS failures.

Exercise the actual installed copy of the source launcher over separate freshly materialized
build/orchestrate installs plus inactive sibling/consumer decoys; first delivery and one-child
reuse; active build-log/progress/resolver-byte changes stale review/reuse and qualification;
inactive decoy mutation cannot stand in for active-copy verification; missing/conflicting root
or shared binding, physical root switch/replacement, traversal and old attempts fail closed.
Exercise audit publication/receipt/alias protection and complete caller propagation. Source-layout
fallback requires full Git/marketplace proof, with adversarial GIT_* environment isolation.
Non-durable resolver behavior is unchanged and directly exercised. Synthetic policy tests do
not establish historical corpus, LLM recall/speedup, pilot or remote macOS approval.

## Approved pre-dispatch amendments C1–C7

These specifics qualify revision 2 and override ambiguous wording above. They are the exact
pre-dispatch amendments required by ActiveRootPlanRecheck; that reviewer explicitly stated that
they do not change the approved design and need no fresh review unless changed.

- C1: An unbound no-contract ledger remains legal for generic state commands and checkpoint
  fixtures, including operational-log, repaired, background, checkpoint-receipt and checkpoint
  publication. It does not authorize durable execution or final certification. Do not enforce
  closure when contract_paths is None and no binding exists. On the FIRST actual durable bind,
  gate/merge require explicit contract_root AND orchestrate_root, plus the complete closure;
  review_loop does not rediscover either root. Add --orchestrate-root to fingerprint, merge,
  gate and lenses. Lenses with absent/unbound state keeps sampling OFF with warning.
- C2: Manual build-review and reference flows resolve/freeze both roots before first bind.
  MAKATO_ORCHESTRATE_ROOT is required for installed/manual binding; it is not optional and no
  runtime-context/cache discovery may fill it. Only the launcher may use the fully proved source
  checkout fallback. README and skill examples must reflect this distinction.
- C3: Add reconcile-before-resume.sh:112-119, po-agent.md:863-864,1084-1085 and
  reconcile-before-resume-smoke-tests.sh:239-265 to caller coverage. Existing non-durable sibling
  fallback may remain; a wrong executing install in durable recovery returns blocked, exit 4,
  rather than executing from a frozen path. test_task_schedule.py:553-660 remains the real generic
  no-contract checkpoint flow under C1, and is exercised after the cutover.
- C4: Scheduler is hash-bound only: canonical closure hashes its actual selected installed copy.
  The ledger checkpoint command checks its own executing build installation and frozen roots,
  not the scheduler's process identity. Do not claim otherwise or add an invented prefix check.
- C5: Configuration v2 uses canonical records path/kind/mode/SHA-256. "Content-only" excludes
  physical root locations/devices/inodes, NOT source kind or executable permission. Relocation
  with identical bytes AND kind/mode preserves content identity; permission changes invalidate it.
- C6: Empty root exports are unset. Canonicalize helper own directories using pwd -P or Python
  realpath. build-log's preexisting temporary model cache is outside the new "before writes"
  promise: that promise covers private ledger/audit writes. Durable _progress_target never reaches
  runtime-context.sh, including runtime-child re-entry. Preserve non-durable behavior.
- C7: Include --review-orchestrate-root in durable_flags AND runtime-child override rejection.
  Main resolves roots before build_command; build_command includes orchestrate prompt metadata
  only when args denote durable or runtime-child dispatch, using those resolved roots. Both
  launcher and runtime child must construct identical authorized command bytes. Durable dry-run
  resolves roots without requiring a bound ledger; visible_env exposes build/orchestrate/shared.

## Independent verdict

Revision 1: REJECTED by ActiveRootPlanVerdict (B1–B9); no production edits made.
Revision 2: APPROVED by independent ActiveRootPlanRecheck, with C1–C7 above applied verbatim in
meaning before dispatch. B1–B9 were independently marked resolved. Exact review evidence is
`.git/makato-ci/186/active-root-plan-review-2.txt`. No production edit preceded
approval/amendment application. Approval is technical design only; implementation review, final
AC certification, qualification and remote CI remain unapproved.

## Local implementation outcome

Tasks 6 and 8 have completed BUILD, actual runtime, permanent behavioral tests and
targeted verification. Canonical closure has 24 inputs; invocation roots remain
physically frozen, while reproducible configuration uses only source kind/mode/bytes.

- Independent design approval: revision 2 with C1–C7 applied before production edits.
  Revision 1 rejection remains in `.git/makato-ci/186/active-root-plan-review-1.json`.
- Coder-owned RED/GREEN and pre-test runtime evidence are retained in
  `.git/makato-ci/186/active-roots-{core,runtime,helpers,eval}-r1.json`.
- Combined affected-path verification: 400 tests and 206 subtests passed.
  Progress-comment source smoke: 33 passed.
- Actual source launcher with separate active installations and an inactive sibling:
  accepted delivery, one-child duplicate reuse, active mutation blocked, inactive
  decoy irrelevant, and dry-run exports both roots and the selected shared directory.
- Final evaluator source CLI: 10 controlled source-identity scenarios passed;
  coder-owned final CLI evidence covers 14 scenarios. These are synthetic source
  and policy checks, not real LLM qualification.
- Branch baseline evidence was reused without fabricating a missing failure set.
  Every selected failure was blocking; no full suite, integration or coverage ran.
- Six newly authored audit rows lacked timestamps. Disclosed recorded-at backfills
  preserve their existing data and the exact pre-invocation 91-row audit prefix;
  original event times are unavailable and were not invented.

R2-002 is locally implemented, not independently implementation-certified.
Retained R2-001, R1-001 and R2-003 repairs still require independent re-review.
Native macOS and remote CI confirmation remain CI-owned. Sampling remains OFF;
qualification and pilot are blocked. No downstream workflow, commit or push ran.
