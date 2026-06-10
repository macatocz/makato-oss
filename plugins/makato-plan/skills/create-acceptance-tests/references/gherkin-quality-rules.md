# Gherkin Quality Rules

Rules for writing high-level acceptance test scenarios in makato-plan. These scenarios are manually testable, PO-readable, and serve as the acceptance gate before implementation.

---

## Core Conventions

- **Given** — precondition (world state before action)
- **When** — single triggering action by a named actor
- **Then** — observable outcome (what the user should see/experience)
- **And** — continuation of Then (never open a scenario with And)
- Each scenario is self-contained (no Background blocks)
- Then steps use "should" (e.g., "the user should see a confirmation")

---

## Anti-Patterns to Reject

### 1. Implementation Leaks
Steps mention APIs, endpoints, databases, SQL, functions, classes, file extensions, HTTP verbs, error codes, or internal component names.

**Fix**: Rewrite in business language describing what the user observes.

### 2. Generic Titles
Title contains "test", "check", "verify", "handle", "it should", "make sure", or is a single vague noun.

**Fix**: Rewrite as an outcome statement — what is true after the scenario.

### 3. Vague Language
Steps use "correct", "appropriate", "valid", "properly", "successfully", "as expected" without specifying what that means concretely.

**Fix**: Replace with the specific observable behavior.

### 4. Multiple Actions
Scenario has two or more When steps, or a When step uses "and" to chain actions.

**Fix**: Split into separate scenarios, each testing one behavior.

### 5. Over-Detailed Steps
Steps mention specific field names, exact API payloads, database columns, config keys, or environment variables.

**Fix**: Describe the user-level intent, not the system-level implementation.

### 6. Too Many Scenarios
More than 5 scenarios for a single story, or scenarios that test minor variations better suited to unit tests.

**Fix**: Keep 3-5 scenarios at the integration/acceptance level. Detailed variations belong in automated test suites during implementation.

---

## Title Conventions

Scenario titles must be outcome-focused and self-explaining:

| Context | Pattern | Example |
|---------|---------|---------|
| Happy path | `[Actor] [outcome] [context]` | "User sees pricing summary after adding items to cart" |
| Error/edge | `[Actor] [receives guidance] when [condition]` | "User should see an error when payment method is expired" |
| Idempotent | `[Action] [safely] [condition]` | "Re-submitting the form should not create duplicate entries" |

---

## Checklist (apply to every scenario)

- [ ] Title is outcome-focused (not action-phrased)
- [ ] No technical jargon in any step
- [ ] No vague words — concrete expected behavior only
- [ ] Self-contained (own Given steps, no Background dependency)
- [ ] Single When step (one action tested)
- [ ] Then uses "should"
- [ ] Manually testable by a PO in a demo
- [ ] Max 5 steps total
