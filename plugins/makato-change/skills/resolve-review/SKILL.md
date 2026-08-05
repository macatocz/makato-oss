---
name: resolve-review
description: >-
  Resolve PR review feedback for a change request — address inline comment
  threads and review-level comments with code fixes or clarifying replies,
  push fixes to the feature branch, and reply to reviewers with commit SHAs.
  Use after a PR has been created and reviewers have left feedback.
  Triggers: PR comments, review feedback, address comments, reviewer feedback,
  resolve review, re-review, address PR review.
version: "1.0.4"
metadata:
  last_updated: "2026-08-05"
allowed-tools:
  - Bash
  - Read
  - Write
---

# resolve-review

Resolve PR review feedback for change request implementation by addressing
comments, making necessary code changes, and replying to reviewers.

## When to Use

Use this skill after a PR has been created for a change request and reviewers
have left feedback that needs to be addressed.

**Handles:**
- PR review comments (general feedback on the PR)
- Line-specific inline comments (feedback on particular code sections)
- Review threads (groups of related comments)

**Does NOT handle:**
- Issue comments on the linked GitHub Issues ticket (use GitHub Issues MCP tools directly)
- Commit comments (use `gh` CLI directly)
- GitHub issue comments if the PR is from a fork

**Do NOT use this skill if:**
- No PR exists yet (use `execute` first)
- The PR has no review comments
- The PR has already been approved and merged

## Anti-patterns

**NEVER mark comment threads as resolved yourself — only the original reviewer should.**
GitHub's thread-resolution state drives the reviewer's re-check workflow. If you
mark a thread resolved, the reviewer loses their own checklist of items-to-verify,
and the PR may show "all resolved" while the reviewer has not yet seen the fix.
Thread resolution is a reviewer-owned gate, not a writer-owned one.

**NEVER push partial fixes mid-batch when multiple comments share a root cause.**
Pushing separate "address PR review feedback" commits for the same underlying
problem (e.g., a missing null guard in three locations) makes bisect useless and
buries the actual fix in noise. Group all comments with the same root cause into
one atomic commit and reference all comment IDs in the commit body.

**NEVER reply to a comment before the fix commit is pushed.**
A reply saying "Fixed" without a commit SHA gives reviewers nothing to click.
They must wait for the commit, then manually correlate the fix to the thread.
Push first, capture the SHA, then reply with `Fixed in <SHA>` so reviewers jump
directly to the diff.

**NEVER adopt a Design Disagreement suggestion without consulting the user first.**
The design was settled in the `design` phase and is the source of truth for scope.
Autonomously refactoring to a reviewer's preferred pattern can invalidate the
design artifact, expand scope, and violate the makato-change 15-file scope cap.
Always present the tradeoffs and get explicit user approval before restructuring.

**NEVER use `gh pr comment` to reply to inline (line-specific) review comments.**
`gh pr comment` appends a new top-level PR comment — not a threaded reply. Inline
review threads require the dedicated endpoint:
`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`
Using the wrong endpoint breaks thread context; reviewers must hunt for the reply
instead of seeing it inline, and automated "resolved" tracking is bypassed.

## Workflow

### Step 1: Identify the PR

Ask the user for the PR identifier (either PR number or GitHub issue number).

If GitHub issue number is provided:
- Use the GitHub MCP `issue_read` tool (method: get) to fetch the issue —
  do NOT use `gh issue view` CLI (MCP tools return structured data without
  shell-escaping concerns)
- Locate the linked PR:
  ```bash
  gh pr list --json number,url --search "closes:#<ISSUE_NUMBER>"
  ```
- Parse PR number from the result
- If no PR link found: inform user and exit (PR not yet created, use `execute` first)

If PR number is provided directly, use it.

Store: `PR_NUMBER`, `ISSUE_KEY`

### Step 2: Fetch Review Comments

GitHub PR feedback lives in three distinct structures — fetch all three for
complete coverage (a common miss is omitting inline comments):

```bash
# Completed review submissions (state: APPROVED, CHANGES_REQUESTED, COMMENTED)
gh pr view <PR_NUMBER> --json reviews

# General PR-level comments (not attached to a specific line)
gh pr view <PR_NUMBER> --json comments

# Inline review comments attached to file:line positions (includes id field for replies)
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/comments
```

Parse each response to extract:
- Review-level comments (general feedback on the PR)
- Line-specific inline comments — note each comment's `id`, `path`, and `line`
  (the `id` is required for thread replies in Step 7)
- Comment authors and timestamps

If no comments found across all three sources, inform the user and exit.

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

MANDATORY: Load @references/review-feedback-patterns.md now to understand
feedback categories before classifying any comment. Do NOT load this reference
at any other step.

For each comment, classify the appropriate action:

**Code Change Required:** Reviewer identified a bug, security issue, or
incorrect implementation → make the code change.

**Clarification Needed:** Reviewer has a question or misunderstood the approach.
MANDATORY: Load @references/reply-templates.md when crafting a clarification
reply. Do NOT load reply-templates.md unless a clarification or reply is needed.

**Design Disagreement:** Reviewer suggests a different approach → do NOT adopt
autonomously (see Anti-patterns). Use AskUserQuestion with these options:
```
Options:
1. Adopt reviewer's suggestion ([describe the change])
2. Keep current approach — reply with rationale
3. Propose a compromise
```

**Acknowledgment:** Reviewer suggests a future improvement → acknowledge and
optionally create a follow-up GitHub Issues issue.

After classifying each comment, use AskUserQuestion to confirm before
implementing:

```
Comment #<N>: <summary>
Classification: <Code Change / Clarification / Design Disagreement / Acknowledgment>
Proposed action: <specific action>

Options:
1. Proceed with proposed action
2. Override → Code Change
3. Override → Clarification
4. Override → Design Disagreement
5. Override → Acknowledgment
```

### Step 5: Run Quality Gate

After all code changes are made, dispatch the **quality-guard** agent to verify.

**Skip this step if no code changes were made** (all comments resolved via
replies, clarifications, or acknowledgments only — proceed directly to Step 6).

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
- If gate FAILED: review blocker issues, fix, re-run quality-guard agent, do
  not proceed until gate passes

**Why this step is critical:** Review feedback often introduces new code paths
or edge case handling. Without the full quality gate, these changes may lack
test coverage or violate project standards.

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
git -C <REPO_ROOT> push
```

**Why `-C <REPO_ROOT>`:** Ensures git operations target the correct repository
when the skill is invoked from a separate specs directory or another location.

**Capture the commit SHA immediately after push** — required for reply messages
in Step 7 (see Anti-patterns: never reply before pushing):

```bash
REPLY_SHA=$(git -C <REPO_ROOT> rev-parse --short HEAD)
```

### Step 7: Reply to Comments

Reply to every comment that was addressed. Always reference `$REPLY_SHA` in
fix-replies. For inline comments, use the thread-reply endpoint (NOT `gh pr comment`
— see Anti-patterns).

**For review-level comments (general PR feedback):**
```bash
gh pr comment <PR_NUMBER> --body "$(cat <<'EOF'
@<reviewer> <response text>
EOF
)"
```

**For line-specific inline comments:**
```bash
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies \
  -f body="$(cat <<'EOF'
<response text>
EOF
)"
```

Comment IDs come from the inline comment payload fetched in Step 2.

**Reply discipline:**
- Always include commit SHA: "Fixed in $REPLY_SHA"
- For line-specific comments, explain what code changed and why
- Do NOT mark threads as resolved — that is the reviewer's gate (see Anti-patterns)

### Step 8: Present Summary

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

### Step 9: Record Lessons (optional)

After a successful resolve-review cycle, the agent MAY record noteworthy lessons
discovered while addressing review feedback. Only record if genuinely useful for
a future session.

```bash
MAKATO_ROOT=$(git rev-parse --show-toplevel)
"$MAKATO_ROOT/plugins/makato-build/shared/write-lessons.sh" \
  "<issue-key>" \
  "<tier: procedural | semantic>" \
  "<scope: generalizable | local>" \
  "<lesson text>" \
  "[tags_csv]"
```

This appends one JSONL record to `specs/<issue-key>-*/change-lessons.jsonl`.
The record shape is `{ts, tier, text, tags, scope, key, repo}` — the seven
fields `promote-lessons.sh` reads when lifting generalizable records into
`.makato/memory/`.

**When to record:**
- A recurring reviewer concern signaling a project convention not captured in docs
- A non-obvious test pattern that reviewers requested
- A durable fact about this repo's review norms (e.g. required PR checklist items)

**Do NOT record:**
- Information already in the design, analysis, or PR artifacts
- Trivial observations obvious from the code
- PII, credentials, or internal service details

If nothing noteworthy arose, skip this step entirely.
