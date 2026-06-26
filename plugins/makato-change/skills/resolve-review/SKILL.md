---
name: resolve-review
description: Resolve PR review feedback for change request by addressing comments with code fixes or clarifying replies, update GitHub issue status
version: "1.0.3"
---

# resolve-review

Resolve PR review feedback for change request implementation by addressing comments, making necessary code changes, and replying to reviewers.

## When to Use

Use this skill after a PR has been created for a change request and reviewers have left feedback that needs to be addressed. This skill helps systematically work through review comments, make code changes where needed, provide clarifying responses, and update the PR.

**Handles:**
- PR review comments (general feedback on the PR)
- Line-specific inline comments (feedback on particular code sections)
- Review threads (groups of related comments)

**Does NOT handle:**
- Issue comments on the linked GitHub Issues ticket (use GitHub Issues MCP tools directly)
- Commit comments (use `gh` CLI directly)
- GitHub issue comments (if PR is from a fork)

**Do NOT use this skill if:**
- No PR exists yet (use `execute` first)
- The PR has no review comments
- The PR has already been approved and merged

## Workflow

### Step 1: Identify the PR

Ask the user for the PR identifier (either PR number or GitHub Issues key).

If GitHub Issues key is provided:
- Use MCP tool `gh issue view` to fetch the issue (do NOT use `gh issue view`)
- Extract PR link from `remote_links` field
- Parse PR number from the link
- If no PR link found: Inform user and exit (PR not yet created, use `execute` skill first)

If PR number is provided directly, use it.

Store: `PR_NUMBER`, `ISSUE_KEY`

### Step 2: Fetch Review Comments

Use `gh pr view <PR_NUMBER> --json reviews,comments` to get all review feedback.

Parse the response to extract:
- Review-level comments (general feedback on the PR)
- Line-specific comments (feedback on particular code sections)
- Threads (groups of related comments)
- Comment authors and timestamps

If no comments found, inform the user and exit.

Store the comments in a structured format for processing.

### Step 3: Load Context Artifacts

Read the change request artifacts to understand the implementation context:

```bash
specs/<ISSUE_KEY>/analysis.md
specs/<ISSUE_KEY>/design.md
specs/<ISSUE_KEY>/repositories.yml
```

These provide the requirements, technical approach, and repository location.

**Load repository context from repositories.yml:**

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

**Validate:**
```bash
test -d "$REPO_ROOT/.git"
```

If validation fails:
- Show searched locations
- Suggest standard layouts (see @shared/path-resolution.md for error message template)
- Exit gracefully

**All subsequent git and file operations must use REPO_ROOT context.**

Also run `git -C "$REPO_ROOT" log --oneline -10` to see recent commits.

### Step 4: Present Comments and Address Each One

For each review comment, present it to the user in this format:

```
Comment #<N> by @<reviewer> on <file>:<line>
---
<comment text>
---
```

Load @references/review-feedback-patterns.md to understand common feedback types and appropriate responses.

For each comment, determine the appropriate action:

**Code Change Required:**
- Reviewer identified a bug, security issue, or incorrect implementation
- Action: Make the code change, explain what was fixed

**Clarification Needed:**
- Reviewer has a question or misunderstood the approach
- Action: Load @references/reply-templates.md and craft a response explaining the reasoning

**Design Disagreement:**
- Reviewer suggests a different approach
- Action: Discuss with user, decide whether to adopt suggestion or explain current approach

**Acknowledgment:**
- Reviewer suggests an improvement that will be addressed later
- Action: Acknowledge and optionally create a follow-up GitHub Issues issue

After addressing each comment, ask the user: "How should we address this comment?" Present the options:
1. Make the code change
2. Reply with clarification
3. Discuss alternative approach
4. Acknowledge for follow-up

Implement the chosen action.

### Step 5: Run Quality Gate

After all code changes are made, dispatch the **quality-guard** agent to verify the changes.

**Skip this step if no code changes were made** (all comments resolved via replies, clarifications, or acknowledgments only — proceed directly to Step 6).

**Agent input:**
```
REPO_ROOT: <from Step 3: repositories.yml primary repo path>
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
- If gate PASSED: proceed to Step 6
- If gate FAILED:
  - Review blocker issues (unit test failures, type errors, critical coverage gaps)
  - Fix issues
  - Re-run quality-guard agent
  - Do not proceed until gate passes

**Why this step is critical:** Review feedback often introduces new code paths or edge case handling. Without running the full quality gate, these changes may lack test coverage or violate project standards, causing the pipeline to fail after the PR is pushed.

### Step 6: Commit and Push Changes

If code changes were made, create a commit following @shared/commit-message-format.md:

```bash
git -C <REPO_ROOT> add <changed-files>
git -C <REPO_ROOT> commit -m "$(cat <<'EOF'
fix(<scope>): address PR review feedback (<ISSUE_KEY>)

<Summary of changes made in response to review>

Design: specs/<ISSUE_KEY>/design.md
EOF
)"
```

Push to the PR branch:
```bash
git -C <REPO_ROOT> push
```

**Why `-C <REPO_ROOT>`:** Ensures git operations target the correct repository when the skill is invoked from a separate specs directory or another location.

### Step 7: Reply to Comments

For each comment that requires a written response, reply directly to the specific review comment thread.

**For review-level comments (general PR feedback):**
```bash
gh pr comment <PR_NUMBER> --body "$(cat <<'EOF'
@<reviewer> <response text>
EOF
)"
```

**For line-specific comments (inline code feedback):**
Reply directly to the comment thread using the GitHub API:

```bash
gh api repos/:owner/:repo/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies \
  -f body="$(cat <<'EOF'
<response text>
EOF
)"
```

To get comment IDs, parse the output from Step 2 (`gh pr view --json comments`). Each comment has an `id` field.

**Best practices:**
- Reply in the same thread as the original comment (keeps discussion organized)
- For line-specific comments, explain what code was changed and why
- Reference commit SHAs when code was fixed: "Fixed in abc1234"
- Keep replies concise and professional

### Step 8: Present Summary

Show the user a summary of actions taken:

```
Review Resolution Summary:
- <N> comments addressed
- <N> code changes made
- <N> test runs (all passing)
- <N> commits pushed
- <N> replies posted

PR Status: Ready for re-review
PR URL: <link>
```

If all comments have been addressed and tests pass, the PR is ready for the reviewer to take another look.
