# makato-ux

**Goal:** Turn working backend code into a shippable, production-grade user interface.

**How:** Reads existing code, spec artifacts, and design system tokens, then applies
production-grade frontend patterns to produce a deployable UI layer — HTML/CSS, React
components, and JavaScript — verified by browser-based testing through Playwright MCP.

**Why:** Engineers who build clean backend code still face the gap between a working API
and a user-facing product. This plugin closes that gap without requiring dedicated UX
specialists, so a single session can take built code to a shippable interface.

## What Belongs Here

- Frontend deployment — bundling, hosting, and CI/CD for UI artifacts
- UI design — translating specs and design tokens into styled components
- Webapp testing — browser-based functional and visual regression tests via Playwright
- HTML/CSS creation — markup and styling for UI surfaces
- React and JavaScript — component authoring, state management, and interactivity

## What Does NOT Belong Here

- Prototypes and mockups — exploratory HTML for UX validation (use `makato-plan/create-prototype`)
- Diagrams and flowcharts — architecture or workflow visualizations (use `makato-plan`)
- Backend or API implementation — server logic, database, infrastructure (use `makato-build`)
- Story decomposition or planning (use `makato-plan`)

## Workflow

```
makato-plan artifacts          makato-build artifacts
(prototype.html, ux.md)  ───►  (working code, prd.md, design.md)
                                        │
                                        ▼
                          ┌─────────────────────────┐
                          │     frontend-design      │
                          │     (interactive)        │
                          │                          │
                          │ In:  spec artifacts,     │
                          │      design tokens,      │
                          │      existing codebase   │
                          │ Out: HTML/CSS/React,     │
                          │      WCAG AA, responsive │
                          └────────────┬────────────┘
                                       │
                                       ▼
                          ┌─────────────────────────┐
                          │     webapp-testing       │
                          │     (interactive)        │
                          │                          │
                          │ In:  running dev server  │
                          │ Out: screenshots, DOM    │
                          │      snapshots, pass/    │
                          │      fail summary        │
                          └────────────┬────────────┘
                                       │ formalize test coverage:
                                       ▼
                          ┌─────────────────────────┐
                          │  e2e-testing-patterns    │
                          │     (interactive)        │
                          │                          │
                          │ In:  app URL + scenarios │
                          │ Out: Playwright POM      │
                          │      suite, fixtures,    │
                          │      CI config           │
                          └─────────────────────────┘
```

**Phase summaries:**

- `frontend-design`: Spec artifacts + design tokens → production UI code (HTML/CSS/React), WCAG AA compliant, responsive.
- `webapp-testing`: Running dev server URL → verified screenshots, DOM inspection, functional pass/fail report.
- `e2e-testing-patterns`: App URL + test scenarios → Playwright test suite with POM, fixtures, and CI-ready config.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`frontend-design`](skills/frontend-design/SKILL.md) | Create distinctive, production-grade frontend interfaces — HTML/CSS, React, components, pages, dashboards, landing pages, web UI. Avoids generic AI aesthetics in favour of bold intentional design with design token discovery and WCAG AA validation. (interactive) | Spec artifacts (`prd.md`, `design.md`), design system tokens from existing codebase, and the UI requirements or redesign target | Production HTML/CSS/React code with design tokens applied, WCAG AA compliant, responsive across mobile/tablet/desktop breakpoints | 1.0.0 |
| [`e2e-testing-patterns`](skills/e2e-testing-patterns/SKILL.md) | Build reliable Playwright E2E test suites using Page Object Model, fixtures, waiting strategies, network mocking, and accessibility testing. Use when implementing or debugging end-to-end tests for a production UI. (interactive) | Target app URL and test scenarios (user journeys, flows, accessibility requirements to cover) | Playwright test suite with Page Object Model classes, fixtures, CI-ready `playwright.config.ts`, and axe accessibility checks | 1.0.0 |
| [`webapp-testing`](skills/webapp-testing/SKILL.md) | Test and verify local web applications using the Playwright MCP browser — screenshots, DOM inspection, console logs, functional checks, and UI debugging. Use when verifying a UI change works or debugging frontend behaviour. (interactive) | Running local dev server URL (e.g. `localhost:3000`) and the UI state or flow to verify | Verification report with screenshots, accessibility snapshots, console log findings, and pass/fail summary of tested flows | 1.0.0 |

## Notable Governance Files

| File | Purpose |
|------|---------|
| [`AGENTS.md`](AGENTS.md) | Contributor guide, PR checklist, decision rules |
| [`CLAUDE.md`](CLAUDE.md) | @-includes AGENTS.md so subagents inherit contributor guidance |
| [`CHANGELOG.md`](CHANGELOG.md) | Release-please managed changelog |
| [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) | Plugin manifest consumed by Claude Code |
| [`.mcp.json`](.mcp.json) | Playwright MCP server declaration |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Consumes from | `makato-build` | Working backend code and spec artifacts (`prd.md`, `design.md`) consumed as input for `frontend-design` |
| Consumes from | `makato-plan` | `prototype.html` as UI reference; `ux.md` for screen inventory and interaction patterns consumed by `frontend-design` |
| Complementary | `makato-observability` | E2E tests written with `e2e-testing-patterns` can assert on OTel spans wired by `makato-observability` |

## Prerequisites / MCP Servers

| Server | Purpose | Required |
|--------|---------|----------|
| `playwright` | Browser-based UI testing and interaction — used by `webapp-testing` and `e2e-testing-patterns` to navigate, screenshot, inspect DOM, and interact with running web apps | Yes |

Install the Playwright MCP server before using any skill that drives a browser:

```bash
npx @playwright/mcp@latest install
```

## Installation

```bash
claude --plugin-dir ./plugins/makato-ux
```

## Version

0.1.0
