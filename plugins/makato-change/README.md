<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
# makato-change

**Goal**: Implement changes to existing functionality based on updated business requirements.

**How**: Refine requirements against current behavior, identify affected code sections via
specialized agents, design a technical approach, implement modifications (including small
supporting components), verify changes with automated quality and code-review agents, create a
PR, and resolve review feedback. All phases produce artifact files under `specs/<issue-key>/`
that chain into each other.

**Why**: The suite covers new feature development through `makato-plan` and `makato-build`, but
has no dedicated lower-overhead workflow for targeted adjustments to existing functionality
(1–15 files, shallow cross-cutting changes). `makato-change` fills that gap without requiring
full shaping or a TDD pipeline.

## What Belongs Here

- Requirement refinement comparing current behavior vs updated requirements to identify the diff
  that needs to be addressed
- Identification of affected code sections and technical approach design
- Implementation of modifications to existing functionality (small: 1–5 files; medium: 6–15 files)
- New supporting components when needed (helpers, utils) — medium scope
- Verification, PR creation, and resolution of review feedback
- New and updated tests for the changed behavior

## What Does NOT Belong Here

- Large-scale changes requiring thorough discovery and preparation (16+ files, new subsystems,
  multi-team coordination — escalate to `makato-plan` + `makato-build`)
- Bug fixes and defect resolution — no dedicated plugin yet; route through `makato-plan` if
  shaping is needed or `makato-build` if the fix is well-scoped
- New features with no existing functionality to change (use `makato-plan`)

## Workflow

```
GitHub Issue (change request)
          │
          ▼
┌─────────────────────┐
│     orchestrate     │  guides phases in sequence
│    (interactive)    │  Input:  GitHub issue key
│                     │  Output: coordinated CR workflow, phase tracking
└──────────┬──────────┘
           │  or invoke each phase directly:
           ▼
┌─────────────────────┐  agents: code-explorer, requirements-diff-analyzer,
│       analyze       │          test-analyzer
│    (interactive)    │  Input:  GitHub issue key + codebase
│                     │  Output: analysis.md, repositories.yml,
│                     │          updated GitHub issue
└──────────┬──────────┘
           ▼
┌─────────────────────┐  agents: code-explorer, test-analyzer
│       design        │  Input:  analysis.md + codebase
│    (interactive)    │  Output: design.md, test-scenarios.md,
│                     │          updated GitHub issue
└──────────┬──────────┘
           ▼
┌─────────────────────┐  agents: quality-guard, code-reviewer
│       execute       │  Input:  design.md + repositories.yml
│    (autonomous)     │  Output: modified code, feature branch, PR opened
└──────────┬──────────┘
           │  PR review comments arrive
           ▼
┌─────────────────────┐
│   resolve-review    │  Input:  PR number or issue key
│    (interactive)    │  Output: fixes committed, replies posted,
│                     │          GitHub issue status updated
└─────────────────────┘
```

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`analyze`](skills/analyze/SKILL.md) | Analyze change request requirements by comparing current behavior against requested changes, identify open questions and inconsistencies, update GitHub issue with refined requirements. (interactive) | GitHub issue key; current codebase accessible at REPO_ROOT | `specs/<issue-key>/analysis.md`, `repositories.yml`, `test-analysis.md` (cached); GitHub issue updated with analysis comment and label `makato-change-analyzed` | 1.1.2 |
| [`design`](skills/design/SKILL.md) | Design technical approach for change request by discovering affected code, planning solution, and updating GitHub issue with implementation strategy. (interactive) | `specs/<issue-key>/analysis.md`, `repositories.yml`; codebase at REPO_ROOT | `specs/<issue-key>/design.md`, `test-scenarios.md` (if E2E work needed); GitHub issue updated with design comment and label `makato-change-designed` (conditional on user approval) | 1.1.1 |
| [`execute`](skills/execute/SKILL.md) | Implement change request by modifying code, updating tests, running verification (quality-guard + code-reviewer loop), and creating a PR linked to the GitHub issue. (autonomous) | `specs/<issue-key>/design.md`, `repositories.yml`; approved design from design skill | Modified source and test files in target repo, feature branch created, PR opened; GitHub issue labeled `makato-change-implemented` and transitioned to Code Review | 1.0.3 |
| [`orchestrate`](skills/orchestrate/SKILL.md) | Guide users through the full change request workflow (analyze → design → execute → resolve-review) with phase tracking and recommendations. (interactive) | GitHub issue key; `specs/<issue-key>/` directory (read for phase detection) | Coordinated CR workflow: invokes phase skills in sequence, tracks completion via artifact existence, loops until all phases complete or user exits | 1.0.0 |
| [`resolve-review`](skills/resolve-review/SKILL.md) | Resolve PR review feedback for change request by addressing comments with code fixes or clarifying replies, then updating GitHub issue status. (interactive) | PR number or GitHub issue key (to look up PR); `specs/<issue-key>/analysis.md`, `design.md`, `repositories.yml` for context | Code fixes committed and pushed to PR branch, review replies posted to comment threads, quality-guard run after code changes; GitHub issue status updated | 1.0.3 |

## Agents

| Agent | Model | Permission | Purpose | Dispatched by |
|-------|-------|------------|---------|---------------|
| `code-explorer` | claude-haiku | `bypassPermissions` (read-only: disallowedTools Write, Edit, Bash, NotebookEdit, WebSearch) | Explore codebase to discover affected files, dependencies, code patterns, test coverage, and project specs context. Returns synthesized findings so calling skills never re-read sources. | analyze (Step 3), design (Step 4 Option B) |
| `requirements-diff-analyzer` | claude-sonnet | `bypassPermissions` (read-only: disallowedTools Write, Edit, Bash, NotebookEdit, WebSearch) | Compare current system behavior against requested changes to produce a structured side-by-side diff, identify gaps, open questions (blocking vs clarifying), and inconsistencies. | analyze (Step 4) |
| `test-analyzer` | claude-haiku | `bypassPermissions` (read-only: disallowedTools Write, Edit, Bash, NotebookEdit, WebSearch) | Discover and analyze all tests (unit, integration, E2E, contract, performance) affected by the change request; map tests to affected functionality; classify impact severity; identify coverage gaps. | analyze (Step 3.5), design (Step 5 when test-analysis.md cache absent) |
| `quality-guard` | claude-haiku | `bypassPermissions` (bash allowed; disallowedTools Write, Edit, NotebookEdit, WebSearch) | Run quality checks (lint, format, type-check, unit tests, coverage) after implementation. Discovers commands from project config, executes them, and reports pass/fail with actionable feedback. Never auto-fixes. | execute (Step 5.5.2), resolve-review (Step 5) |
| `code-reviewer` | claude-sonnet | `bypassPermissions` (read-only: disallowedTools Write, Edit, Bash, NotebookEdit, WebSearch) | Review implementation changes for bugs, security issues, design alignment, and requirements coverage before PR creation. Classifies findings as CRITICAL / MAJOR / MINOR and returns approved or changes_required. | execute (Step 5.5.1) |

## Shared Resources

- `shared/repositories-yml-schema.md` — YAML schema contract for `specs/<issue-key>/repositories.yml`: field reference, path resolution algorithm, validation rules, and lifecycle (analyze writes; design, execute, resolve-review read).
- `shared/path-resolution.md` — Shell algorithm for resolving a repository name from `repositories.yml` to an absolute local path using four ordered strategies (sibling of CWD, same parent one level deeper, CWD basename match, specs parent basename match).
- `shared/commit-message-format.md` — Conventional commit format rules for change request implementation commits: type/scope/subject structure, heredoc usage, body/footer guidance, multi-commit pattern.

## Notable Governance Files

- `plugins/makato-change/AGENTS.md` — Primary governance document: goal, scope boundaries (small/medium/large decision table), agent design principles, file structure, cross-repository patterns, path resolution overview, versioning policy, and PR checklist.
- `plugins/makato-change/README.md` — Plugin overview with workflow ASCII diagram, skills table, agents table, plugin connections, prerequisites, and version claim.
- `plugins/makato-change/.claude-plugin/plugin.json` — Plugin registry metadata: name, description, author (no version field — repo uses release-please).
- `plugins/makato-change/CHANGELOG.md` — Per-PR change history for the plugin.

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|------------|
| Escalates to | `makato-plan` | Large changes (16+ files, new subsystems, significant architectural impact) are escalated here for proper shaping before implementation |
| Escalates to | `makato-build` | Well-scoped changes that need the full TDD pipeline are escalated here instead of using `makato-change` |
| Complements | `makato-core` | Uses the `create-issue` skill for filing carry-over tracking issues when review feedback is deferred |

## Prerequisites / MCP Servers

No MCP servers required.

**External prerequisites:**

- `gh` CLI — required for GitHub issue operations (view, comment, label, edit state) and PR
  operations (create, view, comment on reviews).

## Installation

```bash
claude --plugin-dir ./plugins/makato-change
```

## Version

0.1.0
