# Change Request Analysis: <jira-key>

**Issue**: <jira-key> — <issue-summary>  
**Type**: <Story|Task>  
**Status**: <current-status>  
**Analyzed**: <date>

---

## Overview

<1-2 paragraph summary of what this change request is about>

---

## Requirements

<Extract key requirements from the Jira issue. Quote directly when helpful. Break into logical sections if complex.>

### Summary
<Brief restatement of what the issue requests>

### Acceptance Criteria
<List acceptance criteria from Jira, or note if missing>

### Additional Context
<Any relevant comments, attachments, or background from the issue>

---

## Current Behavior

<Describe how the feature works now. Focus on what's observable (user perspective) and how it's implemented (code perspective).>

### User Perspective
<What the user experiences now>

### Implementation
<Key files, functions, data flow. Enough detail for the design skill to understand constraints.>

**Key Files:**
- `<file-path>` — <role>
- `<file-path>` — <role>

**Constraints:**
- <Validation rules>
- <Permissions>
- <Dependencies>

**Edge Cases Handled:**
- <Boundary conditions>
- <Error scenarios>

---

## Requested Changes

<Describe what should happen after the change. Be explicit about what's added, modified, or removed.>

### Functional Changes
<What behavior changes from the user's perspective>

### Technical Changes
<What code/config/data changes are implied>

---

## Comparison: Current vs. Requested

<Side-by-side table showing the differences. Use the pattern from requirements-comparison-pattern.md>

| Aspect | Current Behavior | Requested Changes |
|--------|------------------|-------------------|
| <aspect-1> | <current> | <requested> |
| <aspect-2> | <current> | <requested> |
| <aspect-3> | <current> | <requested> |

### Gap Analysis

<List things the request doesn't address: edge cases, error handling, validation details, etc.>

---

## Open Questions

<List ambiguities and missing information that need stakeholder input. Use the patterns from question-identification-guide.md>

### Critical (Block Design)
<Questions that must be answered before technical design can proceed>

1. **<Question>**
   - Context: <what's unclear>
   - Impact: <why this matters>
   - Options: <possible interpretations>
   - Who can answer: <stakeholder>

### Important (Block Implementation)
<Questions that can be deferred until design, but must be resolved before coding>

1. **<Question>**
   - ...

### Nice to Have
<Questions that can be answered with reasonable assumptions if stakeholders don't respond>

1. **<Question>**
   - Assumption if no answer: <reasonable default>

---

## Inconsistencies

<List conflicts, risks, or problems that must be resolved>

### Internal Contradictions
<Places where the request conflicts with itself>

- **<Conflict>**: <description>
  - Impact: <what breaks>
  - Resolution: <suggested fix>

### System Conflicts
<Places where the request conflicts with existing features or constraints>

- **<Conflict>**: <description>
  - Impact: <what breaks>
  - Resolution: <suggested fix>

### Technical Risks
<Performance, security, scalability concerns>

- **<Risk>**: <description>
  - Impact: <what could go wrong>
  - Mitigation: <how to address>

---

## E2E Test Impact

<Document E2E test scenarios that will be affected by this change>

### E2E Tests Found

<"Yes" or "No — confirmed with user that no E2E tests exist">

### Affected Scenarios

**If E2E tests were found:**

<List scenarios that need updates:>

1. **<Scenario ID or name>** (`<file-path>`)
   - Current behavior: <what the test validates now>
   - Required change: <what needs to be updated>
   - Type: <assertions | steps | expected outcomes | test data>

2. **<Scenario ID or name>** (`<file-path>`)
   - ...

**If NO E2E tests found:**

> No E2E test coverage detected for this functionality. Confirmed with user in Step 3 discovery.

### New Scenarios Needed

<List if new E2E scenarios should be created for new workflows introduced by this change>

- <New scenario 1>
- <New scenario 2>

Or: "No new E2E scenarios needed — change is covered by existing test updates"

Or: "No E2E scenarios needed — no E2E test infrastructure exists"

---

## Scope Estimate

**Classification**: <Small|Medium|Large>

### File Count Estimate
- Source files to modify: <count>
- New files to create: <count>
- Test files to change/add: <count>
- Total: <count>

### Architectural Impact
<Isolated | Cross-cutting (shallow) | Cross-cutting (deep) | New subsystem>

<Describe how deeply this cuts across the system>

### New Components
<List new code artifacts needed: functions, components, services, tables, etc.>

- <component-1>
- <component-2>

### Test Impact
<Adjust existing tests | Write new + adjust | Design new test strategy>

<Describe test work required>

### Uncertainties
<List unknowns that affect confidence in the estimate>

- <uncertainty-1>
- <uncertainty-2>

### Justification
<Explain why this scope classification was chosen. Reference the criteria from scope-estimation-criteria.md>

---

## Recommendation

<Clear next step based on the analysis>

### If Small/Medium and Clear
> Requirements are clear and scope fits makato-change. **Next step**: Proceed to design skill to plan technical implementation.

### If Questions Block Progress
> Open questions (see above) must be answered before design can proceed. **Next step**: Get stakeholder input, then proceed to design.

### If Scope is Large
> This change is too large for makato-change. **Next step**: Escalate to makato-plan workflow for discovery and decomposition.
> 
> **Reason**: <why this needs architecture/discovery — new subsystem, multiple teams, significant unknowns, etc.>

---

## Notes

<Any additional context, observations, or concerns not covered above>
