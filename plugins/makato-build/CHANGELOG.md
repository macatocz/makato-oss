<!-- markdownlint-disable MD013 -->
# Changelog — makato-build

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

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
