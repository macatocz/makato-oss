# Changelog

## [0.11.1](https://github.com/macatocz/makato/compare/v0.11.0...v0.11.1) (2026-06-26)


### ♻️ Refactors

* **plugins:** decouple scouts from dcp-specs; wire makato project board ([#39](https://github.com/macatocz/makato/issues/39)) ([02ccdf3](https://github.com/macatocz/makato/commit/02ccdf380a35baa20309551c27a94c57e0033ba9))

## [0.11.0](https://github.com/zstary/makato/compare/v0.10.0...v0.11.0) (2026-06-25)


### ✨ Features

* **makato-plan:** issue-to-project v2.7.0 implementation ([#19](https://github.com/zstary/makato/issues/19)) ([6ac3407](https://github.com/zstary/makato/commit/6ac3407a52f1d7cf0395c6d947804bbbb797443a))

## [0.10.0](https://github.com/zstary/makato/compare/v0.9.0...v0.10.0) (2026-06-25)


### ✨ Features

* **makato-plan:** issue-to-project v1.0.0–v2.6.0 (O1–O7 capabilities) ([#15](https://github.com/zstary/makato/issues/15)) ([95ab4b1](https://github.com/zstary/makato/commit/95ab4b15a98e0f1f1ef1db71b0508340d72ff76f))

## [0.9.0](https://github.com/zstary/makato/compare/v0.8.0...v0.9.0) (2026-06-24)


### ✨ Features

* **makato-plan:** add type:future-enhancement to to-issues taxonomy (v3.1.0) ([#12](https://github.com/zstary/makato/issues/12)) ([2b1a1ff](https://github.com/zstary/makato/commit/2b1a1ffe7ce0d3ded7f33cfff8d158248d758643))
* **makato-plan:** rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0) ([#14](https://github.com/zstary/makato/issues/14)) ([6326513](https://github.com/zstary/makato/commit/632651309471c9e474c9fb22b93935b0f7378f7b))

## [0.8.0](https://github.com/zstary/makato/compare/v0.7.0...v0.8.0) (2026-06-23)


### ⚠ BREAKING CHANGES

* **makato-plan:** to-issues now targets github.com only. The 2.x github.concur.com / GH_ENTERPRISE_TOKEN / project-information.md wiring is removed. The project name is read from .claude/config.json (fallback 'sagibeast'). All issues now carry a 4-dimension label set (type/tier/tech/module) inferred from the story text and ADR folder names. A specs/<slug>/created-issues.json artifact is written for downstream skills (build-create-pr) to consume. Set DRY_RUN=1 to exercise the skill without calling the GitHub API.

### ✨ Features

* **makato-build:** inject Closes #N from created-issues.json into PR body (v1.3.0) ([3fc8d6a](https://github.com/zstary/makato/commit/3fc8d6a34f04424d7d8745001bb94f2c612ae046))
* **makato-plan:** add created-issues.json schema (to-issues v3 contract) ([a96683d](https://github.com/zstary/makato/commit/a96683da5fe6f690abfab389a165292912e1d73a))
* **makato-plan:** add issue-template reference for to-issues v3 ([912f225](https://github.com/zstary/makato/commit/912f2259f3340df637b3f99e4ab8a9cbc6a24b00))
* **makato-plan:** add label-taxonomy reference for to-issues v3 ([e26fa5f](https://github.com/zstary/makato/commit/e26fa5ff81591214e49e88239c010b2fb291645d))
* **makato-plan:** rewrite to-issues as generic marketplace skill (v3.0.0) ([2678628](https://github.com/zstary/makato/commit/26786289ccbcb0612e46117eb1b26655dfa38933))
* **makato-sagibeast:** add sagibeast-connect-testbox and sagibeast-create-testbox skills ([8b7432a](https://github.com/zstary/makato/commit/8b7432a7020148fcdf5861e1831c7bee5a456629))
* **makato-sagibeast:** scaffold plugin with governance and marketplace registration ([d5bd829](https://github.com/zstary/makato/commit/d5bd829c44040b2352c981457fd16ecf34e0d700))


### 🐛 Bug Fixes

* **makato-build:** rename daff.config.json discovery hook to makato.config.json ([3c7d63d](https://github.com/zstary/makato/commit/3c7d63d305d05bd12dda250b4f363d7f032f1035))
* **makato:** macOS sed portability and stale daff-* reference in build-create-pr ([3067fd4](https://github.com/zstary/makato/commit/3067fd46f3c7bcda65f99d6d6ef3799f584790d0))
* **makato:** remove remaining daff-* references from new to-issues redesign ([b9633ee](https://github.com/zstary/makato/commit/b9633eeaff696d9feda24799ec0929bcd9d7e171))
* **repo:** add top-level version, gitignore .superpowers/, scrub daff from issue templates, track design plans ([a197cc9](https://github.com/zstary/makato/commit/a197cc9b90936910810cb3436e8dd5b619bb74eb))


### ♻️ Refactors

* **makato-core:** move dotx-schema-extractor, manage-pdf, manage-microsoft-excel to makato-sagibeast ([8059fa5](https://github.com/zstary/makato/commit/8059fa5b56d70c536a3123c05b303f3cfd278428))


### 🤖 CI

* remove redundant plugin/skill checks from validate workflow ([cf9249a](https://github.com/zstary/makato/commit/cf9249aa53b19fbf6724292fecd8d0191539c060))

## [0.7.0](https://github.com/zstary/makato/compare/v0.6.0...v0.7.0) (2026-06-21)


### ✨ Features

* **makato-core:** add 5 foundation skills aligned to suite standards ([#10](https://github.com/zstary/makato/issues/10)) ([6e86218](https://github.com/zstary/makato/commit/6e86218a1a45d243ece84dc74b8ccc868386d205))
* **makato-database:** scaffold plugin with manage-postgres skill ([#8](https://github.com/zstary/makato/issues/8)) ([4addf08](https://github.com/zstary/makato/commit/4addf083980927b339b312d5b0a9d0fc291ffb66))

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
