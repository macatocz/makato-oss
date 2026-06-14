---
name: e2e-testing-patterns
description: Build reliable E2E test suites with Playwright using Page Object Model, fixtures, waiting strategies, and network mocking — e2e-tests, playwright, flaky-tests, ci-testing, accessibility-tests, visual-regression, browser-testing. Use when implementing or debugging end-to-end tests for a production UI.
version: "1.0.0"
---

# e2e-testing-patterns

## When to Use

- Implementing E2E test automation for a production UI
- Debugging flaky or unreliable tests
- Testing critical user workflows (login, checkout, signup)
- Setting up Playwright in a CI/CD pipeline
- Adding accessibility or visual regression testing
- Establishing E2E testing standards for a new project

## When NOT to Use

- Unit-level logic — use unit tests (faster, more precise)
- API contract validation — use integration tests
- Edge cases that don't involve user-visible behaviour — too slow for E2E

---

## Workflow

### Step 1: Assess Scope

Identify what to test with E2E vs other layers:

- **E2E**: critical user journeys, complex interactions (multi-step forms, drag-and-drop),
  cross-browser compatibility, authentication flows, real API integration
- **Not E2E**: internal implementation details, every edge case, API contracts

### Step 2: Configure Playwright

Load @references/playwright-config.md for the recommended `playwright.config.ts`.

Key settings to confirm with the user:

- `baseURL` — the app's local dev URL
- `projects` — browsers to test (chromium, firefox, webkit, mobile)
- `retries` — 0 locally, 2 in CI
- `reporter` — html + junit for CI artifact upload

### Step 3: Write Tests Using Page Object Model

Load @references/page-object-model.md for the POM pattern.

Structure each page interaction as a class:

- Constructor defines `Locator` properties using `getByRole`, `getByLabel`, `getByText`
- Methods encapsulate multi-step flows (e.g., `login(email, password)`)
- Tests import the page object — they never inline raw selectors

Selector priority (most to least stable):

1. `getByRole` — matches ARIA roles; survives CSS refactors
2. `getByLabel` — matches form labels; survives DOM restructuring
3. `getByText` — matches visible text; survives class changes
4. `data-testid` attribute — explicit test hook, always stable
5. CSS class — avoid; breaks on refactoring

Never use `nth-child`, positional selectors, or implementation-specific class names.

### Step 4: Handle Async Correctly

Load @references/waiting-strategies.md for correct waiting patterns.

- Never use `page.waitForTimeout(N)` — it creates timing-dependent flakiness
- Use `expect(locator).toBeVisible()` — Playwright auto-waits up to the configured timeout
- For network-dependent state: `page.waitForResponse(url => ...)` before the triggering action
- For navigation: `page.waitForURL('/target')` after the click

### Step 5: Mock Network When Needed

Use `page.route()` to intercept requests for:

- Simulating API errors (`status: 500`)
- Removing third-party dependencies (Stripe, analytics)
- Controlling response data in tests that don't need real API calls

Load @references/network-mocking.md for patterns.

Do not mock network calls in tests that are specifically validating API integration.

### Step 6: Add Accessibility Tests

Load @references/accessibility-testing.md for axe-core integration.

For every new page or component with user-facing UI, add:

```typescript
const results = await new AxeBuilder({ page }).analyze();
expect(results.violations).toEqual([]);
```

### Step 7: Run and Debug

```bash
# Headed mode — see the browser
npx playwright test --headed

# Debug mode — step through with inspector
npx playwright test --debug

# Single test
npx playwright test tests/login.spec.ts

# CI mode
npx playwright test --reporter=junit
```

For flaky tests: add `test.step()` labels around each logical phase so the trace viewer
shows exactly where it failed. Use `page.pause()` to inspect state mid-test locally.

### Step 8: Visual Regression (Optional)

If the project requires visual regression testing, use `toHaveScreenshot()`:

```typescript
await expect(page).toHaveScreenshot('homepage.png', { maxDiffPixels: 100 });
```

Commit the baseline screenshots to the repository. Re-generate baselines with
`npx playwright test --update-snapshots` after intentional design changes.
