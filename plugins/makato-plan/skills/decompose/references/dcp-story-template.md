# DCP Story Description Template

## Jira Wiki Markup Rendering

When stories.json is published to Jira, each story's description fields render into this panel structure:

```
{panel:title=Background|borderColor=#f1f9fc|titleBGColor=#f1f9fc|bgColor=#f9fcfe}
{{background}}
{panel}
{panel:title=Scope|borderColor=#e1f1fc|titleBGColor=#e1f1fc|bgColor=#f3f8fe}
{{scope}}
{panel}
{panel:title=Dependencies|borderColor=#ffdde7|titleBGColor=#ffdde7|bgColor=#ffe9ef}
{{externalDependencies rendered as bullet list, or "N/A"}}
{panel}
{panel:title=Feature Toggle|borderColor=#e6e0f8|titleBGColor=#e6e0f8|bgColor=#f3f0fb}
 - Feature Toggle already in place: {{alreadyInPlace}}
 - New Feature Toggle needed: {{newNeeded}}
 - Feature Toggle longterm usage: {{longTermUsage}}
 - Name of feature toggle: {{name}}
 - Feature Toggle Default State: {{defaultState}}
{panel}
{panel:title=Success Scenario|borderColor=#f2fae1|titleBGColor=#f2fae1|bgColor=#f6fde9}
{{successScenarios rendered as Gherkin}}
{panel}
{panel:title=Solution Approach|borderColor=#faead9|titleBGColor=#faead9|bgColor=#fdeee3}
{color:#4c9aff}to be filled by Architect or Team{color}
{{solutionApproach or empty}}
{panel}
{panel:title=Acceptance Test Cases|borderColor=#f2fae1|titleBGColor=#f2fae1|bgColor=#f6fde9}
{noformat}
Once the business requirements are described, add label "QARefinement" so that QAs can start to define test cases for automation.
{noformat}
{{acceptanceTestCases or empty}}
{panel}
{panel:title=Wiki documentation|borderColor=#f1f9fc|titleBGColor=#f1f9fc|bgColor=#f9fcfe}
{color:#4c9aff}to be filled by Team{color}
{{wikiDocumentation or empty}}
{panel}
{panel:title=Out of Scope|borderColor=#f7f7f7|titleBGColor=#f7f7f7|bgColor=#fbfbfb}
{{outOfScope items as bullet list, or "N/A"}}
{panel}
```

## Panel Color Conventions

| Panel | Border/Title BG | Purpose |
|-------|----------------|---------|
| Background | Light blue (#f1f9fc) | Context and rationale |
| Scope | Medium blue (#e1f1fc) | What to build |
| Dependencies | Pink (#ffdde7) | External blockers — attention-drawing |
| Feature Toggle | Purple (#e6e0f8) | Toggle configuration |
| Success Scenario | Light green (#f2fae1) | Gherkin acceptance |
| Solution Approach | Orange (#faead9) | Technical approach (filled later) |
| Acceptance Tests | Light green (#f2fae1) | Detailed test cases (filled later) |
| Wiki | Light blue (#f1f9fc) | Documentation links (filled later) |
| Out of Scope | Gray (#f7f7f7) | Explicit exclusions |

## What Decompose Fills vs. What's Deferred

| Section | Filled by Decompose | Notes |
|---------|---|---|
| Background | Yes | Why this story exists |
| Scope | Yes | Bounded description of what to build |
| Dependencies | Yes | External team dependencies |
| Feature Toggle | Yes | At minimum newNeeded yes/no |
| Success Scenario | Yes (draft) | 1-3 high-level Gherkin from QA agent |
| Solution Approach | No | Left empty — team fills during refinement |
| Acceptance Tests | No | Left empty — QAs fill via acceptance-tests skill |
| Wiki | No | Left empty — team fills post-implementation |
| Out of Scope | Yes | Explicit boundaries |

## Gherkin Rendering

Success scenarios render as:

```
*Scenario 1: Happy path*
Given ...
When ...
Then ...

*Scenario 2: Edge case*
Given ...
When ...
Then ...
```
