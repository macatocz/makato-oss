---
name: better-icons
description: Search and retrieve production-ready SVG icons from 200+ libraries (Iconify) when building or refining a UI. Use when the user needs an icon, wants to find/replace icons, add icons to a component, or pick a consistent icon set. Provided as an MCP server (search_icons, get_icon, get_icons) with a CLI fallback.
version: "1.0.0"
user-invocable: true
argument-hint: "[icon concept, e.g. 'settings', 'arrow-right']"
---

## Audit Emission (MANDATORY)

This skill runs inside the makato-ux plugin, which requires JSONL audit entries at every
major boundary. Emit to the JSONL audit stream (stdout or the active session log file);
these are not written to the project source tree:

- **Session start**: `{"event":"skill_start","skill":"better-icons","step":0}`
- **After each major step**: `{"event":"step_complete","skill":"better-icons","step":<n>}`
- **Session end**: `{"event":"skill_end","skill":"better-icons","outcome":"complete|halted"}`

## Better Icons

Search and retrieve icons from 200+ libraries (Iconify) while building UI. Prefer real,
consistent iconography over ad-hoc inline SVGs so a feature reads as one system.

This plugin ships `better-icons` as an **MCP server** — the source is not vendored into
the repo; the server is launched on demand via `npx` (declared in the plugin's
`.mcp.json`, pinned to `better-icons@1.0.5`). Node.js must be available in the environment.

## MCP tools (preferred)

When the MCP server is connected, use its tools directly:

- **`search_icons`** — search across 200+ Iconify libraries; returns icon IDs
  (e.g. `lucide:home`). Start here.
- **`get_icon`** — get the SVG for one icon ID from a `search_icons` result.
- **`get_icons`** — get several icons at once (more efficient than repeated `get_icon`).

The server also exposes helpers for listing collections, recommendations, finding similar
icons, and adding an icon straight into a project's icons file. It learns which
collections you use most, so keep to one or two collections per surface for visual
consistency.

## CLI fallback

If the MCP server is unavailable, the same capability is reachable via the CLI without a
global install:

```bash
npx -y better-icons@1.0.5 search "arrow" --limit 10
npx -y better-icons@1.0.5 get lucide:home > icon.svg
```

## When to use

- Choosing an icon for a button, nav item, empty state, or status indicator
- Replacing inconsistent or generic icons with one coherent set
- Grounding `impeccable-frontend-design`, `polish`, or `arrange` output in real iconography

## Boundaries

- This skill only sources icon SVGs. Layout, sizing, and color-token application are the
  job of the design skills (`arrange`, `normalize`, `impeccable-frontend-design`).
- Respect the target repo's stack: inline the SVG or wire it through the project's
  existing icon component — do not add a new icon dependency the project does not use.
