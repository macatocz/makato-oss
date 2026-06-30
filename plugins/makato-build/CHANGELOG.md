<!-- markdownlint-disable MD013 -->
# Changelog — makato-build

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## `build-log.sh --batch` mode + AUTONOMOUS-MODE.md batched-logging convention (#118 Part B)

Each invocation of `build-log.sh` costs a `bash` startup + `git rev-parse --git-common-dir` + `find specs/` resolution. An autonomous run across 12 skills with 3-5 rows per step is 50-150 fork-execs of pure overhead — material once the test/lint suites are no longer the wall-clock bottleneck.

This commit adds an opt-in batch mode that reads NDJSON from stdin and appends every parsed entry in one shell invocation. Output is byte-for-byte identical to per-row single-entry mode for the same set of entries (verified by smoke test T3).

- **`shared/build-log.sh`** → new `--batch` mode. Signature: `shared/build-log.sh <key> --batch < entries.ndjson`. Reads NDJSON from stdin; skips blank lines and lines that don't parse as JSON (preserves the "logging never crashes" invariant); appends each parsed entry to `<spec>/build.jsonl`. Single-entry mode (`build-log.sh <key> '<json>'`) is unchanged — skills migrate opportunistically with no flag day.
- **`shared/build-log-batch-smoke-tests.sh`** → new. 6 test groups covering: single-entry mode appends one row; batch mode reads NDJSON and appends each row; batch output matches single-entry output byte-for-byte; batch skips blank lines; batch skips malformed JSON lines; batch is idempotent on empty stdin.
- **`AUTONOMOUS-MODE.md` § Batched logging** → new sub-section under § *Logging contract*. Documents the migration pattern (accumulate in a heredoc, flush at step boundary), the cross-step batching warning (don't carry rows past a step boundary or a failure loses the audit trail), and the byte-for-byte equivalence with single-entry output.
- **`skills/build-implement-tdd/SKILL.md`** → 1.9.1 → 1.9.2 — Step 5 (tracer) prose gains an "Optional batched flush" note documenting the three-row flush opportunity (`tracer-stub` → `tracer-test` → `tracer-verify`) at the end of the tracer phase.

---

## Stop forwarding `--autonomous` across cross-skill dispatch (#117)

> **BREAKING (internal contract).** Skills dispatching other skills no longer add `--autonomous` to the downstream invocation. The CLI flag is preserved for developer-driven entry points (a human at the prompt can still run `/makato-build:build-refine GAP-005 --autonomous`); only the skill-initiated dispatch path drops the flag. `$AGENT_ID` already crosses subprocess boundaries via env inheritance and is now designated the canonical bash-level autonomous-mode signal.

The earlier contract required every cross-skill hand-off to forward `--autonomous` explicitly "for symmetry with the CLI surface." In practice this produced redundant plumbing — `$AGENT_ID` was already setting the activation flag in every dispatched skill's falsy-check via Trigger #3, and a missed forwarding caused silent interactive fallback (the loop hangs on the first prompt the PO-agent can't reach). Tests did not assert the forwarding boundary; today they do.

- **`plugins/makato-build/AUTONOMOUS-MODE.md` § *Cross-skill propagation*** → rewritten. The "MUST forward" rule is replaced by "Skills MUST NOT forward `--autonomous` on cross-skill dispatch." The CLI flag stays in place for developer use; downstream skills detect autonomous mode via inherited `$AGENT_ID` (which the PO-agent exports once at session start). Context-bundle fields (`WORKTREE_PATH`, `PRIOR_LESSONS`, `CI_FAILURE_LOG`) are NOT affected by this rule — they continue to be forwarded explicitly because the env cannot carry them.
- **`plugins/makato-build/AUTONOMOUS-MODE.md` § *Default-taking rules per gate*** → the `build-push-to-git` Step 8 row no longer names `--autonomous` in the dispatched invocation; it forwards `$AGENT_ID` implicitly.
- **`skills/build-push-to-git/SKILL.md`** → 1.6.0 — Step 8 hand-off prose no longer claims the flag MUST be forwarded; the "Autonomous Execution" bullet that read "Forward `--autonomous` explicitly" now reads "Do NOT forward `--autonomous`". `WORKTREE_PATH` forwarding stays. The `log-bypass.sh` extras blob updated to `'{"forwarded":["WORKTREE_PATH"]}'` (no longer `["--autonomous","WORKTREE_PATH"]`).
- **`shared/autonomous-propagation-smoke-tests.sh`** → new. 5 test groups (16 assertions): AUTONOMOUS-MODE.md documents the new rule and names `$AGENT_ID` as the canonical signal; no skill prose dispatches another skill with `--autonomous`; every autonomous-capable skill still references `--autonomous` somewhere (preserving the CLI surface); `$AGENT_ID` is still a documented trigger; a subprocess repro of the falsy-check pattern confirms `AGENT_ID`-only env propagation activates autonomous mode.
- **`shared/worktree-path-propagation-smoke-tests.sh`** → updated. The "build-push-to-git Step 8 forwards WORKTREE_PATH alongside --autonomous" assertion is now "forwards WORKTREE_PATH in the context bundle" (no `--autonomous` alongside). The "BEFORE Step 1" entry-guard assertion now matches `[Bb]efore Step 1` (case-insensitive) because #114's collapse turned the bold marker into lowercase prose; the contract is unchanged. 70/70 contract checks pass.

---

## Consolidate HALT-code registry across orchestrate + build skills (#115)

The HALT codes emitted by build-* skills (`MISSING_INPUT`, `BASELINE_BROKEN`, `PUSH_REJECTED`, …) lived in 5 separate `## HALT Codes` tables, one per skill, with no central reference. The PO-agent error-mode table in `po-agent.md` covered numeric `HALT-NNN` codes but had no documented routing for the 17+ string tokens — when a skill emitted `errors: ["BASELINE_BROKEN: ..."]`, the PO-agent fell back to a generic `operator-escalation` for every one of them.

This commit lands a single registry that maps every skill-level token to (origin skills, recovery route, description), shortens each per-skill HALT-Codes section to a forward reference, and adds a smoke test that fails if a new token escapes registration.

- **`plugins/makato-build/halt-codes.md`** → new. 20 tokens registered (the 17 listed in #115 plus the 3 `CARRY_OVER_FAILED` / `RENDER_FAILED` / `STRUCTURAL_BLOCKER` variants discovered during the lift). Three documented PO-agent recovery routes: `refine`, `operator-escalation`, `structural`. Includes a `## Scope and relationship to halt-conditions.md` section that pins the two registries' disjoint domains (numeric `HALT-NNN` lives in orchestrate; uppercase-underscore tokens live here) and a `## Caller contract` documenting that `data.halt_code` is the preferred surface and `errors[]` is the human-readable explanation.
- **`plugins/makato-build/shared/halt-codes-smoke-tests.sh`** → new. Six test groups: registry exists; every expected token is registered with a `\`CODE\`` row; every row carries enough columns (origin + route + description); every SKILL.md HALT-Codes section forwards to the registry; no SKILL.md retains the old multi-row table; numeric orchestrate-level codes are NOT in this registry (HALT-001 … HALT-010, HALT-STRUCTURAL).
- **5 SKILL.md sections collapsed** to a forward-ref + skill-unique behavioural notes (the registry's prose can't carry per-skill narrative like "MISSING_PLAN is soft in build-simplify — proceeds without one"). Touched: `build-refine` 1.7.1 → 1.7.2, `build-simplify` 1.5.1 → 1.5.2, `build-push-to-git` 1.5.1 → 1.5.2, `build-create-pr` 1.6.1 → 1.6.2, `build-address-pr-comments` 1.5.1 → 1.5.2.
- **`plugins/makato-orchestrate/agents/po-agent.md`** → 1.6.1 — error-mode table now has a row pointing at `halt-codes.md` for build-skill tokens. The PO-agent's parsing rule (read `data.halt_code` first; fall back to parsing `[A-Z_]+:` from `errors[0]`) is documented in both files for symmetry.

---

## Extract shared mode-detection, entry-guard, and R1-envelope references (#114)

Deduplicates three blocks that were copied verbatim across the build skills, replacing each inline copy with a one-sentence forward reference to the canonical source. Drift was already visible (build-verify omitted the REPO_ROOT snippet; build-address-pr-comments had an abbreviated guard); a single edit to add the next mode-detection trigger would have required touching 8 SKILL.md files.

**Grep audit:**

- Block A (mode-detection trigger list): **12 inline copies → 0** across the 6 skills that carried both a Step 1a list and a trailing "Autonomous Execution" copy (build-refine, build-simplify, build-push-to-git, build-create-pr, build-address-pr-comments). The per-skill behaviour table that documents what each gate defaults to in autonomous mode is retained — that is genuinely skill-specific.
- Block B (workspace-isolation entry guard): the `if [[ -z "${WORKTREE_PATH}" ]]` bash snippet from AUTONOMOUS-MODE.md is no longer inlined in any skill (**0 copies**). Each skill keeps a single forward-ref sentence naming the HALT semantics and the canonical §; the skill-specific REPO_ROOT derivation (when present) stays where it materially affects spec-artefact reads.
- Block C (R1 envelope top-level shape): `tool_calls_used` and the top-level field boilerplate appears **only in RETURN-CONTRACT.md** (7 references, all canonical); the 5 skills that previously reproduced the JSON shape (build-refine, build-simplify, build-push-to-git, build-create-pr, build-address-pr-comments) now show only the `data.*` payload + a one-line forward-ref.

**Touched files (version bumps):**

- `skills/build-refine/SKILL.md` → 1.7.0 — Block A (Step 1a + Autonomous Execution), Block B, Block C
- `skills/build-implement-tdd/SKILL.md` → 1.9.1 — Block B only (no A/C present); composed on top of #119's CI-failure recovery mode at 1.9.0
- `skills/build-implement-goal/SKILL.md` → 1.5.0 — Block B only (no A/C present)
- `skills/build-simplify/SKILL.md` → 1.5.0 — Block A (Step 1a + Autonomous Execution Mode Detection), Block B, Block C
- `skills/build-verify/SKILL.md` → 1.6.0 — Block B only (the inline-prose variant; no A/C present)
- `skills/build-push-to-git/SKILL.md` → 1.5.0 — Block A (Step 1a + Autonomous Execution), Block B, Block C
- `skills/build-create-pr/SKILL.md` → 1.6.0 — Block A (Step 1a + Autonomous Execution), Block B, Block C
- `skills/build-address-pr-comments/SKILL.md` → 1.5.0 — Block A (Step 1a + Autonomous Execution), Block B, Block C
- `build-review/SKILL.md` — untouched (no autonomous wiring, no duplication)

Canonical sources unchanged: `AUTONOMOUS-MODE.md` § *Activation triggers* (Block A), § *WORKTREE_PATH — workspace-isolation contract* / § *Falsy-check pattern* (Block B), `agents/RETURN-CONTRACT.md` § *R1 envelope schema* (Block C).

---

## `log-bypass.sh` helper replaces inline `autonomous_bypass` JSON literals (#116)

The `autonomous_bypass` JSONL row was previously constructed as an inline JSON literal at every bypassed gate — 17 call sites across 5 skill files in this plugin. Schema drift was already visible (`build-address-pr-comments` added `counts`, `comment_id`, `summary`, `out_of_scope_files`, `follow_up_issue`; `build-push-to-git` added `forwarded`) and none of these extensions appeared in `AUTONOMOUS-MODE.md`. Renaming `bypassed` → `bypass_applied` (or adding the next required field) would have required grepping all 17 sites individually.

This commit lands a single helper that owns the canonical schema and an explicit `extra` extension point.

- **`shared/log-bypass.sh`** → new, executable. Signature: `log-bypass.sh <skill> <key> <gate> <default_taken> <trigger> [extra-json-object]`. Assembles the canonical 5-field shape (`event: "autonomous_bypass"`, `gate`, `bypassed: true`, `default_taken`, `trigger`), merges the optional `extra` JSON object — extras cannot override canonical keys — and delegates the file append to `shared/build-log.sh` so REPO_ROOT / worktree resolution stays in one place. Validates `trigger` against the documented enum (`agent_id` / `cli_flag` / `task_id_bundle`, plus the `<agent_id|cli_flag|task_id_bundle>` placeholder form), exits 2 on missing args or bad trigger, exits 3 on a non-object `extra` payload.
- **`shared/log-bypass-smoke-tests.sh`** → new, 28 assertions across 10 test cases: canonical 5-field shape; extras merged into data; extras cannot override canonical fields; every documented trigger accepted; missing required arg → exit 2; invalid trigger → exit 2; non-object extras → exit 3; non-JSON extras → exit 3; ISO-8601-ms timestamp matches the audit-consumer regex; entry lands in `$REPO_ROOT/specs/<key>-*/build.jsonl`.
- **All 17 inline call sites replaced.** Touched skills (versions, composed on top of #114): build-refine 1.7.0 → 1.7.1; build-simplify 1.5.0 → 1.5.1; build-push-to-git 1.5.0 → 1.5.1; build-create-pr 1.6.0 → 1.6.1; build-address-pr-comments 1.5.0 → 1.5.1. The skill-specific context that previously drifted (counts, comment_id, follow_up_issue, out_of_scope_files, forwarded) is now passed through the documented `extra` parameter and surfaces unambiguously in `data`.
- **`AUTONOMOUS-MODE.md § Logging contract`** → rewritten to reference `log-bypass.sh` as the single source of truth, with a new sub-section *Skill-specific context (`extra`)* documenting how skills extend the schema without drift. The inline JSON example is retained as the audit-grep target; the imperative changes from "emit via `build-log.sh`" to "invoke `log-bypass.sh`".
- **`shared/pr-comments-smoke-tests.sh`** → updated assertions to expect helper calls rather than inline `"gate":"…"` JSON literals (5 assertions retargeted); the version-bump assertion now accepts any `1.4.x+` so future patches don't pin against the exact tuple. 45/45 tests pass.

---

## Dogfood pytest harness for `build-simplify` (GAP-064 / #64 — Part B, also closes #58)

Lands the makato monorepo's own pytest harness scoped narrowly to skill smoke tests, plus the `build-simplify` regression test that proves Part A's no-test-runner contract keeps working. With Part A's SKILL.md contract and Part B's regression test merged, **#58** also closes — its Sub-issue B target ("smoke-test `build-simplify` against a downstream consumer repo") was rerouted by #64 to "dogfood inside the makato repo" once `dcp-specs` went away.

- **pyproject.toml** → new (top-level) — declares the harness scope, pytest as the sole dev dependency, the three `testpaths` (`tests/`, `plugins/makato-build/shared/`, `plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/`), and the `norecursedirs` glob that suppresses double-collection of stale worktree copies under `.claude/worktrees/**`. Inline rationale documents the explicit scope decision: this is the makato monorepo's own smoke-test harness, NOT a "makato is a Python package" declaration; plugin distribution remains via Claude Code's plugin marketplace.
- **tests/test_smoke_build_simplify.py** → new — two smoke tests that drive the full 7-step JSONL arc through `shared/build-log.sh` and assert (1) the on-disk JSONL audit trail matches the documented Step 3 / Step 7 / Step 7a shapes, (2) the synthesized R1 envelope carries the Part A `test_suite_present` and `degraded_confidence` fields and obeys the consistency rule `test_suite_present=False ⇒ degraded_confidence=True`. Test 1 covers the code-file-touch case (autonomous Step 7a bypass; R1 `status: "partial"`); test 2 covers the doc-only-touch case (Step 7a no-op; R1 `status: "success"` with `degraded_confidence: true`). Why simulation-not-live-dispatch: the skill body is LLM-readable markdown — there is no Python entrypoint to import; the test validates the JSONL contract `build-log.sh` emits and the envelope schema downstream consumers parse, which is the actual cross-process contract Part A defines.
- **tests/fixtures/build-simplify-smoke/** → new — the synthetic `BSS-001` fixture: a `plan.md` describing the smoke story and a `synthetic/user_service_wrapper.ts` reproducing the "Wrapper for Wrapper's Sake" anti-pattern from `references/simplification-patterns.md`. Lives under `tests/fixtures/` rather than `specs/` directly because `specs/` is repo-level gitignored; the test materializes a temporary `specs/BSS-001-build-simplify-smoke/` at runtime inside a throwaway git repo so `build-log.sh`'s `--git-common-dir` resolver finds a real REPO_ROOT.
- **plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/conftest.py** → new — fixes the `ModuleNotFoundError: No module named 'fixtures'` collection error documented in #64 Part B's last AC. The conftest's mere presence adds the tests root to `sys.path` automatically; an explicit `sys.path.insert` is included as belt-and-braces so collection works regardless of the pytest invocation directory (repo root, plugin root, or the tests directory itself). 23 dotx-schema-extractor tests now collect and pass cleanly from the repo-level harness.

---

## `build-simplify` no-test-runner handling (GAP-064 / #64 — Part A)

Closes the latent failure mode where `build-simplify` would crash mid-session when dispatched against a project with no runnable test suite (docs-only repo, config-only repo, freshly scaffolded project). Surfaced while trying to execute #58's smoke test against the makato repo itself. Part B (dogfood pytest harness) ships in a follow-up PR.

- **skills/build-simplify/SKILL.md** → 1.4.0 — Step 3 now branches on the gate-scout outcome. Outcome (a) — test runner discovered — captures the baseline as before; outcome (b) — no runner — sets `test_suite_present: false`, skips baseline-capture, and logs a `status: "skip"` row with `reason: "no test runner discovered"`. Step 7 short-circuits when `test_suite_present == false`, skipping the test-run entirely and emitting a verify-skip log with `degraded_confidence: true`. New § *Step 7a — Unverified-change gate (no test runner)* fires only when `test_suite_present == false` AND ≥1 applied simplification touched a file outside `**/*.{md,yaml,yml,json,toml}`: interactive mode prompts y/n before hand-off (n → revert + `UNVERIFIED_HALT`), autonomous mode skips the prompt and emits a per-AUTONOMOUS-MODE.md `autonomous_bypass` JSONL entry plus the upward `data.degraded_confidence: true` signal. Step 8 hand-off message extended with a no-runner note in interactive mode. R1 envelope `data` adds `test_suite_present: bool` and `degraded_confidence: bool`; status mapping documents the autonomous-mode `partial` returned when code files were touched without a verify gate. HALT codes table extends with `UNVERIFIED_HALT` and clarifies `BASELINE_BROKEN` is distinct from the no-runner skip path.
- **AUTONOMOUS-MODE.md** — per-gate table grows a third `build-simplify` row for Step 7a (prompt skipped, `degraded_confidence: true` flows upward). New § *No-test-runner handling in `build-simplify` is a degraded-confidence path, not a HALT* explains the design: `gate-scout` returning no runner is a deterministic environmental condition, not an error; the skill proceeds and surfaces the signal in R1 rather than halting. Names the doc/config glob (`**/*.{md,yaml,yml,json,toml}`) that suppresses the Step 7a gate as a no-op. Names the contrast with `BASELINE_BROKEN` (test runner exists but crashes — still a HALT).

---

## Headless PR-comment handling in autonomous mode (GAP-011 / #36)

Wires `build-address-pr-comments` for safe headless operation under `--autonomous`. The skill already classified MUST-FIX / SHOULD-FIX / CONSIDER / OUT-OF-SCOPE and skipped the user-approval gate; this entry covers the four edge cases that need extra care without a human at the prompt — SHOULD-FIX scope creep, STRUCTURAL HALT, OUT-OF-SCOPE carry-over, and reply-text externalization.

- **skills/build-address-pr-comments/SKILL.md** → 1.4.0 — autonomous-mode policy refined. (AC2) SHOULD-FIX now applies only when every file the comment touches is inside the task's diff scope (`plan.md` `task[].file_targets[]`); out-of-scope SHOULD-FIX is marked DEFERRED with a `[DEFERRED]` reply, a `should-fix-scope-guard` `autonomous_bypass` entry, and an `out_of_scope_files[]` audit list. (AC3) STRUCTURAL MUST-FIX now triggers a dedicated Step 5a flow: post a single `[STRUCTURAL]` summary reply via `gh pr comment`, apply `needs-human-review` to PR + linked issue (auto-creating the label if absent), log per-comment + summary `autonomous_bypass` entries, and exit with R1 `failure` + `data.halt_code: "HALT-003"`. (AC4) OUT-OF-SCOPE comments now open a follow-up GitHub Issue via `gh issue create` with the `makato-carry-over` label (auto-created), reply with the new issue URL, and log `out-of-scope-carry-over` bypass; `gh issue create` failure HALTs `HALT-005` with `CARRY_OVER_FAILED: <comment_id>` rather than posting a half-rendered reply. (AC5) reply text moved entirely to the new shared template file — Step 9 renders each reply from `templates/pr-comment-replies.md`; hard-coded prose in the skill body is now a contract violation, and `RENDER_FAILED: <comment_id>` HALTs the skill rather than posting placeholders. R1 envelope extended with `should_fix_deferred`, `carry_over_issues[]`, and `halt_code` fields; `status` selection rules documented.
- **templates/pr-comment-replies.md** → new — plugin-level template directory introduced (deliberate exception to AGENTS.md § *Skill Authoring* "self-contained skills" rule, pinned by AC5). One section per classification tier plus three autonomous-only sections (`[DEFERRED]` for scope-guard skips, `[OUT-OF-SCOPE]` autonomous with `<follow-up-issue>` URL, `[STRUCTURAL]` for the HALT-003 summary). Placeholder vocabulary documented (`<commit-sha>`, `<fix-summary>`, `<reason>`, `<key>`, `<follow-up-issue>`, `<comment-summary>`); unsubstituted placeholders fail-loud rather than posting half-rendered replies. Bot-vs-human authorship treated uniformly at the reply layer (matches the classification guide's content-overrides-source rule). Versioning policy: adding a section is minor, removing/renaming is a coordinated major bump across consumers.
- **AUTONOMOUS-MODE.md** — per-gate table extended. `build-address-pr-comments` Step 5 row rewritten to capture the scope-guard + carry-over policy; new Step 5a row added for the STRUCTURAL HALT-003 flow. New § *Shared reply templates — `templates/pr-comment-replies.md`* explains the plugin-level template directory and why it overrides the skill-local convention. New § *Label-application exception — STRUCTURAL HALT-003* documents that `build-address-pr-comments` applies `needs-human-review` itself (not the PO-agent) on the AC3 path and explains the idempotency guarantee that keeps the orchestrator's later label write a safe no-op. § *STRUCTURAL MUST-FIX is deliberately not auto-handled* updated to reflect the new post-reply + label + HALT sequence.

## WORKTREE_PATH propagation hardening (GAP-017 / #46 follow-up, #85)

Follow-up hardening pass on PR #87. The 10-angle xhigh review of the initial
propagation patch surfaced 7 CRITICAL runtime bugs that block the autonomous
pipeline end-to-end. This entry records the fixes amended onto the same branch
before merge.

- **shared/build-log.sh** — REPO_ROOT resolution now uses `git rev-parse --git-common-dir` instead of `git rev-parse --show-toplevel`. When the helper is invoked from inside a git worktree, the previous resolver returned the worktree path; combined with `specs/` being gitignored at the repo level, every JSONL entry from worktree-based sub-agents would have landed at `<worktree>/specs/<key>/build.jsonl` — a directory nobody else reads, splitting the audit trail across disconnected files. The new resolver derives the parent of the common `.git` directory and always points at the main checkout regardless of caller CWD.
- **AUTONOMOUS-MODE.md** — § *WORKTREE_PATH — workspace-isolation contract* rewritten. (1) Removed the phantom `${AUTONOMOUS:-false}` env-var check from the falsy-check snippet — no callsite sets it; the canonical agent-level signal is `$AGENT_ID` plus SKILL.md-level enforcement of the `--autonomous` / `task_id` activation set. (2) Added § *Two roots, one contract — `WORKTREE_PATH` vs `REPO_ROOT`* explaining why `specs/<key>-*/` (gitignored) must be read from the main checkout while source edits go to the worktree. Names the four artefact families (source edits, spec reads, audit-trail writes, tracked dot-files) and which root each uses. (3) Expanded the consumer-skill list to 8 entries — added `build-refine`, `build-simplify`, `build-address-pr-comments` plus the `coder` HALT-on-empty rule, matching the new entry-guard prose in those skills.
- **agents/coder.md** Phase 0 — added an autonomous-mode HALT branch. When `$AGENT_ID`, `$AUTONOMOUS_MODE`, or `$TASK_ID` is exported AND `WORKTREE_PATH` is empty, the agent appends a `step:"phase0", status:"error"` JSONL audit entry and emits R1 `failure` with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]` — no silent fallback to the main checkout. Interactive-mode developer-hands callers keep the `git rev-parse --show-toplevel` fallback unchanged.
- **skills/build-push-to-git/SKILL.md** Step 8 — autonomous-mode hand-off now forwards `WORKTREE_PATH` alongside `--autonomous` when dispatching `/build-create-pr`. Previously the bundle carried only the CLI flag; `build-create-pr`'s entry guard would then HALT `MISSING_INPUT`, blocking the autonomous pipeline at the PR-creation hand-off. The hand-off-decision JSONL log entry now records `forwarded: ["--autonomous", "WORKTREE_PATH"]` for audit completeness.
- **skills/build-push-to-git/SKILL.md** + **skills/build-create-pr/SKILL.md** Step 1 — `plan.md`, `stories.json`, `prd.md`, `created-issues.json`, `.github/PULL_REQUEST_TEMPLATE.md` reads now resolve via `$REPO_ROOT/specs/<key>-*/` instead of the (empty) worktree-relative path. The entry-guard prose explains the rationale inline and shows the `git -C "$WORKTREE_PATH" rev-parse --git-common-dir` resolver. Both skills now declare REPO_ROOT alongside WORKTREE_PATH at the same entry-guard block.
- **skills/build-implement-tdd/SKILL.md** + **skills/build-implement-goal/SKILL.md** — entry guard relocated to BEFORE Step 1 (Step 1 calls `AskUserQuestion` in interactive mode; the previous "immediately after Step 1" prose was timing-fragile and would have deadlocked an autonomous dispatch with empty `WORKTREE_PATH` at the prompt). New prose also adds the `REPO_ROOT` resolution snippet alongside the worktree falsy-check.
- **skills/build-simplify/SKILL.md** + **skills/build-address-pr-comments/SKILL.md** + **skills/build-refine/SKILL.md** — added § *Input* and § *Workspace-isolation entry guard* sections so the three additional autonomous-mode-callable skills behave consistently with verify / push-to-git / create-pr. Each declares `WORKTREE_PATH` as mandatory-in-autonomous, falls back to `git rev-parse --show-toplevel` in interactive mode, and resolves `REPO_ROOT` for spec-folder reads. The build-simplify version notes `sensor-fixer` as a separate autonomous-mode caller alongside the PO-agent.
- **shared/worktree-path-propagation-smoke-tests.sh** — extended from 31 to 70 contract assertions. New coverage: (1) all 8 consumer skills carry the entry-guard prose; (2) skills whose Step 1 calls `AskUserQuestion` declare "BEFORE Step 1" in the entry-guard; (3) every spec-reading consumer resolves `REPO_ROOT` via `git-common-dir`; (4) `build-log.sh` does NOT use bare `--show-toplevel` as the primary resolver; (5) `build-push-to-git` Step 8 forwards `WORKTREE_PATH` to `build-create-pr`; (6) `coder.md` Phase 0 declares MISSING_INPUT on empty WORKTREE_PATH and detects autonomous mode via `AGENT_ID`; (7) `AUTONOMOUS-MODE.md` documents the `Two roots, one contract` split and does NOT reference the phantom `$AUTONOMOUS` env var. Runs in <1s.

---

## WORKTREE_PATH propagation (GAP-017 / #46 follow-up, #85)

- **AUTONOMOUS-MODE.md** — new § *WORKTREE_PATH — workspace-isolation contract* documents the dispatch-bundle field PO-agent injects on every autonomous-mode invocation. Specifies: mandatory in autonomous mode (HALT R1 `failure` with `MISSING_INPUT: WORKTREE_PATH required in autonomous mode` when empty), optional in interactive mode (fall back to `git rev-parse --show-toplevel`), forwarded explicitly through every hand-off, injected into every agent dispatch. Includes the canonical falsy-check bash snippet and the `git -C` vs `cd` rationale. Names the five consumer skills plus the `coder` agent.
- **skills/build-implement-tdd/SKILL.md** → 1.8.0 — new § *Input* declares `WORKTREE_PATH` as mandatory-in-autonomous; new § *Workspace-isolation entry guard* applies the falsy-check pattern before any plan-analyst / coder / scout dispatch. Step 6 coder-dispatch bundle and the per-task scout dispatch both forward `WORKTREE_PATH` verbatim.
- **skills/build-implement-goal/SKILL.md** → 1.4.0 — same pattern: § *Input* + § *Workspace-isolation entry guard*; BUILD / VERIFY RUNTIME / TEST / VERIFY phases all run from `$WORKTREE_PATH`.
- **skills/build-verify/SKILL.md** → 1.5.0 — § *Input* + § *Workspace-isolation entry guard* added before Gate 0; gates 1–5 inherit the working directory.
- **skills/build-push-to-git/SKILL.md** → 1.4.0 — § *Input* + § *Workspace-isolation entry guard* added before `git status`; ensures `git commit` / `git push` operate on the worktree's branch.
- **skills/build-create-pr/SKILL.md** → 1.5.0 — § *Input* + § *Workspace-isolation entry guard* added before `git status -sb`; ensures `gh pr create` resolves the worktree's branch.
- **agents/coder.md** → 1.5.0 — new `WORKTREE_PATH` input (optional; populated by `build-implement-tdd` in every dispatch); new **Phase 0 — Workspace isolation** runs `cd "$WORKTREE_PATH"` (or the `git rev-parse --show-toplevel` fallback) before Phase 1 RED so every file edit, git invocation, and test command lands on the right branch.
- **shared/worktree-path-propagation-smoke-tests.sh** — new 31-check static contract test verifies: AUTONOMOUS-MODE.md anchors the section + falsy-check + HALT message + fallback; each of the five consumer skills declares the input, the entry-guard, the mandatory-in-autonomous note, and the fallback; coder.md declares the input + Phase 0 + the `cd` invocation; the producer→consumer chain (PO-agent → build-implement-tdd → coder) all reference the canonical key. Documentation/grep test because the consumer half is LLM instructions, not executable code — a runtime test would require booting the full dispatch chain and the markdown is the source of truth the LLM reads.

---

## Per-task scout wiring (GAP-013 / #29)

- **skills/build-implement-tdd/SKILL.md** → 1.7.0 — Step 6 grows a new § *Pre-flight scout dispatch (GAP-013 / #29)* sub-section between the blockedBy enforcement clause and the coder dispatch. For every `mode: tdd` task in topological order, the skill now: (1) resolves bundles via `inject_context.resolve_bundles(task.files, yaml.safe_load(open('plugins/makato-build/config/context-bundles.yml')))`; (2) dispatches `plugins/makato-orchestrate/agents/scout.md` with `TASK_DESCRIPTION`, `CHANGED_FILES`, `BUNDLE_RULES` (after `{repo}` substitution), `REPO_ROOT`; (3) parses the scout's R1 per `RETURN-CONTRACT.md` § Caller parsing rule; (4) maps R1 status to coder input — `success` forwards `r1.data` as `SCOUT_SUMMARY` and mirrors R1 to `build.jsonl`; `partial` forwards the partial payload and emits a `scout-partial` warn entry; `failure` (or R1 contract violation) skips `SCOUT_SUMMARY` and emits a `scout-skipped` warn entry. Guarded: when `plugins/makato-orchestrate/agents/scout.md` is absent on disk (consumer repo running the build pipeline standalone), the scout dispatch is skipped silently and the coder is dispatched without `SCOUT_SUMMARY` — same cross-plugin guard pattern as the existing `workflow-state.sh patch` call at the end of Step 6. Scout output is **advisory**, never gating, per the GAP-013 AC.
- **agents/coder.md** → 1.4.0 — § *Input* gets a new `SCOUT_SUMMARY` field (optional, GAP-013 / #29) documenting the five-field payload from `plugins/makato-orchestrate/agents/scout.md`: `key_patterns`, `naming_conventions`, `test_file_paths`, `existing_exports`, `warnings`. Absence-handling documented inline (scout failure, plugin absent, or dispatch skipped → proceed without it; `PLAN_CONTEXT` remains binding). New § *Behavior Rules* clause requires the coder to apply `naming_conventions` for the exact `TASK.files` (overriding the broader `PLAN_CONTEXT.Standards` only when the two conflict for that specific file), write test files to the scout's `test_file_paths`, never duplicate or shadow `existing_exports`, mirror `key_patterns` in the RED test before introducing fresh patterns, and surface every `warnings` entry in its phase-end JSONL `data` so the audit trail records what the coder saw.

---

## Context bundle resolution skill (GAP-008 / #25)

- **config/context-bundles.yml** → 1.0 — new canonical bundle registry mapping changed-file globs to ordered rule-file paths. Defines four canonical bundles: `typescript` (`**/*.ts`, `**/*.tsx`, `**/*.mts`, `**/*.cts`), `python` (`**/*.py`, `**/*.pyi`), `sql` (`**/*.sql`, `**/migrations/**`, `**/schema/**`), and `default` (`**/*` catch-all). Rule paths use `{repo}` placeholder substituted by `knowledge-scout` at resolution time with the agent's `REPO_NAME` input. Schema requires every bundle to declare `name`, `globs[]`, and `rules[]`; the `default` bundle is mandatory — its absence raises HALT-006.
- **shared/inject_context.py** → 1.0 — pure-function resolver (stdlib only — no PyYAML dependency at the resolver layer; caller pre-parses the YAML). `resolve_bundles(changed_files, config) -> (rules, warning)` implements glob-specificity-first ordering (literal-segment count), config-declaration order tie-break, `default` bundle always appended last, dedup preserving first occurrence, no-match-fallback returning a `{"code": "no-match-fallback", "unmatched_files": [...]}` warning tuple, and `BundleResolutionError` carrying `halt_code="HALT-006"` when `default` is absent. Custom segment-wise globstar matcher (Python 3.12 stdlib `fnmatch` lacks `**` semantics; `pathlib.PurePath.full_match` would require 3.13+).
- **shared/test_inject_context.py** → 1.0 — 9 stdlib `unittest` cases: single-match, multi-match + dedup, two specificity cases (Python over default; SQL migration-path), empty input, no-match warning, missing-default → HALT-006, and two integration cases that load the real `context-bundles.yml` and exercise mixed workloads. Run via `python3 -m unittest discover plugins/makato-build/shared -p 'test_*.py'`.
- **skills/inject-context/SKILL.md** → 1.0.0 — new shared skill documenting the resolution contract (inputs, output tuple shape, warning dict schema, HALT-006 path), usage by `knowledge-scout` (parse → substitute `{repo}` → resolve → handle HALT/warning → pre-read up to 8 rule files), and the versioning policy (changes to the tuple shape, warning schema, or specificity semantics are major bumps coordinated with every consumer).
- **agents/knowledge-scout.md** → 1.3.0 — frontmatter description updated from 3-step to 4-step process; new `CHANGED_FILES` input documented; new **Step 0 — Resolve context bundles** inserted before the existing SPECS_ROOT discovery, with sub-steps 0a (parse `context-bundles.yml`), 0b (substitute `{repo}` placeholder), 0c (call `resolve_bundles`; handle HALT-006 by short-circuiting to R1 failure; append `no-match-fallback` warning to `build.jsonl` when surfaced), and 0d (pre-read up to 8 resolved rule files, tolerating missing paths). Bundle context supplements but does not replace dcp-specs synthesis.

---

## Semgrep route split: security vs style (#73)

- **shared/parse-sarif.py** — added `_semgrep_category()` helper and category-prefix logic in `parse_sarif()`. For any run whose `tool.driver.name` starts with `semgrep`, each finding's `rule` field is now emitted as `{category}.{original_rule_id}` (e.g. `security.python.lang.security.deserialization.use-of-pickle`). Category is resolved from (1) `result.properties.category`, (2) `rule_def.properties.tags`, (3) rule-id segment heuristic — first match wins, fallback is `style`. New Fixture 7 in `--selftest` covers all three resolution paths.
- **shared/finding-routes.json** — replaced single `semgrep:*` catch-all with two explicit routes: `semgrep:security.*` (fallback `build-fix-security`) and `semgrep:style.*` (fallback `build-simplify`). Removes incorrect routing of security findings to `build-simplify`.

---

## Definition-of-Done shared skill (GAP-009 / #28)

- **skills/definition-of-done/SKILL.md** → 1.0.0 — new canonical, versioned, machine-checkable Definition of Done shared across the makato-build pipeline and the makato-orchestrate PO-agent. **Automated tier (12 items)**: tests pass, conditional coverage ≥ threshold, lint clean, type-check clean, zero CRITICAL sensor findings, conventional commits, branch rebased on `origin/main`, no `TODO`/`FIXME` without tracking issue, no hard-coded credentials, `build.jsonl` entry per skill step, R1 JSON block in every agent return, PR description contains `Closes #N`. **Manual tier (6 items)**: all decomposed sub-tasks `status: success`, no unresolved `MUST-FIX` PR comments, `outer_iterations < 3` (HALT-008), `human_review_cycles < MAX` (HALT-010), no `needs-human-review` label, PR approved (or `skip-review` flag set). The skill is a checklist, not an enforcer — each item names the consumer skill/agent that enforces it. Item count is contract: adding, removing, renumbering, or merging items is a major bump (`1.0.0` → `2.0.0`) plus coordinated update to every consumer in § Cross-references.
- **agents/coder.md** → 1.3.0 — Phase 4 (VERIFY) now references `skills/definition-of-done/SKILL.md` Automated tier as the authoritative checklist. Items 1 (tests pass, zero new failures), 10 (`build.jsonl` written), and 11 (R1 envelope emitted) are enforced directly in this agent; items 2–9 and 12 are downstream. New Behavior Rules bullet forbids declaring VERIFY complete with items 1, 10, 11 unsatisfied.
- **skills/build-verify/SKILL.md** → 1.4.0 — new `### Definition-of-Done — Automated Tier Mapping` section at the top of the Workflow, mapping each of the 12 automated items to its enforcing gate (or sibling skill) and the HALT code that fires when the item is unmet in autonomous mode (HALT-001/002/004/005 as applicable). Step 9 hand-off now requires every item 1–12 to be satisfied before printing PASS.

---

## Autofix-then-skill execution path (#60)

- **agents/sensor-fixer.md** → 1.1.0 — added Phase 0 batched-autofix pre-pass before the per-finding loop. The agent now groups findings by the autofix `cmd` declared in `finding-routes.json` for routes whose `action` is `autofix` or `autofix-then-skill`, runs each distinct cmd **once** on the union of touched files, re-parses, and drops resolved findings before Phase 1 dispatch begins. This collapses N redundant per-finding CLI invocations into one batched call and clears deterministic findings without any LLM round-trip. New `loop: 0` / `action: "autofix-batched"` audit-row shape documented in §5. R1 envelope §4a extended with `phase0_resolved` and `phase0_cmds_run` counters; `"autofix-batched"` joins `skills_used` when Phase 0 fires. New §3.1 Helper Functions block defines the contracts for `finding_route_key`, `lookup_route` (exact-then-glob, first-match-wins — required for glob keys like `ruff:UP*` / `markdownlint:MD0*` / `semgrep:*` to actually match real findings), `reparse_after_autofix`, and `append_jsonl`. Pseudocode rewritten with quoted expansions and `read -ra cmd_argv` so multi-word route cmds (`"ruff check --fix --select UP"`) and file paths containing spaces are handled safely. Four new hard rules: NEVER skip Phase 0 when routes declare autofix; NEVER treat a Phase 0 cmd failure as fatal; NEVER put shell metacharacters in a route `cmd`; NEVER rely on literal `jq '.routes[$key]'` lookup (use `lookup_route`).
- **skills/build-resolve-finding/SKILL.md** → 1.1.0 — recognized `action: "autofix-then-skill"` as a valid route value in §3. New decision-tree branch routes `skill` and `autofix-then-skill` both into Branch 2, picking `route.skill` for the former and `route.fallback_skill` for the latter. Documented the post-Phase-0 invariants: a `autofix` finding arriving here is already-attempted-and-failed-by-the-CLI (Branch 1 runs a targeted single-file retry), and a `autofix-then-skill` finding arriving here goes straight to its `fallback_skill`. §4 output JSON now lists `autofix-then-skill` in the `action` enum. Skill-name examples extended to `makato-core:markdown` for the residual MD0xx case wired by #59.

---

## Cross-plugin workflow-state hook (GAP-003 / #26)

- **skills/build-implement-tdd/SKILL.md** → 1.6.0 — added a guarded `workflow-state patch` call after the existing R1-mirror block on the `r1.status == "success"` branch. Cross-plugin path resolved via `git rev-parse --show-toplevel`; `-x` test on `plugins/makato-orchestrate/shared/workflow-state.sh` skips the block silently in consumer repos where the orchestrate plugin is absent. The call is unconditional on autonomous mode (this skill always runs autonomously per AUTONOMOUS-MODE.md) and conditional only on R1 success — `partial`/`failure` paths defer state mutation to the PO-agent (GAP-006 / #32), which reads from `build.jsonl`.

---

## Autonomous mode (cross-cutting, GAP-005 / #27)

- **AUTONOMOUS-MODE.md** — new convention doc at the plugin root: activation triggers (CLI `--autonomous`, context-bundle `task_id`, `$AGENT_ID` env var), per-gate default-taking rules, `autonomous_bypass` log-event schema, per-skill applicability matrix, cross-skill flag propagation rule, and the explicit list of skills NOT in scope (`build-sensors`, `build-verify`, the implement loops, the review/simplify skills, `build-resolve-finding`, `build-start`). Mirrors `plugins/makato-plan/skills/to-issues/SKILL.md` v3.4.0 mode-detection pattern verbatim so a contributor reading either plugin sees the same shape.
- **skills/build-refine/SKILL.md** → 1.6.0 — added Step 1a `Mode detection` block and Autonomous Execution section. In `--autonomous` mode the Step 1 work-item-key prompt requires the key as an argument (HALT `MISSING_INPUT` otherwise) and Step 11 plan-review (in-chat / in-browser) is bypassed entirely — `plan.md` is written and the skill proceeds straight to hand-off. R1 envelope documented; HALT codes: `MISSING_INPUT`, `SPEC_NOT_FOUND`, `MISSING_ARTIFACTS`, `INVALID_FILE_TARGET`, `UNCOVERED_AC`.
- **skills/build-push-to-git/SKILL.md** → 1.3.0 — added Step 1a `Mode detection` block and Autonomous Execution section. In `--autonomous` mode the Step 4 commit-grouping confirmation uses each plan task's `commitMessage` verbatim, the Step 6 push prompt is skipped (pre-push hook still fires), and the Step 8 hand-off auto-invokes `/build-create-pr <key> --autonomous` (flag is forwarded explicitly). R1 envelope documented; HALT codes: `MISSING_INPUT`, `PROTECTED_BRANCH`, `NOTHING_TO_COMMIT`, `COMMIT_FAILED`, `PUSH_REJECTED`.
- **skills/build-create-pr/SKILL.md** → 1.4.0 — added Step 1a `Mode detection` block and Autonomous Execution section. In `--autonomous` mode the Step 1 work-item-key prompt falls back to reading the most-recent `build.jsonl` session entry in the spec folder for `issue` and `branch` fields, and the Step 4 PR-draft approval is bypassed — the PR body is rendered entirely from spec artifacts and workflow-state with no human authoring. `Closes #<n>` injection from `created-issues.json` (D20) is the canonical issue-link source. R1 envelope documented; HALT codes: `MISSING_INPUT`, `UNPUSHED_COMMITS`, `GH_AUTH_FAILED`, `PR_CREATE_FAILED`.
- **skills/build-address-pr-comments/SKILL.md** → 1.3.0 — added Step 1a `Mode detection` block and Autonomous Execution section. In `--autonomous` mode the Step 5 classification approval is bypassed: MUST-FIX (non-STRUCTURAL) and SHOULD-FIX are auto-applied, CONSIDER and OUT-OF-SCOPE are skipped; STRUCTURAL MUST-FIX is deliberately NOT auto-handled — the skill HALTs with R1 `status:"failure"` + `STRUCTURAL_BLOCKER` so the PO-agent (GAP-006 / #32) escalates to re-planning. Step 8 push-confirm is also skipped. R1 envelope documented; HALT codes: `MISSING_INPUT`, `PROTECTED_BRANCH`, `STRUCTURAL_BLOCKER`, `BUILD_FAILED`, `PUSH_REJECTED`.

---

## R1 return contract (cross-cutting, GAP-002 / #24)

- **agents/RETURN-CONTRACT.md** — new authoritative schema doc defining the R1 envelope (`schema`/`agent`/`status`/`summary`/`files_changed`/`tests_written`/`errors`/`tool_calls_used`/`data`). Per-agent rules, parsing pseudocode, and audit-log integration documented. Versioned via the `schema` field so future R2 can coexist during migration.
- **agents/coder.md** → 1.2.0 — added `## Output Contract (R1)` section with success/partial/failure mapping and the per-agent `data` keys (`phase_reached`, `unit_tests`, `integration_tests`, `new_failures`, `escalation`, `task_index`).
- **agents/diff-reviewer.md** → 1.2.0 — added R1 section; `status: "failure"` when CRITICAL findings remain; `errors[]` carries the CRITICAL finding text.
- **agents/sensor-fixer.md** — added R1 section (§4a) alongside the existing run-summary block; `status: "partial"` on residual carry-over; `errors[]` carries unresolved-finding fingerprints.
- **agents/knowledge-scout.md** → 1.2.0 — added R1 section; `loaded: false` graceful fall-through is a valid `status: "success"`.
- **agents/plan-analyst.md** → 1.3.0 — added R1 section; `data` mirrors the existing prose Plan Analysis metadata fields.
- **agents/gate-scout.md** → 1.3.0 — added R1 section; `data` mirrors the existing Gate Commands fields including `lint_ci_divergence` and `java_version_required`.
- **skills/build-implement-tdd/SKILL.md** → 1.5.0 — coder dispatch now parses the R1 envelope from the last `json`-fenced block via `JSON.parse()` instead of scraping prose. R1 envelope mirrored into `build.jsonl` under `step: "r1"` for full machine-contract preservation in the audit trail. Backward-compatible `task-escalate` warn entry preserved on `status: "failure"`.

---

## `build-grill-with-docs` skill

- **1.3.2**
  - sagibeast-alignment audit: flatten `description: >-` multiline folded scalar to a single-line string per frontmatter-spec
  - move two unkeyed prose paragraphs out of the YAML frontmatter block into a new `## When to Use` section in the body (the prose had no key binding and broke the YAML)

## Plugin-level

- **0.5.0**
  - Add Security Model section to README.md and AGENTS.md documenting `coder` agent's `bypassPermissions` scope, safeguards, and contributor rule against adding elevated permissions to new agents
  - Fix AGENTS.md `shared/build-log.sh` calling convention — remove stale symlink claim; document that skills call the script as a bare relative path from the plugin root context
  - Add `shared/baseline-guide.md` — canonical test baseline rules extracted from `implement-tdd`, `implement-goal`, and `simplify` skills to eliminate duplication

- **0.4.0**
  - Design Principle 4 extended: log every agent decision that deviates from the happy path using `status: "decision"` or `status: "warn"` — classification choices, escalations, retries, and workarounds must be persisted to `build.jsonl` so sessions are reconstructable

- **0.3.0**
  - Align all spec folder references from `spec/<key>/` to `specs/<key>-<slug>/` to match makato-plan's naming convention
  - Update `shared/build-log.sh` to resolve the spec folder via prefix-match (`find specs/<key>-*`) instead of an exact path
  - Update hooks to scan `specs/*/build.jsonl` and use `specDir='specs'` in embedded scripts

- **0.2.0**
  - Rename all 11 skills with `build-` prefix for unambiguous invocation (`/makato-build:build-refine` vs `/makato-build:refine`)
  - Add `shared/build-log.sh` script — all skills now call the script for JSONL appends instead of writing inline
  - Add `shared/` symlink in each skill directory so `shared/build-log.sh` is reachable without path escapes
  - Update hooks to match renamed skill names in JSONL `skill:` field checks

---

## `build-start` skill

- **1.3.1**
  - Step 3: remove ADR-0006 violation — `stories.json` absent path no longer invokes `/makato-plan:decompose` inline; now stops with a hard STOP directing the user to run makato-plan first and return

- **1.3.0**
  - Step 2b: upstream sync check — if an `upstream` remote exists, fetch it and warn if the branch base is N commits behind `upstream/main`; offer to rebase before proceeding
- **1.2.0**
  - `plan.md` already-exists path changed from hard-stop to interactive recovery: show plan summary and offer Continue / Start fresh (archive to `plan.md.bak`) / Implement now — applies to both ticket and local-work paths
  - `stories.json` absent path now checks for `prd.md` + `design.md` presence before stopping; if both exist, offer to run `/makato-plan:decompose` inline and continue to `/build-refine`
- **1.1.1**
  - Replace `spec/<key>/` paths with `specs/<key>-*/` prefix-match to align with makato-plan folder naming
- **1.1.0**
  - Add no-ticket path: user can enter a slug instead of a GitHub key; skill writes `spec/local-<slug>/design.md` via a 3-question interview
  - Add git pre-flight (Steps 2a–2c): clean working tree check, `git fetch + branch divergence` check, main/master → offer to create feature branch
  - Renamed from `start` to `build-start`
  - JSONL appends now use `shared/build-log.sh`
- **1.0.0**
  - Initial — pre-flight entry point for makato-build sessions; validates spec prerequisites, captures TDD vs goal mode, initializes build.jsonl session-start entry, and hands off to /build-refine

---

## `build-refine` skill

- **1.5.3**
  - Step 5.5 narration: drop `dcp-specs` term — knowledge graph is sourced from "project specs" (in-repo `<REPO_ROOT>/specs/` or `makato.config.json.specsRoot`); user-facing log line now reads "Knowledge graph: {N} hard constraints loaded from project specs ({source})"
  - Reflects knowledge-scout 1.1.0 contract: no sibling-directory fallback, no `dcp-specs` naming

- **1.5.2**
  - Step 8: add file target path validation — all `files` entries in each task must be relative paths within the repo root; skill stops and reports any path beginning with `/` or containing `..` before writing `plan.md`
  - Frontmatter: add `model: opus` hint

- **1.5.1**
  - Step 1: remind user of direct invocation pattern (`/makato-build:build-refine ISSUE-1234`) when asking interactively
  - Step 11: `AskUserQuestion` prompt reworded to "The plan is ready. How would you like to review it before implementation starts?" with option descriptions clarifying chat vs. interactive HTML
- **1.5.0**
  - Step 7: add mixed-mode sequencing rule — TDD tasks precede goal tasks by default; encoded as `runOrder: [tdd, goal]` in plan frontmatter; exception noted in Scope Flags if a goal task is a structural prerequisite
  - Step 8: task schema extended with `blockedBy` (list of task indices with compile-time dependency) and `commitMessage` (conventional commit draft pre-populated by refine); both fields are required in all plans
  - Step 12: add grill-with-docs recommendation rule — recommend when `glossary.md` has ≥3 terms or plan touches domain-specific field names; skip for infra/config-only changes
- **1.4.2**
  - Replace `spec/<key>/` paths with `specs/<key>-*/` prefix-match to align with makato-plan folder naming
- **1.4.1**
  - Add local-work path in Step 3: if key starts with `local-`, accept `design.md` alone (no `stories.json` required); derive synthetic AC-1 from goal
  - Renamed from `refine` to `build-refine`
  - JSONL appends now use `shared/build-log.sh`

---

## `build-grill-with-docs` skill

- **1.3.1**
  - Step 1: ADR path probe now loads `@references/adr-criteria.md` for the probe order instead of repeating the list inline
  - Step 7: ADR routing rule inline prose replaced by a reference load from `adr-criteria.md` — single source of truth for routing decisions
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - ADR path failure fallback: when the user skips ADRs or the directory cannot be created, ADR-worthy decisions are now written to `decisions.md` with `[ADR-PENDING]` marker instead of being silently dropped
- **1.2.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.2.0**
  - Renamed from `grill-with-docs` to `build-grill-with-docs`; JSONL appends now use `shared/build-log.sh`

## `build-implement-tdd` skill

- **1.4.1**
  - Step 3: replace verbose inline baseline prose with `@shared/baseline-guide.md` load; flakey test retry rule added — re-run single failing test once if no source code changed before classifying
  - Step 5: trim tracer bullet inline prose to load `@references/tdd-cycle-rules.md` directly; removes ~20 lines of duplication with the reference file
  - Step 6: add `blockedBy` cycle detection pre-flight — topological sort before first dispatch; stops with report if circular dependency detected
  - Frontmatter: add `model: opus` hint

- **1.4.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: baseline-gate decision logged with `status: "decision"` when user chooses to continue with broken baseline
  - Step 6: task escalation logged with `status: "warn"` when coder returns `escalation: refine`
  - Step 8: session summary printed from `build.jsonl` warn/decision entries at handoff; full remaining pipeline shown
- **1.3.0**
  - Step 3: broken baseline gate — if `pre_existing_failures > 0`, present Continue-with-broken-baseline vs Fix-baseline-first choice instead of silently proceeding; decision logged to `build.jsonl`
  - Step 5: tracer topmost-layer fallback for non-monolith — if no standard layer (ui/controller/service/repository/persistence) is detected, use the public entry point of the module being modified as the topmost layer
  - Step 6: `blockedBy` enforcement — tasks with a non-empty `blockedBy` list are not dispatched concurrently with their blocking tasks; hard sequencing replaces prose-only "prerequisite" description
  - Step 6: `commitMessage` and `blockedBy` now included in the TASK object passed to the coder agent
- **1.2.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.2.0**
  - Renamed from `implement-tdd` to `build-implement-tdd`; JSONL appends now use `shared/build-log.sh`

## `build-implement-goal` skill

- **1.3.1**
  - Step 3: replace inline baseline prose with `@shared/baseline-guide.md` load; flakey test retry rule added
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: baseline-gate decision logged with `status: "decision"` when user chooses to continue with broken baseline
  - Step 5: fix-vs-escalate decisions logged by coder agent
  - Step 7: session summary printed from `build.jsonl` warn/decision entries at handoff; full remaining pipeline shown
- **1.2.0**
  - Step 3: broken baseline gate — if `pre_existing_failures > 0`, present Continue-with-broken-baseline vs Fix-baseline-first choice instead of silently proceeding; decision logged to `build.jsonl`
- **1.1.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.1.0**
  - Renamed from `implement-goal` to `build-implement-goal`; JSONL appends now use `shared/build-log.sh`

## `build-simplify` skill

- **1.2.1**
  - Step 3: replace inline baseline prose with `@shared/baseline-guide.md` load
  - Step 4: security constraint guard added — removals of input validation, authentication/authorization checks, or security guards are classified as ESCALATE regardless of test pass/fail state

- **1.2.0**
  - Step 6: ESCALATE findings now logged to `build.jsonl` with `status: "warn"` before recommending re-plan
  - Step 8: handoff shows full remaining pipeline (`/build-review` → `/build-verify` → ...)
- **1.1.2**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.1.1**
  - Renamed from `simplify` to `build-simplify`; JSONL appends now use `shared/build-log.sh`

## `build-review` skill

- **1.3.2**
  - Workflow: add explicit no-commit guard — mechanical and CRITICAL fixes accumulate in the working tree; `git add`/`git commit` are forbidden during this skill
  - Step 5.5 (new): re-run mechanical fixes after the CRITICAL loop closes — catches formatting drift introduced by CRITICAL fixes before the working tree is handed to `/build-push-to-git`

- **1.3.1**
  - Frontmatter: add `model: opus` hint

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 5: CRITICAL findings now logged to `build.jsonl` with `status: "warn"` before fixes are applied
  - Step 6: handoff shows full remaining pipeline (`/build-verify` → `/build-push-to-git` → `/build-create-pr`)
- **1.2.0**
  - Step 5: zero-findings trigger is now LOC-gated — only trigger recheck when `git diff main...HEAD --stat` LOC count > 50; diffs ≤ 50 LOC accept a clean first pass with citation record only
- **1.1.1**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.1.0**
  - Renamed from `review` to `build-review`; JSONL appends now use `shared/build-log.sh`

## `build-verify` skill

- **1.3.1**
  - Step 5: flakey test retry rule added — if a unit test fails but no source code changed, re-run once; log as flaky-pass if it passes, classify normally if it fails again
  - Step 6: same flakey retry rule applied to integration gate

- **1.3.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 3: gate-retry decisions logged with `status: "warn"` on every BUILD gate failure and retry
  - Step 4: CI lint divergence check — gate-scout `lint_ci_divergence` field consumed; both local and CI lint commands run when they differ; WARNING emitted if CI config is unreadable
  - Step 8: handoff shows remaining pipeline (`/build-push-to-git` → `/build-create-pr`)
- **1.2.0**
  - Step 1: JVM version mismatch detection — compare `gate-scout`'s `java_version_required` against `java -version`; prefix all commands with `JAVA_HOME=<path>` if they differ; emit WARNING to user
  - Step 5: re-run scope rule — re-run from BUILD (Gate 1) if fix touched production code; re-run from failed gate only if fix was test-only or config
  - Step 6: re-run scope rule applied to integration gate (same logic: BUILD re-run for production changes, INTEGRATION re-run for test/data/env changes)
- **1.1.1**
  - Replace `spec/<key>/` path with resolved spec folder reference to align with makato-plan folder naming
- **1.1.0**
  - Renamed from `verify` to `build-verify`; JSONL appends now use `shared/build-log.sh`

## `build-push-to-git` skill

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
  - Step 8: after successful push, ask via `AskUserQuestion` whether to invoke `/build-create-pr` immediately; invokes it directly on confirmation
- **1.1.0**
  - Step 4: use `commitMessage` field from each plan task as the proposed commit message; present it alongside file grouping for user confirmation before Step 5
- **1.0.1**
  - Replace `spec/<key>/` path with resolved spec folder reference to align with makato-plan folder naming
- **1.0.0**
  - Renamed from `push-to-git` to `build-push-to-git`; JSONL appends now use `shared/build-log.sh`

## `build-create-pr` skill

- **1.3.0**
  - Auto-inject `Closes #N` into the PR body's Links section when `specs/<slug>/created-issues.json` is present and validates against the schema shipped by `to-issues` v3.0.0+ (path: `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`)
  - Dedupe against user-supplied `GH#N` references — artifact wins ties (D20)
  - Malformed or schema-invalid artifacts log a single warning and fall back to v1.2.0 behavior; PR creation is never blocked (D21)
  - Step 7 log entry adds `closes_injected` (count) and `artifact_status` (`valid` / `missing` / `malformed`) fields under `data`
  - Updated `references/pr-description-guide.md` Links Section table with the new artifact-driven row

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
- **1.1.0**
  - Step 5: auto-detect `GH_HOST` from `git remote get-url origin`; if hostname differs from `github.com`, prefix all `gh` commands with `GH_HOST=<hostname>`; prevents misleading "Head sha can't be blank" failure on internal GitHub instances
- **1.0.2**
  - Replace `spec/<key>/` paths with resolved spec folder references to align with makato-plan folder naming
- **1.0.1**
  - Renamed from `create-pr` to `build-create-pr`; JSONL appends now use `shared/build-log.sh`

## `build-address-pr-comments` skill

- **1.2.1**
  - Step 4: inline default-tier classification table removed; classification rules now loaded exclusively from `@references/comment-classification-guide.md`
  - Step 9: explicit `gh api` fallback commands documented for when `github-tools` MCP is unavailable

- **1.2.0**
  - Step 1: invocation hint added to interactive key prompt
- **1.1.0**
  - Step 5: structural comment escalation flow defined — present 3-option choice (A: continue non-structural now, open `/build-refine` after; B: stop entirely; C: treat as regular MUST-FIX); after non-structural pass if (A) chosen, prompt to open `/build-refine`
- **1.0.0**
  - Initial — renamed from `address-pr-comments` to `build-address-pr-comments`; JSONL appends now use `shared/build-log.sh`; classify and resolve all PR comments (human and bot); four-tier MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE classification; posts reply per comment

---

## `knowledge-scout` agent

- **1.1.0**
  - Strip `dcp-specs` naming and remove sibling-repo fallback entirely — discovery is now strictly (1) `<REPO_ROOT>/makato.config.json` `specsRoot` field, (2) in-repo `<REPO_ROOT>/specs/index.yml`. No more `DSPEC_ROOT` variable, no `context/repository-registry.yml` lookup, no glob-scanning sibling directories
  - 4-step process collapsed to 3 steps: locate SPECS_ROOT → read index → synthesize. The former Step 2 (registry lookup) is removed; in-repo specs need no registry
  - Step 3 scoring is scope-agnostic: keyword overlap on index entries; entries whose `file` path contains `golden-rules`, `anti-patterns`, `harness`, `architecture`, `structure`, or `standards` are still preferred but not required
  - Description and mission text updated: "dcp-specs knowledge graph" → "project specs knowledge graph"

- **1.0.2**
  - Fix misleading description: "3-step discovery" → "4-step process" — the agent always performs 4 steps (discover specs root, locate repo in registry, read index, synthesize); the "3-step" phrasing referred only to the DSPEC_ROOT sub-steps and confused callers
- **1.0.1**
  - Remove hardcoded GitHub fallback (Step 1c) — discovery is now makato.config.json specsRoot field → sibling scan → skip silently; project-specific GitHub URLs belong in `makato.config.json`, not in the agent definition
- **1.0.0**
  - Initial — read-only knowledge graph agent dispatched by plan-analyst, refine, and grill-with-docs; implements 4-step discovery sequence (makato.config.json → sibling scan → GitHub CLI → skip silently); returns Hard Constraints (golden rules, anti-patterns), Standards (naming/API/testing conventions), and Architecture Context for a named repository

## `coder` agent

- **1.1.0**
  - PLAN_CONTEXT input expanded to document Hard Constraints and Standards sections from the knowledge graph; added Behavior Rule requiring Hard Constraints to be respected as non-overridable project rules; Standards applied to all naming decisions

- **1.0.1**
  - Added STORY_KEY, TASK_INDEX, JSONL_PATH, TRACER_TEST_NAME to Input; coder now appends JSONL entries per phase (red/green/integrate/verify-task) directly to build.jsonl
- **1.0.0**
  - Initial — per-task TDD executor dispatched by implement-tdd; runs RED→GREEN→INTEGRATE→VERIFY for one task; enforces fix-vs-escalate threshold; returns structured result with phase reached, test counts, and escalation flag

## `diff-reviewer` agent

- **1.1.0**
  - Classify findings rule expanded to a 3-tier rubric with explicit decision criteria: CRITICAL = wrong output / security exposure / AC gap; SUGGESTION = structural improvement without correctness impact; NITPICK = style/clarity only; disambiguation guidance added for CRITICAL vs SUGGESTION borderline cases
- **1.0.1**
  - Added disallowedTools (Write, Edit, NotebookEdit); added STORY_KEY and PASS_NUMBER to Input; added pass-number re-review guard (PASS_NUMBER ≥ 2 only raises new findings); clarified agent is report-only — calling skill applies all fixes
- **1.0.0**
  - Initial — adversarial branch diff reviewer dispatched by review; applies seven quality categories (correctness, edge cases, error handling, security, contract, test coverage, optimizations); classifies findings as CRITICAL/SUGGESTION/NITPICK; produces source-anchored citation record on zero-CRITICAL passes

## `gate-scout` agent

- **1.2.0**
  - Step 2c (new): CI lint divergence detection — probes `.github/workflows/`, `Jenkinsfile`, `.gitlab-ci.yml`, `.circleci/config.yml` for lint commands; compares to locally-discovered lint command; emits `lint_ci_divergence` and `lint_ci_command` in output
  - Output format: added `lint_ci_divergence` and `lint_ci_command` fields
- **1.1.0**
  - Step 2: Maven unit command now surfaces Surefire `<groups>`/`<excludedGroups>` flags as distinct unit vs integration commands when both Surefire and Failsafe are configured
  - Step 2: pytest unit command derived from marker config — `pytest -m "not integration"` when `integration` marker is defined in `[tool.pytest.ini_options]`
  - Step 2b (new): JVM version detection for Maven/Gradle projects — reads `<java.version>` / `maven.compiler.source` (pom.xml) or `sourceCompatibility` / `java.toolchain.languageVersion` (build.gradle); emits `java_version_required` in output
  - Output format: added `java_version_required` field
- **1.0.1**
  - Default coverage threshold to 80% when COVERAGE_HINT is not provided — aligns with project standard for new code; story-specific threshold passed via COVERAGE_HINT still overrides
- **1.0.0**
  - Initial — read-only gate command discoverer dispatched by verify; scans package.json, pom.xml, build.gradle, Makefile, pyproject.toml for build/lint/unit/integration/coverage commands; coverage threshold passed via COVERAGE_HINT by the calling skill (not auto-read from design.md); returns structured command map with detected project types

## `plan-analyst` agent

- **1.2.0**
  - Step 2: `tracer_required` heuristic changed from layer-count (≥3 layers) to file-creation + new dependency edge — `true` only when at least one file is `create` AND the created file introduces a new cross-layer dependency edge; additive-only plans (`modify` only) default to `tracer_required: false`
- **1.1.1**
  - Remove duplicate `## Process` heading that split Step 0 from Steps 1–4 into two disconnected sections
  - Fix stale `github` value in `knowledge_context_source` output field — knowledge-scout v1.0.1 removed GitHub discovery; valid values are now `local | none`
- **1.1.0**
  - Step 0: dispatch knowledge-scout agent before plan analysis; REPO_NAME derived from REPO_ROOT last segment; keywords extracted from task titles; Hard Constraints, Standards, and Architecture Context sections added to output; knowledge_context_loaded and knowledge_context_source added to output metadata
- **1.0.0**
  - Initial — read-only plan classifier dispatched by implement-tdd and implement-goal; reads plan.md and glossary.md; returns task list with tdd/goal mode, architectural layer detection, tracer_required flag, glossary constraints, and reusable codebase patterns; build tool identification uses config files (package.json, pom.xml, build.gradle, pyproject.toml) directly — no cross-agent dependency

## `post-implement` hook

- **1.1.1**
  - How It Works: document Node.js as a runtime prerequisite; list all silent-exit cases explicitly so users can diagnose when auto-continuation doesn't fire

- **1.0.1**
  - Add note that Stop hook stdout injection is an observed behavior, not a documented contract; if /simplify does not trigger automatically, run it manually
- **1.0.0**
  - Initial — fires on Stop event after implement-tdd or implement-goal session ends with status: ok; automatically invokes /simplify with the same work item key; hook command discovers active story by finding most recently modified build.jsonl; no user prompt required

## `pre-push` hook

- **1.1.1**
  - How It Works: document Node.js as a runtime prerequisite; list all silent-exit cases explicitly including JSON parse errors and missing push entries

- **1.0.2**
  - Tighten verify pass check: only skip warning when both an implementation session AND a verify session exist in build.jsonl and verify is after implementation; previously a verify-only file (no implementation history) would always pass silently
- **1.0.1**
  - Redesign from PreToolUse/Bash (blocking, relied on undocumented CLAUDE_TOOL_INPUT_COMMAND env var) to Stop hook (advisory); hook now detects a completed push-to-git session in build.jsonl and warns if no verify pass exists after the last implementation session; warning is injected as context, not a process exit
- **1.0.0**
  - Initial — fires on PreToolUse for Bash tool when command contains git push; checks build.jsonl for a verify session-end entry (status: ok) that is more recent than the last implementation/review session-end entry; story key discovered dynamically from most recently modified build.jsonl; halts with an error message if no valid verify pass is found

---

## `grill-with-docs` skill

- **1.2.0**
  - Step 3: dispatch knowledge-scout agent with candidate term list as keywords; learnings-based findings suppress re-raising resolved terminology conflicts; Hard Constraints and Standards from knowledge graph injected as conflict evidence
- **1.1.0**
  - Replace CONTEXT.md + context-snapshot.md with direct enrichment of `spec/<key>/glossary.md` (the feature vocabulary written by `/makato-plan:grill`); adds `_Code_:` annotations for codebase conflicts; removes repo-detection logic and per-story snapshot file — one glossary, one truth
  - `implement-tdd` and `implement-goal` updated to read `glossary.md` instead of `context-snapshot.md`
  - `context-md-format.md` reference updated to describe glossary enrichment (entry annotation rules, `_Code_:` format, purity rules)
- **1.0.0**
  - Initial — aligns implementation plan terminology to the codebase domain model; probes codebase for canonical names; conducts adversarial alignment interview (Q1/Q2/…); writes `CONTEXT.md` with repo-detection logic (single, monorepo, multi-repo); writes `spec/<key>/context-snapshot.md`; routes decisions to `decisions.md` vs ADR via three-criteria test; ADR path lookup with per-repo discovery and `docs/governance/adr/` default; complexity signals trigger Opus recommendation

## `address-pr-comments` skill

- **1.0.1**
  - Step 9: prefer `mcp__github-tools__add_reply_to_pull_request_comment` over raw `gh api` for posting replies; `gh api` kept as fallback when MCP is not configured
- **1.0.0**
  - Initial — classify and resolve all PR comments (human and bot); four-tier MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE classification with source-heuristic defaults for bot comments; presents classification for approval; implements fixes grouped by file; re-runs build and unit gates; commits and pushes with interactive confirmation; posts reply per comment

## `create-pr` skill

- **1.0.1**
  - Step 3: use `.github/PULL_REQUEST_TEMPLATE.md` (already loaded in Step 1) as the body structure instead of constructing a free-form body; maps each template section to a spec artifact source
- **1.0.0**
  - Initial — draft PR description from spec artifacts (ACs→How to Test, plan tasks→What changed, prd.md→Goal Alignment); optional GitHub `Closes #N` issue linking; interactive draft review before `gh pr create`

## `push-to-git` skill

- **1.0.0**
  - Initial — atomic conventional commits from plan task structure; one commit per task with tests bundled; staged per-file (never `git add -A`); interactive push confirmation before affecting remote; verbatim error reporting on push rejection

## `verify` skill

- **1.1.0**
  - Step 1: replace gate-definitions.md reference with gate-scout agent dispatch; agent receives REPO_ROOT and COVERAGE_HINT (threshold extracted from design.md) and returns exact build/lint/unit/integration/coverage commands; skill uses returned command map for all gates
- **1.0.0**
  - Initial — sequential gate pipeline (build → lint → unit → integration → conditional coverage); each gate runs separately so failures are attributable; re-runs from the failed gate after a fix; structural failures escalate to `/refine`

## `review` skill

- **1.1.0**
  - Step 4: replace inline adversarial analysis with diff-reviewer agent dispatch; agent receives STORY_KEY, PASS_NUMBER, CHANGED_FILES, PLAN_CONTEXT, REPO_ROOT and returns CRITICAL/SUGGESTION/NITPICK findings; skill handles CRITICAL fix loop and re-dispatch
- **1.0.1**
  - Step 4: add explicit `git diff main...HEAD -- <file>` command for reading per-file diffs; prevents agents from picking inconsistent diff ranges
- **1.0.0**
  - Initial — autonomous adversarial review loop; auto-fixes mechanical issues silently before reporting; CRITICAL findings loop until clean; zero-findings first pass triggers mandatory source-anchored recheck (every changed file must be cited with path, line range, and evidence)

## `simplify` skill

- **1.1.1**
  - Step 3: remove hard-stop on pre-existing test failures; record failing count as the pre-simplification baseline and proceed — only *new* failures introduced during the session block in Step 7
- **1.1.0**
  - `repo-patterns-guide.md`: replace stale `CONTEXT.md` + `context-snapshot.md` references with `spec/<key>/glossary.md` (single glossary source since grill-with-docs 1.1.0)
- **1.0.0**
  - Initial — interactive complexity review post-implementation; checks against AI over-engineering anti-pattern catalog and local repo conventions; presents SIMPLIFY/KEEP/ESCALATE findings for approval before applying; verifies zero new failures after changes

## `implement-goal` skill

- **1.1.0**
  - Step 4: replace manual plan.md + glossary.md reads with plan-analyst agent dispatch; agent returns task list, layer classification, glossary constraints, and reusable patterns — implement-goal consumes the Plan Analysis output directly
- **1.0.0**
  - Initial — autonomous BUILD→VERIFY RUNTIME→TEST→VERIFY loop for UI, config, and migration work; post-implementation tests document observed behavior (not internal state); conditional branch coverage gate

## `implement-tdd` skill

- **1.2.0**
  - Step 4: replace manual plan.md + glossary.md reads with plan-analyst agent dispatch; agent returns structured Plan Analysis (task list, layers, tracer_required, glossary constraints, reusable patterns)
  - Step 6: replace inline TDD loop with coder agent dispatch per task; skill passes TASK, TASK_INDEX, STORY_KEY, JSONL_PATH, PLAN_CONTEXT, TRACER_TEST_NAME, BASELINE_FAILURES, REPO_ROOT; coder appends JSONL directly and returns status/escalation
- **1.1.0**
  - Tracer Bullet phase: conditional pre-loop step for plans spanning ≥ 3 distinct architectural layers; detects layers from plan file targets; writes thin stubs and one end-to-end integration test before the per-task loop; tracer test stays green throughout as stubs are replaced; `tdd-cycle-rules.md` extended with Tracer Bullet Phase section
- **1.0.0**
  - Initial — autonomous RED→GREEN→INTEGRATE→VERIFY loop per task; unit tests first (isolated, mocked), then integration tests against real dependencies; conditional branch coverage gate before advancing to next task

## `refine` skill

- **1.4.1**
  - Step 5.5: remove stale `→ GitHub` from discovery description and remove `github` from log schema source enum — knowledge-scout v1.0.1 removed GitHub discovery; valid source values are `local | none`
- **1.4.0**
  - Step 5.5 (new): dispatch knowledge-scout before local context/ exploration; REPO_NAME derived from target repo root last segment; Hard Constraints from knowledge graph applied as mandatory plan rules; Standards applied as naming/pattern conventions; constraint count surfaced in plan summary to user
- **1.3.0**
  - Step 1: use `AskUserQuestion` tool as fallback when no argument is passed, instead of a plain text prompt
  - Step 4: document that `stories.json` is the authoritative source over the GitHub issue when content diverges
  - Step 6: check for pre-built `context/` directory at the target repo root before direct file exploration; validate freshness via timestamp in `index.yml` / `index.md`; add optional `gh pr list` hint to surface recent merged changes
  - Step 11: add `AskUserQuestion` for terminal vs browser review choice; browser path generates `spec/<key>/plan-review.html` from `templates/plan-review-template.html` and opens it
  - New: `templates/plan-review-template.html` — 3-slide HTML review page (Story overview, Task list, AC coverage) with per-slide feedback textareas and "Copy All Feedback" button, consistent with makato-plan review templates
- **1.2.0**
  - Step 2: if `spec/<key>/` does not exist, stop and redirect the user to run `/makato-plan:decompose` before returning to `/refine`
- **1.1.0**
  - Read `AGENTS.md` and `CLAUDE.md` from the target codebase root at the start of Step 6; extracts project goal, decision test, naming conventions, and contributor constraints as hard constraints on the implementation plan
- **1.0.0**
  - Initial — bridges planned work items to implementable plans; reads GitHub issue and spec/ artifacts (prd.md, design.md, decisions.md); produces plan.md with tasks, file targets, unit/integration test strategy, and AC mapping; interactive; entry point to the build pipeline

## Plugin-level (initial releases)

- **0.2.0**
  - add full build pipeline: refine, implement-tdd, implement-goal, simplify, review, verify, push-to-git, create-pr, address-pr-comments; all skills emit JSONL build audit log to `spec/<key>/build.jsonl`
- **0.1.0** — 2026-05-14
  - initial plugin with governance files, plugin manifest (`plugin.json`), contributor guide (`AGENTS.md`)
