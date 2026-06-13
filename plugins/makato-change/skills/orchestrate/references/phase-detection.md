# Phase Detection

Logic for detecting which phase the change request workflow is currently in, based on artifact presence and Jira state.

## Detection Rules

### Phase 1: Analyze (Requirements Refinement)

**Status: Complete** if:
- `specs/<ISSUE_KEY>/analysis.md` exists
- File is not empty (> 100 bytes)

**Status: In Progress** if:
- Directory `specs/<ISSUE_KEY>/` exists
- But `analysis.md` is missing or empty

**Status: Not Started** if:
- Directory `specs/<ISSUE_KEY>/` does not exist

### Phase 2: Design (Technical Approach)

**Status: Complete** if:
- `specs/<ISSUE_KEY>/design.md` exists
- File is not empty (> 100 bytes)

**Status: In Progress** if:
- `analysis.md` exists (prerequisite met)
- But `design.md` is missing or empty

**Status: Blocked** if:
- `analysis.md` does not exist (prerequisite not met)

### Phase 3: Execute (Implementation + PR)

**Status: Complete** if:
- Jira issue has a remote link with "pull" or "PR" in the URL
- Check using: `mcp__plugin_daff-core_jira__get_remote_links`
- Link should point to GitHub PR (github.com)

**Status: In Progress** if:
- `design.md` exists (prerequisite met)
- But no PR link found in Jira

**Status: Blocked** if:
- `design.md` does not exist (prerequisite not met)

### Phase 4: Resolve Review (Review Feedback)

**Status: Complete** if:
- PR exists (from Phase 3 check)
- PR is merged (check via `gh pr view <PR_NUMBER> --json state`)

**Status: In Progress** if:
- PR exists and is open
- PR has review comments (check via `gh pr view <PR_NUMBER> --json reviews,comments`)

**Status: Blocked** if:
- No PR exists (prerequisite not met)

**Status: Not Needed** if:
- PR exists and is open
- But no review comments found

## Detection Algorithm

```
1. Check if specs/<ISSUE_KEY>/ exists
   → No: All phases "Not Started", recommend Analyze
   → Yes: Continue

2. Check for analysis.md (> 100 bytes)
   → No: Analyze "In Progress", recommend resuming Analyze
   → Yes: Analyze "Complete", continue

3. Check for design.md (> 100 bytes)
   → No: Design "Not Started", recommend Design
   → Yes: Design "Complete", continue

4. Fetch Jira remote links
   → No PR link: Execute "Not Started", recommend Execute
   → PR link exists: Execute "Complete", continue

5. Fetch PR state and reviews
   → PR merged: All "Complete", workflow done
   → PR open + no comments: Resolve Review "Not Needed", wait
   → PR open + comments: Resolve Review "In Progress", recommend Resolve Review
```

## Recommended Next Phase

Based on current state:

| State | Recommended Next Phase |
|-------|----------------------|
| Nothing started | Analyze |
| Analyze complete, Design not started | Design |
| Design complete, Execute not started | Execute |
| Execute complete, PR open, no reviews | Wait (offer manual Resolve Review) |
| Execute complete, PR has comments | Resolve Review |
| All complete, PR merged | None (workflow complete) |

## File Size Checks

Minimum thresholds to consider a file "complete":
- `analysis.md`: 100 bytes (ensures at least some content, not just frontmatter)
- `design.md`: 100 bytes

These are safety checks. Even if the file exists, if it's too small, treat as incomplete/corrupt.

## Handling Ambiguity

**If multiple phases appear incomplete:**
- Recommend the earliest incomplete phase
- Explain to user what's missing
- Let user choose whether to fix earlier phase or skip ahead

**If artifacts exist but Jira state conflicts:**
- Trust artifacts over Jira (they're the source of truth)
- Example: If `design.md` exists but analysis.md is missing, recommend re-running analyze
- Don't auto-delete artifacts — let user decide

**If user manually deleted artifacts:**
- Detection will show phase as not started
- User can re-run that phase
- Existing later-phase artifacts remain untouched
