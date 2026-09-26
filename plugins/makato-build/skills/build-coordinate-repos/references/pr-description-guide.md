# PR Description Guide for Multi-Repo Coordination

## Template

```markdown
## {STORY_KEY}: {Summary}

### Changes in this repository

{Scope of changes specific to this repo}

### Multi-Repo Coordination

This PR is part of a coordinated change across multiple repositories:

| Repository | PR | Role |
|---|---|---|
| **{this_repo}** | **This PR** | {role} |
| {other_repo_1} | {PR_URL_1} | {role} |
| {other_repo_2} | {PR_URL_2} | {role} |

**Review and merge order**: {dependency order or "any order"}

### Jira

- Ticket: [{STORY_KEY}]({JIRA_URL})

### Checklist

- [ ] All sibling PRs reviewed
- [ ] Integration verified across repos
- [ ] No breaking changes to shared contracts
```

## Field Reference

| Field | Source |
|---|---|
| `STORY_KEY` | Build session story key |
| `Summary` | Story summary from `stories.json` or plan |
| `role` | `primary` or `supporting` from `repositories.yml` |
| `dependency order` | Derived from repo roles — `primary` first if tightly coupled |
