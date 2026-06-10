# DCP Story Description Panels

> Exact Jira wiki markup panel structure for story descriptions. Load at Step 8 when rendering story descriptions.

## Complete Panel Structure

```jira
{panel:title=Background|borderColor=#f1f9fc|titleBGColor=#f1f9fc|bgColor=#f9fcfe}
{background text}
{panel}
{panel:title=Scope|borderColor=#e1f1fc|titleBGColor=#e1f1fc|bgColor=#f3f8fe}
{scope text}
{panel}
{panel:title=Dependencies|borderColor=#ffdde7|titleBGColor=#ffdde7|bgColor=#ffe9ef}
{externalDependencies as bullet list, or "N/A"}
{panel}
{panel:title=Feature Toggle|borderColor=#e6e0f8|titleBGColor=#e6e0f8|bgColor=#f3f0fb}
If `featureToggle.name` is empty, render exactly:
 - Not applicable
Otherwise render all 5 lines:
 - Feature Toggle already in place: {alreadyInPlace}
 - New Feature Toggle needed: {newNeeded}
 - Feature Toggle longterm usage: {longTermUsage}
 - Name of feature toggle: {name}
 - Feature Toggle Default State: {defaultState}
{panel}
{panel:title=Success Scenario|borderColor=#f2fae1|titleBGColor=#f2fae1|bgColor=#f6fde9}
{successScenarios rendered as Gherkin — see below}
{panel}
{panel:title=Solution Approach|borderColor=#faead9|titleBGColor=#faead9|bgColor=#fdeee3}
{color:#4c9aff}to be filled by Architect or Team{color}
{solutionApproach or empty}
{panel}
{panel:title=Acceptance Test Cases|borderColor=#f2fae1|titleBGColor=#f2fae1|bgColor=#f6fde9}
{noformat}
Once the business requirements are described, add label "QARefinement" so that QAs can start to define test cases for automation.
{noformat}
{acceptanceTestCases rendered as Gherkin, or empty}
{panel}
{panel:title=Wiki documentation|borderColor=#f1f9fc|titleBGColor=#f1f9fc|bgColor=#f9fcfe}
{color:#4c9aff}to be filled by Team{color}
{wikiDocumentation or empty}
{panel}
{panel:title=Out of Scope|borderColor=#f7f7f7|titleBGColor=#f7f7f7|bgColor=#fbfbfb}
{outOfScope items as bullet list, or "N/A"}
{panel}
{panel:title=Definition of Done|borderColor=#e3fcef|titleBGColor=#e3fcef|bgColor=#f1fdf6}
{definitionOfDone items as bullet list}
{panel}
{panel:title=Shaping Artifacts|borderColor=#deebff|titleBGColor=#deebff|bgColor=#f0f7ff}
{links to PRD, Design, Prototype — only those that exist}
{panel}
```

## Gherkin Rendering

Success scenarios and acceptance test cases render as:

```jira
*Scenario 1: {title}*
Given {given}
When {when}
Then {then}
And {and[0]}
And {and[1]}

*Scenario 2: {title}*
Given {given}
When {when}
Then {then}
```

The `and[]` field is optional. Emit one `And {item}` line per entry directly after the `Then` line. Omit the And lines entirely when `and[]` is missing or empty.

## External Dependencies Rendering

```jira
* *{team}*: {description} (Status: {status})
```

Or "N/A" if empty.

## Out of Scope Rendering

```jira
* {item 1}
* {item 2}
```

Or "N/A" if empty.

## Definition of Done Rendering

```jira
* {dod item 1}
* {dod item 2}
* {dod item 3}
```

## Shaping Artifacts Rendering

Only include links for artifacts that actually exist in the spec folder:

```jira
* [PRD|{gitUrl}/blob/{branch}/specs/{folder}/prd.md]
* [Design|{gitUrl}/blob/{branch}/specs/{folder}/design.md]
* [Prototype|{gitUrl}/blob/{branch}/specs/{folder}/prototype.html]
```
