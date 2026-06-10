# Gherkin Scenario Schema

> Shared scenario plan inside `stories.json` for both `description.successScenarios[]` (drafted by `decompose`) and `description.acceptanceTestCases[]` (refined by `create-acceptance-tests`). Single source of truth for the scenario object.

## plan

```json
{
  "title": "Outcome-focused scenario title using business language",
  "given": "Single precondition describing world state before action",
  "when": "Single triggering action by the user/actor",
  "then": "Observable outcome using 'should' (e.g., 'the user should see...')",
  "and": ["Optional additional Then assertions"]
}
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `title` | string | Yes | Outcome-focused. Avoid "Test", "Check", "Verify" prefixes. |
| `given` | string | Yes | Single precondition. World state, not a step. |
| `when` | string | Yes | Single triggering action. Avoid chaining with "and". |
| `then` | string | Yes | Observable outcome. Should contain "should". |
| `and` | string[] | No | Continuation Then assertions. Rendered as `And ...` lines after the `Then` line. Omit when empty. |

## Where It's Used

- `stories[].description.successScenarios[]` — draft scenarios produced by the `qa-reviewer` agent during `decompose` Step 5, copied into stories.json at Step 7.
- `stories[].description.acceptanceTestCases[]` — refined scenarios produced by `create-acceptance-tests` (3-5 per story, polished against quality rules).

Both use this exact plannot introduce divergent fields in either consumer.

## Rendering

Jira wiki markup (consumed by `publish` Step 8 via `dcp-story-panels.md`):

```jira
*Scenario 1: {title}*
Given {given}
When {when}
Then {then}
And {and[0]}
And {and[1]}
```

The `And` lines are emitted only when `and[]` has entries.
