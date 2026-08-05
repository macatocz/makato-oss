# spec-delta.md Template

A `spec-delta.md` file captures the precise set of requirements that change between the
current specification and the desired target state. It is the source-of-truth input for the
`makato-change` design skill: the skill reads this file to discover what must be added,
modified, removed, or renamed before it plans any code changes. Each requirement is expressed
as a named third-level heading (`### <Requirement Name>`), a mandatory **SHALL**: statement
that describes the new obligation in present tense, and an optional **Scenario**: block
(Given/When/Then) that pins down the acceptance criteria in executable form. Keep entries
atomic — one behavioral change per entry — so the design skill can map each delta to a
minimal, independently reviewable code change.

---

## ADDED Requirements

<!-- List every new requirement that does not exist in the current implementation.
     Use one ### heading per requirement. The name should match the feature or rule
     you are introducing. The **SHALL**: statement is mandatory; the **Scenario**:
     block is optional but recommended for behavioral changes. -->

<!--
### <Requirement Name>

**SHALL**: <concise present-tense statement of the new obligation, e.g.
"The system SHALL validate the `email` field against RFC 5321 before persisting a record.">

**Scenario**: <short title>
  Given <precondition>
  When  <action or event>
  Then  <expected outcome>
  And   <additional outcome, if needed>
-->

---

## MODIFIED Requirements

<!-- List every requirement whose behavior changes relative to the current implementation.
     Describe the new behavior in the **SHALL**: statement; the design skill infers the
     old behavior from the existing codebase. -->

<!--
### <Requirement Name>

**SHALL**: <updated present-tense statement of what the requirement now demands,
e.g. "The system SHALL apply a 30-second timeout (previously 10 seconds) to all
outbound HTTP calls made by the integration adapter.">

**Scenario**: <short title>
  Given <precondition>
  When  <action or event>
  Then  <expected outcome under the new behavior>
-->

---

## REMOVED Requirements

<!-- List every requirement that the current implementation satisfies but that must
     be removed from the system. The **SHALL**: statement should name the obligation
     that is being retired so that the design skill can locate and delete the
     corresponding code, tests, and documentation. -->

<!--
### <Requirement Name>

**SHALL**: no longer <statement of the obligation being retired, e.g.
"The system SHALL no longer expose the legacy `/v1/search` endpoint.">

**Scenario**: <short title>
  Given the legacy endpoint existed
  When  a request is made to the retired path
  Then  the system SHALL return 404 or redirect, not the former response
-->

---

## RENAMED Requirements

<!-- List every requirement whose name changes but whose behavior is preserved.
     Renames are tracked separately so the design skill can update identifiers,
     symbols, labels, and documentation strings without accidentally modifying logic. -->

<!--
### <Old Requirement Name> → <New Requirement Name>

**SHALL**: be renamed from `<OldName>` to `<NewName>` with no change to observable
behavior. All occurrences in code, tests, configuration, and documentation MUST be
updated atomically.

**Scenario**: rename is transparent to callers
  Given a caller that previously referenced `<OldName>`
  When  the rename is applied
  Then  the caller's interaction produces identical results under `<NewName>`
-->
