# Implementation Guidelines

Best practices for implementing changes based on a design specification. Focus on code quality, following existing patterns, and avoiding over-engineering.

## Follow the Design

The design artifact is your specification. Implement what it describes, nothing more, nothing less.

### Do:
- Read the design artifact thoroughly before starting
- Follow the implementation plan step-by-step
- Implement exactly what the design specifies
- Ask the user if something in the design is unclear

### Don't:
- Add features not in the design ("while I'm here, I'll also...")
- Refactor unrelated code
- Create abstractions not called for
- Change the approach without discussing with the user

If you discover the design is incomplete, incorrect, or won't work: **stop and inform the user**. Don't improvise a fix.

## Match Existing Patterns

The design should identify code patterns to follow. Your implementation must match these patterns.

### Naming Conventions

If existing code uses:
- `getUserProfile()` and `updateUserEmail()` → new function should be `deleteUserAccount()` (verb + object, camelCase)
- `UserProfile.tsx` and `EmailForm.tsx` → new component should be `DeleteDialog.tsx` (PascalCase, noun)
- `userService.test.ts` → new test should be `accountService.test.ts` (matches pattern)

Don't introduce a new pattern. Use what exists.

### File Structure

Preserve the organizational structure used in existing files:
- Observe how existing files in the same directory are organized
- Match the order and grouping of sections (imports, definitions, implementations, exports)
- Don't reorganize or introduce a new structure just because you prefer it

Different languages and codebases have different conventions. Follow what the codebase already uses.

### Error Handling

If existing code:
- Throws typed errors (`ValidationError`, `NotFoundError`)
- Use the same approach for new error cases

If existing code:
- Returns `Result<T, Error>` or `{ success: boolean, error?: string }`
- Match that pattern

Don't introduce a different error handling style.

### Import Style

Match how existing code imports dependencies. Different languages have different import mechanisms — observe and follow the conventions used in the files you're modifying.

## Write Minimal Comments

Default to writing NO comments. Only add a comment when:

### When to Comment:
- **Non-obvious "why"**: The reason for doing something is surprising or involves a hidden constraint
  ```typescript
  // Safari requires explicit width on flex items to prevent shrinking
  style={{ width: '100%' }}
  ```
- **Workaround**: You're working around a bug or limitation
  ```python
  # Workaround for Django 4.x bug #12345 - remove when fixed
  ```
- **Business rule**: A constraint from the requirements that isn't obvious from code
  ```java
  // Users must be 18+ to delete their account (legal requirement)
  if (user.age < 18) throw new ValidationError(...);
  ```

### When NOT to Comment:
- **What the code does** (the code itself says this):
  ```typescript
  // Get the user's email ❌
  const email = user.getEmail();
  ```
- **Obvious behavior**:
  ```python
  # Return True if valid, False otherwise ❌
  def is_valid():
      return self.status == Status.VALID
  ```
- **Restating the implementation**:
  ```java
  // Loop through users ❌
  for (User user : users) {
  ```

If you find yourself writing a comment that just describes what the next line does, delete the comment. Well-named functions and variables are better than comments.

## Handle Edge Cases

The design should specify how to handle edge cases identified in the analysis. Implement them.

**Example from design:**
> Edge case: User is the last admin
> - Check admin count before deletion
> - If count === 1 and user is admin: throw ValidationError

**Your implementation:**
```typescript
async function deleteAccount(userId: string): Promise<void> {
  const user = await getUser(userId);
  
  if (user.role === 'admin') {
    const adminCount = await countAdmins();
    if (adminCount === 1) {
      throw new ValidationError('Cannot delete last admin');
    }
  }
  
  await db.users.delete(userId);
}
```

Don't skip edge cases because they're "unlikely" or "not in the happy path." The design calls for them — implement them.

## Error Handling

Follow the error strategy from the design.

### Fail Fast

If something is wrong, detect it early:

```typescript
function updateProfile(profile: Profile): void {
  if (!profile.email) {
    throw new ValidationError('Email required');
  }
  // continue with valid data
}
```

Don't let invalid data propagate through the system.

### Meaningful Error Messages

Error messages should:
- Tell the user what went wrong
- Be specific enough to act on
- Match existing error message style in the codebase

**Good:**
> "Cannot delete account — you are the only admin. Promote another user first."

**Bad:**
> "Invalid operation"
> "Error: 403"

### Log for Debugging, Not for Users

Logs are for developers. Error messages are for users. Don't confuse them:

```typescript
// User-facing error
throw new ValidationError('Email address is already in use');

// Logged for debugging
logger.error('Duplicate email on signup', { email, userId, timestamp });
```

## Don't Over-Engineer

You're implementing a change request, not building a framework.

### Three Similar Lines

If you have three similar lines of code, that's fine. Don't create an abstraction:

```typescript
// This is fine ✓
updateUserField('name', newName);
updateUserField('email', newEmail);
updateUserField('phone', newPhone);

// Don't do this ❌
['name', 'email', 'phone'].forEach((field, i) =>
  updateUserField(field, [newName, newEmail, newPhone][i])
);
```

Abstractions have a cost (complexity, indirection). Only create them when there's a clear benefit.

### One-Time Operations

If something happens once, just do it directly:

```typescript
// One-time operation - just write it ✓
const result = await api.post('/users', { name, email });
if (result.status === 201) {
  showToast('User created');
}

// Don't create a factory for one use ❌
const userCreator = new UserCreatorFactory(api, toastService);
await userCreator.create({ name, email });
```

### Don't Design for Hypothetical Futures

Implement what the design calls for, not what you think might be needed later:

**Design says:** "Add a delete button"

**Don't do:**
- Make it configurable (what if we need to hide it?)
- Add undo functionality (what if users make mistakes?)
- Add audit logging (what if we need compliance?)
- Make it reusable across all pages (what if we need it elsewhere?)

Just add the delete button. If those hypothetical needs become real, you'll implement them then with full context.

## Code Quality Checklist

Before committing, check:

- [ ] Follows the design specification
- [ ] Matches existing code patterns (naming, structure, style)
- [ ] Handles edge cases specified in the design
- [ ] Error handling follows existing patterns
- [ ] No comments unless "why" is non-obvious
- [ ] No features beyond the design
- [ ] No unnecessary abstractions or configurations
- [ ] Imports match existing style
- [ ] Works as verified by tests

If all checked: your implementation is ready to commit.
