# GitHub Issues Design Update Format

Structure and tone for posting technical design/solution approach back to GitHub Issues as comments.

**IMPORTANT**: GitHub Issues uses Wiki Markup format, not Markdown. Use the format specified in this guide exactly to avoid rendering issues.

## Tone

- **Technical but accessible** — You're updating both engineers and stakeholders
- **Solution-focused** — Lead with the approach, then supporting detail
- **Confidence without arrogance** — State the plan clearly, acknowledge risks

Avoid:
- Overly detailed implementation minutiae (save for the design artifact)
- Uncertainty hedging ("maybe", "possibly", "I think")
- Jargon without context (define technical terms if PO/QA will read)

## Comment Structure

Use this template. Note: This uses GitHub Issues Wiki Markup format:

```
h2. Technical Design

*Files Affected:* <count>

h3. Solution Approach
[2-3 sentences: how the change will be implemented, high-level strategy]

h3. Key Changes
* [Bullet point 1]
* [Bullet point 2]
* [Bullet point 3]

h3. Implementation Steps
# [Step 1]
# [Step 2]
# [Step 3]

h3. Risks
[Bulleted list using * if any, or "None identified"]

*Estimated time:* <minutes/hours>

----
Full design: {{specs/<ISSUE-KEY>/design.md}}
```

**Key GitHub Issues Wiki Markup syntax:**
- Headers: `h2.`, `h3.`, `h4.` (NOT `##`, `###`)
- Bold: `*text*` (NOT `**text**`)
- Numbered lists: `#` at line start (NOT `1.`, `2.`)
- Bulleted lists: `*` at line start
- Horizontal rule: `----` (NOT `---`)
- Monospace/code: `{{text}}` (NOT backticks)

## Section Guidelines

### Files Affected

State the count upfront so readers understand the scope:

**Format:**
{quote}*Files Affected:* 6 (3 source, 3 test){quote}

or

{quote}
*Files Affected:* 4
* {{src/components/UserProfile.tsx}}
* {{src/services/userService.ts}}
* {{tests/UserProfile.test.tsx}}
* {{tests/userService.test.ts}}
{quote}

Choose the first format (count only) if there are many files. Choose the second (list) if there are few (under 5).

### Solution Approach

Summarize the design in 2-3 sentences:

**Pattern:**
1. What the solution does (user perspective)
2. How it's structured (technical perspective)
3. Why this approach (rationale, if not obvious)

**Example:**
{quote}The solution adds a confirmation dialog before account deletion and validates that the user is not the last admin. The backend implements the validation logic in {{userService}}, returning a 403 error if blocked. The frontend displays a modal dialog on delete button click, calls the service, and handles success or error states.{quote}

### Key Changes

Highlight the most important modifications. Keep to 3-5 bullets.

**Format:**
* *What changes* — Why (if not obvious)

**Example:**
{quote}
* *Backend validation* — Prevent deletion if user is last admin (business rule)
* *Confirmation dialog* — New modal component to confirm action before proceeding
* *Delete button* — Added to user profile settings, triggers dialog on click
* *Error handling* — Toast notifications for success/failure scenarios
{quote}

### Implementation Steps

List the major phases (not exhaustive tasks). Match the implementation plan from the design artifact.

**Keep it high-level:**
✅ Good:
{quote}
# Implement backend validation
# Create confirmation dialog UI
# Wire delete flow (button → dialog → API)
# Add tests
# Verify end-to-end
{quote}

❌ Too detailed:
{quote}
# Add {{isLastAdmin()}} function
# Call {{isLastAdmin()}} in {{deleteAccount()}}
# Throw ValidationError if true
# Create {{DeleteAccountDialog.tsx}} file
# Import React
# Define props interface
...
{quote}

Engineers can read the design artifact for detail. GitHub Issues comment should be scannable.

### Risks

Be honest about unknowns and blockers. Stakeholders appreciate transparency.

**If no risks:**
{quote}
*Risks*

None identified — implementation is straightforward.
{quote}

**If risks exist:**
{quote}
*Risks*

* *Auth permissions unclear:* Need to verify users can delete their own accounts via API. Will test early in Step 3.
* *Migration on large table:* {{users}} table has 10M+ rows. Schema change might timeout. Will test on staging first.
{quote}

Don't sugarcoat, but do include mitigation plans if you have them.

## Labeling

After posting the comment, add label `cr-designed` to the issue. This signals:
- Design is complete
- Implementation can begin
- Stakeholders can review the approach

Use:
```
gh issue edit --add-label(key="PROJ-1234", label="cr-designed")
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

**How to tag:**
Use `[~username]` (NOT `@username`) in GitHub Issues comments. The username is typically the I-number (e.g., `[~I844709]`).

## Link to Full Design

Always end with the artifact path:

{quote}
----
Full design: {{specs/PROJ-1234/design.md}}
{quote}

This gives engineers the full detail without cluttering the GitHub Issues comment.

## Example Full Comment

```
h2. Technical Design

*Files Affected:* 6 (3 source, 3 test)

h3. Solution Approach

The solution adds a confirmation dialog before account deletion and validates that the user is not the last admin. The backend implements the validation logic in {{userService}}, returning a 403 error if deletion is blocked. The frontend displays a modal dialog on delete button click, calls the service, and handles success or error states with toast notifications.

h3. Key Changes

* *Backend validation* — Prevent deletion if user is last admin (returns 403 with error message)
* *Confirmation dialog* — New {{DeleteAccountDialog}} component with warning text and Cancel/Confirm buttons
* *Delete button* — Added to user profile settings section, triggers dialog on click
* *Error handling* — Toast notifications for success (account deleted) and failure (last admin, network error)
* *Test coverage* — Unit tests for dialog and service logic, integration test for full flow

h3. Implementation Steps

# Implement backend validation ({{isLastAdmin()}} check, throw error if blocked)
# Create confirmation dialog UI component
# Wire delete flow (button → dialog → API call → success/error handling)
# Add/update tests (unit + integration)
# Verify end-to-end in local environment

h3. Risks

* *Auth permissions unclear:* Need to verify users can delete their own accounts via API. Will test early in Step 3 and escalate if blocked.

*Estimated time:* 3 hours

----
Full design: {{specs/PROJ-1234/design.md}}
```

## Technical Detail Balance

**Too much detail** (avoid):
{quote}The {{DeleteAccountDialog}} component will be a functional React component using TypeScript. It will accept props: {{isOpen}}, {{onClose}}, and {{onConfirm}}. The dialog will use the {{Modal}} component from our UI library, styled with Tailwind classes: {{bg-white rounded-lg shadow-xl p-6}}. The title will be in {{text-xl font-bold}} and the body text in {{text-gray-600}}. The Cancel button will have class {{btn-secondary}} and the Delete button will have {{btn-danger}}.{quote}

This is implementation detail that belongs in the design artifact, not the GitHub Issues comment.

**Right amount** (do this):
{quote}The solution adds a confirmation dialog before account deletion using a new {{DeleteAccountDialog}} component. The dialog displays a warning message and provides Cancel/Confirm buttons.{quote}

This tells stakeholders what's being built without drowning them in code.

## Updating an Existing Design Comment

If the design changes based on feedback, edit the original comment (if GitHub Issues allows) or post a new comment:

{quote}
h2. Updated Technical Design

*Change:* [What changed and why]

[Rest of template]
{quote}

GitHub Issues preserves comment history, so edits are tracked. If you can't edit (permissions), post a new comment and note "Updated design" at the top.
