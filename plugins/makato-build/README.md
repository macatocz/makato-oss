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
                                             │ CRITICAL findings fixed
                                             ▼
                                    ┌─────────────────┐
                                    │   build-verify  │
                                    └────────┬────────┘
                                             │ gates PASS
                                             ▼
                                   ┌──────────────────┐   sensor-fixer +
                                   │  build-sensors   │◄─ build-resolve-finding
                                   └────────┬─────────┘   (per-finding repair)
                                            │ changed-file checks pass
                                            ▼
                                 ┌──────────────────────┐
                                 │  build-push-to-git   │
                                 └──────────┬───────────┘
                                            │ branch pushed
                                            ▼
                                 ┌──────────────────────┐
                                 │   build-create-pr    │
                                 └──────────┬───────────┘
                                            │ PR URL
                                            ▼
                          ┌─────────────────────────────────┐
                          │  build-address-pr-comments      │
                          └─────────────────────────────────┘
                                            │ fixes pushed, comments replied
                                            ▼
                                        merged PR
```

| Phase                                      | Input                                                         | Output                                                                     |
| ------------------------------------------ | ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| build-start                                | Work item key or local design.md                              | Validated session state; hands off to build-refine                         |
| build-refine                               | Issue + spec folder (`stories.json` or `created-issues.json`) | plan.md with tasks, file targets, test strategy                            |
| build-grill-with-docs (optional)           | plan.md + spec folder + codebase                              | Enriched glossary.md; ADRs for hard-to-reverse decisions                   |
| build-implement-tdd / build-implement-goal | plan.md with tasks                                            | Working code + tests; build.jsonl entries                                  |
| build-simplify                             | Branch diff vs main + plan.md                                 | Simplified working tree                                                    |
| build-review                               | Branch diff vs origin/main + plan.md                          | CRITICAL (+ MAJOR in autonomous) findings fixed; SUGGESTION/NITPICK report |
| build-verify                               | Working tree + gate commands                                  | PASS/FAIL per gate; coverage report                                        |
| build-sensors                              | staged or branch-changed files                                | Clean sensor run; residual findings carried over                           |
| build-push-to-git                          | Verified working tree + plan.md                               | Feature branch on remote; commits map to plan tasks                        |
| build-create-pr                            | Pushed branch + spec artifacts                                | GitHub PR URL with spec-derived description                                |
| build-address-pr-comments                  | PR with unresolved review comments                            | Fixes committed; reply comments posted; carry-over issues logged           |

## Validation Authority

`build-sensors` is the local sensor authority and validates a changed-file set: either staged files
or files changed against the target branch. `build-verify` is the local project-gate authority for
build, lint, tests, coverage, and runtime checks. E2E execution can be configured for local or
remote placement without turning commit or push hooks into repository-wide gates.

GitHub Actions is the authoritative remote validation and merge signal. The post-push hook only
warns when verify evidence is stale or absent; it never blocks a commit or push.

## Skills

| Skill                                                                  | Description                                                                                                                                                                                                                                                                                                                                                                               | Input                                                                                                                                                          | Output                                                                                                                                                      | Version |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| [build-start](skills/build-start/SKILL.md)                             | Entry point for a full build session — validates git state, validates spec prerequisites, captures implementation mode (TDD vs goal), creates or resumes an isolated interactive worktree, initializes the build log, and kicks off build-refine. (interactive)                                                                                                                           | Work item key (GitHub Issue number or spec slug); optional: local design.md created via interview when no ticket exists.                                       | Validated session state — clean git, spec folder confirmed, implementation mode recorded, isolated worktree handed to build-refine.                         | 1.9.0   |
| [build-refine](skills/build-refine/SKILL.md)                           | Bridge a planned work item to an implementation plan — tasks, file targets, unit/integration test strategy, acceptance mapping. Reads target repo AGENTS.md/CLAUDE.md as hard constraints and creates or resumes an isolated worktree when invoked directly. (interactive)                                                                                                                | GitHub Issue or stories.json + full spec folder from makato-plan (prd.md, design.md, decisions.md); optional --autonomous flag and WORKTREE_PATH.              | plan.md written to specs/\<key\>-\*/ with task list, file targets, test strategy, acceptance mapping, and worktree handoff.                                 | 1.12.0  |
| [build-grill-with-docs](skills/build-grill-with-docs/SKILL.md)         | Align implementation plan terminology to the codebase domain model — probes codebase for canonical names, adversarial alignment interview, enriches glossary.md with _Code_: annotations, routes ADRs via three-criteria test and target-repository ADR path lookup. (interactive)                                                                                                        | plan.md from specs/\<key\>-\*/; optional prd.md, design.md, decisions.md, glossary.md from spec folder; codebase to probe.                                     | Enriched specs/\<key\>-\*/glossary.md with _Code_: annotations for codebase conflicts; ADRs created for hard-to-reverse decisions in the target repository. | 1.7.0   |
| [build-implement-tdd](skills/build-implement-tdd/SKILL.md)             | Execute a refined plan using TDD — RED failing tests, GREEN unit passing, INTEGRATE real dependencies, VERIFY full suite per task. Tracer bullet phase for multi-layer stories. Autonomous loop. (autonomous)                                                                                                                                                                             | plan.md with tdd-mode tasks in specs/\<key\>-\*/; optional --autonomous flag and WORKTREE_PATH.                                                                | Working code with unit and integration tests passing; JSONL entries appended to build.jsonl.                                                                | 1.9.2   |
| [build-implement-goal](skills/build-implement-goal/SKILL.md)           | Execute goal-mode tasks from a refined plan — BUILD → VERIFY RUNTIME → TEST → VERIFY. For UI, config, or migration work where implementation must exist before tests can be written. (autonomous)                                                                                                                                                                                         | plan.md with goal-mode tasks in specs/\<key\>-\*/; optional --autonomous flag and WORKTREE_PATH.                                                               | Working code with tests written after runtime verification; JSONL entries appended to build.jsonl.                                                          | 1.5.0   |
| [build-simplify](skills/build-simplify/SKILL.md)                       | Review implemented code for complexity that does not serve the acceptance criteria — premature abstractions, unnecessary wrappers, dead code, over-indirection. Interactive by default; auto-approves SIMPLIFY findings under --autonomous. (interactive)                                                                                                                                 | Current branch diff vs main; plan.md for acceptance criteria reference; optional --autonomous flag and WORKTREE_PATH.                                          | Simplified code in working tree; SIMPLIFY findings applied or ESCALATE findings surfaced via R1.                                                            | 1.4.2   |
| [build-review](skills/build-review/SKILL.md)                           | Adversarial quality review of the branch diff — CRITICAL (and, in autonomous mode, MAJOR) findings are fixed and the review loops until clean. Auto-fixes mechanical issues (formatting, imports). Reports SUGGESTION and NITPICK findings. Persists per-AC verified/gap verdicts to build.jsonl. (autonomous)                                                                            | Current branch diff vs origin/main (resolved via default-branch.sh); plan.md acceptance criteria.                                                              | Clean working tree with CRITICAL (+ autonomous MAJOR) findings fixed; SUGGESTION/NITPICK report; `ac-verification` build.jsonl entry; does not commit.      | 1.5.0   |
| [build-verify](skills/build-verify/SKILL.md)                           | Sequential gate pipeline: build → lint → unit → integration → conditional coverage. Each gate runs separately so failures are attributable. Fixable failures fixed and re-run; structural failures escalate to refine. (autonomous)                                                                                                                                                       | Current working tree; optional --autonomous flag and WORKTREE_PATH; gate commands discovered by gate-scout.                                                    | Gate results (PASS/FAIL per gate, coverage report); JSONL entries appended to build.jsonl.                                                                  | 1.12.0  |
| [build-sensors](skills/build-sensors/SKILL.md)                         | Run pre-commit sensors against staged or changed-vs-main files, parse findings, and dispatch sensor-fixer until clean or MAX_LOOPS=5. Implements gate-0 of the build pipeline. (autonomous)                                                                                                                                                                                              | scope (staged\|changed-vs-main), spec_key for build.jsonl path, and pre-commit config in the target project.                                                   | Clean pre-commit run; residual findings carried over to draft PR; JSONL audit entries.                                                                      | 1.0.0   |
| [build-resolve-finding](skills/build-resolve-finding/SKILL.md)         | Per-finding decision tree resolving a single sensor finding via 4 branches — autofix, tech-skill route (action skill or autofix-then-skill fallback), safe-automated action (redact/upgrade/suppress), or carry-over to draft PR. (autonomous)                                                                                                                                            | Single normalized sensor finding from sensor-fixer; finding-routes.json for routing; target file path.                                                         | Structured outcome: branch taken, fix applied or carry-over recorded; JSONL entry appended.                                                                 | 1.1.0   |
| [build-fix-security](skills/build-fix-security/SKILL.md)               | Per-finding security repair engine dispatched by build-resolve-finding for bandit:\*, safety:\*, and pip-audit:\* findings. CWE-keyed 4-branch decision tree (autofix / refactor / suppress / carry-over). Never invoked directly by the user. (autonomous)                                                                                                                               | Single normalized bandit/safety/pip-audit finding dispatched by build-resolve-finding.                                                                         | In-place code edit or suppression comment or carry-over record; structured outcome returned to caller.                                                      | 1.0.0   |
| [build-fix-types](skills/build-fix-types/SKILL.md)                     | Per-finding type-error repair dispatched by build-resolve-finding for pyright:\* or mypy:\* findings — 6-branch decision tree (narrow / annotate / TypeVar/Generic / Protocol / cast / type:ignore-with-justification). Never invoked directly by the user. (autonomous)                                                                                                                  | Single normalized pyright/mypy finding dispatched by build-resolve-finding.                                                                                    | In-place type annotation or guard edit; structured outcome returned to caller.                                                                              | 1.0.0   |
| [build-push-to-git](skills/build-push-to-git/SKILL.md)                 | Create atomic conventional commits from the plan's task structure and push the feature branch to remote. One commit per logical task, individually bisectable. Confirms push before affecting remote. (interactive)                                                                                                                                                                       | Verified working tree; plan.md for task-to-commit mapping; optional --autonomous flag and WORKTREE_PATH.                                                       | Feature branch pushed to remote; commit history maps to plan tasks.                                                                                         | 1.6.0   |
| [build-create-pr](skills/build-create-pr/SKILL.md)                     | Generate a pull request from the pushed feature branch. Drafts PR description from spec artifacts — acceptance criteria map to How to Test, design decisions surface in the description. Renders a machine-readable `## AC Verification` block from build.jsonl so the post-merge agent can mark verified AC checkboxes. Presents draft for approval before opening. (interactive)        | Pushed feature branch; spec artifacts (prd.md, decisions.md, stories.json); build.jsonl `ac-verification` entry; optional work-item-key and --autonomous flag. | GitHub PR URL opened with spec-derived description, `makato:ac-verdicts` block, and issue links.                                                            | 1.9.0   |
| [build-address-pr-comments](skills/build-address-pr-comments/SKILL.md) | Classify and resolve all PR comments — human reviewer feedback and automated bot findings. Four-tier classification (MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE). Structural feedback escalates to refine. Headless-safe under --autonomous. (interactive)                                                                                                                                 | PR with unresolved review comments; optional work-item-key, --autonomous flag, and WORKTREE_PATH.                                                              | Fixes committed and pushed; reply comments posted via gh CLI; OUT-OF-SCOPE items logged as carry-over issues.                                               | 1.5.2   |
| [definition-of-done](skills/definition-of-done/SKILL.md)               | Canonical, versioned, machine-checkable Definition of Done — 13 automated items enforced by build-verify/build-sensors/build-push-to-git/coder agent; 6 manual items asserted by the PO-agent. Single source of truth referenced across the pipeline.                                                                                                                                     | No runtime input — reference document consumed by coder VERIFY phase, build-verify gate mapping, and PO-agent task-completion logic.                           | Authoritative DoD checklist (19 items total) returned as structured reference.                                                                              | 2.3.0   |
| [inject-context](skills/inject-context/SKILL.md)                       | Resolve a list of changed file paths against config/context-bundles.yml and return a deterministic, deduplicated, ordered list of rule-file paths for knowledge-scout to pre-read. Glob-specificity-first ordering; raises HALT-006 when default bundle is absent. (autonomous)                                                                                                           | List of predicted changed file paths from the current task; config/context-bundles.yml registry.                                                               | Ordered list of rule-file paths for knowledge-scout to pre-read; no-match warning surfaced when applicable.                                                 | 1.0.0   |
| [inject-skills](skills/inject-skills/SKILL.md)                         | Resolve a list of changed file paths against the cross-plugin merged skill-bundles.yml registry and return an ordered, deduplicated list of recommended skills. Glob-specificity ordering (D9), OR-substring content hints (D19), target-repo installed-skill subset filter (D10), graceful missing-skill skip (D18); raises HALT-006 when no plugin ships a default bundle. (autonomous) | List of predicted changed file paths from the current task; every plugin's config/skill-bundles.yml registry; target repo path.                                | Ordered list of recommended skill identifiers for the dispatching agent; no-match and missing-skills warnings surfaced when applicable.                     | 1.0.0   |

## Agents

| Agent           | Model                     | Permission                                                                             | Purpose                                                                                                                                                                                                                                                                                    | Dispatched by                             |
| --------------- | ------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| coder           | claude-sonnet-latest      | bypassPermissions                                                                      | Execute a single TDD task (RED→GREEN→INTEGRATE→VERIFY) from a refined implementation plan. The only agent with elevated permissions.                                                                                                                                                       | build-implement-tdd                       |
| diff-reviewer   | claude-sonnet-latest      | bypassPermissions (disallowedTools: Write, Edit, NotebookEdit — effectively read-only) | Adversarially review the branch diff against acceptance criteria — finds correctness bugs, edge cases, security issues, and contract violations. Returns CRITICAL / MAJOR / SUGGESTION / NITPICK findings plus a per-AC verified/gap verdict (`data.ac_verdicts[]`). Does not apply fixes. | build-review                              |
| gate-scout      | claude-haiku-latest       | bypassPermissions (disallowedTools: Write, Edit, Bash, NotebookEdit — read-only)       | Discover build, lint, unit test, integration test, and coverage commands by scanning project config files. Returns a structured command map for build-verify.                                                                                                                              | build-verify                              |
| knowledge-scout | claude-haiku-latest       | bypassPermissions (disallowedTools: Write, Edit, NotebookEdit — read-only)             | Discover project Hard Constraints and Standards from the specs knowledge graph via inject-context (Step 0) → locate SPECS_ROOT → read index → synthesize constraints.                                                                                                                      | build-refine, build-grill-with-docs       |
| plan-analyst    | claude-haiku-latest       | bypassPermissions (disallowedTools: Write, Edit, Bash, NotebookEdit — read-only)       | Read a refined implementation plan and return a structured context object — task list, architectural layer classification, glossary constraints, tracer_required flag, and reusable codebase patterns.                                                                                     | build-implement-tdd, build-implement-goal |
| runtime-qa      | claude-haiku-4-5-20251001 | bypassPermissions: false                                                               | Exercise the built app via Playwright MCP and score against acceptance criteria. CRITICAL findings block build-push-to-git; MAJOR/ADVISORY are advisory. No-op when no runtime surface detected.                                                                                           | build-runtime-qa skill / PO-agent         |
| sensor-fixer    | claude-sonnet-latest      | Edit/Write restricted to changed-files set captured at dispatch time                   | Outer loop reading parsed sensor findings, running batched deterministic-autofix Phase 0, then dispatching build-resolve-finding per residual finding. Tier-escalates sonnet→opus on second failure for the same finding (not yet wired, #287).                                            | build-sensors                             |

## Hooks

| Hook               | Trigger                                                                           | Purpose                                                                                                                                                                                                                                                            |
| ------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
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
- `shared/inject_context.py` — Python implementation of the inject-context bundle resolver — given
  changed file paths and context-bundles.yml, returns ordered rule-file paths for knowledge-scout.
- `shared/test_inject_context.py` — Unit tests for inject_context.py.
- `shared/inject_skills.py` — Python implementation of the inject-skills bundle resolver —
  aggregates every plugin's skill-bundles.yml, applies glob-specificity ordering (D9), content-hint
  predicates (D19), and the installed-skill subset filter (D10), and returns ordered recommended
  skills for the dispatching agent.
- `shared/test_inject_skills.py` — Unit + integration tests for inject_skills.py.
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
- `shared/baseline-guide.md` — Reference guide for establishing a test baseline before code changes
  — distinguishes pre-existing failures from session-introduced ones. Consumed by
  build-implement-tdd, build-implement-goal, build-simplify, build-verify.
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
| Complements   | makato-orchestrate | Shares shared/build-log.sh for JSONL audit entries; provides inject-context to makato-orchestrate scout agent per task                                                                                                                        |

## Prerequisites / MCP Servers

No MCP servers required.

External prerequisites:

- `pre-commit` installed in target project (required by build-sensors)
- `gh` CLI installed for PR creation and comment resolution (build-create-pr,
  build-address-pr-comments)
- Python 3 for `shared/inject_context.py` and `shared/parse-sarif.py`
- Git remote (`origin`) accessible for build-push-to-git and build-create-pr
- `specs/<key>-*/` folder with makato-plan artifacts before build-start/build-refine can run

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
