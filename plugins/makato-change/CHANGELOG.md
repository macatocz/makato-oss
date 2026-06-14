<!-- markdownlint-disable MD012 MD013 -->
# Changelog

## `code-explorer` agent

- **1.0.1**
  - Fix specs-context discovery: replace bash commands (`pwd`, `test -d`, `echo $VAR`) with Glob/Read equivalents so Step 1 works correctly when Bash is in disallowedTools
  - Fix file discovery: replace `find` commands with `glob()` calls in Step 2 for consistency with disallowedTools constraints
- **1.0.0**
  - Initial — Explore codebase to discover affected files, dependencies, patterns, and specs-context context for change requests
  - Enhanced specs-context detection with multi-strategy approach (CWD, sibling directory, environment variable)

## `requirements-diff-analyzer` agent

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

- **1.0.0**
  - Initial — Design technical approach for change requests with code discovery (guided or exploratory), solution planning, and GitHub Issues updates
  - Add repository metadata loading from repositories.yml (Step 1.5)
  - Validate repository path exists before dispatching agents
  - Update agent dispatch to use repositories.yml for REPO_ROOT and REPO_NAME
  - Add automatic path resolution (searches standard locations, no configuration needed)

## `analyze` skill

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

