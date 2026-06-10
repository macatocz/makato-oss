# Story Rendering Guide

Describes how story fields from `stories.json` render into two outputs:
`handoff.md` (always) and GitHub Issue body (when GitHub provider is configured).

## Sections Filled by Decompose vs. Deferred

| Section | Filled by Decompose | Notes |
|---------|---------------------|-------|
| Background | Yes | Why this story exists |
| Scope | Yes | Bounded description of what to build |
| Dependencies | Yes | External team dependencies |
| Feature Toggle | Yes | At minimum newNeeded yes/no |
| Success Scenarios | Yes (draft) | 1-3 high-level Gherkin from QA agent |
| Solution Approach | No | Left empty — team fills during refinement |
| Acceptance Tests | No | Left empty — QAs fill via acceptance-tests skill |
| Wiki Documentation | No | Left empty — team fills post-implementation |
| Out of Scope | Yes | Explicit boundaries |

## Gherkin Rendering

Success scenarios render as fenced Gherkin code blocks:

```gherkin
Given the user has items in their cart
When they proceed to checkout
Then the total is calculated correctly
```

If a scenario has `and[]` entries, render them as `And ...` continuation lines after `Then`.

## Definition of Done Rendering

Render as a GitHub-flavoured markdown task list:

```markdown
- [ ] User can complete checkout without errors
- [ ] Toggle `checkout.redesign.enabled` controls the feature independently
```

## handoff.md vs. GitHub Issue

Both outputs use the same story fields. The difference is context:

- **handoff.md** — flat markdown, covers the entire epic in one file
- **GitHub Issue** — uses the template at `publish/references/github-issue-template.md`; each story gets its own issue

See `github-issue-template.md` in the publish skill for the full GitHub Issue body template.
