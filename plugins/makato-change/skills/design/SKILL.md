---
name: design
description: Design technical approach for change request by discovering affected code, planning solution, and updating Jira with implementation strategy. Use for technical design, solution planning, code discovery, implementation approach.
version: "1.0.0"
argument-hint: "[ISSUE-KEY]"
---

# Design Change Request Solution

Design the technical approach for implementing a change request. Discovers affected code (guided by user or exploratory), plans the solution, and produces a structured design artifact with implementation strategy.

## When to Use

- Analysis is complete (analyze skill has run and produced `specs/<jira-key>/analysis.md`)
- Requirements are clear (critical open questions resolved)
- Need to plan the technical implementation before coding
- Want to identify affected files, design the solution approach, and get approval before executing

## When NOT to Use

- Analysis hasn't been done yet (run analyze skill first)
- Critical open questions from analysis are unresolved (get stakeholder answers first)
- Scope was determined to be too large for makato-change (escalate to makato-plan instead)
- Already have a complete design and ready to implement (use execute skill)

---

## Workflow

### Step 1: Load Analysis Artifact

Jira key is required (from argument or ask user).

Read the analysis artifact at `specs/<jira-key>/analysis.md`:
- Validate artifact exists (if not, prompt user to run analyze skill first)
- Extract: requirements summary, current behavior, requested changes, scope estimate, open questions
- Confirm scope is small/medium (not escalated to makato-plan)

**Optional: Fetch latest from Jira** (if user wants to check for updates):
- Use MCP tool `mcp__plugin_daff-core_jira__get_issue` to get current status (do NOT use `gh issue view`)
- Compare with analysis artifact to detect any requirement changes

### Step 1.5: Load Repository Metadata

Read `specs/<jira-key>/repositories.yml`.

**If repositories.yml does NOT exist:**
- Error: "Repository metadata not found. Run analyze skill first to discover target repository."
- Exit gracefully

**Load and validate** (per @shared/repositories-yml-schema.md):

```yaml
version: "1.0"
affected:
  - name: <repo-name>
    role: primary
    path: <repo-name>  # just the repo name, will be auto-resolved
```

**Extract:**
- REPO_NAME: `affected[role=primary].path`

**Resolve path** using @shared/path-resolution.md algorithm:

Determine base search directory:
```bash
SPECS_DIR="specs/<ISSUE_KEY>"
SPECS_ROOT=$(cd "$(dirname "$SPECS_DIR")" && cd .. && pwd)
```

Try multiple search strategies:

1. **Sibling to dcp-specs**: `$SPECS_ROOT/../$REPO_NAME`
2. **Same parent, one level deeper**: `$SPECS_ROOT/../*/$REPO_NAME`
3. **Current working directory**: If `git rev-parse --show-toplevel` basename matches `$REPO_NAME`
4. **specs/ parent itself**: If `$SPECS_ROOT` basename matches `$REPO_NAME`

Set `REPO_ROOT` to first matching location.

**Validate resolved path:**
```bash
test -d "$REPO_ROOT/.git"
```

If validation fails:
- Show searched locations
- Suggest standard layouts (see @shared/path-resolution.md for error message template)
- Exit gracefully

**If validation fails:**
- Inform user with specific failure: "Repository not found at <REPO_ROOT>" or "Invalid repositories.yml structure"
- Suggest: "Update `specs/<jira-key>/repositories.yml` manually or re-run analyze skill"
- Exit gracefully

**Store for subsequent steps:**
- REPO_ROOT: <absolute-path>
- REPO_NAME: <repo-name>

### Step 2: Verify Prerequisites

Check if critical open questions from the analysis are resolved:
- If the analysis flagged "Critical (Block Design)" questions that are still unanswered, inform the user
- Explain why design cannot proceed without answers
- Suggest getting stakeholder input first, then re-running this skill

If questions are resolved or there were none, proceed.

### Step 3: Ask User for Code Discovery Preference

Load @references/code-discovery-strategies.md to understand the two approaches.

Present options to the user using AskUserQuestion:

**Question:** "How would you like to discover the affected code?"

**Option A (Guided):** "I know where changes need to go — I'll provide file paths and modules"
- Choose this when you're familiar with the codebase and know exactly what needs to change
- Faster, more direct

**Option B (Exploratory):** "Help me find affected code — run discovery agent"
- Choose this when you need to explore the codebase to identify affected areas
- Spawns an agent to search and map the code

Capture the user's preference.

### Step 4: Discover Affected Code (Based on Preference)

#### If Option A (Guided)

Ask the user to provide:
1. **File paths** that need to be modified (e.g., `src/components/UserProfile.tsx`, `api/users.py`)
2. **Module or component names** involved
3. **Related test files** (if known)

Confirm understanding by listing back what the user provided:
> "Got it. I'll design changes for:
> - `src/components/UserProfile.tsx` (UI component)
> - `api/users.py` (backend API)
> - `tests/test_users.py` (test coverage)
>
> Is that correct?"

Wait for confirmation before proceeding.

#### If Option B (Exploratory)

**Dispatch `code-explorer` agent** to discover affected code:

**Agent input:**
```
REPO_ROOT: <from Step 1.5: repositories.yml primary repo path>
REPO_NAME: <from Step 1.5: repositories.yml primary repo name>
FEATURE_KEYWORDS: <extract from analysis artifact: requirements + requested changes>
REQUESTED_CHANGES: <brief summary from analysis artifact>
```

Extract FEATURE_KEYWORDS by identifying key terms from analysis artifact:
- Feature names mentioned in requirements
- Component names from current behavior section
- Technical terms from requested changes

**Agent will return:**
- Primary affected files and their roles
- Dependencies (inbound/outbound)
- Code patterns and conventions
- DCP-specs context (if available)

**Store result** in working memory as CODE_EXPLORATION_RESULT.

**Extract for design:**
- List of files to modify (with descriptions)
- Existing patterns to follow (naming, error handling, testing)
- Dependencies to consider

### Step 5: Analyze Test Coverage

**Dispatch `test-analyzer` agent** to discover all affected tests.

**Agent input:**
```
REPO_ROOT: <from Step 1.5: repositories.yml primary repo path>
AFFECTED_FILES: <from code-explorer results or user-guided list>
FEATURE_KEYWORDS: <same as Step 4>
REQUESTED_CHANGES: <brief summary from analysis artifact>
```

**Agent will return:**
- Unit tests found and their coverage
- Integration tests found
- E2E tests found with scenario details
- Coverage gaps identified

**Store result** in working memory as TEST_ANALYSIS_RESULT.

**Extract for design:**
- Existing E2E test scenarios (IDs and names)
- What user workflows are currently validated
- What test updates will be needed

### Step 6: Read and Understand Affected Code

Read the key files identified in Step 4:
- Understand how the code is structured
- Note patterns and conventions used (naming, error handling, testing style)
- Identify dependencies: what this code imports, what imports it
- Review existing test coverage: what's tested, what's not

Focus on understanding enough to design a solution that fits the existing codebase patterns, not reading every line in detail.

### Step 7: Design Solution Approach

Load @references/solution-design-pattern.md for structure guidance.

Design how the changes will be implemented:

#### What Will Be Modified
List existing files/functions that need changes and what kind of changes (edit logic, add parameters, refactor, etc.)

#### What Will Be Added
Identify new components needed:
- New UI elements (buttons, dialogs, form fields)
- New functions or classes
- New validation rules
- New error messages
- Config or schema changes

#### Patterns to Follow
Note existing patterns in the codebase that the solution should match:
- Naming conventions (function names, variable names)
- Error handling style (exceptions, return codes, validation patterns)
- Testing approach (unit tests, integration tests, mocking strategy)

#### Edge Cases and Error Handling
Plan how to handle:
- Edge cases identified in the analysis
- Error scenarios (what error messages, what recovery)
- Validation (what rules, where to enforce)

#### Test Strategy

**Use TEST_ANALYSIS_RESULT to inform strategy:**
- What existing tests need updates (from test-analyzer: existing unit/integration tests)
- What new tests need to be written (to cover new behavior)
- What E2E scenarios need updates (from test-analyzer: E2E tests found)
- What test data or fixtures are needed

**Determine test scope:**
- **Module-only tests**: Change is isolated to one module/package with clear boundaries
  - Modified code only affects that module
  - No shared utilities or cross-module dependencies touched
  - Run only that module's test suite
- **Full test suite**: Change affects shared code or has cross-cutting impact
  - Modified shared utilities, common libraries, or base classes
  - Changed API contracts or data models used by multiple modules
  - Modified configuration, environment setup, or build process
  - When unsure about impact → default to full suite
- Document the test scope decision in the design artifact

### Step 8: Plan Implementation Steps

Load @references/implementation-planning-guide.md for step breakdown guidance.

Break the solution into logical implementation chunks (not exhaustive task list, just major phases):

**Example structure:**
1. Update data model/schema (if needed)
2. Implement backend logic changes
3. Update API endpoints (if needed)
4. Implement UI changes
5. Add/update tests
6. Verify end-to-end

Order the steps logically based on dependencies. Consider: should tests be written first (TDD)? Does backend need to be done before frontend?

Identify risks or blockers:
- **Unknowns:** framework capabilities, performance implications, third-party dependencies
- **External dependencies:** waiting on other teams, infrastructure changes needed
- **Technical risks:** breaking changes, migration complexity, edge case coverage

Validate scope: if the design is revealing more complexity than expected, flag it. If scope is growing beyond small/medium, recommend pausing and escalating to makato-plan.

### Step 9: Generate Design Artifact

Load @templates/design.md for structure.

Write the complete design to `specs/<jira-key>/design.md`:

**Required sections:**
1. **Overview** — Reference to analysis, summary of design approach
2. **Affected Files** — List with descriptions (what each file does, why it's affected)
3. **Solution Approach** — Detailed design (what will be modified, what will be added, patterns to follow)
4. **Implementation Plan** — Logical steps (major phases, ordering, dependencies)
5. **Test Strategy** — What tests to update/add, test approach, E2E scenarios to update
6. **Test Scope** — Module-only or full suite, with justification
7. **Risks** — Unknowns, blockers, technical concerns
8. **Supporting Components** — New UI elements, helpers, config changes

Link back to the analysis artifact for traceability:
> Analysis: `specs/<jira-key>/analysis.md`

Make the artifact self-contained so the execute skill can implement from this design without needing conversation context.

### Step 10: Present Design to User for Approval

Show a summary of the design to the user:

**Summary format:**
```
## Design Summary

**Files affected:** <count> files
- <file-1>: <role>
- <file-2>: <role>
- ...

**Key changes:**
- <high-level change 1>
- <high-level change 2>

**Implementation approach:**
<1-2 sentence overview>

**Risks:**
<list if any, or "None identified">

**Full design:** `specs/<jira-key>/design.md`
```

Use `AskUserQuestion` to get approval:

**Question:** "Does this design look good?"

**Options:**
1. **Approve and post to Jira** — Accept design and update Jira issue with design summary
2. **Approve but don't post to Jira** — Accept design but skip Jira update (useful for drafts or offline work)
3. **Request changes** — Provide feedback to revise the design

If user requests changes:
- Address their feedback
- Regenerate the design artifact
- Present the updated summary again with the same approval options

Store the user's choice: `POST_TO_JIRA` (boolean)

### Step 11: Update Jira Issue (Conditional)

**Only proceed if user selected "Approve and post to Jira" in Step 10.**

Load @references/jira-design-update-format.md for comment structure.

Post the solution approach as a Jira comment using `mcp__plugin_daff-core_jira__add_comment`:

**IMPORTANT**: Use Jira Wiki Markup format (NOT Markdown). Key syntax:
- Headers: `h2.`, `h3.` (NOT `##`, `###`)
- Bold: `*text*` (NOT `**text**`)
- Numbered lists: `#` at line start (NOT `1.`, `2.`)
- Bulleted lists: `*` at line start
- Monospace: `{{text}}` (NOT backticks)
- Horizontal rule: `----` (NOT `---`)

**Comment template:**
```
h2. Technical Design

*Files Affected:* <count>

h3. Solution Approach
<2-3 sentence summary of how changes will be implemented>

h3. Key Changes
* <change 1>
* <change 2>
* <change 3>

h3. Implementation Steps
# <step 1>
# <step 2>
# <step 3>

h3. Risks
<list using * if any, or "None identified">

*Estimated time:* <minutes/hours>

----
Full design: {{specs/<jira-key>/design.md}}
```

Add label `cr-designed` using `mcp__plugin_daff-core_jira__add_label`.

**Transition status if needed:**
- Get current issue status using `mcp__plugin_daff-core_jira__get_issue` (with fields: ["status"])
- If status is "New", transition to "Open":
  - Get available transitions using `mcp__plugin_daff-core_jira__get_transitions`
  - Find transition to "Open" status
  - Execute transition using `mcp__plugin_daff-core_jira__transition_issue` (no comment needed for this straightforward transition)
  - If transition fails (not available), continue without error (workflow may differ by project)

### Step 12: Present Summary to User

Confirm completion:
> "Design complete and posted to Jira.
> 
> **Design artifact:** `specs/<jira-key>/design.md`
> 
> **Next step:** Proceed to execute skill to implement the changes."

Provide the path to the design artifact for reference.
