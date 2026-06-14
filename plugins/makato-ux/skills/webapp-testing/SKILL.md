---
name: webapp-testing
description: Test and verify local web applications using the Playwright MCP browser — screenshots, functional checks, DOM inspection, console logs, UI debugging. Use when verifying a UI change works, checking for regressions, or debugging frontend behaviour in a running app.
version: "1.0.0"
---

# webapp-testing

## When to Use

- Verifying a UI change works before declaring it done
- Checking for visual regressions after a code change
- Debugging why a UI element is not rendering or behaving correctly
- Capturing screenshots of specific states for review
- Reading browser console logs to diagnose frontend errors

## When NOT to Use

- Writing reusable E2E test suites — use `e2e-testing-patterns`
- Testing backend APIs without a UI — use curl or unit tests
- Building the UI itself — use `frontend-design`

---

## Workflow

### Step 1: Confirm the App is Running

Check whether the dev server is already running. If not, start it before proceeding:

```bash
npm run dev       # or: yarn dev, pnpm dev, npx serve, etc.
```

Note the port (commonly 3000, 5173, 8080). All subsequent browser actions use this base URL.

### Step 2: Navigate and Wait

Use the Playwright MCP `browser_navigate` to open the target URL, then wait for the page
to fully load before inspecting or interacting:

- Always call `browser_wait_for` with `networkidle` or a known element after navigation
- Dynamic apps (React, Vue, etc.) render asynchronously — inspecting before load completes
  returns stale or empty DOM

### Step 3: Inspect and Verify

Choose the right tool for the task:

- **`browser_snapshot`** — accessibility tree of the current page; best for finding
  selectors and verifying element presence without a screenshot
- **`browser_take_screenshot`** — pixel-level visual capture; use for regression checks
  or sharing current state
- **`browser_console_messages`** — read JS errors, warnings, and logs since last navigation

For DOM state questions, prefer `browser_snapshot` over screenshot — it is faster and
returns structured data you can reason about.

### Step 4: Interact

To test user flows, use the Playwright MCP interaction tools in order:

1. `browser_click` — click buttons, links, or any element
2. `browser_type` — fill inputs and textareas
3. `browser_select_option` — choose dropdown values
4. After each interaction, call `browser_snapshot` or `browser_wait_for` to confirm
   the expected state change occurred

For multi-step flows (login → navigate → action), chain interactions with a snapshot
between each step to verify intermediate states.

### Step 5: Report Findings

Summarise what was verified:

- What was tested (URL, element, flow)
- What passed (element present, text correct, no console errors)
- What failed or needs attention (missing element, unexpected error, visual regression)
- Screenshots or snapshot excerpts as evidence

If a bug is found, describe the reproduction steps and the expected vs actual behaviour.
