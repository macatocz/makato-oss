# makato-build

**Goal.** Take a decomposed, vertically-sliced story shaped by makato-plan and produce a merged pull
request — tested, reviewed, and ready to ship — within a single session.

**How.** A sequential skill pipeline anchored at `build-start` walks through refinement,
implementation (TDD or goal-driven), simplification, review, gate verification, sensor repair,
commit, push, PR creation, and comment resolution. Stories arrive planned but unrefined;
`build-refine` bridges that gap into a plan small enough for autonomous, single-session execution.
Sub-agents handle specialised read-only tasks (gate discovery, context loading, adversarial review)
while the `coder` agent — the only agent with elevated write permissions — executes each TDD task.

**Why.** Planned stories become shippable features without manual orchestration overhead.
makato-build closes the loop from ideation to merged code.

## What Belongs Here

- Skills that refine planned stories into implementation plans
- Skills that implement code via TDD or goal-driven approaches
- Skills that review, simplify, and verify implementations
- Skills that commit, push, and create pull requests from implementations
- Skills that address PR review feedback

## What Does NOT Belong Here

- Hotfixes, small defects, or ad-hoc code changes (no dedicated plugin yet)
- Shaping work — PRDs, architecture, prototypes, decomposition (that is makato-plan)
- Plugin/skill scaffolding (that is makato-contribute)
- CI/CD pipeline configuration or deployment automation
- Project management or issue tracker state machine transitions

## Workflow

```
  GitHub Issue / spec slug
          │
          ▼
  ┌───────────────┐   validates git, spec, mode
  │  build-start  │ ──────────────────────────────────────────────┐
  └───────────────┘                                               │
                                                                  ▼
                                                       ┌───────────────────┐
                                                       │   build-refine    │
                                                       └─────────┬─────────┘
                                                                 │ plan.md
                                                                 ▼
                                                    ┌────────────────────────┐
                                                    │  build-grill-with-docs │ (optional)
                                                    └────────────┬───────────┘
                                                                 │ enriched glossary + ADRs
                                                   ┌─────────────┘
                                                   │
                               ┌───────────────────┴───────────────────┐
                               │                                       │
                               ▼                                       ▼
               ┌────────────────────────┐             ┌────────────────────────┐
               │  build-implement-tdd   │             │  build-implement-goal  │
               │    (TDD mode tasks)    │             │   (goal mode tasks)    │
               └────────────┬───────────┘             └────────────┬───────────┘
                            └─────────────────┬─────────────────────┘
                                              │ working code + tests
                                              ▼
                                   ┌────────────────────┐
                                   │   build-simplify   │
                                   └──────────┬─────────┘
                                              │ simplified working tree
                                              ▼
                                    ┌─────────────────┐
                                    │   build-review  │
                                    └────────┬────────┘
                                             │ CRITICAL + MAJOR repaired and re-reviewed
                                             ▼
                                    ┌─────────────────┐   Gate 0: build-sensors +
                                    │   build-verify  │◄─ sensor-fixer +
                                    └────────┬────────┘   build-resolve-finding
                                             │ gates PASS (integration + coverage owned
                                             │ by CI when the repo's CI runs them)
                                            ▼
                                 ┌──────────────────────┐
                                 │  build-push-to-git   │
                                 └──────────┬───────────┘
                                            │ branch pushed
                                            ▼
                                 ┌──────────────────────┐
                                 │   build-create-pr    │
                                 └──────────┬───────────┘
                                            │ autonomous: build-fix-ci → current-head green
                                            ▼
                          ┌─────────────────────────────────┐
                          │  build-address-pr-comments      │
                          └─────────────────────────────────┘
                                            │ fixes pushed, comments replied
                                            ▼
                                        merged PR
```

| Phase                                      | Input                                                        | Output                                                                     |
| ------------------------------------------ | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| build-start                                | Work item key or local design.md                             | Validated session state; hands off to build-refine                         |
| build-refine                               | GitHub Issue + spec folder (prd.md, design.md, decisions.md) | plan.md with tasks, file targets, test strategy                            |
| build-grill-with-docs (optional)           | plan.md + spec folder + codebase                             | Enriched glossary.md; ADRs for hard-to-reverse decisions. `--autonomous`: decides what it can, asks the rest in ONE issue comment and parks the card in Blocked until answered |
| build-implement-tdd / build-implement-goal | plan.md with tasks                                           | Working code + tests; build.jsonl entries                                  |
| build-simplify                             | Branch diff vs main + plan.md                                | Simplified working tree                                                    |
| build-review | Current working-tree diff from integration merge-base + plan.md | CRITICAL/MAJOR repaired by coder and re-reviewed in both modes; SUGGESTION/NITPICK report |
| build-verify                               | Working tree + gate commands                                 | PASS/FAIL per gate; coverage report                                        |
| build-sensors                              | staged/all/changed/branch files                                     | Clean pre-commit run; residual findings carried over                       |
| build-push-to-git                          | Verified working tree + plan.md                              | Feature branch on remote; commits map to plan tasks                        |
| build-create-pr | Pushed branch + spec artifacts | PR URL; autonomous calls also wait for current-head CI or return a blocker |
| build-fix-ci | Existing PR + isolated worktree + plan | All actionable CI failures repaired, reviewed, verified and pushed; current-head green or explicit blocker |
| build-address-pr-comments                  | PR with unresolved review comments                           | Fixes committed; reply comments posted; carry-over issues logged           |

## Skills

| Skill                                                                  | Description                                                                                                                                                                                                                                                                                                                                                                               | Input                                                                                                                                                          | Output                                                                                                                                                      | Version |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| [build-start](skills/build-start/SKILL.md)                             | Entry point for a full build session — validates git state, validates spec prerequisites, captures implementation mode (TDD vs goal), creates or resumes an isolated interactive worktree, initializes the build log, and kicks off build-refine. (interactive)                                                                                                                           | Work item key (GitHub Issue number or spec slug); optional: local design.md created via interview when no ticket exists; `MAKATO_BUILD_ROOT` for suite-owned helpers. | Validated session state — clean git, spec folder confirmed, implementation mode recorded, isolated worktree handed to build-refine.                         | 1.10.0   |
| [build-refine](skills/build-refine/SKILL.md)                           | Bridge a planned work item to an implementation plan — tasks, file targets, unit/integration test strategy, acceptance mapping. Reads target repo AGENTS.md/CLAUDE.md as hard constraints and creates or resumes an isolated worktree when invoked directly. Planned `create` files are filtered before exploration reads. (interactive) | GitHub Issue or stories.json + full spec folder from makato-plan (prd.md, design.md, decisions.md); optional --autonomous flag, WORKTREE_PATH, and `MAKATO_BUILD_ROOT`. | plan.md written to specs/\<key\>-\*/ with task list, file targets, test strategy, acceptance mapping, and worktree handoff.                                 | 1.13.0  |
| [build-grill-with-docs](skills/build-grill-with-docs/SKILL.md)         | Align implementation plan terminology to the codebase domain model — probes codebase for canonical names, adversarial alignment interview, enriches glossary.md with _Code_: annotations, routes ADRs via three-criteria test and target-repository ADR path lookup. (interactive)                                                                                                        | plan.md from specs/\<key\>-\*/; optional prd.md, design.md, decisions.md, glossary.md from spec folder; `MAKATO_BUILD_ROOT` and optional `MAKATO_ORCHESTRATE_ROOT`. | Enriched specs/\<key\>-\*/glossary.md with _Code_: annotations for codebase conflicts; ADRs created for hard-to-reverse decisions in the target repository. | 1.8.0   |
| [build-implement-tdd](skills/build-implement-tdd/SKILL.md)             | Execute a refined plan with task-scoped TDD — RED/GREEN only. RED writes/extends task tests and runs only this coder's added/changed test files (plus `TRACER_TEST_NAME` when set) with one targeted command from `GATE_COMMANDS`, preserving the runner prefix, to confirm the intended failure. GREEN adds minimum production code and reruns that same command; all targeted tests must pass. No INTEGRATE, full-suite VERIFY, coverage, or repo-wide lint. Tracer bullet uses the targeted tracer test. (autonomous) | plan.md with tdd-mode tasks in specs/\<key\>-\*/; optional --autonomous flag and WORKTREE_PATH. | Working code with targeted task tests passing; build-review owns independent review and bounded repair checks, while build-verify owns whole-change gates (integration and coverage CI-owned when the repo's CI runs them); JSONL entries appended to build.jsonl. | 1.17.0  |
| [build-implement-goal](skills/build-implement-goal/SKILL.md)           | Execute goal-mode tasks from a refined plan — BUILD → VERIFY RUNTIME → TEST → targeted VERIFY (task tests plus existing tests exercising changed files, against the reused branch baseline; no suite or coverage run). For UI, config, or migration work where implementation must exist before tests can be written. (autonomous)                                                                                                                                                                                         | plan.md with goal-mode tasks in specs/\<key\>-\*/; optional --autonomous flag and WORKTREE_PATH.                                                               | Working code with tests written after runtime verification; JSONL entries appended to build.jsonl.                                                          | 1.10.0  |
| [build-simplify](skills/build-simplify/SKILL.md)                       | Review implemented code for complexity that does not serve the acceptance criteria — premature abstractions, unnecessary wrappers, dead code, over-indirection. Interactive by default; auto-approves SIMPLIFY findings under --autonomous. Runs no tests when nothing was applied; otherwise only tests exercising the touched files. (interactive)                                                                                                                                 | Current branch diff vs main; plan.md for acceptance criteria reference; optional --autonomous flag and WORKTREE_PATH.                                          | Simplified code in working tree; SIMPLIFY findings applied or ESCALATE findings surfaced via R1.                                                            | 1.5.0   |
| [build-review](skills/build-review/SKILL.md) | Adversarial diff review with mandatory, bounded coder repair and independent re-review of CRITICAL/MAJOR findings in both modes. Full passes on large changes are split by lens (parallel `diff-reviewer`s, `MAKATO_REVIEW_LENSES`); findings carry an invariant and all its sites and are repaired at invariant level, with a design pre-check for CRITICAL and returning findings, parallel repairs on disjoint files and a background full pass from round 2. The repair loop is capped by convergence: `MAKATO_MAX_REPAIR_ROUNDS` (soft, default 3) and `MAKATO_MAX_REPAIR_ROUNDS_HARD` (hard, default 8), and a recurring finding stops it. Re-reviews after a repair cover only the repair delta and its neighbours, and one full pass certifies the whole tree before it proceeds (`MAKATO_REVIEW_SCOPE=full` reviews everything every pass). SUGGESTION/NITPICK remain advisory; exhaustion fails closed to HALT-003. | Current working tree including untracked additions; plan.md; WORKTREE_PATH | Zero blocking findings or fail-closed at the convergence cap; final per-AC verdicts in build.jsonl; repairs left uncommitted | 1.10.0 |
| [build-verify](skills/build-verify/SKILL.md)                           | Whole-change gate pipeline: sensors at CI scope → build/lint from Gate 0 hook results → unit (collecting coverage) → integration (local, or CI-owned when CI runs it) → coverage report without re-running tests; a locally enforced threshold miss adds edge-case tests for the lowest-covered files. Pytest gates run in parallel (pytest-xdist) and repair re-checks triage incrementally (pytest-testmon) via `shared/pytest_accel.py`. Does not fix code-level failures itself; bounded coder verify-repair loop with delta diff review, `MAKATO_MAX_REPAIR_ROUNDS` default 3; exhaustion → HALT-002; structural escalation → refine. (autonomous) | Current working tree; optional --autonomous flag, WORKTREE_PATH, `MAKATO_BUILD_ROOT`, gate commands, and recorded implementation baseline. | Gate results and coverage report; repair rounds and unresolved findings logged in build.jsonl. | 1.17.0  |
| [build-sensors](skills/build-sensors/SKILL.md)                         | Run pre-commit sensors against staged/all/changed/branch files, parse findings, dispatch sensor-fixer agent within one shared repair budget (max_loops=5). Implements gate-0 of the build pipeline. (autonomous)                                                                                                                                                                                                    | scope (staged\|all\|changed-vs-main\|branch), spec_key for build.jsonl path; pre-commit config in target project.                                                      | Clean pre-commit run; residual findings carried over to draft PR; JSONL audit entries.                                                                      | 1.3.0   |
| [build-resolve-finding](skills/build-resolve-finding/SKILL.md)         | Per-finding decision tree resolving a single sensor finding via 4 branches — autofix, tech-skill route (action skill or autofix-then-skill fallback), safe-automated action (redact/upgrade/suppress), or carry-over to draft PR. (autonomous)                                                                                                                                            | Single normalized sensor finding from sensor-fixer; finding-routes.json for routing; target file path.                                                         | Structured outcome: branch taken, fix applied or carry-over recorded; JSONL entry appended.                                                                 | 1.1.0   |
| [build-fix-security](skills/build-fix-security/SKILL.md)               | Per-finding security repair engine dispatched by build-resolve-finding for bandit:\*, safety:\*, and pip-audit:\* findings. CWE-keyed 4-branch decision tree (autofix / refactor / suppress / carry-over). Never invoked directly by the user. (autonomous)                                                                                                                               | Single normalized bandit/safety/pip-audit finding plus `MAKATO_BUILD_ROOT`.                                                                                   | In-place code edit or suppression comment or carry-over record; structured outcome returned to caller.                                                      | 1.1.0   |
| [build-fix-types](skills/build-fix-types/SKILL.md)                     | Per-finding type-error repair dispatched by build-resolve-finding for pyright:\* or mypy:\* findings — 6-branch decision tree (narrow / annotate / TypeVar/Generic / Protocol / cast / type:ignore-with-justification). Never invoked directly by the user. (autonomous)                                                                                                                  | Single normalized pyright/mypy finding plus `MAKATO_BUILD_ROOT`.                                                                                            | In-place type annotation or guard edit; structured outcome returned to caller.                                                                              | 1.2.0   |
| [build-push-to-git](skills/build-push-to-git/SKILL.md)                 | Create atomic conventional commits from the plan's task structure and push the feature branch to remote. One commit per logical task, individually bisectable. Confirms push before affecting remote. (interactive)                                                                                                                                                                       | Verified working tree; plan.md for task-to-commit mapping; optional --autonomous flag and WORKTREE_PATH.                                                       | Feature branch pushed to remote; commit history maps to plan tasks.                                                                                         | 1.6.0   |
| [build-create-pr](skills/build-create-pr/SKILL.md)                     | Generate a pull request from the pushed feature branch. Drafts PR description from spec artifacts — acceptance criteria map to How to Test, design decisions surface in the description. Renders a machine-readable `## AC Verification` block from build.jsonl so the post-merge agent can mark verified AC checkboxes. Presents draft for approval before opening. (interactive)        | Pushed feature branch; spec artifacts (prd.md, decisions.md, stories.json); build.jsonl `ac-verification` entry; optional work-item-key, --autonomous flag, and `MAKATO_BUILD_ROOT`. | GitHub PR URL opened with spec-derived description, `makato:ac-verdicts` block, and issue links.                                                            | 1.11.0   |
| [build-address-pr-comments](skills/build-address-pr-comments/SKILL.md) | Classify and resolve all PR comments — human reviewer feedback and automated bot findings. Four-tier classification (MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE). Structural feedback escalates to refine. Headless-safe under --autonomous. (interactive)                                                                                                                                 | PR with unresolved review comments; optional work-item-key, --autonomous flag, and WORKTREE_PATH.                                                              | Fixes committed and pushed; reply comments posted via gh CLI; OUT-OF-SCOPE items logged as carry-over issues.                                               | 1.5.2   |
| [definition-of-done](skills/definition-of-done/SKILL.md)               | Canonical, versioned, machine-checkable Definition of Done — 13 automated items enforced by build-verify/build-sensors/build-push-to-git/coder agent; 6 manual items asserted by the PO-agent. Single source of truth referenced across the pipeline.                                                                                                                                     | `MAKATO_BUILD_ROOT` context for suite-owned helper references; consumed by coder task/repair checks and build-verify gate mapping, plus PO-agent task-completion logic. | Authoritative DoD checklist (19 items total) returned as structured reference.                                                                              | 2.7.0   |
| [inject-context](skills/inject-context/SKILL.md)                       | Resolve a list of changed file paths against config/context-bundles.yml and return a deterministic, deduplicated, ordered list of rule-file paths for knowledge-scout to pre-read. Glob-specificity-first ordering; raises HALT-006 when default bundle is absent. (autonomous)                                                                                                           | List of predicted changed file paths from the current task; config/context-bundles.yml registry.                                                               | Ordered list of rule-file paths for knowledge-scout to pre-read; no-match warning surfaced when applicable.                                                 | 1.0.0   |
| [inject-skills](skills/inject-skills/SKILL.md)                         | Resolve a list of changed file paths against the cross-plugin merged skill-bundles.yml registry and return an ordered, deduplicated list of recommended skills. Glob-specificity ordering (D9), OR-substring content hints (D19), target-repo installed-skill subset filter (D10), graceful missing-skill skip (D18); raises HALT-006 when no plugin ships a default bundle. (autonomous) | List of predicted changed file paths from the current task; every plugin's config/skill-bundles.yml registry; target repo path.                                | Ordered list of recommended skill identifiers for the dispatching agent; no-match and missing-skills warnings surfaced when applicable.                     | 1.0.0   |
| [build-fix-ci](skills/build-fix-ci/SKILL.md) | Shared autonomous CI repair loop; SHA-bound inspection, all-job diagnostics, TDD/goal/sensor routing, coverage-threshold raise from CI's combined data, review/verify before repair push, resumable private checkpoint. | PR number, repo, worktree, plugin roots, work-item key and spec context | R1 with current head, CI status, repair rounds and unresolved checks | 1.1.0 |

### Autonomous CI recovery

Autonomous `build-create-pr` creates or reuses the branch's PR, then runs
`build-fix-ci` without another prompt. To resume an existing PR directly:

```text
/makato-build:build-fix-ci <work-item-key> --autonomous
```

Supply `PR_NUMBER`, `REPO`, `WORKTREE_PATH`, `REPO_ROOT` and
`MAKATO_BUILD_ROOT` in the dispatch context. The skill never merges. Source
repairs pass review and verification, then update the same PR. A new push
invalidates prior CI approval. Metadata-only fixes do not create empty commits.
The configured OMP roles must be available under lowercase aliases (for example,
`REVIEW` uses `modelRoles.review`). Missing role configuration blocks dispatch;
the coordinator does not choose replacement models or edit OMP configuration.

`MAKATO_MAX_CI_FAILURE_CYCLES=0` (default) keeps repairing while progress is
verified; set a positive ceiling to cap repair rounds. No-progress, permissions,
missing secrets, operator cancellation and pending timeout are explicit blockers,
not green results. `MAKATO_CI_WAIT_SECS=600` and `MAKATO_CI_POLL_INTERVAL=60`
control waits. Private checkpoint/logs live under the worktree's git metadata.
Manual PR creation still returns after opening the PR.

## Agents

| Agent           | Model                     | Permission                                                                             | Purpose                                                                                                                                                                                                                                                                                    | Dispatched by                             |
| --------------- | ------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| coder | claude-sonnet-latest | bypassPermissions | Execute TDD tasks with targeted RED/GREEN tests; repair and verify findings in review-repair or verify-repair mode, including coverage-raise edge-case tests. | build-implement-tdd, build-review, build-verify |
| diff-reviewer   | claude-sonnet-latest      | bypassPermissions (disallowedTools: Write, Edit, NotebookEdit — effectively read-only) | Adversarially review the branch diff against acceptance criteria — finds correctness bugs, edge cases, security issues, and contract violations. Returns CRITICAL / MAJOR / SUGGESTION / NITPICK findings plus a per-AC verified/gap verdict (`data.ac_verdicts[]`). Does not apply fixes. | build-review, build-verify |
| gate-scout | claude-haiku-latest | bypassPermissions (disallowedTools: Write, Edit, Bash, NotebookEdit — read-only) | Discover project build, lint, unit, integration, and split coverage collect/append/report commands plus CI ownership (integration lane, coverage gate, sensor scope). | build-verify, build-review |
| knowledge-scout | claude-haiku-latest       | bypassPermissions (disallowedTools: Write, Edit, NotebookEdit — read-only)             | Discover project Hard Constraints and Standards from the specs knowledge graph via inject-context (Step 0) → locate SPECS_ROOT → read index → synthesize constraints.                                                                                                                      | build-refine, build-grill-with-docs       |
| plan-analyst    | claude-haiku-latest       | bypassPermissions (disallowedTools: Write, Edit, Bash, NotebookEdit — read-only)       | Read a refined implementation plan and return a structured context object — task list, architectural layer classification, glossary constraints, tracer_required flag, and reusable codebase patterns.                                                                                     | build-implement-tdd, build-implement-goal |
| runtime-qa      | claude-haiku-4-5-20251001 | bypassPermissions: false                                                               | Exercise the built app via Playwright MCP and score against acceptance criteria. CRITICAL findings block build-push-to-git; MAJOR/ADVISORY are advisory. No-op when no runtime surface detected.                                                                                           | build-runtime-qa skill / PO-agent         |
| sensor-fixer    | claude-sonnet-latest      | Edit/Write restricted to changed-files set captured at dispatch time                   | Outer loop reading parsed sensor findings, running batched deterministic-autofix Phase 0, then dispatching build-resolve-finding per residual finding within the remaining shared build-sensors repair budget. Tier-escalates sonnet→opus on second failure for the same finding (not yet wired, #287).                                            | build-sensors                             |

## Hooks

| Hook               | Trigger                                                                           | Purpose                                                                                                                                                                                                                                                            |
| ------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| pre-commit-sensors | PreToolUse on Bash(git commit\*) — blocks the tool call on non-zero exit          | Fast-lane gate: runs pre-commit on staged files before any git commit; blocks the commit and hands off to sensor-fixer on non-zero exit. Restricted to cheap deterministic checks (linters, formatters, secret-regex, filesystem hygiene) with a 30s hard timeout. |
| pre-push           | Stop event after Claude turn (advisory, not blocking)                             | After a git push is detected in the session, warns if the verify gate has not been run since the last implementation. Advisory — does not block the push but surfaces the gap.                                                                                     |
| post-implement     | Stop event after Claude turn — checks build.jsonl for completed implement session | After a successful build-implement-tdd or build-implement-goal session, automatically injects a message causing Claude to continue with /build-simplify without waiting for the user.                                                                              |

## Scripts

- `shared/build-log.sh` — Append a JSONL entry (or batch of entries via --batch stdin mode) to
  specs/\<key\>-\*/build.jsonl. Worktree-aware: derives REPO_ROOT from the common git directory so
  entries always land on the main checkout.
- `shared/default-branch.sh` — Resolve the remote-tracking ref of the repository's default branch
  (e.g. origin/main). Used by build-review and build-simplify to diff against the correct
  integration target, avoiding stale local branch issues.
- `shared/log-bypass.sh` — Append a canonical autonomous_bypass JSONL entry to build.jsonl when a
  skill takes an autonomous default instead of prompting the user.
- `shared/human_questions.py` — Batched human-questions helper for `build-grill-with-docs --autonomous`:
  `post` writes ONE issue comment with every open question (options + recommendation), moves the
  board card to Blocked and writes `awaiting-answers-<N>.json`; `status`/`wait` watch the card
  (moved back to Ready or In progress = answered); `collect` merges the replies per question (the
  recommended option fills the gaps); `resolve` retires the marker. Stdlib only, Python 3.9+.
- `shared/test_human_questions.py` — Unit + lifecycle tests for human_questions.py against a fake GitHub.
- `shared/inject_context.py` — Python implementation of the inject-context bundle resolver — given
  changed file paths and context-bundles.yml, returns ordered rule-file paths for knowledge-scout.
- `shared/test_inject_context.py` — Unit tests for inject_context.py.
- `shared/inject_skills.py` — Python implementation of the inject-skills bundle resolver —
  aggregates every plugin's skill-bundles.yml, applies glob-specificity ordering (D9), content-hint
  predicates (D19), and the installed-skill subset filter (D10), and returns ordered recommended
  skills for the dispatching agent.
- `shared/test_inject_skills.py` — Unit + integration tests for inject_skills.py.
- `shared/review_scope.py` — Review-scope helper for build-review/build-verify: `snapshot` captures the
  uncommitted working tree as a tree id (throw-away index, real index untouched), `delta` lists what a
  repair touched plus the changed files that test or reference it, `materialize` checks a snapshot out
  into a detached worktree (for the background full pass) and `release` removes it, and `decide` is the
  state machine that schedules the delta re-reviews, the one final full pass and the `background-full`
  certification. `MAKATO_REVIEW_SCOPE=full` restores a full review on every pass.
- `shared/test_review_scope.py` — Tests for review_scope.py against real temporary git repositories.
- `shared/review_loop.py` — Review-loop state helper for build-review: `init` keeps per-story finding
  history in the git dir, `lenses` decides the lens split (`MAKATO_REVIEW_LENSES`), `merge` combines
  lens results into one R1 with stable finding ids, `repaired` records repair claims, `next` is the
  convergence rule (`MAKATO_MAX_REPAIR_ROUNDS` soft / `MAKATO_MAX_REPAIR_ROUNDS_HARD` hard cap, redesign
  and stop on recurring findings), `partition` groups findings by file for parallel repairs and
  `background` decides whether a background full pass runs.
- `shared/test_review_loop.py` — Tests for review_loop.py against real temporary files and git repositories.
- `shared/pytest_accel.py` — Makes gate-scout's pytest commands parallel (pytest-xdist) and, for repair
  triage, incremental (pytest-testmon). `detect`, `install`, `rewrite` and `reset`; `rewrite` returns
  the accelerated command plus the `serial_command` to fall back to. A Coverage.py
  `coverage run … -m pytest` is translated to `python -m pytest -n N --cov` (pytest-cov), which writes
  the same `.coverage` data; options without a pytest-cov counterpart, `parallel`/`concurrency` in the
  coverage config, compound shell commands and `--pdb` keep the command as it is. Controlled by
  `MAKATO_PYTEST_ACCEL=off`, `MAKATO_PYTEST_WORKERS` and `MAKATO_PYTEST_XDIST_INTEGRATION=1`.
- `shared/test_pytest_accel.py` — Tests for pytest_accel.py rewrite rules and state handling.
- `shared/parse-sarif.py` — Normalise diagnostic output from various linters/checkers (including
  SARIF format) into a unified Finding stream for sensor-fixer. Emits the canonical Finding shape
  documented in `shared/finding-schema.md`.
- `shared/finding-schema.md` — Single source of truth for the normalised Finding shape flowing
  through the sensor loop (build-sensors → sensor-fixer → build-resolve-finding → fixers). Linked
  from all four loop artefacts.
- `shared/finding-schema-smoke-test.sh` — Contract test guarding the Finding schema: asserts
  parse-sarif.py's emitted keys equal the documented canonical set, the loop docs carry no forbidden
  field names (rule_id/fixable/Finding-level file), and the reference doc is linked from every
  artefact. Wired into validate.yml (#230).
- `shared/autonomous-propagation-smoke-tests.sh` — Smoke tests verifying that --autonomous flag
  propagates correctly across cross-skill dispatches.
- `shared/build-log-batch-smoke-tests.sh` — Smoke tests for build-log.sh --batch mode.
- `shared/default-branch-smoke-tests.sh` — Smoke tests for default-branch.sh resolution logic.
- `shared/halt-codes-smoke-tests.sh` — Smoke tests verifying HALT code emission from build skills.
- `shared/log-bypass-smoke-tests.sh` — Smoke tests for log-bypass.sh.
- `shared/pr-comments-smoke-tests.sh` — Smoke tests for PR comment classification and reply logic in
  build-address-pr-comments.
- `shared/worktree-path-propagation-smoke-tests.sh` — Smoke tests verifying WORKTREE_PATH is
  propagated and used correctly across autonomous skill dispatch.

## Shared Resources

- `shared/finding-routes.json` — Sensor finding → action routing table (version 1.1). Maps
  `tool:rule` (see `shared/finding-schema.md`) to action (autofix/skill/autofix-then-skill), cmd,
  and fallback_skill. Consumed by sensor-fixer Phase 0 and build-resolve-finding.
- `shared/baseline-guide.md` — Reference guide for the branch test baseline: run once per branch
  base, recorded with its failing test IDs, and reused by later implementation passes. Distinguishes
  pre-existing failures from session-introduced ones. Recorded or reused by build-implement-tdd and
  build-implement-goal; consumed by build-verify as `BASELINE_FAILURES`.
- `shared/coverage-raise-guide.md` — Coverage-raise procedure for a threshold miss on data that covers
  every lane: rank files lowest coverage first, select up to 5 per round to close the gap, write
  test-only edge-case tests, re-measure. Used by build-verify Gate 5 (coder) and build-fix-ci
  (build-implement-goal recovery task).
- `config/context-bundles.yml` — Bundle registry consumed by inject-context — maps file glob
  patterns to rule-file paths that knowledge-scout should pre-read.
- `agents/RETURN-CONTRACT.md` — R1 envelope spec shared by all build agents — defines the required
  JSON block shape (status, errors, tool_calls_used, data) that every sub-agent must emit as its
  final output.
- `AUTONOMOUS-MODE.md` — Authoritative reference for --autonomous flag propagation across build-\*
  skills — documents activation triggers, per-gate default-taking rules, WORKTREE_PATH
  workspace-isolation contract, and logging requirements.
- `halt-codes.md` — Registry of skill-level HALT codes (uppercase-underscore tokens like
  MISSING_INPUT, BASELINE_BROKEN, PUSH_REJECTED) emitted by build-\* skills in R1 envelopes.
  Distinct from orchestrate-level numeric HALT-NNN codes.

## Notable Governance Files

- `plugins/makato-build/AGENTS.md` — Contributor routing guide — Goal, Build Boundary, What
  Belongs/Does Not Belong, Design Principles, Security Model, Skill Authoring conventions, File
  Structure, Versioning, and PR Checklist.
- `plugins/makato-build/AUTONOMOUS-MODE.md` — Authoritative spec for autonomous mode operation —
  activation triggers, per-gate default-taking rules, WORKTREE_PATH workspace-isolation contract,
  and falsy-check pattern.
- `plugins/makato-build/halt-codes.md` — Skill-level HALT code registry for all build-\* skills —
  uppercase-underscore tokens, their recovery routes, and relationship to orchestrate-level HALT-NNN
  codes.
- `plugins/makato-build/agents/RETURN-CONTRACT.md` — R1 envelope schema spec shared by all agents —
  machine-parseable JSON contract for autonomous PO-agent integration.
- `plugins/makato-build/.claude-plugin/plugin.json` — Plugin manifest with name, description, and
  author (no version field — versioned via release-please + git tags).
- `plugins/makato-build/shared/finding-routes.json` — Routing table mapping sensor tool:rule_id
  pairs to autofix commands or skill routes — the dispatch table for the entire sensor repair
  pipeline.
- `plugins/makato-build/config/context-bundles.yml` — Bundle registry mapping file globs to
  rule-file paths consumed by inject-context to feed knowledge-scout.
- `plugins/makato-build/templates/pr-comment-replies.md` — Reply text templates used by
  build-address-pr-comments to render per-classification replies on resolved PR comments.

## Plugin Connections

| Direction     | Plugin             | What flows                                                                                                                                                                                                                                    |
| ------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Consumes from | makato-plan        | stories.json, prd.md, design.md, decisions.md, prototype.html — read from specs/\<key\>-\*/ at session start by build-refine and build-start                                                                                                  |
| Dispatched by | makato-orchestrate | PO-agent dispatches build-refine → build-implement-tdd/build-implement-goal → build-verify → build-push-to-git → build-create-pr → build-address-pr-comments with --autonomous; receives R1 envelopes and HALT codes to drive recovery routes |
| Complements   | makato-orchestrate | Shares `"$MAKATO_BUILD_ROOT/shared/build-log.sh"` for JSONL audit entries; provides inject-context to makato-orchestrate scout agent per task                                                                                                                        |

## Prerequisites / MCP Servers

No MCP servers required.

External prerequisites:

- `pre-commit` installed in target project (required by build-sensors and pre-commit-sensors hook)
- `gh` CLI installed for PR creation and comment resolution (build-create-pr,
  build-address-pr-comments)
- Python 3 for `shared/inject_context.py` and `shared/parse-sarif.py`
- Git remote (`origin`) accessible for build-push-to-git and build-create-pr
- `specs/<key>-*/` folder with makato-plan artifacts before build-start/build-refine can run

Runtime roots:

- `MAKATO_BUILD_ROOT` identifies the installed makato-build plugin and is used
  for every suite-owned helper, reference, and schema path. Skills resolve it
  from `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` when the caller
  does not provide it.
- `MAKATO_PLAN_ROOT` is optional. When present, build-create-pr uses it for
  `created-issues.json` schema validation; when absent, that advisory check is
  skipped rather than probing the consumer repository.
- `MAKATO_ORCHESTRATE_ROOT` is optional for cross-plugin workflow-state
  integration. When absent, build-grill-with-docs skips its best-effort state
  update.

## Installation

```bash
claude --plugin-dir ./plugins/makato-build
```

## Version

```bash
claude plugin add makato-build --source https://github.com/zstary/makato/tree/main/plugins/makato-build

claude plugin marketplace add https://github.com/zstary/makato/tree/main/plugins/makato-build#stable
claude plugin install makato-build@makato-suite
```

Or interactively via /plugin marketplace add then /plugin install makato-build@makato-suite.
