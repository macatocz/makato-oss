# GitHub Issue Body Template

Use this template when rendering a story from `stories.json` into a GitHub Issue body.
Replace each `{{placeholder}}` with the corresponding story field value.

---

## Background

{{story.description.background}}

## Scope

{{story.description.scope}}

## Acceptance Scenarios

For each scenario in `story.description.successScenarios`, render as:

Title: **{{scenario.title}}**

```gherkin
Given {{scenario.given}}
When {{scenario.when}}
Then {{scenario.then}}
And {{scenario.and[0]}} (repeat for each and[] entry)
```

## Definition of Done

Render each item as a GitHub task list checkbox:

- [ ] {{dod item 1}}
- [ ] {{dod item 2}}

## Out of Scope

{{story.description.outOfScope — render as bullet list, or "None"}}

## Feature Toggle

- Already in place: {{story.description.featureToggle.alreadyInPlace}}
- New needed: {{story.description.featureToggle.newNeeded}}
- Name: {{story.description.featureToggle.name or "N/A"}}
- Default state: {{story.description.featureToggle.defaultState or "N/A"}}

## External Dependencies

{{story.externalDependencies — render each as "**Team:** description (status)", or "None"}}

## Shaping Artifacts

Omit any line where the artifact file does not exist in the spec folder:

- [PRD]({{prdUrl}})
- [Design]({{designUrl}})
- [Prototype]({{prototypeUrl}})

---

Published by makato-plan/publish
