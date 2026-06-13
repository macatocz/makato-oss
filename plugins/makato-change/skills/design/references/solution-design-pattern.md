# Solution Design Pattern

How to structure a technical solution for a change request. Covers what will be modified, what will be added, patterns to follow, and edge case handling.

## Solution Design Structure

A good solution design answers:
1. **What exists now** that needs to change
2. **What's new** that needs to be added
3. **How to fit** into existing code patterns
4. **What could go wrong** (edge cases, errors)

## Section 1: What Will Be Modified

List existing files/functions that need changes.

### Format

For each file:
```
**File:** `path/to/file.ts`
**Role:** What this file does in the system
**Changes needed:**
- Modify `functionName()` to [what changes]
- Update `ComponentName` to [what changes]
- Adjust validation rules in [where]
```

### Example

```
**File:** `src/components/UserProfile.tsx`
**Role:** Displays user profile information and settings
**Changes needed:**
- Add "Delete Account" button in the settings section
- Add confirmation dialog component (new modal)
- Wire button click to call `deleteAccount()` from userService

**File:** `src/services/userService.ts`
**Role:** Handles user-related API calls and business logic
**Changes needed:**
- Add `deleteAccount()` method that calls DELETE /api/users/:id
- Add validation: prevent deletion if user is last admin
- Return error if validation fails
```

## Section 2: What Will Be Added

Identify new components that don't currently exist.

### Categories

**UI Components:**
- New buttons, dialogs, form fields
- New screens or views
- Icons, alerts, notifications

**Logic/Functions:**
- New helper functions
- New validation rules
- New business logic methods

**Data/Config:**
- New database fields or tables
- New config options
- New constants or enums

**Infrastructure:**
- New API endpoints
- New routes
- New permissions or roles

### Format

```
**New: [Component Name]**
**Type:** [UI / Logic / Data / Infrastructure]
**Purpose:** [Why this is needed]
**Location:** [Where it will live]
**Details:** [Specific implementation notes]
```

### Example

```
**New: DeleteAccountDialog**
**Type:** UI Component
**Purpose:** Confirm account deletion before executing
**Location:** `src/components/dialogs/DeleteAccountDialog.tsx`
**Details:**
- Modal dialog with title "Delete your account?"
- Body text: "This cannot be undone. Your comments will be anonymized."
- Two buttons: Cancel (secondary) and Delete Account (danger/red)
- On Cancel: close dialog, no action
- On Confirm: call userService.deleteAccount(), show success toast or error

**New: isLastAdmin() validation**
**Type:** Logic
**Purpose:** Prevent deletion if user is the only admin
**Location:** `src/services/userService.ts`
**Details:**
- Query: count users with role=admin
- If count === 1 and current user is admin: throw error
- Error message: "Cannot delete account — you are the only admin. Promote another user first."
```

## Section 3: Patterns to Follow

Note existing conventions in the codebase that the solution must match.

### Naming Conventions

**Functions:**
- Existing: `getUserProfile()`, `updateUserEmail()`
- Pattern: camelCase, verb + noun
- New function should be: `deleteUserAccount()` (matches pattern)

**Components:**
- Existing: `UserProfile.tsx`, `EmailForm.tsx`
- Pattern: PascalCase, noun-based
- New component should be: `DeleteAccountDialog.tsx` (matches pattern)

**Files:**
- Existing tests: `userService.test.ts`, `UserProfile.test.tsx`
- Pattern: `[name].test.[ext]`, co-located with source or in `tests/` dir
- New test should be: `deleteAccount.test.ts` or `DeleteAccountDialog.test.tsx`

### Error Handling

**Existing pattern:**
- Service layer: throws typed errors (ValidationError, NotFoundError)
- UI layer: catches errors, shows toast notification with error.message
- API layer: returns 4xx status codes with JSON {error: "message"}

**Solution must:**
- Throw `ValidationError` if user is last admin
- Catch in UI, show error toast
- API returns 403 with {error: "Cannot delete last admin"}

### Testing Approach

**Existing pattern:**
- Unit tests: mock dependencies (API calls, services)
- Integration tests: use test database, real API calls
- UI tests: render component, simulate user actions, assert DOM

**Solution must:**
- Add unit test: mock userService.deleteAccount(), assert dialog behavior
- Add integration test: create test user, delete via API, verify DB state
- UI test: render UserProfile, click delete button, assert dialog appears

## Section 4: Edge Cases and Error Handling

Plan how to handle non-happy-path scenarios.

### Edge Cases Checklist

From the analysis artifact, review the "Gap Analysis" section. For each identified edge case, design the behavior:

**Pattern:**
```
**Edge case:** [Description]
**Current behavior:** [What happens now, if anything]
**Desired behavior:** [What should happen]
**Implementation:** [How to achieve it]
```

### Example

```
**Edge case:** User is the last admin
**Current behavior:** N/A (deletion doesn't exist yet)
**Desired behavior:** Block deletion, show clear error message
**Implementation:**
- In userService.deleteAccount(), query admin count before delete
- If count === 1 and user.role === 'admin': throw ValidationError
- UI catches, shows toast: "Cannot delete account — you are the only admin"

**Edge case:** Email notification fails to send
**Current behavior:** N/A
**Desired behavior:** Deletion proceeds anyway (notification is informational, not critical)
**Implementation:**
- After successful deletion, try to send email
- Catch email send error, log warning, do not throw
- User sees success message regardless of email status
```

### Error Scenarios

For each possible failure, define:
- What error occurs
- What message the user sees
- Whether the operation rolls back or proceeds
- Whether the error is logged

**Example:**
```
**Error:** API call fails (network timeout, 500 error)
**User sees:** Toast notification: "Could not delete account. Please try again."
**Operation:** Rolls back (no deletion occurs)
**Logging:** Log error with stack trace to error monitoring service

**Error:** User navigates away mid-operation
**User sees:** Nothing (operation cancelled)
**Operation:** Front-end cancels API request (if in-flight)
**Logging:** None (normal user behavior)
```

## Section 5: Test Strategy

Plan what tests to write and how.

### Update Existing Tests

List tests that need changes because behavior is modified:

```
**Test file:** `tests/UserProfile.test.tsx`
**Test case:** "renders user information"
**Change needed:** Assert that "Delete Account" button is present
**Why:** New button is part of the profile UI
```

### Add New Tests

List new tests for new behavior:

```
**Test file:** `tests/DeleteAccountDialog.test.tsx` (new)
**Test cases:**
- "renders with correct text and buttons"
- "closes dialog on Cancel click"
- "calls deleteAccount() on Confirm click"
- "shows error toast if deletion fails"

**Test file:** `tests/userService.test.ts`
**New test cases:**
- "deleteAccount() succeeds for non-admin user"
- "deleteAccount() throws ValidationError if last admin"
- "deleteAccount() calls DELETE /api/users/:id with correct user ID"
```

### Test Data / Fixtures

Identify what test data is needed:

```
**Fixture:** Test user (non-admin)
**Fixture:** Test user (admin, last admin in DB)
**Fixture:** Test user (admin, but other admins exist)
**Mock:** API response for DELETE /api/users/:id (success)
**Mock:** API response for DELETE /api/users/:id (403 last admin error)
```

### Integration Test Coverage

If integration tests exist, plan what to add:

```
**Integration test:** "User can delete their account"
**Steps:**
1. Create test user via API
2. Authenticate as that user
3. Call DELETE /api/users/:id
4. Assert: user is deleted from DB
5. Assert: user's comments are anonymized
6. Assert: confirmation email was sent (check email queue)
```

## Design Review Checklist

Before finalizing the design, check:

- [ ] All affected files are identified and documented
- [ ] New components are fully specified (name, location, purpose)
- [ ] Solution matches existing code patterns (naming, errors, tests)
- [ ] All edge cases from analysis are addressed
- [ ] Error handling is defined for failure scenarios
- [ ] Test strategy covers new and modified behavior
- [ ] No missing pieces (incomplete specs, TBD sections)

If any checklist item is incomplete, fill it in before presenting the design to the user.
