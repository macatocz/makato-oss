# Commit Message Format

Structure for git commit messages when implementing change requests. Follow conventional commits and link back to Jira.

## Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

## Type

Use conventional commit types appropriate for change requests:

| Type | When to Use |
|------|-------------|
| `feat` | Adding or modifying functionality (default for change requests) |
| `test` | Adding or updating tests as a standalone commit |
| `refactor` | Code restructuring without behavior change (if committed separately from feat) |
| `chore` | Maintenance tasks like adding dependencies (if committed separately from feat) |

**For most change requests, use `feat`** — this covers implementing the requested change, including code modifications, new components, and tests all in one commit.

Use other types only when making standalone commits:
- `refactor`: if you refactor code separately before adding the feature
- `chore`: if you add dependencies or update config separately
- `test`: if you add tests in a separate commit from implementation

If refactoring, adding dependencies, or writing tests as part of the feature implementation, include them in the `feat` commit.

## Scope

The scope is the area of the codebase affected. Options:
- Module name: `auth`, `profile`, `api`
- Feature name: `user-settings`, `account-deletion`
- Component name: `DeleteDialog`, `UserProfile`

Choose a scope that matches how the codebase is organized.

## Subject

The subject line summarizes the change in one line (under 72 characters).

### Rules:
- Start with lowercase
- No period at the end
- Use imperative mood ("add feature" not "added feature")
- Reference the Jira key

### Examples:

✓ **Good:**
```
feat(profile): add account deletion with confirmation (PROJ-1234)
feat(auth): prevent deletion of last admin user (PROJ-1234)
fix(api): handle email send failure on deletion (PROJ-1234)
```

❌ **Bad:**
```
Add feature.
Added the account deletion feature for PROJ-1234.
feat(profile) account deletion PROJ-1234
```

## Body

The body explains **what** changed and **why** (the design artifact has the **how**).

### Structure:

1-3 paragraphs:
1. **What changed** (high-level summary)
2. **Why it changed** (business reason, requirement)
3. **Reference to design** (link back to artifact)

### Example:

```
feat(profile): add account deletion with confirmation (PROJ-1234)

Adds a "Delete Account" button to the user profile settings page.
When clicked, shows a confirmation dialog before proceeding with
deletion. Prevents deletion if the user is the last admin.

This implements the change request from PROJ-1234 to give users
control over their data by allowing self-service account deletion.

Design: specs/PROJ-1234/design.md
```

### Keep It Concise

The commit message is not documentation. Don't list every file changed or every function modified — the diff shows that.

**Do:**
- Summarize the high-level change
- Explain the business reason
- Link to the design for details

**Don't:**
- List every file changed
- Describe implementation details
- Copy/paste the entire Jira description

## Footer

The footer contains references and metadata.

### Always Include:

```
Design: specs/<ISSUE-KEY>/design.md
```

This links the commit to the design artifact for traceability.

### Optional Additions:

If the commit closes the Jira issue (it usually doesn't until after review and merge):
```
Closes: PROJ-1234
```

If the commit references related issues:
```
Related: PROJ-1235, PROJ-1236
```

## Complete Example

```
feat(profile): add account deletion with confirmation (PROJ-1234)

Adds a "Delete Account" button to user profile settings. Clicking
the button shows a confirmation dialog with warning text. On
confirmation, the account is deleted unless the user is the last
admin, in which case a validation error is shown.

This change gives users self-service control over account deletion
as requested in PROJ-1234. The confirmation step prevents accidental
deletion, and the admin check prevents system lockout.

Design: specs/PROJ-1234/design.md
```

## Multi-Commit Changes

If the change is implemented across multiple commits (e.g., backend first, then frontend), each commit should stand alone:

**Commit 1:**
```
feat(api): add account deletion endpoint (PROJ-1234)

Implements DELETE /api/users/:id endpoint with admin validation.
Prevents deletion if the user is the last admin.

Design: specs/PROJ-1234/design.md
```

**Commit 2:**
```
feat(profile): add delete account UI (PROJ-1234)

Adds delete button and confirmation dialog to profile settings.
Calls the account deletion API on confirmation.

Design: specs/PROJ-1234/design.md
```

Each commit references the same design but describes its specific contribution.

## Using Heredoc for Commit Messages

To ensure proper formatting and avoid shell escaping issues, always use heredoc:

```bash
git commit -m "$(cat <<'EOF'
feat(profile): add account deletion with confirmation (PROJ-1234)

Adds a "Delete Account" button to user profile settings with
confirmation dialog and admin validation.

Design: specs/PROJ-1234/design.md
EOF
)"
```

This preserves newlines and special characters without escaping issues.

## Commit Message Checklist

Before committing, verify:

- [ ] Type is correct (`feat` for new functionality)
- [ ] Scope matches codebase organization
- [ ] Subject line is under 72 characters
- [ ] Subject uses imperative mood ("add" not "added")
- [ ] Jira key is in subject line
- [ ] Body explains what and why (not how)
- [ ] Footer links to design artifact
- [ ] Message is concise (under 200 words for body)
- [ ] Used heredoc to avoid formatting issues

If all checked: commit message is ready.

## When Commits Fail

If a pre-commit hook blocks your commit:
1. Read the hook output (linting errors, test failures, formatting)
2. Fix the issues
3. Stage the fixes with `git add`
4. Create a NEW commit (don't use `--amend` unless replacing your own commit)

**Never use `--no-verify`** to skip hooks. Fix the underlying issue.

## Amending Commits

Only use `git commit --amend` when:
- You just made a commit and immediately caught a typo
- You forgot to add a file to the last commit
- You want to fix the commit message of the most recent commit

**Never amend:**
- Commits that have been pushed to a shared branch
- Commits that aren't the most recent one
- Someone else's commit

If you need to fix an older commit, create a new fixup commit instead.
