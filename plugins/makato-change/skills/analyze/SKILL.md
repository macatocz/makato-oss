---
name: analyze
description: >-
  Analyze change request requirements by comparing current behavior against
  requested changes, identify and address open questions and inconsistencies,
  update GitHub issue with refined requirements. Use for change requests,
  requirement analysis, behavior comparison, scope estimation.
version: "1.3.0"
argument-hint: "[ISSUE-KEY]"
allowed-tools: Bash(git *) Bash(gh *) Bash(test *) Bash(python3 *) Bash(plugins/makato-orchestrate/shared/workflow-state.sh *) Read Write
metadata:
  last_updated: "2026-08-05"
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

## Mindset

**Three non-obvious principles shape this skill's sequencing:**

**1. Scope is a gate, not a label.** The scope estimate at Step 7 is not metadata — it decides whether to continue this workflow or terminate and recommend makato-plan. If code-explorer returns 16+ primary affected files OR signals a new subsystem is required, short-circuit immediately: skip Steps 3.5 and 4, compute scope from code-explorer alone, and emit the Large recommendation. Running test-analyzer and requirements-diff-analyzer against a clearly-large scope wastes agent budget and produces artifacts that will not be used.

**2. Blocking vs clarifying questions are NOT the same triage axis as blocking vs deferrable.** A blocking question (agent `blocking: true`) is one whose answer changes WHICH files need to change or WHETHER a behavior is correct. A clarifying question only determines HOW to implement something already decided. In headless mode: block on blocking questions. In interactive mode: ask all questions — the user usually knows answers even if they're not in the written requirements. Never silently assume an answer to a blocking question in either mode.

**3. The artifact is the contract.** The design skill loads `analysis.md` cold, with no conversation context. Every assumption, answer, and piece of prior knowledge must be in the artifact. If it is not in `analysis.md`, the design lane will miss it.

---

## References

**Do NOT load any reference before its indicated step** — loading eagerly inflates context and may bias analysis before agent results are available.

| Reference | Load When |
|-----------|-----------|
| `@references/exploration-strategy.md` | **MANDATORY at Step 3** — before dispatching code-explorer |
| `@references/requirements-comparison-pattern.md` | **MANDATORY at Step 4** — before dispatching requirements-diff-analyzer |
| `@references/question-identification-guide.md` | At Step 5 — only when supplementing agent questions |
| `@references/scope-estimation-criteria.md` | **MANDATORY at Step 7** — before scope decision |
| `@templates/analysis.md` | At Step 9 — before writing the artifact |
| `@references/jira-update-format.md` | At Step 10 — tone and section structure only (see note in Step 10) |

---

## Workflow

### Step 1: Fetch Requirements from GitHub Issues

GitHub Issues issue key is required (passed as argument or asked from user).

Emit a session-start entry to the audit log immediately after the issue key is resolved:

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"session","status":"start","data":{"skill":"analyze","key":"<KEY>","issue":<N>}}'
```

Use the `issue_read` MCP tool with `method: get` to fetch the issue. Do NOT use the `gh issue view` CLI command for this structured fetch — the MCP tool returns typed JSON that agents can consume directly without shell parsing.

```json
{
  "method": "get",
  "owner": "<org>",
  "repo": "<repo>",
  "issue_number": <number>
}
```

Response handling:
- Validate issue exists and type is Story or Activity
- Extract: summary, description, acceptance criteria, comments, current status
- If issue type is not Story or Activity, inform user and exit
- If MCP tool fails, report the error — do not fall back to CLI

### Step 2: Establish Artifact Location

Create the artifact directory for this change request:
```
specs/<issue-key>/
```

This follows the makato-plan pattern of project-scoped work directories. All analysis artifacts for this change request will live here. The design and execute skills will load artifacts from this location.

**Spec folder shapes:** When the issue was seeded via `seed-issue` (new-work path), the folder may instead be `specs/<N>-<slug>/` where `<N>` is the issue number and `<slug>` is the normalized title (e.g. `specs/233-fix-auth-bug/`). Both shapes are valid:
- `specs/<issue-key>/` — direct creation by analyze (this step)
- `specs/<issue-number>-<normalized-title>/` — canonical shape produced by `seed-issue`

When loading artifacts in later steps, check both shapes and use whichever exists.

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

**Headless branch (MAKATO_HEADLESS=1):**

Check if `REPO_ROOT` is present in the dispatch context bundle:

- `REPO_ROOT` present → auto-write `repositories.yml` using that path:
  ```yaml
  version: "1.0"
  affected:
    - name: <basename of REPO_ROOT>
      role: primary
      path: <basename of REPO_ROOT>
      description: "<GitHub Issues summary one-line>"
  ```
  Set `REPO_ROOT` and `REPO_NAME` from the bundle value. Continue to Step 3.

- `REPO_ROOT` absent → HALT-CH-001. Write to `specs/<issue-key>/deferred-questions.md`:
  ```
  ## HALT-CH-001: Repository not discovered

  The `repositories.yml` file does not exist and `REPO_ROOT` was not provided
  in the dispatch context bundle.

  To resume: re-dispatch with `REPO_ROOT=/absolute/path/to/repo` in the bundle,
  or create `specs/<issue-key>/repositories.yml` manually before re-running.
  ```
  Return R1 `status:"failure"`, `errors:["HALT-CH-001: REPO_ROOT required in headless mode"]`.

**Interactive branch (default):**

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
- REPO_ROOT: `<absolute-path>` — always use `git rev-parse --show-toplevel` inside the target repo, never pwd
- REPO_NAME: `<repo-name>`

### Step 2.7: Recall Prior Lessons

After REPO_ROOT is resolved, recall any prior lessons recorded for this repository so they
can inform analysis and be forwarded to the execute lane.

```bash
REPO_REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
PRIOR_LESSONS="[]"
if [[ -n "$REPO_REMOTE" ]]; then
  _recalled="$(plugins/makato-orchestrate/shared/workflow-state.sh recall-lessons "$REPO_REMOTE" 3 2>/dev/null || echo "[]")"
  # Validate minimal JSON-array shape; fall back to [] on malformed output.
  if echo "$_recalled" | python3 -c "import sys,json; v=json.load(sys.stdin); assert isinstance(v,list)" 2>/dev/null; then
    PRIOR_LESSONS="$_recalled"
  fi
fi
```

**MUST NOT block** — on any failure (script absent, git error, malformed JSON) set
`PRIOR_LESSONS=[]` and continue without error. The recall is advisory only.

**Store:** `PRIOR_LESSONS` (JSON array, may be `[]`).

### Step 3: Discover Affected Code and Current Behavior

**MANDATORY: Load `@references/exploration-strategy.md` now** — it contains discovery patterns for code files, test files, E2E frameworks, and project specs that the code-explorer agent applies. Do NOT load it before this step.

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

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"code-explorer","status":"ok","data":{"skill":"analyze","agent":"code-explorer"}}'
```

**Early large-scope shortcut:** If CODE_EXPLORATION_RESULT shows **16+ primary affected files** OR explicitly signals a new subsystem is required, skip Steps 3.5 and 4 entirely and jump to Step 7. A change this large should not consume test-analyzer and requirements-diff-analyzer budget — the scope verdict is already clear from code exploration.

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

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"test-analyzer","status":"ok","data":{"skill":"analyze","agent":"test-analyzer"}}'
```

**Extract for analysis:**
- Existing E2E test scenarios (IDs and names)
- What user workflows are currently validated
- What test updates will be needed

### Step 4: Generate Requirements Comparison

**MANDATORY: Load `@references/requirements-comparison-pattern.md` now** — it defines the three-column comparison table format, gap analysis structure, and ambiguity annotation conventions. Do NOT load it before code-explorer results are available; the pattern requires knowing actual current behavior before the diff is meaningful.

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

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"requirements-diff-analyzer","status":"ok","data":{"skill":"analyze","agent":"requirements-diff-analyzer"}}'
```

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

**MANDATORY: Load `@references/scope-estimation-criteria.md` now** — it contains the full 6-dimension decision tree (file count, architectural impact, new components, test impact, uncertainty, coordination) with thresholds and edge-case guidance for borderline medium/large calls.

**Use agent results for sizing:**
- **File count**: From CODE_EXPLORATION_RESULT (primary affected files + dependencies)
- **Test impact**: From TEST_ANALYSIS_RESULT (number of test files affected)
- **Requirements complexity**: From REQUIREMENTS_DIFF_RESULT (number of gaps, questions, conflicts)

**Decision:**
- Small/Medium (≤15 files, isolated or shallow cross-cutting) → proceed with makato-change workflow
- Large (16+ files, new subsystem, or deep architectural impact) → recommend makato-plan workflow, explain why

### Step 8: Resolve Open Questions Interactively

**Extract open questions from Step 5 (consolidated from REQUIREMENTS_DIFF_RESULT).**

**If no open questions exist:**
- Skip to Step 9 (Generate Analysis Artifact)

**If open questions exist:**

**Headless branch (MAKATO_HEADLESS=1):**

Classify each question using the `requirements-diff-analyzer`'s `blocking` flag:

- **Non-critical questions** (`blocking: false`): Write them to `specs/<issue-key>/deferred-questions.md` under a `## Deferred Questions` heading with the question text and why it matters. Do NOT ask. Continue to Step 9.
- **Critical blocking questions** (`blocking: true`): HALT-CH-002. Append each critical question to `specs/<issue-key>/deferred-questions.md` under `## Critical Blocking Questions (HALT-CH-002)`. Return R1 `status:"failure"`, `errors:["HALT-CH-002: Critical questions require human input before design"]`, with `data.blocking_questions` listing the question texts.

**Interactive branch (default):**

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

11. **Prior Lessons** — Emit the recalled lessons from Step 2.7 as a fenced block at the end of `analysis.md` so the execute lane can read it back without re-running recall:

    ```
    <!-- prior_lessons: <PRIOR_LESSONS JSON array, verbatim> -->
    ```

    When `PRIOR_LESSONS` is `[]`, write `<!-- prior_lessons: [] -->` as a stable sentinel
    so the execute lane does not need to special-case a missing marker.

12. **Recommendation** — Next step:
   - If open questions remain after Step 8 → "Resolve N remaining questions before design"
   - If inconsistencies exist from Step 6 → "Resolve inconsistencies before design"
   - If all questions resolved AND no inconsistencies AND scope = small/medium → "Ready to proceed to design skill"
   - If scope = large → "Escalate to makato-plan workflow"

Make the artifact self-contained. The design skill will load this file without access to the GitHub Issues issue or conversation context.

### Step 10: Update GitHub Issues Issue

Load @references/jira-update-format.md for **tone and section structure guidance only**. Ignore its markup syntax examples — that file contains Jira Wiki Markup (`h2.`, `h3.`, `*bold*`, `# lists`), which renders as literal text in GitHub Issues. Use standard GitHub Markdown as shown below.

Post analysis summary as a GitHub issue comment using `gh issue comment`.

**IMPORTANT**: Use standard GitHub Markdown — NOT Jira Wiki Markup. GitHub renders `##` as headers, `**text**` as bold, and `1.`/`2.` as numbered lists. Jira-style syntax appears as unformatted noise to reviewers.

**Comment structure:**
```
## Change Request Analysis

**Scope**: [Small/Medium/Large]

### Summary
[2-3 sentence overview of what changes and complexity]

### Questions Resolved
[If any questions were answered in Step 8:
 1. Question: <question text>
    **Answer**: <user's answer>
OR if none resolved: "None — all questions require stakeholder input"]

### Open Questions
[Numbered list of remaining unresolved questions, or "None — requirements are clear"]

### Inconsistencies
[Bulleted list, or "None identified"]

### E2E Test Scenarios Affected
[List scenarios with format:
  - For scenarios with IDs: "DCPAT-123: Scenario name"
  - For .feature files: "Scenario name (features/checkout.feature)"
  - For code-based tests: "Test description (e2e/checkout.spec.ts)"
OR if no E2E tests found: "None found — no E2E test coverage detected"]

### Next Steps
[Recommendation based on resolved vs remaining questions:
 - If all questions resolved: "Proceed to design"
 - If N questions remain: "Resolve N remaining questions, then proceed to design"
 - If scope is large: "Escalate to makato-plan"]

---
Full analysis: `specs/<issue-key>/analysis.md`
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

Emit a session-end entry:

```bash
plugins/makato-build/shared/build-log.sh "<KEY>" \
  '{"step":"session","status":"ok","data":{"skill":"analyze","key":"<KEY>","issue":<N>}}'
```

---

## Anti-patterns

**NEVER route a bug/defect through this skill.** Bugs have a gap between expected and actual behavior for a spec that is already correct — not a "current behavior vs requested behavior" comparison. Running the 3-agent pipeline on a defect produces a misleading `analysis.md` with a fabricated "requested change" section, and the design skill will design around the wrong problem. Route bugs to `makato-build` directly.

**NEVER guess or derive REPO_ROOT from CWD in headless mode when it is absent from the dispatch bundle.** The headless agent's CWD is the makato repo, not the target repo. Calling `git rev-parse --show-toplevel` without an explicit `-C` path silently points all three discovery agents at the makato codebase instead of the target service — every file reference in the resulting `analysis.md` will be wrong. Emit HALT-CH-001 and stop.

**NEVER silently widen scope past the 15-file cap to keep a change in makato-change.** If Step 3 or Step 7 reveals a large change, emit the Large verdict and recommend makato-plan — do not mentally split or downgrade the scope. The AGENTS.md hard constraint exists to protect the execute lane from unbounded PRs. Silent expansion produces a `design.md` that `change-implementer` cannot safely execute, and the failure surfaces mid-implementation where recovery is expensive.

**NEVER post Jira Wiki Markup (`h2.`, `h3.`, `*bold*`, `#` for lists, `{{code}}`) in a GitHub Issues comment.** That syntax renders as literal text in GitHub Issues — reviewers see raw markup noise instead of structured content. Use `##`, `**bold**`, `1.`/`-` and backticks. (The `jira-update-format.md` reference uses Jira syntax in its examples; override those examples with the Markdown structure in Step 10.)

**NEVER load `references/exploration-strategy.md` or `references/requirements-comparison-pattern.md` at skill start or before their designated steps.** Eager loading inflates the context window before agent outputs are available, and the exploration-strategy guidance is meaningless without the feature keywords and codebase context produced in Steps 1–2.

**NEVER write `analysis.md` without the `<!-- prior_lessons: ... -->` sentinel**, even when `PRIOR_LESSONS` is `[]`. The execute lane reads this marker unconditionally to avoid re-running recall. A missing sentinel forces execute to re-dispatch the recall script mid-phase, potentially reading stale lessons if the lesson store was updated between analyze and execute.
