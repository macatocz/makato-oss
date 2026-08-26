---
name: e2e-testing-patterns
description: >-
  Build reliable E2E test suites with Playwright using Page Object Model,
  fixtures, auth state management, waiting strategies, and network mocking —
  e2e-tests, playwright, flaky-tests, ci-testing, accessibility-tests,
  visual-regression, browser-testing, parallel-workers, storageState. Use
  when implementing or debugging end-to-end tests for a production UI.
version: "1.1.0"
metadata:
  last_updated: "2026-08-05"
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

## Audit Emission (MANDATORY)

This skill runs inside the makato-ux plugin, which requires JSONL audit entries at every
major boundary. Emit to the session log at:

- **Session start**: `{"event":"skill_start","skill":"e2e-testing-patterns","step":0}`
- **After Step 1** (scope assessed): `{"event":"step_complete","skill":"e2e-testing-patterns","step":1}`
- **After Step 2** (Playwright configured): `{"event":"step_complete","skill":"e2e-testing-patterns","step":2,"target_env":"local|ci|both"}`
- **After Step 3** (auth strategy set): `{"event":"step_complete","skill":"e2e-testing-patterns","step":3,"auth_pattern":"per-worker|inject|none"}`
- **After Step 4** (tests written): `{"event":"step_complete","skill":"e2e-testing-patterns","step":4,"pom_used":<true|false>}`
- **After Step 5** (async handling confirmed): `{"event":"step_complete","skill":"e2e-testing-patterns","step":5}`
- **After Step 6** (network mocking decided): `{"event":"step_complete","skill":"e2e-testing-patterns","step":6,"mocking":<true|false>}`
- **After Step 7** (accessibility assertions added): `{"event":"step_complete","skill":"e2e-testing-patterns","step":7}`
- **After Step 8** (run and debug): `{"event":"step_complete","skill":"e2e-testing-patterns","step":8,"tests_passing":<true|false>}`
- **Session end**: `{"event":"skill_end","skill":"e2e-testing-patterns","outcome":"complete|halted"}`

These are appended to the JSONL audit stream (stdout or the active session log file);
they are not written to the project source tree.

---

## Workflow

### Step 1: Assess Scope

Decide what belongs at E2E vs a faster layer. The deciding question:
**Does the test require a real browser rendering cycle or multiple service
boundaries to produce a meaningful signal?**

- **E2E**: critical user journeys, multi-step forms, drag-and-drop, cross-browser
  compatibility, authentication flows, real API integration end-to-end
- **Not E2E**: internal implementation details, every edge case, API contracts

If the honest answer is "no" — move it to a unit or integration test. Every
extra E2E test adds to total suite time quadratically once parallelism is
constrained.

### Step 2: Configure Playwright

**MANDATORY load trigger**: Load `@references/playwright-config.md` before
writing any `playwright.config.ts` — auth project dependencies and
`fullyParallel` interact in non-obvious ways that the reference covers.

**Do NOT load** `playwright-config.md` if the project already has a
`playwright.config.ts` you are not changing.

Ask the user with AskUserQuestion (selectable options):

```
What is the target test environment?
[ ] Local dev only — no CI
[ ] CI/CD pipeline (GitHub Actions, GitLab CI, etc.)
[ ] Both local + CI
```

Set values based on the answer:

| Setting           | Local                          | CI                                  |
| ----------------- | ------------------------------ | ----------------------------------- |
| `retries`       | `0`                          | `2`                               |
| `workers`       | `'auto'`                     | `4` (or `os.cpus().length / 2`) |
| `reporter`      | `['html']`                   | `['html', 'junit']`               |
| `fullyParallel` | `true` if tests are isolated | `true` if tests are isolated      |

Never set `retries` above 2 — it masks genuinely broken tests (see Anti-patterns).

### Step 3: Auth State and Parallel Workers

**This is the #1 source of non-deterministic E2E failures in parallel suites.**
Read this section before writing any authentication fixture.

Playwright workers run in separate OS processes. If all workers share one
`storageState` file (the pattern in Playwright's own quick-start), concurrent
workers fight over the same session cookie: one worker's token refresh or
logout invalidates the others mid-test. The failure is non-deterministic
and vanishes when you rerun serially, making it nearly impossible to diagnose
without knowing this pattern.

**Correct pattern**: one auth file per worker index.

```typescript
// tests/global-setup.ts — runs once per worker via project dependency
import { test as setup } from '@playwright/test';

setup('authenticate', async ({ page, workerInfo }) => {
  await page.goto('/login');
  await page.fill('[name=email]', `user+${workerInfo.workerIndex}@example.com`);
  await page.fill('[name=password]', process.env.TEST_PASSWORD!);
  await page.click('[type=submit]');
  await page.waitForURL('/dashboard');
  await page.context().storageState({
    path: `playwright/.auth/worker-${workerInfo.workerIndex}.json`,
  });
});
```

Reference this in `playwright.config.ts` using a project dependency:

```typescript
projects: [
  { name: 'setup', testMatch: '**/global-setup.ts' },
  {
    name: 'chromium',
    use: {
      storageState: ({ workerInfo }) =>
        `playwright/.auth/worker-${workerInfo.workerIndex}.json`,
    },
    dependencies: ['setup'],
  },
],
```

**When `workers: 1` is the right answer**: tests that mutate shared database
state (e.g., "create order → verify in admin panel" using the same DB row) must
run serially. Apply it at the describe level:

```typescript
test.describe.configure({ mode: 'serial' });
```

**Faster auth injection** (skip the UI login flow entirely):

```typescript
await page.addInitScript(() => {
  window.localStorage.setItem('auth_token', process.env.TEST_TOKEN!);
});
await page.goto('/dashboard'); // arrives already authenticated
```

Use this when the login UI is covered by its own dedicated test and the auth
state only needs to be present, not tested.

### Step 4: Write Tests Using Page Object Model

**MANDATORY load trigger**: Load `@references/page-object-model.md` before
writing any page object class — the fixture-based pattern in the reference
avoids the most common POM scope trap.

**Do NOT load** `page-object-model.md` if this is a single-file throwaway
script, a one-off smoke test, or a test with one locator and one assertion —
the overhead of a class adds no value.

Decision: when NOT to use POM:

- Spike scripts (run once, delete)
- Tests that serve as living documentation — inline selectors sometimes communicate the flow better
- Trivial tests with < 3 actions — wrapping adds indirection with no gain

Selector priority (most to least stable):

1. `getByRole` — matches ARIA roles; survives CSS refactors; validates accessibility as a side effect
2. `getByLabel` — matches form labels; survives DOM restructuring
3. `getByText` — matches visible text; survives class changes
4. `data-testid` attribute — explicit test hook; always stable; requires dev cooperation
5. CSS class — avoid; breaks on refactoring

**Expert rule**: prefer `getByRole` over `data-testid` for interactive elements.
If you cannot locate an element by role, the element likely has an accessibility
defect — the selector failure surfaces it early.

Use `test.step()` to label each logical phase inside a test. This makes the
trace viewer show exactly which phase failed, not just which line:

```typescript
test('user completes checkout', async ({ page, checkoutPage }) => {
  await test.step('add item to cart', async () => { ... });
  await test.step('enter shipping', async () => { ... });
  await test.step('confirm payment', async () => { ... });
});
```

### Step 5: Handle Async Correctly

**MANDATORY load trigger**: Load `@references/waiting-strategies.md` when
diagnosing flaky tests or writing any wait or assertion logic.

**Do NOT load** `waiting-strategies.md` for tests with no dynamic content
(static pages, pre-rendered HTML with no loading states).

Core rules:

- Never use `page.waitForTimeout(N)` — creates timing-dependent flakiness
- Use `expect(locator).toBeVisible()` — auto-waits up to the configured timeout
- For network-dependent state: `page.waitForResponse(urlPattern)` before the
  triggering action, not after
- For navigation: `page.waitForURL('/target')` after the click

**Non-obvious `beforeAll` trap**: `test.beforeAll` shares state across all
tests in the same `describe` block — if one test mutates that state (adds a
row, changes a flag), subsequent tests see the mutation. Reserve `beforeAll`
for expensive read-only setup (seeding reference data). Use `beforeEach` for
everything that must start clean.

**`expect.soft()` for multi-assertion tests**: when you need to collect several
failures in one test run rather than aborting on the first:

```typescript
await expect.soft(page.getByRole('heading')).toHaveText('Dashboard');
await expect.soft(page.getByRole('button', { name: 'Logout' })).toBeVisible();
expect(test.info().errors).toHaveLength(0);
```

### Step 6: Mock Network When Needed

**MANDATORY load trigger**: Load `@references/network-mocking.md` before
writing any `page.route()` handler or simulating error states.

**Do NOT load** `network-mocking.md` for tests that are specifically validating
real API integration — those must not mock.

Decision tree for mocking:

```
Does the test validate API integration end-to-end?
  YES → do NOT mock; use real API
  NO  → Is the service unreliable / slow / rate-limited / paid?
    YES → mock it
    NO  → Is a deterministic response shape required for assertion?
      YES → mock it (control exact response)
      NO  → prefer real API (less maintenance burden)
```

Always add a catch-all fallback when partially mocking a complex page — without
it, unmatched routes hang until timeout:

```typescript
await page.route('**/api/specific-endpoint', handler);
await page.route('**', route => route.continue()); // catch-all — must be last
```

### Step 7: Add Accessibility Tests

**MANDATORY load trigger**: Load `@references/accessibility-testing.md` when
adding axe-core assertions for the first time, or when configuring WCAG level
or exclusion rules.

**Do NOT load** `accessibility-testing.md` for purely non-visual internal
tooling with no accessibility requirements.

For every new user-facing page or component:

```typescript
const results = await new AxeBuilder({ page }).analyze();
expect(results.violations).toEqual([]);
```

Run at the page level after full render, not inside `beforeAll` — axe needs
the final DOM state including async-loaded content.

### Step 8: Run and Debug

```bash
npx playwright test --headed              # see the browser
npx playwright test --debug               # step through with inspector
npx playwright test tests/login.spec.ts   # single file
npx playwright test --last-failed         # re-run only the tests that failed last run
npx playwright test --shard=1/4           # distribute across 4 CI machines
npx playwright test --repeat-each=3       # confirm a test is truly flaky
npx playwright test --reporter=junit      # CI mode
```

Set `PLAYWRIGHT_HTML_OPEN=never` in CI to prevent the HTML reporter from
attempting to open a browser after the run.

Flakiness diagnosis sequence:

1. Add `test.step()` labels — the trace viewer pins the failure to a named phase
2. Run `--repeat-each=5` to confirm intermittency (one failure is not flakiness)
3. If failure is timing-based: replace any `waitForTimeout` with `waitForResponse` or `waitForURL`
4. If failure is selector-based: check role availability; the element may be inside a shadow DOM or an iframe
5. Reduce `workers` to 1 to rule out parallel state contention as the cause
6. Use `page.pause()` mid-test locally to inspect DOM state at the failure point

### Step 9: Visual Regression (Optional)

**MANDATORY load trigger**: Load `@references/playwright-config.md` for
`snapshotPathTemplate` and `expect.toHaveScreenshot` baseline configuration.

```typescript
await expect(page).toHaveScreenshot('homepage.png', { maxDiffPixelRatio: 0.01 });
```

**Use `maxDiffPixelRatio` not `maxDiffPixels`**: a pixel count threshold fails
on responsive layouts when viewport size varies; a ratio is viewport-agnostic.

**CI vs local divergence**: screenshots taken on macOS (Core Text renderer,
Retina DPI) differ from Linux CI (FreeType/Noto fonts, different pixel ratio)
even at identical viewport sizes — this is the most common cause of visual
regression tests that "always pass locally but fail in CI". Two options:

- Generate and commit baselines inside a Docker container that matches the CI
  image; never regenerate baselines on macOS
- Alternatively, use `--ignore-snapshots` locally and enforce visual regression
  only in CI

Commit baseline screenshots alongside the tests. Regenerate with
`npx playwright test --update-snapshots` only from inside the CI-matched environment.

---

## Anti-patterns

### NEVER share a single storageState file across parallel workers

WHY: Workers run in separate OS processes and will race to read/write the same
session file. A token refresh or logout from one worker silently invalidates
another worker's active session mid-test. The failure is non-deterministic,
disappears on serial rerun, and is almost impossible to diagnose without knowing
this is the cause. Each worker must own its auth file (indexed by `workerIndex`).

### NEVER use `waitForTimeout` to stabilize a flaky test

WHY: A hardcoded delay is a guess at timing that bets on the slowest environment
you have ever tested on. It will be too short on an overloaded CI runner and
unnecessarily slow locally. It does not fix the root cause — it hides it. Use
`waitForResponse`, `waitForURL`, or `expect(locator).toBeVisible()` to wait for
the actual condition the test needs.

### NEVER exceed `retries: 2` in CI

WHY: A test that requires 3 retries to pass is a broken test. High retry counts
let flaky tests accumulate invisibly — the suite reports green while a growing
fraction of the coverage is unreliable. Cap at 2; investigate failures rather
than retry them away.

### NEVER write test ordering dependencies

WHY: If test B depends on side effects from test A, the suite fails
non-deterministically in parallel mode or when test A is filtered. The failure
cannot be reproduced by running the failing test alone. Each test must set up
and tear down its own required state via `beforeEach`.

### NEVER mock network in tests that validate API integration

WHY: Mocking turns the test into a tautology — you assert that your mock returns
what you told it to return, not that the real service works. Keep integration
tests network-real; use mocking only for tests that are deliberately validating
UI behaviour in isolation from the backend.

### NEVER use nth-child or positional selectors

WHY: Positional selectors break when any sibling element is added, removed, or
reordered — a CSS refactor unrelated to your feature will silently break the
test. The failure gives no signal about what actually changed. Use `getByRole`,
`getByLabel`, or `data-testid`.

### NEVER regenerate screenshot baselines on macOS when CI runs Linux

WHY: macOS uses Core Text for font rendering; Linux CI typically uses FreeType
with Noto fonts. Even at the same viewport and scale factor, character spacing
and antialiasing differ enough to produce pixel-level mismatches. Baselines
committed from macOS cause every visual regression check to fail in CI, making
the visual suite permanently broken until rebuilt from the right environment.

---

## References

| File                                                           | Load When                                                                                      |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| [playwright-config.md](references/playwright-config.md)         | Writing or editing`playwright.config.ts`; auth project dependencies; visual regression setup |
| [page-object-model.md](references/page-object-model.md)         | Writing or refactoring page object classes; fixture-scoped POM pattern                         |
| [waiting-strategies.md](references/waiting-strategies.md)       | Diagnosing flakiness; writing any wait or assertion logic                                      |
| [network-mocking.md](references/network-mocking.md)             | Writing`page.route()` handlers; simulating error states; partial mocking                     |
| [accessibility-testing.md](references/accessibility-testing.md) | Adding axe-core assertions; configuring WCAG level or exclusion rules                          |
