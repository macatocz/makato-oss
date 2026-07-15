# Technical Design: <issue-key>

**Issue**: <issue-key> — <issue-summary>
**Analysis**: `specs/<issue-key>/analysis.md`
**Designed**: <date>

---

## Overview

<1-2 paragraph summary of the design approach>

**Scope confirmation:** <Small|Medium> (from analysis)

**Prerequisites resolved:** <Yes — all critical questions answered | Partial — see notes>

---

## Affected Files

<List all files that will be modified or created, organized by category>

### Source Files (Modified)

- **`<file-path>`**
  **Role:** <what this file does>
  **Changes:** <what will be modified>

- **`<file-path>`**
  **Role:** <what this file does>
  **Changes:** <what will be modified>

### Source Files (New)

- **`<file-path>`**
  **Purpose:** <why this new file is needed>
  **Contents:** <what it will contain>

### Test Files (Modified)

- **`<file-path>`**
  **Changes:** <what test updates are needed>

### Test Files (New)

- **`<file-path>`**
  **Purpose:** <what this will test>

### Configuration / Schema

- **`<file-path>`**
  **Changes:** <config or schema updates>

---

## Solution Approach

<Detailed description of how the change will be implemented>

### What Will Be Modified

<For each existing component/function that needs changes, describe the modification>

**Component: `<name>`**
- Current behavior: <what it does now>
- Change needed: <what will change>
- Why: <reason for the change>

**Function: `<name>`**
- Current: <what it does now>
- Change: <what will change>
- Why: <reason>

### What Will Be Added

<For each new component/function/element, describe what's being created>

**New Component: `<name>`**
- Purpose: <why this is needed>
- Location: <where it will live>
- Details:
  - <detail 1>
  - <detail 2>

**New Function: `<name>`**
- Purpose: <why this is needed>
- Signature: `<function-signature>`
- Behavior: <what it does>
- Location: <where it will live>

### Supporting Components

<Small new elements like buttons, dialogs, validation rules, error messages>

**New UI Elements:**
- Button: "<label>" — <where, what it does>
- Dialog: "<name>" — <purpose, buttons, behavior>
- Form field: "<name>" — <type, validation>

**New Validation Rules:**
- Rule: <description>
- Where enforced: <frontend/backend/both>
- Error message: "<message>"

**New Error Messages:**
- Scenario: <when this appears>
- Message: "<user-facing text>"

### Patterns to Follow

<Existing code patterns that this solution must match>

**Naming Conventions:**
- Functions: <pattern> (e.g., camelCase, verb + noun)
- Components: <pattern> (e.g., PascalCase, noun-based)
- Files: <pattern>

**Error Handling:**
- <describe existing error handling pattern in the codebase>
- <how new code will match this pattern>

**Testing Approach:**
- <describe existing test patterns>
- <how new tests will match>

### Edge Cases and Error Handling

<For each edge case identified in analysis, describe how it will be handled>

**Edge Case: <description>**
- Current behavior: <what happens now, or N/A>
- Desired behavior: <what should happen>
- Implementation:
  - <step 1>
  - <step 2>

**Error Scenario: <description>**
- What fails: <what goes wrong>
- User sees: "<error message>"
- System behavior: <rollback/proceed/retry>
- Logging: <what gets logged>

---

## Implementation Plan

<High-level roadmap showing major phases of work>

### Step 1: <Phase Name>

**What:** <what gets done in this step>
**Output:** <what exists after this step>
**Depends on:** <previous step, or "None">
**Risk:** <risks, or "None">

### Step 2: <Phase Name>

**What:** <what gets done>
**Output:** <deliverable>
**Depends on:** <dependency>
**Risk:** <risks, or "None">

### Step 3: <Phase Name>

**What:** <what gets done>
**Output:** <deliverable>
**Depends on:** <dependency>
**Risk:** <risks, or "None">

---

### Step N: Verify End-to-End

**What:** Manual testing in local environment
**Output:** Confirmed working implementation
**Depends on:** All above steps
**Risk:** None

---

## Test Strategy

<Plan for test coverage>

### Update Existing Tests

**Test file:** `<path>`
**Test case:** "<name>"
**Change needed:** <what assertion or behavior changes>
**Why:** <reason>

### Add New Tests

**Test file:** `<path>` (new)
**Test cases:**
- "<test case 1>" — <what it verifies>
- "<test case 2>" — <what it verifies>
- "<test case 3>" — <what it verifies>

**Test file:** `<path>`
**New test cases:**
- "<test case>" — <what it verifies>

### Test Data / Fixtures

<What test data is needed>

- Fixture: <description> (e.g., "Test user — non-admin")
- Mock: <description> (e.g., "API response for DELETE /users/:id success")

### Integration Test Coverage

<If integration tests exist, what to add>

**Integration test:** "<name>"
**Steps:**
1. <step 1>
2. <step 2>
3. <step 3>

**Assertions:**
- <assertion 1>
- <assertion 2>

---

## Risks and Mitigation

<Known risks and how to handle them>

### Risk: <description>

**Impact:** <what happens if this risk materializes>
**Likelihood:** <High/Medium/Low>
**Mitigation:** <how to reduce or handle>

### Risk: <description>

**Impact:** <what happens>
**Likelihood:** <High/Medium/Low>
**Mitigation:** <mitigation plan>

---

## Dependencies

<External dependencies or blockers>

### Technical Dependencies

- <dependency 1> — <why needed>
- <dependency 2> — <why needed>

### Team Dependencies

- Waiting on: <team/person> for <what>
- Blocker: <description>

---

## Notes

<Any additional context, observations, or decisions not covered above>

### Design Decisions

**Decision:** <what was decided>
**Rationale:** <why>
**Alternatives considered:** <what else was considered, why rejected>

### Open Questions (If Any)

**Question:** <what's still unclear>
**Impact:** <how this affects implementation>
**Who can answer:** <stakeholder>

---

## Approval

**User approved:** <Yes/No/Pending>
**Approval date:** <date, if approved>
**Changes requested:** <if any>

---

## Recommended Skills

<!--
  Populated by the `design` skill Step 4.5 inject-skills resolver.
  Only present when the resolver returns a non-empty list for the affected-file set.
  The `execute` skill Step 2.1 reads this section and forwards the list to
  `change-implementer` as RECOMMENDED_SKILLS.
  Omit this section entirely when the list is empty — do NOT write an empty array.
-->

- <skill-id-1>
- <skill-id-2>
