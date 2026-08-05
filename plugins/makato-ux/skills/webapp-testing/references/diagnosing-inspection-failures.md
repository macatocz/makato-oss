# Diagnosing Inspection Failures

## Failure taxonomy for Playwright MCP inspection

When an inspection step returns unexpected results, classify before acting:

| Symptom | Most likely cause | Next step |
|---|---|---|
| Snapshot shows empty page body | JS not yet executed (async render) | `browser_wait_for text="<known element>"` then re-snapshot |
| Expected element absent in snapshot | Shadow DOM / iframe / stale ref | Check for `<iframe>` tags; try `browser_evaluate` |
| `browser_click` reports "not found" | Selector ref is stale after re-render | Re-call `browser_snapshot` to get fresh refs, click again |
| `browser_wait_for text` never resolves | Text is inside iframe or Shadow DOM | Switch to `browser_take_screenshot` + visual check |
| Console shows no errors but UI is wrong | Silently swallowed error or wrong state | Check `browser_network_requests` for failed API calls |
| Snapshot ref works but click has no effect | Element is covered by overlay/modal | Look for `aria-modal` or `role=dialog` in snapshot; dismiss first |

## Stale accessibility tree selectors

The accessibility tree ref values (e.g. `ref="42"`) are generated per `browser_snapshot`
call and are valid ONLY until the next DOM mutation. After any interaction (`browser_click`,
`browser_type`, `browser_fill_form`) always call `browser_snapshot` again before using
a ref from a previous call. Using a stale ref silently targets the wrong element or fails
with a cryptic error — it does NOT warn you the ref is stale.

## Large page snapshot truncation

`browser_snapshot` on pages with thousands of DOM nodes returns a truncated tree.
When you see refs cut off mid-tree, scope the snapshot:

```
browser_snapshot target="<selector for the component under test>"
```

Scoping to a container element reduces noise and prevents ref truncation. Always scope
when testing a specific component rather than a full page.

## Network-caused rendering failures

A blank or partially rendered page despite navigation completing is often a failed
background API call. Before assuming a frontend bug:

1. Call `browser_network_requests static=false` filtered to `/api/`
2. Inspect failed requests for 401/403/500 responses
3. Only investigate frontend code after ruling out API failures

This order saves significant debugging time — frontend symptoms often mask backend causes.

## Port detection

When the dev server port is unknown, check for a running process before assuming defaults:

```bash
lsof -i :3000 -i :5173 -i :8080 -i :4173 | grep LISTEN
```

Do not guess the port. A wrong port produces "connection refused" which looks identical
to a server-not-started failure.
