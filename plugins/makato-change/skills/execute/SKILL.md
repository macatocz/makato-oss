---
name: execute
description: >-
  Implement a change request by modifying code in the target repo, updating
  tests, running the quality gate (code-reviewer + quality-guard agents), and
  opening a pull request linked to the GitHub issue. Use when design.md is
  approved and the user is ready to write code. Trigger keywords:
  implementation, coding changes, test updates, PR creation, execute change,
  apply design, implement change request.
version: "1.5.0"
argument-hint: "[ISSUE-KEY]"
allowed-tools: Bash
metadata:
  authors: [makato-change]
  last_updated: "2026-08-05"
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

## Anti-patterns

Violations in this section cause silent failures that are hard to diagnose — each WHY explains the non-obvious failure mode.

**NEVER call `worktree.sh create` when `WORKTREE_PATH` is already present in the dispatch bundle.**
WHY: `orchestrate` Step 0.5 already created the `feat/<KEY>-change` worktree and recorded its path in the loop's `workflow-state.json`. A second `worktree.sh create` call spawns a differently-named branch, orphaning the issue's audit trail, creating divergent board state, and preventing `orchestrate` from reconciling the in-flight item (#467).

**NEVER improvise when `change-implementer` returns `status=blocked` with a `design_gap`.**
WHY: The `execute` context holds the full approved requirements from `analyze` + `design`. Any decision about resolving the gap belongs to the user (interactive) or must be surfaced as a blocker (autonomous). Improvising produces an implementation that silently diverges from the approved design — the design review step catches code issues, not requirement substitution.

**NEVER use `gh issue view --json state` or `gh issue edit --state` to advance the project board Status.**
WHY: These two commands control the issue's open/closed lifecycle flag, not the GitHub Projects v2 board column. The command exits 0 and appears to succeed while leaving the board card unchanged — so the loop picks the issue up again on the next poll, producing a duplicate dispatch. Use `gh project item-edit --single-select-option-id` (exactly as Step 1.6 does for In Progress).

**NEVER use `git add .` or `git add -A` when staging changes.**
WHY: The skill is invoked from a `specs/` directory that is typically a sibling of the target repo. A glob add stages from the current working directory — which is the specs tree, not the repo — and may include `.env`, generated credentials, or large binaries that are outside the design scope and must not be committed.

**NEVER pass an empty array (`[]`) for `PRIOR_LESSONS` or `RECOMMENDED_SKILLS` in the `change-implementer` dispatch bundle.**
WHY: `change-implementer` treats an empty array as "no prior art was found" (checked and confirmed empty), while an absent field means "not applicable / not looked up". Sending `[]` suppresses the agent's own lookup fallback, silently discarding lessons that were recorded but happened to be empty at analysis time. Omit the field entirely when the value is absent or `[]`.

**NEVER use `--no-verify` or `--no-gpg-sign` on commits.**
WHY: Pre-commit hooks in the target repo enforce security policies, compliance gates, or lint rules that exist independent of this skill's quality gate. Bypassing them produces commits that pass locally but fail CI on push — and the failure cannot be remedied without a force-push or a fixup commit, both of which disrupt the audit trail.

**NEVER improvise custom PR section headers.**
WHY: Both the repo template and `templates/pr-description-template.md` have fixed section names that automated PR bots, semantic-release tooling, and changelog generators parse by exact header text. Custom sections like "Summary" or "Changes" cause those tools to silently skip the PR, producing an incomplete changelog and breaking linked-issue tracking.

---

## Reference Loading Contract

References are loaded **at point-of-use only** — never pre-loaded. Each entry is marked **MANDATORY** at the step where it is required.

| Reference | Load at | Condition |
|---|---|---|
| `@shared/repositories-yml-schema.md` | Step 1.5 | always |
| `@shared/path-resolution.md` | Step 1.5 | always |
| `@references/implementation-guidelines.md` | Step 2 | always |
| `@references/test-generation-guide.md` | Step 3 | test infrastructure present |
| `@references/test-generation-guide.md` | Step 4 | test infrastructure present |
| `@shared/commit-message-format.md` | Step 7 | always |

**Do NOT load** any reference before the step listed above. Loading `test-generation-guide.md` before confirming that test infrastructure exists wastes context on a branch the skill may never enter.

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

**MANDATORY: Load `@shared/repositories-yml-schema.md`** — schema and field semantics for repositories.yml.

Extract:
- REPO_NAME: `affected[role=primary].path`

**MANDATORY: Load `@shared/path-resolution.md`** — resolution algorithm, error message template, and edge-case handling.

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
- Suggest standard layouts (see `@shared/path-resolution.md` for error message template)
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

**MANDATORY: The agent loads `@references/implementation-guidelines.md`** before writing any code — this is enforced by the agent prompt and covers absolute-path conventions, scope cap (15 files), and context7 lookup obligation.

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

**If test infrastructure exists:**

**MANDATORY: Load `@references/test-generation-guide.md`** — contains the full stack-specific test writing procedure, mocking patterns, fixture conventions, and coverage thresholds for this skill.

Apply the test scope from the design artifact (module-only vs full suite). For each modified file: update assertions for changed behavior, add new test cases for new scenarios, update mocks/fixtures if data structures changed. For new files: create test files following existing naming conventions. Detect and update E2E tests in `e2e/`, `cypress/`, `playwright/`, `__e2e__/` if the changed behavior affects user-facing workflows.

### Step 4: Run Test Suites

**MANDATORY: Load `@references/test-generation-guide.md`** — for test command detection patterns and stack-specific run conventions.

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

Start the application locally (check `package.json` `start`/`dev` scripts, or `rails server`, `python manage.py runserver`) and navigate to the affected feature. Verify against the happy path and each edge case listed in `analysis.md`. Look for regressions in adjacent workflows. Stop the dev server when done.

**If changes are backend-only (no UI):**
Confirm via test output that behavior is correct; optionally make test API calls via curl and check logs for unexpected warnings.

**Confirm requirements met:**
Review the requirements from the analysis artifact — each requirement must be satisfied before proceeding.

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

**MANDATORY: Load `@shared/commit-message-format.md`** — conventional commit structure, type vocabulary, subject-line limits, and footer conventions for this plugin.

Stage all changed and new files in target repository (explicit paths only — never `git add .` or `git add -A`):
```bash
git -C <REPO_ROOT> add <files>
```

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
- Use `--no-verify` or `--no-gpg-sign` (respect hooks and signing — see Anti-patterns)
- Use `--amend` unless explicitly replacing a commit you just made in this session
- Skip writing a meaningful commit message
- Commit directly to main/master (feature branch should already be checked out from Step 6)

If the commit fails due to a pre-commit hook:
1. Read the hook output
2. Fix the issue (linting, formatting, validation)
3. Stage the fixes
4. Create a NEW commit (do not amend the previous commit)

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
- Do NOT improvise custom sections like "Summary", "Changes", or "Testing" (see Anti-patterns)
- Remove ALL HTML comments from the filled template
- The filled template must have the same sections in the same order as the source template

### Step 9: Update GitHub Issues and Advance Board

Link the PR to GitHub Issues using `gh issue comment`:
```
url: <PR URL>
title: "Pull Request: <PR title>"
```

**Error handling:**
- If link creation fails: Log the error but continue (user can manually link PR to GitHub Issues)

Add label `makato-change-implemented` using `gh issue edit --add-label`.

**Transition to In Review on project board:**

Read project config from `.claude/config.json` (`github_project` block). Extract:
`fields.status.id` → `STATUS_FIELD_ID`, `fields.status.options.in_review` → `IN_REVIEW_OPTION_ID`, `project_node_id` → `PROJECT_NODE_ID`, `host`, `owner`, `number`. If any field is missing, skip board transition with a WARN and continue.

Otherwise, find the board item and advance its Status (same `gh project item-edit` pattern as Step 1.6 — never `gh issue edit --state`, which sets open/closed, not board column):

```bash
ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
  --owner "$OWNER" --format json --limit 9999 \
  --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
  | head -1)"
ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
```

If `ITEM_ID` is empty: log `execute: WARN — issue not found on board; skipping In Review update` and continue.

If `CUR_STATUS` is already `"In review"`: log `execute: already In Review — skipping` and continue.

Otherwise:
```bash
GH_HOST="$HOST" gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_NODE_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$IN_REVIEW_OPTION_ID"
```

On failure: log `execute: WARN — could not set In Review on board; continuing` (best-effort).

### Step 10: Present Summary to User

Confirm implementation is complete:

```
Implementation complete!

PR: <PR URL>

Changes:
- Modified: <count> files
- Created: <count> new files
- Tests: <count> added/updated
- All tests passing

Verification:
- Implementation matches design
- Requirements satisfied
- Manual verification complete

Next steps:
- Wait for code review
- Address review feedback (use resolve-review skill if needed)
- Merge once approved
```

Provide the PR URL prominently so the user can view it immediately.

### Step 11: Record Lessons

After successful PR creation, record one JSONL entry per noteworthy lesson discovered during execution — only if genuinely useful for a future session. Skip entirely if nothing noteworthy arose.

```bash
plugins/makato-build/shared/write-lessons.sh \
  "<issue-key>" \
  "<tier: procedural | semantic>" \
  "<scope: generalizable | local>" \
  "<lesson text>" \
  "[tags_csv]"
```

Appends to `specs/<issue-key>-*/change-lessons.jsonl`. Record shape: `{ts, tier, text, tags, scope, key, repo}` — the seven fields `promote-lessons.sh` reads when lifting generalizable records into `.makato/memory/`.

**Record when:**
- A non-obvious integration issue affected this change and could recur
- A naming or convention pitfall is not captured in project docs
- A durable technical fact about this repo would benefit future agents

**Do NOT record:**
- Information already in the design or analysis artifacts
- Trivial observations obvious from the code
- PII, credentials, or internal service details
