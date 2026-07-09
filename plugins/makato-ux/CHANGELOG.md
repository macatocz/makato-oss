# Changelog — makato-ux

## [0.4.0] — 2026-07-09

### Added

- `config/skill-bundles.yml` (#145) — bundles `ux-skills`, `ux-frontend`, `ux-styles`, `ux-e2e`, `ux-design-spec` route React/TSX files, CSS/SCSS stylesheets, Playwright spec files, design spec markdown, and UX skill files to the appropriate UX skills.

## [0.3.0] — 2026-07-09

### Changed

- `penpot-uiux-design` skill updated to v1.1.0 — cloud Penpot MCP (HTTP token auth, no local server) as
  primary setup path; added `mcp__penpot__high_level_overview` to tool table and workflow step 1; removed
  unavailable `mcp__penpot__import_image`; added two API gotchas (`return` requirement, `high_level_overview`
  deferred load); simplified setup section for cloud-first usage

## [0.2.0] — 2026-06-15

### Added

- `frontend-design` skill — create production-grade HTML/CSS/React interfaces with bold intentional aesthetics
- `e2e-testing-patterns` skill — build reliable Playwright E2E test suites with POM, fixtures, and network mocking
- `webapp-testing` skill — verify and debug local web apps using the Playwright MCP browser

## [0.1.0] — 2026-06-14

### Initial release

- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- MCP server declarations (playwright)
