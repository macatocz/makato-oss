# accessibility-testing.md

Axe-core integration with Playwright for automated WCAG compliance checks.

## Setup

```bash
npm install --save-dev @axe-core/playwright
```

```typescript
import AxeBuilder from '@axe-core/playwright';
```

## Basic Page-Level Assertion

```typescript
test('home page has no accessibility violations', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});
```

Run at the page level **after** the page has fully loaded including async
content. Running before async content loads produces false passes — violations
inside lazy-loaded components are missed.

## WCAG Level Configuration

```typescript
// Default (axe-core default is WCAG 2.x AA)
await new AxeBuilder({ page }).analyze();

// Explicit WCAG 2.1 AA
await new AxeBuilder({ page })
  .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
  .analyze();

// WCAG 2.2 AA + best practices
await new AxeBuilder({ page })
  .withTags(['wcag22aa', 'best-practice'])
  .analyze();
```

## Scoping to a Component

Run axe against a specific region rather than the full page — useful when a
page embeds third-party widgets you cannot control:

```typescript
const results = await new AxeBuilder({ page })
  .include('#main-content') // CSS selector
  .analyze();
expect(results.violations).toEqual([]);
```

You can also exclude a known-offending region while the fix is in progress:

```typescript
const results = await new AxeBuilder({ page })
  .exclude('#legacy-widget') // document the reason in a comment
  .analyze();
```

## Handling Known Violations (Intentional Exclusions)

When a violation is a known false positive or a tracked debt item, disabling
it without documentation is a maintenance trap. Use `disableRules` with a
comment and a link to the tracking issue:

```typescript
const results = await new AxeBuilder({ page })
  // color-contrast: dark-mode toggle not yet implemented — tracked in #1234
  .disableRules(['color-contrast'])
  .analyze();
```

Never use `.disableRules` without a comment explaining why and linking to where
the real fix will happen.

## Interpreting Violations

```typescript
const results = await new AxeBuilder({ page }).analyze();
if (results.violations.length > 0) {
  // Print human-readable violation summary on failure
  const formatted = results.violations
    .map(v => `${v.id}: ${v.description} (${v.nodes.length} element(s))`)
    .join('\n');
  throw new Error(`Accessibility violations:\n${formatted}`);
}
```

Each violation object includes:
- `id` — rule identifier (e.g., `color-contrast`, `button-name`)
- `description` — what the rule checks
- `nodes` — array of DOM elements that failed, each with `target` (CSS path)
  and `failureSummary`
- `helpUrl` — link to the axe-core rule documentation

## Fixture-Based Integration

Add an `a11y` fixture that wraps AxeBuilder for reuse across tests:

```typescript
// tests/fixtures.ts
import AxeBuilder from '@axe-core/playwright';
import { test as base } from '@playwright/test';

type A11yFixture = {
  checkA11y: (options?: { include?: string; exclude?: string }) => Promise<void>;
};

export const test = base.extend<A11yFixture>({
  checkA11y: async ({ page }, use) => {
    const check = async ({ include, exclude }: { include?: string; exclude?: string } = {}) => {
      let builder = new AxeBuilder({ page });
      if (include) builder = builder.include(include);
      if (exclude) builder = builder.exclude(exclude);
      const results = await builder.analyze();
      expect(results.violations).toEqual([]);
    };
    await use(check);
  },
});
```

Usage in tests:

```typescript
test('checkout flow is accessible', async ({ page, checkA11y }) => {
  await page.goto('/checkout');
  await checkA11y({ exclude: '#legacy-payment-widget' });
});
```

## When axe-core Is Not Enough

Axe-core catches structural violations (missing alt text, wrong ARIA roles,
color contrast failures). It does NOT catch:
- Focus trap failures (e.g., modal does not trap focus)
- Keyboard navigation order issues (visually logical but DOM order differs)
- Screen-reader announcement wording

For those, add explicit keyboard navigation tests:

```typescript
test('modal traps focus', async ({ page }) => {
  await page.keyboard.press('Tab');
  // confirm focus stays inside modal — check focused element
  await expect(page.locator(':focus')).toHaveAttribute(
    'data-within-modal', 'true'
  );
});
```
