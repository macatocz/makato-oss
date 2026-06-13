# makato-change

**Goal**: Implement changes to existing functionality based on updated business requirements.

**How**: Refine requirements against current behavior, identify affected code sections, design a technical approach, implement modifications (including small supporting components when needed), verify changes, create PR, and resolve review feedback.

**Why**: The suite has new feature development (makato-plan → makato-build) and bug fixing (makato-fix planned), but lacks a dedicated workflow for implementing adjustments to existing functionality based on changed business requirements.

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

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `orchestrate` | Guide users through change request workflow (analyze, design, execute, resolve-review), track progress, coordinate phases | 1.0.0 |
| `analyze` | Analyze change request requirements by comparing current vs. requested behavior, identify and address questions and inconsistencies, update Jira with refined requirements | 1.0.0 |
| `design` | Design technical approach for change request by discovering affected code, planning solution, and updating Jira with implementation strategy | 1.0.0 |
| `execute` | Implement change request by modifying code, updating tests, running verification, and creating pull request with Jira link | 1.0.0 |
| `resolve-review` | Resolve PR review feedback by addressing comments with code fixes or clarifying replies, update Jira status | 1.0.0 |

## Agents

This plugin uses specialized sub-agents for focused tasks:

| Agent | Model | Purpose | Used By |
|-------|-------|---------|---------|
| `code-explorer` | haiku | Explore codebase to discover affected files, dependencies, patterns, and dcp-specs context | analyze, design |
| `requirements-diff-analyzer` | sonnet | Compare current vs requested behavior to produce structured requirements diff with gaps and inconsistencies | analyze |
| `test-analyzer` | haiku | Discover and analyze all tests (unit, integration, E2E) affected by change request, map to affected functionality | analyze, design |
| `quality-guard` | haiku | Run quality checks (lint, format, tests, coverage) after implementation with actionable feedback | execute |
| `code-reviewer` | sonnet | Review implementation changes before PR creation for bugs, security issues, design alignment | execute |

## Prerequisites

### Required Plugins

- **daff-core** — Provides Jira MCP server for fetching requirements and updating issues

### MCP Servers

This plugin uses MCP servers declared in `daff-core`:

| Server | Purpose | Source |
|--------|---------|--------|
| `jira` (from daff-core) | Fetch change request requirements from Jira (github.com) and link PRs back to Jira issues | `daff-core/.mcp.json` |

The `gh` CLI is used for GitHub operations (available system-wide, no MCP server required).

## Cross-Repository Operations

makato-change can be invoked from **two locations**:

### Option A: From dcp-specs (Recommended)

**Advantages:**
- Centralized artifact storage (`dcp-specs/specs/<jira-key>/`)
- Access to pre-built context files (`context/<repo-name>/`)
- Clean separation: specs in dcp-specs, code changes in target repo

**How it works:**
1. On first invocation (analyze skill), you'll be asked for target repository path
2. Path is stored in `specs/<jira-key>/repositories.yml`
3. All code discovery and modifications target that repository
4. Artifacts remain in dcp-specs for review and reuse

**Example:**
```bash
cd ~/repos/dcp-specs

# Invoke analyze skill
/makato-change:analyze DCP-1234
# → Prompts: "Which repository does this change affect?"
# → You answer: /Users/username/repos/dcp-portal-ui
# → Creates: dcp-specs/specs/DCP-1234/repositories.yml
# → Discovers code in dcp-portal-ui
# → Stores analysis in dcp-specs/specs/DCP-1234/analysis.md

# Invoke execute skill
/makato-change:execute DCP-1234
# → Reads: dcp-specs/specs/DCP-1234/repositories.yml
# → Modifies files in: /Users/username/repos/dcp-portal-ui
# → Creates branch in: dcp-portal-ui repo
# → Creates PR from: dcp-portal-ui repo
```

### Option B: From target repository

**Advantages:**
- Quick for one-off changes
- No need to navigate to dcp-specs

**How it works:**
1. CWD is automatically detected as target repository
2. Artifacts stored in `<target-repo>/specs/<jira-key>/`

**Example:**
```bash
cd ~/repos/dcp-portal-ui

# Invoke analyze skill
/makato-change:analyze DCP-1234
# → Auto-detects: current directory is target repo
# → Creates: dcp-portal-ui/specs/DCP-1234/repositories.yml
# → Stores analysis in: dcp-portal-ui/specs/DCP-1234/analysis.md
```

### Repository Metadata File

All skills use `specs/<jira-key>/repositories.yml` to track target repository.

**Standard format (automatically portable across team members):**
```yaml
version: "1.0"
affected:
  - name: dcp-portal-ui
    role: primary
    path: dcp-portal-ui
    description: "Frontend application requiring validation rule updates"
```

The `path` field contains just the repository name. Skills automatically resolve this to the local repository path using standard search strategies:

1. Sibling to dcp-specs: `../dcp-portal-ui`
2. Same parent, one level deeper: `../projects/dcp-portal-ui`
3. Current working directory (if basename matches)
4. specs/ parent directory itself

**Works automatically with standard layouts:**
```
repos/
├── dcp-specs/          ← specs committed here
└── dcp-portal-ui/      ← automatically found

repos/
├── dcp-specs/
└── projects/
    └── dcp-portal-ui/  ← automatically found
```

**When to edit manually:**
- Repository was renamed (update `name` and `path` to new name)
- Different repository needed for same Jira issue

**Schema**: See `shared/repositories-yml-schema.md` for full path resolution details.

## Installation

```bash
claude --plugin-dir ./plugins/makato-change
```

## Version

0.1.0
