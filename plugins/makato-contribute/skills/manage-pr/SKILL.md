---
name: manage-pr
description: Triage and resolve PR review-bot comments after opening a PR — review pr comments, fix bot feedback, resolve hyperspace insights, manage pr review, post-pr cleanup. Validates each finding against the actual code, rates severity, waits for approval, applies fixes, posts gh CLI replies, and resolves threads via GraphQL.
version: "1.1.0"
---

# manage-pr

## When to Use

Use after opening a PR when review bots (e.g., hyperspace-insights) have left comments and the contributor wants to triage them: validate each claim against the real code, rate severity, fix the legitimate ones, and reply on each thread to close the loop.

## When NOT to Use

- Before a PR exists — open the PR first.
- For human-author code review feedback that requires conversation — this skill targets bot-style line comments.
- For repository-wide cleanups unrelated to a specific PR.

## Workflow

### Step 1: Resolve PR Context

If the user gave a PR number or URL, parse it. Otherwise infer from the current branch:

```bash
gh pr view --json url,number,headRepository,baseRepository,headRefName
```

State the resolved PR (number + URL) back to the user before proceeding. If no PR is found for the current branch, stop and ask.

### Step 2: Confirm Remote

Inspect `git remote get-url origin` and confirm the repo resolves to `github.com`.

Load @references/gh-cli-github.md for gh CLI patterns and quirks.

### Step 3: Fetch Summary Review

```bash
gh pr view <n> --json comments,reviews
```

This captures top-level review summaries (the bot's overview comment, if any).

### Step 4: Check Out the PR Branch Locally

```bash
gh pr checkout <n>
```

Check out the branch before fetching comments so validation in later steps reads the correct file content.

### Step 5: Fetch Line-Level Review Threads

```bash
gh api "repos/<owner>/<repo>/pulls/<n>/comments?per_page=100"
```

Do NOT pass `--paginate` — it concatenates multiple JSON arrays and breaks `json.load`. If there are more than 100 comments, page manually with `?page=N`.

### Step 6: Validate Each Comment

For each thread, verify the bot's claim against the actual code:
1. Read the cited file at the cited line.
2. Grep for any symbol, regex, or codepoint the bot quotes — bots often misread these.
3. Decide if the claim matches reality.

Load @references/comment-validation-rubric.md for the validation checklist.

### Step 7: Rate Each Comment

Assign three labels per thread:
- **Validity**: ✅ Valid / ⚠️ Partially valid / ❌ Invalid
- **Severity**: High / Medium / Low / N/A
- **Quality**: 🌟 Awesome / ✅ Helpful / 🤷 Neutral / ❌ Misleading

Load @references/severity-rating-rubric.md for tier definitions and examples.

### Step 8: Render the Report

Print a Markdown table to the conversation using @templates/pr-comment-report.md. One row per comment with: ID, file:line, issue, validity, severity, quality, recommended action.

### Step 9: Wait for Approval

Ask: **"Which fixes should I apply?"** Accept answers like "all valid", "1,3,4", "skip", or per-comment instructions. Do NOT modify any files until the user explicitly approves the set.

### Step 10: Apply Approved Fixes

Edit each cited file at the cited line per the approved recommendation. Stage and commit:

```
fix(<scope>): address PR bot review

- #<id>: <one-line summary>
- #<id>: <one-line summary>
```

Use the plugin name as scope (e.g., `fix(makato-plan): ...`). Match existing commit conventions in the repo.

### Step 11: Reply to Threads on GitHub

For each addressed thread, post a reply via the gh CLI:

```bash
gh api --method POST \
  "repos/<owner>/<repo>/pulls/<n>/comments/<comment_id>/replies" \
  -f body="<reply text>"
```

Load @references/reply-templates.md for canned phrasing (Fixed, Won't fix, Already correct, Out of scope).

### Step 12: Resolve Threads on GitHub

The REST API cannot mark a review thread as resolved — that requires the GraphQL `resolveReviewThread` mutation. After replying, fetch each thread's GraphQL node ID and resolve it.

Fetch thread node IDs (one query for the whole PR):

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:50){
        nodes{ id isResolved comments(first:1){ nodes{ databaseId } } }
      }
    }
  }
}' -F owner=<owner> -F repo=<repo> -F pr=<n>
```

Match each `comments.nodes[0].databaseId` (the REST `id` from Step 5) to its thread `id`. Then resolve:

```bash
gh api graphql \
  -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -F id=<thread-node-id>
```

Only resolve threads the user approved fixes for in Step 9. Leave skipped/invalid threads open so the user can decide whether to dismiss them in the GitHub UI.

### Step 13: Push and Remind

Run `git push` on the PR branch. Then remind the user:
- Check CI: `gh pr checks <n>`
- Some bots re-run on push; others need a manual re-trigger.

### Step 14: Final Summary

Report:
- Comments fetched: N
- Valid: V (Awesome: A, Helpful: H, Neutral: U, Misleading: M)
- Fixes applied: F
- Threads replied: R
- Threads resolved: S
- Threads left open: O — list each so the user can decide whether to dismiss them in the GitHub UI.
