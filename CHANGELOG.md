# Changelog

## [0.6.0](https://github.com/zstary/makato/compare/v0.5.0...v0.6.0) (2026-06-19)


### ✨ Features

* **makato-core:** autonomous config.json-based repo and project resolution for create-issue ([#6](https://github.com/zstary/makato/issues/6)) ([1047805](https://github.com/zstary/makato/commit/10478056b4c60a252ae9e4f6bb29b71098ba0f96))
* **sensors:** execute sensor-harness PLAN v1.5 (KNOWLEDGE layer) ([#4](https://github.com/zstary/makato/issues/4)) ([a3f40ff](https://github.com/zstary/makato/commit/a3f40ffd74e48b85169995aa4a5fdc9cb5596651))

## [0.5.0](https://github.com/zstary/makato/compare/v0.4.0...v0.5.0) (2026-06-15)


### ✨ Features

* **build-simplify:** add skill for simplifying code complexity with interactive review ([bf06ade](https://github.com/zstary/makato/commit/bf06adef80fdfbf1d596691d654b3d5151cce52b))
* **build-start:** introduce entry point for build sessions with git validation and spec checks ([bf06ade](https://github.com/zstary/makato/commit/bf06adef80fdfbf1d596691d654b3d5151cce52b))
* **build-verify:** implement full quality gate pipeline for build verification ([bf06ade](https://github.com/zstary/makato/commit/bf06adef80fdfbf1d596691d654b3d5151cce52b))
* **excel:** add manage-microsoft-excel skill for Excel file operations ([e18b4aa](https://github.com/zstary/makato/commit/e18b4aaa93f19c827ea530772805638da512933e))
* **makato-change:** add AGENTS.md documentation for change request workflow ([17131cb](https://github.com/zstary/makato/commit/17131cbcbbe3b948ba78be2c0abf02320b4088e0))
* **makato-contribute:** add sync-from-upstream skill and rename makato-skill-creator ([#1](https://github.com/zstary/makato/issues/1)) ([fb09341](https://github.com/zstary/makato/commit/fb09341e6343bb69129593c9b0c108acf0cc08ea))
* **makato-core:** add contract specification for specs artifact folder ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-plan:** add arch-ux skill for UX design documents and wireframes ([03f4c6f](https://github.com/zstary/makato/commit/03f4c6f8de353ae44b9faf210711dcb7ea22a423))
* **makato-plan:** add github-issue-template for publish GitHub provider ([5f4e8dc](https://github.com/zstary/makato/commit/5f4e8dc8baeea59f10f088abfadc2f590ac69d89))
* **makato-plan:** add tools and testing reference for UX design ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-plan:** bump stories.json schema to v2.0 — remove Jira fields ([85b83da](https://github.com/zstary/makato/commit/85b83da1b9ed9ac4ee4026d4ed1635bb796772a0))
* **makato-plan:** create UX design document template ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-plan:** introduce create-ux skill for UX design documentation ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-plan:** rework brainstorming — 4-way input, slug-only folders, no Jira ([d266058](https://github.com/zstary/makato/commit/d266058c54997aa8b5e2c3ed4e237e1e343b6182))
* **makato-plan:** rewrite publish — local handoff always, GitHub Issues optional ([8af0a7d](https://github.com/zstary/makato/commit/8af0a7db4920facf760e408d27d2a4f6f7eb9452))
* **makato-plan:** update decompose — slug folders, no Jira references ([3a44443](https://github.com/zstary/makato/commit/3a444431b147be06c4b2d22179e4448198846fe1))
* **makato-ux:** add changelog for versioning and updates ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** add webapp-testing skill for local web application verification ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** create frontend-design skill for production-grade UI development ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** document CLAUDE integration for agent reference ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** implement e2e-testing-patterns skill for Playwright E2E testing ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** initialize makato-ux plugin with contributor guide and plugin manifest ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **makato-ux:** update README with plugin goals and installation instructions ([e9dc38d](https://github.com/zstary/makato/commit/e9dc38d396b5500ba9559269622cf57753adee71))
* **marketplace:** add makato-change plugin ([ea13c57](https://github.com/zstary/makato/commit/ea13c57034e34ef37db83893b7a9a444cecc37ad))
* **marketplace:** register makato-langgraph plugin ([#3](https://github.com/zstary/makato/issues/3)) ([9386d57](https://github.com/zstary/makato/commit/9386d5788dbe69b842591ec6abfd9cf09f9050fb))
* **pdf:** add manage-pdf skill for comprehensive PDF processing capabilities ([e18b4aa](https://github.com/zstary/makato/commit/e18b4aaa93f19c827ea530772805638da512933e))


### 🐛 Bug Fixes

* **makato-change:** replace daff-cr, daff-shape, github.tools.sap, JIRA_KEY ([5dd3499](https://github.com/zstary/makato/commit/5dd3499d2bbf6d481b06a903cca2a37494813b90))


### 🤖 CI

* **release:** upgrade release-please-action to v5 and fix PR creation ([1f39ca2](https://github.com/zstary/makato/commit/1f39ca2d016df8433aeba537f64a4f43c55a1747))
* upgrade actions/checkout v4 → v6 for Node.js 24 compatibility ([99afba9](https://github.com/zstary/makato/commit/99afba9b8757849aac124c566b92ccf85745b636))

## Changelog

All notable changes to the makato suite are documented here.
Entries are managed by [release-please](https://github.com/googleapis/release-please).
