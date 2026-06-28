# Test Generation Guide

How to write and update tests when implementing a change request. Follow existing test patterns and ensure coverage of new behavior.

## Follow Existing Test Patterns

The codebase already has tests. Your job is to write tests that fit the existing style.

### Find the Pattern

Before writing any tests, read 2-3 existing test files in the codebase:
- How are test files named? (`*.test.ts`, `*_test.go`, `test_*.py`?)
- Where do test files live? (Co-located with source, or in `tests/` directory?)
- What test framework is used? (Jest, pytest, RSpec, Go testing, etc.)
- How are tests structured? (describe/it blocks, functions, classes?)
- How are mocks created? (manual mocks, mock library, test doubles?)

**Your new tests must match these patterns exactly.**

## Unit Tests

Unit tests verify individual functions or components in isolation.

### When to Write Unit Tests

- New function added
- New component added
- Function behavior changed

### Structure

Follow the existing structure. Common patterns:

**Jest/Vitest (JavaScript/TypeScript):**
```typescript
describe('deleteAccount', () => {
  it('should delete user account when user is not last admin', async () => {
    // Arrange
    const mockUser = { id: '123', role: 'user' };
    jest.spyOn(userService, 'getUser').mockResolvedValue(mockUser);

    // Act
    await deleteAccount('123');

    // Assert
    expect(db.users.delete).toHaveBeenCalledWith('123');
  });

  it('should throw ValidationError when user is last admin', async () => {
    const mockUser = { id: '123', role: 'admin' };
    jest.spyOn(userService, 'getUser').mockResolvedValue(mockUser);
    jest.spyOn(userService, 'countAdmins').mockResolvedValue(1);

    await expect(deleteAccount('123')).rejects.toThrow(ValidationError);
  });
});
```

**pytest (Python):**
```python
def test_delete_account_succeeds_for_non_admin():
    # Arrange
    user = User(id=123, role='user')

    # Act
    result = delete_account(user.id)

    # Assert
    assert result.success == True
    assert User.query.get(123) is None

def test_delete_account_fails_for_last_admin():
    # Arrange
    user = User(id=123, role='admin')
    # Assume no other admins in test DB

    # Act & Assert
    with pytest.raises(ValidationError) as excinfo:
        delete_account(user.id)
    assert 'last admin' in str(excinfo.value)
```

### What to Test

For each new function:
1. **Happy path**: Normal case where everything works
2. **Edge cases**: Boundary conditions identified in the analysis
3. **Error cases**: Expected failures (validation errors, not found, etc.)

**Don't test:**
- Framework internals (React rendering, database ORM behavior)
- Third-party libraries (they have their own tests)
- Implementation details (private methods, internal state)

Test **behavior**, not **implementation**.

## Integration Tests

Integration tests verify multiple components working together (e.g., API + database, UI + API).

### When to Write Integration Tests

- New API endpoint added
- New user flow added
- Multiple services interact in a new way

### Structure

Integration tests are slower and more complex. Use them sparingly.

**Example (API integration test):**
```typescript
describe('DELETE /api/users/:id', () => {
  beforeEach(async () => {
    await setupTestDatabase();
  });

  afterEach(async () => {
    await cleanupTestDatabase();
  });

  it('should delete user and return 200', async () => {
    // Create test user
    const user = await createTestUser({ role: 'user' });

    // Make API call
    const response = await request(app)
      .delete(`/api/users/${user.id}`)
      .set('Authorization', `Bearer ${user.token}`);

    // Assert
    expect(response.status).toBe(200);
    expect(await User.findById(user.id)).toBeNull();
  });

  it('should return 403 when deleting last admin', async () => {
    const admin = await createTestUser({ role: 'admin' });
    // Ensure no other admins exist

    const response = await request(app)
      .delete(`/api/users/${admin.id}`)
      .set('Authorization', `Bearer ${admin.token}`);

    expect(response.status).toBe(403);
    expect(response.body.error).toContain('last admin');
  });
});
```

## UI Component Tests

For UI components, test user interactions, not implementation.

### React Component Example

```typescript
import { render, screen, fireEvent } from '@testing-library/react';
import { DeleteAccountDialog } from './DeleteAccountDialog';

describe('DeleteAccountDialog', () => {
  it('should render dialog with correct text', () => {
    render(<DeleteAccountDialog isOpen={true} onClose={() => {}} onConfirm={() => {}} />);

    expect(screen.getByText('Delete your account?')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Delete Account' })).toBeInTheDocument();
  });

  it('should call onClose when Cancel is clicked', () => {
    const onClose = jest.fn();
    render(<DeleteAccountDialog isOpen={true} onClose={onClose} onConfirm={() => {}} />);

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('should call onConfirm when Delete Account is clicked', () => {
    const onConfirm = jest.fn();
    render(<DeleteAccountDialog isOpen={true} onClose={() => {}} onConfirm={onConfirm} />);

    fireEvent.click(screen.getByRole('button', { name: 'Delete Account' }));

    expect(onConfirm).toHaveBeenCalledTimes(1);
  });
});
```

Test what the user sees and does, not internal state or props.

## Updating Existing Tests

When you modify behavior, existing tests may fail or become inaccurate.

### Fixing Failing Tests

If a test fails after your changes:

1. **Understand why it's failing**
   - Read the test code
   - Read the failure message
   - Is the test asserting old behavior that changed?

2. **Update the assertion**
   ```typescript
   // Old assertion (before adding confirmation dialog)
   expect(deleteAccount).toHaveBeenCalledImmediately();

   // New assertion (after adding confirmation dialog)
   expect(deleteAccount).not.toHaveBeenCalled();
   fireEvent.click(screen.getByRole('button', { name: 'Confirm' }));
   expect(deleteAccount).toHaveBeenCalled();
   ```

3. **Update test names if behavior changed**
   ```typescript
   // Old test name
   it('should delete account immediately on button click')

   // New test name
   it('should show confirmation dialog on button click')
   ```

### Adding Test Cases to Existing Tests

If the function still exists but has new behavior, add test cases to the existing test file:

```typescript
describe('deleteAccount', () => {
  // Existing tests...
  it('should delete account for regular user', async () => { ... });

  // New test case added
  it('should throw ValidationError when user is last admin', async () => {
    // New behavior being tested
  });
});
```

Don't create a new test file unless you're testing a completely new function/component.

## Mocking Strategy

Match the existing mocking approach.

### Manual Mocks

If existing tests use manual mocks:
```typescript
// __mocks__/userService.ts
export const deleteAccount = jest.fn();
export const countAdmins = jest.fn();
```

Your tests should use the same style.

### Inline Mocks

If existing tests mock inline:
```typescript
jest.spyOn(userService, 'deleteAccount').mockResolvedValue(undefined);
```

Match that style.

### Test Doubles

If existing tests use test doubles (fake implementations):
```python
class FakeUserRepository:
    def __init__(self):
        self.users = []

    def delete(self, user_id):
        self.users = [u for u in self.users if u.id != user_id]
```

Use the same approach.

Don't introduce a new mocking style just because you prefer it.

## Test Data and Fixtures

### Use Existing Fixtures

If the codebase has test fixtures or factory functions:
```typescript
// Existing
const testUser = createTestUser({ role: 'admin' });

// Your test should use it
const testUser = createTestUser({ role: 'user' });
```

### Create New Fixtures

If you need a fixture that doesn't exist, create it in the same place as existing fixtures:

```typescript
// tests/fixtures/users.ts
export function createTestUser(overrides = {}) {
  return {
    id: '123',
    email: 'test@example.com',
    role: 'user',
    ...overrides,
  };
}

// Your new fixture
export function createLastAdminUser() {
  return createTestUser({ role: 'admin' }); // Assumes no other admins in DB
}
```

## Test Coverage Checklist

Before committing, verify:

- [ ] All new functions have unit tests
- [ ] All modified functions have updated tests
- [ ] Happy path is tested
- [ ] Edge cases from analysis are tested
- [ ] Error scenarios are tested
- [ ] Test names accurately describe what they test
- [ ] Tests follow existing patterns (structure, naming, mocking)
- [ ] Integration tests added for new flows (if applicable)
- [ ] All tests pass

If all checked: test coverage is complete.

## Common Mistakes

### Testing Implementation Details

❌ **Bad:**
```typescript
it('should set state.loading to true', () => {
  // Testing internal state
});
```

✓ **Good:**
```typescript
it('should show loading spinner while deleting', () => {
  // Testing visible behavior
});
```

### Over-Mocking

❌ **Bad:**
```typescript
// Mocking every single dependency
jest.mock('./db');
jest.mock('./logger');
jest.mock('./validation');
jest.mock('./utils');
```

✓ **Good:**
```typescript
// Mock only external boundaries (DB, API calls)
jest.mock('./db');
// Let internal functions run for real
```

### Not Cleaning Up

❌ **Bad:**
```typescript
it('test 1', () => {
  mockFunction.mockReturnValue('foo');
  // No cleanup - affects next test
});
```

✓ **Good:**
```typescript
afterEach(() => {
  jest.clearAllMocks();
});
```

Or use `beforeEach` to set up fresh mocks for each test.
