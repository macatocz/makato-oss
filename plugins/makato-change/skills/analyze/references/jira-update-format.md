# GitHub Issues Update Format

Structure and tone for posting analysis results back to GitHub Issues as comments.

**IMPORTANT**: GitHub Issues uses Wiki Markup format, not Markdown. Use the format specified in this guide exactly to avoid rendering issues.

## Tone

- **Professional but conversational** — You're updating teammates, not writing a legal document
- **Direct and clear** — Lead with conclusions, then supporting detail
- **Action-oriented** — Make next steps obvious

Avoid:
- Overly formal language ("As per the aforementioned requirements...")
- Apologetic hedging ("I think maybe possibly this might...")
- Walls of text with no structure

## Comment Structure

Use this template as a starting point. Note: This uses GitHub Issues Wiki Markup format:

```
h2. Change Request Analysis

*Scope*: [Small/Medium/Large]

h3. Summary
[2-3 sentences: what changes, complexity level, confidence in estimate]

h3. Open Questions
[Numbered list using # symbols, or "None — requirements are clear"]

h3. Inconsistencies
[Bulleted list using * symbols, or "None identified"]

h3. Next Steps
[Clear recommendation: answer questions / proceed to design / escalate]

----
Full analysis: {{specs/<ISSUE-KEY>/analysis.md}}
```

**Key GitHub Issues Wiki Markup syntax:**
- Headers: `h2.`, `h3.`, `h4.` (NOT `##`, `###`)
- Bold: `*text*` (NOT `**text**`)
- Numbered lists: `#` at line start (NOT `1.`, `2.`)
- Bulleted lists: `*` at line start
- Horizontal rule: `----` (NOT `---`)
- Monospace/code: `{{text}}` (NOT backticks)

## Section Guidelines

### Scope

State it upfront so readers immediately know complexity:

**Good:**
{quote}*Scope*: Medium (6-8 files, isolated to user profile module, new validation + tests){quote}

**Bad:**
{quote}*Scope*: Medium{quote}

### Summary

Give the high-level story in 2-3 sentences:

**Pattern:**
1. What currently happens
2. What the change requests
3. Implementation complexity or confidence level

**Example:**
{quote}Currently, users can delete their account immediately with no confirmation. The change request adds a confirmation dialog and prevents deletion if the user is the last admin. This is a medium-sized change affecting the profile UI, account service, and permissions logic. Requirements are clear and implementation is straightforward.{quote}

### Open Questions

List questions that block progress. Number them so they can be referenced in replies.

If there are no blocking questions, say so explicitly:

{quote}
*Open Questions*

None — requirements are clear and complete.
{quote}

If there ARE questions:

{quote}
*Open Questions*

# Should the confirmation dialog mention that comments will be anonymized? (UX decision)
# What happens to user's posts? Request doesn't specify. (Delete? Anonymize? Keep as-is?)
# Should there be a grace period where deletion can be undone? (Product decision)
{quote}

**Tag stakeholders** who can answer:

{quote}[~username] — can you clarify question 2 (posts handling)?{quote}

### Inconsistencies

Flag problems that must be resolved before design:

**Pattern:**
- State the conflict
- Explain the impact
- Suggest resolution if obvious

**Example:**
{quote}
*Inconsistencies*

* *Conflict with audit requirement*: Request says users can "edit submitted forms," but our audit policy (POLICY-123) requires immutability. We need to decide: create new version (preserving original) or allow edits with full change log?
* *Performance risk*: Bulk delete of 10,000 items could timeout. Request doesn't address this. Suggest: add confirmation for bulk actions >100 items, or implement async job for large deletions.
{quote}

If none:

{quote}
*Inconsistencies*

None identified — change aligns with existing system behavior.
{quote}

### E2E Test Scenarios Affected

List E2E test scenarios that will need updates, using their IDs as primary identifiers.

**If E2E scenarios are affected:**

{quote}
*E2E Test Scenarios Affected*

* DCPAT-123: User completes checkout with discount code — will need updated assertions for new validation
* DCPAT-456: Admin deletes user account — scenario covers the affected workflow, needs review
{quote}

**If no E2E scenarios affected:**

{quote}
*E2E Test Scenarios Affected*

None — no existing E2E scenarios cover this functionality.
{quote}

### Next Steps

Be explicit about what should happen next. Don't leave readers guessing.

**If questions block progress:**

{quote}
*Next Steps*

Waiting on answers to questions 1-3 above before proceeding to design. Please respond in this ticket or tag me in Slack.
{quote}

**If clear to proceed:**

{quote}
*Next Steps*

Requirements are clear. Proceeding to technical design phase. I'll update this ticket when the design is ready for review.
{quote}

**If scope is too large:**

{quote}
*Next Steps*

This change is too large for a single story. Recommend escalating to makato-plan workflow for proper discovery and decomposition into multiple stories. Reason: introduces new subsystem (async job processing) that affects multiple teams and requires architectural design.
{quote}
> 
> None identified — change aligns with existing system behavior.

### Next Steps

Be explicit about what should happen next. Don't leave readers guessing.

**If questions block progress:**

> **Next Steps**
> 
> Waiting on answers to questions 1-3 above before proceeding to design. Please respond in this ticket or tag me in Slack.

**If clear to proceed:**

> **Next Steps**
> 
> Requirements are clear. Proceeding to technical design phase. I'll update this ticket when the design is ready for review.

**If scope is too large:**

> **Next Steps**
> 
> This change is too large for a single story. Recommend escalating to makato-plan workflow for proper discovery and decomposition into multiple stories. Reason: introduces new subsystem (async job processing) that affects multiple teams and requires architectural design.

## Link to Full Analysis

Always end with the artifact path:

{quote}
----
Full analysis: {{specs/PROJ-1234/analysis.md}}
{quote}

This gives readers the option to go deeper without cluttering the GitHub Issues comment.

## Labeling

After posting the comment, add label `makato-change-analyzed` to the issue. This makes it easy to filter analyzed vs. un-analyzed change requests.

Use:
```
gh issue edit --add-label
```

**Note**: The `makato` and `makato-change` labels should already be present (added at the start of the analyze phase in Step 2.2).

## When to Tag People

**Do tag:**
- The issue assignee (if different from you)
- People who can answer open questions (based on watchers, reporter, or known domain experts)
- People explicitly mentioned in the issue description ("Check with @alice before implementing")

**Don't tag:**
- Large groups or distribution lists
- People who are just watching for awareness
- Your manager (unless they specifically asked to be tagged)

**How to tag:**

In GitHub Issues comments, use `[~username]` (NOT `@username`). The username is typically the I-number (e.g., `[~I844709]`). If you're not sure of the username, check the issue's "Reporter" or "Watchers" fields.

## Updating the Label

When you add `makato-change-analyzed` label, it signals:
- Analysis is complete
- Results are posted
- Stakeholders can review and respond

If the issue already has labels like `needs-clarification` or `blocked`, leave those in place. The labels accumulate to show current state.

## Example Full Comment

```
h2. Change Request Analysis

*Scope*: Medium (affects profile UI, account API, permissions service, ~6-8 files)

h3. Summary

Currently, users can delete their account by clicking "Delete Account" in settings — no confirmation, happens immediately. This change adds a confirmation dialog, prevents deletion if the user is the only admin, and anonymizes the user's comments on deletion. The change is medium complexity, affecting UI, backend service, and permissions logic. Most requirements are clear, with a few open questions below.

h3. Open Questions

# Should the confirmation dialog explicitly mention that comments will be anonymized? (UX copy decision)
# What happens to the user's posts? Request doesn't specify. Options: delete, anonymize (replace author with "Deleted User"), or keep as-is.
# Should there be a grace period (e.g., 30 days) where deletion can be undone? Or is it permanent immediately?

[~jane-product] — can you clarify questions 1-3? These affect the UX and data retention logic.

h3. Inconsistencies

* *Email send failure*: Request says "send confirmation email" but doesn't specify what happens if email send fails. Recommend: proceed with deletion anyway and log warning (email is notification only, not critical to the operation).

h3. Next Steps

Waiting on answers to questions 1-3 before proceeding to technical design. Once clarified, I'll design the solution and update this ticket.

----
Full analysis: {{specs/PROJ-1234/analysis.md}}
```
