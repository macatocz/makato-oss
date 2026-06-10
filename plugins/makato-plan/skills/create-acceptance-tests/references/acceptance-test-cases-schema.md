# `acceptanceTestCases` Field Schema

The `acceptanceTestCases` field in `stories.json` holds the refined acceptance test scenarios per story. This field is populated by the `create-acceptance-tests` skill after decompose.

## Field Location

```json
{
  "stories": [
    {
      "description": {
        "acceptanceTestCases": [ ... ]
      }
    }
  ]
}
```

## Scenario Object

The scenario object uses the shared scenario schema. Read `shared/scenario-schema.md` (sibling of this skill's SKILL.md) for the canonical plan and field reference.

## Constraints Specific to `acceptanceTestCases`

| Rule | Value |
|------|-------|
| Scenarios per story | 3-5 for `foundation`/`happy-path`; 1-3 for `edge-cases` |
| Title format | Outcome-focused, no "Test"/"Check"/"Verify" prefix |
| Quality rules | Must pass all 6 anti-patterns in `@gherkin-quality-rules.md` |

## Relationship to `successScenarios`

- `successScenarios` — rough drafts from decompose's QA agent (1-3 per story).
- `acceptanceTestCases` — polished, refined versions (3-5 per `foundation`/`happy-path` story; 1-3 per `edge-cases` story).

Both use the same object structure (the shared scenario schema). The `create-acceptance-tests` skill reads from `successScenarios` as input seeds and writes to `acceptanceTestCases` as output.

## Example

```json
"acceptanceTestCases": [
  {
    "title": "User should see pricing breakdown after configuring product",
    "given": "the user has selected a product with configurable options",
    "when": "the user completes the configuration wizard",
    "then": "the user should see a price breakdown showing base price and option costs",
    "and": ["the total should reflect all selected options"]
  },
  {
    "title": "User should receive guidance when required options are missing",
    "given": "the user has not selected all mandatory configuration options",
    "when": "the user attempts to add the product to cart",
    "then": "the user should see which required options are still missing",
    "and": ["the add-to-cart action should be blocked until resolved"]
  }
]
```
