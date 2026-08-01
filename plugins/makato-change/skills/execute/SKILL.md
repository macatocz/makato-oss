---
name: execute
description: Implement change request by modifying code, updating tests, running verification, and creating pull request with GitHub issue link. Use for implementation, coding changes, test updates, PR creation.
version: "1.4.0"
argument-hint: "[ISSUE-KEY]"
---

# Execute Change Request Implementation

Implement the designed change request by modifying code, creating new components, updating tests, verifying the implementation, and creating a pull request linked to GitHub Issues.

## When to Use

- Design is complete (design skill has run and produced `specs/<issue-key>/design.md`)
- Design has been approved by user
- Ready to write code and implement the solution
- Want to deliver a verified PR with working implementation

## When NOT to Use

- Design hasn't been done yet (run design skill first)
- Design is not approved or needs revision
- Requirements or design are unclear
- Want to review or address PR feedback (use resolve-review skill)

---

## Workflow

### Step 1: Load Design Artifact

GitHub Issues key is required (from argument or ask user).

Read the design artifact at `specs/<issue-key>/design.md`:
- Validate artifact exists (if not, prompt user to run design skill first)
- Extract: affected files, solution approach, implementation plan, test strategy, test scope, risks
- Review implementation steps to understand the execution sequence
- Note the test scope decision (module-only vs full suite)

If `specs/<issue-key>/spec-delta.md` exists, read it and store its full content as
`SPEC_DELTA_CONTEXT`; otherwise `SPEC_DELTA_CONTEXT` is absent (no error, no warning —
graceful degradation preserves byte-for-byte legacy behaviour).

### Step 1.5: Establish Repository Context

Read `specs/<issue-key>/repositories.yml`.

**If repositories.yml does NOT exist:**
- Error: "Repository metadata not found. Run analyze skill first to discover target repository."
- Exit gracefully

**Load and validate** (per @shared/repositories-yml-schema.md):

Extract:
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

**Validate repository access:**
```bash
test -d "$REPO_ROOT/.git"
```

**If validation fails:**
- Show searched locations
- Suggest standard layouts (see @shared/path-resolution.md for error message template)
- Exit gracefully

**Store repository context for all subsequent steps:**
- REPO_ROOT: <absolute-path>
- REPO_NAME: <repo-name>

**IMPORTANT: All file operations from Step 2 onwards must use absolute paths constructed as `<REPO_ROOT>/<relative-path-from-design>`.**

**IMPORTANT: All git operations must use `git -C <REPO_ROOT>` to operate on the target repository regardless of current working directory.**

### Step 1.6: Transition to In Progress on project board

Mark the issue as In Progress on the GitHub Projects board immediately — before any code is written — so the autonomous loop does not pick up the same issue concurrently.

**Determine `ISSUE_NUMBER`** from the `ISSUE_KEY` argument (e.g., `specs/<ISSUE_KEY>/repositories.yml` or simply parse the numeric part of the key if it is a plain integer).

**Read project config** from `.claude/config.json` at the repo root. Extract from the `github_project` block: `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number`. If the block is absent or any field is missing, skip this step with a WARN and continue (best-effort — never block execution).

**Otherwise:**

1. Find the board item and its current status:
   ```bash
   ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
     --owner "$OWNER" --format json --limit 9999 \
     --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
     | head -1)"
   ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
   CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
   ```
   If `ITEM_ID` is empty: log `execute: WARN — issue #$ISSUE_NUMBER not found on board; skipping In Progress update` and continue.

2. Set Status = In Progress (only if not already set):
   If `CUR_STATUS` is already `"In progress"`: log `execute: #$ISSUE_NUMBER is already In Progress — skipping` and continue.
   Otherwise:
   ```bash
   GH_HOST="$HOST" gh project item-edit \
     --id "$ITEM_ID" \
     --project-id "$PROJECT_NODE_ID" \
     --field-id "$STATUS_FIELD_ID" \
     --single-select-option-id "$IN_PROGRESS_OPTION_ID"
   ```
   On success: log `execute: marked #$ISSUE_NUMBER as In Progress on project board`.
   On failure: log `execute: WARN — could not set In Progress on board; continuing` (best-effort).

### Step 2: Implement Changes Following Design

The file modifications are performed by a write-capable **`change-implementer`** subagent, not
inline in this skill's context. This keeps the write phase off the main `execute` context —
which already carries `analyze` + `design` + Step 1.5 repository discovery + every file read
so far — and gives technology skills (including the mandatory `context7`) a natural injection
point, mirroring `makato-build`'s isolated `coder`. See `agents/change-implementer.md`.

**2.1: Resolve recommended skills (optional).** If the design artifact carries a
`## Recommended Skills` section, parse the bullet list and capture it as
`recommended_skills[]` to forward below. This field is populated by `design` Step 4.5,
which calls the inject-skills resolver on the affected-file set — the same resolver
`knowledge-scout` Step 0e uses — and writes the result into design.md automatically.
For change requests designed before this feature shipped, or for runs where the
resolver returned no results, the section will be absent: omit the field entirely in
that case — do NOT pass an empty array. Independently of this field, the
`change-implementer` agent always performs the mandatory `context7` lookup for any library the
change touches (routing for source files is provided cross-plugin by makato-doc's
`doc-code-docs` bundle; the agent prompt enforces it at the write phase regardless of routing).

**2.2: Dispatch `change-implementer` agent** to apply the changes.

**Before dispatching**, extract `PRIOR_LESSONS` from `specs/<issue-key>/analysis.md` if it
was persisted there by the `analyze` skill (Step 2.7). Look for the sentinel comment:

```
<!-- prior_lessons: <JSON array> -->
```

If the marker is present and the JSON array is non-empty, include it in the dispatch bundle
below. If absent, empty `[]`, or malformed — omit the field entirely.

**Agent input:**
```
REPO_ROOT: <from Step 1.5: repositories.yml primary repo path>
REPO_NAME: <from Step 1.5>
ISSUE_KEY: <issue-key>
DESIGN_PATH: <specs/<issue-key>/design.md>
ANALYSIS_PATH: <specs/<issue-key>/analysis.md>   # omit if not present
RECOMMENDED_SKILLS: <array from 2.1>              # omit when absent
PRIOR_LESSONS: <array from analysis.md sentinel>  # omit when absent or []
SPEC_DELTA_CONTEXT: <full content of spec-delta.md from Step 1> # omit when absent
```

When `SPEC_DELTA_CONTEXT` is present, the implementer MUST satisfy each SHALL statement in
`## MODIFIED Requirements` — treat these as binding correctness constraints on par with
`DESIGN_ARTIFACT`.

The agent loads `@references/implementation-guidelines.md`-equivalent best practices, invokes
any recommended skills and the mandatory `context7` lookup, then applies every file
modification and creation the design specifies (absolute paths, existing conventions, no
scope creep) in its own context.

**Agent will return:** a summary with `status: implemented | blocked`, the list of files
changed and created (each with a one-line rationale), skills/context7 consulted, and any
notes or deviations.

**Handle results:**
- If `status = implemented`: record the changed/created file list (needed for Step 5.5's
  `CHANGED_FILES` and the commit in Step 7), then continue to Step 3.
- If `status = blocked` with a `design_gap`: the design is incomplete or incorrect. Do NOT
  guess — surface the gap to the user (interactive) or emit the blocker (autonomous), since
  this context holds the full requirements needed to decide how to proceed.

**Key principles (enforced by the agent, restated here for the contract):**
- Don't add features beyond what the design specifies
- Don't refactor unrelated code
- Don't add abstractions not called for in the design
- Follow the design's solution approach, don't improvise
- If the design is incomplete or incorrect, the agent returns `blocked` rather than improvising

### Step 3: Update and Generate Tests

Load @references/test-generation-guide.md for testing patterns.

**First, check if test infrastructure exists:**

1. Look for test directories (`test/`, `tests/`, `__tests__/`, `spec/`)
2. Look for test command in `package.json`, `Makefile`, or `README.md`
3. Look for test configuration files (`jest.config.js`, `pytest.ini`, `*_test.go`, etc.)

**If no test infrastructure found:**

**Headless branch (MAKATO_HEADLESS=1):**

Do NOT halt and do NOT prompt. Set an in-memory flag `no_test_infrastructure:true` and continue to Step 5. The R1 envelope at session end MUST include:
```json
"data": {
  "no_test_infrastructure": true,
  "degraded_confidence": true
}
```
This signals HALT-CH-004 (degraded confidence, not a failure). Note in the PR description that automated tests are not included due to missing infrastructure.

Log an `autonomous_bypass` entry:
```bash
shared/log-bypass.sh makato-change:execute "<ISSUE_KEY>" no-test-infrastructure continue-degraded cli_flag \
  '{"halt_code":"HALT-CH-004"}'
```

**Interactive branch (default):**

Use `AskUserQuestion` to confirm approach:

**Question:** "No test infrastructure detected. How should I proceed?"

**Options:**
1. **Skip tests** — Implement without tests (warn about lack of verification)
2. **Create basic test setup** — Set up minimal test infrastructure for this project
3. **User will add tests later** — Proceed with implementation, user handles testing separately

If user chooses "Skip tests":
- Warn that implementation will not be verified by automated tests
- Note in PR description that tests are not included
- Proceed to Step 5 (Verify Changes)

If user chooses "Create basic test setup":
- Set up test framework matching project language/stack
- Create example test file
- Document test setup in commit message
- Proceed with test writing below

**If test infrastructure exists, follow the test strategy from the design artifact:**

**Update Existing Tests:**
1. Find test files that cover modified code (unit, integration, and E2E)
2. Adjust assertions for changed behavior
3. Add new test cases for new scenarios within existing tests
4. Update mocks/fixtures if data structures changed
5. Ensure test names still accurately describe what they test

**Check for E2E tests:**
- Search for E2E test files that cover the affected functionality
- Common locations: `e2e/`, `tests/e2e/`, `cypress/`, `playwright/`, `__e2e__/`
- Common patterns: `*.e2e.spec.*`, `*.e2e.test.*`, `*.spec.ts` (in e2e directories)
- If E2E tests exist, read them to understand what user scenarios they validate
- Update E2E test scenarios if behavior changes affect those workflows

**Generate New Tests:**
1. Create test files for new functions/components
2. Write unit tests for new behavior (following existing patterns)
3. Write integration tests for new flows (if design specifies)
4. Use the same mocking/fixture approach as existing tests
5. Match test file naming and location conventions
6. Cover happy path and edge cases identified in the design

**Test Coverage Checklist:**
- All new functions have unit tests
- All modified behavior has updated tests
- E2E tests updated if user workflows changed
- Edge cases from analysis are covered
- Error scenarios from design are tested

### Step 4: Run Test Suites

Load @references/test-generation-guide.md for test command detection patterns.

**Detect test command** (README → package.json scripts → language conventions → Makefile → ask user if unclear).

**Run unit/integration tests:**
- Respect test scope from design (module-only vs full suite)
- Execute: `<detected-test-command> [module-path-if-module-only]`
- If tests fail: diagnose (implementation bug, incorrect test, environment), fix, re-run
- Do not proceed until tests pass

**Run E2E tests** (if they exist per design):
- Detect E2E command (README, package.json `test:e2e`/`e2e`/`cypress`/`playwright`)
- Execute E2E test command
- If fail: check integration issues, fix, re-run
- Do not proceed until E2E tests pass

### Step 5: Verify Changes (Manual Check)

**If changes affect UI or user-facing behavior:**

1. Check if a dev server is needed:
   - Look for `start` or `dev` script in `package.json`
   - Common patterns: `npm start`, `npm run dev`, `rails server`, `python manage.py runserver`
2. Start the application locally
3. Navigate to the affected feature in the UI
4. Manually verify the changed behavior works as designed:
   - Test the happy path (normal usage)
   - Test edge cases identified in the analysis
   - Verify error messages appear correctly
   - Check that UI elements look right (buttons, dialogs, text)
5. Look for regressions (other features broken by the change)
6. Stop the dev server when done

**If changes are backend-only (no UI):**
- Confirm via test output that behavior is correct
- Optionally: make test API calls using curl or Postman to verify manually
- Check logs for any unexpected warnings or errors

**Confirm requirements met:**
- Review the requirements from the analysis artifact
- Verify each requirement is satisfied by the implementation
- If any requirement is not met, go back and fix before proceeding

### Step 5.5: Review and Verify Implementation (Loop Until Approved)

This step runs code review first, then quality checks, forming a verification loop that ensures both code quality and test coverage before committing.

**Iteration Loop (max 3 iterations — if not resolved, surface to user):**

**5.5.1: Dispatch `code-reviewer` agent** to review implementation.

**Agent input:**
```
REPO_ROOT: <from Step 1.5: repositories.yml primary repo path>
ISSUE_KEY: <issue-key>
DESIGN_PATH: <specs/<issue-key>/design.md>
ANALYSIS_PATH: <specs/<issue-key>/analysis.md>
CHANGED_FILES: <list of modified/created files, relative to REPO_ROOT>
DIFF: <output of: git -C <REPO_ROOT> diff>
```

**Agent will return:**
- Critical issues (must fix)
- Major issues (should fix)
- Minor issues (consider)
- Positive findings
- Design alignment check
- Requirements coverage check
- Status: approved | changes_required

**Handle results:**
- If status = changes_required:
  - Review critical and major issues
  - Fix issues in code
  - Continue to Step 5.5.2 (quality gate will catch if fixes need tests)
- If status = approved:
  - Continue to Step 5.5.2 (run quality gate on final code)

**5.5.2: Dispatch `quality-guard` agent** to run quality checks.

**Agent input:**
```
REPO_ROOT: <from Step 1.5: repositories.yml primary repo path>
DESIGN_PATH: <specs/<issue-key>/design.md>
TEST_SCOPE: <from design: module-only | full-suite>
MODULE_PATH: <if module-only, the module/package path>
CHANGED_FILES: <list of modified/created files, relative to REPO_ROOT>
```

**Agent will return:**
- Lint status (pass/fail with errors)
- Format status (pass/fail with unformatted files)
- Type check status (pass/fail with errors)
- Unit test status (pass/fail with failures)
- Coverage status (pass/fail with per-file metrics)
- Integration test status (if applicable)
- Overall gate status (PASS/FAIL)

**Handle results:**
- If gate PASSED and code-reviewer status was approved:
  - Proceed to Step 6
- Otherwise (gate FAILED, or gate PASSED but code-reviewer status was changes_required):
  - If gate FAILED: fix blocker issues (add missing tests, fix type errors, fix lint issues)
  - Go back to Step 5.5.1 (re-run code-reviewer on the current code)
  - **Loop guard**: Track iteration count. If this is the 3rd iteration without approval, stop and report to user with details of blocking issues that prevent automatic resolution.

**Why this sequence matters:** Code review can introduce new code paths (edge case handling, bug fixes). Running quality-guard AFTER code-reviewer ensures those changes are tested and meet coverage thresholds before committing.

### Step 6: Create Feature Branch

**CRITICAL: Always work on a feature branch, never commit directly to main/master.**

Check current branch in target repository:
```bash
git -C <REPO_ROOT> branch --show-current
```

If on `main` or `master` branch, create and checkout a feature branch:

**Headless branch (MAKATO_HEADLESS=1):**

1. **Use the orchestrate-provided `WORKTREE_PATH` when present.** When `execute` is dispatched by `makato-change:orchestrate` (the normal autonomous path), the context preamble carries a non-empty `WORKTREE_PATH` — orchestrate Step 0.5 already created (or, on resume, re-attached to) the `feat/<KEY>-change` worktree. In that case **do NOT call `worktree.sh create` again**: adopt the provided `WORKTREE_PATH` directly and skip to "Store the returned worktree path" below. This prevents a second, differently-named worktree and keeps every commit inside orchestrate's isolated branch (#467).

2. **No `WORKTREE_PATH` in the bundle (standalone `execute` invocation).** Only in this case, use `worktree.sh` to create the branch inside a dedicated worktree. Use the **same** branch-name convention orchestrate uses — `feat/<ISSUE-KEY>-change` — so a standalone run and an orchestrate-driven run never diverge:

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/worktree.sh" create --new-branch <KEY> <ISSUE_NUMBER> <REPO_NAME> feat/<ISSUE-KEY>-change
   ```

Store the returned worktree path as `WORKTREE_PATH`. All subsequent file edits and git operations in this step and Steps 7–8 MUST use `WORKTREE_PATH` instead of `REPO_ROOT` for git ops.

If `MAKATO_ORCHESTRATE_SHARED` is unset, fall back to the standard `git -C` approach below (no worktree isolation — branch is created in the main checkout).

**Interactive branch (default):**

```bash
git -C <REPO_ROOT> checkout -b feat/<ISSUE-KEY>-<short-description>
```

**Branch naming convention:**
- Format: `feat/<ISSUE-KEY>-<short-description>`
- Example: `feat/PROJ-1234-account-deletion`
- Use lowercase with hyphens
- Keep description brief (2-4 words)

If already on a feature branch, continue on that branch.

**Why `-C` flag:** The skill may be invoked from a separate specs directory or another location. The `-C <REPO_ROOT>` flag ensures git operations target the correct repository regardless of current working directory.

### Step 7: Commit Changes

Load @shared/commit-message-format.md for commit structure.

Stage all changed and new files in target repository:
```bash
git -C <REPO_ROOT> add <files>
```

**Important:** Do NOT use `git add .` or `git add -A` — explicitly add files to avoid accidentally committing sensitive files (.env, credentials, etc.) or large binaries.

Check git status to confirm:
```bash
git -C <REPO_ROOT> status
```

Review staged files. If unintended files are staged, unstage them.

Create commit with structured message:
```bash
git -C <REPO_ROOT> commit -m "$(cat <<'EOF'
<type>(<scope>): <subject line> (<ISSUE-KEY>)

<body: summary of changes>

Design: specs/<ISSUE-KEY>/design.md
EOF
)"
```

**Example:**
```bash
git commit -m "$(cat <<'EOF'
feat(profile): add account deletion with confirmation (PROJ-1234)

Adds a "Delete Account" button to user profile settings with
confirmation dialog and admin validation.

Design: .claude/cr/PROJ-1234/design.md
EOF
)"
```

**Follow these rules:**
- Use conventional commit format: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
- Reference the GitHub Issues key at the end of subject line in parentheses: `(ISSUE-KEY)`
- Keep subject under 72 characters (including GitHub Issues key)
- Body should summarize WHAT changed and WHY (the design has the HOW)
- Link back to the design artifact for traceability

**Do NOT:**
- Use `--no-verify` or `--no-gpg-sign` (respect hooks and signing)
- Use `--amend` unless explicitly replacing a commit you just made
- Skip writing a meaningful commit message
- Commit directly to main/master (feature branch should already be checked out from Step 6)

If the commit fails due to a pre-commit hook:
1. Read the hook output
2. Fix the issue (linting, formatting, validation)
3. Stage the fixes
4. Create a NEW commit (don't amend unless the previous commit was yours)

### Step 8: Push and Create Pull Request

**Push to remote:**
```bash
git -C <REPO_ROOT> push -u origin <branch-name>
```

**Create PR** with title format: `<type>(<scope>): <description> (<ISSUE-KEY>)`

**Step 1**: Check for repository PR template
```bash
test -f <REPO_ROOT>/.github/PULL_REQUEST_TEMPLATE.md && echo "exists" || echo "not found"
```

**Step 2**: Read the appropriate template

**If repository template exists** (`<REPO_ROOT>/.github/PULL_REQUEST_TEMPLATE.md`):
```
Read: <REPO_ROOT>/.github/PULL_REQUEST_TEMPLATE.md
```

**If NO repository template**:
```
Read: plugins/makato-change/skills/execute/templates/pr-description-template.md
```

**Step 3**: Fill the template

1. Copy the ENTIRE template content from the Read result
2. Replace placeholder text with actual implementation details:
   - **Description of Changes**: Brief overview (2-3 sentences) of what was implemented and why
   - **Links**: GitHub Issues URL - `[ISSUE-XXXXX](https://github.com/browse/ISSUE-XXXXX)`
   - **How to Test**: Concrete steps to verify changes (or note automated tests cover it)
   - **Breaking Changes**: Mark `[x]` on appropriate checkbox (usually No for change requests)
   - **Additional Notes**: Any relevant context, decisions, or trade-offs
   - **PR Checklist**: Mark `[x]` on all applicable items
3. Remove ALL HTML comments (including PR title tips and instructional comments)

**Step 4**: Create PR with filled template:
```bash
cd <REPO_ROOT> && gh pr create --title "<type>(<scope>): <description> (<ISSUE-KEY>)" --body "$(cat <<'EOF'
<paste filled template here - section headers with filled content, NO HTML comments>
EOF
)"
```

**Why `cd <REPO_ROOT>` first:** The `gh` CLI determines the target repository from the current directory. Change to the target repository before creating the PR to ensure it's created in the correct repo.

**CRITICAL**:
- Use the EXACT section headers from whichever template was read
- Do NOT improvise custom sections like "Summary", "Changes", or "Testing"
- Remove ALL HTML comments from the filled template
- The filled template must have the same sections in the same order as the source template

### Step 9: Update GitHub Issues Issue

Link the PR to GitHub Issues using `gh issue comment`:
```
url: <PR URL>
title: "Pull Request: <PR title>"
```

**Error handling:**
- If link creation fails: Log the error but continue (user can manually link PR to GitHub Issues)

Add label `makato-change-implemented` using `gh issue edit --add-label`.

**Transition to Code Review:**
- Get current issue status using `gh issue view` (with fields: ["status"])
- If status is "In Progress", transition to "Code Review":
  - Get available transitions using `gh issue view --json state`
  - Find transition to "Code Review" status
  - Execute transition using `gh issue edit --state` (no comment needed for this straightforward transition)
  - If "Code Review" not available, try "In Review" as fallback
  - If transition fails (not available), continue without error (workflow may differ by project)

### Step 10: Present Summary to User

Confirm implementation is complete:

```
✅ Implementation complete!

**PR**: <PR URL>

**Changes**:
- Modified: <count> files
- Created: <count> new files
- Tests: <count> added/updated
- All tests passing ✓

**Verification**:
- Implementation matches design
- Requirements satisfied
- Manual verification complete

**Next steps**:
- Wait for code review
- Address review feedback (use resolve-review skill if needed)
- Merge once approved
```

Provide the PR URL prominently so the user can view it immediately.

### Step 11: Record Lessons (optional)

After a successful PR creation, the agent MAY record noteworthy lessons or facts discovered
during this execution into the per-issue store. This step is optional and agent-discretionary
— only record a lesson if it is genuinely useful for a future session.

```bash
plugins/makato-build/shared/write-lessons.sh \
  "<issue-key>" \
  "<tier: procedural | semantic>" \
  "<scope: generalizable | local>" \
  "<lesson text>" \
  "[tags_csv]"
```

This appends one JSONL record to `specs/<issue-key>-*/change-lessons.jsonl`. The record
shape is `{ts, tier, text, tags, scope, key, repo}` — the seven fields `promote-lessons.sh`
reads when lifting generalizable records into `.makato/memory/`.

**When to record:**
- A non-obvious integration issue that affected this change and could recur
- A naming or convention pitfall that is not captured in project docs
- A durable technical fact about this repo that would benefit future agents

**Do NOT record:**
- Information already in the design or analysis artifacts
- Trivial observations that are obvious from the code
- PII, credentials, or internal service details

If nothing noteworthy arose during execution, skip this step entirely.
