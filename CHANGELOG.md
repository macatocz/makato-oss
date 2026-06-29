# Changelog

## [0.23.1](https://github.com/macatocz/makato/compare/v0.23.0...v0.23.1) (2026-06-29)


### 🐛 Bug Fixes

* **makato-build:** pre-merge hardening pass for WORKTREE_PATH propagation ([#85](https://github.com/macatocz/makato/issues/85)) ([#90](https://github.com/macatocz/makato/issues/90)) ([4f8f9f1](https://github.com/macatocz/makato/commit/4f8f9f1368120822358bbffc0e974e28ab000e77))

## [0.23.0](https://github.com/macatocz/makato/compare/v0.22.0...v0.23.0) (2026-06-29)


### ✨ Features

* **makato-build:** propagate WORKTREE_PATH into build-* skills and coder ([#85](https://github.com/macatocz/makato/issues/85)) ([#87](https://github.com/macatocz/makato/issues/87)) ([5f92355](https://github.com/macatocz/makato/commit/5f923552ef05cb7258e4554c3fefe6a5d88069fb))
* **makato-orchestrate:** add documentation-agent for post-merge docs (GAP-012, [#35](https://github.com/macatocz/makato/issues/35)) ([#89](https://github.com/macatocz/makato/issues/89)) ([3c64090](https://github.com/macatocz/makato/commit/3c64090225bdbd2a833a35520e038ca13b08297a))

## [0.22.0](https://github.com/macatocz/makato/compare/v0.21.0...v0.22.0) (2026-06-29)


### ✨ Features

* **makato-orchestrate:** worktree lifecycle management in po-agent (GAP-017, [#46](https://github.com/macatocz/makato/issues/46)) ([#84](https://github.com/macatocz/makato/issues/84)) ([e021e2e](https://github.com/macatocz/makato/commit/e021e2ef16c07f6d3f0354fb73124066c3de6034))

## [0.21.0](https://github.com/macatocz/makato/compare/v0.20.1...v0.21.0) (2026-06-29)


### ✨ Features

* **makato-build:** inject-context bundle resolver (GAP-008, [#25](https://github.com/macatocz/makato/issues/25)) ([#81](https://github.com/macatocz/makato/issues/81)) ([ef00d3d](https://github.com/macatocz/makato/commit/ef00d3d9349e93b59671d49606d5c0c0e47f4cad))
* **makato-orchestrate:** per-task scout agent for file pre-reading (GAP-013, [#29](https://github.com/macatocz/makato/issues/29)) ([#83](https://github.com/macatocz/makato/issues/83)) ([a1355d0](https://github.com/macatocz/makato/commit/a1355d0f0d9930fd195f9027ed6513d614869688))

## [0.20.1](https://github.com/macatocz/makato/compare/v0.20.0...v0.20.1) (2026-06-28)


### 🐛 Bug Fixes

* **makato-build:** split semgrep:* route into security vs style ([#73](https://github.com/macatocz/makato/issues/73)) ([#79](https://github.com/macatocz/makato/issues/79)) ([444327e](https://github.com/macatocz/makato/commit/444327e0c86b4227e2ede0d1e95e833595e5d767))

## [0.20.0](https://github.com/macatocz/makato/compare/v0.19.0...v0.20.0) (2026-06-28)


### ✨ Features

* **makato-build:** build-fix-security skill — bandit/safety per-CWE 4-branch playbook ([#72](https://github.com/macatocz/makato/issues/72)) ([#77](https://github.com/macatocz/makato/issues/77)) ([6bbc377](https://github.com/macatocz/makato/commit/6bbc3770b0eed06ff1a25e8e7834285268024329))
* **makato-build:** definition-of-done shared skill (GAP-009, [#28](https://github.com/macatocz/makato/issues/28)) ([#76](https://github.com/macatocz/makato/issues/76)) ([84ffbef](https://github.com/macatocz/makato/commit/84ffbeffd99a67bc71c54de12adb765ec7136cca))

## [0.19.0](https://github.com/macatocz/makato/compare/v0.18.0...v0.19.0) (2026-06-28)


### ✨ Features

* **makato-build:** build-fix-types skill — pyright/mypy type-error repair ([#71](https://github.com/macatocz/makato/issues/71)) ([#75](https://github.com/macatocz/makato/issues/75)) ([320b938](https://github.com/macatocz/makato/commit/320b938323f15c7a12f673a41638d0c2a859a499))
* **makato-orchestrate:** /loop skill — autonomous polling driver (GAP-007 / [#33](https://github.com/macatocz/makato/issues/33)) ([#70](https://github.com/macatocz/makato/issues/70)) ([8258776](https://github.com/macatocz/makato/commit/8258776abb40603e545bf3e2fe7caf082b3cb610))

## [0.18.0](https://github.com/macatocz/makato/compare/v0.17.0...v0.18.0) (2026-06-28)


### ✨ Features

* **makato-build:** finding-routes autofix audit; residual MD0xx→makato-core:markdown ([#59](https://github.com/macatocz/makato/issues/59)) ([#62](https://github.com/macatocz/makato/issues/62)) ([9239c4f](https://github.com/macatocz/makato/commit/9239c4fdf5a82863873fc99850333fe4df221e1e))

## [0.17.0](https://github.com/macatocz/makato/compare/v0.16.0...v0.17.0) (2026-06-28)


### ✨ Features

* **makato-build:** build-simplify joins autonomous mode ([#57](https://github.com/macatocz/makato/issues/57)) ([#63](https://github.com/macatocz/makato/issues/63)) ([6bfada2](https://github.com/macatocz/makato/commit/6bfada23c6ec0087f0b8dc91b01383dae2883bfd))

## [0.16.0](https://github.com/macatocz/makato/compare/v0.15.0...v0.16.0) (2026-06-28)


### ✨ Features

* **makato-build:** sensor-fixer Phase 0 batched autofix + autofix-then-skill action ([#60](https://github.com/macatocz/makato/issues/60)) ([#61](https://github.com/macatocz/makato/issues/61)) ([bdba866](https://github.com/macatocz/makato/commit/bdba8666982e148ffb3a0e8a13add9f94e85045f))
* **repo:** pre-commit-config scoped to makato's actual file types ([#65](https://github.com/macatocz/makato/issues/65)) ([6c74600](https://github.com/macatocz/makato/commit/6c746004117c08a100159b70e31eaed150f7ef3d))

## [0.15.0](https://github.com/macatocz/makato/compare/v0.14.0...v0.15.0) (2026-06-28)


### ✨ Features

* **makato-orchestrate:** po-agent — top-level autonomous orchestrator (GAP-006, [#32](https://github.com/macatocz/makato/issues/32)) ([#56](https://github.com/macatocz/makato/issues/56)) ([1ae56ac](https://github.com/macatocz/makato/commit/1ae56acf7e620c6fe4681041b8ef5265eb6cd67c))

## [0.14.0](https://github.com/macatocz/makato/compare/v0.13.0...v0.14.0) (2026-06-28)


### ✨ Features

* **makato-orchestrate:** kill-switch + context-handoff (GAP-004, [#30](https://github.com/macatocz/makato/issues/30)) ([#55](https://github.com/macatocz/makato/issues/55)) ([f6f55a6](https://github.com/macatocz/makato/commit/f6f55a6fc76560bcc1a8c82fd84e007f73213abc))
* **makato-orchestrate:** workflow-state schema + skill (GAP-003, [#26](https://github.com/macatocz/makato/issues/26)) ([#53](https://github.com/macatocz/makato/issues/53)) ([94a001e](https://github.com/macatocz/makato/commit/94a001ea82adde141514a11e7164bfcfdbb9b379))

## [0.13.0](https://github.com/macatocz/makato/compare/v0.12.0...v0.13.0) (2026-06-27)


### ✨ Features

* **makato-build:** autonomous-mode for build-* approval gates ([#27](https://github.com/macatocz/makato/issues/27)) ([#47](https://github.com/macatocz/makato/issues/47)) ([efe0432](https://github.com/macatocz/makato/commit/efe0432ffdad4c98e9b2d64593caea83360caa2b))
* **makato-orchestrate:** scaffold plugin for autonomous control plane (GAP-001) ([#49](https://github.com/macatocz/makato/issues/49)) ([eeb4250](https://github.com/macatocz/makato/commit/eeb42502649e36eb588121a3715a33851d4cd277)), closes [#23](https://github.com/macatocz/makato/issues/23)

## [0.12.0](https://github.com/macatocz/makato/compare/v0.11.1...v0.12.0) (2026-06-27)


### ✨ Features

* **makato-plan:** to-issues v3.4.0 — severity/phase/effort/priority/points dimensions ([#41](https://github.com/macatocz/makato/issues/41)) ([f26cf61](https://github.com/macatocz/makato/commit/f26cf61f0fd5c76f18583962ab9a0f58e0f0392e))

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
