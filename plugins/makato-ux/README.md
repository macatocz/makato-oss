# makato-ux

**Goal**: Transform built code into a production UX platform.

**How**: Discovers existing code and design system, applies the prototype
pattern from create-prototype, and produces a deployable UI layer —
HTML/CSS, React components, and JavaScript — verified by browser-based
testing via Playwright.

**Why**: Provides a graphical interface above code artifacts without
requiring UX skills from the engineer — closing the gap between working
backend code and a shippable user-facing product.

## What Belongs Here

- Frontend deployment — bundling, hosting, and CI/CD for UI artifacts
- UI design — translating specs and design tokens into styled components
- Webapp testing — browser-based functional and visual regression tests
  via Playwright
- HTML/CSS creation — markup and styling for UI surfaces
- React and JavaScript — component authoring, state management, and
  interactivity

## What Does NOT Belong Here

- Prototypes and mockups — exploratory HTML for UX validation only
  (use makato-plan/create-prototype)
- Diagrams and flowcharts — architecture or workflow visualizations
  (use makato-plan)
- Backend or API implementation — server logic, database, infrastructure
  (use makato-build)
- Story decomposition or planning (use makato-plan)

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `frontend-design` | Create production-grade HTML/CSS/React interfaces with bold intentional aesthetics, design token discovery, and WCAG AA validation. | 1.0.0 |
| `e2e-testing-patterns` | Build reliable Playwright E2E test suites using Page Object Model, fixtures, waiting strategies, network mocking, and accessibility testing. | 1.0.0 |
| `webapp-testing` | Verify and debug local web apps using the Playwright MCP browser — screenshots, DOM inspection, console logs, functional checks. | 1.0.0 |

## Prerequisites

### MCP Servers

This plugin declares the following MCP servers:

| Server | Purpose |
|--------|---------|
| `playwright` | Browser-based UI testing and interaction |

Install the Playwright MCP server before using skills that run browser tests:

```bash
npx @playwright/mcp@latest install
```

## Installation

```bash
claude --plugin-dir ./plugins/makato-ux
```

## Version

0.1.0
