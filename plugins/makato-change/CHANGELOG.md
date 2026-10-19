<!-- markdownlint-disable MD012 MD013 -->
# Changelog

## [Unreleased]

### Changed — route subagents through shared model roles

- Removed `modelRole:` from agent frontmatter; no harness read it. Each agent now
  declares a Claude Code `model:` alias derived from its shared role in the repo's
  `config/agent-roles.yml`. Under OMP the same role reaches the agent via
  `task.agentModelOverrides` (`"@<role>"`), which `scripts/select-model-profile.sh`
  merges into the OMP config.
- **`change-implementer` agent v1.1.0**: `task` → `model: inherit`.
- **`quality-guard` agent v1.3.0**: `smol` → `model: haiku`.
- **`code-reviewer`** and **`requirements-diff-analyzer`** agents: `advisor` →
  `model: opus`.
- **`code-explorer`** and **`test-analyzer`** agents: `smol` → `model: haiku`.
- **`gherkin-scenario-elaborator`** agent: newly assigned the `commit` role (it had
  no `modelRole`) → `model: sonnet`.

### Fixed — interactive orchestrate handoffs use clean contexts

- **`orchestrate` skill v1.6.2** persists the selected phase and returns an explicit
  `/handoff`/`/new` plus `/skill:<phase>` instruction in human-driven OMP sessions,
  instead of invoking the next phase in the same session. The headless/autonomous
  phase workflow and Claude-native invocation remain available.

### Fixed — durable project learning (port of #123 from `development`)

- **`execute` skill v1.6.2** and **`resolve-review` skill v1.0.5** require learning
  review and capture before completion or handoff. Use the installed build helper
  rather than a nonexistent consumer `plugins/` path; pass `--issue N` when issues
  share a feature spec.
- Generalizable captures persist immediately to the main checkout’s `.makato/`;
  no merge or post-merge documentation agent is required.

### Fixed — linked target root for change state and specs

- **`orchestrate` skill v1.6.1** reads and updates change-state files under
  `MAKATO_TARGET_REPO_ROOT` when supplied; its unset-override `show-toplevel`
  fallback is unchanged.
- **`design` skill v1.5.1** uses the target root for spec artifacts when set,
  preserving the existing common-dir fallback otherwise.

### Fixed — host-qualified gh project-scope remediation

- **`execute` skill v1.6.1** — the In Progress and In Review board updates keep `gh project
  item-list` stderr. When the token lacks the `project` scope they log
  `gh auth refresh --hostname $HOST --scopes project,read:project` and the device-login URL instead
  of reporting the issue as missing from the board.

### Added — Role-based workflow dispatch

- Route analyze, design, execute, and resolve-review through the public skill launcher,
  preserving the full context bundle between separate OMP processes. Resolve role and
  effort from workflow-schema.yml and concrete model providers from OMP `modelRoles`.

## quality-guard scopes checks to touched stacks (changed-files scoping)

Scopes the `quality-guard` quality gate to the stacks a change actually touches.
Previously, in a polyglot repo the agent ran every discovered check regardless of
what changed — a frontend-only change paid for the full backend pytest suite. Now
the agent classifies `CHANGED_FILES` by stack and, when only one code stack is
touched, runs only that stack's checks (frontend → vitest + biome; backend →
pytest + ruff) and marks the rest `skipped: stack-not-touched`. When two or more
code stacks are touched — or the change is only stack-neutral files — it runs every
discovered check, preserving prior behaviour with no regression.

**Changes:**

- **`plugins/makato-change/agents/quality-guard.md`** (`v1.1.0 → v1.2.0`) — adds
  a scope-to-touched-stacks rule, polyglot multi-stack command discovery (Step 2),
  a new **Step 2.5: Scope Checks to Touched Stacks** (file-bucket classification →
  `scoped_to_stack` decision), a scope gate on the run steps (3–8), `scoped_to_stack`
  and `stack_buckets` fields in the report, and edge-case rows for empty/neutral/
  multi-stack `CHANGED_FILES`.

- **`plugins/makato-change/skills/execute/SKILL.md`** (`v1.5.0 → v1.6.0`) — Step 5.5.2
  documents that `quality-guard` scopes checks to the stacks `CHANGED_FILES` touches
  and stresses passing an accurate changed-file list.

## spec-delta.md generation and binding constraint propagation (v1.4.0)

Adds `spec-delta.md` awareness to the change request pipeline so that the
precise diff between the original spec and the updated spec is captured at
design time and carried into execution as a binding constraint — preventing
the change-implementer from touching requirements that did not change.

**Changes:**

- **`plugins/makato-change/skills/design/SKILL.md`** (`v1.3.0 → v1.4.0`) —
  adds **Step 9.5: Generate spec-delta.md**, inserted after Step 9 (design.md
  written) and before Step 10 (GitHub issue update). The step reads
  `spec-delta-template.md` from the skill's `references/` directory, computes
  the requirement diff between `analysis.md` and the approved `design.md`,
  and writes `specs/<issue-key>/spec-delta.md`. Supports headless auto-generate
  with log-bypass: when invoked with `--autonomous`, Step 9.5 writes
  spec-delta.md without an interactive confirmation checkpoint.

- **`plugins/makato-change/skills/execute/SKILL.md`** (`v1.3.0 → v1.4.0`) —
  Step 1 now reads `spec-delta.md` when present and stores its content as
  `SPEC_DELTA_CONTEXT`. Step 2 passes `SPEC_DELTA_CONTEXT` to the
  `change-implementer` agent as a binding constraint for MODIFIED requirements,
  ensuring the implementer applies only the deltas recorded in spec-delta.md
  and does not re-implement requirements that were not part of the change.

## Change orchestrate runs in an isolated worktree, on fresh runs and resumes (#467)

Fixes #467: `makato-change:orchestrate --autonomous` committed to the operator's
ambient checked-out branch instead of a dedicated `feat/<KEY>-change` worktree. The
resulting PR was clean only by luck (when the ambient branch's prior work had already
merged); otherwise it bundled unrelated work into one PR.

**Changes:**

- **`skills/orchestrate/SKILL.md`** — Step 0.5 now branches fresh-vs-resume. On a
  resume (a `change-state-<N>.json` with a non-null `worktree_path` already exists) it
  no longer re-initializes state or resets `current_phase`, and recovers `WORKTREE_PATH`
  via the po-agent Step 2b `git ls-remote` probe-then-create pattern — calling
  `worktree.sh create` **without** `--new-branch` when the branch exists on the remote
  (the unconditional `--new-branch` previously hard-failed on resume and dropped the
  session onto the ambient checkout). Step 5 re-reads `worktree_path` before each phase
  dispatch and forwards it as an explicit `WORKTREE_PATH` context preamble to
  analyze/design/execute.
- **`skills/execute/SKILL.md`** — Step 6 (headless branch) now adopts an
  orchestrate-provided `WORKTREE_PATH` when present instead of creating a second
  worktree, and standalone invocations use the matching `feat/<ISSUE-KEY>-change`
  branch name.

## Glob-based skill injection in design skill — closes makato-build asymmetry (v1.3.0)

Closes the gap documented in #429: change requests now receive the same technology-skill
routing that `makato-build`'s `coder` gets automatically, without requiring a human to
hand-write `recommended_skills[]` in design.md.

**Root cause:** `makato-build`'s `coder` receives technology skills via `knowledge-scout`
Step 0e → `resolve_skills_for_repo(changed_files, MAKATO_ROOT)` → `plan.md`
`recommended_skills[]` → coder dispatch. `makato-change`'s `change-implementer` had no
equivalent step — nothing ever called the inject-skills resolver, so the field was absent
from design.md unless a human added it manually.

**Changes:**

- **`plugins/makato-change/skills/design/SKILL.md`** (`v1.2.0 → v1.3.0`) — adds
  **Step 4.5: Resolve recommended skills**, inserted after Step 4 (affected-file set
  known) and before Step 9 (design.md written). The step calls
  `resolve_skills_for_repo(AFFECTED_FILES, MAKATO_ROOT)` from
  `plugins/makato-build/shared/inject_skills.py` — the same cross-plugin resolver
  `knowledge-scout` uses — and stores the result as `RECOMMENDED_SKILLS_RESULT`.
  Best-effort: resolver failure or empty result logs a warning, never blocks the design
  phase. Updates Step 9 to emit the `## Recommended Skills` section from the result; omits
  the section entirely when the list is empty (mirrors the execute Step 2.1 contract).

- **`plugins/makato-change/skills/design/templates/design.md`** — adds a
  `## Recommended Skills` section at the end of the template with an inline comment
  explaining the execute Step 2.1 forward wiring and the omit-when-empty contract.

- **`plugins/makato-change/skills/execute/SKILL.md`** — updates Step 2.1 prose to
  reference `design` Step 4.5 as the authoritative source of `recommended_skills[]`,
  replacing wording that implied the field was only ever hand-inserted.

- **`plugins/makato-change/shared/skill-injection-smoke-tests.sh`** (new) — 13-scenario
  smoke test covering: technology skill routing for FastAPI/Postgres/LangGraph affected-file
  sets (AC-7a), design.md template structure (AC-7b), execute Step 2.1/2.2 wiring (AC-7c),
  and empty-result/no-flood contract (AC-7d). Follows the `tests/integration/skill-bundles-aggregate.sh`
  pattern.

**Unchanged:** the mandatory `context7` lookup in `change-implementer` is unaffected —
still enforced unconditionally at the write phase. The `execute` Step 2.2 dispatch
mechanics are unchanged; only the Step 2.1 documentation was updated. Resolves #429.

## change-implementer write-subagent for execute (v1.2.0)

Introduces a write-capable `change-implementer` agent (analogue of `makato-build`'s `coder`).
`execute` Step 2 now dispatches it to apply the design's file modifications in an isolated
context instead of editing in the main skill context — which already carried `analyze` +
`design` + repository discovery. This bounds main-context token growth during Medium (6–15
file) changes and gives the mandatory `context7` obligation a real injection point at the
write phase (agent prompt), routed for source files by makato-doc's cross-plugin
`doc-code-docs` bundle rather than living only as AGENTS.md prose. Resolves #396.

## Progress comment narration in orchestrate skill (v1.2.0)

Mirrors the `makato-orchestrate` PO-agent progress-comment pattern into the `makato-change`
`orchestrate` skill so that anyone watching a change-request issue on GitHub can follow the run
in plain English — without having to watch the local terminal.

- **`orchestrate` skill — `## Progress comment` section** — documents the `progress-comment.sh`
  interface, the per-phase narration table (`--skill`, `--agent`, `--goal` for each of
  analyze / design / execute / resolve-review), and the three contract invariants (best-effort /
  only when `MAKATO_ORCHESTRATE_SHARED` is set / opt-out via `MAKATO_PROGRESS_COMMENT_DISABLE=1`).
- **Step 0.5 (autonomous init)** — emits a run-start `note` after worktree creation.
- **Step 5 (invoke skill)** — calls `progress-comment.sh start` before every phase dispatch,
  using the matching row from the narration table.
- **Step 6 (post-phase check)** — calls `progress-comment.sh done` after every phase returns,
  with `--result` (completed/failed) and a one-sentence `--summary`.
- **Step 7 (loop/exit)** — calls `progress-comment.sh note` on workflow-complete and on HALT,
  so the issue comment always has a clear terminal entry.
- **Edge case** — added explicit degraded-mode note: when `MAKATO_ORCHESTRATE_SHARED` is unset
  all progress-comment calls are skipped silently, no HALT is raised.
- Skill version bumped `1.1.0 → 1.2.0`.
## `quality-guard` — raise default coverage threshold to 90%

**`agents/quality-guard.md`** (new `version: "1.1.0"`): default coverage threshold raised 80% → **90%** for all metrics (statements, branches, functions, lines) on new/changed code, applied when the design artifact declares none. The design-artifact value and `DESIGN_PATH`-not-readable fallback now read 90%. The worked-example report block was re-based so its pass/fail illustrations remain correct against a 90% floor. The "Maintain 80% coverage" / "Must achieve 85% test coverage" strings under *Look for* are left as-is — they are examples of user-supplied design text the agent detects, not defaults. Aligned with the makato-build `gate-scout` / `definition-of-done` 90% default.

## Autonomous path — orchestrate + headless phase branches (#144)

Adds full autonomous execution support to the `makato-change` pipeline so the `loop` skill can
dispatch change-request issues unattended in the same way it dispatches PO-agent work items.

- **`AUTONOMOUS-MODE.md` 1.0.0** — new document: canonical reference for headless execution in
  `makato-change`. Defines the `--autonomous` contract (no interactive prompts, R1 envelope on
  every exit, HALT-CH-* codes on non-success paths), the three guarded actions that require
  explicit operator opt-in (`needs-human-review` labelling, PR merge, scope-ceiling override),
  and the `change-state.json` audit obligations that mirror `workflow-state.json` in
  `makato-orchestrate`.
- **`orchestrate` skill — `--autonomous` flag** — the `orchestrate` skill now accepts
  `--autonomous` as an invocation flag. When set: interactive confirmation prompts are suppressed;
  each phase (analyze, design, execute, resolve-review) emits an R1 envelope on completion;
  failures in any phase produce the appropriate HALT-CH-* code and write to `change-state.json`
  before returning R1 `status: "failure"`. Interactive (default) behavior is unchanged.
- **`analyze` skill — headless branch** — when invoked with `--autonomous`, `analyze` skips the
  "confirm requirements diff" interactive checkpoint and instead writes the diff to
  `change-state.json` under `requirements_diff`; if the `requirements-diff-analyzer` agent
  returns unresolvable conflicts the skill fires HALT-CH-001 and returns R1 failure without
  waiting for operator input.
- **`design` skill — headless branch** — when invoked with `--autonomous`, `design` skips the
  "approve technical approach" checkpoint; if the `code-explorer` agent cannot locate a primary
  affected file or the scope exceeds the medium-change ceiling the skill fires HALT-CH-002 and
  returns R1 failure.
- **`execute` skill — headless branch** — when invoked with `--autonomous`, `execute` suppresses
  the pre-commit and pre-PR interactive confirmations; suppressed `quality-guard` findings below
  the error threshold are recorded as HALT-CH-003 (informational) in `change-state.json` and do
  not block the PR from being opened.

---

## Plugin-level

- **0.3.0** (#145)
  - Added `config/skill-bundles.yml` — plugin-prefixed bundles (`change-skills`, `change-spec`)
    for routing change-request spec files and plugin skill files to the orchestrate/analyze/design/execute/resolve-review skills via the inject-skills resolver.

- **0.2.0**
  - Strip `dcp-specs` / `specs-context` / `$DCP_SPECS_PATH` / `dcp-portal-ui` terminology suite-wide. Project specs are now discovered exclusively via (1) `<REPO_ROOT>/makato.config.json` `specsRoot` field or (2) in-repo `<REPO_ROOT>/specs/index.yml`. The "Sibling to specs-context" path-resolution strategy is removed and replaced with "Sibling of CWD"; `$DCP_SPECS_PATH` environment-variable fallback is removed entirely
  - README Option A relabeled "From a separate specs working directory"; Option B (in-repo `specs/`) is now the recommended default
  - `analyze/references/exploration-strategy.md` rewritten: no more `pwd`-based CWD-in-specs-context detection; replaced with the two-strategy discovery matching AGENTS.md
  - AGENTS.md "Project Specs Discovery" section rewritten; example repo name `dcp-portal-ui` replaced with `my-service` across docs and shared/

## `code-explorer` agent

- **1.1.0**
  - Strip `dcp-specs` / `specs-context` naming and remove sibling-repo + environment-variable discovery. Two strategies only: (1) `<REPO_ROOT>/makato.config.json` `specsRoot` field, (2) `<REPO_ROOT>/specs/index.yml`. No `DCP_SPECS_PATH` variable. Output field renamed `dcp_specs_available` → `specs_available`; output section renamed "specs-context" → "Project Specs"

- **1.0.1**
  - Fix specs-context discovery: replace bash commands (`pwd`, `test -d`, `echo $VAR`) with Glob/Read equivalents so Step 1 works correctly when Bash is in disallowedTools
  - Fix file discovery: replace `find` commands with `glob()` calls in Step 2 for consistency with disallowedTools constraints
- **1.0.0**
  - Initial — Explore codebase to discover affected files, dependencies, patterns, and specs-context context for change requests
  - Enhanced specs-context detection with multi-strategy approach (CWD, sibling directory, environment variable)

## `requirements-diff-analyzer` agent

- **1.0.1**
  - Strip `specs-context` term: input source list now says "from code or project specs"

- **1.0.0**
  - Initial — Compare current vs requested behavior to produce structured requirements diff with gaps, inconsistencies, and completeness assessment

## `test-analyzer` agent

- **1.0.0**
  - Initial — Discover and analyze all tests (unit, integration, E2E) affected by change request, map to affected functionality, identify coverage gaps

## `quality-guard` agent

- **1.0.0**
  - Initial — Run quality checks (lint, format, tests, coverage) after implementation with actionable feedback and 80% coverage threshold for new code

## `code-reviewer` agent

- **1.0.0**
  - Initial — Review implementation changes before PR creation for bugs, security issues, design alignment, classify issues by severity (CRITICAL/MAJOR/MINOR)

## `orchestrate` skill

- **1.0.0**
  - Initial — Guide users through change request workflow (analyze, design, execute, resolve-review), track progress, coordinate phases

## `resolve-review` skill

- **1.0.3**
  - Strip `specs-context` term: path-resolution Strategy 1 relabeled "Sibling of CWD"; `-C` flag rationale comment reworded to "may be invoked from any working directory"

- **1.0.2**
  - GitHub API endpoint for replying to line-specific PR comments corrected by adding missing pull_number parameter (was `repos/:owner/:repo/pulls/comments/<COMMENT_ID>/replies`, now `repos/:owner/:repo/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies`)
- **1.0.1**
  - Replace Step 5 (Run Tests) with Step 5 (Run Quality Gate) to dispatch quality-guard agent after addressing review feedback, ensuring test coverage and quality checks verify changes before pushing
- **1.0.0**
  - Initial — Resolve PR review feedback by addressing comments with code fixes or clarifying replies, update GitHub issue status
  - Add repository context loading from repositories.yml
  - Use `git -C <REPO_ROOT>` for all git operations to support cross-repo execution
  - Add automatic path resolution (searches standard locations, no configuration needed)

## `execute` skill

- **1.0.3**
  - Strip `specs-context` term: path-resolution Strategy 1 relabeled "Sibling of CWD"; `-C` flag rationale comment reworded to "may be invoked from any working directory"

- **1.0.1**
  - Restructure Step 5.5 and 5.6 into single "Review and Verify Implementation" loop that runs code-reviewer first, then quality-guard, ensuring changes from review process are covered by tests before committing
- **1.0.0**
  - Initial — Implement change requests by modifying code, updating tests, running verification, and creating PR with GitHub Issues link
  - Add repository context loading from repositories.yml (Step 1.5)
  - Use absolute paths for all file operations (`<REPO_ROOT>/<relative-path>`)
  - Use `git -C <REPO_ROOT>` for all git operations to support cross-repo execution
  - Use `cd <REPO_ROOT> && gh pr create` for PR creation to target correct repository
  - Add automatic path resolution (searches standard locations, no configuration needed)

## `design` skill

- **1.1.1**
  - Strip `specs-context` term: path-resolution Strategy 1 relabeled "Sibling of CWD"; "specs-context context" wording replaced with "Project specs context"

- **1.0.0**
  - Initial — Design technical approach for change requests with code discovery (guided or exploratory), solution planning, and GitHub Issues updates
  - Add repository metadata loading from repositories.yml (Step 1.5)
  - Validate repository path exists before dispatching agents
  - Update agent dispatch to use repositories.yml for REPO_ROOT and REPO_NAME
  - Add automatic path resolution (searches standard locations, no configuration needed)

## `analyze` skill

- **1.1.2**
  - Strip `specs-context` term: "specs-context context" and "specs-context or code patterns" replaced with project-agnostic wording; exploration-strategy.md reference rewritten to the two-strategy project-specs discovery

- **1.1.1**
  - sagibeast-alignment audit: remove duplicate `8. Inconsistencies` section heading in Step 9 artifact template
  - renumber the second "Step 9" (GitHub Issues update) to "Step 10" so workflow step numbers are unique
- **1.0.0**
  - Initial — Analyze change request requirements by comparing current vs. requested behavior, identify and address questions and inconsistencies, update GitHub issue with refined requirements
  - Add repository discovery step (Step 2.5) that prompts for target repo and writes repositories.yml
  - Support invocation from specs-context or target repo (auto-detects CWD or prompts for path)
  - Update agent dispatch to use repositories.yml for REPO_ROOT and REPO_NAME
  - Write repo name only to repositories.yml (automatic path resolution, no configuration needed)

## Plugin-level

- **0.1.0**
  - Initial — makato-change plugin with governance documentation
  - Add cross-repository operation support via repositories.yml
  - Add shared repositories-yml-schema.md (independent from makato-plan)
  - Add shared path-resolution.md for automatic path resolution
  - Enable invocation from specs-context or target repo
  - Support automatic path resolution (searches standard locations, no configuration needed)
  - Document cross-repo usage patterns in README.md and AGENTS.md
