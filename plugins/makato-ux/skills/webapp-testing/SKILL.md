---
name: webapp-testing
description: >-
  Test and verify local web applications using the Playwright MCP browser —
  screenshots, functional checks, DOM inspection, console logs, UI debugging.
  Use when verifying a UI change works, checking for regressions, or debugging
  frontend behaviour in a running app. Triggers: verify UI, screenshot, check
  rendering, debug frontend, console errors, visual regression, DOM inspection,
  browser check, webapp test.
version: "1.1.0"
metadata:
  last_updated: "2026-08-05"
mcp_server: plugin:playwright
allowed-tools:
  - mcp__plugin_playwright_playwright__browser_navigate
  - mcp__plugin_playwright_playwright__browser_snapshot
  - mcp__plugin_playwright_playwright__browser_take_screenshot
  - mcp__plugin_playwright_playwright__browser_wait_for
  - mcp__plugin_playwright_playwright__browser_click
  - mcp__plugin_playwright_playwright__browser_type
  - mcp__plugin_playwright_playwright__browser_fill_form
  - mcp__plugin_playwright_playwright__browser_select_option
  - mcp__plugin_playwright_playwright__browser_console_messages
  - mcp__plugin_playwright_playwright__browser_network_requests
  - mcp__plugin_playwright_playwright__browser_evaluate
  - mcp__plugin_playwright_playwright__browser_tabs
  - mcp__plugin_playwright_playwright__browser_find
  - Bash
---

# webapp-testing

This skill is for **spot-checking a running app** — verifying a change worked,
diagnosing a rendering bug, capturing evidence of current state. It is NOT for
authoring repeatable test suites; use `e2e-testing-patterns` for that.

The key practitioner insight: Playwright MCP's accessibility-tree tools
(`browser_snapshot`, `browser_find`) and screenshot tools address different
failure modes. Knowing which to reach for — and what each misses — is the
entire skill.

## When to Use

- Verifying a UI change works before declaring it done
- Checking for visual regressions after a code change
- Debugging why a UI element is not rendering or behaving correctly
- Capturing screenshots of specific states for review
- Reading browser console logs to diagnose frontend errors
- Confirming a multi-step user flow executes without errors

## When NOT to Use

- Writing reusable E2E test suites — use `e2e-testing-patterns`
- Testing backend APIs without a UI — use curl or unit tests
- Building the UI itself — use `frontend-design`
- Prototyping or UX validation — use `makato-plan/create-prototype`

---

## Audit Emission (MANDATORY)

This skill runs inside the makato-ux plugin, which requires JSONL audit entries at every
major boundary. Emit to the session log at:

- **Session start**: `{"event":"skill_start","skill":"webapp-testing","step":0}`
- **After Step 1** (server confirmed running): `{"event":"step_complete","skill":"webapp-testing","step":1,"port":<port>}`
- **After Step 2** (navigation and render confirmed): `{"event":"step_complete","skill":"webapp-testing","step":2,"url":"<url>"}`
- **After Step 3** (snapshot inspected): `{"event":"step_complete","skill":"webapp-testing","step":3,"elements_found":<true|false>}`
- **After Step 4** (interactions completed): `{"event":"step_complete","skill":"webapp-testing","step":4}`
- **After Step 5** (console and network checked): `{"event":"step_complete","skill":"webapp-testing","step":5,"errors_found":<true|false>}`
- **After Step 6** (findings reported): `{"event":"step_complete","skill":"webapp-testing","step":6}`
- **Session end**: `{"event":"skill_end","skill":"webapp-testing","outcome":"complete|halted"}`

These are appended to the JSONL audit stream (stdout or the active session log file);
they are not written to the project source tree.

---

## Inspection Strategy: choosing the right tool

Before touching any tool, decide which inspection axis matters:

| What you need to know | Primary tool | Fallback |
|---|---|---|
| Is an element present / what is its text? | `browser_snapshot` (or `browser_find`) | `browser_take_screenshot` + visual |
| Does the page look visually correct? | `browser_take_screenshot` | — |
| Are there JS errors / console warnings? | `browser_console_messages` | — |
| Did an API call fail silently? | `browser_network_requests` | — |
| Is an element inside Shadow DOM or iframe? | `browser_evaluate` | `browser_take_screenshot` + note |
| Does the element respond to a click? | `browser_click` then `browser_snapshot` | — |

Prefer `browser_snapshot` over `browser_take_screenshot` when the question is
about DOM state — it is faster, returns structured refs you can target for
interactions, and does not consume screenshot tokens.

Prefer `browser_take_screenshot` when:
- The question is visual (layout, spacing, colour)
- You need evidence to share with a human reviewer
- `browser_snapshot` returns no refs (Shadow DOM / iframe — see below)

---

## Workflow

### Step 1: Confirm the App is Running

Check whether the dev server is already running. If the port is unknown, detect it:

```bash
lsof -i :3000 -i :5173 -i :8080 -i :4173 | grep LISTEN
```

If no process is found, start the server:

```bash
# common commands — confirm with project README
npm run dev       # or: yarn dev, pnpm dev, npx serve
```

Do NOT guess the port. A wrong port produces "connection refused" — identical
to a server-not-started failure, wasting a full diagnostic cycle.

### Step 2: Navigate and Wait for Render

Navigate, then wait for a known element — NOT a fixed time:

```
browser_navigate → http://localhost:<PORT>/path
browser_wait_for text="<text only present when the page has rendered>"
```

**Why `text` over `time`**: React, Vue, and other SPA frameworks render
asynchronously. `browser_wait_for time=2` passes on a fast machine and fails
on a slow CI runner. `text` waits for actual DOM content — environment-independent.

Use `time` only when you explicitly need to observe an intermediate animation
frame or a transient UI state (tooltip hover, loading spinner).

If the page requires authentication, load `@references/auth-and-complex-flows.md`
now — **MANDATORY** before attempting any login flow or testing a protected route.

**Do NOT load** `auth-and-complex-flows.md` if the page is publicly accessible
without login.

### Step 3: Inspect and Verify

Scope your snapshot to the component under test to prevent ref truncation:

```
browser_snapshot target="<selector for the section under test>"
```

Scoping matters: on pages with thousands of DOM nodes, an unscoped
`browser_snapshot` truncates the tree mid-render. Truncated trees produce
stale or missing refs that cause subsequent `browser_click` calls to silently
target the wrong element.

For broad page surveys (first look, unknown structure), an unscoped snapshot
is fine — just re-scope before any interaction.

If the expected element is absent from the snapshot despite being visually
present, load `@references/diagnosing-inspection-failures.md` — **MANDATORY**
before spending time on selector hunting.

**Do NOT load** `diagnosing-inspection-failures.md` on the happy path when
the element is found on first snapshot.

### Step 4: Interact

After each interaction, always re-snapshot before using any ref:

```
browser_click ref="<ref from snapshot>"
browser_snapshot target="<same scope>"   ← ALWAYS before next ref use
browser_click ref="<ref from NEW snapshot>"
```

Accessibility tree refs are valid ONLY until the next DOM mutation. A ref
from a snapshot taken before a click is stale the moment the click fires a
re-render. This is the single most common source of confusing "element not
found" failures — the element exists, but the ref no longer points to it.

For multi-step flows (login, navigate, fill form, submit):

```
1. Complete login (see auth-and-complex-flows.md if needed)
2. Navigate to target page, wait for render
3. Snapshot (scoped), extract refs
4. Interact (click / type)
5. Snapshot again (same scope), verify state change
6. Repeat 3-5 for each step
```

### Step 5: Check Console and Network on Failure

When a UI state is wrong but no DOM explanation is visible:

```
browser_console_messages level=error
browser_network_requests static=false filter="/api/"
```

Check network requests BEFORE diving into DOM debugging. A blank or
partially rendered page is most often a failed background API call (401,
500) — not a frontend bug. Diagnosing the wrong layer wastes time.

### Step 6: Report Findings

Structure findings as:

- **Tested**: URL, element, flow, browser state at test time
- **Passed**: element present, text correct, no console errors, flow completed
- **Failed**: what was missing or wrong, with snapshot excerpt or screenshot as evidence
- **Reproduction**: exact steps to reproduce a failure
- **Suspected cause**: DOM issue / API failure / auth / Shadow DOM constraint

---

## Anti-patterns

**NEVER use stale accessibility tree refs after an interaction.**
Refs like `ref="42"` are regenerated on every `browser_snapshot` call. After
any `browser_click`, `browser_type`, or `browser_fill_form`, the DOM has
mutated — old refs silently target wrong elements or fail cryptically. Always
call `browser_snapshot` again before using a ref from a previous call.

**NEVER call `browser_wait_for time=N` to wait for async render.**
Fixed-time waits pass on fast machines and fail on slow CI or loaded laptops.
They also add wall-clock time when the page renders faster than N seconds.
Use `browser_wait_for text="<known content>"` to wait for actual DOM evidence.

**NEVER call an unscoped `browser_snapshot` on pages with large DOM trees
before an interaction.**
Unscoped snapshots on 1000+ node trees return truncated output. Refs from a
truncated tree are incomplete and may be absent entirely. Scope to the
component: `browser_snapshot target="<container>"`.

**NEVER assume `browser_snapshot` covers shadow DOM or iframe content.**
The accessibility tree does not cross iframe boundaries or shadow roots. An
element visually present but absent in the snapshot is inside one of these
boundaries — not a transient render issue. Reaching for `browser_find` or
re-running the snapshot repeatedly will not help. Use `browser_evaluate` or
fall back to `browser_take_screenshot` and document the constraint.

**NEVER start diagnosing frontend code when the page is blank or half-rendered
without first checking `browser_network_requests`.**
Most blank-page bugs are a failed API call returning 401/403/500, not a
JavaScript error. Checking network requests takes 5 seconds; debugging the
frontend rendering pipeline takes 30 minutes.

**NEVER start a test session without confirming the dev server port.**
Guessing the port (assuming 3000, assuming 5173) produces "connection refused"
errors that are indistinguishable from a server crash. Run
`lsof -i :3000 -i :5173 -i :8080 | grep LISTEN` first.

---

## Edge Cases

### Framework-specific timing (React 18 concurrent, Vue Suspense)

React 18 concurrent mode and Vue Suspense can produce a visible intermediate
state (skeleton / spinner) before final content loads. If `browser_wait_for`
resolves on the skeleton text and your snapshot catches the loading state,
add a second `browser_wait_for text="<final content text>"` after the first.
Do not use `time` — the hydration window is variable.

### Multi-tab flows (OAuth, PDF viewer, new window)

OAuth redirects and some external links open a new browser tab. After any
click that may open a new tab:

```
browser_tabs action=list
browser_tabs action=select index=<new tab index>
browser_wait_for text="<expected landing page content>"
```

Without the tab switch, subsequent tool calls operate on the original tab
context — a silent failure that looks like the navigation did nothing.

**MANDATORY load trigger**: Load `@references/auth-and-complex-flows.md`
before testing any OAuth flow, login sequence, or multi-tab scenario.

### Overlays blocking interactions

If `browser_click` completes without error but produces no state change,
the click may have landed on an overlay or modal covering the target element.
Check the snapshot for `role=dialog`, `aria-modal=true`, or a high z-index
container. Dismiss the overlay first, then retry the click.
