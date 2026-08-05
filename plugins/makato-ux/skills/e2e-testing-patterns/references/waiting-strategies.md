# waiting-strategies.md

Correct async waiting patterns in Playwright — and the failure modes each
pattern is designed to prevent.

## Auto-Waiting: The Default Mental Model

Playwright's `expect(locator).toBeVisible()` and similar assertions retry
internally up to `expect.timeout` (default 5 s, configurable). This is the
only safe default — do not add explicit waits unless the auto-wait does not
cover the condition you need.

```typescript
// Correct — Playwright retries until visible or timeout
await expect(page.getByRole('alert')).toBeVisible();

// Wrong — races against rendering; passes if element happens to be there now
const el = await page.getByRole('alert');
expect(el).toBeTruthy(); // this just checks the Locator object exists, not the DOM
```

## The `waitForTimeout` Failure Mode

`page.waitForTimeout(2000)` means "wait 2 seconds regardless of what the
app does". The test is betting that 2 seconds is always enough. On an
overloaded CI runner under heavy load, 2 seconds is not enough. On a fast
developer machine, 2 seconds is wasted. It accumulates: 10 such waits per
test × 100 tests = 1000 seconds of artificial delay.

**Replace every `waitForTimeout` with a condition-based wait.**

## Network-Dependent State

Wait for the response before triggering the action that depends on it:

```typescript
// Wrong — the response may not have arrived by the time you assert
await page.click('[data-testid="load-more"]');
await expect(page.getByTestId('item-list')).toHaveCount(20);

// Correct — wait for the network response first, then assert
const responsePromise = page.waitForResponse(
  resp => resp.url().includes('/api/items') && resp.status() === 200
);
await page.click('[data-testid="load-more"]');
await responsePromise;
await expect(page.getByTestId('item-list')).toHaveCount(20);
```

The promise must be created **before** the action that triggers the request.
Creating it after the click means the response may already have arrived and
been dropped.

## Navigation Waits

```typescript
// After a click that navigates:
await page.click('[data-testid="go-to-settings"]');
await page.waitForURL('**/settings');

// After a form submit that redirects:
await Promise.all([
  page.waitForURL('**/confirmation'),
  page.click('[type=submit]'),
]);
```

## Waiting for DOM Mutations

```typescript
// Wait for count to stabilize (e.g., list loaded via infinite scroll)
await expect(page.getByRole('listitem')).toHaveCount(10);

// Wait for text to appear
await expect(page.getByTestId('status')).toHaveText('Completed');

// Wait for attribute change (e.g., disabled removed after async validation)
await expect(page.getByRole('button', { name: 'Submit' })).toBeEnabled();
```

## Polling for External State

When a test depends on an external system (webhook, background job, email
delivery), Playwright's auto-wait is not enough — you need to poll:

```typescript
async function waitForEmail(to: string, timeout = 15_000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const email = await mailhog.getLatest(to);
    if (email) return;
    await page.waitForTimeout(500); // polling sleep — acceptable ONLY here
  }
  throw new Error(`Email to ${to} not received within ${timeout}ms`);
}
```

`waitForTimeout` is acceptable only inside a polling helper with a hard
deadline, never as a free-standing stabilizer in a test body.

## `beforeAll` Trap

`beforeAll` in Playwright runs once per worker for all tests in the `describe`
block, not once per test. If the state set in `beforeAll` is mutated by any
test in the block, subsequent tests see the mutation. This is the most common
source of "the test passes alone but fails in a full run" bugs.

Rule: use `beforeAll` only for expensive, purely read-only setup. Use
`beforeEach` for any state that tests should see in a clean initial condition.

## Shadow DOM and Iframe Waits

Standard locators do not pierce shadow DOM or iframes. If an element is
inside a shadow root:

```typescript
const shadowHost = page.locator('[data-component="date-picker"]');
const inputInsideShadow = shadowHost.locator('input'); // Playwright pierces shadow DOM
await expect(inputInsideShadow).toBeVisible();
```

For iframes:
```typescript
const frame = page.frameLocator('iframe[title="Payment"]');
await expect(frame.getByLabel('Card number')).toBeVisible();
```
