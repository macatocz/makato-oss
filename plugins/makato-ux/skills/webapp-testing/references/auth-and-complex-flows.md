# Auth and Complex Flows Reference

## Login flows with Playwright MCP

When testing pages behind authentication, the session cookie is NOT persisted between
`browser_navigate` calls unless you manage it explicitly. The MCP browser context
resets per session restart but persists across tool calls within the same session.

### Decision: should you log in during the test?

| Scenario | Approach |
|---|---|
| Verifying the login page itself | Navigate to `/login`, fill form, snapshot post-login state |
| Verifying a protected page | Log in first in Step 2, then navigate to the protected route |
| Auth state already present (page already loaded with session) | Skip login — call `browser_snapshot` to confirm the auth UI is rendered |

### Login flow pattern

```
1. browser_navigate → /login
2. browser_wait_for text="Email" (or known field label)
3. browser_type → email input selector
4. browser_type → password input selector
5. browser_click → submit button
6. browser_wait_for text="<element only present when logged in>"
7. Proceed with the actual test
```

Critical: use `browser_wait_for` with a `text` that only appears in the authenticated
state, NOT `time` — timing is non-deterministic under CPU load.

## Iframe contexts

`browser_snapshot` does NOT cross iframe boundaries by default. Symptoms:
- You expect an element to appear in the snapshot but it is absent
- `browser_click` fails with "element not found" despite being visually present

Identify iframe presence: look for `<iframe>` in `browser_snapshot` output. If the
target element is inside an iframe, the only MCP tool option is `browser_evaluate`
with `document.querySelector('iframe').contentDocument...` — recognize this is
fragile and document it.

When you cannot reach into an iframe via snapshot, fall back to `browser_take_screenshot`
to visually confirm and note the iframe constraint in the findings report.

## Multi-tab flows

`browser_tabs list` before and after any action that opens a new tab (OAuth redirects,
PDF viewers, help pages) — the active tab context shifts and subsequent tool calls
operate on the wrong tab if you do not switch.

## Shadow DOM

Elements inside a Shadow DOM are NOT visible to `browser_snapshot`'s accessibility
tree. Symptoms identical to iframe: element visually present, absent in snapshot refs.

Identification: look for `mode: open/closed` in source, or Web Component custom
element names (`<my-component>`, `<app-*>`). When shadow DOM is confirmed, use
`browser_evaluate` with `shadowRoot.querySelector(...)` and report the constraint.
