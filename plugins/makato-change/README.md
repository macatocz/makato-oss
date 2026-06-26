<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
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
| `analyze` | Analyze change request requirements by comparing current vs. requested behavior, identify and address questions and inconsistencies, update GitHub issue with refined requirements | 1.0.0 |
| `design` | Design technical approach for change request by discovering affected code, planning solution, and updating GitHub issue with implementation strategy | 1.0.0 |
| `execute` | Implement change request by modifying code, updating tests, running verification, and creating pull request with GitHub issue link | 1.0.0 |
| `resolve-review` | Resolve PR review feedback by addressing comments with code fixes or clarifying replies, update GitHub issue status | 1.0.0 |

## Agents

This plugin uses specialized sub-agents for focused tasks:

| Agent | Model | Purpose | Used By |
|-------|-------|---------|---------|
| `code-explorer` | haiku | Explore codebase to discover affected files, dependencies, patterns, and project specs context | analyze, design |
| `requirements-diff-analyzer` | sonnet | Compare current vs requested behavior to produce structured requirements diff with gaps and inconsistencies | analyze |
| `test-analyzer` | haiku | Discover and analyze all tests (unit, integration, E2E) affected by change request, map to affected functionality | analyze, design |
| `quality-guard` | haiku | Run quality checks (lint, format, tests, coverage) after implementation with actionable feedback | execute |
| `code-reviewer` | sonnet | Review implementation changes before PR creation for bugs, security issues, design alignment | execute |

## Prerequisites

The `gh` CLI is required for GitHub operations (available system-wide, no MCP server required).

## Cross-Repository Operations

makato-change can be invoked from **two locations**:

### Option A: From a separate specs working directory

One layout option is to maintain a dedicated specs directory separate from the target repo. This is optional — not required.

**Advantages:**
- Centralized artifact storage (`specs/<issue-key>/`)
- Clean separation: specs separate from the code being changed

**How it works:**
1. On first invocation (analyze skill), you'll be asked for target repository path
2. Path is stored in `specs/<issue-key>/repositories.yml`
3. All code discovery and modifications target that repository
4. Artifacts remain in the specs directory for review and reuse

**Example:**
```bash
cd ~/repos/my-specs-dir

# Invoke analyze skill
/makato-change:analyze ISSUE-1234
# → Prompts: "Which repository does this change affect?"
# → You answer: /Users/username/repos/my-service
# → Creates: specs/ISSUE-1234/repositories.yml
# → Discovers code in my-service
# → Stores analysis in specs/ISSUE-1234/analysis.md

# Invoke execute skill
/makato-change:execute ISSUE-1234
# → Reads: specs/ISSUE-1234/repositories.yml
# → Modifies files in: /Users/username/repos/my-service
# → Creates branch in: my-service repo
# → Creates PR from: my-service repo
```

### Option B: From the target repository (Recommended)

The recommended pattern. Artifacts live inside the target repo under `specs/`.

**How it works:**
1. CWD is automatically detected as target repository
2. Artifacts stored in `<target-repo>/specs/<issue-key>/`

**Example:**
```bash
cd ~/repos/my-service

# Invoke analyze skill
/makato-change:analyze ISSUE-1234
# → Auto-detects: current directory is target repo
# → Creates: my-service/specs/ISSUE-1234/repositories.yml
# → Stores analysis in: my-service/specs/ISSUE-1234/analysis.md
```

### Repository Metadata File

All skills use `specs/<issue-key>/repositories.yml` to track target repository.

**Standard format (automatically portable across team members):**
```yaml
version: "1.0"
affected:
  - name: my-service
    role: primary
    path: my-service
    description: "Frontend application requiring validation rule updates"
```

The `path` field contains just the repository name. Skills automatically resolve this to the local repository path using standard search strategies:

1. Sibling of CWD: `../my-service`
2. Same parent, one level deeper: `../projects/my-service`
3. Current working directory (if basename matches)
4. `specs/` parent directory itself

**Works automatically with standard layouts:**
```
repos/
├── specs/          ← specs committed here
└── my-service/         ← automatically found

repos/
├── specs/
└── projects/
    └── my-service/     ← automatically found
```

**When to edit manually:**
- Repository was renamed (update `name` and `path` to new name)
- Different repository needed for same GitHub issue

**Schema**: See `shared/repositories-yml-schema.md` for full path resolution details.

## Installation

```bash
claude --plugin-dir ./plugins/makato-change
```

## Version

0.1.0
