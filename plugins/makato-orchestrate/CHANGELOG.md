<!-- markdownlint-disable MD013 -->
# Changelog — makato-orchestrate

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change.

## [Unreleased]

### Added
- `promote-lessons.sh`: **tier-based routing** (#494, epic #464). A promoted
  `scope: generalizable` record is now routed by its `tier` field —
  `tier == "semantic"` lands in `.makato/memory/semantic.jsonl`, `tier ==
  "procedural"` or an absent tier lands in `.makato/memory/procedural.jsonl`
  (byte-for-byte legacy behaviour). Dedup + occurrences-bump applies
  independently per target file. Adds an optional 4th positional argument
  `SEMANTIC_MEMORY_FILE` (default `.makato/memory/semantic.jsonl`); 3-arg callers
  are unaffected. Closes the gap where a `tier:semantic` fact written by the
  build lane (#473) never reached `semantic.jsonl`. Smoke T9/T10 and
  `test_promote_lessons.py::TestPromoteLessonsSemanticTier` cover routing,
  regression, and per-file dedup.
- `loop.sh`: orphaned `specs/<slug>/` folder pruning (`_reap_orphan_specs`) —
  runs in the same reap pass as the merged-worktree reaper. Removes local spec
  folders for issues that are done (`workflow-state-<N>.json`
  `current_phase == "done"`, fast local path) or closed (`gh issue view` returns
  `CLOSED`, fallback for thin folders). Only FULLY-UNTRACKED folders are ever
  removed — any tracked file skips the folder (consumer repos use
  `archive-spec.sh` via `git mv`). **Before deleting, generalizable lessons are
  promoted:** the reaper runs `promote-lessons.sh <N>` so any
  `scope: generalizable` lesson in the (gitignored) `workflow-state-<N>.json` /
  `change-lessons.jsonl` lands in `.makato/memory/procedural.jsonl` first; a
  failed promotion keeps the folder so no lesson is lost. This is the only place
  that promotion can read those files — `documentation-agent` runs on a fresh
  GHA checkout where the gitignored sources do not exist. Default on; opt-out via
  `MAKATO_LOOP_REAP_SPECS=0`. Respects `MAKATO_LOOP_REAP_DRYRUN`; offline test
  hook `MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE`. Audit in `loop-status.json`
  `.last_reap_specs_count` / `.reap_specs_pruned`. New smoke tests T84–T90.
  Bumps `loop` skill to 2.1.0.

### Fixed
- `promote-lessons.sh`: spec-folder discovery now matches BOTH lane naming
  conventions — number-first `<N>-<slug>` (new-work, e.g. `470-persistent-memory`)
  as well as the previous number-last `<slug>-<N>` and bare `<N>`. Previously the
  `*-<N>` glob silently missed every new-work spec folder, so their generalizable
  lessons never promoted into `.makato/memory/`. New smoke test T8.


- `seed-issue`: expanded plan lane to all `new-work` issues — light-planner now
  runs at seed time for `plan-tier:full` issues too, gating board promotion on a
  valid `plan.md` (`PLAN_LANE=true` replaces `LIGHTWEIGHT_LANE=true`)
- `loop.sh`: pre-dispatch plan guard (`_pre_dispatch_plan_guard`) in
  `cmd_dispatch()` — validates `plan.md` before launching the PO-agent; attempts
  `build-refine --autonomous` recovery on invalid plans; patches
  `pre_dispatch_plan_guard` field into `loop-status.json`
- **Added** persistent memory store and extended `recall-lessons` (#470, epic #464 S1).
  Creates `.makato/memory/` with committed `semantic.jsonl` and `procedural.jsonl` JSONL files as the persistent, cross-run lesson store. Extends `recall-lessons` to read this store alongside `workflow-state-*.json` sources, adds optional `--bundles`/`--labels` filters, and sorts results by scope asc, occurrences DESC, recency DESC. Updates the po-agent Step 2c call-site to pass tech-label bundles. All changes backward-compatible with the existing 2-arg `recall-lessons <REPO> [N]` signature.
  - **`.makato/memory/semantic.jsonl`** and **`.makato/memory/procedural.jsonl`** — empty committed JSONL files; the persistent store that outlives per-issue spec folders.
  - **`.gitignore`** — `*.jsonl` under `.makato/` ignored by default; the two committed files explicitly negated. `.loop-owner.pid` also added to the gitignore so the root-structure guard passes cleanly.
  - **`scripts/check-root-structure.sh`** — `.makato` added to the `ALLOWED` hidden-directory array.
  - **`shared/workflow-state.sh`** — `recall-lessons` extended: reads `.makato/memory/*.jsonl`, parses optional `--bundles`/`--labels` from argv, applies OR-filtered bundle/label matching, sorts by `[scope_rank ASC, occurrences DESC, cycle DESC, ts DESC]` (two-pass stable sort for backward compat with legacy items). Malformed JSONL lines skipped without aborting.
  - **`skills/workflow-state/references/workflow-state.schema.json`** — `lessons_learned` items extended with optional `bundle`, `scope` (`generalizable`|`local`), `occurrences`, and `label` fields (additionalProperties remains false).
  - **`skills/workflow-state/references/recall-extension-smoke-tests.sh`** — new T59–T64 smoke suite for the recall extension (AC-1 through AC-5).
  - **`agents/po-agent.md`** Step 2c — updated to derive `BUNDLES_CSV` from `tech:*` labels and pass `--bundles` to `recall-lessons`.
  - **`skills/workflow-state/SKILL.md`** — `recall-lessons` signature documented with filters and sort order.
  - **`README.md`** — workflow-state skill description updated; `workflow-state.sh` entry updated.
  - New tests: `tests/test_memory_store.py`, `tests/test_root_structure_guard.py`, `tests/test_makato_gitignore.py`, `tests/test_recall_lessons.py`.

- **Fixed** `context-handoff.sh` `_emit_resume` — type:change resume routing (#467).
  - A HALT-007B context handoff now detects a `type:change` run by the presence of `specs/*/change-state-<N>.json` and emits a `makato-change:orchestrate` resume prompt (with the recovered `WORKTREE_PATH` baked in and a "resume from current phase, commit inside WORKTREE_PATH" instruction) instead of the po-agent prompt. Non-change issues keep the byte-for-byte-unchanged po-agent resume path.
  - Adds T16 (change-state present → change-orchestrate + WORKTREE_PATH) and T17 (absent → po-agent) to `context-handoff-smoke-tests.sh`; adds T76 (type:change dispatch threads change-orchestrate + REPO_ROOT) to `loop-smoke-tests.sh`.
- **Fixed** `loop` — dispatch no longer produces a doubled issue-number branch prefix.
  - When the derived `KEY` already begins with `<issue>-` (both the `to-issues` footer slug for collision-avoidance folders like `470-persistent-…` and the seed-issue title-fallback slug `<issue>-<title>`), `cmd_dispatch` now emits `feat/<key>` instead of `feat/<issue>-<key>`, avoiding branches like `feat/470-470-persistent-…`. A `KEY` without the prefix (e.g. `test-feature`) still gets `feat/<issue>-<key>` as before.
  - T27 smoke-test assertion updated to expect the un-doubled `feat/503-fix-…`.

- **Changed** `promote-ready` → v1.1.0 — dependency label cleanup after promotion.
  - Step 5 now removes `blocked by` from each promoted issue immediately after the board promotion succeeds.
  - After the full promotion batch completes, computes the reverse dependency graph and removes `blocking` from every upstream issue whose all downstream dependents have been promoted to `Ready` or beyond. Check runs once per upstream issue per batch (not per individual promotion) to avoid redundant API calls. Both operations are best-effort (`|| true`) — a label-remove failure never aborts or rolls back the board promotion.

- **Changed** `seed-issue` → v1.3.0 — dependency labels `blocked by` / `blocking` pre-created on every target repo at seed time.
  - Step 3 now unconditionally creates both `blocked by` (`B60205`) and `blocking` (`D93F0B`) via idempotent `gh label create ... || true`, regardless of issue type. This ensures the labels are present before `to-issues` batches run or before operators apply them manually.
  - Provenance footer, plan stub, and `seed-manifest.json` `skill_version` updated to `1.3.0`.
  - Step 9 confirmation summary now lists the two dependency labels in the `Labels` line.

- **Added** `loop` — per-issue final-envelope aggregation into a run report (#448, part of #443).
  The loop dispatches issues serially and deliberately discards each PO-agent exit code, so an
  overnight multi-issue run left no single "N issues → N verdicts" summary; operators had to
  hand-reconstruct what shipped vs what escalated from N separate `workflow-state-<issue>.json`
  files.
  - **`scripts/generate-run-report.sh`** — new read-only script. Accepts issue numbers (positional
    or via `--issues "<n> <n>"`), locates each `specs/*/workflow-state-<issue>.json`, and derives a
    verdict per issue: `merged` (positive `github_pr_number`), `halted` (last `halt_audit` entry,
    carrying its machine-readable `code` + `origin`), or `unknown` (missing/incomplete state — never
    an error). Emits `.claude/state/run-report-<run_id>.json` (atomic write; `run_id` defaults to a
    UTC slug, overridable with `--run-id`). Prints the report path to stdout, a one-line summary to
    stderr. Never writes `workflow-state.json` or `orchestrate.jsonl` — it is a derived artefact, not
    a second source of truth.
  - **`scripts/loop.sh`**: `cmd_run` accumulates the dispatched issue numbers (real dispatches only,
    not `--dry-run`) and calls the report script at every end-of-run boundary (HALT, `--once`,
    poll-fail-`--once`) via the new best-effort `_emit_run_report` helper — prints the report path to
    stderr and records it in `loop-status.json` under `.last_run_report`. Skips silently on an idle
    run. bash-3.2-safe empty-array expansion at the call sites; a report failure never changes the
    loop's exit status.
  - **`scripts/generate-run-report-smoke-tests.sh`**: new **T1–T8** — mixed merged+halted batch,
    halt-origin propagation, empty list, missing-state → unknown, multi-entry halt_audit (last wins),
    legacy no-origin entry, read-only contract (no fixture mutation / no orchestrate.jsonl), and
    `--run-id` override. Fully offline via synthetic fixtures under `MAKATO_REPORT_SPECS_DIR`.
- **Added** `loop` — `gh` CLI → REST fallback for the critical loop calls (#447, part of #443).
  Every GitHub read outside the board poll (`_gh_project_item_list`) previously went straight
  through `gh` with `|| true`, so an auth glitch, a CLI bug, or an unparseable JSON body
  degraded silently — `jq` failed and the result was indistinguishable from an empty one, so
  a broken KEY derivation or gate read looked like "no provenance" / "no labels" and the tick
  proceeded on bad data.
  - **`scripts/loop.sh`**: new `_gh_with_fallback <context> <primary args> -- <rest args>` wrapper
    (mirrors `_gh_project_item_list`'s contract) that retries the primary `gh` call, falls back to
    the REST `gh api` equivalent with bounded exponential backoff, and — via the new `_gh_json_valid`
    predicate — treats jq-unparseable output as a failure, never masking it as an empty result. On
    exhaustion it prints nothing and returns non-zero so callers distinguish it from an empty payload.
  - Wired into the four critical read sites: `_derive_key_for_issue`'s body + title fetch, the
    dispatch-gate `labels,title` fetch, and the issue-type routing `labels` fetch. Non-critical
    best-effort calls (assign, label create, comment post, board item-add) keep their fail-open
    `|| true` behaviour — no over-engineering.
  - Two new env overrides, floor-guarded and documented in the `loop.sh` header like `POLL_RETRIES`:
    `MAKATO_LOOP_FALLBACK_RETRIES` (default 2) and `MAKATO_LOOP_FALLBACK_BACKOFF_BASE` (default 2s).
  - **`scripts/loop-smoke-tests.sh`**: new **T-fb-json** + **T-fb-1–T-fb-5** — primary-success (REST
    never called), primary-exit-fail → REST success, unparseable-JSON → REST success, all-attempts
    exhausted → non-zero + empty stdout, and 429 → backoff-then-late-success. Fully offline via
    `MAKATO_LOOP_FALLBACK_TEST_CMD` + `MAKATO_LOOP_SLEEP_CMD=true`. Also hardened the pre-existing
    watchdog (T12–T14) and stall-cause (T-STALL-1a/2a/3a) tests, which dispatch bogus offline issue
    numbers: they now set `MAKATO_LOOP_FALLBACK_TEST_CMD='exit 1'` + `MAKATO_LOOP_SLEEP_CMD=true` so
    the newly-wrapped KEY-derivation / routing / gate reads fail instantly and offline (preserving the
    original empty-KEY → po-agent routing) instead of incurring real REST-fallback backoff before the
    watchdog child spawns — that latency was pushing T12 past its 6-second observation window.

- **Changed** `config/skill-bundles.yml` (#430) — `promote-ready` appended to both the
  `orchestrate-skills` bundle (after `archive-spec`) and the `orchestrate-shared` bundle
  (after `kill-switch`), so edits to orchestrate skill files and shared/scripts/hooks bash
  helpers surface the `promote-ready` skill in the injected context.

## `loop` — auto-seed: generalise bot-author veto from `renovate[bot]` to any `*[bot]`

Hardens the auto-seed candidate filter's author backstop (added by #369). The veto previously
matched only the literal `renovate[bot]`; a bot-filed issue from any other GitHub App
(`dependabot[bot]`, `github-actions[bot]`, …) without the `dependencies` label would slip
through into the auto-seed queue. Bot-authored issues are never human-shaped work.

- **`scripts/loop.sh`**: `_auto_seed_candidates` T3 author veto now matches the generic
  `*"[bot]"` suffix instead of the exact `renovate[bot]` login, covering all current and
  future bot accounts. Skip log now includes the offending author login.
- **`scripts/loop-smoke-tests.sh`**: new **T58b** regression guard — asserts `dependabot[bot]`
  and `github-actions[bot]` (both without a `dependencies` label) are vetoed by the author
  backstop alone, while a human author passes.

## `loop` — HALT-013: bound the auto-reshape to prevent plan↔build oscillation (#351, epic #319 S5)

Story 5/5 of epic #319 closes the *no runaway* gap for the auto-drive reshape pass added by #350.
Introduces `HALT-013` (Hard stop): when a Needs Planning issue is picked up by `_reshape_pass` but has
already been reshaped `MAKATO_MAX_RESHAPE_CYCLES` (default **2**) times, the loop stops dispatching and
pages the operator instead. Mirrors the bounded-counter design of HALT-008 origins and HALT-010.

- **`scripts/loop.sh`**:
  - Ceiling check in `_reshape_pass` now fires **HALT-013** instead of a silent `needs-human-review`.
    Three-step contract per `halt-conditions.md HALT-013`: (1) apply `needs-human-review` label via
    `_apply_needs_human_review_reshape`; (2) append `halt_audit` entry with `code:"HALT-013"` and
    `data:{reshape_cycles, max_reshape_cycles}` to `workflow-state-<issue>.json` via
    `workflow-state.sh append-halt`; (3) write `orchestrate.jsonl` line `step:"halt" data.halt_code:"HALT-013"`.
  - `MAKATO_MAX_RESHAPE_CYCLES` default changed from `3` → **`2`** to match epic #319 design;
    existing callers who already set this env var are unaffected.
  - Inline doc comment updated to reference HALT-013 and new default.
- **`shared/workflow-state.sh`**:
  - `init` subcommand now initialises `reshape_cycles: 0` alongside `ci_failure_cycles` and
    `structural_halt_cycles`, so freshly-initialised state files carry the counter.
- **`skills/workflow-state/references/workflow-state.schema.json`**:
  - Added `"default": 0` to the `reshape_cycles` property (field was added by #350; default was absent).
- **`halt-conditions.md`**: new HALT-013 row — trigger, action, recovery.
- **`agents/po-agent.md`**: HALT-013 added to the HALT/label matrix table.
- **`never-patterns.md`**: new NEVER rule — "Never dispatch a reshape when `reshape_cycles >= MAKATO_MAX_RESHAPE_CYCLES`; fire HALT-013 and page the operator instead."
- **`README.md`**: HALT code table updated to reference HALT-000 through HALT-013.
- **`scripts/loop-smoke-tests.sh`**: two new scenarios (T-reshape-halt013-ceiling and T-reshape-halt013-below-ceiling) covering the HALT-013 boundary.

---

## task-file-scout agent (formerly scout) (#397)

- Renamed the `scout` agent → `task-file-scout`. The bare `scout` root was the most
  confusable of four discovery agents (`context-scout`, `gate-scout`, `knowledge-scout`,
  `scout`); the new name states its per-task-file role. Agent file `agents/scout.md` →
  `agents/task-file-scout.md` (`git mv`), frontmatter `name`, H1, self-reported R1 `agent`
  identity, and all references updated: the `agents/scout.md` dispatch path in
  `build-implement-tdd`, `coder.md`, `knowledge-scout.md`, `RETURN-CONTRACT.md`, and the
  orchestrate AGENTS.md/README roster + agent table. The `SCOUT_SUMMARY` coder-input field
  and the `scout-skipped` / `scout-partial` JSONL step names are unchanged (renaming those is
  a separate breaking contract change, out of scope here).

---

## `loop` 2.0.0 — auto-seed at dispatch: tick integration, toggle, and offline smoke suite (#373, epic #367 S5)

S5 (final) of epic #367 completes the auto-seed-at-dispatch pipeline by composing the four arms
built by S1–S4 into a single pre-poll pass, wiring it into `cmd_run` before `_promote_labelled_ready`,
and providing a default-on toggle plus a standalone entry point. A full offline smoke suite
(scenarios Ta–Tk) validates all arms, best-effort behaviour, idempotency, toggle, and ordering.

- **`scripts/loop.sh`** (→ 2.0.0 via SKILL.md):
  - New function **`_auto_seed_unprepared()`** (#373, epic #367 S5) — composing pass that calls
    `_auto_seed_candidates()` (S1) and routes each `{number, plan_tier}` candidate: `light` →
    `_auto_seed_dispatch_light()` (S2) then `_auto_seed_reconcile_thin_body()` (S3) on the result;
    `full`/`change`/untiered → `_auto_seed_block_full()` (S4). Each candidate's handling is wrapped
    in `|| true` so a single failure never aborts the pass; the function always returns 0
    (best-effort contract, AC1).
  - **`cmd_run`** — pre-poll auto-seed call added immediately before `_promote_labelled_ready`
    (ordering is load-bearing: a freshly-seeded light issue must reach `Status=Ready` in the same
    tick, AC2). Gated on `MAKATO_LOOP_AUTOSEED_ON_POLL` (default on) and `status_name == "Ready"`.
  - New env var **`MAKATO_LOOP_AUTOSEED_ON_POLL`** (default on: unset / `1` runs the pass, `0`
    disables it entirely — no candidate query, no seed or block action, AC3). Documented at the
    top of the file alongside other `MAKATO_LOOP_*` toggle vars.
  - New subcommand **`auto-seed`** / `cmd_auto_seed()` — standalone entry point that runs
    `_auto_seed_unprepared` once and exits, mirroring `cmd_promote_ready` (AC4). Wired into the
    arg dispatcher at the `auto-seed)` case.
  - New test hook **`_test-auto-seed-unprepared`** in the `MAKATO_LOOP_TEST_HOOK` block — exercises
    `_auto_seed_unprepared` offline, reusing the per-step S1–S4 test hooks.
- **`scripts/loop-smoke-tests.sh`** — 11 new scenarios Ta–Tk covering all four arms, best-effort,
  idempotency, toggle, and ordering (AC5). All offline via `MAKATO_LOOP_*_OVERRIDE` /
  `MAKATO_LOOP_SEED_TEST_CMD` / `MAKATO_LOOP_BLOCK_TEST_FILE` hooks. Updated `ALL TESTS PASSED`
  summary line.
- **`skills/loop/SKILL.md`** (1.9.0 → 2.0.0):
  - Version bumped.
  - Subcommands table: added `promote-ready` and `auto-seed` rows.
  - Process section: new step 1.5 documenting the pre-poll auto-seed pass.
  - Env-var table: added `MAKATO_LOOP_AUTOSEED_ON_POLL`, `MAKATO_LOOP_AUTOSEED_OVERRIDE`,
    `MAKATO_LOOP_SEED_TEST_CMD`, `MAKATO_LOOP_BLOCK_TEST_FILE`, `MAKATO_LOOP_AUTOSEED_SPEC_ROOT`.
  - Smoke-tests section: added items 31–41 (Ta–Tk).


 — union-merge append-only files instead of silently dropping the target's lines

The `merge -X ours` fallback silently discarded the target branch's hunks on any conflicting region — and for an **append-only** file (a CHANGELOG where each PR prepends its own release block, an AUTHORS list, a `*.jsonl` audit log) that is data loss, not a resolution. `-X ours` does not even report a conflict there: `main`'s changelog entry just vanishes from the merge. This is the single most common conflict the autonomous loop hits (two PRs both touched the changelog), and it was being "resolved" by throwing away one side.

- **`scripts/resolve-append-only-conflict.sh`** (new) — union-merges one conflicted path via `git merge-file -p --union` over the three merge stages (`:2` ours / `:1` base / `:3` theirs), keeping every line from both sides in order, then `git add`s it. Handles the add/add case (absent base → empty). Emits a one-line JSON summary; refuses any path that is not actually unmerged. stdlib + git only.
- **`scripts/resolve-append-only-conflict-smoke-tests.sh`** (new) — 8 scenarios (T1–T8): arg validation, non-unmerged rejection, modify/modify union keeps both changelog blocks, staging + unmerged-state clearing, summary JSON, add/add (`had_base:false`), distinct-region superset, and merge-completes-after-resolution.
- **`skills/resolve-pr-conflict/SKILL.md`** (1.1.0 → 1.2.0) — Step 4 rewritten from a blunt `merge -X ours` to a **partitioned** fallback: a *plain* merge first (so all conflicts surface as unmerged paths — `-X ours` would hide them), then per-file resolution by a fixed append-only allow-list (`CHANGELOG(.md)`, `AUTHORS(.md)`, `CONTRIBUTORS(.md)`, `*.jsonl` → union; everything else → `checkout --ours`). `merge-fallback` log gains `union_files[]` / `ours_files[]`; success strategy renamed `merge-X-ours` → `partitioned-merge`; HALT-008 trigger, lesson text, and R1 summaries updated. `allowed-tools` gains the helper script.
- **`AGENTS.md`** — File Structure lists the two new scripts.


## `documentation-agent` 1.1.0 — mark verified AC checkboxes `[x]` on the linked Issue post-merge

Acceptance-criteria checkboxes were never checked by the autonomous pipeline; a merged PR closed its Issue with every `- [ ]` still empty. This adds a post-merge step that transcribes the per-AC verified/gap verdict — produced by `diff-reviewer` and carried in the PR body by `build-create-pr` (both in `makato-build`) — into the Issue's checkboxes, so a `[x]` reflects confirmed code + test coverage rather than merely a merge.

- **`agents/documentation-agent.md`** (→ 1.1.0) — new **Step 4a** (runs before Issue closure): extracts the `makato:ac-verdicts` JSON block from the merged PR body, matches each `verified: true` verdict to an Issue checkbox by normalized text, and flips `- [ ]` → `- [x]` via `gh issue edit --body`. **Granular** matching by default; **all-or-nothing fallback** when no line pairs (all-verified → check all AC/DoD boxes; any gap → check none, log `ac_fallback_gated_open`); **marks nothing** when the block is absent (no false `[x]`). Forward-only — never unchecks a box, never edits prose.
- Frontmatter gains `version: 1.1.0`; Rules document the issue-body edit as a bounded `gh` API mutation (outside the file `Write`/`Edit` allow-list); error-modes table and R1 examples updated (`ac_checkbox_mode`, `ac_boxes_checked`); "does NOT do" clarifies the agent transcribes verdicts, never judges ACs.
- **`AGENTS.md`** — documentation-agent roster row updated to note Step 4a checkbox marking.
- Producer chain: `plugins/makato-build/agents/diff-reviewer.md` § *Per-AC verdict* → `build-review` Step 4a → `build-create-pr` § *AC Verification block*.



Foundation story of epic #319 (HALT → planning feedback loop). No counter tracked how many
times an issue terminated on a **structural** HALT across separate PO-agent runs —
`outer_iteration`, `human_review_cycles`, `merge_conflict_cycles`, and `ci_failure_cycles` are all
within-run and none captures "repeated structural failure on the same issue". Epic #319's
AC-epic-1 needs that cross-run recurrence property to be detectable. This story adds the durable
counter; sibling stories #348 (emit Needs Planning signal) and #349 (reshape context packet) build
on it.

- **Schema** — new optional top-level field `structural_halt_cycles` (integer ≥ 0). Left OUT of
  `required` so the schema still validates the in-flight, gitignored `workflow-state-*.json` files
  written before this bump (same backward-compat precedent as `session_baseline_tokens` #281 and
  `flake_rerun_pending` #312); readers default an absent field to 0.
- **`shared/workflow-state.sh`** — `init` seeds `structural_halt_cycles: 0` alongside the existing
  counters. New subcommand **`bump-structural-halt <KEY> <ISSUE> <CODE> [<ORIGIN>]`** increments the
  counter by exactly 1 **iff** `(CODE, ORIGIN)` is a structural HALT — the authoritative set is
  HALT-003, HALT-STRUCTURAL, HALT-010, and HALT-008 with `ORIGIN == outer_iteration`. Every other
  code (HALT-007, HALT-007B, HALT-008 with origin `merge_conflict`/`ci_failure`/none) is a
  documented **no-op** (counter untouched, exit 0). Malformed codes are rejected. Prints the
  resulting value; self-logs a `step: "structural_halt_increment"` entry to `orchestrate.jsonl` on a
  real increment. Absent-field backward-compat: treated as 0 and backfilled on first structural bump.
- **`agents/po-agent.md`** — Step 7 (session-end) now calls `bump-structural-halt` once per run on a
  HALT termination, passing the `halt_audit[]` `data.origin` for HALT-008. Documents the HALT-007B
  exception: the handoff path (Step 4b) returns `partial`/HANDOFF before Step 7, and the helper
  classifies HALT-007B as non-structural, so the counter is never reset across a context handoff —
  a resumed session reads the same value the prior session persisted.
- **Tests** — `references/smoke-tests.sh` grows T47–T54 covering the #347 draft scenarios
  (structural increment, non-structural no-op, handoff-does-not-reset) plus init default,
  backward-compat backfill, and malformed-code rejection (46 → 54 assertions). The whole
  workflow-state suite is now wired into `.github/workflows/validate.yml` (it was previously not run
  in CI).

## po-agent — emit reshape-request on structural HALT (#349, epic #319)

Third story of epic #319 (HALT → planning feedback loop). Wires
`scripts/emit-reshape-request.sh` into the po-agent structural-HALT
termination path so every structural HALT produces a durable
`reshape-request.json` artifact that the `Needs Planning` signal (sibling
story #348) can read.

- **`agents/po-agent.md` Step 7** — added `emit-reshape-request.sh` call
  after `bump-structural-halt` (from #347) and before the session-end JSONL
  append. Applies to all structural HALT exits: HALT-003, HALT-STRUCTURAL,
  HALT-010, and HALT-008 with `data.origin == "outer_iteration"`. If the
  script exits non-zero, a `step:"emit-reshape-request" status:"warn"` entry
  is logged to `orchestrate.jsonl` but termination is never blocked — the
  HALT path always terminates cleanly.
- Also incorporates the `bump-structural-halt` prose from #347 (the
  `structural_halt_cycles` counter call and the updated session-end JSONL
  line that now includes `structural_halt_cycles`), which ships together with
  this PR.

---

## `promote-ready` 1.0.0 — dependency-aware Ready promotion (#268)

New skill + shared script closing the "FIFO only in v1" gap left by `loop` (#33). The
autonomous loop dispatches board `Ready` items strictly FIFO and single-threaded and ignores
cross-issue `blocked_by` dependencies; no makato component read the dependency graph back at
promotion time. `promote-ready` is the missing dependency-aware layer — an operator tool, run
deliberately wave-by-wave, that decides which issues may enter the loop's `Ready` queue.

- **`scripts/promote-ready.sh`** — loads the cross-issue dependency graph from
  `specs/<slug>/created-issues.json` (`issues[].blocked_by[]`, real issue numbers); falls back to
  `stories.json` (`stories[].dependencies.blockedBy`, story sequences translated to issue numbers
  via `sequence → githubIssue`, warning on stories with no `githubIssue`). Reads each issue's live
  board Status via `GH_HOST=<host> gh project item-list` (no `--hostname`; `gh project` has no host
  flag). Computes right-now-unblocked issues (board Status ∈ {Todo, Blocked, off-board} AND every
  `blocked_by` predecessor is `Done`), arranges topological waves, and prints a recommendation
  (waves / promote-now / collision-deferred / still-blocked / already-progressing). On approval
  (interactive, or `--yes`), promotes selected issues to `Status=Ready` via `gh project item-edit`
  — **idempotent, forward-only** (never rolls a card back from Ready/In progress/In review/Done, so
  it never races the loop claim or `issue-to-project sync-lifecycle`, #259), **warn-not-fail**.
  `--dry-run` / the `plan` subcommand mutates nothing. Reads all ids from `.claude/config.json` →
  `github_project` (no hardcoded IDs).
- **plan.md collision guard (#173)** — issues sharing one `specs/<KEY>-<slug>/` folder share a
  single `plan.md` in the main checkout (#173 isolated `workflow-state-<n>.json` but not
  `plan.md`). The tool never recommends two same-folder issues in one pass: it keeps the lowest
  issue number per folder and defers the rest, to be promoted after the sibling's PR merges.
- **`scripts/promote-ready-smoke-tests.sh`** — thirteen offline scenarios (T1–T13): graph load,
  unblocked/wave computation, non-Done blocker stays blocked, collision guard defers a same-folder
  sibling, `--dry-run` makes no mutation (isolated via `--yes` so the dry-run gate — not the
  non-TTY guard — is the tested gate), forward-only skip, live promote of exactly the recommended
  set, the `stories.json` sequence→githubIssue fallback, off-board promotability, an **unfiled**
  `stories.json` blocker keeping the dependent issue blocked, dependency-cycle termination, the
  empty-graph `(no issues in graph)` message, and a clean no-such-slug run on bash 3.2. Fully
  offline via `MAKATO_PROMOTE_GH_OVERRIDE` + `MAKATO_PROMOTE_EDIT_TEST_FILE` — `gh` is never
  invoked. Wired into `.github/workflows/validate.yml`.
- **Hardened against nine adversarially-verified defects** (independent review + verify pass):
  a CRITICAL where an unfiled `stories.json` `blockedBy` sequence was silently dropped (dependent
  issue wrongly appeared unblocked — now kept blocked as an unresolved predecessor); a TOCTOU where
  `_promote_one` wrote `Ready` unconditionally and could roll a concurrently-claimed `In progress`
  card backward (now a re-poll compare-and-set skips a card that moved off `Todo`/`Blocked` since
  the snapshot); a topological-level miscount for cyclic graphs (cycle sentinel is now memoized so
  parent frames don't overwrite it); the `--dry-run` test being vacuous (the non-TTY guard, not the
  dry-run gate, was holding it — now bypassed via `--yes`, with a meta-test confirming it catches a
  dry-run-gate regression); a bash 3.2 empty-array crash under `set -u` in `_collect_graph_files`;
  a malformed synthesized fallback URL that silently failed `item-add` for off-board `stories.json`
  issues (now `item-add` only with a real URL, else an actionable WARN); an inflated `issue_count`
  in the report; and the dead empty-graph message branch.

## `loop.sh` — board-poll rate-limit is no longer an unmitigated SPOF (#289)

Fixes a MEDIUM-severity availability bug. The board poll (`gh project item-list`) is the loop's
single point of contact with the GitHub API, and every caller degraded a `gh` non-zero exit to
`echo '{"items":[]}'`. A 429 (rate-limit) or transient 5xx therefore read downstream as an
**empty queue**: a rate-limited loop logged "queue empty" and idled the full interval while
Ready work sat undispatched, with the audit showing a healthy idle loop and masking the outage.
On the `_claim_board_card` re-poll the same idiom additionally warn-proceeded on an unreadable
board, re-opening the pre-#259 double-dispatch race.

- **`scripts/loop.sh`** — new `_gh_project_item_list` wrapper adds bounded exponential-backoff
  retry (`MAKATO_LOOP_POLL_RETRIES`, default 3; `MAKATO_LOOP_POLL_BACKOFF_BASE`, default 2s) and,
  crucially, distinguishes "poll failed" from "queue empty": on exhaustion it returns non-zero
  and prints nothing rather than a fabricated empty payload. `cmd_poll` propagates that as rc 75
  (`EX_TEMPFAIL`); `cmd_run` stamps a distinct transient-error state (`poll_healthy:false`,
  `last_poll_error`) into `loop-status.json`, skips dispatch that tick, and re-polls after a short
  `MAKATO_LOOP_POLL_ERROR_BACKOFF` (default: `--interval`) instead of the full idle interval.
  `_claim_board_card` now SKIPs the claim (returns 1) on a failed re-poll rather than warn-
  proceeding, so a transient read failure can never re-open the double-dispatch race.
- **`scripts/loop-smoke-tests.sh`** — T39–T42 added: retry rides out a transient blip; exhaustion
  returns non-zero with empty stdout; `cmd_poll` surfaces rc 75; `run --once` records the
  transient-error state and never logs a false "queue empty". Fully offline via
  `MAKATO_LOOP_POLL_TEST_CMD` + `MAKATO_LOOP_SLEEP_CMD=true`.

---

## `loop.sh` — halted issue excluded from Ready re-promotion (#286)

Fixes a MEDIUM-severity dual-source-of-truth bug. Every HALT path applies `needs-human-review`
but never strips `status:ready-for-dev`, and the pre-poll promotion pass
`_promote_labelled_ready` did not treat `needs-human-review` as a promotion veto. So a halted
issue kept getting dragged back onto Status=Ready, where the in-flight guard
(`workflow-state-<N>.json` non-done) then refused to dispatch it — leaving the card stuck on
Ready every tick, wasting polls and obscuring the real queue until an operator intervened.

- **`scripts/loop.sh`** — `needs-human-review` added to `_PROMOTE_EXCLUSION_LABELS` (the veto
  filter that already excludes `triage experimental status:blocked autonomous:halt`). A halted,
  human-review-pending issue is now skipped by the promotion pass until a human clears the label;
  the recovery path (clear label → issue promotes to Ready normally) is intact.
- **`scripts/loop-smoke-tests.sh`** — T28 extended with fixture `#606`
  (`status:ready-for-dev` + `needs-human-review`) asserting it is NOT promoted, alongside the
  existing four exclusion-label cases. Full loop suite passes.

---

## `workflow-state.sh` — worktree-safe `specs/` resolution (#282)

Fixes a HIGH-severity split-tree bug. `workflow-state.sh` resolved `REPO_ROOT` with a bare
`git rev-parse --show-toplevel`, which returns the **worktree** path when the helper is invoked
from inside a per-run worktree (the normal autonomous-run condition — NEVER 10). Because
`specs/` is gitignored, a fresh `git worktree add` has no `specs/` content, so the sole-writer
state helper wrote `workflow-state-<N>.json` under the worktree's `specs/`, while the sibling
`build-log.sh` (already worktree-safe via `--git-common-dir`) appended `build.jsonl` under the
main checkout's `specs/`. State and audit trail split across two disconnected trees; a resume
from the main checkout saw `{}` and the run's audit was orphaned.

- **`shared/workflow-state.sh`** — `REPO_ROOT` now derives from the COMMON git dir
  (`git rev-parse --git-common-dir`), mirroring `plugins/makato-build/shared/build-log.sh:34-42`
  byte-for-byte, with the same outside-a-repo fallback to `--show-toplevel`. Non-worktree
  callers are unaffected (the common dir and top-level resolve to the same root). The intentional
  duplication of spec-folder resolution between the two helpers (documented in AGENTS.md) is
  preserved — one copy had been fixed to `--git-common-dir` and the other had not; this closes
  the drift.
- **`shared/worktree-smoke-tests.sh`** — adds T19, a hermetic regression: invokes `init` from
  inside a real worktree and asserts the state file lands in the main checkout's `specs/`, never
  the worktree's. 19/19 pass.

---

## `context-handoff.sh` / `workflow-state` — HALT-007B evaluates per-session delta (#281)

Fixes a CRITICAL restart-storm: after a HALT-007B context handoff, `budget_consumed_tokens`
was never reset, so the resumed session re-evaluated the ceiling on its first outer-loop
boundary, handed off again, and burned through `MAKATO_MAX_HANDOFFS` (default 5) back-to-back
spawns before firing HALT-007 — the soft-handoff mechanism never delivered its purpose.

- **`shared/workflow-state.sh`** — `init` now seeds a new `session_baseline_tokens: 0` field.
- **`skills/workflow-state/references/workflow-state.schema.json`** — added the
  `session_baseline_tokens` property (integer ≥ 0). Left OUT of `required` so in-flight state
  files predating #281 still validate; readers default it to 0.
- **`scripts/context-handoff.sh`** — `check` now compares the **per-session delta**
  (`budget_consumed_tokens - session_baseline_tokens`) against `context_warn_tokens` instead of
  the cumulative total. On handoff it advances `session_baseline_tokens` to the current
  `budget_consumed_tokens`, so the resumed session's delta restarts at 0. The cumulative
  `budget_consumed_tokens` is left untouched — the HALT-007 per-task and daily **cost** ceilings
  keep evaluating the true lifetime total (resetting it, the naive fix, would have silently
  disabled cost control). Audit entries gain `session_baseline_tokens` and `session_delta_tokens`.
- **`scripts/context-handoff-smoke-tests.sh`** — added T8 (resumed session below the delta
  threshold → no-op, storm prevented), T9 (delta above threshold still hands off; baseline
  advances), T10 (absent `session_baseline_tokens` on pre-#281 state defaults to 0). 10 tests.
- Docs: `halt-conditions.md`, `skills/kill-switch/SKILL.md`, `skills/workflow-state/SKILL.md`,
  and `agents/po-agent.md` updated to describe the delta semantics and the cumulative-vs-session
  split.

---

The HALT-CH-001 … HALT-CH-004 table added in #144 (see the *makato-change autonomous
path integration* block below) documented triggers and severities that **never matched**
the skills that actually emit these codes. The orchestrate-side table has been rewritten
to mirror `plugins/makato-change/AUTONOMOUS-MODE.md` and the ground-truth skill sources
(`analyze/SKILL.md`, `design/SKILL.md`, `execute/SKILL.md`):

- **HALT-CH-001** — was "analyze blocked by requirements conflict"; is **headless repo
  discovery failure** (`REPO_ROOT` absent AND no `repositories.yml`). `failure`.
- **HALT-CH-002** — was "design blocked, scope > 15 files"; is **critical blocking question
  in analyze Step 8**. `failure`.
- **HALT-CH-003** — was "execute with suppressed quality findings"; is **design
  auto-approved in autonomous mode** (audit marker, run continues). `audit`.
- **HALT-CH-004** — was "resolve-review retry budget exhausted" (a code that could never
  fire — `resolve-review` is excluded from autonomous mode); is **no test infrastructure
  in headless execute** (degraded confidence, run continues). `degraded`.
- Added a *single source of truth* note pointing at `AUTONOMOUS-MODE.md`, split the two-row
  category table into the three severities the pipeline actually emits (`failure` / `audit`
  / `degraded`), corrected the audit-shape example, and added AUTONOMOUS-MODE.md to *See also*.
- No skill or script behaviour changed — this is a documentation-accuracy fix only.

---

## loop 1.8.0 — reaper landed-detection fix: ancestry + tracked-only dirty + nested-child (#265)

The 1.7.0 reaper left worktrees un-reaped that should have been removed. A live
run over 32 real worktrees surfaced two false negatives and one latent hazard:

- **Renamed-head / squash-merged branches were missed.** The merged-PR check
  keyed solely on `gh pr list --head <branch>`, so a branch whose PR head was
  renamed (or whose local branch name never matched the PR) looked un-merged
  even though its commits were long in `main`. **Fix:** guard 8 now treats a
  worktree as *landed* on either signal — a merged PR **or** `HEAD` being a
  strict ancestor of the base ref (`git merge-base --is-ancestor`). A worktree
  sitting exactly on the base tip (freshly branched, no commits) is explicitly
  *not* landed, so a new empty workspace still survives. New
  `MAKATO_LOOP_REAP_BASE_REF` override (default `origin/HEAD` → `origin/main`).
- **Untracked scratch pinned worktrees forever.** Guard 6 skipped on any
  `git status --porcelain` output, so a single generated file (e.g. a built
  `*.html`) kept a fully-merged worktree alive indefinitely. **Fix:** guard 6
  now ignores untracked `??` entries and vetoes only on uncommitted **tracked**
  changes — real work still pins, scratch does not.
- **Nested-child worktrees could be removed inside a live parent.** Guard 3
  only skipped the *parent* of a nested worktree; the ancestry fix newly made
  the *children* (worktrees registered under another worktree's
  `.claude/worktrees/`) removal candidates, and deleting one there corrupts the
  parent. **Fix:** guard 3 now skips both directions — parent-of-nested and
  child-nested-inside-another-worktree — while correctly treating the main
  checkout owning `.claude/worktrees/` as the normal (non-nested) layout.
- **Audit field** `reaped[].pr` → `reaped[].landed` (a reason string, e.g.
  `merged PR #206` or `ancestor of origin/main`).
- **New smoke tests T36–T38** (ancestry-landed with no PR + fresh-on-tip
  survives; untracked-only scratch reaped; nested parent & child both skipped).
  T31/T32 updated for the tracked-only-dirty and landed semantics.
- **SKILL.md 1.7.0 → 1.8.0**: guard stack (3/6/8) rewritten,
  `MAKATO_LOOP_REAP_BASE_REF` documented, `reaped[].landed` field, three new
  smoke-test entries.

---

## loop 1.7.0 — auto-reap merged worktrees (#265)

Git worktrees under `.claude/worktrees/` accumulate on the operator's local disk
(a live audit found 31 registered, the sampled majority from long-merged PRs).
The PO-agent's `worktree.sh cleanup` only fires for a fully autonomous run that
reaches merge in its own session; hand-created (`EnterWorktree`) or session-
orphaned worktrees carry no `workflow-state` and were never removed.

- **New `_reap_merged_worktrees` pre-poll pass in `loop.sh`.** Walks
  `git worktree list --porcelain` and removes worktrees whose branch has a
  **merged** PR (`gh pr list --state merged`). Runs locally — a cloud GitHub
  Action cannot reach the operator's disk. Wired into `cmd_run` after the #231
  promotion pass and before the board poll; also exposed as the standalone
  `remove-worktrees` subcommand.
- **8-layer guard stack.** A worktree is removed only when it is not the main
  checkout, lives under `.claude/worktrees/`, is not the parent of a nested
  worktree, is not `locked`, is not a detached HEAD, has a **clean** working
  tree, is not `worktree_retained`, and its branch has a merged PR. The
  clean-tree and `git worktree lock` guards are the reliable operator pins;
  `worktree_retained` vetoes only when a `workflow-state` maps to the worktree.
- **Throttled + best-effort.** Self-throttled to at most once per
  `MAKATO_LOOP_REAP_INTERVAL` (default 3600 s) via the `last_reap` stamp, so it
  is a no-op on most ticks. Any `gh`/`git` failure logs a WARN and never blocks
  the tick.
- **Opt-out** `MAKATO_LOOP_REAP_ON_POLL=0`. **Offline test hooks**
  `MAKATO_LOOP_REAP_GH_OVERRIDE` (merged-PR map), `MAKATO_LOOP_REAP_WT_OVERRIDE`
  (canned porcelain), `MAKATO_LOOP_REAP_DRYRUN`, `MAKATO_LOOP_REAP_REPO`.
- **New status fields** `last_reap`, `last_reap_count`, `reaped[]` in
  `loop-status.json`.
- **New smoke tests T31–T35** (dry-run decision set, live removal + audit,
  retained guard, opt-out, throttle) — fully offline via a disposable temp repo.
- **SKILL.md 1.6.0 → 1.7.0**: new §*Pre-poll merged-worktree reap*, Process
  step 3, `remove-worktrees` subcommand, six env vars, three status fields, and
  the T31–T35 smoke-test entries.

---

## loop 1.6.0 — synchronous board claim closes cross-worktree double-dispatch (#259)

Two concurrent `loop run` sessions in different worktrees on the same host could
both dispatch the same `Ready` issue: the run-mutex pidfile is `$STATE_DIR`-scoped,
the in-flight filter is `specs/`-scoped, and the only cross-session signal — the
board `Status` — was moved `Ready → In progress` only asynchronously by the
`issues.assigned` → `project-board-sync.yml` webhook. That async gap was the race
window. The loop now claims the board card itself, synchronously, before spawn.

- **New `_claim_board_card` compare-and-set.** Just before dispatch, the loop
  re-polls the issue's board `Status` and, only if it is still `Ready`, sets it to
  `In progress` via `gh project item-edit` (field + `in_progress` option ids from
  `.claude/config.json`). If the re-poll shows the card is no longer `Ready`, a
  second session already claimed it → the issue is skipped (exit 0, no spawn, no
  assign, `active_workflow` cleared). This makes the board the shared **lock**, not
  just the shared **queue**.
- **Forward-only + best-effort.** The claim only ever writes *from* `Ready`, so it
  can never roll a card back from `In review`/`Done` and never races
  `issue-to-project sync-lifecycle` (which still owns `In review`/`Done`). Any
  inability to read the current Status (`gh` outage, missing config, empty board)
  logs a `WARN` and **proceeds** — degrading to the pre-#259 assign-only behaviour
  rather than blocking dispatch.
- **Invariant revised.** The previous "loop is strictly read-only against the
  board" invariant is replaced: the loop now owns the `Ready → In progress` claim.
  The assign-on-dispatch step (#33) is retained as a redundant belt-and-braces
  webhook trigger.
- **Opt-out** `MAKATO_LOOP_CLAIM_ON_DISPATCH=0` disables the claim (the
  cross-worktree race re-opens; leave enabled in multi-worktree setups).
- **New smoke test T30** (four sub-assertions: claim / skip / warn-proceed /
  disabled), fully offline via `MAKATO_LOOP_CLAIM_TEST_FILE` +
  `MAKATO_LOOP_CLAIM_STATUS_OVERRIDE`. SKILL.md updated (§*Board writes at
  dispatch: the synchronous claim*, Single-thread guarantee now five layers).

---

## po-agent — live progress comment on the driven issue

Adds a human-readable narration layer over the machine `orchestrate.jsonl` /
`build.jsonl` audit, which lives under gitignored `specs/` and is invisible to
anyone watching the issue on GitHub. The PO-agent now mirrors the START and DONE
of every skill it dispatches into a single, continuously-edited GitHub issue
comment, written in plain English and timestamped per entry.

- **New `shared/progress-comment.sh`** with three subcommands (`start` / `done` /
  `note`). It creates the live comment on first call, appends on later calls, and
  rolls over to a fresh comment near GitHub's 65 536-char limit. START entries
  name the skill, its input, the sub-agent used, and a one-line goal; DONE entries
  carry the result and a short summary. Fully offline-testable via a `gh` stub.
- **Best-effort, never fatal.** Any `gh` or state failure logs a WARN, emits a
  `step:"progress-comment"` JSONL row, and exits 0 — it never triggers a HALT and
  never blocks a dispatch. Opt-out with `MAKATO_PROGRESS_COMMENT_DISABLE=1`.
- **State surface.** One new field `progress_comment_id` (integer or null) added
  to `workflow-state.schema.json` and the `init` default. It is written only
  through `shared/workflow-state.sh`, so the PO-agent remains the sole writer of
  `workflow-state.json`.
- **po-agent.md** wires `start`/`done`/`note` into the existing dispatch anchors
  (Steps 2, 4d, 4e, 4f, 6, Error modes) and documents the per-skill agent/goal map
  in a new § *Progress comment* section.
- **Tests.** New `shared/progress-comment-smoke-tests.sh` — 9 scenarios / 24
  asserts, fully offline (`MAKATO_PC_GH_STUB`).

---

## loop — non-to-issues issues enter the loop unattended (#231, #232)

Closes the two sibling gaps that kept a hand-filed or auto-filed (testbox/CI) issue off
the autonomous loop unless an operator ran `seed-issue` by hand. Both fixes land in
`scripts/loop.sh` + `loop-smoke-tests.sh`; the loop smoke suite is now wired into CI.

- **`loop` 1.4.0 → 1.5.0**
  - **#232 — KEY provenance fallback.** `_derive_key_for_issue` gains a third fallback:
    when the issue body carries neither the `to-issues` footer nor a
    `specs/<slug>/stories.json` line, it derives `<issue-number>-<normalized-title>` (the
    exact `seed-issue` SLUG convention) from the issue title, so the po-agent dispatch
    bundle no longer carries an empty KEY. Reached only when both provenance patterns miss
    — to-issues issues are unchanged. New `MAKATO_LOOP_ISSUE_TITLE_OVERRIDE` test hook.
  - **#231 — pre-poll label→board bridge.** `run` now runs `_promote_labelled_ready`
    before each poll (default `Ready` status only): open `status:ready-for-dev` issues that
    are off-`Ready` and not carrying an exclusion label (`triage`, `experimental`,
    `status:blocked`, `autonomous:halt`) are promoted to `Status=Ready` via
    `gh project item-edit` — the same mutation `seed-issue` uses — so a labelled non-to-issues
    issue enters the queue without a manual `seed-issue` run. Best-effort: a `gh` failure or
    missing config logs a WARN and never blocks the tick. Also exposed standalone as
    `loop promote-ready`. New `MAKATO_LOOP_PROMOTE_OVERRIDE` / `MAKATO_LOOP_PROMOTE_DRYRUN`
    test hooks.
  - **Tests + CI.** `loop-smoke-tests.sh` gains T27 (KEY fallback + regression + title
    normalization) and T28 (promotion pass + exclusion guard), both offline via the new
    override hooks. The full suite (T1–T28) is now run in `.github/workflows/validate.yml`
    — previously the loop smoke tests had no CI gate.



- **Fixed** `Post-merge spec archive` GitHub Actions workflow failed on every feature-branch merge with `claude: command not found` (exit 127) — the `Setup Claude CLI` step was a placeholder that installed nothing, so the `claude --print …` archive invocation had no binary on `PATH` (#221). Replaced the LLM-driven runner path with a deterministic bash port, `scripts/archive-spec.sh` (+ `archive-spec-smoke-tests.sh`, 9 offline scenarios): it derives the spec slug from the issue body's `to-issues` provenance (same logic as `loop.sh`), resolves `specs/<slug>/` or `specs/<slug>-*/`, appends an Evolution Log row to the master spec, moves the folder to `specs/archive/<date>-<folder>/`, and closes the issue idempotently. No Claude CLI, no `ANTHROPIC_API_KEY` secret, no per-merge LLM cost — consistent with the D5 "no LLM in the runner" constraint. Tolerates the gitignored-`specs/` case (folder absent on the runner → issue-close is the durable effect, exit 0). The `archive-spec` SKILL remains the source of truth for the interactive/model-driven path (semantic requirement extraction, OBSOLETE path, conflict handling). `archive-spec` SKILL 1.0.0 → 1.1.0; `.github/workflows/archive-spec.yml` + `workflows/archive-spec.yml` template + `references/archive-spec-workflow.md` updated.
- **Fixed** `scripts/loop.sh` dispatch — long unattended builds were killed mid-run (#146 regression). Two coupled causes: (1) the dispatch prompt delegates to the po-agent via the Task tool, which in claude >= 2.1.x runs the subagent as a *background* task, and the top-level `-p` session terminated it after the default 600 s `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` ceiling — killing a full build cycle 10 min in; (2) the plain `--output-format text` format flushes nothing until session end, so the log mtime stayed frozen and the liveness watchdog stall-killed the po-agent after 60 min. Fix: set `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (wait indefinitely; watchdog + HALT poll remain the bounding mechanisms) and switch the watched production path to `--output-format stream-json --verbose` for a live per-event mtime signal. The `MAKATO_LOOP_STALL_DISABLE=1` opt-out path keeps `text` (operator watches the terminal) but also gets the ceiling override.
- **Added** `config/skill-bundles.yml` (#145) — bundles `orchestrate-skills`, `orchestrate-workflow-state`, `orchestrate-shared` route workflow-state JSON/JSONL files and orchestrate bash helpers to the workflow-state/kill-switch/session-status skills.

---

## po-agent — HALT-006 auto-materialize on fresh clone (#200)

- **Added** `scripts/should-materialize-spec.sh` + `scripts/should-materialize-spec-smoke-tests.sh`
  (12 asserts) — deterministic gate that decides whether the PO-agent's Step 1 should
  auto-materialize a missing `plan.md` or fall through to HALT-006. Emits `materialize`
  (missing/stub plan AND `plan-tier:light`), `proceed` (plan already valid — not a HALT-006
  case), or `halt` (missing/stub plan without `plan-tier:light`). Classifies the HALT-006
  sub-cause by delegating to `validate-plan-body.sh` (the same guard the lightweight lane
  uses), so the two never disagree about "stub"/"empty". Pure bash, offline.
- **Changed** `agents/po-agent.md` Step 1 — before firing HALT-006 on a missing spec folder
  or stub `plan.md`, the PO-agent now runs Step 1a: for a `plan-tier:light` issue it writes
  a seed stub (mirroring seed-issue Step 8), dispatches the `light-planner` agent to
  synthesize a real `plan.md` from the issue body, re-validates with `validate-plan-body.sh`,
  and on a valid plan sets `spec_tier:plan-only` and retries Step 1 **once**. A thin-body /
  hollow-plan result, a non-`plan-tier:light` issue, or a second Step 1a entry falls through
  to the existing HALT-006 → `needs-human-review` path. Each attempt emits a
  `step:"materialize-spec"` `orchestrate.jsonl` entry (issue #200 point 5 — never silently
  masks a planning gap). Fixes the fresh-clone dead-end: `specs/` is gitignored scratch, so
  the plan.md seed-issue wrote locally never travels with a clone, and every autonomous
  small-fix run previously hit HALT-006 at Step 1. Reconciles #200's original
  `build-refine`/`type:fix` proposal to the taxonomy that shipped after it (lightweight lane
  #210–#212): `light-planner` is the plan synthesizer (build-refine cannot materialize from a
  raw issue), and `plan-tier:light` is the eligibility signal (`type:fix`/`type:bug` labels
  do not exist).
- **Extended** the PO-agent Write/Edit allow-list from four to five paths — Step 1a writes the
  seed stub `plan.md` + `seed-manifest.json` under gitignored `specs/`. Documented in
  `po-agent.md` § *Rules*, `never-patterns.md` NEVER 4, and `AGENTS.md` § *Security Model*.

---

## seed-issue — 1.2.0 · light-planner agent + plan-gated promotion (#212)

- **Added** `agents/light-planner.md` (net-new, sonnet) — the lightweight planning
  lane's plan producer. Given a `plan-tier:light` issue body + bounded target-repo
  context, it generates a full `plan.md` (non-empty `## Tasks` + `## Acceptance
  criteria`, not the HALT-006 stub) that `build-refine`'s plan-only path (#210)
  consumes as its sole acceptance source. Runs locally under the operator's Claude
  at seed time (D3 — free, reviewable in git before dispatch). Carries a
  minimum-viable-body guard: a too-thin body yields NO plan.md and a
  `data.thin_body:true` R1 so seed-issue re-tiers to full.
- **Added** `scripts/validate-plan-body.sh` + `scripts/validate-plan-body-smoke-tests.sh`
  (13 asserts) — deterministic promotion guard. Emits `valid ok` only when both
  `## Tasks` and `## Acceptance criteria` carry non-placeholder content; the seed
  stub, empty sections, HTML comments, template tokens, and the `_To be filled in…_`
  placeholder all return `invalid`. This is the machine-checkable half of the lane —
  it, not the agent's R1, is the source of truth for "promotable".
- **`seed-issue` → 1.2.0** — restructured board promotion for the lightweight lane.
  New **Step 2.5** detects the `plan-tier:*` label; new **Step 8.5** dispatches
  light-planner, validates the written plan with `validate-plan-body.sh`, and only
  then (guard `valid`) writes `spec_tier:plan-only` into `seed-manifest.json` and
  promotes the card to `Ready`. **Step 7 promotion is now deferred** for
  `plan-tier:light` new-work (it previously promoted ALL new-work unconditionally
  before any plan existed — the window that let the po-agent dispatch a stub and fire
  HALT-006). Thin-body / hollow-plan fallback: no plan.md, no `spec_tier`, card stays
  at `Todo`, issue re-tiered to `plan-tier:full`, `status:ready-for-dev` removed,
  clear message, exit 0. Partial-write recovery (plan valid but board move failed) is
  a safe `seed-issue` re-run. The standard path (`plan-tier:full|change|none`) is
  unchanged byte-for-byte. Soft dep on #211: absent `plan-tier:light` label → standard
  path; operators may apply the label by hand before #211 ships.



- **`seed-issue` → 1.1.0** — `seed-manifest.json` `schema_version` bumped `"1" → "2"`.
  v2 adds the single **optional** `spec_tier` field (`"plan-only"` marks the lightweight
  planning lane; consumed by `build-refine` to source acceptance criteria from `plan.md`).
  The change is fully backwards-compatible: a v1 manifest and a v2 manifest with `spec_tier`
  absent are treated identically by every consumer. The default `new-work` path leaves the
  field unset; only the `plan-tier:light` path (light-planner integration, tracked
  separately) writes it. Documented the full manifest schema table in `SKILL.md` Step 8.

---


## makato-change autonomous path integration (#144)

Wires the `makato-change` autonomous pipeline into the loop/po-agent dispatch surface and
documents the corresponding halt conditions.

- **`seed-issue` skill 1.0.0** — new skill: given a GitHub Issue tagged `status:ready-for-dev`
  whose body identifies it as a change request (label `type:change` or `change-request` in the
  title prefix), the skill resolves the target repository, seeds an initial `change-state.json`,
  and returns the `KEY`/`REPO`/`REPO_ROOT` bundle consumed by the `orchestrate --autonomous`
  dispatch path. Replaces the ad-hoc body-parsing that `loop.sh` was doing for change-type
  issues.
- **`loop.sh` disambiguation + routing** — `_classify_issue_type` helper added; issues whose
  body contains `<!-- change-request -->` or carry the `type:change` label are routed to
  `makato-change:orchestrate --autonomous` instead of the PO-agent. PO-agent path unchanged.
  New test hook `MAKATO_LOOP_ISSUE_TYPE_OVERRIDE` keeps the routing smoke test offline.
- **`loop` skill 1.5.0** — bump from 1.4.0; dispatch-prompt template gains a `ROUTE` field
  (`"po-agent"` or `"change-orchestrate"`) derived by `_classify_issue_type`; skill docs updated
  to explain the two dispatch paths.
- **`halt-conditions.md`** — HALT-CH-001 through HALT-CH-004 added for the `makato-change`
  autonomous path. **Note:** the triggers described in this historical entry were later found
  to be inaccurate and were corrected — see the *HALT-CH-* taxonomy corrected* entry at the top
  of this changelog for the authoritative definitions.

---

## `loop.sh` po-agent dispatch bundle — KEY/BRANCH derivation (#144)

Closes the contract gap that crashed the autonomous dispatch of #144. The
loop's `cmd_dispatch` passed only the issue number to the po-agent, but
`agents/po-agent.md` requires `KEY`, `REPO`, `BRANCH`, `REPO_ROOT` and
refuses to request missing inputs — so every autonomous dispatch failed
immediately with `missing input: KEY`, never reaching real work.

- **`loop` skill 1.4.0** — the dispatch prompt now carries the full
  po-agent input bundle (`ISSUE_NUMBER`/`KEY`/`REPO`/`BRANCH`/`REPO_ROOT`).
- **`scripts/loop.sh`** — new `_derive_key_for_issue` helper reads the
  issue body and extracts the feature slug from the `to-issues` provenance
  (footer `*Feature slug: …*`, falling back to the top-of-body
  `specs/<slug>/stories.json` line); `BRANCH` is derived as
  `feat/<issue>-<KEY>`; `REPO`/`REPO_ROOT` are threaded from the existing
  poll result and script global. Derivation failure degrades to a `WARN`
  with empty `KEY` (the po-agent then surfaces the input-validation
  failure with a clear audit) rather than dispatching blind. New test hook
  `MAKATO_LOOP_ISSUE_BODY_OVERRIDE` keeps the KEY-derivation smoke test
  offline.
- **`scripts/loop-smoke-tests.sh`** — new **T25** (three sub-assertions:
  primary footer derivation, `stories.json` fallback, WARN-on-missing
  degradation). Full suite (25 scenarios) passes.

---

## `archive-spec` skill + GHA workflow — post-merge spec lifecycle

- **1.0.0** — new skill: archive completed features (master spec merge + `gh issue close`) and
  mark obsolete specs; migrated from `makato-plan` (wrong plugin); removes all `.daff/` and
  `mcp__dcp-jira__*` tooling; uses `gh` CLI only
- **`workflows/archive-spec.yml`** — GHA consumer template; fires on `pull_request.closed`,
  extracts `Closes/Fixes/Resolves #N`, runs skill headless via `claude --print`
- **`.github/workflows/archive-spec.yml`** — same workflow wired into this repo

---

## PO-agent post-dispatch audit-tail guard + `HALT-011` (#175)

Closes the outer-loop half of the audit-contract gap fixed on the sub-skill
side by #169 / PR #174. Before this PR a `build-*` sub-skill that emitted a
terminal `step:"session" status:"error"` line to `build.jsonl` but then
died mid-R1 left the PO-agent with `failure` and no `halt_code` — the
route table in `plugins/makato-build/halt-codes.md` had nothing to key
against. The autonomy guarantee reproduced by #143 quietly broke.

- **`shared/check-session-tail.sh`** — new read-only helper. Given a
  work-item key and a sub-skill name, reads the last N lines of the
  resolved `specs/<key>-*/build.jsonl` and emits a single JSON object
  with `verdict ∈ {ok, error, silent, no-log}` plus `halt_code`,
  `last_step`, `last_status`, and `session_start_present`. Resolution
  logic mirrors `build-log.sh` so the guard never disagrees with the
  writer about the target file. `MAKATO_BUILD_JSONL_OVERRIDE` is a test
  hook that pins the file path so fixtures live outside `specs/`.

- **`shared/check-session-tail-smoke-tests.sh`** — 10 fixture-driven
  tests covering the four verdicts, an idempotency guarantee, tail
  isolation across interleaved skills, `data.halt_code`-absent belt-and-
  braces, and a malformed-line survival test (regression against a
  fragile `-c -s` pipeline). All green:
  - **T1** `session:ok` → `verdict:ok` (AC3 happy path).
  - **T2** `session:error` with `data.halt_code` → `verdict:error`
    surfacing the code (AC1).
  - **T3** `session:start` but no terminal — the #143 repro shape →
    `verdict:silent` (AC2).
  - **T4/T5/T10** empty file / wrong skill / missing file → `no-log`.
  - **T6** `session:error` without `data.halt_code` → `verdict:error`
    with `halt_code:null` — PO-agent falls back to R1 `errors[]` parse.
  - **T7** multi-skill interleaving — a silent `build-create-pr` is
    correctly attributed even after `build-verify` and
    `build-push-to-git` both cleanly closed.
  - **T8** idempotent — repeated invocations produce identical output.
  - **T9** malformed line in tail is skipped (uses `inputs | fromjson?`
    on `-R` stream — no `-s` slurp that would crash on any non-JSON byte).

- **`agents/po-agent.md`** — new § *Step 4d.1 — Post-dispatch audit-tail
  guard (#175)* between Step 4d and Step 4e. Documents the verdict →
  response table, the four design invariants (additive, idempotent,
  no network I/O, `halt_code` tail-recovery updates state), and the
  JSONL audit-line schema. HALT / label matrix gains a `HALT-011` row.

- **`halt-conditions.md`** — new `HALT-011` row in the code table.
  Trigger: `check-session-tail.sh verdict:"silent"` on a `build-*`
  dispatch. Action: `needs-human-review`, `halt_audit[]` gets
  `{skill, last_step, last_status}`, worktree retained. Recovery: read
  the truncated `build.jsonl` for forensics, decide sub-skill contract
  fix vs re-run. Chosen over the issue-body-suggested `HALT-007B` label
  because that code is already allocated (context-ceiling handoff, no
  label, self-restart) with opposite semantics — sharing the code would
  break the label-vs-no-label invariant documented in the § *Why
  HALT-007 and HALT-007B are different codes* section of
  `halt-conditions.md`.

---

## `loop.sh` sleep-wake dispatch guard (#171)

Fixes the incident documented in #171: after a macOS host sleep of ~6.5 h
mid-run, `loop.sh` woke and emitted 35× `dispatching issue #145` log lines
in the same second, forking that many `exec claude -p` subprocesses against
the same issue. Root cause: naive `sleep "$interval"` in `cmd_run` can
return early when the kernel timer collapses across suspend/resume, and
`cmd_dispatch` had no idempotence check — every re-entry re-stamped
`active_workflow` and forked another PO-agent. Token cost inflation,
telemetry pollution, and `workflow-state.json` write races followed.

- **`scripts/loop.sh`** — two layered guards land:
  1. **`_guarded_sleep`** replaces the bare `sleep "$interval"` at the end
     of `cmd_run`'s poll loop. It re-enters raw sleep in ≤
     `MAKATO_LOOP_SLEEP_MAX_STEP`-second chunks (default 30 s) until
     `$(date +%s)` has advanced by the requested total — a wall-clock
     guarantee that survives early-return sleeps. `MAKATO_LOOP_SLEEP_CMD`
     is a test hook that substitutes the inner `sleep` command so smoke
     tests can simulate the macOS behaviour in ~1 s wall-clock.
  2. **Idempotent-dispatch guard in `cmd_dispatch`.** New helper
     `_within_dispatch_guard` composes two predicates:
     - **A** — `active_workflow.issue == target` AND
       `_seconds_since(active_workflow.started_at) < MIN_DISPATCH_GAP_SECS`
       (default 30). Covers the "same issue still in flight from a prior
       cmd_dispatch that has not yet returned" case — the exact 35×
       burst scenario.
     - **B** — `.last_dispatch_issue == target` AND
       `_seconds_since(.last_dispatch_at) < LAST_DISPATCH_GAP_SECS`
       (default 30). Covers the "same issue just dispatched, PO-agent's
       state write races with next poll" case. `last_dispatch_at` is
       now stamped on every real dispatch attempt, not only in
       `MAKATO_LOOP_DRY_DISPATCH` mode.

     Both predicates use *time since a timestamp*, never a boolean, so
     a crashed dispatch that left `active_workflow` populated reclaims
     after the guard window elapses. Guard-refuse exits **0** with a
     single stderr line explaining the skip — distinct from the
     pre-existing exit-2 "different issue in flight" branch, which
     stays intact. The outer `cmd_run` treats the exit-0 as a normal
     completion and sleeps the full interval before the next poll.
  3. Header env-var comment block gains a `# --- Sleep-wake guard
     (#171) ---` section documenting `MAKATO_LOOP_SLEEP_MAX_STEP`,
     `MAKATO_LOOP_MIN_DISPATCH_GAP`, `MAKATO_LOOP_LAST_DISPATCH_GAP`,
     and the `MAKATO_LOOP_SLEEP_CMD` test hook.

- **`scripts/loop-smoke-tests.sh`** — three new scenarios (T19–T21)
  raise the smoke count to 21. T19 asserts `_guarded_sleep 2` burns
  ≥ 2 s wall-clock even when the inner sleep is replaced by a
  ~instant `sleep 0.1`. T20 asserts the in-flight guard preserves
  `active_workflow.started_at` byte-for-byte and skips the dispatch
  body. T21 covers both the release (stale `.last_dispatch_at`) and
  fire (fresh same-issue `.last_dispatch_at`) branches of predicate B.
  Whole suite runs in ~15 s wall-clock.

- **Explicit non-goals.** Fix 3 from the issue (`pmset`-based suspend
  detection) is deferred — if T19–T21 leave residual dispatch bursts
  under a real macOS sleep-wake, file a follow-up. `_watchdog_poll`
  (#164) and `_acquire_run_mutex` (#172) are untouched.

---

## `workflow-state` per-issue file layout (#173)

Fixes the incident documented in #173: the `agent-skill-routing` story spans
issues #143–#147, all sharing `specs/agent-skill-routing/` and therefore the
same `workflow-state.json`. When `loop.sh` dispatched #144 at 02:34 CEST on
2026-07-08 (after #143 completed at 01:53), the second `init` call overwrote
the state file — #143's `sub_tasks[]`, `halt_audit[]`, and `lessons_learned[]`
were permanently lost. Every multi-issue story with a shared spec folder was
one dispatch away from the same data loss, and two concurrent PO-agents
racing on the same file would corrupt state without any lock.

- **`shared/workflow-state.sh`** — state file layout changed from
  `specs/<KEY>/workflow-state.json` to
  `specs/<KEY>/workflow-state-<ISSUE_NUMBER>.json`. Every subcommand that
  historically took only `<KEY>` (`read`, `write`, `patch`, `append-lesson`,
  `append-halt`, `summarise-lessons`) now takes an additional
  `<ISSUE_NUMBER>` positional in slot #3. `init` was already issue-scoped;
  `recall-lessons` (repo-scoped by design) is unchanged in signature — its
  aggregator glob widened from `-name workflow-state.json` to
  `-name workflow-state-*.json`. Three new helpers land inside the script:
  `_validate_issue_number` (`^[1-9][0-9]*$` at the shell layer, doubling
  the fail-open jsonschema check), `_resolve_state_file` (path composer),
  and `_migrate_legacy_state` (read-time promotion of any legacy
  `workflow-state.json` to `workflow-state-<its own .issue_number>.json` —
  content-driven, atomic `mv`, idempotent, and preserves a legacy file
  under `.superseded-by-<issue>` when the target already exists). Atomic
  write, schema validation, and the #170 `.worktree_path` guard all flow
  unchanged through the new path — the guard is now enforced on every
  per-issue file individually.
- **`skills/workflow-state/SKILL.md`** — 1.4.0 → 1.5.0. Every subcommand
  example carries the new `<ISSUE_NUMBER>` positional. Description
  updated to name the per-issue layout as the on-disk contract. Cross-
  plugin caller note explicitly states that `build-implement-tdd` threads
  the issue number.
- **`skills/workflow-state/references/smoke-tests.sh`** — 34 existing
  tests updated for the new arg shape; eight new tests (T35–T42) cover
  per-issue init isolation, subcommand routing per ISSUE, per-issue
  `summarise-lessons`, aggregate `recall-lessons` across per-issue files,
  legacy-file read-time migration, ISSUE_NUMBER validation, `.worktree_path`
  guard regression under the new layout, and cross-repo filter. 42/42
  pass.
- **`scripts/context-handoff.sh`** — `check` and `emit-resume` grow a
  required `<ISSUE_NUMBER>` positional in slot #3. The resume script name
  is now `resume-<KEY>-<ISSUE>.sh` so multiple issues sharing a spec
  folder cannot clobber each other's resume scripts. Its idempotency
  guard reads state via `WS read "$KEY" "$ISSUE"`.
- **`scripts/loop.sh`** — `in_flight_issues` glob widened to
  `\( -name workflow-state-*.json -o -name workflow-state.json \)` so
  per-issue files are picked up and any not-yet-migrated legacy files
  remain visible until their next mutation triggers promotion.
- **`hooks/session-status.sh`** — banner scan widened to
  `"$SPECS_ROOT"/*/workflow-state-*.json` (with legacy
  `"$SPECS_ROOT"/*/workflow-state.json` fallback). One banner line per
  per-issue state file. Malformed-file skip preserved.
- **`scripts/loop-smoke-tests.sh`, `scripts/context-handoff-smoke-tests.sh`,
  `hooks/session-status-smoke-tests.sh`** — fixture paths follow the
  new layout; every mutating `WS` invocation threads the issue number.
  All 18 + 7 + 13 tests pass.
- **`agents/po-agent.md`, `agents/documentation-agent.md`, `README.md`,
  `skills/loop/SKILL.md`, `skills/resolve-pr-conflict/SKILL.md`,
  `skills/session-status/SKILL.md`** — doc-only. Every embedded
  `workflow-state.sh` shell example now carries `<ISSUE_NUMBER>`; every
  glob / walk reference names the per-issue layout with a legacy fallback.
  `resolve-pr-conflict` explicitly requires the PO-agent's dispatch
  bundle to carry `ISSUE_NUMBER` alongside `KEY`.

**Backward compatibility.** The one-shot read-time migration means
consumer repos with existing `specs/<KEY>/workflow-state.json` files
promote them on next read without operator action. The promotion path
is content-driven (issue read from the file's own `.issue_number`), so a
caller reading with a wrong `ISSUE_NUMBER` sees `{}` after promotion —
correct behaviour because the legacy file belonged to a different issue
and the caller can now `init` its own file.

**Schema unchanged.** `workflow-state.schema.json` is agnostic to the
on-disk filename; only the file layout and caller signatures changed.

---

## `loop.sh` run mutex — pidfile guard against concurrent instances (#172)

Fixes the incident documented in #172: an operator started
`plugins/makato-orchestrate/scripts/loop.sh run --status Ready --interval 600`
at 01:50 CEST. Six hours later a second `loop.sh` instance was
discovered running from the plugin cache
(`~/.claude/plugins/cache/makato-suite/makato-orchestrate/ca8b02a2807f/scripts/loop.sh`)
with different arguments (default `--interval 300`, no explicit status).
Both instances wrote to the same `.claude/state/loop-status.json`, both
consumed the same `specs/` tree for in-flight filtering, and both had
dispatched PO-agents against the same repo working tree. The 35× repeated
`dispatching #145` observed in the operator's log had a mirror in the
plugin-cache loop's log at the same cadence — six hours of network and
token spend on a run whose audit trail could not be trusted.

- **`scripts/loop.sh`** — `cmd_run` now acquires a pidfile at
  `.claude/state/loop.pid` (override via `MAKATO_LOOP_PIDFILE`) before
  any state write. A live pidfile — PID responds to `kill -0` — causes
  the second invocation to exit `3` with a message naming the incumbent
  PID and pidfile; the refusing instance never touches
  `loop-status.json`. A stale pidfile (PID gone) is reclaimed silently.
  On clean shutdown an `EXIT` trap removes the pidfile so the next
  `run` starts without stale state.
- **`scripts/loop.sh`** — `run --force` reclaims a live pidfile by
  `SIGTERM`ing the incumbent, waiting `MAKATO_LOOP_FORCE_GRACE`
  seconds (default 10), then `SIGKILL`ing if it is still alive. For
  operators who want to yank a stuck loop without shelling out to
  `kill -TERM <pid>` themselves. A cooperative `kill -TERM` from the
  operator's terminal is still preferred because the incumbent's own
  `EXIT` trap gets to run.
- **`scripts/loop.sh`** — new `startup_audit` object stamped once into
  `loop-status.json` at `run` startup. Records `started_at`,
  `script_path` (canonicalised through `os.path.realpath` so a
  symlinked plugin-cache invocation resolves to its real disk path),
  `pid`, `ppid`, `pidfile`, and the CLI arguments the process was
  started with. An operator seeing multiple `loop.sh` processes in
  `ps` can cross-reference the audit to tell which one owns the state
  dir — the exact diagnostic gap that made #172 invisible for six hours.
- **`scripts/loop-smoke-tests.sh`** — four new scenarios: T15 (live
  pidfile refused with exit 3, pidfile preserved), T16 (stale pidfile
  reclaimed and cleaned up on exit), T17 (`startup_audit` fields
  populated including `script_path`, `pid`, `pidfile`), T18 (`--force`
  SIGTERMs the incumbent and takes over). All 18 scenarios pass
  locally in ~10 s.
- **`skills/loop/SKILL.md`** — bumped to `1.3.0`. New `## Run mutex`
  section documents the pidfile contract, `--force` semantics, the
  startup-audit surface, and the non-goals (process-scoped only; no
  `flock`-style cross-clone lock; two operators running against
  different state dirs is supported by design). `argument-hint` gains
  `[--force]`. Environment-variable table gains rows for
  `MAKATO_LOOP_PIDFILE` and `MAKATO_LOOP_FORCE_GRACE`.
  `loop-status.json` schema table and JSON example gain the
  `startup_audit` object. "Single-thread guarantee" section rewritten
  from three layers to four (pidfile is now the outermost). Smoke-test
  index extended from 14 to 18.
- **`never-patterns.md`** — new NEVER 11 documenting the mutex
  contract with #172 traceability.

---

## PO-agent worktree-isolation hardening — three-layer defence against silent main-repo corruption (#170)

Fixes the critical isolation bug documented in #170: when `loop.sh` dispatched the PO-agent for a fresh issue whose feature branch did not yet exist, the agent's model self-repaired by running `git checkout -b feat/<N>-<slug>` **in the main repo working tree**, then `git worktree add` failed with `branch already used by worktree at <REPO_ROOT>`, and the agent bypassed the failure by patching `.worktree_path` directly via `workflow-state.sh patch` to point at the main-repo root. The main repo was left on a feature branch, workspace isolation was destroyed, cross-issue `workflow-state.json` clobbering became possible, and the audit log carried a fabricated `worktree_created` event pointing at the main checkout. Any headless overnight run past the first issue was unsafe until fixed.

Three independent fixes, all applied — each closes the incident at a different layer so a regression in one is still caught by the others:

- **Fix 1 — PO-agent hard ban + Step 2b branch-existence probe.** `agents/po-agent.md` Rules section gains a new bullet forbidding `git checkout -b`, `git branch <name>`, or any other inline branch-creation command from within the PO-agent process. Step 2b is rewritten to probe `git ls-remote --exit-code origin $BRANCH` before dispatching the worktree helper; branch present → `worktree.sh create`, branch absent → `worktree.sh create --new-branch`. Never the inline path. The `Input` table's `BRANCH` row is updated to say "may not yet exist" — the historical wording ("created upstream by build-start") no longer holds now that loop.sh dispatches fresh issues without a build-start prelude. The § *Worktree lifecycle* failure-modes table adds two rows (`git worktree add -b` failure → HALT-006, patch-to-unregistered-path → refused at layer 3).
- **Fix 2 — `worktree.sh create --new-branch` atomic mode.** `shared/worktree.sh` accepts an optional `--new-branch` positional immediately after `create` and, when passed, runs `git worktree add -b <BRANCH> <path> <origin/HEAD>` to create the branch and worktree atomically. Base ref is resolved via `git symbolic-ref refs/remotes/origin/HEAD` with a fallback to `origin/main` so the helper works against any target repo. After the atomic add, the new branch is pushed with `-u` from **inside** the worktree so no step ever needs to `cd` into the main checkout. Push failure is a warning, not a state-corrupting condition — the local worktree stays intact so a caller can retry manually. Idempotent under resume: passing `--new-branch` against an already-registered worktree emits `worktree_resumed`, matching the plain-`create` behaviour.
- **Fix 3 — `workflow-state.sh patch` schema validator for `.worktree_path`.** `shared/workflow-state.sh` gains a `_validate_worktree_path_write` gate that fires only for `.worktree_path` writes. Explicit-null writes are always permitted (the invariant `worktree_path != null ⟺ dir on disk` allows null when no worktree is registered — cleanup uses this). Non-null writes must point at a path that (a) is not the main-repo root AND (b) appears in `git worktree list --porcelain` under canonicalised comparison (`os.path.realpath` — matches `worktree.sh`'s own `_is_registered_worktree` for identical semantics). The main-repo-root check is the layer that catches the #170 exact incident: git lists the primary worktree in `--porcelain`, so a plain "is registered?" check would have accepted it. Tests may bypass with `MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1`; production callers must not.

Other changes:

- **`never-patterns.md`** adds NEVER 10 documenting the three-layer contract with #170 traceability.
- **`shared/worktree-smoke-tests.sh`** gains T14–T18 (5 new scenarios; 13 → 18 total). T14 asserts the #170 core invariant — `git worktree add -b` runs and the main-repo HEAD remains on `main`, the worktree HEAD is on the new branch, and `origin/$BRANCH` is populated. T15 asserts idempotent resume under `--new-branch`. T16 asserts that plain `create` on a non-existent branch still fails loudly (regression bar for the old silent-repair class). T17 exercises the four Fix 3 paths (unregistered patch refused, non-existent-path refused, explicit-null permitted, bypass env var permits the write). T18 asserts the validator only guards `.worktree_path` — unrelated field patches pass through unchanged. All 18 pass locally.
- **`shared/worktree-smoke-tests.sh`** T8 (pre-existing, unrelated to #170) now sets `MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1` when it re-writes an already-removed path to simulate a stale state pointer — documented at the call site.

---

## Add liveness watchdog to `loop.sh` dispatch (#164)

Third and last of the three coupled contract holes surfaced by the #160 incident. #160 fixed the root cause (dispatch prompt now delegates to po-agent), #163 wired the caller-side `MAKATO_HEADLESS=1` defence; #164 adds the last-resort net so a future novel deadlock class doesn't wedge the loop indefinitely.

- **`scripts/loop.sh`** — `cmd_dispatch`: when the watchdog is enabled (default), the PO-agent's combined stdout+stderr is redirected to `.claude/state/dispatch-<issue>.log`, and a background `_watchdog_poll` helper polls the log's mtime every `MAKATO_LOOP_STALL_POLL` seconds. Two escalation levels: **WARN** (`idle ≥ MAKATO_LOOP_STALL_WARN`, default 900 s) stamps `active_workflow.stalled = true` / `stalled_since = <iso>` — visibility only, no signal to the child. **KILL** (`idle ≥ MAKATO_LOOP_STALL_KILL`, default 3600 s) snapshots `last_watchdog_kill = {issue, killed_at, idle_seconds, stall_kill_seconds}` (surviving the `active_workflow=null` clear on dispatch return), stamps `active_workflow.killed_by_watchdog = true`, sends `SIGTERM`, and follows up with `SIGKILL` after `MAKATO_LOOP_STALL_TERM_GRACE` seconds (default 30) if the child hasn't exited.
- **`scripts/loop.sh`** — `active_workflow` now initializes with the watchdog fields (`stalled: false, stalled_since: null, killed_by_watchdog: false`) so the JSON shape is stable across dispatch runs regardless of whether the watchdog fires.
- **`scripts/loop.sh`** — `MAKATO_LOOP_STALL_DISABLE=1` skips log capture and never spawns the watchdog (debug-session escape hatch). `MAKATO_LOOP_STALL_TEST_CMD` is a test-only hook that runs the given command (e.g. `sleep 30`) in place of `claude` so the smoke suite has a real stall to reap without invoking the model.
- **`scripts/loop-smoke-tests.sh`** — three new scenarios: T12 (WARN stamps `stalled=true`), T13 (KILL SIGTERMs child and `last_watchdog_kill` audit survives), T14 (`MAKATO_LOOP_STALL_DISABLE=1` fully opts out — no log file, no status stamps). All 14 scenarios pass locally in ~10 s.
- **`skills/loop/SKILL.md`** — bumped to `1.2.0`. New "Liveness watchdog" section documents the WARN/KILL escalation, non-goals (not a semantic-progress meter), and the escape hatch. `loop-status.json` schema table gains rows for the four new fields. Environment-variable table gains rows for `MAKATO_LOOP_STALL_{WARN,KILL,POLL,TERM_GRACE,DISABLE,TEST_CMD}`. Smoke-test index extended from 11 to 14.

---

## Export MAKATO_HEADLESS=1 on `claude -p` dispatch (#163)

Belt-and-braces defence against the #160 deadlock class. #160 fixed the root cause (dispatch prompt now delegates to po-agent, which threads `--autonomous`). #163 adds the skill-side defensive guard in `makato-build` (`build-refine` Step 1b); this PR wires the caller-side signal.

- **`scripts/loop.sh`** — `cmd_dispatch`: prefix the `$CLAUDE_BIN` exec with `MAKATO_HEADLESS=1`. If the po-agent delegation prompt is somehow ignored and a `build-*` skill fires interactively, its Step 1b guard HALTs with `MISSING_INPUT` instead of hanging on `AskUserQuestion`.
- **`scripts/context-handoff.sh`** — `_emit_resume`: the emitted HALT-007B resume script's `exec` line becomes `exec env MAKATO_HEADLESS=1 "$CLAUDE_BIN" …` so the same defensive property carries across a context handoff. The existing T5 smoke-test regex (`claude ... --dangerously-skip-permissions ... --resume`) continues to match; a new dedicated smoke test in makato-build asserts the `env MAKATO_HEADLESS=1` prefix.
- **`skills/loop/SKILL.md`** — Step 5 dispatch description updated to note the env-var prefix and cross-reference the `AUTONOMOUS-MODE.md` § *Defensive-headless guard* contract.
- All 11 loop smoke tests and 7 context-handoff smoke tests continue to pass.

---

## Fix loop.sh dispatch prompt not delegating to po-agent (#160)

`loop.sh`'s `cmd_dispatch` was calling `claude -p "Drive issue #<n> to merged PR"`, which is under-specified: the headless top-level Claude session did not delegate to the `makato-orchestrate:po-agent` subagent and instead invoked `makato-build` skills directly (e.g. `build-refine`). Those skills default to interactive mode and fire `AskUserQuestion` on the plan; the headless `claude -p` subprocess has no stdin, so the loop deadlocked on the first dispatch. Observed live on 2026-07-07 against issue #143 (PID hung ~14 min at 0.4% CPU before manual kill). The same under-specified prompt appeared in the HALT-007B resume script — same failure mode after every context handoff.

- **`scripts/loop.sh`** — `cmd_dispatch`: replaced the bare prompt with an explicit delegation: `"Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to drive GitHub issue #<n> to a merged PR. […] do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."`. Header comment updated. Dry-run echo updated to describe the delegation rather than quote the whole prompt.
- **`scripts/context-handoff.sh`** — `_emit_resume`: the HALT-007B resume script now uses the same delegation prompt so the resumed session also delegates via the po-agent subagent instead of running `makato-build` skills directly.
- **`skills/loop/SKILL.md`** — Step 5 dispatch description and HALT-007B row updated to describe the delegation prompt and reference #160.
- **`skills/kill-switch/SKILL.md`** — HALT-000 resumption example points at `loop.sh run` (the loop entry point) instead of an ad-hoc `claude -p` invocation.
- **`halt-conditions.md`** — HALT-007B recovery description updated to describe the delegation prompt.
- All 11 loop smoke tests and all 7 context-handoff smoke tests pass.



`scripts/loop.sh`'s `cmd_poll` called `gh --hostname "$host" project item-list …`, but `gh project item-list` has never accepted a `--hostname` flag. The subprocess exited with `unknown flag: --hostname`, stderr was swallowed by `2>/dev/null`, and the `|| echo '{"items":[]}'` fallback made the loop see an empty queue on every poll — even when Ready items existed on the board. Verified live: pre-fix `poll Ready` → `[]`; post-fix → issue #143.

- **`scripts/loop.sh`** — `cmd_poll`: replaced `gh --hostname "$host" project item-list …` with `GH_HOST="$host" gh project item-list …`. Removed the `2>/dev/null` swallow so real `gh` failures surface (the caller still degrades to an empty queue via the fallback, but with diagnostics). Comment expanded to record the incident and the routing rule. All 11 loop smoke tests pass; live verification against `macatocz/projects/4` returns the Ready queue correctly.

---

## Fix loop.sh dispatch using non-existent `claude --session/--autonomous` flags (#152)

`loop.sh`'s `cmd_dispatch` called `claude --session loop --autonomous <issue>`, but these flags have never existed in the released Claude Code CLI binary. The same phantom invocation appeared in the context-handoff resume script. Both dispatch paths failed immediately with `error: unknown option '--session'`.

- **`scripts/loop.sh`** — `cmd_dispatch`: replaced `"$CLAUDE_BIN" --session loop --autonomous "$issue"` with `"$CLAUDE_BIN" --dangerously-skip-permissions -p "Drive issue #${issue} to merged PR"`. Dry-run echo updated to match. Header comment updated (`--session` reference removed). All 11 smoke tests pass.
- **`scripts/context-handoff.sh`** — `_emit_resume`: replaced `exec "$CLAUDE_BIN" --session loop --autonomous "\$ISSUE" --resume "\$KEY"` with `exec "$CLAUDE_BIN" --dangerously-skip-permissions --resume "\$KEY" -p "Drive issue #\$ISSUE to merged PR"`. All 7 context-handoff smoke tests pass.
- **`scripts/context-handoff-smoke-tests.sh`** — T5 grep pattern updated from `--session loop --autonomous` to `--dangerously-skip-permissions.*--resume` to match the new invocation.
- **`skills/loop/SKILL.md`** — Step 5 dispatch description and kill-switch table updated to use the correct flags.
- **`skills/kill-switch/SKILL.md`** — HALT-000 resumption example updated.
- **`halt-conditions.md`** — HALT-007B recovery description updated.
- **`README.md`** — scripts section updated.

---

## `workflow-state.sh append-halt` subcommand + four-step HALT contract (#118 Part A)

Replaces the open-coded read-merge-write pattern (`_append_halt_audit()` in `scripts/context-handoff.sh`, plus several inline `patch .halt_audit '...'` call sites in `agents/po-agent.md`) with a single typed subcommand that owns the canonical entry shape, code-format validation, and JSON-object data validation.

- **`shared/workflow-state.sh`** → 1.4.0 — new `append-halt <KEY> <CODE> <JSON-DATA>` subcommand. Mirrors the `append-lesson` shape: `ts` helper-injected; `CODE` validated against `HALT-NNN`, `HALT-NNN[A-Z]`, or `HALT-STRUCTURAL`; `JSON-DATA` rejected unless it's a JSON object (arrays, scalars, malformed JSON exit 1); merges via `+ [new]` to preserve immutable append-only semantics; the result is schema-validated like every other write. The synopsis line and unknown-subcommand help message list the new subcommand.
- **`skills/workflow-state/SKILL.md`** → 1.4.0 — new `## append-halt` section documenting the signature, validation rules, and the rule that callers MUST use this subcommand rather than `patch .halt_audit`. Description bumped from "seven subcommands" to "eight subcommands".
- **`skills/workflow-state/references/smoke-tests.sh`** → 28 → 34 tests. T29: append one entry; T30: canonical {code, ts, data} shape; T31: HALT-007B accepted; T32: HALT-STRUCTURAL accepted; T33: malformed code (BAD-CODE) rejected; T34: non-object data (string, array, malformed JSON) rejected.
- **`scripts/context-handoff.sh`** → `_append_halt_audit()` collapses to a single call to `"$WS" append-halt`. The optional pre-read-state parameter was removed — the helper does its own atomic read+patch with validation, making the caller's optimisation unnecessary. Both call sites (HALT-007 fallback at L145, HALT-007B handoff at L212) are unchanged at the source level; only the helper's body was rewritten.
- **`agents/po-agent.md`** → 1.6.1 → 1.7.0 — Step 1 (spec-folder missing → HALT-006) and § *Error modes* updated to dispatch through `append-halt` instead of `patch .halt_audit`. The "three-step contract" is now a "four-step contract": (1) `append-halt`, (2) `append-lesson`, (3) `worktree retain`, (4) `summarise-lessons`. The bootstrap-exception clause extends to cover `append-halt` as well — pre-`init` HALT paths skip step 1 alongside the existing skips of 2 and 4 and emit a `halt-pre-init` JSONL audit entry instead. HALT-007B retains its R1-`partial` exit and still emits the `append-halt` entry (a HALT code that fired must be audited).

---

## PO-agent error-mode table references build halt-codes registry (#115)

The PO-agent error-mode table previously had no documented routing for skill-level string HALT codes (`MISSING_INPUT`, `BASELINE_BROKEN`, `PUSH_REJECTED`, etc.). It covered the numeric `HALT-NNN` codes documented in `halt-conditions.md`, but the 17+ uppercase-underscore tokens emitted by build-* skills fell through to a generic `operator-escalation`.

- **agents/po-agent.md** → 1.6.1 — new error-mode row pointing at `plugins/makato-build/halt-codes.md`, which now owns the build-skill-token registry with (origin skills, recovery route, description) columns. The PO-agent's parsing rule (read `data.halt_code` first; fall back to parsing `[A-Z_]+:` from `errors[0]`) is documented in both files so a future reader sees the same contract from either end.

The two HALT registries stay deliberately disjoint: numeric `HALT-NNN` continues to live in `halt-conditions.md` (this plugin); the new build-skill-token registry lives in `makato-build`. A sub-agent R1 that surfaces BOTH (e.g. `build-address-pr-comments` setting `data.halt_code: "HALT-003"` AND `errors: ["STRUCTURAL_BLOCKER: …"]`) is still parsed numeric-first by the PO-agent; the string token is forensic context.

---

## Fix PO-agent Step 6a coder-bypass contradiction (#119)

Closes the self-contradictory contract in `po-agent.md` where two invariant statements (lines ~272 and ~358) said "PO-agent does NOT dispatch `coder` directly" but Step 6a (CI-failure fix loop) dispatched `/makato-build:coder --autonomous` itself. The bypass skipped the tracer-bullet guard, per-task scout pre-flight, `blockedBy` topological check, workflow-state task-status patch, baseline-failure gate, and the per-task `REPO_ROOT` / `WORKTREE_PATH` forwarding rules — every guarantee `build-implement-tdd` is documented as the single owner of. Surfaced independently by the simplification and altitude reviewers on PR #113.

- **agents/po-agent.md** → 1.6.0 — Step 6a CI-failure fix loop now dispatches `/makato-build:build-implement-tdd <KEY> --autonomous` with the CI failure log appended as a `CI_FAILURE_LOG` bundle field, replacing the direct `coder` dispatch. The skill identifies the failing task(s) from the log and runs its own scout + RED/GREEN/INTEGRATE/VERIFY cycle on the affected task(s), patching `sub_tasks[N].status` through the same workflow-state carve-out as Step 4d. The two invariant statements (Step 4 outer-loop bullet, Step 4d closing paragraph) now explicitly call out that the rule holds for the CI-failure fix loop too — a single implementation entry point with no documented exceptions.
- **agents/po-agent.md** → CI-failure recovery success/failure sub-steps now reference the skill's R1, not coder R1, so the propagation chain matches reality.

---

## Merge-conflict detection and rebase resolution in PO-agent outer loop (GAP-016 / #45)

- **workflow-state schema** — New required field `merge_conflict_cycles` (integer, minimum 0, default 0). Distinct from `outer_iteration` so a single run can exhaust both the re-plan-loop ceiling (`outer_iteration >= 3`, enforced by `kill-switch poll`) AND the conflict-resolution ceiling (`merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES`, enforced at the PO-agent's pre-dispatch check in Step 6 #3 and at the `resolve-pr-conflict` Step 6 terminal HALT). Both ceilings fire HALT-008 — the `data` payload distinguishes them.
- **shared/workflow-state.sh** — `init` seeds `merge_conflict_cycles: 0` alongside the other defaults. `patch` and `read` work against the new field without schema changes (jsonschema rejects non-integer or negative values via the existing validation pipeline).
- **smoke-tests.sh** — 25 → 28 tests. T26: `merge_conflict_cycles` seeded at init with default 0. T27: `patch` persists a non-negative integer value. T28: schema rejects negative integer (`-1`) via the existing `_validate` heredoc.
- **halt-conditions.md** — HALT-008 row rewritten to document TWO origins: (a) `outer_iteration >= 3` (re-plan exhaustion, `kill-switch poll` path); (b) `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES` (conflict-resolution exhaustion, `resolve-pr-conflict` path). The counters are independent. See-also section adds a link to `skills/resolve-pr-conflict/SKILL.md` and the `merge_conflict_cycles` schema field.
- **skills/resolve-pr-conflict/SKILL.md** → 1.1.0 — Four changes:
  - **Auto-detected rebase target** — new Step 2 picks `development` when `origin/development` exists, otherwise `main`. Detection uses `git ls-remote --exit-code --heads origin <branch>` against the remote (not local HEAD) so a stale local-only `development` ref never produces a false positive. `git fetch origin --prune` precedes the check so the remote view is current. The resolved target is logged via `step: "target-resolved"`. The skill no longer hard-codes `origin/main` in Steps 3-5; `$TARGET_BRANCH` is threaded through the rebase, the `merge -X ours` fallback, and every log row. AC: works for both PRD-style (`development`) and makato-style (`main`) consumer repos without per-consumer configuration.
  - **Canonical event names (AC9)** — Step 1 now emits `merge_conflict_detected` alongside the session-start row. Step 5 emits `rebase_resolved` alongside `push-resolved`. Step 6 emits `rebase_failed` alongside the session-end HALT row. The dual-row pattern is intentional — `step:` names matching the body convention stay (existing audit consumers continue to work), and the AC-mandated names are surfaced on their own rows so a downstream reader can count merge-conflict outcomes without joining `session` rows.
  - **Typed state mutation (AC5)** — Step 6 now invokes `shared/workflow-state.sh patch <KEY> .merge_conflict_cycles <N>` and `shared/worktree.sh retain <KEY> merge_conflict` instead of hand-rolled jq. The schema field is now real; the helpers carry the sole-writer contract and schema validation.
  - **Worktree path resolution** — Step 1 now reads `.worktree_path` from workflow-state via `shared/workflow-state.sh read` (which resolves the `specs/<key>-*/` prefix-match path) instead of hand-constructing `.claude/state/workflow-${KEY}.json` (which never existed — the schema lives under `specs/`).
  - **HALT Codes table** — `HALT-008` row extended to document the cap origin alongside the unresolvable-tree origin; `NETWORK_ERROR` row extended to cover the "neither development nor main on origin" path.
  - **New Environment section** — documents `MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3).
- **agents/po-agent.md** → 1.5.0 — Three changes:
  - **Step 6 #3 (push pipeline) merge-conflict routing (AC1, AC3, AC4)** — `build-push-to-git` R1 `failure` is now classified before HALTing. When `errors[]` contains a case-insensitive substring match for `conflict`, `cannot be rebased automatically`, or `non-fast-forward`, the PO-agent enters the conflict-resolution sub-loop: read `merge_conflict_cycles` (HALT-008 immediately if already at cap), dispatch `/makato-orchestrate:resolve-pr-conflict <KEY> --autonomous`, parse its R1, and on `success` re-dispatch `build-push-to-git` (AC3 — re-run PR creation through the same pipeline step on clean rebase). On the skill's own HALT-008 R1, propagate the `halt_code` through po-agent's R1. Other resolution-skill failures (`SAFETY_BOUNDARY`, `NETWORK_ERROR`, `PUSH_REJECTED`) escalate to HALT-005.
  - **Step 6a (CI checks) rebase-check classification (AC1)** — when `gh pr checks` reports any check name matching `(?i)(rebase|merge.?conflict)` with `conclusion: "failure"`, the PO-agent routes through the same conflict-resolution sub-loop instead of dispatching the coder. This is the distinct second detection signal (failed merge-detector job in CI) from the first (push itself rejected). After clean rebase, CI is re-polled from the top of sub-step 6a (counter reset).
  - **Label application matrix** — `HALT-008` row now lists BOTH writers: `kill-switch poll` for the outer-iteration origin, `resolve-pr-conflict` for the merge-conflict origin. PO-agent's subsequent `gh issue edit --add-label` (when it re-fires HALT-008 on the pre-cap pre-dispatch check in Step 6 #3) is documented as idempotent no-op.
  - **Error modes** — new row covering the cap path: when `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES`, the skill applies `needs-human-review` itself and the worktree is retained for human inspection.
  - **Frontmatter description** — updated to call out the merge-conflict detection + rebase-resolution capability.
  - **See also** — new entries for GAP-016 / #45 and the resolve-pr-conflict skill.
- **AC10 cross-references** — `halt-conditions.md` HALT-008 row, `agents/po-agent.md` Step 6 #3 and Step 6a, and `skills/resolve-pr-conflict/SKILL.md` HALT Codes table all reference each other so the merge-conflict origin is documented from three angles (the HALT taxonomy, the caller dispatch path, the callee skill contract).

### Out of scope (deferred per issue § Out of Scope)

- File-claim labels (`files:<glob>`) — redundant with worktree isolation + single-threaded `/loop`.
- Import-graph dependency analysis at assignment time — covered by `scout` (GAP-013 / #29).
- `PreToolUse` hook blocking Write/Edit on collision — fights the TDD inner loop.
- Auto-merging the PR after conflict resolution — human or GHA merge remains the final step.
- Concurrent ticket execution (`LOOP_MAX_CONCURRENT > 1`) — single-threaded loop in v1.

### Note on rebase target

The skill now **auto-detects** the target branch at Step 2 via `git ls-remote --exit-code --heads origin <branch>`: `development` wins when it exists on `origin`, otherwise `main`. Detection runs against remote refs (not local HEAD) so renames or stale local-only branches do not confuse the choice. The AgenticSystem PRD `code-conflict-prevention.md` convention (`development`) and the makato repo's actual default (`main`) are both honoured without per-consumer configuration. When neither branch exists on `origin`, the skill HALTs with `NETWORK_ERROR` and reason `"target branch not found on origin"` — the consumer repo has a non-standard default and human resolution is required.

---

## Structured lessons learned + inter-session carry-forward (GAP-015 / #37)

- **workflow-state schema** — `lessons_learned[]` item shape extended from `{ts, text}` to `{ts, cycle, trigger, description, files_affected}`. `trigger` is a closed enum: `ci_failure | halt | review_comment | sensor | merge_conflict` (the `merge_conflict` value covers the `resolve-pr-conflict` call site that GAP-016 / #45 prepared). `description` is capped at 200 chars (`maxLength: 200`) per the issue's technical notes — keep lessons structured, not narrative. `files_affected` is an array of repo-relative paths (may be empty); the `ts` and `cycle` mirror `updated_at` and `outer_iteration` so a lesson is timestamped and locatable in the run timeline without joining other fields.
- **shared/workflow-state.sh** — Three changes:
  - **`append-lesson` signature** changed to `append-lesson <KEY> <CYCLE> <TRIGGER> <DESCRIPTION> [FILE…]`. The helper injects `ts`, regex-gates `CYCLE` (non-negative integer, refused otherwise — avoids jq-injection via numeric argjson), regex-matches `TRIGGER` against the schema enum (schema validation provides the final guard), truncates `DESCRIPTION` at 200 chars with a `…` suffix instead of refusing, and accepts zero-or-more `FILE` positional args as `files_affected[]`. The signature change is loud: old `{ts, text}` callers fail with `description required` from `${5:?…}` so an operator notices and migrates the call site by hand — there is no automatic migration of in-flight state files either (the schema is strict; legacy entries trigger `HALT: INVALID_STATE` on the next mutating call, and operators re-`init` or hand-edit).
  - **`recall-lessons <REPO> [N]`** new subcommand. Aggregates `lessons_learned[]` across every `specs/*/workflow-state.json` whose `.repo` matches `<REPO>`, returns the top-N (default 3) as a JSON array sorted `(cycle DESC, ts DESC)`. Used by the PO-agent at session start (AC3) to warm-start the dispatch bundle. ARG2 is REPO (not KEY) — handled by binding ARG2 generically at the top of the script. Returns `[]` when no matching repo or `specs/` is absent — never errors on first-run-for-this-repo.
  - **`summarise-lessons <KEY>`** new subcommand. Renders `lessons_learned[]` as `specs/<key>-<slug>/lessons-YYYYMMDD.md` (AC4). Idempotent (same-day re-run overwrites). Writes a stub file with `_No lessons recorded for this run._` when the array is empty so the file's existence is the audit signal. Prints the absolute path to stdout.
- **smoke-tests.sh** — Expanded 15 → 25 tests. New coverage: typed lesson fields (T8 rewritten), enum violation (T16), non-integer cycle guard (T17), 200-char truncation with `…` suffix (T18), files_affected variadic-optional (T19), `merge_conflict` trigger (T20), AC5 `patch` preserves `lessons_learned[]` (T21), `recall-lessons` filters by repo and returns top-N newest-first across multiple specs (T22), `recall-lessons` empty-repo case (T23), `summarise-lessons` markdown content (T24), `summarise-lessons` same-day idempotency (T25). All 25 pass.
- **skills/workflow-state/SKILL.md** — Bumped to 1.3.0. Description updated to "seven subcommands". Schema reference rewritten for the new `lessons_learned[]` item. New `append-lesson` (typed signature), `recall-lessons`, and `summarise-lessons` sections with worked examples. JSONL audit requirement extended — `summarise-lessons` is mutating (writes a markdown artifact) so callers MUST emit an audit entry; `recall-lessons` is read-only so it does not. Verification section lists the new tests.
- **agents/po-agent.md** — Bumped to 1.4.0.
  - Frontmatter description now calls out structured lessons + warm-start.
  - **New Step 2c** between Step 2b (worktree resolve) and Step 3 (sub-task list build) runs `recall-lessons <REPO> 3` and caches the result for the dispatch bundle. Empty result is normal (no HALT). One JSONL audit entry per call (`step: "recall-lessons"`).
  - **Step 4d** — `PRIOR_LESSONS` documented as the canonical dispatch-bundle key alongside `WORKTREE_PATH`. Advisory by contract — consumers tolerate both `[]` and missing key identically; lessons never trigger a HALT.
  - **Step 6a (CI failure)** — typed `append-lesson` call with `trigger: ci_failure` and the current `outer_iteration` as cycle. Also the 10-poll timeout path.
  - **Step 6b (CHANGES_REQUESTED)** — typed `append-lesson` call with `trigger: review_comment`, current cycle, and the reviewer's commented-on paths as `files_affected` (via `gh pr view --json reviews --jq`).
  - **Step 6 #8 (success terminal)** — calls `summarise-lessons <KEY>` after worktree cleanup; emits the matching `step: "summarise-lessons"` JSONL audit. Idempotent on re-run.
  - **§ Error modes** — now mandates a three-step terminal contract for every HALT path: (1) append a `trigger: halt` lesson with the HALT code in the description, (2) `worktree.sh retain`, (3) `summarise-lessons`. HALT-007B is the documented exception (handoff is not a failure; no `halt` lesson; fresh session resumes lesson accumulation in place).
  - **See also** — new link to GAP-015 / #37 reference.
- **skills/resolve-pr-conflict/SKILL.md** — Step 5 #3 now invokes `shared/workflow-state.sh append-lesson` directly with the new positional signature (rather than building a JSON object via jq and leaving the persist step as a TODO comment). The conflicted-file list passes through as variadic positional args via a Bash array. The `merge_conflict` enum value lands the resolve-pr-conflict path in the same lesson stream as PO-agent-generated lessons.
- **agents/context-summariser.md** — Schema-pin update: the lessons-extraction step reads `.lessons_learned[].description` (not `.text`), and the rendered KEY DECISIONS block prefixes each line with `[<trigger>]` for context (e.g. `[ci_failure] ruff F401 unused import`).

---

## HALT-003 extended for STRUCTURAL PR comments (GAP-011 / #36 follow-on)

- **halt-conditions.md** — HALT-003 trigger list extended to include `build-address-pr-comments` autonomous-mode STRUCTURAL detection (alongside the original `diff-reviewer` CRITICAL-findings trigger). The recovery prose now also documents the structural-comment path: re-shape via `makato-plan` or override and re-run interactively.
- **agents/po-agent.md** § *Label application* — new row `HALT-003 (variant)` calls out that `build-address-pr-comments` applies `needs-human-review` itself on AC3, and that the PO-agent's subsequent `gh issue edit --add-label` is an idempotent no-op. Avoids the appearance of a duplicate-writer contract violation against Design Principle 1.

## session-status SessionStart hook (GAP-014 / #31)

- **1.0.0** — Operator-facing SessionStart banner so every new Claude Code session opens with a one-line summary per active workflow.
  - `hooks/session-status.sh` — Read-only hook that scans `$(git rev-parse --show-toplevel)/specs/*/workflow-state.json` (override via `MAKATO_SPECS_ROOT`) and prints one banner line per file: `#<issue> | phase: <phase> | budget: <consumed>/<limit> (<pct>%) | halts: <N> | updated: <ts>`. When `~/.claude/HALT` exists (override via `MAKATO_HALT_FILE`), prints a prominent `⛔ HALT ACTIVE — remove <path> to resume` block FIRST, before the workflow list — same file path as `check-halt.sh`. Stale workflows (`updated_at` more than `MAKATO_STALE_HOURS` ago, default 24h) get a `⚠ STALE — resume: /loop --autonomous <issue>` suffix. `halt_audit` entries surface the last HALT code on the per-line banner. When no `workflow-state.json` files exist, prints `No active workflows` and exits 0. Read-only by contract — PO-agent (GAP-006 / #32) remains the sole writer of `workflow-state.json`. Failure modes are deliberately silent: missing `jq`, no git repo, malformed JSON, zero `budget_limit_tokens` all degrade to a warning on stderr or `?%` rather than blocking the session. `MAKATO_DISABLE_SESSION_STATUS=1` short-circuits the hook to a silent exit for CI runs or emergencies.
  - `hooks/session-status-smoke-tests.sh` — Eight scenarios covering every banner path in a disposable sandbox `specs/` tree (so smoke tests never read the makato repo's own live `workflow-state.json` files): no state files prints "No active workflows"; one active workflow surfaces the full banner with all fields and correct percentage; stale workflow gets `STALE` marker plus `/loop --autonomous <issue>` resume hint; HALT file present prints the `HALT ACTIVE` banner BEFORE the workflow list (line-order assertion); `halt_audit` non-empty surfaces the last HALT code on the banner line; zero `budget_limit_tokens` shows `?%` instead of crashing with divide-by-zero; multiple workflows all surface in output; `MAKATO_DISABLE_SESSION_STATUS=1` exits silently with empty stdout. Uses `MAKATO_SPECS_ROOT` and `MAKATO_HALT_FILE` env overrides so tests are hermetic.
  - `skills/session-status/SKILL.md` — Reference document for the hook. Frontmatter `name`, `description`, `version: "1.0.0"`. Sections: When to Use (clarifies SessionStart hook, not an invocable skill), Purpose, settings.json wiring snippet (`matcher: "SessionStart"`, `command: "${CLAUDE_PLUGIN_ROOT}/hooks/session-status.sh"`, `timeout: 10000`), Output format with worked examples (HALT-active and empty case), Environment variables table, Failure semantics (jq missing / not a git repo / malformed JSON / divide-by-zero / never blocks session), Read-only contract referencing AGENTS.md and `never-patterns.md` NEVER 4, Related links.
  - `README.md` patched — Status section adds GAP-014 (#31) shipped entry; Skills table flips `session-status` from "follow-up" to "Shipped — GAP-014 (#31)"; Hooks table flips `session-status.sh` from "follow-up" to "Shipped — GAP-014 (#31)"; new `### session-status.sh wiring` subsection with the `.claude/settings.json` snippet plus the four env-var overrides; File Structure block updated to reflect the new files.
  - `AGENTS.md` patched — File Structure block updates the `hooks/session-status.sh` line from "GAP-007 follow-up — stub" to "GAP-014 / #31 — shipped" and adds the smoke-tests sibling; `skills/session-status/SKILL.md` line updated to "GAP-014 / #31 — shipped".
  - **Schema alignment** — issue text mentions `.claude/state/workflow-*.json` as the scan path, but the actual workflow-state schema writes to `specs/<key>-<slug>/workflow-state.json`. The hook follows the schema (sole source of truth), not the issue prose. The discrepancy is noted in the plan's *Scope Flags* section so future readers don't get confused.
  - **macOS portability** — uses `python3` (not BSD/GNU `date -d`) to compute the stale cutoff and parse ISO-8601 `updated_at`, matching the workflow-state.sh approach. The hook works on macOS Sonnet 4.6 and Linux without `coreutils` install.

---

## WORKTREE_PATH propagation (GAP-017 / #46 follow-up, #85)

- **agents/po-agent.md** → 1.2.0 — § *Worktree Lifecycle* § *Inheritance* gets a new closing paragraph cross-referencing `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*. The PO-agent owns the **producer** half (create at Step 2b, propagate via dispatch bundle, cleanup at Step 6 #6, retain on HALT); each consumer skill / agent enforces the **consumer** half (HALT on empty in autonomous mode, fall back to `git rev-parse --show-toplevel` in interactive mode, forward to its own sub-agent dispatches). The Layer 1 workspace-isolation guarantee documented in `plugins/makato-orchestrate/code-conflict-prevention.md` is now active end-to-end — was previously documented in the caller but unimplemented in the callees.

---

## worktree lifecycle (GAP-017 / #46)

- **1.0.0** — Worktree lifecycle management in the PO-agent
  - `shared/worktree.sh` — Lifecycle helper exposing `create`, `path`, `cleanup`, `retain` subcommands. `create` resolves the canonical path `.claude/worktrees/<sanitised-repo>-<issue-number>` (`owner/name` → `owner-name`, same convention as Claude Code's `EnterWorktree`), detects existing registrations via `git worktree list --porcelain` after realpath-normalisation (macOS `/var/folders` → `/private/var/folders` aliasing collapsed), runs `git worktree add` for fresh runs, reuses on resume, and patches `.worktree_path` in workflow-state. Stdout contract: event marker (`worktree_created` / `worktree_resumed`) on line 1, absolute path on line 2 — readable via `head -1` / `tail -1` without JSON parsing. `cleanup` runs `git worktree remove --force` (falls back to `git worktree prune` on refusal), patches state back to null, and emits `worktree_removed`; idempotent — emits `worktree_noop` when state is already cleared, tolerates a stale path pointer with the on-disk worktree already gone. `retain <HALT_CODE>` flips `.worktree_retained = true` and `.worktree_retain_reason = <code>` WITHOUT removing the worktree — used on every terminal HALT so a human (or GAP-016 / #45 `resolve-pr-conflict`) can inspect the failed run.
  - `shared/worktree-smoke-tests.sh` — Eight scenarios covering the full lifecycle in a disposable sandbox repo (so smoke tests never pollute the makato repo's own `.claude/worktrees/`): init seeds new fields, create emits the right marker, path returns the absolute path, re-create on existing worktree emits `worktree_resumed`, retain flips flags without removing, cleanup removes and clears, cleanup is idempotent, and cleanup tolerates a missing on-disk worktree with state pointing at it. Uses `MAKATO_WORKTREE_ROOT` env override so worktrees live inside the sandbox, and symlinks the production helpers + schema into the sandbox so the helpers' `git rev-parse` resolves correctly.
  - `skills/workflow-state/references/workflow-state.schema.json` patched — two new required fields: `worktree_retained` (boolean) and `worktree_retain_reason` (string|null). `worktree_path`'s description rewritten to reference the GAP-017 lifecycle. Schema-validation T15 in `smoke-tests.sh` confirms `worktree_retained` rejects non-boolean values via `python3 + jsonschema`.
  - `shared/workflow-state.sh init` patched — seeds `worktree_retained: false` and `worktree_retain_reason: null` alongside the existing `worktree_path: null` default. Existing T14 in workflow-state smoke tests confirms all three fields land with their safe defaults.
  - `skills/workflow-state/references/smoke-tests.sh` patched (13 → 15 cases) — T14 verifies GAP-017 fields are seeded with safe defaults at init; T15 verifies the schema rejects non-boolean values for `worktree_retained`.
  - `skills/workflow-state/SKILL.md` patched (1.1.0 → 1.2.0) — schema reference table extended with `worktree_retained` and `worktree_retain_reason` rows; `init` defaults documentation updated to list the three new defaults; `worktree_path` description pinned to the GAP-017 lifecycle helper.
  - `agents/po-agent.md` patched (1.0.0 → 1.1.0) — new § *Worktree Lifecycle* documents the four mechanisms (Creation / Inheritance / Cleanup on success / Retention on HALT) plus a lifecycle summary table and failure-mode matrix. New Step 2b runs `worktree.sh create` immediately after state init and before any sub-agent dispatch. Step 4d gains a § *Worktree path propagation* clause documenting that every implementation-skill dispatch carries `WORKTREE_PATH` from `worktree.sh path <KEY>` — sub-agents `cd "$WORKTREE_PATH"` before any file operation and never invoke `git worktree` directly. Step 6 #6 calls `worktree.sh cleanup <KEY>` on success. § *Error modes* gets a header note that EVERY terminal HALT path must call `worktree.sh retain` before exiting (HALT-007B is the documented exception — context-ceiling handoff leaves the worktree on disk untouched so the fresh session resumes via `worktree_resumed`). § *Permission boundary* clarifies that the `git worktree` commands are NOT `Write`/`Edit` calls and are governed by the lifecycle section, not the four-path allow-list.
  - **Branch name convention** — `auto/{repo}-{issue-number}` as established by `build-start`. The helper does NOT pass `-b` to `git worktree add` because the branch must already exist; passing `-b` would conflict on resume of a half-failed earlier run.
  - **macOS realpath quirk** — `git worktree list --porcelain` prints canonicalised paths (`/private/var/folders/...`) on macOS even when the user-supplied path starts with `/var/folders/...`. The resume detect path-compares after `os.path.realpath()` normalisation on BOTH sides so the resume case fires correctly. This isn't a Linux concern — Linux has no such symlink — but it would silently break smoke tests on macOS.
  - **Composes with GAP-016 / #45** — `resolve-pr-conflict` already reads `.worktree_path` from workflow-state to `cd` into the retained worktree on merge-conflict recovery. GAP-016 also patches `.worktree_retained = true` and `.worktree_retain_reason = "merge_conflict"` on HALT-008 — the same two fields this helper writes. The contract is now backed by schema validation; both writers agree on the shape.
  - **Disjoint from Claude Code's `EnterWorktree`** — that tool is the interactive `worktree:` agent-tool option for ad-hoc isolation; this helper is the deterministic per-issue lifecycle the PO-agent owns. They share the `.claude/worktrees/` path convention but do not share state — the PO-agent's worktrees are tied to `workflow-state.json`, not to any session-level harness state.

---

## scout (GAP-013 / #29)

- **1.0.0** — Initial per-task read-only file scout
  - `agents/scout.md` — Haiku read-only agent with `maxTurns: 10`, `disallowedTools: Write, Edit, Bash, NotebookEdit`. Given a sub-task's predicted `CHANGED_FILES`, the bundle-resolved `BUNDLE_RULES` from `inject-context` (GAP-008 / #25), `TASK_DESCRIPTION`, and `REPO_ROOT`, pre-reads at most 8 files and returns a structured ~500-token summary: `key_patterns`, `naming_conventions`, `test_file_paths`, `existing_exports`, `warnings` (plus `files_read` / `truncated` metadata). The summary is injected into `coder`'s `SCOUT_SUMMARY` input via `build-implement-tdd` Step 6 so the coder honours per-file naming and test-file placement before writing its first RED test.
  - **Disjoint from `knowledge-scout`** by design: that agent does repo-wide synthesis from `specs/index.yml` at plan time; this one does per-task pre-reading at dispatch time. The two share no dispatch path — `build-implement-tdd` invokes both at different lifecycle stages and forwards different payloads to the coder (`PLAN_CONTEXT` from `knowledge-scout`, `SCOUT_SUMMARY` from `scout`).
  - **Advisory, not gating** — § *Caller fallback contract* in `agents/scout.md` and § *Pre-flight scout dispatch* in `plugins/makato-build/skills/build-implement-tdd/SKILL.md` § Step 6 both document the same rule: on `r1.status == "failure"`, the calling skill logs a `warn` JSONL entry (`step: "scout-skipped"`) and dispatches `coder` **without** `SCOUT_SUMMARY`. On `partial`, the partial `data` payload is forwarded with a `scout-partial` warn entry. This matches the GAP-013 AC explicitly: a scout failure must not halt the run.
  - **8-file cap** — `CHANGED_FILES` priority first (the files the coder will actually modify), then `BUNDLE_RULES` in the order the resolver returned them (most-specific bundle first per `inject-context`'s specificity-precedence rule, `default` last). Truncation surfaces as a `warnings` entry only when `CHANGED_FILES` itself overflows; bundle-rule truncation is silent (lower-priority signal, ordered).
  - `plugins/makato-build/agents/coder.md` patched (1.3.0 → 1.4.0) — adds `SCOUT_SUMMARY` to § *Input* documenting the five-field payload and the absent-input behaviour, plus a § *Behavior Rules* clause requiring the coder to apply `naming_conventions` for the exact target files (overriding `PLAN_CONTEXT.Standards` only when the two conflict for that specific file), write to the scout's `test_file_paths`, avoid duplicating `existing_exports`, mirror `key_patterns`, and surface every `warnings` entry in phase-end JSONL. Scout output is documented as advisory and never overrides `PLAN_CONTEXT.Hard Constraints`.
  - `plugins/makato-build/skills/build-implement-tdd/SKILL.md` patched (1.6.0 → 1.7.0) — Step 6 gets a new § *Pre-flight scout dispatch* sub-section. Resolves bundles via `inject-context.resolve_bundles(...)` (GAP-008 / #25), dispatches the scout, parses its R1 envelope, maps `success`/`partial`/`failure` to coder input + JSONL warnings, mirrors the scout R1 to `build.jsonl` under `step: "r1", data.scout_agent: "scout"`. Guarded: if `plugins/makato-orchestrate/agents/scout.md` is absent (consumer repo running the build pipeline standalone) the scout dispatch is skipped silently — the pipeline stays usable in a developer's hands without `makato-orchestrate` installed, mirroring the existing `workflow-state.sh` cross-plugin guard.
  - `agents/po-agent.md` Step 4d gets a § *Per-task scout pre-read (GAP-013 / #29)* clause documenting that `build-implement-tdd` owns the scout dispatch internally — the PO-agent does NOT call the scout itself (that would mean a round-trip per task, duplicating the bundle resolution work). The scout R1 surfaces in `build.jsonl` via the mirror so the PO-agent's audit-trail read remains complete.
  - `AGENTS.md` and `README.md` patched — scout's row flipped from `(planned)` to **shipped**, dispatch table updated (`build-implement-tdd` Step 6, not `po-agent`), file-structure listings flipped from stub to shipped. Status-banner block adds the `GAP-013 (#29) — agents/scout.md ✓ shipped` entry.

---

## loop (GAP-007 / #33)

- **1.1.0** — Queue source moved from issue labels to the GitHub Projects v2 board
  - **Breaking vs the original AC**: issue #33 suggested polling `gh issue list --label status:ready-for-dev`, but no `status:ready-for-dev` label exists in the repo's label set (and none of the `status:*` labels are auto-emitted by `to-issues` v3.2.0 — the taxonomy is dormant). The makato board (`macatocz/projects/4`) uses a `Status` single-select field as the queue source of truth, and the sibling `issue-to-project sync-lifecycle` writes Status on the board, not labels. Polling labels would therefore poll into a void.
  - `scripts/loop.sh` — `cmd_poll` now reads `.claude/config.json` → `github_project.{owner, number, host}` (via the new `_read_project_config` helper) and runs `gh --hostname <host> project item-list <number> --owner <owner> --format json --limit 9999`. Two-step `jq` filter: drop everything where `content.type != "Issue"` (DraftIssue / PullRequest items never enter the queue), then keep only items whose `status` equals the requested name (default `"Ready"`).
  - **CLI rename**: `--label <L>` is gone — replaced by `--status <NAME>` (default `Ready`). Environment variable rename: `MAKATO_LOOP_LABEL` → `MAKATO_LOOP_STATUS`. `loop-status.json` field rename: `label` → `status_name`.
  - **New env var**: `MAKATO_LOOP_CONFIG` (test-only override of `.claude/config.json` path) and `MAKATO_LOOP_GH_OVERRIDE` (test-only canned `item-list` fixture path). The smoke-test harness uses the latter to stay fully offline.
  - `skills/loop/SKILL.md` — new § *Why the board is the queue source* documents the rationale; § *Prerequisites* requires `/makato-plan:issue-to-project --init` before first invocation; § *Why we don't mutate the board / labels at dispatch* documents the deliberate read-only stance vs `issue-to-project sync-lifecycle`'s write authority over `Status`.
  - `scripts/loop-smoke-tests.sh` — fixture rewritten to mirror `gh project item-list` JSON shape (top-level `items[]` with `content.type` + `content.number` + flat `status` field). Two new scenarios (T10: Status filter; T11: non-Issue exclusion) plus all nine original scenarios still pass. Stub `gh` binary on `PATH` is no longer needed — `MAKATO_LOOP_GH_OVERRIDE` short-circuits the `gh` call inside `cmd_poll`.

- **1.0.0** — Initial autonomous polling driver
  - `skills/loop/SKILL.md` — Operator-facing entry point for unattended runs. Documents the `run` / `poll` / `next` / `status` / `dispatch` / `check-halt` subcommand matrix, the FIFO queue contract from `gh issue list`, the in-flight filter that skips any spec whose `workflow-state.json:current_phase` is anything other than `"done"`, the `loop-status.json` schema, the three-layer single-thread guarantee (in-flight filter + dispatch refusal + inline blocking exec), and the deliberate split between this skill (HALT-000 / queue gate) and `kill-switch` (per-issue HALTs inside the PO-agent's session).
  - `scripts/loop.sh` — Single-script implementation (≈ 250 lines, shellcheck-clean syntax). Six subcommands matching the SKILL contract; `_now` borrowed from `context-handoff.sh` (Python over `date +%N` — macOS lacks nanosecond precision); atomic `_write_status` via `mktemp` + `mv` so partial writes never leave a corrupt JSON file. The PO-agent dispatch is an inline `$MAKATO_CLAUDE_BIN --session loop --autonomous <issue>` exec — single-threaded by construction (next poll cannot run until the subprocess returns).
  - `scripts/loop-smoke-tests.sh` — Nine scenarios covering the four AC-required cases (`--dry-run`, `--once`, HALT detection, single-shot exit) plus contract details (status-file shape, queue filtering by `current_phase`, dispatch refusal under active workflow, in-flight filter symmetry across phases). Stub `gh` binary on `PATH` returns a deterministic fixture; `MAKATO_LOOP_DRY_DISPATCH=1` test hook exercises the full dispatch state-machine without forking a real subprocess.
  - **Kill-switch layering** — `loop` implements only the queue-level HALT-000 (`~/.claude/HALT` poll at every outer-iteration boundary). Per-issue HALTs (HALT-001..010, HALT-007B) remain inside the PO-agent's session via `kill-switch poll`; the loop's next iteration re-derives ground truth from `workflow-state.json` rather than trusting an exit code.
  - **Single-thread guarantee** — Three layers: (1) `in_flight_issues` filter excludes any issue whose spec folder has `current_phase != "done"`; (2) `dispatch` refuses (exit 2) if `.active_workflow.issue` is set to a different issue; (3) the PO-agent runs inline as a blocking subprocess, so the next `gh` poll cannot start until it exits.
  - **`loop-status.json` contract** — Operator-facing live audit, written atomically (mktemp + mv) with auto-stamped `updated_at`. Fields: `label`, `interval_seconds`, `dry_run`, `last_poll`, `queue_depth`, `queue[]`, `active_workflow`, `last_halt_at`, `last_dispatch_issue`, `updated_at`. Sufficient for `tail -f | jq` or `watch loop.sh status` unattended monitoring.
  - **Environment matrix** — `MAKATO_LOOP_INTERVAL` (default 300), `MAKATO_LOOP_LABEL` (default `status:ready-for-dev`), `MAKATO_CLAUDE_BIN` (default `claude`), `MAKATO_HALT_FILE` (default `~/.claude/HALT`), `MAKATO_LOOP_STATE_DIR` (test override), `MAKATO_LOOP_DRY_DISPATCH` (test hook).
  - **Out of scope (v1)** — Priority ordering of the queue (FIFO from `gh issue list`); multi-repo aggregation; GitHub Actions webhook variant (use `issue-to-project --from-webhook` instead); `gh issue edit --remove-label` at dispatch time (the in-flight filter prevents double-dispatch without label mutation).
  - Honours NEVER 3 (HALT-file check runs on every outer iteration; no caching). The dispatch chain inherits NEVER 4 from the PO-agent (the loop itself never touches target-repo source). No new entries in `halt-conditions.md` — `loop`'s only HALT is the existing HALT-000.

---

## po-agent (GAP-006 / #32)

- **1.0.0** — Initial top-level autonomous orchestrator
  - `agents/po-agent.md` — Sonnet outer-loop driver with `maxTurns: 100` and `permissionMode: bypassPermissions`. Reads a `status:ready-for-dev` GitHub Issue, resolves the spec folder via `specs/<key>-*/` prefix-match, reads/inits `workflow-state.json`, and dispatches `makato-build` skills with `--autonomous`. The outer loop is **plan-level**, not per-task: each iteration dispatches ONE `build-implement-tdd` (or `build-implement-goal`) which itself walks the full task list in topological order — the PO-agent never dispatches `coder` directly. After each implementation dispatch, the PO-agent parses the skill's terminal R1 envelope (last fenced ```json block, per RETURN-CONTRACT.md), decides whether to advance to verify → pr → done OR to re-plan via `build-refine` (incrementing `outer_iteration`), and emits its own R1 envelope at termination. Polls `kill-switch poll` and `kill-switch handoff` at every outer-loop boundary. HALT-008 is enforced by `kill-switch poll`, not by the PO-agent.
  - `agents/po-agent.md` documents the four resume flags read on session start (`current_phase == "done"` → idempotent success; `handoff_reason == "context_ceiling"` → continue from `resume_point` with `session_summary` injected; `restart_failed == true` → HALT-007; otherwise fresh dispatch), in-progress recovery (any `in_progress` task with `agent_result == null` is reset to `pending` at Step 4c on the next iteration), conditional `outer_iteration` increment (counts only re-plan attempts, not handoffs or operator kills), and explicit non-scope of source edits, concurrent dispatch, decomposition, and post-merge documentation.
  - **Label application matrix** documented inline: `kill-switch poll` applies `needs-human-review` for HALT-007/008/009; the PO-agent applies it directly via `gh issue edit` for HALT-002 / HALT-003 / HALT-005 / HALT-006 / HALT-STRUCTURAL; HALT-000 and HALT-007B do not label.
  - **Session bookends** — session-start JSONL emitted at Step 0 (with `resumed` flag and `session_count`), session-end JSONL emitted at Step 7 (with `terminal_state`, `outer_iterations`, `sub_tasks_complete`, `github_pr_number`, `halt_code`). Per-step JSONL `status` field maps from R1 `status`: `success` → `ok`, `partial` → `warn`, `failure` → `error`.
  - **Dependency-cycle handling** — Step 4c's plan-graph topological sort treats a detected cycle as HALT-006 (malformed plan), not HALT-STRUCTURAL (which is reserved for sub-agent `data.escalation: "refine"` post-dispatch escalation).
  - **`github_pr_number` propagation contract** — `build-push-to-git --autonomous`'s R1 propagates `data.github_pr_number` from the auto-invoked `build-create-pr`. Fallback path documented: read the last `step:"r1"` entry for `build-create-pr` from `build.jsonl` if the field is absent.
  - Honours NEVER 3 (no cached HALT polls), NEVER 4 (no source edits — `files_changed` and `tests_written` are always empty in R1), NEVER 5 (sole writer of `workflow-state.json`), NEVER 6 (R1 contract — never scrapes prose), NEVER 9 (no `needs-human-review` label on HALT-007B handoff). Frontmatter `disallowedTools: NotebookEdit` only — `Edit` and `Write` are needed for state mutation; the source-edit boundary is enforced by a behavioural allow-list in three locations (frontmatter Permission Boundary, `never-patterns.md` NEVER 4, `AGENTS.md` Security Model) backed by code review.
  - `README.md` and `AGENTS.md` patched — po-agent rows flipped from "stub until GAP-006" to "**shipped**"; file-structure listings updated; workflow ASCII diagram updated to show plan-level outer loop (dispatch build-implement-tdd, not coder); tracking-issue cross-references unchanged.
  - `never-patterns.md` patched — NEVER 4 enforcement clause rewritten to acknowledge that `disallowedTools` is all-or-nothing in Claude agent frontmatter (cannot do path-scoped denial), so the source-edit boundary is enforced behaviourally + code review. `AGENTS.md` Security Model rewritten to match. Both documents now name the three locations the allow-list must appear so the contract is auditable at PR review time.

---

## kill-switch + context-handoff (GAP-004 / #30)

- **1.0.0** — Initial kill-switch surface and proactive context-handoff path
  - `skills/kill-switch/SKILL.md` — PO-agent-only skill that composes four orthogonal shutdowns at every outer-loop boundary: `HALT-000` (operator HALT file), `HALT-009` (`claude-halt` GitHub label, ~60 s poll), `HALT-007` per-task (`budget_consumed_tokens >= budget_limit_tokens`), `HALT-007` daily (`.claude/state/daily-budget-{YYYY-MM-DD}.json` ≥ `MAKATO_DAILY_TOKEN_BUDGET`), `HALT-008` (`outer_iteration >= 3`). Subcommands: `poll`, `handoff` (shim to `scripts/context-handoff.sh`), `record-budget` (atomic increment of `budget_consumed_tokens` + daily ledger), `reset-daily-budget`. Documents three operator levers (HALT file, GitHub label, env-var ceilings) and the four-env-var matrix (`MAKATO_DAILY_TOKEN_BUDGET`, `MAKATO_CONTEXT_WARN_TOKENS`, `MAKATO_MAX_HANDOFFS`, `MAKATO_HANDOFF_DISABLE`).
  - `skills/kill-switch/references/daily-budget.schema.json` — JSON Schema draft-07 for the per-UTC-day budget ledger. `additionalProperties: false`. `runs[]` append-only audit; `ceiling_tokens` omitted entirely when `MAKATO_DAILY_TOKEN_BUDGET` is unset (no-op daily check). Files >30 days are pruned on PO-agent session start (separate skill, out of scope for GAP-004).
  - `scripts/context-handoff.sh` — Implements the HALT-007B proactive-handoff lifecycle: CHECK → CAP → CHECKPOINT → SUMMARISE → EMIT → RESTART. Reads `budget_consumed_tokens` vs `context_warn_tokens` from `workflow-state.json`; respects `MAKATO_MAX_HANDOFFS` (default 5) to prevent infinite restart loops (NEVER 8); requires `session_summary` to be populated before handoff (NEVER 6 — refuses to paper over PO-agent contract violations); emits idempotent `.claude/state/resume-{KEY}.sh` with embedded `current_phase=done` guard; detached `nohup`-based restart so the current session exits cleanly. Falls back to HALT-007 (with `restart_failed: true`) when the `claude` binary cannot be resolved or the cap is reached. `MAKATO_HANDOFF_DRY_RUN=1` performs state mutations without forking — used by the smoke-test harness. Does NOT call Claude directly: the `context-summariser` agent dispatch is owned by the PO-agent, which writes `session_summary` to state BEFORE invoking this script. Keeps shell logic deterministic and unit-testable.
  - `scripts/context-handoff-smoke-tests.sh` — Seven scenarios covering the four AC-required cases (below threshold no-op, threshold→handoff, threshold→restart-fail→HALT-007, cap-exceeded→HALT-007) plus three contract details (emit-resume idempotency, resume-script no-op when phase=done, missing session_summary→HALT-007). Stub `claude` binary via `MAKATO_CLAUDE_BIN` env override.
  - `agents/context-summariser.md` — Haiku sub-agent, `maxTurns: 5`, `disallowedTools: Write, Edit, Bash, NotebookEdit, Task`. Read-only — only `Read` is permitted; `Grep` and `Glob` denied so source files cannot leak into the summary. Strict ≤ 500-token output budget; system prompt enforces a five-block summary shape (RUN / DONE / NEXT / KEY DECISIONS / RESUME ACTION). Returns R1 with `data.summary` carrying the summary text the PO-agent writes verbatim to `workflow-state.json:session_summary` via `workflow-state.sh patch`. Documented why this agent lives in `makato-orchestrate` (outer-loop concern) rather than `makato-build` (code concern).
  - `hooks/check-halt.sh` — `PreToolUse(Bash)` hook. Stats `~/.claude/HALT` (override via `MAKATO_HALT_FILE`); blocks the tool call with HALT-000 stderr if present; `MAKATO_HALT_DISABLE=1` emergency-bypass with audit log to stderr (reserved for hotfix operators, never global). Intentionally small (~50 lines) because it runs on every `Bash` tool call.
  - `halt-conditions.md` — Authoritative reference for HALT-000 through HALT-010 plus HALT-007B and HALT-STRUCTURAL. Each row documents trigger, action, recovery. Explains why HALT-007 (cost control, `needs-human-review`) and HALT-007B (quality control, no label) MUST remain separate codes — the distinction is the hinge of the proactive-handoff design. Documents the dual-write convention: `halt_audit[]` for live state, `orchestrate.jsonl` for cross-session audit trail.
  - `never-patterns.md` — Nine universal NEVER rules covering pre-commit bypass, force-push to default branch, HALT-file-check skipping, target-repo source edits from PO-agent, state-writer multiplicity, R1 contract violations, daily-budget exceedance, handoff-cap exceedance, and `needs-human-review` on HALT-007B. Each rule names the enforcement mechanism (PreToolUse hook, frontmatter `disallowedTools`, code review) and the HALT code that fires before the violation completes.
  - `skills/workflow-state/SKILL.md` patched (1.0.0 → 1.1.0) — schema reference table now lists five new fields (`context_warn_tokens`, `session_summary`, `session_count`, `handoff_reason`, `restart_failed`) alongside the existing 16. `HALT-007B` distinction documented (cost vs quality); `HALT-007` and `HALT-009` rows added. `init` defaults documentation updated with `MAKATO_CONTEXT_WARN_TOKENS` env override.
  - `skills/workflow-state/references/workflow-state.schema.json` patched — five new required fields (`context_warn_tokens` integer ≥ 1, `session_summary` string|null with 4000-char defensive cap, `session_count` integer ≥ 0, `handoff_reason` enum `["context_ceiling", null]`, `restart_failed` boolean). `budget_limit_tokens` description corrected to point at HALT-007 (was incorrectly HALT-007B).
  - `skills/workflow-state/references/smoke-tests.sh` patched — four new cases (T10: GAP-004 fields populated at init with safe defaults; T11: `handoff_reason` enum rejects values outside the canonical pair; T12: canonical `"context_ceiling"` persists; T13: `MAKATO_CONTEXT_WARN_TOKENS` env override honored at init). 13 cases total.
  - `shared/workflow-state.sh` patched — `init` subcommand reads `MAKATO_CONTEXT_WARN_TOKENS` env (default 150000) and seeds all five new fields with safe defaults (`session_count: 0`, `session_summary: null`, `handoff_reason: null`, `restart_failed: false`).

---

## workflow-state (GAP-003 / #26)

- **1.0.0** — Initial `workflow-state` skill and helper
  - `skills/workflow-state/SKILL.md` — Skill documentation covering schema reference, five subcommands (`init`/`read`/`write`/`patch`/`append-lesson`), staleness rule (>24 h triggers stale at session resume — detection is the caller's responsibility), JSONL audit logging requirement, and HALT codes. `halt_audit[]` accommodates future codes `HALT-007B` (context-ceiling, GAP-004 extension) and `HALT-008` (outer-iteration cap) without schema change.
  - `skills/workflow-state/references/workflow-state.schema.json` — JSON Schema draft-07. All 16 required top-level fields per issue #26. Sub-schemas for `sub_tasks[]`, `halt_audit[]`, and `lessons_learned[]` item shapes (each `additionalProperties: false`). ISO-8601 `format: date-time` on all timestamp fields. Top-level `additionalProperties: false`.
  - `skills/workflow-state/references/smoke-tests.sh` — Manual verification harness covering 9 cases (schema parses, init creates valid file, init refuses duplicate, read returns file, read on missing key returns `{}`, patch updates field and timestamp advances, indexed-path patches, append-lesson grows array, invalid write halts). No automated CI hook — matches `shared/` convention in `makato-build`.
  - `shared/workflow-state.sh` — Shell helper (`set -euo pipefail`, positional args, `${VAR:?msg}` for required args). Spec-folder resolution duplicated from `plugins/makato-build/shared/build-log.sh:13-22` (prefix-match `specs/<key>-*/` → fallback `specs/<key>/` → create placeholder). `jq` for all mutations (per issue #26 AC); `python3 + jsonschema` for validation (matches `plugins/makato-plan/skills/issue-to-project` precedent, fail-open if `jsonschema` is not installed). Atomic writes via `mktemp` + `mv`. `updated_at` injected automatically on every write/patch/append-lesson.
  - `plugins/makato-build/skills/build-implement-tdd/SKILL.md` patched (1.5.0 → 1.6.0) — adds guarded `workflow-state patch` calls after the R1-mirror block on the `r1.status == "success"` branch. Cross-plugin path resolved via `git rev-parse --show-toplevel`; `-x` test skips silently when running in a consumer repo without the `makato-orchestrate` plugin present.

---

## Plugin scaffold (GAP-001 / #23)

- **0.1.0** — Initial plugin scaffold
  - `.claude-plugin/plugin.json` created with name, description, author (no `version` field — repo-level release-please + git tags carry the version per suite convention)
  - `AGENTS.md` — Contributor guide: goal, orchestrate boundary, scope inclusions/exclusions, decision test, design principles (state SoT, HALT codes, R1 end-to-end, resumability), security model (PO-agent `bypassPermissions` + safeguards), agent roster table (stubs), skill authoring rules, file structure, `--autonomous` invocation contract, versioning, PR checklist
  - `README.md` — User-facing overview: status banner with tracking-issue references for each follow-up gap, orchestrate boundary, upstream/downstream integration with `makato-plan` and `makato-build`, sibling `issue-to-project` lifecycle hand-off, `--autonomous` propagation table, skills/agents/hooks scaffold tables linked to tracking issues, `orchestrate.jsonl` logging schema, high-level workflow ASCII diagram, file-structure listing, see-also references (AgenticSystem PRD, RETURN-CONTRACT.md, AUTONOMOUS-MODE.md)
  - `CLAUDE.md` — `@AGENTS.md` reference (matches makato-build / makato-change pattern)
  - Directory structure: `skills/`, `agents/`, `hooks/`, `shared/` created with `.gitkeep` placeholders so the empty subdirectories are tracked
  - Root `.claude-plugin/marketplace.json` extended with the `makato-orchestrate` entry so the plugin is discoverable from the makato-suite marketplace
