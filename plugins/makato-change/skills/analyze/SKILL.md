---
name: analyze
description: Analyze change request requirements by comparing current behavior against requested changes, identify and address open questions and inconsistencies, update GitHub issue with refined requirements. Use for change requests, requirement analysis, behavior comparison, scope estimation.
version: "1.1.2"
argument-hint: "[ISSUE-KEY]"
---

# Analyze Change Request

Analyze change request requirements by comparing current system behavior against requested changes. Produces a structured analysis artifact identifying what needs to change, open questions requiring clarification, and scope estimation.

## When to Use

- Starting work on a GitHub Issues Story or Activity that requests changes to existing functionality
- Need to understand the gap between current behavior and requested behavior
- Need to identify ambiguities or missing information before design begins
- Want to validate scope fits makato-change (small/medium changes) vs. makato-plan (large features)

## When NOT to Use

- Issue is a bug/defect with no business-requirement change (route through `makato-plan` if shaping is needed, or `makato-build` if the fix is well-scoped)
- Issue is a new feature with no existing functionality to change (use makato-plan)
- Already have a complete analysis and ready to design the solution (use design skill)
- Issue is not in GitHub Issues or lacks a GitHub Issues key

---

## Workflow

### Step 1: Fetch Requirements from GitHub Issues

GitHub Issues issue key is required (passed as argument or asked from user).

**IMPORTANT:** Use the GitHub Issues MCP tool only. Do NOT use `gh issue view` or attempt to fetch from GitHub.

Call the MCP tool `gh issue view` with the issue key:

```json
{
  "issueKey": "<issue-key>"
}
```

Response handling:
- Validate issue exists and type is Story or Activity
- Extract: summary, description, acceptance criteria, comments, current status
- If issue type is not Story or Activity, inform user and exit
- If MCP tool fails, report the error - do not fall back to GitHub

### Step 2: Establish Artifact Location

Create the artifact directory for this change request:
```
specs/<issue-key>/
```

This follows the makato-plan pattern of project-scoped work directories. All analysis artifacts for this change request will live here. The design and execute skills will load artifacts from this location.

### Step 2.2: Add Suite and Plugin Labels

Add labels `makato` and `makato-change` using `gh issue edit --add-label` (two separate calls or combined). These identify issues managed by the makato suite and specifically by the makato-change plugin.

### Step 2.5: Discover Target Repository

**Check for existing repository metadata:**

Read `specs/<issue-key>/repositories.yml` if it exists.

**If repositories.yml exists:**

Load it using @shared/repositories-yml-schema.md for validation.

Extract primary repo:
- REPO_ROOT = `affected[role=primary].path`
- REPO_NAME = `affected[role=primary].name`

Validate the path exists and is a git repository:
```bash
test -d <REPO_ROOT> && test -d <REPO_ROOT>/.git
```

If validation fails:
- Warn user: "Repository not found at <REPO_ROOT> or not a git repository"
- Suggest: "Update `specs/<issue-key>/repositories.yml` with correct path or delete it to re-discover"
- Ask user if they want to continue with re-discovery or fix manually
- If re-discovery chosen: proceed to prompt below
- If manual fix: exit gracefully

**If repositories.yml does NOT exist:**

Use AskUserQuestion to discover target repository:

**Question:** "Which repository does this change affect?"

**Header:** "Target Repository"

**Options:**
1. **Current directory** (description: "The change affects the repository in my current working directory")
2. **Provide path** (description: "I'll provide the absolute path to the target repository")
3. **Multiple repositories** (description: "This change spans multiple repos — I should use makato-plan instead")

**If option 1 (Current directory):**
- Run `git rev-parse --show-toplevel` to get repo root
- If command fails: "Current directory is not a git repository. Please choose 'Provide path' or navigate to target repo."
- Set REPO_ROOT = command output
- Extract REPO_NAME from last path segment of REPO_ROOT

**If option 2 (Provide path):**
- Capture user's path from annotations/notes
- Validate path exists and is a git repo:
  ```bash
  test -d <user-path> && test -d <user-path>/.git
  ```
- If validation fails: "Path does not exist or is not a git repository. Please provide a valid path."
- Set REPO_ROOT = user's path
- Extract REPO_NAME from last path segment

**If option 3 (Multiple repositories):**
- Inform user: "Changes spanning multiple repositories should use the makato-plan → makato-build workflow for proper discovery and decomposition."
- Suggest: "Consider filing this as a feature request rather than a change request."
- Exit skill gracefully

**Write repositories.yml:**

Create `specs/<issue-key>/repositories.yml` with just the repository name:

```yaml
version: "1.0"
affected:
  - name: <REPO_NAME>
    role: primary
    path: <REPO_NAME>
    description: "<GitHub Issues summary one-line>"
```

**Note**: The `path` field contains just the repo name (same as `name`). Consumer skills will automatically resolve this to the local path using standard search strategies. No configuration needed - works for everyone with standard directory layouts.

**Store for subsequent steps:**
- REPO_ROOT: <absolute-path>
- REPO_NAME: <repo-name>

### Step 3: Discover Affected Code and Current Behavior

**Dispatch `code-explorer` agent** to discover affected files, dependencies, and patterns.

**Agent input:**
```
REPO_ROOT: <from Step 2.5: repositories.yml primary repo path>
REPO_NAME: <from Step 2.5: repositories.yml primary repo name>
FEATURE_KEYWORDS: <extract from GitHub Issues summary/description>
REQUESTED_CHANGES: <brief summary from GitHub Issues>
```

Extract FEATURE_KEYWORDS by identifying key terms from GitHub Issues summary and description:
- Feature names (e.g., "user registration", "password validation")
- Component names (e.g., "checkout", "order service")
- Technical terms (e.g., "authentication", "payment processing")

**Agent will return:**
- Primary affected files and their roles
- Dependencies (inbound/outbound)
- Code patterns and conventions
- Project specs context (if available)

**Store result** in working memory as CODE_EXPLORATION_RESULT.

**Document current behavior** from agent findings:
- What the system does now (from file analysis)
- How it does it (key files, functions, data flow)
- What constraints exist (from project specs or code patterns)

### Step 3.5: Analyze Test Coverage

**Dispatch `test-analyzer` agent** to discover all affected tests.

**Agent input:**
```
REPO_ROOT: <from Step 2.5: repositories.yml primary repo path>
AFFECTED_FILES: <from code-explorer results>
FEATURE_KEYWORDS: <same as Step 3>
REQUESTED_CHANGES: <brief summary from GitHub Issues>
```

**Agent will return:**
- Unit tests found and their coverage
- Integration tests found
- E2E tests found with scenario details
- Coverage gaps identified

**Store result** in working memory as TEST_ANALYSIS_RESULT.

**Extract for analysis:**
- Existing E2E test scenarios (IDs and names)
- What user workflows are currently validated
- What test updates will be needed

### Step 4: Generate Requirements Comparison

**Dispatch `requirements-diff-analyzer` agent** to compare current vs requested behavior.

**Agent input:**
```
ISSUE_KEY: <issue-key>
CURRENT_BEHAVIOR: <synthesized from code-explorer results>
REQUESTED_CHANGES: <from GitHub Issues: summary + description + ACs>
CODE_EXPLORATION_RESULT: <full output from code-explorer>
EXISTING_TESTS: <from test-analyzer: unit and E2E test list>
```

**Agent will return:**
- Side-by-side comparison table (current vs requested)
- Identified gaps and missing information
- Open questions (blocking and clarifying)
- Inconsistencies and conflicts
- Completeness assessment (ready_for_design | needs_clarification | resolve_conflicts)

**Store result** in working memory as REQUIREMENTS_DIFF_RESULT.

**Extract for analysis artifact:**
- Comparison table
- Open questions list
- Inconsistencies list
- E2E scenarios affected (from test-analyzer + requirements-diff-analyzer synthesis)

### Step 5: Identify Open Questions

**Extract from REQUIREMENTS_DIFF_RESULT:**
- Load open questions identified by requirements-diff-analyzer
- Questions are pre-classified as blocking vs clarifying
- Agent has already flagged ambiguities, missing information, and decision points

**Supplement if needed:**
- Load @references/question-identification-guide.md for additional patterns
- Review CODE_EXPLORATION_RESULT for technical constraints that raise questions
- Review TEST_ANALYSIS_RESULT for test coverage gaps that need clarification

**Consolidate questions:**
- Merge agent findings with any additional questions discovered
- Remove duplicates, prioritize by blocking impact
- For each question: what's unclear, why it matters, who can answer

### Step 6: Check for Inconsistencies

**Extract from REQUIREMENTS_DIFF_RESULT:**
- Load inconsistencies and conflicts identified by requirements-diff-analyzer
- Agent has already flagged internal contradictions, system conflicts, technical impossibilities
- Agent provides completeness assessment: ready_for_design | needs_clarification | resolve_conflicts

**Supplement if needed:**
- Review CODE_EXPLORATION_RESULT for technical constraints that create conflicts
- Check if requested changes conflict with existing patterns or architecture
- Identify risks: performance concerns, security implications, breaking changes

**Consolidate inconsistencies:**
- Merge agent findings with any additional conflicts discovered
- For each inconsistency: describe conflict, explain impact, suggest resolution if obvious

### Step 7: Estimate Scope

Load @references/scope-estimation-criteria.md for decision tree.

**Use agent results for sizing:**
- **File count**: From CODE_EXPLORATION_RESULT (primary affected files + dependencies)
- **Test impact**: From TEST_ANALYSIS_RESULT (number of test files affected)
- **Requirements complexity**: From REQUIREMENTS_DIFF_RESULT (number of gaps, questions, conflicts)

Determine if the change fits makato-change (small/medium) or needs makato-plan (large):

**Consider:**
- Number of affected files (1-5 = small, 6-15 = medium, 16+ = large)
- Architectural impact (isolated change = small, cross-cutting = medium, new subsystem = large)
- New components needed (none = small, helpers/utils = medium, new modules/services = large)
- Test impact (adjust existing = small, write new + adjust = medium, new test strategy = large)

**Decision:**
- Small/Medium → proceed with makato-change workflow
- Large → recommend makato-plan workflow, explain why (complexity, discovery needed, multiple teams involved)

### Step 8: Resolve Open Questions Interactively

**Extract open questions from Step 5 (consolidated from REQUIREMENTS_DIFF_RESULT).**

**If no open questions exist:**
- Skip to Step 9 (Generate Analysis Artifact)

**If open questions exist:**

Open questions include both blocking questions (must answer before design) and clarifying questions (improve design quality). All are worth asking since the user often knows answers even if they're not in the written requirements.

1. **Present questions to user one at a time:**

   For each question, use AskUserQuestion with:
   - **Question text**: The question from Step 5
   - **Header**: Brief context (e.g., "Edge Case", "Validation Rule", "Error Handling")
   - **Options**:
     - "I can answer this" (description: "Provide the answer")
     - "Needs clarification" (description: "Requires stakeholder input")

   Include in the question: why this matters (impact on design/implementation from Step 5)

2. **Capture user responses:**
   - For answered questions: record the answer from user's annotations/notes
   - For questions needing clarification: mark as unresolved for stakeholder follow-up

3. **Update consolidated question list:**
   - Resolved questions: move to "Resolved Questions" section with answers
   - Unresolved questions: remain in "Open Questions" section

**Example interaction:**

```
Header: "Validation Rule"

Question: Should email validation use RFC 5322 strict mode or allow common formats like "user+tag@domain.com"?

Why it matters: Affects validation logic complexity and whether users can use plus addressing for email filtering.

Options:
- "I can answer this" → [User provides note: "Allow common formats - we support plus addressing"]
- "Needs clarification"
```

**Update working memory:**
- RESOLVED_QUESTIONS: list of questions with answers
- OPEN_QUESTIONS: remaining questions needing stakeholder clarification

### Step 9: Generate Analysis Artifact

Load @templates/analysis.md for structure.

Write complete analysis to `specs/<issue-key>/analysis.md`:

**Required sections:**

**Pull data from agent results:**

1. **Overview** — GitHub Issues key, summary, issue type, current status (from Step 1)

2. **Requirements** — What the issue requests (from Step 1: GitHub Issues summary + description + ACs)

3. **Current Behavior** — How the feature works now (from CODE_EXPLORATION_RESULT: synthesis of file analysis, data flow, constraints)

4. **Requested Changes** — What should change (from Step 1 GitHub Issues + REQUIREMENTS_DIFF_RESULT interpretation)

5. **Comparison** — Side-by-side table (from REQUIREMENTS_DIFF_RESULT: current vs requested comparison)

6. **Resolved Questions** — Questions answered during Step 8 with answers (if any were resolved)

7. **Open Questions** — Remaining questions needing stakeholder clarification (from Step 8: unresolved questions, or from Step 5 if Step 8 was skipped)

8. **Inconsistencies** — Conflicts and risks (from Step 6: consolidated from REQUIREMENTS_DIFF_RESULT + supplemental findings)

9. **E2E Test Impact** — Affected scenarios with IDs (from TEST_ANALYSIS_RESULT: E2E scenarios found + REQUIREMENTS_DIFF_RESULT: test update needs)

10. **Scope Estimate** — Small/medium/large with justification (from Step 7: based on CODE_EXPLORATION_RESULT file count + TEST_ANALYSIS_RESULT test count + REQUIREMENTS_DIFF_RESULT complexity)

11. **Recommendation** — Next step:
   - If open questions remain after Step 8 → "Resolve N remaining questions before design"
   - If inconsistencies exist from Step 6 → "Resolve inconsistencies before design"
   - If all questions resolved AND no inconsistencies AND scope = small/medium → "Ready to proceed to design skill"
   - If scope = large → "Escalate to makato-plan workflow"

Make the artifact self-contained. The design skill will load this file without access to the GitHub Issues issue or conversation context.

### Step 10: Update GitHub Issues Issue

Load @references/jira-update-format.md for tone and structure.

Post analysis summary as a GitHub issue comment using `gh issue comment`.

**IMPORTANT**: Use GitHub Issues Wiki Markup format (NOT Markdown). Key syntax:
- Headers: `h2.`, `h3.` (NOT `##`, `###`)
- Bold: `*text*` (NOT `**text**`)
- Numbered lists: `#` at line start (NOT `1.`, `2.`)
- Bulleted lists: `*` at line start
- Monospace: `{{text}}` (NOT backticks)
- Horizontal rule: `----` (NOT `---`)

**Comment structure:**
```
h2. Change Request Analysis

*Scope*: [Small/Medium/Large]

h3. Summary
[2-3 sentence overview of what changes and complexity]

h3. Questions Resolved
[If any questions were answered in Step 8, list them here with answers:
 # Question: <question text>
   *Answer*: <user's answer>
OR if none resolved: "None — all questions require stakeholder input"]

h3. Open Questions
[Numbered list of remaining unresolved questions using # symbols, or "None — requirements are clear"]

h3. Inconsistencies
[List using * symbols, or "None identified"]

h3. E2E Test Scenarios Affected
[List scenarios with format:
  - For scenarios with IDs: "DCPAT-123: Scenario name"
  - For .feature files: "Scenario name (features/checkout.feature)"
  - For code-based tests: "Test description (e2e/checkout.spec.ts)"
OR if no E2E tests found: "None found — no E2E test coverage detected"]

h3. Next Steps
[Recommendation based on resolved vs remaining questions:
 - If all questions resolved: "Proceed to design"
 - If N questions remain: "Resolve N remaining questions, then proceed to design"
 - If scope is large: "Escalate to makato-plan"]

----
Full analysis: {{specs/<issue-key>/analysis.md}}
```

Add label `makato-change-analyzed` using `gh issue edit --add-label`.

### Step 11: Present Summary to User

Show a brief summary of findings:
- Scope estimate (small/medium/large)
- Number of questions resolved in Step 8 (if any)
- Number of open questions remaining (if any)
- Critical inconsistencies (if any)
- Recommendation for next step

If critical questions block progress:
- Highlight them prominently
- Suggest getting answers before proceeding to design

If analysis is complete and clear:
- Confirm scope fits makato-change
- Suggest proceeding to design skill next

Provide the path to the analysis artifact for detailed review:
```
specs/<issue-key>/analysis.md
```
