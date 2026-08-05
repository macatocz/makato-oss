# playwright-config.md

Recommended `playwright.config.ts` for a full production project with auth
isolation, parallel workers, and CI/local branching.

## Canonical Config

```typescript
import { defineConfig, devices } from '@playwright/test';
import os from 'os';

const IS_CI = !!process.env.CI;

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  retries: IS_CI ? 2 : 0,
  workers: IS_CI ? Math.max(1, Math.floor(os.cpus().length / 2)) : 'auto',
  reporter: IS_CI ? [['html'], ['junit', { outputFile: 'results.xml' }]] : [['html']],

  // Global timeout for each test
  timeout: 30_000,

  // Retry timeout resets per attempt — set this lower than timeout
  expect: { timeout: 5_000 },

  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',
    trace: IS_CI ? 'on-first-retry' : 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    // Auth setup runs once; each worker writes to its own file
    {
      name: 'setup',
      testMatch: '**/global-setup.ts',
    },
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: ({ workerInfo }) =>
          `playwright/.auth/worker-${workerInfo.workerIndex}.json`,
      },
      dependencies: ['setup'],
    },
    {
      name: 'firefox',
      use: {
        ...devices['Desktop Firefox'],
        storageState: ({ workerInfo }) =>
          `playwright/.auth/worker-${workerInfo.workerIndex}.json`,
      },
      dependencies: ['setup'],
    },
    {
      name: 'mobile',
      use: { ...devices['Pixel 5'] },
      // No auth dependency if mobile suite is public-facing
    },
  ],

  // Visual regression baselines
  snapshotPathTemplate: '{testDir}/__screenshots__/{testFilePath}/{arg}{ext}',
});
```

## Key Config Decisions

### `fullyParallel: true` + auth dependency
Without `dependencies: ['setup']`, tests start before auth files exist and fail.
The project dependency graph ensures setup runs first for authenticated projects.

### `trace: 'on-first-retry'` in CI
Generating traces on every run adds significant storage overhead. `on-first-retry`
captures the trace only when something went wrong, at the first retry — before
the test is retried again and possibly passes.

### `workers` in CI
`os.cpus().length` on a GitHub Actions runner reports 2 CPUs; using `'auto'`
gives 2 workers. For a large suite, this is fine. On self-hosted runners with
more cores, `Math.floor(os.cpus().length / 2)` prevents memory pressure from
too many browser instances.

### `baseURL` via environment variable
Never hardcode a port in `playwright.config.ts`. Different developers run
different ports; CI may vary. Always allow `BASE_URL` override.

## `.gitignore` additions

```
playwright/.auth/
playwright-report/
test-results/
```

Commit baseline screenshots but never auth state files — they contain session
tokens.

## Visual Regression: `snapshotPathTemplate`

Using a path that includes `{testFilePath}` keeps baselines next to the test
that generated them, making it obvious when a test is deleted that its baselines
should be deleted too.

Generate baselines from the CI environment, not from local macOS. See the
Anti-patterns section in SKILL.md for why.
