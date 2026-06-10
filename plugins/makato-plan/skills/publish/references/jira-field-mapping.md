# Jira Field Mapping

> Complete mapping from stories.json fields to Jira API fields. Load at Step 7 for epic creation and Step 8 for story creation.

## Epic Fields

| stories.json | Jira Field | API field/param | Notes |
|---|---|---|---|
| `epic.summary` | Summary | `summary` | Epic title |
| `epic.labels` | Labels | `labels` | Always includes "makato" |
| `epic.pi` | Component | `components` | Format: "PI \| 26/03" |
| `feature` (ITDB key) | Issue Link | Parent-Child link | Epic is child-of ITDB feature |

## Story Fields

| stories.json | Jira Field | API field/param | Notes |
|---|---|---|---|
| `story.summary` | Summary | `summary` | Story title |
| `story.labels` | Labels | `labels` | Always includes "makato" |
| `story.storyPoints` | Story Points | `storyPoints` (customfield_10013) | Fibonacci values |
| `story.teams` | Team(s) | customfield_16240 | Multi-select |
| `story.description.*` | Description | `description` | Rendered to Jira wiki markup panels |
| `story.definitionOfDone` | Description (DoD panel) | Part of `description` | Informational — not checklist field |
| Epic key | Epic Link | `epicLink` | Native Jira agile link |

## Link Types

The Jira MCP `create_issue_link` tool takes `sourceIssue` / `targetIssue`. The link reads as: "sourceIssue \<outward\> targetIssue".

| Relationship | Link Type | sourceIssue | targetIssue | Reads as |
|---|---|---|---|---|
| Epic ← ITDB Feature | Parent-Child (outward: "parent-of") | ITDB feature key | Epic key | "ITDB is parent-of Epic" |
| Story → Story | Dependency (outward: "depends on", id: 10010) | Blocked story | Blocker story | "Blocked depends on Blocker" |

## Issue Types

| Entity | Jira Issue Type | Type ID |
|---|---|---|
| Epic | Epic | 7 |
| Story | Story | 10500 |
| Subtask | Sub-Task | 10401 |

## Project Keys

Selected at runtime via AskUserQuestion:
- **DCP** — production project
- **DCPAI** — testing project (ID: 194336)

## Labels Convention

Stories always carry:
- `makato` — identifies makato-generated content
- Any additional labels from `story.labels` in stories.json
