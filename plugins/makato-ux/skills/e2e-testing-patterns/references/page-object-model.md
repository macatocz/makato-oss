# page-object-model.md

Page Object Model patterns for Playwright, using the fixture-based approach
that avoids the most common POM scope trap.

## Fixture-Based POM (Preferred)

The canonical Playwright POM pattern passes `page` into the class constructor.
The critical insight: instantiate page objects inside fixtures, not inside tests.
Instantiating inside the test body means you cannot leverage fixture scoping
and teardown.

```typescript
// tests/page-objects/LoginPage.ts
import { type Page, type Locator } from '@playwright/test';

export class LoginPage {
  readonly page: Page;
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;

  constructor(page: Page) {
    this.page = page;
    this.emailInput = page.getByLabel('Email address');
    this.passwordInput = page.getByLabel('Password');
    this.submitButton = page.getByRole('button', { name: 'Sign in' });
    this.errorMessage = page.getByRole('alert');
  }

  async goto() {
    await this.page.goto('/login');
  }

  async login(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.submitButton.click();
  }

  async loginAndWait(email: string, password: string) {
    await this.login(email, password);
    await this.page.waitForURL('/dashboard');
  }
}
```

## Fixture File

```typescript
// tests/fixtures.ts
import { test as base } from '@playwright/test';
import { LoginPage } from './page-objects/LoginPage';
import { DashboardPage } from './page-objects/DashboardPage';

type MyFixtures = {
  loginPage: LoginPage;
  dashboardPage: DashboardPage;
};

export const test = base.extend<MyFixtures>({
  loginPage: async ({ page }, use) => {
    await use(new LoginPage(page));
  },
  dashboardPage: async ({ page }, use) => {
    await use(new DashboardPage(page));
  },
});

export { expect } from '@playwright/test';
```

Tests import from `fixtures.ts`, not from `@playwright/test`:

```typescript
// tests/login.spec.ts
import { test, expect } from '../fixtures';

test('redirects to dashboard after successful login', async ({ loginPage }) => {
  await loginPage.goto();
  await loginPage.loginAndWait('user@example.com', 'password');
  // no raw page selectors in the test body
});

test('shows error on bad credentials', async ({ loginPage }) => {
  await loginPage.goto();
  await loginPage.login('wrong@example.com', 'bad');
  await expect(loginPage.errorMessage).toBeVisible();
});
```

## Fixture Scope: `test` vs `worker`

The default fixture scope is `'test'` — a fresh instance per test, with its
own browser context. This is what you want for 95% of cases.

`scope: 'worker'` shares one fixture instance across all tests in the same
worker process. Use it **only** for expensive resources that are truly
read-only across all tests (e.g., a seeded reference dataset loaded once).
Any shared-state mutation in a worker-scoped fixture produces ordering
dependencies and non-deterministic failures.

```typescript
// Only for genuinely read-only, expensive setup:
expensiveData: [async ({}, use) => {
  const data = await seedReferenceData(); // slow
  await use(data);
  // no teardown writes here
}, { scope: 'worker' }],
```

## When NOT to Use POM

- Single-use scripts or smoke tests run once and discarded — the class adds
  boilerplate with zero reuse
- Tests with one locator and one assertion — wrapping adds indirection that
  obscures the intent
- Living-documentation tests where inline selectors communicate the user
  journey better than abstracted method names

## Locator Pattern: Define in Constructor, Use in Methods

Define all locators as class properties, never inline them in method bodies.
This makes the locator list a spec of what the page exposes:

```typescript
// Good — all selectors visible at the top
this.saveButton = page.getByRole('button', { name: 'Save changes' });

// Avoid — selector buried inside method, invisible from class interface
async save() {
  await this.page.getByRole('button', { name: 'Save changes' }).click();
}
```

## Component Objects for Reused UI Elements

For UI components that appear on multiple pages (nav, modals, toasts), create
a component object, not a page object:

```typescript
export class ToastComponent {
  readonly container: Locator;
  constructor(page: Page) {
    this.container = page.getByRole('status'); // toast region
  }
  async expectSuccess(message: string) {
    await expect(this.container).toContainText(message);
  }
}
```

Compose it into page objects that need it:

```typescript
export class DashboardPage {
  readonly toast: ToastComponent;
  constructor(page: Page) {
    this.toast = new ToastComponent(page);
    // ...
  }
}
```
