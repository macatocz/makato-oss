---
name: penpot-uiux-design
description: >-
  Comprehensive guide for creating professional UI/UX designs in Penpot using
  MCP tools. Use this skill when: (1) Creating new UI/UX designs for web,
  mobile, or desktop applications, (2) Building design systems with components
  and tokens, (3) Designing dashboards, forms, navigation, or landing pages,
  (4) Applying accessibility standards and best practices, (5) Following
  platform guidelines (iOS, Android, Material Design), (6) Reviewing or
  improving existing Penpot designs for usability. Triggers: "design a UI",
  "create interface", "build layout", "design dashboard", "create form",
  "design landing page", "make it accessible", "design system",
  "component library".
version: 1.2.0
mcp_server: penpot
allowed-tools:
  - mcp__penpot__execute_code
  - mcp__penpot__export_shape
  - mcp__penpot__high_level_overview
  - mcp__penpot__penpot_api_info
metadata:
  last_updated: "2026-08-05"
---

# Penpot UI/UX Design Guide

Create professional, user-centered designs in Penpot using the Penpot MCP server.

## Available MCP Tools

| Tool | Purpose |
| ---- | ------- |
| `mcp__penpot__execute_code` | Run JavaScript in Penpot plugin context to create/modify designs |
| `mcp__penpot__export_shape` | Export shapes as PNG/SVG for visual inspection |
| `mcp__penpot__high_level_overview` | Read Penpot API overview — call once before first execute_code |
| `mcp__penpot__penpot_api_info` | Retrieve detailed Penpot API docs for a specific type or member |

> **No `mcp__penpot__import_image`** — not available in the cloud Penpot MCP. Use image fills via
> `shape.fills = [{ fillOpacity: 1, fillImage: { ... } }]` if image import is needed, or skip images
> and use color fills / SVG shapes instead.

## MCP Server Setup

### Check First — Server May Already Be Connected

**Always check if the MCP server is already available before attempting setup:**

1. Try calling `mcp__penpot__high_level_overview` — if it succeeds, the server is connected. No setup needed.
2. If the tool fails, ask the user whether the Penpot MCP is configured in their `.mcp.json`.

### Cloud Penpot MCP (Preferred)

The cloud Penpot MCP connects directly to `https://design.penpot.app` — no local servers or Node.js required.

Add to `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "penpot": {
      "type": "http",
      "url": "https://design.penpot.app/mcp/stream?userToken=<YOUR_TOKEN>"
    }
  }
}
```

To get a `userToken`:

1. Log in to [design.penpot.app](https://design.penpot.app)
2. Go to **Profile → Access Tokens**
3. Generate a new token and paste it into the URL

**The Penpot browser tab must be open and a design file must be active** for `execute_code` to work.
The cloud MCP does not use WebSockets or local ports.

### Local Penpot MCP (Alternative)

For self-hosted Penpot or offline work, see [setup-troubleshooting.md](references/setup-troubleshooting.md).

MANDATORY: load `references/setup-troubleshooting.md` when: user reports connection errors, port conflicts,
plugin not loading, WebSocket failures, or needs local/self-hosted Penpot setup.
Do NOT load for cloud Penpot users with a working token.

### Troubleshooting

| Issue | Solution |
| ----- | -------- |
| `execute_code` times out | Open Penpot in the browser and open a design file |
| Token auth error | Regenerate token in Penpot → Profile → Access Tokens |
| Tools not appearing | Reload plugins in Claude Code: `/reload-plugins` |
| Empty result from `execute_code` | Ensure a file is open — not just the Penpot dashboard |

## Quick Reference

| Task | Reference File | MANDATORY trigger |
| ---- | -------------- | ----------------- |
| MCP server installation & troubleshooting | [setup-troubleshooting.md](references/setup-troubleshooting.md) | Load when user has connection/setup issues |
| Component specs (buttons, forms, nav, cards, modals) | [component-patterns.md](references/component-patterns.md) | Load when creating or specifying any UI component |
| Accessibility (contrast, touch targets, WCAG) | [accessibility.md](references/accessibility.md) | Load when user asks about contrast, a11y, WCAG, or touch targets |
| Screen sizes & platform specs (iOS, Android, Material) | [platform-guidelines.md](references/platform-guidelines.md) | Load when designing for a specific platform or screen size |

**Do NOT load references pre-emptively.** Load each reference only at the MANDATORY trigger point above.

## Design Workflow

1. **Read the API overview first**: Call `mcp__penpot__high_level_overview` before the first `execute_code` call (it is deferred — call it once per session)
2. **Discover design context**: Query the active file for existing patterns before creating anything (see code below)
3. **Determine design system source** (see decision tree below)
4. **Understand the page**: Call `mcp__penpot__execute_code` with `penpotUtils.shapeStructure()` to see hierarchy
5. **Find elements**: Use `penpotUtils.findShapes()` to locate elements by type or name
6. **Position new boards**: Check existing board positions before creating (see Positioning section)
7. **Create/modify**: Use `penpot.createBoard()`, `penpot.createRectangle()`, `penpot.createText()` etc.
8. **Apply layout**: Use `addFlexLayout()` for responsive containers
9. **Validate**: Call `mcp__penpot__export_shape` to visually check your work
10. **Emit JSONL audit entries**: see `## Audit Emission (MANDATORY)` below for concrete payload shapes

## Audit Emission (MANDATORY)

This skill runs inside the makato-ux plugin, which requires JSONL audit entries at every
major boundary. Emit to the session log at:

- **Session start**: `{"event":"skill_start","skill":"penpot-uiux-design","step":0}`
- **After Step 1** (API overview read): `{"event":"step_complete","skill":"penpot-uiux-design","step":1}`
- **After Step 2** (design context discovered): `{"event":"step_complete","skill":"penpot-uiux-design","step":2,"colors_found":<count>,"components_found":<count>}`
- **After Step 3** (design system source determined): `{"event":"step_complete","skill":"penpot-uiux-design","step":3,"design_system_path":"user-provided|discovered|scratch"}`
- **After Step 4** (page hierarchy understood): `{"event":"step_complete","skill":"penpot-uiux-design","step":4}`
- **After Step 5** (elements located): `{"event":"step_complete","skill":"penpot-uiux-design","step":5,"shapes_found":<count>}`
- **After Step 6** (board positions checked): `{"event":"step_complete","skill":"penpot-uiux-design","step":6,"next_x":<px>}`
- **After Step 7** (shapes created or modified): `{"event":"step_complete","skill":"penpot-uiux-design","step":7,"shapes_created":<count>}`
- **After Step 8** (layout applied): `{"event":"step_complete","skill":"penpot-uiux-design","step":8}`
- **After Step 9** (design validated via export): `{"event":"step_complete","skill":"penpot-uiux-design","step":9,"export_ok":<true|false>}`
- **Session end**: `{"event":"skill_end","skill":"penpot-uiux-design","outcome":"complete|halted"}`

These are appended to the JSONL audit stream (stdout or the active session log file);
they are not written to the project source tree.

## Design System Decision Tree

**Before creating designs, determine the design system source.**

Use `AskUserQuestion` with these options:

```
Q: Do you have a design system or brand guidelines to follow?

Options:
  A) Yes — I have brand tokens/guidelines (describe or share them)
  B) Yes — discover from the current Penpot file
  C) No — start from scratch with sensible defaults
```

**Path A (user-provided tokens):** Use their specified colors, spacing, typography exactly. Match their naming conventions. Do not substitute defaults.

**Path B (discover from file):**

```javascript
// Discover existing design patterns in current file
const allShapes = penpotUtils.findShapes(() => true, penpot.root);

// Find existing colors in use
const colors = new Set();
allShapes.forEach(s => {
  if (s.fills) s.fills.forEach(f => colors.add(f.fillColor));
});

// Find existing text styles (font sizes, weights)
const textStyles = allShapes
  .filter(s => s.type === 'text')
  .map(s => ({ fontSize: s.fontSize, fontWeight: s.fontWeight }));

// Find existing components
const components = penpot.library.local.components;

return { colors: [...colors], textStyles, componentCount: components.length };
```

Adopt discovered colors and type scales. Do not override them with defaults.

**Path C (no design system):**
MANDATORY: load `references/component-patterns.md` before specifying any component dimensions or states.
Use an 8px spacing base scale (4/8/16/24/32/48px) as a starting point, offer to help establish consistent
patterns, and document the tokens used so they can be adopted as a system.

## Key Penpot API Gotchas

- `width`/`height` are READ-ONLY → use `shape.resize(w, h)`
- `parentX`/`parentY` are READ-ONLY → use `penpotUtils.setParentXY(shape, x, y)`
- Use `insertChild(index, shape)` for z-ordering (not `appendChild`)
- Flex children array order is REVERSED for `dir="column"` or `dir="row"`
- After `text.resize()`, reset `growType` to `"auto-width"` or `"auto-height"`
- `execute_code` return value must be explicitly `return`-ed — the last expression is NOT auto-returned
- `mcp__penpot__high_level_overview` must be called before accessing advanced API — it loads deferred type definitions

## Anti-patterns

**NEVER do these — each reflects a non-obvious failure mode confirmed by the Penpot API:**

1. **NEVER assign `shape.width = x` or `shape.height = x` directly.**
   WHY: These properties are read-only on all Penpot shape types. The assignment silently fails — the shape stays unchanged with no error thrown, and the design looks wrong only on visual export. Always use `shape.resize(w, h)`.

2. **NEVER use `appendChild` when z-order matters.**
   WHY: `appendChild` always inserts at the end of the children array (bottom of z-stack). In Penpot's flex layout and layer panels, z-order determines visual stacking. Use `insertChild(index, shape)` to place at the correct position.

3. **NEVER iterate flex children expecting top-to-bottom order for `dir="column"`.**
   WHY: Penpot stores flex children in a reversed array for column direction. Iterating index 0→N to build a top-to-bottom visual stack produces a visually upside-down layout. Reverse the array before building column layouts, or build bottom-up.

4. **NEVER call `text.resize()` without immediately resetting `growType`.**
   WHY: Calling `resize()` on a text shape implicitly changes `growType` to `"fixed"`. The text then clips or overflows instead of auto-sizing on subsequent edits. Always follow `text.resize(w, h)` with `text.growType = "auto-width"` (single-line) or `"auto-height"` (multi-line).

5. **NEVER omit `return` from `execute_code` snippets expecting a result.**
   WHY: Penpot's `execute_code` runs the code as a function body. The last expression value is NOT auto-returned (unlike browser console eval). Omitting `return` makes the tool appear to succeed but returns `undefined`, silently discarding audit data, IDs, or diagnostic outputs.

6. **NEVER call `execute_code` advanced API without first calling `mcp__penpot__high_level_overview`.**
   WHY: Penpot defers loading type definitions until `high_level_overview` is called. Skipping this in a new session causes `penpotUtils` and advanced shape methods to be undefined, producing cryptic `TypeError: penpotUtils is not defined` errors.

7. **NEVER create a new board without first querying existing board positions.**
   WHY: Penpot has no automatic layout for frames. New boards default to `x=0, y=0`, stacking invisibly on top of existing boards. The result looks like work was lost. Always compute `nextX` from existing board right-edges before creating (see Positioning section).

8. **NEVER verify cloud Penpot MCP setup by looking for `mcp__penpot__import_image`.**
   WHY: This tool does not exist in the cloud MCP (`design.penpot.app`). Checking for it as a setup-complete signal gives a false "broken" diagnosis and wastes time on non-existent troubleshooting. Cloud setup verification uses `execute_code`, `export_shape`, `high_level_overview`, and `penpot_api_info` only.

## Positioning New Boards

**Always check existing boards before creating new ones** to avoid overlap:

```javascript
// Find all existing boards and calculate next position
const boards = penpotUtils.findShapes(s => s.type === 'board', penpot.root);
let nextX = 0;
const gap = 100; // Space between boards

if (boards.length > 0) {
  // Find rightmost board edge
  boards.forEach(b => {
    const rightEdge = b.x + b.width;
    if (rightEdge + gap > nextX) {
      nextX = rightEdge + gap;
    }
  });
}

// Create new board at calculated position
const newBoard = penpot.createBoard();
newBoard.x = nextX;
newBoard.y = 0;
newBoard.resize(375, 812);
```

**Board spacing guidelines:**

- Use 100px gap between related screens (same flow)
- Use 200px+ gap between different sections/flows
- Align boards vertically (same y) for visual organization
- Group related screens horizontally in user flow order

## Validating Designs

Use these validation approaches with `mcp__penpot__execute_code`:

| Check | Method |
| ----- | ------ |
| Elements outside bounds | `penpotUtils.analyzeDescendants()` with `isContainedIn()` |
| Text too small (<12px) | `penpotUtils.findShapes()` filtering by `fontSize` |
| Missing contrast | Call `mcp__penpot__export_shape` and visually inspect |
| Hierarchy structure | `penpotUtils.shapeStructure()` to review nesting |

MANDATORY: load `references/accessibility.md` when the user asks about contrast ratios, WCAG compliance,
touch target sizes, or color accessibility. Do NOT load for layout-only or structure-only tasks.

### Export CSS

Use `penpot.generateStyle(selection, { type: 'css', includeChildren: true })` via `mcp__penpot__execute_code` to extract CSS from designs.
