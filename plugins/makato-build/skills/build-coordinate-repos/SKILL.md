---
name: build-coordinate-repos
description: >-
  Coordinate multi-repo story PRs — pre-flight each repo, open cross-linked PRs,
  link to Jira, post coordination comment. Use when a story spans multiple repositories.
version: "1.0.0"
argument-hint: "[story-key]"
allowed-tools: Bash(git *) Bash(gh *) Read Write Grep Glob
metadata:
  last_updated: "2026-09-25"
---

# Build Coordinate Repos

Coordinate PRs across multiple repositories for a single story. Pre-flights each repo,
opens PRs with cross-links, links all to the Jira ticket, and posts a coordination
comment. Replaces manual multi-repo PR coordination.

## When to Use

- Story spans 2+ repositories (infra + application, API + UI, etc.)
- `build-push-to-git` detected `repos_pushed > 1`
- Need atomic PR coordination with cross-links and Jira integration

## When NOT to Use

- Single-repo story (use `build-create-pr` directly)
- No PRs to open (story is still in progress)
- Repos are unrelated (open PRs independently)

---

## Workflow

### Step 1: Resolve Repositories

Read `build.jsonl` for the current story key and identify all repos that have been pushed:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

Extract unique repository paths from `build.jsonl` entries with `repo` field or from
`repositories.yml` in the spec folder.

For each repo, confirm:
- Feature branch exists and is pushed
- No uncommitted changes remain
- `build-verify` gate passed (check `build.jsonl` for `gate-*` entries with `status: ok`)

### Step 2: Pre-flight Checks

For each repository in the coordination set:

1. **Uncommitted changes check**: `git status --porcelain` must be empty.
2. **Feature branch check**: current branch is not `main` or `master`.
3. **Pushed check**: `git log origin/<branch>..HEAD` must be empty (all commits pushed).
4. **Verify gate scoped to repo**: scan `build.jsonl` for entries with `"repo":"<name>"`
   and confirm all `gate-*` steps have `status: ok`.

If any check fails, report which repo and which check, and offer:

```text
AskUserQuestion:
  question: "Pre-flight failed for {repo}: {check}. How to proceed?"
  options:
    - "Fix it — I'll address the issue and re-run"
    - "Skip this repo — open PR for the others only"
    - "Abort — cancel coordination"
```

### Step 3: Optional Integration Verification

```text
AskUserQuestion:
  question: "Run integration verification across repos before opening PRs?"
  options:
    - "Yes — verify integration (Recommended for tightly coupled repos)"
    - "Skip — repos are loosely coupled, PRs can be reviewed independently"
```

If yes: run integration tests that span the repos (if configured in the project).

### Step 4: Open PRs Per Repo

For each repo in the coordination set, open a PR with user approval per repo:

1. Load `references/pr-description-guide.md` for the PR body template.
2. Build PR body with:
   - Story key and summary
   - Cross-links to PRs in other repos (use placeholder URLs for not-yet-created PRs,
     then patch after all PRs are open)
   - Scope of changes in this repo
   - Link to Jira ticket

3. For each repo, present and confirm:

```text
AskUserQuestion:
  question: "Open PR for {repo}? Title: '[{STORY_KEY}] {summary}'"
  options:
    - "Yes — open PR (Recommended)"
    - "Skip this repo"
    - "Edit title or body first"
```

4. Open PR:
```bash
GH_HOST=github.com gh pr create \
  --repo "{owner}/{repo}" \
  --title "[{STORY_KEY}] {summary}" \
  --body-file "$TMPFILE" \
  --base main
```

5. Collect all PR URLs.

### Step 5: Cross-Link PRs

After all PRs are created, update each PR body to include links to all sibling PRs:

```bash
for each PR:
  GH_HOST=github.com gh pr edit {PR_NUMBER} \
    --repo "{owner}/{repo}" \
    --body-file "$UPDATED_TMPFILE"
```

### Step 6: Link PRs to Jira

For each PR, link it to the Jira ticket using the Jira MCP or by posting a comment:

```text
mcp: jira add_remote_link or jira add_comment
```

### Step 7: Post Coordination Comment

Post a single coordination comment on the Jira ticket listing all PR URLs:

```markdown
## Multi-Repo PR Coordination

| Repository | PR | Status |
|---|---|---|
| {repo1} | {PR_URL_1} | Open |
| {repo2} | {PR_URL_2} | Open |

All PRs are cross-linked. Review and merge in dependency order.
```

### Step 8: Transition Jira

Transition the Jira ticket to "In Review" status.

### Step 9: Summary

```text
Coordination Complete:
  - {N} PRs opened across {N} repos
  - All PRs cross-linked
  - Jira ticket {STORY_KEY} linked and moved to In Review

PRs:
  - {repo1}: {PR_URL_1}
  - {repo2}: {PR_URL_2}
```
