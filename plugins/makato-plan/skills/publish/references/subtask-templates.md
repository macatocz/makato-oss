# Subtask Templates

> The 4 standard DCP subtasks created per story. Load at Step 9 when creating subtasks. Each type has different content — apply the correct template per subtask type.
>
> NOTE: Content is pre-populated at publish time. The makato-build `refine` skill may enrich these further during sprint planning.

## 1. Implementation

**Summary**: `Implementation`

**Description**: Empty. The parent story's scope and solution approach sections provide implementation guidance. Teams fill in details during refinement.

```jira
```

---

## 2. QA Verification

**Summary**: `QA Verification`

**Description**: Pre-populated with acceptance criteria from the parent story's success scenarios and acceptance test cases as a numbered checklist.

```jira
h2. Expected Results

# {successScenario[0].title}: {then clause}
# {successScenario[1].title}: {then clause}
# {acceptanceTestCase[0].title}: {then clause}
...

----

h2. Test Evidence

_To be filled during QA verification with screenshots and observations._
```

### Rendering rules:
- Each `successScenario` becomes a numbered item with its title and expected outcome (the `then` clause)
- Each `acceptanceTestCase` (if present) appended the same way
- If neither exist, use the story's `definitionOfDone` items instead

---

## 3. Documentation

**Summary**: `Documentation`

**Description**: Pre-populated with links to shaping artifacts and Confluence page.

```jira
h2. Specification Documents

* [Confluence Spec Page|{confluencePageUrl}]
* [PRD|{gitUrl}/blob/{branch}/specs/{folder}/prd.md]
* [Design|{gitUrl}/blob/{branch}/specs/{folder}/design.md]

----

h2. Wiki Documentation

_To be filled by Team_
```

### Rendering rules:
- Only include links for artifacts that actually exist
- Confluence link included only after Step 13 creates the page (update subtask if needed)
- If no artifacts exist at all, leave description empty (DCP convention)

---

## 4. Automate acceptance test cases

**Summary**: `Automate acceptance test cases`

**Description**: Pre-populated with test automation instructions and Gherkin scenarios from the parent story.

```jira
h2. Test Automation

*Instructions:*
* Prefer unit/integration tests over UI-driven tests
* Add test case IDs (@DCPAT-XXXX) into code for traceability
* Tests must run stable (3x in sequence for BDD tests) before closing

*Closure Criteria:*
* All acceptance test cases automated
* Tests running stable in CI/CD pipeline
* XRAY test cases updated with automation status

----

h2. Test Cases

*Test References:*
TBD - to be created

*Scenarios:*

{noformat}
Scenario: {successScenario[0].title}
  Given {given}
  When {when}
  Then {then}

Scenario: {successScenario[1].title}
  Given {given}
  When {when}
  Then {then}
{noformat}

----

h2. Tests to Obsolete

None
```

### Rendering rules:
- All `successScenarios` from the parent story rendered as Gherkin in `{noformat}` block
- All `acceptanceTestCases` (if present) appended after success scenarios
- If neither exist, include only the instructions header with "TBD" for scenarios
