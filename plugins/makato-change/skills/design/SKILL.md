---
name: design
description: >-
  Design technical approach for a change request: discover affected code,
  plan solution, produce design.md + spec-delta.md, and update GitHub issue.
  Use when analysis.md exists and requirements are clear. Triggers: technical
  design, solution planning, code discovery, implementation approach, design CR.
version: "1.5.0"
argument-hint: "[ISSUE-KEY]"
metadata:
  authors: ["makato-change"]
  last_updated: "2026-08-05"
allowed-tools: ["Bash", "Read", "Write", "Edit", "gh"]
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

## Anti-Patterns

These failures are non-obvious and only surface mid-execution. Read before starting.

**NEVER expand the file set beyond what analyze identified** without opening a new change request.
WHY: design.md becomes the implementation contract for execute. Any file added here that
analyze never scoped bypasses the 15-file cap check and the scope guard in AGENTS.md.
The execute skill trusts design.md as a complete, reviewed boundary — unexpected files
break `change-implementer`'s isolation model.

**NEVER post Jira Wiki Markup to a GitHub Issues comment.**
WHY: GitHub Issues renders Markdown, not Jira markup. `h2.`, `h3.`, `{{text}}`, `*bold*`,
and `#` list prefix will appear as raw literal characters in the rendered comment. Every
reviewer will see visually broken output. Use `##`/`###`, `**bold**`, backticks, and
`1.`/`2.` lists.

**NEVER skip the HALT-CH-003 audit log in autonomous mode.**
WHY: The PO-agent outer loop audits `log-bypass.sh` entries to verify that design approval
was intentional rather than silently dropped. A missing entry causes the loop's reconcile
phase to flag the session as incomplete, which can re-queue the item and duplicate work.

**NEVER emit an empty `## Recommended Skills` section in design.md.**
WHY: `execute` Step 2.1 reads this section to forward skills to `change-implementer`.
An empty section causes the implementer to skip skill injection silently — no error, no
warning — leaving it without context for framework-specific code. The rule: if
`RECOMMENDED_SKILLS_RESULT` is empty, omit the section entirely.

**NEVER resolve REPO_ROOT using `pwd` or relative paths.**
WHY: The skill often runs inside a git worktree whose CWD does not match the target
repository. `pwd` returns the makato checkout, not the project under change. Always derive
REPO_ROOT via the path-resolution algorithm in Step 1.5, which tries sibling-of-CWD and
git-basename strategies before failing with a clear error message.

**NEVER write spec-delta.md as a section inside design.md.**
WHY: `execute` reads these two artifacts separately. Merging them breaks the execute
skill's artifact loading contract and loses the structured ADDED/MODIFIED/REMOVED/RENAMED
taxonomy that downstream tooling (e.g., acceptance-test generation) depends on.

---

## Workflow

### Step 1: Load Analysis Artifact

GitHub Issues key is required (from argument or ask user).

Read the analysis artifact at `specs/<issue-key>/analysis.md`:
- Validate artifact exists (if not, prompt user to run analyze skill first)
- Extract: requirements summary, current behavior, requested changes, scope estimate, open questions
- Confirm scope is small/medium (not escalated to makato-plan)

**Optional: Fetch latest from GitHub Issues** (if user wants to check for updates):
- Use `gh issue view <issue-number>` to get current status
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

Determine base search directory using a stable root anchor — never `pwd`:
```bash
MAKATO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
SPECS_ROOT="${MAKATO_ROOT}/specs"
```

Try multiple search strategies:

1. **Sibling of MAKATO_ROOT**: `${MAKATO_ROOT}/../${REPO_NAME}`
2. **Same parent, one level deeper**: `${MAKATO_ROOT}/../*/${REPO_NAME}`
3. **Current working directory**: If `git rev-parse --show-toplevel` basename matches `$REPO_NAME`
4. **specs/ parent itself**: If `$SPECS_ROOT/..` basename matches `$REPO_NAME`

Set `REPO_ROOT` to first matching location.

**Validate resolved path:**
```bash
test -d "$REPO_ROOT/.git"
```

**If validation fails:**
- Inform user with specific failure: "Repository not found at `<REPO_ROOT>`" or "Invalid repositories.yml structure"
- Show all searched locations
- Suggest: "Update `specs/<issue-key>/repositories.yml` manually or re-run analyze skill"
- Exit gracefully

**Store for subsequent steps:**
- REPO_ROOT: `<absolute-path>`
- REPO_NAME: `<repo-name>`

### Step 2: Verify Prerequisites

**MANDATORY: Load `@shared/branch-guard.md`** and run the branch check before any code-explorer dispatch. Record the current branch in working memory as `CURRENT_BRANCH` for reuse by later steps.

Check if critical open questions from the analysis are resolved:
- If the analysis flagged "Critical (Block Design)" questions that are still unanswered, inform the user
- Explain why design cannot proceed without answers
- Suggest getting stakeholder input first, then re-running this skill

If questions are resolved or there were none, proceed.

### Step 2.5: Check code-exploration.md Cache Staleness

Before dispatching the code-explorer agent in Step 4 Option B, gate the dispatch on a
3-way staleness check against the `code-exploration.md` stub written by the analyze skill.

```bash
CACHE_FILE="specs/<issue-key>/code-exploration.md"
CURRENT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
```

**Read the cache file** using `Read` on `$CACHE_FILE`. Extract frontmatter fields
`git_sha`, `timestamp`, and `status`. If the file cannot be parsed as valid YAML frontmatter,
treat it as absent.

**Route:**

| Condition | Action |
|-----------|--------|
| `$CACHE_FILE` absent, unreadable, or frontmatter parse error | **Auto re-scan** — set `CACHE_VERDICT=miss`. Proceed to Step 4 Option B (code-explorer dispatch). |
| `timestamp` age ≥ 24 h (compare against current UTC time) | **Auto re-scan** — set `CACHE_VERDICT=stale`. Proceed to Step 4 Option B. |
| `git_sha` matches `$CURRENT_SHA` AND `status != "pending"` | **Cache hit** — set `CACHE_VERDICT=hit`. Log `cache_hit: true` to `build.jsonl` (see below), load `code-exploration.md` body as `CODE_EXPLORATION_RESULT`, and **skip code-explorer dispatch** in Step 4 Option B. Jump directly to Step 4.5. |
| `git_sha` differs from `$CURRENT_SHA` AND timestamp age < 24 h | **Prompt user** (headless: auto re-scan) — see below. |

**Prompt branch (interactive only, SHA mismatch + age < 24 h):**

Use AskUserQuestion:

**Question:** "The cached code exploration is from a different commit (`<cached_sha>` vs current `<current_sha>`), but it is less than 24 hours old. Re-scan or use cached?"

**Options:**
1. **Re-scan** — dispatch code-explorer against the current commit
2. **Use cached** — skip code-explorer; load the cached body as-is

Headless (`MAKATO_HEADLESS=1`): auto-select **Re-scan** and log a bypass:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" cache-staleness re-scan cli_flag
```

**On cache hit — log entry:**
```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"cache-check","status":"ok","data":{"skill":"design","cache_hit":true,"git_sha":"<CACHED_SHA>"}}'
```

**Store:** `CACHE_VERDICT` (`hit` | `miss` | `stale`) for use in Step 4.

### Step 3: Ask User for Code Discovery Preference

**MANDATORY: Load @references/code-discovery-strategies.md** to understand the two approaches before presenting options.

**Headless branch (MAKATO_HEADLESS=1):**

Auto-select **Guided mode** (Option A). Log an `autonomous_bypass` entry:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" discovery-preference guided cli_flag
```
Proceed to Step 4 Option A. Derive affected files from the analysis artifact's "Affected Files"
section and CODE_EXPLORATION_RESULT. If neither source yields a list, dispatch the
code-explorer agent (Option B) without prompting.

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

**After code-explorer returns** (cache miss or forced re-scan), overwrite `specs/<issue-key>/code-exploration.md` with the updated SHA, timestamp, and full agent output:

```bash
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Write `specs/<issue-key>/code-exploration.md`:

```
---
git_sha: <GIT_SHA>
timestamp: <TIMESTAMP>
status: fresh
---

<full CODE_EXPLORATION_RESULT output>
```

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"code-exploration-write","status":"ok","data":{"skill":"design","git_sha":"<GIT_SHA>","cache_verdict":"<CACHE_VERDICT>"}}'
```

**Extract for design:**
- List of files to modify (with descriptions)
- Existing patterns to follow (naming, error handling, testing)
- Dependencies to consider

### Step 4.5: Resolve Recommended Skills

After the affected-file set is known from Step 4, resolve the technology skills that apply
to those files using the same resolver `knowledge-scout` Step 0e uses. This closes the
asymmetry with `makato-build`: change requests now get glob-based technology-skill routing
automatically, not only when a human hand-writes `recommended_skills[]` in design.md.

**Resolution:**

1. Resolve the makato checkout root — the directory whose `plugins/` subtree contains the
   installed plugins. When the skill is running inside a git worktree the root is:
   ```bash
   MAKATO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
   ```
   Fallback: `$(git rev-parse --show-toplevel)` if the common-dir strategy fails.

2. Call the inject-skills resolver on the **affected-file paths from Step 4** (project-relative
   paths, same form `knowledge-scout` passes):
   ```python
   import sys
   sys.path.insert(0, f"{MAKATO_ROOT}/plugins/makato-build/shared")
   from inject_skills import resolve_skills_for_repo
   recommended_skills, warnings = resolve_skills_for_repo(AFFECTED_FILES, MAKATO_ROOT)
   ```

3. Capture the ordered, deduplicated `recommended_skills` list. Store it in working memory
   as `RECOMMENDED_SKILLS_RESULT`.

4. Log any `missing-skills` warnings at `warn` level — a referenced-but-uninstalled skill
   is expected and non-fatal (D18).

**Best-effort contract:** a resolver failure (import error, `BundleResolutionError`, any
exception) logs a single warning line and sets `RECOMMENDED_SKILLS_RESULT = []`. This step
NEVER blocks the design phase — it mirrors the warning-not-fatal contract `knowledge-scout`
uses. An empty result omits the `## Recommended Skills` section from design.md (Step 9).

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

Dispatch the `gherkin-scenario-elaborator` agent with:

```
ISSUE_KEY: <issue-key>
TERSE_SCENARIOS: <titles / partial outlines from CODE_EXPLORATION_RESULT and TEST_ANALYSIS_RESULT>
DOMAIN_CONTEXT: <brief description of the feature from analysis.md>
```

Write the agent's `# Elaborated Scenarios` output directly into `specs/<issue-key>/test-scenarios.md`,
replacing the inline manual-writing step.

**Fallback:** If the `gherkin-scenario-elaborator` agent is unavailable or returns an error,
fall back to writing the scenarios manually using the following template:

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

Read each file identified in Step 4. For each file, focus on:

- **Entry points and call sites** — what calls this function/component and with what arguments
- **Existing patterns** — naming, error handling, validation style used in this module
- **Test coverage shape** — unit vs. integration, mock boundaries, fixture patterns
- **Inbound dependencies** — who imports this; a signature change here breaks those callers

Stop reading when you can answer: "What is the minimal change that satisfies the requirement
without breaking caller contracts?" Do not read every line; focus on interfaces and patterns.

### Step 7: Design Solution Approach

**MANDATORY: Load @references/solution-design-pattern.md** for structure guidance before writing.

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

**Determine test scope** — this is a non-obvious decision with project-wide impact:

| Signal | → Test Scope |
|--------|-------------|
| Change isolated to one module, no shared utility touched | Module-only |
| Shared utility, base class, or common library modified | Full suite |
| API contract or data model changes (used by multiple modules) | Full suite |
| Config, environment setup, or build process touched | Full suite |
| Unsure about cross-module impact | Full suite (safe default) |

The **only safe default is full suite** when the impact boundary is unclear. Module-only is an
optimization, not a shortcut; choose it only when you can name the exact module boundary.

Document the test scope decision and justification in the design artifact.

### Step 8: Plan Implementation Steps

**MANDATORY: Load @references/implementation-planning-guide.md** for step breakdown guidance before writing.

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

**Scope escalation guard:** If the design is revealing more files or subsystems than the
analysis estimated, stop and evaluate. A design that touches 13+ files or requires a new
module that analyze never mentioned is a signal to pause and escalate to makato-plan before
proceeding. Expanding scope silently is a contract violation (see Anti-Patterns).

### Step 9: Generate Design Artifact

**MANDATORY: Load @templates/design.md** for structure before writing.

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
9. **Recommended Skills** *(conditional)* — Emit this section only when `RECOMMENDED_SKILLS_RESULT`
   from Step 4.5 is non-empty. When the list is empty, **omit the section entirely** — do NOT
   write an empty array or placeholder. This is what `execute` Step 2.1 reads and forwards to
   `change-implementer` as `RECOMMENDED_SKILLS`.

   Format (one skill per line, matching the `plugin:skill-id` or bare `skill-id` convention
   `execute` Step 2.2 and `change-implementer` expect):

   ```markdown
   ## Recommended Skills

   - <skill-id-1>
   - <skill-id-2>
   ```

**Note:** `spec-delta.md` is NOT a section inside design.md. It is a separate companion
artifact emitted in Step 9.5 immediately after this step.

Link back to the analysis artifact for traceability:
> Analysis: `specs/<issue-key>/analysis.md`

Make the artifact self-contained so the execute skill can implement from this design without needing conversation context.

### Step 9.5: Generate Spec-Delta Artifact

**MANDATORY: Load @references/spec-delta-template.md** for the template structure.

Walk the solution approach documented in Step 7 and classify each requirement change as one of:
- **ADDED** — a new requirement not present in the current implementation
- **MODIFIED** — an existing requirement whose behavior changes
- **REMOVED** — an existing requirement that must be retired
- **RENAMED** — a requirement whose name changes but whose behavior is preserved

Write `specs/<issue-key>/spec-delta.md` using the template structure: each change becomes a
`### <Requirement Name>` entry under the correct section heading (`## ADDED Requirements`,
`## MODIFIED Requirements`, `## REMOVED Requirements`, or `## RENAMED Requirements`) with a
**SHALL**: statement derived from the requested behavior. Include an optional **Scenario**:
block for behavioral changes where acceptance criteria can be expressed in Given/When/Then form.

**Headless branch (MAKATO_HEADLESS=1):**

Auto-generate spec-delta.md from design artifact content without prompting. Log an `autonomous_bypass` entry:
```bash
shared/log-bypass.sh makato-change:design "<ISSUE_KEY>" spec-delta-generation generate cli_flag
```
Proceed directly to Step 10.

**Interactive branch (default):**

After writing the file, inform the user:
> "`specs/<issue-key>/spec-delta.md` written — review and edit the requirement delta before proceeding."

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

Set `POST_TO_GITHUB = (MAKATO_CHANGE_POST_DESIGN == "1")`. Proceed to Step 11 conditionally.

**Interactive branch (default):**

Use `AskUserQuestion` to get approval:

**Question:** "Does this design look good?"

**Options:**
1. **Approve and post to GitHub Issues** — Accept design and update the GitHub issue with design summary
2. **Approve but don't post to GitHub Issues** — Accept design but skip GitHub issue update (useful for drafts or offline work)
3. **Request changes** — Provide feedback to revise the design

If user requests changes:
- Address their feedback
- Regenerate the design artifact
- Present the updated summary again with the same approval options

Store the user's choice: `POST_TO_GITHUB` (boolean)

### Step 11: Update GitHub Issue (Conditional)

**Only proceed if `POST_TO_GITHUB` is true (user selected "Approve and post to GitHub Issues" in Step 10).**

**MANDATORY: Load @references/github-design-update-format.md** for comment structure and tone.

Post the solution approach as a GitHub issue comment using `gh issue comment`:

**IMPORTANT**: Use **GitHub Markdown** (NOT Jira Wiki Markup). Key syntax:
- Headers: `##`, `###` (NOT `h2.`, `h3.`)
- Bold: `**text**` (NOT `*text*`)
- Numbered lists: `1.`, `2.`, `3.` (NOT `#` at line start)
- Bulleted lists: `-` or `*`
- Inline code/monospace: `` `text` `` (NOT `{{text}}`)
- Horizontal rule: `---` (NOT `----`)

**Comment template:**
```markdown
## Technical Design

**Files Affected:** <count>

### Solution Approach
<2-3 sentence summary of how changes will be implemented>

### Key Changes
- <change 1>
- <change 2>
- <change 3>

### Implementation Steps
1. <step 1>
2. <step 2>
3. <step 3>

### Risks
<bulleted list if any, or "None identified">

**Estimated time:** <minutes/hours>

---
Full design: `specs/<issue-key>/design.md`
```

Add label `makato-change-designed` using `gh issue edit --add-label`.

**Transition status if needed:**
- Get current issue status using `gh issue view --json state`
- If status is "New", transition to "Open":
  - Execute using `gh issue edit --state open`
  - If transition fails (not available), continue without error (workflow may differ by project)

### Step 12: Present Summary to User

Confirm completion:
> "Design complete and posted to GitHub Issues.
>
> **Design artifact:** `specs/<issue-key>/design.md`
>
> **Next step:** Proceed to execute skill to implement the changes."

Provide the path to the design artifact for reference.
