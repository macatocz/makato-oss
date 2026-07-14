<!-- markdownlint-disable MD013 MD040 -->
# makato-change — Request for change

## Goal

Implement changes to existing functionality based on updated business requirements.

**How:** Refine requirements against current behavior, identify affected code sections, design a technical approach, implement modifications (including small supporting components when needed), verify changes, create PR, and resolve review feedback.

**Why:** The suite has new feature development (makato-plan → makato-build) but no dedicated workflow for implementing targeted adjustments to existing functionality. makato-change fills that gap with a smaller, lower-overhead pipeline than full plan-then-build for changes that don't need fresh shaping.

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
- Bug fixes and defect resolution (out of scope — no dedicated plugin yet; for now, route bug reports through `makato-plan` if shaping is needed, or `makato-build` if the fix is well-scoped)

## Decision Test

"Does this skill help implement changes to existing functionality based on updated business requirements?"

- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/` symlink at the skill root pointing to the plugin's `shared/` directory (Claude Code preserves within-plugin symlinks in the install cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version

## Documentation-skill obligations (suite-wide)

The `makato-doc` skills are mandatory during change execution: the **execute** phase (and its
`code-reviewer`/`quality-guard` agents) MUST use `context7` to look up current API docs before
writing or reviewing code, and any `.md`/README touched by a change MUST use `markdown` /
`crafting-effective-readmes` / `writing-clearly-and-concisely`. See the repo-root `AGENTS.md`
§ *Documentation skills* and `plugins/makato-doc/AGENTS.md`.

makato-change uses specialized sub-agents to delegate focused tasks during the CR workflow:

| Agent                                | Model  | Purpose                                                                                                                                   | Used By         |
| ------------------------------------ | ------ | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| **code-explorer**              | haiku  | Explore codebase to discover affected files, dependencies, patterns, and project specs context                                            | analyze, design |
| **requirements-diff-analyzer** | sonnet | Compare current vs requested behavior to produce structured requirements diff with gaps and inconsistencies                               | analyze         |
| **test-analyzer**              | haiku  | Discover and analyze all tests (unit, integration, E2E) affected by change request, map to affected functionality, identify coverage gaps | analyze, design |
| **quality-guard**              | haiku  | Run quality checks (lint, format, tests, coverage) after implementation with actionable feedback                                          | execute         |
| **code-reviewer**              | sonnet | Review implementation changes before PR creation for bugs, security issues, design alignment                                              | execute         |
| **change-implementer**         | sonnet | Apply the design's file modifications in an isolated context (write-capable); invokes recommended skills + mandatory context7 before editing | execute         |

### Agent Design Principles

- **Read-only agents** (code-explorer, test-analyzer): Use `permissionMode: bypassPermissions` with `disallowedTools: Write, Edit, Bash, NotebookEdit`
- **Write-capable agent** (change-implementer): Uses `permissionMode: bypassPermissions` with NO `disallowedTools` — it performs the design's file modifications in an isolated context (the write phase of `execute` Step 2). It is dispatched only by `execute`, never invoked directly. Do not grant write access to any other agent without documenting the reason here.
- **Model selection**: Haiku for discovery/scanning, Sonnet for analysis/review/implementation
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
│   ├── code-reviewer.md
│   └── change-implementer.md
├── skills/
│   ├── analyze/             # Refine requirements vs current behavior
│   ├── design/              # Plan technical approach + affected code
│   ├── execute/             # Implement, verify, open PR
│   ├── orchestrate/         # Entry-point wrapper that walks analyze → design → execute → resolve-review
│   └── resolve-review/      # Address PR review feedback
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

The `path` field in `repositories.yml` contains just the repository name (e.g., `my-service`).

**Automatic resolution strategies** (tried in order):

1. **Sibling of CWD**: `../my-service`
2. **Same parent, one level deeper**: `../projects/my-service`
3. **Current working directory**: If basename matches repo name
4. **`specs/` parent directory**: If basename matches repo name

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

This enables running skills from any working directory while modifying code in the target repo.

### Project Specs Discovery

The `code-explorer` agent locates the project specs root using two strategies:

1. **`makato.config.json`**: Read `<REPO_ROOT>/makato.config.json` and use the `specsRoot` field (or `specs` / `specsPath`)
2. **In-repo `specs/` directory**: Look for `<REPO_ROOT>/specs/index.yml`

The agent never scans sibling directories and never reads from environment variables. If neither strategy succeeds, the agent proceeds without project-spec context.

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
