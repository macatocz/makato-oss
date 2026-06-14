# makato-change — Request for change

## Goal

Implement changes to existing functionality based on updated business requirements.

**How:** Refine requirements against current behavior, identify affected code sections, design a technical approach, implement modifications (including small supporting components when needed), verify changes, create PR, and resolve review feedback.

**Why:** The suite has new feature development (makato-plan → makato-build) and bug fixing (makato-fix planned), but lacks a dedicated workflow for implementing adjustments to existing functionality based on changed business requirements.

## What Belongs Here

- Requirement refinement comparing current behavior vs updated requirements to identify diff that needs to be addressed
- Identification of affected code sections and technical approach design
- Implementation of modifications to existing functionality
- Verification, PR creation, and resolution of review feedback

**Scope boundaries:**

- **Small** (ideal for makato-change): 1-5 files modified, isolated changes, existing test updates only
- **Medium** (fits makato-change): 6-15 files modified, cross-cutting shallow changes, new supporting components (helpers, utils), new + updated tests
- **Large** (escalate to makato-plan): 16+ files, new subsystems/modules, multi-team coordination, significant architectural impact

## What Does NOT Belong Here

- Large-scale changes requiring thorough discovery and preparation (those belong in makato-plan and makato-build)
- Bug fixes and defect resolution (those belong in makato-fix)

## Decision Test

"Does this skill help implement changes to existing functionality based on updated business requirements?"

- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version

## Agents

makato-change uses specialized sub-agents to delegate focused tasks during the CR workflow:

| Agent                                | Model  | Purpose                                                                                                                                   | Used By         |
| ------------------------------------ | ------ | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| **code-explorer**              | haiku  | Explore codebase to discover affected files, dependencies, patterns, and dcp-specs context                                                | analyze, design |
| **requirements-diff-analyzer** | sonnet | Compare current vs requested behavior to produce structured requirements diff with gaps and inconsistencies                               | analyze         |
| **test-analyzer**              | haiku  | Discover and analyze all tests (unit, integration, E2E) affected by change request, map to affected functionality, identify coverage gaps | analyze, design |
| **quality-guard**              | haiku  | Run quality checks (lint, format, tests, coverage) after implementation with actionable feedback                                          | execute         |
| **code-reviewer**              | sonnet | Review implementation changes before PR creation for bugs, security issues, design alignment                                              | execute         |

### Agent Design Principles

- **Read-only agents** (code-explorer, test-impact-analyzer): Use `permissionMode: bypassPermissions` with `disallowedTools: Write, Edit, Bash, NotebookEdit`
- **Model selection**: Haiku for discovery/scanning, Sonnet for analysis/review
- **Structured output**: All agents return markdown with predictable sections and metadata fields
- **Synthesized findings**: Agents distill insights so calling skills never re-read sources
- **Agent versioning**: Bump `version` in agent frontmatter per feature PR

## File Structure

```
makato-change/
├── .claude-plugin/
│   └── plugin.json
├── agents/                  (specialized sub-agents)
│   ├── code-explorer.md
│   ├── requirements-diff-analyzer.md
│   ├── test-analyzer.md
│   ├── quality-guard.md
│   └── code-reviewer.md
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md
│       ├── references/
│       ├── templates/
│       └── shared -> ../../shared  (symlink, if used)
├── shared/                  (plugin-level shared resources)
│   ├── repositories-yml-schema.md
│   └── path-resolution.md
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Cross-Repository Patterns

### Repository Context Flow

1. **analyze** skill discovers target repo and writes `repositories.yml` with repo name
2. **design** skill loads `repositories.yml` and auto-resolves path for code exploration
3. **execute** skill loads `repositories.yml` and auto-resolves path for code modifications and git operations
4. **resolve-review** skill loads `repositories.yml` and auto-resolves path for PR updates

### Path Resolution

The `path` field in `repositories.yml` contains just the repository name (e.g., `dcp-portal-ui`).

**Automatic resolution strategies** (tried in order):

1. **Sibling to dcp-specs**: `../dcp-portal-ui`
2. **Same parent, one level deeper**: `../projects/dcp-portal-ui`
3. **Current working directory**: If basename matches repo name
4. **specs/ parent directory**: If basename matches repo name

No configuration needed - works automatically with standard directory layouts.

See `shared/path-resolution.md` for full algorithm and error handling.

### Agent Dispatch Pattern

All agents receive explicit repository context:

```
REPO_ROOT: <from repositories.yml: affected[role=primary].path>
REPO_NAME: <from repositories.yml: affected[role=primary].name>
```

Agents operate on absolute paths and never assume CWD = target repo.

### Git Operations

All git commands use `-C` flag for repo targeting:

```bash
git -C <REPO_ROOT> status
git -C <REPO_ROOT> checkout -b <branch>
git -C <REPO_ROOT> commit -m "..."
```

This enables running skills from dcp-specs while modifying code in target repo.

### DCP-Specs Context Discovery

The `code-explorer` agent uses multiple strategies to locate dcp-specs context:

1. **CWD check**: Look for `context/<REPO_NAME>/` in current directory
2. **Sibling directory**: Check `<REPO_ROOT>/../dcp-specs/context/<REPO_NAME>/`
3. **Environment variable**: Use `$DCP_SPECS_PATH/context/<REPO_NAME>/` if set

This allows flexible deployment while maintaining access to pre-built service documentation.

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-change): description`
