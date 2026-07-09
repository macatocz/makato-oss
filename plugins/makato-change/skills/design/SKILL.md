---
name: design
description: Design technical approach for change request by discovering affected code, planning solution, and updating GitHub issue with implementation strategy. Use for technical design, solution planning, code discovery, implementation approach.
version: "1.2.0"
argument-hint: "[ISSUE-KEY]"
---

# Design Change Request Solution

Design the technical approach for implementing a change request. Discovers affected code (guided by user or exploratory), plans the solution, and produces a structured design artifact with implementation strategy.

## When to Use

- Analysis is complete (analyze skill has run and produced `specs/<issue-key>/analysis.md`)
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

GitHub Issues key is required (from argument or ask user).

Read the analysis artifact at `specs/<issue-key>/analysis.md`:
- Validate artifact exists (if not, prompt user to run analyze skill first)
- Extract: requirements summary, current behavior, requested changes, scope estimate, open questions
- Confirm scope is small/medium (not escalated to makato-plan)

**Optional: Fetch latest from GitHub Issues** (if user wants to check for updates):
- Use MCP tool `gh issue view` to get current status (do NOT use `gh issue view`)
- Compare with analysis artifact to detect any requirement changes

### Step 1.5: Load Repository Metadata

Read `specs/<issue-key>/repositories.yml`.

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

1. **Sibling of CWD**: `$SPECS_ROOT/../$REPO_NAME`
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
- Suggest: "Update `specs/<issue-key>/repositories.yml` manually or re-run analyze skill"
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

**Headless branch (MAKATO_HEADLESS=1):**

Auto-select **Guided mode** (Option A). Log an `autonomous_bypass` entry:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" discovery-preference guided cli_flag
```
Proceed to Step 4 Option A. Since no user has provided file paths, derive affected files from the analysis artifact's "Affected Files" section and CODE_EXPLORATION_RESULT. If neither source yields a list, dispatch the code-explorer agent (Option B) without prompting.

**Interactive branch (default):**

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
- Project specs context (if available)

**Store result** in working memory as CODE_EXPLORATION_RESULT.

**Extract for design:**
- List of files to modify (with descriptions)
- Existing patterns to follow (naming, error handling, testing)
- Dependencies to consider

### Step 5: Load Test Analysis (Cached from Analyze Phase)

**Read cached test analysis artifact:**

Read `specs/<issue-key>/test-analysis.md` if it exists (written by analyze skill).

**If file exists:**
- Extract: existing E2E test scenarios, what test updates will be needed, coverage gaps
- Store in working memory as TEST_ANALYSIS_RESULT

**If file does NOT exist:**

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

### Step 5.5: Document Gherkin Test Scenarios (If New Workflows or Updates Identified)

**Check if E2E scenario work is needed:**

From CODE_EXPLORATION_RESULT and TEST_ANALYSIS_RESULT, determine if:
- New user-facing workflows are being added (not covered by existing E2E tests)
- OR existing E2E scenarios need updates (from TEST_ANALYSIS_RESULT: scenarios with High/Medium impact)

**If no new scenarios AND no updates needed:**
- Skip to Step 6
- Note in design: "No E2E test changes needed"

**If new scenarios OR updates are needed:**

Write `specs/<issue-key>/test-scenarios.md` documenting:

```markdown
# Test Scenarios: <issue-key>

## Existing Scenarios to Update
(from TEST_ANALYSIS_RESULT: scenarios with High/Medium impact)
- Scenario: <name> — <what needs updating>
- ...

## New Scenarios to Add
(for each new user-facing workflow)
- Scenario: <title>
  Given <precondition>
  When <action>
  Then <expected outcome>
- ...
```

**Note:** The artifact is created even if only updates are needed (no new scenarios). Both update documentation and new scenario descriptions belong here.

**Store result** in working memory as TEST_SCENARIOS_RESULT.

### Step 5.6: Review New Scenario Classification

**Only proceed if TEST_SCENARIOS_RESULT contains a non-empty "New Scenarios to Add" section** — skip to Step 6 if only existing scenario updates are documented.

**Check artifact content:**
- Read `specs/<issue-key>/test-scenarios.md`
- If "New Scenarios to Add" section is empty or absent: skip to Step 6
- If "New Scenarios to Add" has scenarios: classify each as `e2e` or `unit`

**Headless branch (MAKATO_HEADLESS=1):**

Auto-approve the classifications. Log an `autonomous_bypass` entry:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" scenario-classification approve cli_flag
```
Proceed directly to Step 6.

**Interactive branch (default):**

**Present classification summary to user for confirmation:**

Use AskUserQuestion:

**Question:** "Review the new test scenario classifications below. Do these look correct?"

**Header:** "Test Classification"

Present each new scenario with its proposed implementation type.

**Options:**
1. **Approve classifications** — Proceed with design artifact
2. **Request changes** — I'll provide feedback on specific scenarios

If "Request changes": update test-scenarios.md with corrected implementation types.

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

Write the complete design to `specs/<issue-key>/design.md`:

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
> Analysis: `specs/<issue-key>/analysis.md`

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

**Full design:** `specs/<issue-key>/design.md`
```

**Headless branch (MAKATO_HEADLESS=1):**

Auto-approve the design. Log HALT-CH-003 audit entry:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" design-approval approve cli_flag \
  '{"halt_code":"HALT-CH-003","note":"auto-approved in autonomous mode"}'
```

Set `POST_TO_JIRA = (MAKATO_CHANGE_POST_DESIGN == "1")`. Proceed to Step 11 conditionally.

**Interactive branch (default):**

Use `AskUserQuestion` to get approval:

**Question:** "Does this design look good?"

**Options:**
1. **Approve and post to GitHub Issues** — Accept design and update GitHub Issues issue with design summary
2. **Approve but don't post to GitHub Issues** — Accept design but skip GitHub Issues update (useful for drafts or offline work)
3. **Request changes** — Provide feedback to revise the design

If user requests changes:
- Address their feedback
- Regenerate the design artifact
- Present the updated summary again with the same approval options

Store the user's choice: `POST_TO_JIRA` (boolean)

### Step 11: Update GitHub Issues Issue (Conditional)

**Only proceed if user selected "Approve and post to GitHub Issues" in Step 10.**

Load @references/jira-design-update-format.md for comment structure.

Post the solution approach as a GitHub issue comment using `gh issue comment`:

**IMPORTANT**: Use GitHub Issues Wiki Markup format (NOT Markdown). Key syntax:
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
Full design: {{specs/<issue-key>/design.md}}
```

Add label `makato-change-designed` using `gh issue edit --add-label`.

**Transition status if needed:**
- Get current issue status using `gh issue view` (with fields: ["status"])
- If status is "New", transition to "Open":
  - Get available transitions using `gh issue view --json state`
  - Find transition to "Open" status
  - Execute transition using `gh issue edit --state` (no comment needed for this straightforward transition)
  - If transition fails (not available), continue without error (workflow may differ by project)

### Step 12: Present Summary to User

Confirm completion:
> "Design complete and posted to GitHub Issues.
>
> **Design artifact:** `specs/<issue-key>/design.md`
>
> **Next step:** Proceed to execute skill to implement the changes."

Provide the path to the design artifact for reference.
