# network-mocking.md

`page.route()` patterns for intercepting, modifying, and stubbing network
requests in Playwright.

## Core Syntax

```typescript
// Intercept and fulfill with a fixed response
await page.route('**/api/users', async route => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify([{ id: 1, name: 'Alice' }]),
  });
});

// Intercept and simulate server error
await page.route('**/api/orders', async route => {
  await route.fulfill({ status: 500 });
});

// Intercept and modify a real response (modify-in-flight)
await page.route('**/api/products', async route => {
  const response = await route.fetch();
  const body = await response.json();
  body.items.push({ id: 999, name: 'Injected item' });
  await route.fulfill({ response, body: JSON.stringify(body) });
});

// Allow the request to continue unmodified
await page.route('**/api/health', route => route.continue());
```

## Catch-All Fallback (Required for Partial Mocking)

When you mock only specific endpoints and leave others real, unmatched routes
hang until the configured `timeout`. Always add a catch-all as the last route:

```typescript
await page.route('**/api/search', searchHandler);
await page.route('**/api/suggestions', suggestionsHandler);
await page.route('**', route => route.continue()); // MUST be last
```

Route handlers are evaluated in registration order, last-registered first
(LIFO). The catch-all must be registered last so specific handlers match first.

## Scoping Mocks: Test vs Context vs Page

Three scopes available:

| Scope | Registration | Lifetime |
|-------|-------------|----------|
| `page.route()` | Per-page | Active while page is open |
| `context.route()` | Per browser context | Active for all pages in context |
| `browserContext.route()` | Same as context.route | Active for all pages in context |

For most E2E tests, `page.route()` is the right scope. Use `context.route()`
only if the scenario involves multiple tabs or windows that all need the mock.

## Intercepting GraphQL

GraphQL sends all requests to one endpoint. Match by inspecting the request body:

```typescript
await page.route('**/graphql', async route => {
  const body = route.request().postDataJSON();
  if (body?.operationName === 'GetUserProfile') {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: { user: { id: '1', name: 'Alice' } } }),
    });
  } else {
    await route.continue(); // let other operations through
  }
});
```

## Removing Third-Party Dependencies

Third-party scripts (analytics, chat widgets, A/B testing) slow tests and
introduce external failure modes. Block them permanently in `use.extraHTTPHeaders`
or by routing:

```typescript
// playwright.config.ts — block for all tests
use: {
  extraHTTPHeaders: { 'X-Playwright': '1' }, // optional: server can detect test mode
},

// Or route-based blocking
await page.route(/segment\.com|intercom\.io|sentry\.io/, route => route.abort());
```

## Simulating Slow Networks

```typescript
await page.route('**/api/large-export', async route => {
  await new Promise(r => setTimeout(r, 3_000)); // 3 s delay
  await route.continue();
});
```

Use for testing loading states and skeleton screens — confirm they appear
and disappear correctly under latency.

## Decision: Mock vs Real API

```
Does the test specifically validate the API contract or integration?
  YES → do NOT mock (use real API call)
  NO  → Is the API service unreliable / rate-limited / requires payment?
    YES → mock it
    NO  → Does the test require a deterministic response shape for assertion?
      YES → mock it
      NO  → Does the API call add >1s of latency to an already-slow suite?
        YES → consider mocking for speed
        NO  → prefer real API (less maintenance burden)
```

Mocking adds a maintenance burden: when the API schema changes, your mock is
wrong and your test still passes — silently hiding the regression. Mock only
what you have a clear reason to mock.

## Assertions on Intercepted Requests

Verify that the right request was made with the right payload:

```typescript
let capturedRequest: Record<string, unknown> | null = null;

await page.route('**/api/checkout', async route => {
  capturedRequest = route.request().postDataJSON();
  await route.fulfill({ status: 200, body: JSON.stringify({ orderId: 'abc' }) });
});

await checkoutPage.confirmOrder();

expect(capturedRequest).toMatchObject({
  items: [{ id: 'prod-1', quantity: 2 }],
  paymentMethod: 'card',
});
```

## Cleanup

Routes registered with `page.route()` are automatically cleaned up when the
page is closed. No explicit cleanup required in `afterEach` unless you need
to remove a route mid-test:

```typescript
await page.unroute('**/api/search', searchHandler);
```
