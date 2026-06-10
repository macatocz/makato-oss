# stories.json Schema

> Canonical schema for `stories.json`. The scenario object used inside `successScenarios[]` and `acceptanceTestCases[]` is defined in the shared scenario schema — read `shared/scenario-schema.md` (sibling of this skill's SKILL.md). Do not redefine the scenario plan here.

## Top-Level Structure

```json
{
  "version": "1.0",
  "feature": "ITDB-1234",
  "created": "2026-05-14",
  "status": "draft",
  "epic": {
    "summary": "[Feature Tag] Epic title",
    "objective": "One-line objective statement",
    "pi": "26/03",
    "labels": ["makato", "pi_planning"]
  },
  "stories": [ ... ]
}
```

## Story Object

```json
{
  "sequence": 1,
  "phase": "foundation",
  "summary": "[Component] User outcome title",
  "storyPoints": 3,
  "teams": ["DCP Core One"],
  "labels": ["makato"],
  "description": {
    "background": "Why this story exists, context...",
    "scope": "What to build — specific, bounded...",
    "featureToggle": {
      "alreadyInPlace": false,
      "newNeeded": true,
      "longTermUsage": false,
      "name": "dcp-feature-name.enabled",
      "defaultState": "disabled"
    },
    "successScenarios": [
      {
        "title": "Scenario 1: Happy path",
        "given": "...",
        "when": "...",
        "then": "...",
        "and": ["Optional additional Then assertions"]
      }
    ],
    "solutionApproach": "",
    "acceptanceTestCases": [],
    "wikiDocumentation": "",
    "outOfScope": ["Explicit exclusion 1"]
  },
  "definitionOfDone": [
    "User can do X without Y",
    "Feature toggle Z controls the behavior independently",
    "Error code ABC returned when condition met"
  ],
  "dependencies": {
    "blockedBy": [],
    "blocks": [2, 3]
  },
  "externalDependencies": [
    {
      "team": "Masterdata Team",
      "description": "Need API X to be available",
      "status": "pending"
    }
  ]
}
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | string | Yes | Schema version for forwards-compat |
| `feature` | string | Yes | ITDB key |
| `created` | string | Yes | ISO date |
| `status` | string | Yes | "draft" or "approved" |
| `epic.summary` | string | Yes | Epic title for Jira |
| `epic.objective` | string | Yes | One-liner |
| `epic.pi` | string | Yes | PI identifier — maps to Jira component |
| `epic.labels` | string[] | Yes | Always includes "makato" |
| `stories[].sequence` | number | Yes | Order (1 = walking skeleton) |
| `stories[].phase` | enum | Yes | "foundation" / "happy-path" / "edge-cases" |
| `stories[].summary` | string | Yes | Story title for Jira |
| `stories[].storyPoints` | number | Yes | Fibonacci (1,2,3,5,8,13) |
| `stories[].teams` | string[] | Yes | Team(s) multi-select |
| `stories[].labels` | string[] | Yes | Always includes "makato" |
| `stories[].description.background` | string | Yes | Context/rationale |
| `stories[].description.scope` | string | Yes | Bounded scope statement |
| `stories[].description.featureToggle` | object | Yes | Always present (DCP convention) |
| `stories[].description.successScenarios` | array | Yes | 1-3 high-level Gherkin (draft). Each scenario: `title`, `given`, `when`, `then`, optional `and[]` (continuation Then assertions, rendered as `And ...` lines) |
| `stories[].description.solutionApproach` | string | No | Empty — filled during refinement |
| `stories[].description.acceptanceTestCases` | array | No | Empty — filled by create-acceptance-tests skill (same scenario plan as successScenarios, including optional `and[]`) |
| `stories[].description.wikiDocumentation` | string | No | Empty — filled post-implementation |
| `stories[].description.outOfScope` | string[] | No | Explicit exclusions |
| `stories[].definitionOfDone` | string[] | Yes | 3-5 story-specific product completion conditions |
| `stories[].dependencies.blockedBy` | number[] | No | Other story sequences |
| `stories[].dependencies.blocks` | number[] | No | Other story sequences |
| `stories[].externalDependencies` | array | No | External team dependencies |

## Jira Field Mapping

| stories.json field | Jira field | Jira field ID | Notes |
|---|---|---|---|
| `epic.summary` | Summary | summary | Epic issue type |
| `epic.pi` | Component | components[] | e.g., "PI \| 26/03" |
| `epic.labels` | Labels | labels | |
| Epic → ITDB | Issue Link | "Parent-Child" (child-of) | Epic links to ITDB feature |
| `story.summary` | Summary | summary | Story issue type |
| `story.storyPoints` | Story Points | customfield_10013 | number |
| `story.teams` | Team(s) | customfield_16240 | multi-select |
| `story.labels` | Labels | labels | |
| `story.description.*` | Description | description | Rendered to Jira wiki markup |
| `story.definitionOfDone` | Checklist (DoD section) | checklist | Pre-populates DoD checklist items |
| Story → Epic | Epic Link | epicLink field | Native Jira epic link |
| Story → Story | Issue Link | "Dependency" (id: 10010) | "depends on" direction |
