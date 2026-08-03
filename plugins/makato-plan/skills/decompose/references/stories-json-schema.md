# stories.json Schema

> Canonical schema for `stories.json` (version 2.0). The scenario object used inside
> `successScenarios[]` and `acceptanceTestCases[]` is defined in the shared scenario
> schema — read `shared/scenario-schema.md` (sibling of this skill's SKILL.md).
> Do not redefine the scenario plan here.

## Top-Level Structure

```json
{
  "version": "2.0",
  "slug": "checkout-redesign",
  "source": "github:owner/repo#123",
  "created": "2026-05-14",
  "status": "draft",
  "epic": {
    "summary": "Epic title",
    "objective": "One-line objective statement",
    "labels": ["makato"]
  },
  "stories": []
}
```

`source` is optional — omit when the feature originated from plain text, not a GitHub Issue.

## Story Object

```json
{
  "sequence": 1,
  "phase": "foundation",
  "summary": "User outcome title",
  "storyPoints": 3,
  "teams": ["team-name"],
  "labels": ["makato", "type:feat"],
  "githubIssue": null,
  "description": {
    "background": "Why this story exists, context...",
    "scope": "What to build — specific, bounded...",
    "featureToggle": {
      "alreadyInPlace": false,
      "newNeeded": true,
      "longTermUsage": false,
      "name": "feature-name.enabled",
      "defaultState": "disabled"
    },
    "successScenarios": [
      {
        "title": "Scenario 1: Happy path",
        "given": "...",
        "when": "...",
        "then": "...",
        "and": ["Optional additional Then assertions"],
        "verificationCommand": "pytest tests/test_happy_path.py -k scenario_1"
      }
    ],
    "solutionApproach": "",
    "acceptanceTestCases": [],
    "wikiDocumentation": "",
    "outOfScope": ["Explicit exclusion 1"]
  },
  "definitionOfDone": [
    "User can do X without Y",
    "Error code ABC returned when condition met"
  ],
  "dependencies": {
    "blockedBy": [],
    "blocks": [2, 3]
  },
  "externalDependencies": [
    {
      "team": "Platform Team",
      "description": "Need API X to be available",
      "status": "pending"
    }
  ]
}
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | string | Yes | Always `"2.0"` |
| `slug` | string | Yes | Kebab-case feature identifier — the spec folder name |
| `source` | string | No | `"github:owner/repo#123"` if origin was a GitHub Issue |
| `created` | string | Yes | ISO date |
| `status` | string | Yes | `"draft"` or `"approved"` |
| `epic.summary` | string | Yes | Epic title |
| `epic.objective` | string | Yes | One-liner stakeholder-facing objective |
| `epic.labels` | string[] | Yes | Always includes `"makato"` |
| `stories[].sequence` | number | Yes | Order (1 = walking skeleton) |
| `stories[].phase` | enum | Yes | `"foundation"` / `"happy-path"` / `"edge-cases"` |
| `stories[].summary` | string | Yes | Story title |
| `stories[].storyPoints` | number | Yes | Fibonacci (1,2,3,5,8,13) |
| `stories[].teams` | string[] | Yes | Free-text team names — user-defined |
| `stories[].labels` | string[] | Yes | Always includes `"makato"`. **May carry taxonomy prefixes** (#272): `decompose` emits `type:<feat\|fix\|test\|chore\|docs>` per story (Step 7.12), plus `severity:`/`priority:`/`effort:` when the Three Amigos produce them. `to-issues` (v3.6.0+) honors an explicit in-enum `type:` here over its text heuristic. Example: `["makato", "type:feat"]`. Does NOT carry `tier:`/`points:`/`module:`/`tech:`/`status:` (those are derived by `to-issues`). |
| `stories[].githubIssue` | number | No | Set by `to-issues` when GitHub issues are created |
| `stories[].description.background` | string | Yes | Context/rationale |
| `stories[].description.scope` | string | Yes | Bounded scope statement |
| `stories[].description.featureToggle` | object | Yes | Toggle configuration |
| `stories[].description.successScenarios` | array | Yes | 1-3 high-level Gherkin (draft). Each scenario follows the optional extension pattern from `shared/scenario-schema.md`; the `verificationCommand` field may be present on individual scenarios and must be omitted when unknown. |
| `stories[].description.solutionApproach` | string | No | Empty — filled during refinement |
| `stories[].description.acceptanceTestCases` | array | No | Empty — filled by create-acceptance-tests |
| `stories[].description.wikiDocumentation` | string | No | Empty — filled post-implementation |
| `stories[].description.trigger` | string | No | Event/condition that triggers the story — rendered by `to-issues` as a `## Trigger Condition` section when non-empty |
| `stories[].description.outOfScope` | string[] | No | Explicit exclusions |
| `stories[].definitionOfDone` | string[] | Yes | 3-5 story-specific product conditions |
| `stories[].dependencies.blockedBy` | number[] | No | Other story sequences |
| `stories[].dependencies.blocks` | number[] | No | Other story sequences |
| `stories[].externalDependencies` | array | No | External team dependencies |
