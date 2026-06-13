# Requirements Comparison Pattern

Template for creating side-by-side comparisons of current vs. requested behavior.

## Table Format

Use a three-column markdown table:

| Aspect | Current Behavior | Requested Changes |
|--------|------------------|-------------------|
| ... | ... | ... |

## What to Compare

Break the feature into functional aspects. Each row should cover one distinct piece of behavior.

### Example Aspects

- **User Action** — What the user can do
- **Input Validation** — What rules are enforced
- **Business Logic** — What calculations or decisions happen
- **Data Persistence** — What is saved and where
- **Output/Response** — What the user sees or receives
- **Error Handling** — What happens when things go wrong
- **Permissions** — Who can do what
- **Side Effects** — What else changes (notifications, logs, related records)

## Writing Good Comparisons

### Current Behavior Column

Describe what the system **actually does now**, not what it was supposed to do:
- Be specific (name actual fields, buttons, messages)
- Include constraints (validation rules, permissions)
- Note implicit behavior (things that just happen)

**Good:**
> "User clicks 'Submit' button. Form validates email format. If valid, saves to `users` table and shows success toast. No confirmation dialog."

**Bad:**
> "User submits form and it works."

### Requested Changes Column

Describe what **should happen after the change**:
- Focus on the difference (what changes, not what stays the same)
- Be explicit about new behavior
- Call out what is added, modified, or removed

**Good:**
> "Add confirmation dialog before save. Dialog shows: 'Are you sure? This will notify all team members.' Buttons: Cancel / Confirm. On Confirm, proceed with save + toast."

**Bad:**
> "Add confirmation."

## Highlighting the Gap

After the table, add a **Gap Analysis** section listing things the request doesn't address:

### Missing Information
- Edge cases not covered
- Error scenarios not specified
- Validation rules unclear

### Example

```markdown
## Gap Analysis

The request doesn't specify:
- What happens if the user clicks Cancel in the confirmation dialog? (Stay on form? Clear form? Navigate away?)
- Should the dialog appear for all users or only non-admins?
- What if the notification send fails? (Retry? Show error? Proceed anyway?)
```

## Scope of Comparison

**Include:**
- All behavior that will change
- Related behavior that might be affected
- Dependencies that constrain the change

**Exclude:**
- Unrelated features (even if in same file)
- Implementation details (unless they create constraints)
- Hypothetical future changes not in this request

## Example Comparison

| Aspect | Current Behavior | Requested Changes |
|--------|------------------|-------------------|
| **User Action** | User clicks "Delete Account" button in profile settings. | Same trigger, but add intermediate step. |
| **Confirmation** | No confirmation. Deletion happens immediately. | Show modal dialog: "Delete your account? This cannot be undone." Buttons: Cancel / Delete Account (red). |
| **Validation** | No checks. Any user can delete their own account. | Add check: prevent deletion if user is the last admin. Show error: "Cannot delete account — you are the only admin. Promote another user first." |
| **Side Effects** | Deletes user record from `users` table. Orphans related records (comments, posts). | Same deletion, but also: (1) anonymize user's comments (replace name with "Deleted User"), (2) send email to user confirming deletion. |
| **Error Handling** | If DB delete fails, shows generic error: "Something went wrong." | If DB fails, show: "Could not delete account. Please try again or contact support." If email send fails, proceed anyway but log warning. |

### Gap Analysis

The request doesn't specify:
- Should the confirmation dialog mention that comments will be anonymized?
- What happens to posts? (Anonymize? Delete? Not mentioned.)
- Should there be a "grace period" where deletion can be undone?
- What if the user navigates away from the dialog without choosing? (Treat as Cancel?)

## When Behavior is Ambiguous

If the request is unclear, make your best interpretation in the "Requested Changes" column, then flag it in the Gap Analysis:

**In table:**
> "Show confirmation dialog (exact wording not specified)."

**In Gap Analysis:**
> "Request doesn't provide dialog title, body text, or button labels. Suggested wording shown in comparison."

This makes your assumptions explicit and highlights what needs stakeholder input.
