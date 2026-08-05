# GitHub Issues Design Update Format

Structure and tone for posting technical design/solution approach back to GitHub Issues as comments.

**IMPORTANT**: GitHub Issues renders **Markdown**, not Jira Wiki Markup. Never use Jira
syntax (`h2.`, `h3.`, `{{text}}`, `*bold*`, `#` list prefix) — it renders as raw literal
characters and produces visually broken comments for every reader.

## Tone

- **Technical but accessible** — You're updating both engineers and stakeholders
- **Solution-focused** — Lead with the approach, then supporting detail
- **Confidence without arrogance** — State the plan clearly, acknowledge risks

Avoid:
- Overly detailed implementation minutiae (save for the design artifact)
- Uncertainty hedging ("maybe", "possibly", "I think")
- Jargon without context (define technical terms if PO/QA will read)

## Comment Structure

Use this template. All syntax is standard GitHub Markdown:

```markdown
## Technical Design

**Files Affected:** <count>

### Solution Approach
[2-3 sentences: how the change will be implemented, high-level strategy]

### Key Changes
- [Bullet point 1]
- [Bullet point 2]
- [Bullet point 3]

### Implementation Steps
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Risks
[Bulleted list using `-` if any, or "None identified"]

**Estimated time:** <minutes/hours>

---
Full design: `specs/<ISSUE-KEY>/design.md`
```

**GitHub Markdown syntax reference:**
- Headers: `##`, `###`, `####` (NOT `h2.`, `h3.`)
- Bold: `**text**` (NOT `*text*`)
- Numbered lists: `1.`, `2.`, `3.` (NOT `#` at line start)
- Bulleted lists: `-` or `*` at line start
- Horizontal rule: `---` (NOT `----`)
- Inline code/monospace: `` `text` `` (NOT `{{text}}`)

## Section Guidelines

### Files Affected

State the count upfront so readers understand the scope:

**Format (count only, when many files):**
```
**Files Affected:** 6 (3 source, 3 test)
```

**Format (with list, when ≤4 files):**
```markdown
**Files Affected:** 4
- `src/components/UserProfile.tsx`
- `src/services/userService.ts`
- `tests/UserProfile.test.tsx`
- `tests/userService.test.ts`
```

### Solution Approach

Summarize the design in 2-3 sentences:

1. What the solution does (user perspective)
2. How it's structured (technical perspective)
3. Why this approach (rationale, if not obvious)

**Example:**
> The solution adds a confirmation dialog before account deletion and validates that the user
> is not the last admin. The backend implements the validation logic in `userService`, returning
> a 403 error if blocked. The frontend displays a modal dialog on delete button click, calls
> the service, and handles success or error states.

### Key Changes

Highlight the most important modifications. Keep to 3-5 bullets.

**Format:**
```markdown
- **What changes** — Why (if not obvious)
```

**Example:**
```markdown
- **Backend validation** — Prevent deletion if user is last admin (business rule)
- **Confirmation dialog** — New modal component to confirm action before proceeding
- **Delete button** — Added to user profile settings, triggers dialog on click
- **Error handling** — Toast notifications for success/failure scenarios
```

### Implementation Steps

List the major phases (not exhaustive tasks). Match the implementation plan from the design artifact.

**Keep it high-level:**

Good:
```markdown
1. Implement backend validation
2. Create confirmation dialog UI
3. Wire delete flow (button → dialog → API)
4. Add tests
5. Verify end-to-end
```

Too detailed (save for design artifact):
```markdown
1. Add `isLastAdmin()` function
2. Call `isLastAdmin()` in `deleteAccount()`
3. Throw ValidationError if true
4. Create `DeleteAccountDialog.tsx` file
...
```

Engineers can read the design artifact for detail. The GitHub issue comment should be scannable.

### Risks

Be honest about unknowns and blockers.

**If no risks:**
```
None identified — implementation is straightforward.
```

**If risks exist:**
```markdown
- **Auth permissions unclear:** Need to verify users can delete their own accounts via API.
  Will test early in Step 3.
- **Migration on large table:** `users` table has 10M+ rows. Schema change might timeout.
  Will test on staging first.
```

Don't sugarcoat, but do include mitigation plans if you have them.

## Labeling

After posting the comment, add label `makato-change-designed` to the issue. This signals:
- Design is complete
- Implementation can begin
- Stakeholders can review the approach

Use:
```bash
gh issue edit <ISSUE_NUMBER> --add-label "makato-change-designed"
```

## When to Tag People

**Do tag:**
- The issue assignee (if they'll implement and it's not you)
- Technical lead or architect (if design involves architectural decisions)
- QA engineer (if there are testability concerns)

**Don't tag:**
- Large groups
- People just watching for awareness
- Product owner (unless design affects business logic decisions)

**How to tag in GitHub Issues:** Use `@username` in Markdown comments.

## Link to Full Design

Always end with the artifact path:

```markdown
---
Full design: `specs/PROJ-1234/design.md`
```

This gives engineers the full detail without cluttering the GitHub issue comment.

## Example Full Comment

```markdown
## Technical Design

**Files Affected:** 6 (3 source, 3 test)

### Solution Approach

The solution adds a confirmation dialog before account deletion and validates that the user
is not the last admin. The backend implements the validation logic in `userService`, returning
a 403 error if deletion is blocked. The frontend displays a modal dialog on delete button
click, calls the service, and handles success or error states with toast notifications.

### Key Changes

- **Backend validation** — Prevent deletion if user is last admin (returns 403 with error message)
- **Confirmation dialog** — New `DeleteAccountDialog` component with warning text and Cancel/Confirm buttons
- **Delete button** — Added to user profile settings section, triggers dialog on click
- **Error handling** — Toast notifications for success (account deleted) and failure (last admin, network error)
- **Test coverage** — Unit tests for dialog and service logic, integration test for full flow

### Implementation Steps

1. Implement backend validation (`isLastAdmin()` check, throw error if blocked)
2. Create confirmation dialog UI component
3. Wire delete flow (button → dialog → API call → success/error handling)
4. Add/update tests (unit + integration)
5. Verify end-to-end in local environment

### Risks

- **Auth permissions unclear:** Need to verify users can delete their own accounts via API.
  Will test early in Step 3 and escalate if blocked.

**Estimated time:** 3 hours

---
Full design: `specs/PROJ-1234/design.md`
```

## Technical Detail Balance

**Too much detail** (avoid):
> The `DeleteAccountDialog` component will be a functional React component using TypeScript.
> It will accept props: `isOpen`, `onClose`, and `onConfirm`. The dialog will use the `Modal`
> component from our UI library styled with Tailwind...

This is implementation detail that belongs in the design artifact, not the issue comment.

**Right amount** (do this):
> The solution adds a confirmation dialog before account deletion using a new
> `DeleteAccountDialog` component. The dialog displays a warning message and provides
> Cancel/Confirm buttons.

## Updating an Existing Design Comment

If the design changes based on feedback, edit the original comment (GitHub allows edits) or
post a new comment:

```markdown
## Updated Technical Design

**Change:** [What changed and why]

[Rest of template]
```

GitHub preserves comment edit history so changes are tracked. If you can't edit (permissions),
post a new comment and note "Updated design" at the top.
