# Question Identification Guide

Patterns for spotting ambiguities, missing information, and unclear acceptance criteria in change requests.

## Types of Questions

### 1. Ambiguous Language

Watch for vague words that mean different things to different people:

**Red flags:**
- "improve", "enhance", "better" — Better how? By what measure?
- "simple", "easy", "user-friendly" — From whose perspective?
- "should", "might", "could" — Is this required or optional?
- "relevant", "appropriate", "as needed" — Who decides?
- "soon", "quickly", "eventually" — What's the timeline?

**Question pattern:**
> "The request says [quote vague language]. What specifically does this mean? [Offer 2-3 concrete interpretations]"

**Example:**
> Request: "Make the form validation more user-friendly."
>
> Question: What specifically makes validation "more user-friendly"?
> - Show inline error messages as user types (real-time)?
> - Show all errors at once instead of one at a time?
> - Use plain language instead of technical error codes?
> - Highlight invalid fields visually?
> - Something else?

### 2. Missing Edge Cases

The happy path is described, but edge cases are not:

**Check for:**
- What if input is empty, null, or malformed?
- What if the user is not authenticated or not authorized?
- What if a dependent service is down or slow?
- What if the operation partially succeeds (some items saved, some failed)?
- What if the user does the action twice quickly (race condition)?
- What if the data is too large or exceeds limits?

**Question pattern:**
> "The request describes [happy path]. What should happen if [edge case]?"

**Example:**
> Request: "Add bulk delete button that deletes all selected items."
>
> Questions:
> - What if user selects 10,000 items? (Performance / timeout concerns)
> - What if some items are locked by another user? (Partial failure)
> - What if user has permission to delete some items but not others? (Mixed permissions)
> - Should there be an undo mechanism?

### 3. Unspecified Error Handling

The request describes behavior but not what happens when it fails:

**Check for:**
- What error message should the user see?
- Should the error be logged? Where?
- Should the user be able to retry?
- Should the system recover automatically?
- Should support be notified?

**Question pattern:**
> "What should happen when [operation] fails because [reason]?"

**Example:**
> Request: "Send email notification when account is deleted."
>
> Questions:
> - What if email send fails? (Retry? Block deletion? Proceed anyway?)
> - Should failure be visible to the user or silent?
> - What if user's email is invalid or bounces?

### 4. Missing Acceptance Criteria

The request describes a change but doesn't define "done":

**Check for:**
- How will we know if this works?
- What specific outcomes must be achieved?
- What should we test?
- What is in scope vs. out of scope?

**Question pattern:**
> "How do we verify [feature] works correctly? What are the success criteria?"

**Example:**
> Request: "Improve search performance."
>
> Questions:
> - What's the performance target? (Response time under 200ms? Handle 1000 QPS?)
> - Which search scenarios should improve? (All? Just common queries?)
> - How is performance measured? (P50? P95? P99?)

### 5. Conflicting Implications

The request implies multiple behaviors that might conflict:

**Check for:**
- Does this conflict with existing behavior elsewhere?
- Are there competing priorities (security vs. convenience, speed vs. accuracy)?
- Will this break existing workflows or integrations?

**Question pattern:**
> "The request says [A], but this seems to conflict with [B]. How should we resolve this?"

**Example:**
> Request: "Allow users to edit their submitted forms after submission."
>
> Question: This conflicts with the audit trail requirement that says "all submissions are immutable for compliance." Should we:
> - Create a new submission version (preserving the original)?
> - Allow edits but log every change?
> - Restrict editing to certain users or time windows?
> - Something else?

### 6. Missing UI/UX Details

The request describes functionality but not how the user interacts with it:

**Check for:**
- Where does this appear in the UI? (New page? Modal? Inline?)
- What is the exact wording of labels, buttons, messages?
- What happens on click/submit/cancel?
- Is there visual feedback (spinner, success state, error state)?

**Question pattern:**
> "Where in the UI does [feature] appear, and what does it look like?"

**Example:**
> Request: "Let users export their data."
>
> Questions:
> - Where is the export button/link? (Profile page? Settings? Account menu?)
> - What format? (CSV? JSON? PDF?)
> - Immediate download or async (email link when ready)?
> - What's included in the export? (All data? Just visible fields?)

### 7. Undefined Scope Boundaries

The request is open-ended without clear limits:

**Check for:**
- How far does this extend? (Just this screen? All related screens?)
- Does this apply to all users or specific roles?
- Does this affect mobile, web, API, all of them?
- Should this work for old data or just new data?

**Question pattern:**
> "Does [change] apply to [context A], [context B], or both?"

**Example:**
> Request: "Add filtering by date range."
>
> Questions:
> - Which screens get this filter? (Just the main list? Also reports? Search results?)
> - Should it filter data created in range, or modified in range, or both?
> - Does it apply retroactively to existing records?

### 8. Backward Compatibility and Versioning

The request describes a change without addressing compatibility with existing behavior, data, or integrations:

**Check for:**
- **Output format/schema compatibility:** Will this change the structure of API responses, data exports, or message formats?
- **API contract compatibility:** Do endpoint signatures, parameters, or response codes change? Will existing clients break?
- **Data migration needs:** Does existing data need to be transformed? Can old and new data coexist?
- **Version requirements:** Should this be behind a version flag? Does it require a major version bump?
- **Rollback considerations:** Can this change be safely reverted if needed?
- **Integration impact:** Will downstream systems or partners need to update their code?

**Question pattern:**
> "How should [change] handle compatibility with existing [contracts/data/integrations]?"

**Example:**
> Request: "Change user profile response to include new 'preferences' field as an object instead of flat fields."
>
> Questions:
> - Should we maintain the old flat fields for backward compatibility (e.g., v1 vs v2 API)?
> - Do existing clients expect the current format? Will they break?
> - Should this be opt-in (query parameter or version header)?
> - How do we migrate existing user preferences from flat to nested structure?
> - If we need to roll back, can the new structure be safely reverted?

## How to Ask Good Questions

### Structure

1. **Context** — Quote or reference the ambiguous part
2. **Problem** — Explain why it's unclear or what's missing
3. **Options** — Offer 2-3 concrete interpretations (makes it easy to answer)
4. **Impact** — Explain why this matters (helps prioritize answering)

### Example

> **Context:** The request says "notify relevant users when status changes."
>
> **Problem:** "Relevant users" is not defined.
>
> **Options:**
> - All users who have viewed this item?
> - Users assigned to this item?
> - Users subscribed to notifications for this item?
> - Admins only?
>
> **Impact:** Determines how we query users (performance) and whether we need a new subscription system.

## Prioritizing Questions

### Critical (Block Design)
- Missing business logic rules
- Undefined core behavior
- Conflicts with existing features

### Important (Block Implementation)
- Missing error handling
- Undefined edge cases
- Missing UI/UX details

### Nice to Have (Can Make Assumptions)
- Minor wording preferences
- Optional enhancements mentioned in passing
- "Nice to have" features

In the analysis artifact, label question priority so stakeholders know what must be answered vs. what can be deferred.
