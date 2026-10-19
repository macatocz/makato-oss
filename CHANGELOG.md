# Changelog

## [0.172.0](https://github.com/macatocz/makato-oss/compare/v0.171.1...v0.172.0) (2026-10-19)


### ⚠ BREAKING CHANGES

* agent frontmatter no longer carries `modelRole:`. Agents added to the repo need an entry in config/agent-roles.yml and the matching `model:` alias. Every profile must map the new `orchestrator` role, and the installer merges into existing OMP files instead of replacing them (merging needs PyYAML).

### ✨ Features

* route every makato agent through a shared model role ([#173](https://github.com/macatocz/makato-oss/issues/173)) ([e749e20](https://github.com/macatocz/makato-oss/commit/e749e203f2f5a90f3d97e611aff5bfaa7e78e193))

## [0.171.1](https://github.com/macatocz/makato-oss/compare/v0.171.0...v0.171.1) (2026-10-18)


### 🐛 Bug Fixes

* scope PR closing links to the current work item ([#163](https://github.com/macatocz/makato-oss/issues/163)) ([#170](https://github.com/macatocz/makato-oss/issues/170)) ([6990a1d](https://github.com/macatocz/makato-oss/commit/6990a1d18cf02ba11d960820765876bf9a4ca94d))

## [0.171.0](https://github.com/macatocz/makato-oss/compare/v0.170.2...v0.171.0) (2026-10-17)


### ✨ Features

* **makato-build:** targeted implementation tests, CI-owned integration and coverage ([#164](https://github.com/macatocz/makato-oss/issues/164)) ([#167](https://github.com/macatocz/makato-oss/issues/167)) ([b22a2db](https://github.com/macatocz/makato-oss/commit/b22a2db6eb0821f45f757a38368df00d99fd030e))

## [0.170.2](https://github.com/macatocz/makato-oss/compare/v0.170.1...v0.170.2) (2026-10-17)


### 🐛 Bug Fixes

* **repo:** keep interactive OMP handoffs in clean contexts ([#165](https://github.com/macatocz/makato-oss/issues/165)) ([12600d6](https://github.com/macatocz/makato-oss/commit/12600d6af134acd9e4482fa0e4de889b52533450))

## [0.170.1](https://github.com/macatocz/makato-oss/compare/v0.170.0...v0.170.1) (2026-10-17)


### 🐛 Bug Fixes

* **orchestrate:** keep append-lesson compatible with jq 1.6 ([#161](https://github.com/macatocz/makato-oss/issues/161)) ([b3c530a](https://github.com/macatocz/makato-oss/commit/b3c530aca78701b48c1adb6e873c2d6afa1a7830))

## [0.170.0](https://github.com/macatocz/makato-oss/compare/v0.169.0...v0.170.0) (2026-10-17)


### ✨ Features

* **orchestrate:** dependency-aware mixed-mode task scheduling ([#153](https://github.com/macatocz/makato-oss/issues/153)) ([#157](https://github.com/macatocz/makato-oss/issues/157)) ([608936d](https://github.com/macatocz/makato-oss/commit/608936ddd6d79512c4028814c4fd855585dba72e))

## [0.169.0](https://github.com/macatocz/makato-oss/compare/v0.168.5...v0.169.0) (2026-10-17)


### ✨ Features

* **build:** coders run targeted RED/GREEN; bounded review/verify repair loops ([#148](https://github.com/macatocz/makato-oss/issues/148)) ([#149](https://github.com/macatocz/makato-oss/issues/149)) ([bd46934](https://github.com/macatocz/makato-oss/commit/bd4693443667594fd8f23df5cfc9d31b3660af4c))

## [0.168.5](https://github.com/macatocz/makato-oss/compare/v0.168.4...v0.168.5) (2026-10-17)


### 🐛 Bug Fixes

* port issue-scoped lesson capture and immediate promotion to main ([#123](https://github.com/macatocz/makato-oss/issues/123)) ([#147](https://github.com/macatocz/makato-oss/issues/147)) ([f463fc6](https://github.com/macatocz/makato-oss/commit/f463fc61cedc548748fb57e10abcd527d128abd8))

## [0.168.4](https://github.com/macatocz/makato-oss/compare/v0.168.3...v0.168.4) (2026-10-17)


### 🐛 Bug Fixes

* **makato-build:** make coders own verification and continue unverified results ([#146](https://github.com/macatocz/makato-oss/issues/146)) ([1c19c86](https://github.com/macatocz/makato-oss/commit/1c19c86b3e3185b8440e5e3e34ed537d788ee3a4))
* **makato-orchestrate:** accept classified HALT entries in reshape requests ([#142](https://github.com/macatocz/makato-oss/issues/142)) ([#144](https://github.com/macatocz/makato-oss/issues/144)) ([a5cd4b4](https://github.com/macatocz/makato-oss/commit/a5cd4b4a60484cfd354cf032c3813cfb5756ef04))
* **makato-orchestrate:** start headless OMP dispatches in a fresh session ([#143](https://github.com/macatocz/makato-oss/issues/143)) ([#145](https://github.com/macatocz/makato-oss/issues/145)) ([5dd1cb1](https://github.com/macatocz/makato-oss/commit/5dd1cb1a79365046cc056ebb4b6dcc1ede2412cc))

## [0.168.3](https://github.com/macatocz/makato-oss/compare/v0.168.2...v0.168.3) (2026-10-16)


### 🐛 Bug Fixes

* **loop:** raise watchdog stall defaults to 6 h warn / 12 h kill ([#135](https://github.com/macatocz/makato-oss/issues/135)) ([16ec2f1](https://github.com/macatocz/makato-oss/commit/16ec2f191e8eb3fb475a657d045133d767237aa7))
* **makato-orchestrate:** honour MAKATO_TARGET_REPO_ROOT for workflow state and lessons ([#137](https://github.com/macatocz/makato-oss/issues/137)) ([#140](https://github.com/macatocz/makato-oss/issues/140)) ([d88436f](https://github.com/macatocz/makato-oss/commit/d88436f2cd9133da0f7d91be594e3da27f7c22d3))
* **makato-orchestrate:** resolve plugin-owned assets from the installed plugin ([#136](https://github.com/macatocz/makato-oss/issues/136)) ([#139](https://github.com/macatocz/makato-oss/issues/139)) ([396edd6](https://github.com/macatocz/makato-oss/commit/396edd6c4a9cc0f54febeb1bde8731829d29029a))

## [0.168.2](https://github.com/macatocz/makato-oss/compare/v0.168.1...v0.168.2) (2026-10-16)


### 🐛 Bug Fixes

* **makato-build:** smaller tdd tasks, larger coder budget, installed scout discovery ([#133](https://github.com/macatocz/makato-oss/issues/133)) ([6e1b2d1](https://github.com/macatocz/makato-oss/commit/6e1b2d1b4de0bd2fd24de1c06b7f300a633913b4))

## [0.168.1](https://github.com/macatocz/makato-oss/compare/v0.168.0...v0.168.1) (2026-10-16)


### 🐛 Bug Fixes

* show host-qualified gh project-scope refresh command ([#131](https://github.com/macatocz/makato-oss/issues/131)) ([3f7dcc4](https://github.com/macatocz/makato-oss/commit/3f7dcc491f154d62c0e5c95275fbbfb6712d0b5b))

## [0.168.0](https://github.com/macatocz/makato-oss/compare/v0.167.0...v0.168.0) (2026-10-15)


### ✨ Features

* **build:** add reliable autonomous current-head CI repair ([#128](https://github.com/macatocz/makato-oss/issues/128)) ([d2747e0](https://github.com/macatocz/makato-oss/commit/d2747e0a0af5b9482f3c9a094e43a47d883318a4))
* **makato-build:** route lightweight skills to commit and tiny roles ([#130](https://github.com/macatocz/makato-oss/issues/130)) ([3b9653e](https://github.com/macatocz/makato-oss/commit/3b9653e66b98d2cb8f2144e974262ba9b8398eec))
* **makato-typesafeai:** add TypeSafe/Jev reference skills plugin to makato-suite ([5b4de9b](https://github.com/macatocz/makato-oss/commit/5b4de9bb6f077010937a913e19c9755b5fb14a2c))

## [0.167.0](https://github.com/macatocz/makato-oss/compare/v0.166.0...v0.167.0) (2026-10-15)


### ✨ Features

* configure per-skill model roles and reasoning effort ([#124](https://github.com/macatocz/makato-oss/issues/124)) ([c6732a0](https://github.com/macatocz/makato-oss/commit/c6732a01ebe8b91cd58f02224e476b4d33204ce8))

## [0.166.0](https://github.com/macatocz/makato-oss/compare/v0.165.2...v0.166.0) (2026-10-12)


### ✨ Features

* **makato-sagibeast:** add runtime refresh skill ([#120](https://github.com/macatocz/makato-oss/issues/120)) ([b9b34c3](https://github.com/macatocz/makato-oss/commit/b9b34c37325b50ebecba5e8dcc2b5104c71d3508))

## [0.165.2](https://github.com/macatocz/makato-oss/compare/v0.165.1...v0.165.2) (2026-10-12)


### 🐛 Bug Fixes

* **makato-build:** harden runtime paths and file reads ([#115](https://github.com/macatocz/makato-oss/issues/115)) ([9689307](https://github.com/macatocz/makato-oss/commit/968930761ad6c6976c6443fd7836f9327889f3bb))
* **runtime-qa:** resolve local port mappings on remote hosts ([#118](https://github.com/macatocz/makato-oss/issues/118)) ([532e29c](https://github.com/macatocz/makato-oss/commit/532e29c1693feac84f0f84d1b4c706ac84d03891))

## [0.165.1](https://github.com/macatocz/makato-oss/compare/v0.165.0...v0.165.1) (2026-09-13)


### 🐛 Bug Fixes

* **makato-build:** resolve installed plugin paths ([#106](https://github.com/macatocz/makato-oss/issues/106)) ([6b9aa3a](https://github.com/macatocz/makato-oss/commit/6b9aa3a29865e4856800c7452075800f320ed931))

## [0.165.0](https://github.com/macatocz/makato-oss/compare/v0.164.1...v0.165.0) (2026-09-13)


### ✨ Features

* **build-verify:** add spec verification, Playwright runtime QA, and frontend boot ([#104](https://github.com/macatocz/makato-oss/issues/104)) ([e1bf542](https://github.com/macatocz/makato-oss/commit/e1bf5424329cafed1406a8bb265b44eaa46c7290))


### 🐛 Bug Fixes

* **makato-build:** resolve installed plugin paths ([#107](https://github.com/macatocz/makato-oss/issues/107)) ([f14b562](https://github.com/macatocz/makato-oss/commit/f14b562d132b616c6bd864266a5f75e8bdc6f516))

## [0.164.1](https://github.com/macatocz/makato-oss/compare/v0.164.0...v0.164.1) (2026-09-13)


### 🐛 Bug Fixes

* make makato-build workflow runner-portable ([#101](https://github.com/macatocz/makato-oss/issues/101)) ([96a4755](https://github.com/macatocz/makato-oss/commit/96a47555d5d2e14f47e63680f7ce1f378333521a))
* make makato-build workflows repository-portable ([#103](https://github.com/macatocz/makato-oss/issues/103)) ([b9dcd6d](https://github.com/macatocz/makato-oss/commit/b9dcd6d86dd7b877d19ec4b9b0aee8275ddacfae))

## [0.164.0](https://github.com/macatocz/makato-oss/compare/v0.163.0...v0.164.0) (2026-09-11)


### ✨ Features

* add build logs for various specifications including analysis, implementation, and progress tracking ([369be21](https://github.com/macatocz/makato-oss/commit/369be2159a8052828cb17801a0cf0c3da22a5cdc))

## [0.163.0](https://github.com/macatocz/makato-oss/compare/v0.162.0...v0.163.0) (2026-09-10)


### ✨ Features

* add OpenAI GPT and Qwen macOS compatibility ([#97](https://github.com/macatocz/makato-oss/issues/97)) ([0b3466d](https://github.com/macatocz/makato-oss/commit/0b3466d4a1e4382b560c0b7c9c68492edad7f08f))

## [Unreleased]

### ✨ Features

* **provider compatibility:** add configurable native OpenAI GPT and Qwen/vLLM model profiles (`config/model-profiles.yml`: `openai`, `qwen-vllm`, `apple-ollama`), a harness-neutral OMP/Claude Code dispatch adapter (`plugins/makato-orchestrate/scripts/harness-command.sh`), Apple Silicon client setup (`scripts/macos-setup.sh`), and provider-aware Gate 6 preflight (`scripts/preflight-model-runtime.sh`, `scripts/preflight-omp-context.sh`, `scripts/preflight-optional-services.sh`) so the autonomous issue-to-PR/merge loop runs unattended against native OpenAI, a local Apple-Silicon Ollama endpoint, or a remote Linux/NVIDIA vLLM endpoint, with optional Playwright MCP/Langfuse/Postgres/Temporal/Sagibeast services reported as explicit PASS/SKIP/WARN. See [`docs/macos-openai-qwen.md`](docs/macos-openai-qwen.md) for the quick-start and troubleshooting matrix.

## [0.162.0](https://github.com/macatocz/makato-oss/compare/v0.161.2...v0.162.0) (2026-09-05)


### ✨ Features

* **makato-plan:** add Excalidraw diagram generator skill ([#94](https://github.com/macatocz/makato-oss/issues/94)) ([#95](https://github.com/macatocz/makato-oss/issues/95)) ([1ecda4e](https://github.com/macatocz/makato-oss/commit/1ecda4ebf2da76a10b1ca13e8a860330b75d9446))

## [0.161.2](https://github.com/macatocz/makato-oss/compare/v0.161.1...v0.161.2) (2026-08-27)


### 🐛 Bug Fixes

* **infra:** harden Vast OMP and vLLM deployment ([#91](https://github.com/macatocz/makato-oss/issues/91)) ([fbc04d2](https://github.com/macatocz/makato-oss/commit/fbc04d293ccbb1aef07c753a43ae1254805d81a0))

## [0.161.1](https://github.com/macatocz/makato-oss/compare/v0.161.0...v0.161.1) (2026-08-27)


### 🐛 Bug Fixes

* **orchestrate:** enforce pre-dispatch progress comments ([#64](https://github.com/macatocz/makato-oss/issues/64)) ([b8ec636](https://github.com/macatocz/makato-oss/commit/b8ec6362081993b65b7ee29b5d319aa2e90dcb68))

## [0.161.0](https://github.com/macatocz/makato-oss/compare/v0.160.0...v0.161.0) (2026-08-26)


### ✨ Features

* **infra:** one-command vast.ai provisioning + cold-start fixes ([#87](https://github.com/macatocz/makato-oss/issues/87)) ([21d27fd](https://github.com/macatocz/makato-oss/commit/21d27fdf854140a71227baf5523a8762812a4cfa))


### 🐛 Bug Fixes

* **makato-observability:** fix import sort and pyright excludes for worktree test ([02c5477](https://github.com/macatocz/makato-oss/commit/02c547707675a6135037b56df2b82aa91c5fd63e))

## [0.160.0](https://github.com/macatocz/makato-oss/compare/v0.159.0...v0.160.0) (2026-08-16)


### ✨ Features

* **makato-change:** scope quality-guard to changed files ([#85](https://github.com/macatocz/makato-oss/issues/85)) ([7a778d3](https://github.com/macatocz/makato-oss/commit/7a778d3c205750162c829d98475c0cb4083dc556))

## [0.159.0](https://github.com/macatocz/makato-oss/compare/v0.158.0...v0.159.0) (2026-08-15)


### ✨ Features

* **makato-change:** add shared guards and gherkin-elaborator ([#71](https://github.com/macatocz/makato-oss/issues/71)) ([#83](https://github.com/macatocz/makato-oss/issues/83)) ([fccf4cb](https://github.com/macatocz/makato-oss/commit/fccf4cbe14315dbc04e2b2ae659691a5f35a5288))
* **makato-change:** move code-explorer to design, add code-exploration.md cache validation ([#84](https://github.com/macatocz/makato-oss/issues/84)) ([2fd46d5](https://github.com/macatocz/makato-oss/commit/2fd46d51c658f3873210f24cccf33bf23f6c99aa)), closes [#72](https://github.com/macatocz/makato-oss/issues/72)
* **makato-plan:** P0 token savings for plan plugin ([#70](https://github.com/macatocz/makato-oss/issues/70)) ([#81](https://github.com/macatocz/makato-oss/issues/81)) ([5fca11c](https://github.com/macatocz/makato-oss/commit/5fca11c62915a7b8d4144a3b3a31231c80ee9ec9))

## [0.158.0](https://github.com/macatocz/makato-oss/compare/v0.157.0...v0.158.0) (2026-08-15)


### ✨ Features

* **makato-build:** add DoR gate and In Review board transitions ([#67](https://github.com/macatocz/makato-oss/issues/67)) ([#78](https://github.com/macatocz/makato-oss/issues/78)) ([2638816](https://github.com/macatocz/makato-oss/commit/263881682980fb4e7f3bb96d2ac608a66d5f6e02))
* **makato-plan:** add Pre-Round Coverage Scan before each round in create-prd Step 3 ([143a5de](https://github.com/macatocz/makato-oss/commit/143a5de50e5cc8a968f375a38a4c232181e045ba))
* **makato-plan:** add question-planner.md with 4 lenses and rotation plans ([a55a2cf](https://github.com/macatocz/makato-oss/commit/a55a2cf58c153672bfe26c33c2e6daa508fdadc7))
* **makato-plan:** add Step 2.0 pre-planning protocol and [T] deferral write-back to stress-test-artifact ([3ba0a22](https://github.com/macatocz/makato-oss/commit/3ba0a22588247de2dbb91998e9437c787f1c2718))
* **makato-plan:** makato-plan quality improvements ([#69](https://github.com/macatocz/makato-oss/issues/69)) ([6b0c71c](https://github.com/macatocz/makato-oss/commit/6b0c71cf787b2fbf09d2e2767d23605b99b202d7))
* **makato-plan:** makato-plan quality improvements ([#69](https://github.com/macatocz/makato-oss/issues/69)) ([6b0c71c](https://github.com/macatocz/makato-oss/commit/6b0c71cf787b2fbf09d2e2767d23605b99b202d7))
* **makato-plan:** replace per-story gherkin-quality-rules load with inline 6-rule checklist ([119bce1](https://github.com/macatocz/makato-oss/commit/119bce18c5752995b6c88a19155328ce159c2c58)), closes [#69](https://github.com/macatocz/makato-oss/issues/69)

## [0.157.0](https://github.com/macatocz/makato-oss/compare/v0.156.0...v0.157.0) (2026-08-15)


### ✨ Features

* **makato-build:** compact plan-analyst Task List to single-line pipe format ([#68](https://github.com/macatocz/makato-oss/issues/68)) ([#77](https://github.com/macatocz/makato-oss/issues/77)) ([629b4a5](https://github.com/macatocz/makato-oss/commit/629b4a5f1fe10dcfff4749327a046f23c1ba5191))
* **makato-orchestrate:** omp config min max_model_len 65536 for po-agent ([#66](https://github.com/macatocz/makato-oss/issues/66)) ([#73](https://github.com/macatocz/makato-oss/issues/73)) ([7feecb9](https://github.com/macatocz/makato-oss/commit/7feecb97efbc5481646ee18d9b985d401625faf4))


### 🐛 Bug Fixes

* **makato-orchestrate:** skip already-Ready issues in auto-seed candidate discovery ([#76](https://github.com/macatocz/makato-oss/issues/76)) ([d9d3c5e](https://github.com/macatocz/makato-oss/commit/d9d3c5e776f638d56da10cde61dd739f68b2a943))

## [0.156.0](https://github.com/macatocz/makato-oss/compare/v0.155.2...v0.156.0) (2026-08-14)


### ✨ Features

* **infra:** omp model config + vLLM tool-calling for open-model harness ([#61](https://github.com/macatocz/makato-oss/issues/61)) ([623086f](https://github.com/macatocz/makato-oss/commit/623086fa5f78a77ab74387128241f6a55362c456))

## [0.155.2](https://github.com/macatocz/makato-oss/compare/v0.155.1...v0.155.2) (2026-08-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** set vLLM port to 8100 and default MAKATO_OPEN_ENDPOINT_URL ([82c8ff6](https://github.com/macatocz/makato-oss/commit/82c8ff68f0324fc097321cc13756eca3bbc2555b))

## [0.155.1](https://github.com/macatocz/makato-oss/compare/v0.155.0...v0.155.1) (2026-08-13)


### 🐛 Bug Fixes

* **makato-build:** replace gawk-only 3-arg match() with portable sub()+split() in stale-artifact-check ([e9ed238](https://github.com/macatocz/makato-oss/commit/e9ed2383331e8491a5dfb11dac1e0757f67046dc))
* **makato-build:** replace gawk-only 3-arg match() with portable sub()+split() in stale-artifact-check ([935884b](https://github.com/macatocz/makato-oss/commit/935884bab3c3a3e8d7603328706a20c80351e82c)), closes [#47](https://github.com/macatocz/makato-oss/issues/47)

## [0.155.0](https://github.com/macatocz/makato-oss/compare/v0.154.4...v0.155.0) (2026-08-13)


### ✨ Features

* automate open-model vLLM deployment on vast.ai (systemd auto-start) ([f65cc5b](https://github.com/macatocz/makato-oss/commit/f65cc5b82453a6d3effe04b474f45337c76dbf36))
* **infra:** automate open-model vLLM deployment on vast.ai (systemd auto-start) ([92bddbe](https://github.com/macatocz/makato-oss/commit/92bddbe362908d5a00d4161140600f4c0fa10fe9))

## [0.154.4](https://github.com/macatocz/makato-oss/compare/v0.154.3...v0.154.4) (2026-08-13)


### 🐛 Bug Fixes

* **repo-wide:** repair broken pre-push hooks (pytest-slow, bandit) ([#48](https://github.com/macatocz/makato-oss/issues/48)) ([4d6b650](https://github.com/macatocz/makato-oss/commit/4d6b6509fd8d26f133e43e7eb831995e7db55c80))
* **repo-wide:** repair broken pre-push hooks (pytest-slow, bandit) ([#48](https://github.com/macatocz/makato-oss/issues/48)) ([30f4234](https://github.com/macatocz/makato-oss/commit/30f42345b356d78411fe56eeb304fea3eccc180b))
* serve ThinkingCap-Qwen3.6-27B FP8 as the open vLLM model (§1.3) ([2c47c4e](https://github.com/macatocz/makato-oss/commit/2c47c4e006c9b3f2b94854e168a17076ff2ef533))
* serve ThinkingCap-Qwen3.6-27B FP8 as the open vLLM model (§1.3) ([fbfe20a](https://github.com/macatocz/makato-oss/commit/fbfe20ac815d98184d6383f7437e0b8aae688938))

## [0.154.3](https://github.com/macatocz/makato-oss/compare/v0.154.2...v0.154.3) (2026-08-12)


### 🐛 Bug Fixes

* **makato-orchestrate:** synthesize living spec on archival for to-issues features ([#33](https://github.com/macatocz/makato-oss/issues/33)) ([0b56f1c](https://github.com/macatocz/makato-oss/commit/0b56f1c63020cc8e967bfe1be76fab22e064534c))

## [0.154.2](https://github.com/macatocz/makato-oss/compare/v0.154.1...v0.154.2) (2026-08-12)


### 🐛 Bug Fixes

* **makato-orchestrate:** heal stale status:blocked so a merged-blocker card can't starve the loop queue ([#32](https://github.com/macatocz/makato-oss/issues/32)) ([c8e12a0](https://github.com/macatocz/makato-oss/commit/c8e12a0e5e0536feaaf6b95cbc0b60b5eca3cb49))
* **makato-orchestrate:** heal stale status:blocked so a merged-blocker card can't starve the loop queue ([#32](https://github.com/macatocz/makato-oss/issues/32)) ([0bd96c2](https://github.com/macatocz/makato-oss/commit/0bd96c257a76803e524800595f78e77feec4da79))

## [0.154.1](https://github.com/macatocz/makato-oss/compare/v0.154.0...v0.154.1) (2026-08-11)


### 🐛 Bug Fixes

* **orchestrate:** reconcile stops stamping status:ready-for-dev; gate tolerates it ([253244a](https://github.com/macatocz/makato-oss/commit/253244a3f912703d1bb4318b67517e0d66be9807))

## [0.154.0](https://github.com/macatocz/makato-oss/compare/v0.153.2...v0.154.0) (2026-08-11)


### ✨ Features

* **makato-orchestrate:** offline board mirror + per-tick bidirectional sync ([#9](https://github.com/macatocz/makato-oss/issues/9)) ([a73d335](https://github.com/macatocz/makato-oss/commit/a73d335e2fcd2804bcd3cee8ca4bae76d9896e96))
* **makato-orchestrate:** offline board mirror + per-tick bidirectional sync ([#9](https://github.com/macatocz/makato-oss/issues/9)) ([705c781](https://github.com/macatocz/makato-oss/commit/705c781ae3b0b37a00e1fed862a45d7328f4c8cd))

## [0.153.2](https://github.com/macatocz/makato-oss/compare/v0.153.1...v0.153.2) (2026-08-11)


### 🐛 Bug Fixes

* finish harness-independence [#5](https://github.com/macatocz/makato-oss/issues/5)/[#6](https://github.com/macatocz/makato-oss/issues/6) acceptance tests + repo-wide pytest collection ([7130fb7](https://github.com/macatocz/makato-oss/commit/7130fb7599452f82fdede263a1a1cfdadc0e2e13))
* **makato-orchestrate:** declare models: block in config.yml for 10 modelRoles ([#5](https://github.com/macatocz/makato-oss/issues/5)) ([950687a](https://github.com/macatocz/makato-oss/commit/950687a78c3f4a99d45106d4a86538b7797df9cc))
* **makato-sagibeast:** make dotx-schema-extractor tests collectable at repo root ([022a71c](https://github.com/macatocz/makato-oss/commit/022a71c2217343250384d844251c63ee6cb8f4ae))

## [0.153.1](https://github.com/macatocz/makato-oss/compare/v0.153.0...v0.153.1) (2026-08-11)


### 🐛 Bug Fixes

* **makato-orchestrate:** add &lt;/dev/null to _auto_seed_dispatch_light to prevent TSV pipe drain ([b4e2213](https://github.com/macatocz/makato-oss/commit/b4e221378ebaf21f7b167f14d2386fdec431898d))
* **makato-orchestrate:** add &lt;/dev/null to _auto_seed_dispatch_light to prevent TSV pipe drain ([7df56f9](https://github.com/macatocz/makato-oss/commit/7df56f96eb18adbaea29488c5e5ea82be9aa60ec))
* **makato-orchestrate:** remove Claude Code-specific CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS from harness-independent dispatch ([5c811b4](https://github.com/macatocz/makato-oss/commit/5c811b4c7011620afc7583770619a6bebd51c42f))

## [0.153.0](https://github.com/macatocz/makato-oss/compare/v0.152.0...v0.153.0) (2026-08-11)


### ✨ Features

* **makato-orchestrate:** add persistent-volume config and provision script ([318dac8](https://github.com/macatocz/makato-oss/commit/318dac807a47502d2d9d5b2913c1311f1d055db1))
* **makato-orchestrate:** add Restart=always supervisor templates for macOS and Linux ([a402846](https://github.com/macatocz/makato-oss/commit/a40284664869a4cc4b0c2cfcf22005ff8e84bc78))
* **makato-orchestrate:** implement reconcile-before-resume.sh with D7 decision table ([4c59f11](https://github.com/macatocz/makato-oss/commit/4c59f119d51f4001850d54c0c48533fb9d2b3b28))
* **makato-orchestrate:** preemption survival — persistent volume + reconcile-before-resume ([#8](https://github.com/macatocz/makato-oss/issues/8)) ([e3a7469](https://github.com/macatocz/makato-oss/commit/e3a7469b72ceea0659ba38685d8ac2384a3b07c9))
* **makato-orchestrate:** wire reconcile-before-resume into loop-supervisor Step 4 ([42f711f](https://github.com/macatocz/makato-oss/commit/42f711ff4470d1c97a7cbb01f8eb23292be5341c))

## [0.152.0](https://github.com/macatocz/makato-oss/compare/v0.151.0...v0.152.0) (2026-08-11)


### ✨ Features

* **makato-orchestrate:** add assert-no-approval-stall.sh for headless E2E assertion ([3b5b3c1](https://github.com/macatocz/makato-oss/commit/3b5b3c1b518fa4539d3163e0cc3d25d3c2697121))
* **makato-orchestrate:** add e2e-mvp-proof.sh end-to-end validation script ([0c2828d](https://github.com/macatocz/makato-oss/commit/0c2828dbd8755fa37314ebcd62693b0168a6a96a))
* **makato-orchestrate:** add open-model endpoint config and ANTHROPIC_BASE_URL export ([e7ffa15](https://github.com/macatocz/makato-oss/commit/e7ffa15b5fa3de73dfd4a98d9cd213ab41c93633))
* **makato-orchestrate:** add open-model proof scripts ([#7](https://github.com/macatocz/makato-oss/issues/7)) ([8106cdb](https://github.com/macatocz/makato-oss/commit/8106cdbc17c8baee08501e6a701d9367e3af1844))
* **makato-orchestrate:** add verify-production-isolation.sh for DoD isolation check ([6b63438](https://github.com/macatocz/makato-oss/commit/6b63438e551220a22904b00602e6151c843629e9))


### 🤖 CI

* **makato-oss:** pin release-please-action to commit SHA (fixes code-s… ([9c473f4](https://github.com/macatocz/makato-oss/commit/9c473f431a408c783744951532a87fbd5b5ded25))

## [0.151.0](https://github.com/macatocz/makato-oss/compare/v0.150.0...v0.151.0) (2026-08-11)


### ✨ Features

* **harness:** modelRoles config; drop haiku/sonnet/opus across agents ([#5](https://github.com/macatocz/makato-oss/issues/5)) ([00a522a](https://github.com/macatocz/makato-oss/commit/00a522abcdd0cce0f5c9e5cc8b7d5819a4975f85))
* **infra:** add co-located dev stack with vLLM and Langfuse ([#10](https://github.com/macatocz/makato-oss/issues/10)) ([7329279](https://github.com/macatocz/makato-oss/commit/732927919fdf15a309d58bea48488f4f567e6968))

## [0.150.0](https://github.com/macatocz/makato-oss/compare/v0.149.1...v0.150.0) (2026-08-11)


### ✨ Features

* **makato-observability:** add E2E result emitter to Langfuse ([29415a7](https://github.com/macatocz/makato-oss/commit/29415a7e827a406728575ce0bd9e23b8ee861a65))
* **makato-orchestrate:** cross-platform portability remediation + transcript path re-homing ([#6](https://github.com/macatocz/makato-oss/issues/6)) ([ae09bf5](https://github.com/macatocz/makato-oss/commit/ae09bf5694713b6dcd7c71ae9d30cd7ef6c0f5ee))
* **makato-orchestrate:** cross-platform portability remediation + transcript path re-homing ([#6](https://github.com/macatocz/makato-oss/issues/6)) ([a811748](https://github.com/macatocz/makato-oss/commit/a81174851495049e367588b6e3d2ffa94b6d23e0))
* **makato-orchestrate:** dispatch po-agent via omp --yolo instead of claude -p ([#4](https://github.com/macatocz/makato-oss/issues/4)) ([10d1b00](https://github.com/macatocz/makato-oss/commit/10d1b00c6cb9e793db810cf9aa05965d06d2f9ad))
* **makato-orchestrate:** dispatch po-agent via omp --yolo instead of claude -p ([#4](https://github.com/macatocz/makato-oss/issues/4)) ([3c5429e](https://github.com/macatocz/makato-oss/commit/3c5429e177f25b7e8763a66c05b23a4c91dffc2d))
* **makato-ux:** add ephemeral sagibeast dev DB seed script ([72143c4](https://github.com/macatocz/makato-oss/commit/72143c4f8701f3b45dad02624627ff4033421d44))
* **makato-ux:** add Playwright E2E spec for sagibeast live endpoint ([5653799](https://github.com/macatocz/makato-oss/commit/565379918e8952e90b40519646950bf0f4b86c02))
* **makato-ux:** fix Playwright MCP filterBrowser caveat with --browser chromium ([a09b70f](https://github.com/macatocz/makato-oss/commit/a09b70fd481bf17327543e870fd8544d8d82d487))
* **observability:** add BuildSignals dataclass and _read_build_signals() to langfuse_hook ([#12](https://github.com/macatocz/makato-oss/issues/12)) ([7f2b7b5](https://github.com/macatocz/makato-oss/commit/7f2b7b52c6b2e300195beda94e2d07775ad95c32))
* **observability:** forward-compatible model-role trace enrichment ([#13](https://github.com/macatocz/makato-oss/issues/13)) ([#24](https://github.com/macatocz/makato-oss/issues/24)) ([5417e46](https://github.com/macatocz/makato-oss/commit/5417e4682c7c67653b0eddfafae3afa74219a8f1))
* **observability:** per-step success metrics for open-only run ([#12](https://github.com/macatocz/makato-oss/issues/12)) ([ae50209](https://github.com/macatocz/makato-oss/commit/ae502094fa73c2fc5e22279a5993f19acd56f34d))
* **observability:** per-step success metrics for open-only run ([#12](https://github.com/macatocz/makato-oss/issues/12)) ([ae50209](https://github.com/macatocz/makato-oss/commit/ae502094fa73c2fc5e22279a5993f19acd56f34d))
* Real Playwright E2E against live sagibeast dev copy ([#11](https://github.com/macatocz/makato-oss/issues/11)) ([4a7857d](https://github.com/macatocz/makato-oss/commit/4a7857d84c733284da507e115b8d7389e9da9853))

## [0.149.1](https://github.com/macatocz/makato-oss/compare/v0.149.0...v0.149.1) (2026-08-10)


### 🤖 CI

* **makato-oss:** pin release-please-action to commit SHA (fixes code-scanning [#4](https://github.com/macatocz/makato-oss/issues/4)) ([cfec9fd](https://github.com/macatocz/makato-oss/commit/cfec9fd0566b675fdc7faae2f5bc2c64bc09b814))

## [0.149.0](https://github.com/macatocz/makato-oss/compare/v0.148.0...v0.149.0) (2026-08-10)


### ✨ Features

* add renovate.json to allowed files in root structure check ([302a58f](https://github.com/macatocz/makato-oss/commit/302a58f7e8af266889d86dff7735071b00aaaa6b))
* classify plan-tier by decomposition signal, not body length ([#815](https://github.com/macatocz/makato-oss/issues/815)) ([2d39d05](https://github.com/macatocz/makato-oss/commit/2d39d051a22c04ecc9f9e9cad4e87a597a1b94fe))
* **docs:** generate makato-flow.html graph-data with drift check ([#428](https://github.com/macatocz/makato-oss/issues/428)) ([#439](https://github.com/macatocz/makato-oss/issues/439)) ([d91bd7d](https://github.com/macatocz/makato-oss/commit/d91bd7d5bb01a899948b7239900a430461ce1bca))
* **inject-skills:** F5 task-text routing via task_contains bundle key ([#131](https://github.com/macatocz/makato-oss/issues/131)) ([#263](https://github.com/macatocz/makato-oss/issues/263)) ([bf4a7c8](https://github.com/macatocz/makato-oss/commit/bf4a7c8dc09ef355a492e6f67b7e613e5078d313))
* interactive suite data-flow diagram + split makato-doc out of makato-core ([#271](https://github.com/macatocz/makato-oss/issues/271)) ([ef8122b](https://github.com/macatocz/makato-oss/commit/ef8122b2cc08c88b39e40d273ce3fcd89b3a7f58))
* **loop:** authoritative dispatch gate tiers 1-2 + exclusion veto ([#318](https://github.com/macatocz/makato-oss/issues/318), [#355](https://github.com/macatocz/makato-oss/issues/355)) ([#362](https://github.com/macatocz/makato-oss/issues/362)) ([5afac3a](https://github.com/macatocz/makato-oss/commit/5afac3a901676f685aca79a3d1d7808c54301fe5))
* **loop:** detect exited-incomplete dispatch and resume via --resume ([#531](https://github.com/macatocz/makato-oss/issues/531)) ([ed5713e](https://github.com/macatocz/makato-oss/commit/ed5713e41af0127b3fcc25ff497b471322b54538))
* **loop:** emit Langfuse traces for headless dispatches ([#547](https://github.com/macatocz/makato-oss/issues/547)) ([#549](https://github.com/macatocz/makato-oss/issues/549)) ([3d63188](https://github.com/macatocz/makato-oss/commit/3d6318897a764f370395ecde97326a6ed16da2f9))
* **loop:** generic MAKATO_LOOP_PREPOLL_HOOK pre-poll hook (exit 0/2/3) ([#544](https://github.com/macatocz/makato-oss/issues/544)) ([b0b3e4b](https://github.com/macatocz/makato-oss/commit/b0b3e4bc608895e66683faf4c4896781ba252a9a))
* **makato-build:** add ## Runtime verification section to plan.md and execute as build-verify gate ([#583](https://github.com/macatocz/makato-oss/issues/583)) ([640bea0](https://github.com/macatocz/makato-oss/commit/640bea0e88c489b6ec346db6d3b58d2e20e8bee1))
* **makato-build:** add build-verify-spec skill ([#568](https://github.com/macatocz/makato-oss/issues/568)) ([#619](https://github.com/macatocz/makato-oss/issues/619)) ([b4db21a](https://github.com/macatocz/makato-oss/commit/b4db21a133ec89a802f93c97183243844cd01ef0))
* **makato-build:** add context/makato/standards/ so makato dogfoods inject-context ([fda67c9](https://github.com/macatocz/makato-oss/commit/fda67c9c3c8dd4a737fdca568ddfa190b9a79dcd))
* **makato-build:** add context/makato/standards/ so makato dogfoods inject-context ([#591](https://github.com/macatocz/makato-oss/issues/591)) ([1f5e129](https://github.com/macatocz/makato-oss/commit/1f5e1295b93681fedee5b3c3d3e36993697bdec4))
* **makato-build:** add context/makato/standards/ so makato dogfoods inject-context ([#591](https://github.com/macatocz/makato-oss/issues/591)) ([1f5e129](https://github.com/macatocz/makato-oss/commit/1f5e1295b93681fedee5b3c3d3e36993697bdec4))
* **makato-build:** add optional ## Runtime verification section to plan-template and plan-schema ([c5e1b2e](https://github.com/macatocz/makato-oss/commit/c5e1b2eadf76c0c11de2e99aff054df848a15195))
* **makato-build:** add pre-commit gate for context-bundles.yml ([#324](https://github.com/macatocz/makato-oss/issues/324)) ([#332](https://github.com/macatocz/makato-oss/issues/332)) ([e5ecd39](https://github.com/macatocz/makato-oss/commit/e5ecd395a2ea351c08da03ca1c68973ea1e66d85))
* **makato-build:** add repair_hint (WHAT/WHY/FIX) field to finding schema ([#611](https://github.com/macatocz/makato-oss/issues/611)) ([78252be](https://github.com/macatocz/makato-oss/commit/78252beadb869851e2520010da26b39aa3d66a60)), closes [#592](https://github.com/macatocz/makato-oss/issues/592)
* **makato-build:** add runtime-qa agent definition with R1 envelope contract ([17eaf9e](https://github.com/macatocz/makato-oss/commit/17eaf9e397aafdea46748c97b2dafbeb425fc5a1))
* **makato-build:** add stale-artifact sensor routes to finding-routes.json ([8ff2b27](https://github.com/macatocz/makato-oss/commit/8ff2b27102def2ae121f358be1e405a6de781ea5))
* **makato-build:** add stale-artifact-check pre-commit hook (console.log/debugger/temp-file detection) ([521c114](https://github.com/macatocz/makato-oss/commit/521c114bca1102399337bcc7963741f350f617a9))
* **makato-build:** build-explore read-only thinking-partner skill ([#564](https://github.com/macatocz/makato-oss/issues/564)) ([9ce3ecc](https://github.com/macatocz/makato-oss/commit/9ce3ecc8d5ee48c661b275ea3b7f9e14d20e0361))
* **makato-build:** build-lane lesson write via write-lessons.sh ([#473](https://github.com/macatocz/makato-oss/issues/473)) ([bd37025](https://github.com/macatocz/makato-oss/commit/bd37025556d1b44f7fa9213233e760f4b52afd0f))
* **makato-build:** build-refine Step 8 elicits ## Runtime verification for service/API stories ([2a52d7c](https://github.com/macatocz/makato-oss/commit/2a52d7cc68315bf618755c6d6b0b7aaf35ea8719))
* **makato-build:** build-verify Gate 6 reads ## Runtime verification from plan.md; plan command takes precedence over gate-scout discovery ([00c3af7](https://github.com/macatocz/makato-oss/commit/00c3af7b7447ae4ec9651214fd1578e4b1415764))
* **makato-build:** canary test-framework pre-flight in build-start (Step 2.75) ([#662](https://github.com/macatocz/makato-oss/issues/662)) ([0ce6cea](https://github.com/macatocz/makato-oss/commit/0ce6cea8047bcfaa0cc1bdc7c91a0265ca85869e))
* **makato-build:** diff-reviewer gains MODIFIED-requirements verification pass (Step 2.5) ([0dd724a](https://github.com/macatocz/makato-oss/commit/0dd724a58c76d6abe20844d244368f970014dc12))
* **makato-build:** DoD item 8 and build-verify Gate 8 extended to cover debug/stale artifacts ([f71054e](https://github.com/macatocz/makato-oss/commit/f71054ec8dfc4c58312625965b120101cc5f7ba5))
* **makato-build:** extensible workflow schema system ([#563](https://github.com/macatocz/makato-oss/issues/563)) ([#612](https://github.com/macatocz/makato-oss/issues/612)) ([d60a82e](https://github.com/macatocz/makato-oss/commit/d60a82e749fd460895d802c82cbf6c4f49c40d72))
* **makato-build:** Gate 6 advisory runtime health-check in build-verify ([#580](https://github.com/macatocz/makato-oss/issues/580)) ([9e695de](https://github.com/macatocz/makato-oss/commit/9e695ded84d441289130d858ad661de40c7cc7d8))
* **makato-build:** gate-scout discovers uv/pyright/biome/sqlfluff toolchains ([#377](https://github.com/macatocz/makato-oss/issues/377)) ([95da0c6](https://github.com/macatocz/makato-oss/commit/95da0c6c3d806936cd6a1df765fa1a539c82a729))
* **makato-build:** make context7 lookup mandatory in coder before RED ([#400](https://github.com/macatocz/makato-oss/issues/400)) ([a6ece38](https://github.com/macatocz/makato-oss/commit/a6ece38d4a7c4b717a56fc03d3cb70a3393b904b)), closes [#395](https://github.com/macatocz/makato-oss/issues/395)
* **makato-build:** make integration/E2E gate mandatory for &gt;=3-layer changes ([#581](https://github.com/macatocz/makato-oss/issues/581)) ([#657](https://github.com/macatocz/makato-oss/issues/657)) ([a976a3f](https://github.com/macatocz/makato-oss/commit/a976a3fe26c1390eaa8099f6651fbf2e5208a437))
* **makato-build:** parse-sarif.py maps stale-artifact-check hook label to tool stale-artifact ([7fc0282](https://github.com/macatocz/makato-oss/commit/7fc028247f3697862cbb6bc17be4c43f443a22da))
* **makato-build:** register RUNTIME_QA_BLOCKED halt code in halt-codes.md ([a5c93d1](https://github.com/macatocz/makato-oss/commit/a5c93d1ef0aedf6a01cf6fd83d767faefe2bc489))
* **makato-build:** review-feedback promotion — codify recurring MUST-FIX as pre-commit checks ([#594](https://github.com/macatocz/makato-oss/issues/594)) ([#649](https://github.com/macatocz/makato-oss/issues/649)) ([8126a73](https://github.com/macatocz/makato-oss/commit/8126a73d830b6cf30b71a1eac336eb51b729e88f))
* **makato-build:** runtime-qa agent — exercise built app via Playwright MCP ([#582](https://github.com/macatocz/makato-oss/issues/582)) ([0f36b97](https://github.com/macatocz/makato-oss/commit/0f36b97e1f6293171af876683d46d55d46ff9c98))
* **makato-build:** runtime-qa agent — exercise built app via Playwright MCP ([#582](https://github.com/macatocz/makato-oss/issues/582)) ([0f36b97](https://github.com/macatocz/makato-oss/commit/0f36b97e1f6293171af876683d46d55d46ff9c98))
* **makato-build:** stale-artifact sensor lane — flag debug leftovers in diff ([#596](https://github.com/macatocz/makato-oss/issues/596)) ([bac73fd](https://github.com/macatocz/makato-oss/commit/bac73fd9ed16eabd49ed1dd4a7902726da2cde17))
* **makato-build:** stale-artifact sensor lane — flag debug leftovers in diff ([#596](https://github.com/macatocz/makato-oss/issues/596)) ([bac73fd](https://github.com/macatocz/makato-oss/commit/bac73fd9ed16eabd49ed1dd4a7902726da2cde17))
* **makato-change:** add build.jsonl audit emission to analyze and execute skills ([ed31482](https://github.com/macatocz/makato-oss/commit/ed314820322a60973508bf65e9a438da331709e3))
* **makato-change:** add inject-skills resolver step to design skill ([#429](https://github.com/macatocz/makato-oss/issues/429)) ([#435](https://github.com/macatocz/makato-oss/issues/435)) ([49883a6](https://github.com/macatocz/makato-oss/commit/49883a6136ff809fd1a3668f2288c8a99eea8366))
* **makato-change:** add spec-delta-template.md with ADDED/MODIFIED/REMOVED/RENAMED sections ([88c7582](https://github.com/macatocz/makato-oss/commit/88c75823dced18e5c597c26573628a04d9a351eb))
* **makato-change:** delta spec format for brownfield changes ([#562](https://github.com/macatocz/makato-oss/issues/562)) ([e5eac7b](https://github.com/macatocz/makato-oss/commit/e5eac7b0305f692db32d57baccdd3d0519d18ed6))
* **makato-change:** delta spec format for brownfield changes ([#562](https://github.com/macatocz/makato-oss/issues/562)) ([e5eac7b](https://github.com/macatocz/makato-oss/commit/e5eac7b0305f692db32d57baccdd3d0519d18ed6))
* **makato-change:** execute reads spec-delta.md and passes SPEC_DELTA_CONTEXT to change-implementer ([81f0adf](https://github.com/macatocz/makato-oss/commit/81f0adf0a23c835b25b9a07744f828f6e41ac967))
* **makato-change:** extend design skill to emit spec-delta.md as required output artifact ([b987968](https://github.com/macatocz/makato-oss/commit/b9879681d6cbb655c7958c16f7b50e32cead45e4))
* **makato-change:** isolate execute write phase in change-implementer subagent ([#402](https://github.com/macatocz/makato-oss/issues/402)) ([af8f87c](https://github.com/macatocz/makato-oss/commit/af8f87cc03b285d9a9536d4d6077929e5fe4aa06)), closes [#396](https://github.com/macatocz/makato-oss/issues/396)
* **makato-change:** resolve 4 feature-audit gaps (analyze/execute JSONL, loop.sh MAKATO_ORCHESTRATE_SHARED, resolve-review note) ([79adad3](https://github.com/macatocz/makato-oss/commit/79adad337995283708871e0aa12435ed71e04a77))
* **makato-change:** resolve 4 feature-audit gaps (analyze/execute JSONL, loop.sh MAKATO_ORCHESTRATE_SHARED, resolve-review note) ([79adad3](https://github.com/macatocz/makato-oss/commit/79adad337995283708871e0aa12435ed71e04a77))
* **makato-change:** wire memory recall and lesson-write into change lane ([#474](https://github.com/macatocz/makato-oss/issues/474)) ([728b92e](https://github.com/macatocz/makato-oss/commit/728b92ef687139778ee3bf37826c360f3b456ae7))
* **makato-change:** wire progress-comment narration into orchestrate skill (v1.2.0) ([#387](https://github.com/macatocz/makato-oss/issues/387)) ([48641d2](https://github.com/macatocz/makato-oss/commit/48641d2a2ed1258979c3a6d96b64be8f426465e9))
* **makato-contribute:** add harness-audit SKILL.md ([fa85260](https://github.com/macatocz/makato-oss/commit/fa85260cd74a71d050e18c11995e038883468ec5))
* **makato-contribute:** add harness-audit.sh classifier + smoke tests ([4e85f40](https://github.com/macatocz/makato-oss/commit/4e85f40b7ddd42cf3a70d891a193d77d71913581))
* **makato-contribute:** full skill-routing coverage + box-level diagram edges ([#441](https://github.com/macatocz/makato-oss/issues/441)) ([4f23863](https://github.com/macatocz/makato-oss/commit/4f23863b4af4c532a8e944e189148543568538fc))
* **makato-contribute:** harness-audit skill — AGENTS.md bloat + permissionMode audit ([#590](https://github.com/macatocz/makato-oss/issues/590)) ([1f34aac](https://github.com/macatocz/makato-oss/commit/1f34aac3613468c9d620f4b05778ad78d703a348))
* **makato-contribute:** harness-audit skill — AGENTS.md bloat + permissionMode audit ([#590](https://github.com/macatocz/makato-oss/issues/590)) ([1f34aac](https://github.com/macatocz/makato-oss/commit/1f34aac3613468c9d620f4b05778ad78d703a348))
* **makato-contribute:** register technical skills in skill-bundles.yml ([#278](https://github.com/macatocz/makato-oss/issues/278)) ([8810e6b](https://github.com/macatocz/makato-oss/commit/8810e6b4495c19907d7edd2ee198c13d8ba5b06b))
* **makato-core:** add init onboarding wizard skill ([#566](https://github.com/macatocz/makato-oss/issues/566)) ([1738f83](https://github.com/macatocz/makato-oss/commit/1738f83e17b08c5b0f77272486535f7e7ba25fec))
* **makato-core:** align skill-judge with repo conventions, autonomous scoring ([#415](https://github.com/macatocz/makato-oss/issues/415)) ([650cb67](https://github.com/macatocz/makato-oss/commit/650cb672785da38f6336fe2ee08bdbff5b2c1cbc))
* **makato-core:** extend create-issue with plan-tier, issue-to-project, and seed-issue (v1.2.0) ([#378](https://github.com/macatocz/makato-oss/issues/378)) ([83becd0](https://github.com/macatocz/makato-oss/commit/83becd0e33e412ee3cea7d0981d6d7204da5b084))
* **makato-core:** guided onboarding wizard — makato-core:init skill ([#566](https://github.com/macatocz/makato-oss/issues/566)) ([7ea351f](https://github.com/macatocz/makato-oss/commit/7ea351f793f2963a8ed89d0de51542b062ccff24))
* **makato-core:** guided onboarding wizard — makato-core:init skill ([#566](https://github.com/macatocz/makato-oss/issues/566)) ([7ea351f](https://github.com/macatocz/makato-oss/commit/7ea351f793f2963a8ed89d0de51542b062ccff24))
* **makato-database:** resolve 3 feature-audit gaps ([#711](https://github.com/macatocz/makato-oss/issues/711)) ([#793](https://github.com/macatocz/makato-oss/issues/793)) ([07ec952](https://github.com/macatocz/makato-oss/commit/07ec9527d3a395f0b712fe6226290ccaa74b85fa))
* **makato-fastapi:** initial plugin with governance and fastapi skill ([#359](https://github.com/macatocz/makato-oss/issues/359)) ([34a010d](https://github.com/macatocz/makato-oss/commit/34a010d4334501bf2c3c7e4d7a9c1b7dfde5f8db))
* **makato-harness-independence:** create 11 GitHub issues + plan stubs via to-issues ([18c5e21](https://github.com/macatocz/makato-oss/commit/18c5e213fe1b48e3595bf667cf19345eab0bed3d))
* **makato-observability:** add Claude Code session tracing via Langfuse Stop hook ([af59d1c](https://github.com/macatocz/makato-oss/commit/af59d1c941050831b56fa1eaf12dfa35324efbd7))
* **makato-observability:** add langfuse ops + langfuse-enrich skills ([#452](https://github.com/macatocz/makato-oss/issues/452)) ([d15dcf8](https://github.com/macatocz/makato-oss/commit/d15dcf8053cbfc8a6db86a3adc92ddeddbc31edc))
* **makato-observability:** resolve 6 feature-audit gaps ([#707](https://github.com/macatocz/makato-oss/issues/707)) ([#796](https://github.com/macatocz/makato-oss/issues/796)) ([040bf63](https://github.com/macatocz/makato-oss/commit/040bf633bc877f10f0978af2180105c6bfb7ab24))
* **makato-orchestrate:** add _auto_seed_candidates() to loop.sh ([#369](https://github.com/macatocz/makato-oss/issues/369)) ([#374](https://github.com/macatocz/makato-oss/issues/374)) ([fcd7c84](https://github.com/macatocz/makato-oss/commit/fcd7c84d89336e18d9a5741bd0475ea7d9299e34))
* **makato-orchestrate:** add _auto_seed_dispatch_light() for light-tier auto-seed ([#370](https://github.com/macatocz/makato-oss/issues/370)) ([#381](https://github.com/macatocz/makato-oss/issues/381)) ([c1fdf87](https://github.com/macatocz/makato-oss/commit/c1fdf87faf702b59835b78382e022cfafdd5ce0a))
* **makato-orchestrate:** add &lt;!-- issue: #&lt;issue-number&gt; --&gt; fingerprint header to plan template ([dda91de](https://github.com/macatocz/makato-oss/commit/dda91dea1e3d420fd898c00aba735431cdae70ba))
* **makato-orchestrate:** add build-runtime-qa Step 6 [#1](https://github.com/macatocz/makato-oss/issues/1)b dispatch to po-agent and progress-comment table ([7b1f7ed](https://github.com/macatocz/makato-oss/commit/7b1f7ed91c9ca693a5a19c65702d89c55d5e64eb))
* **makato-orchestrate:** add external supervisor script for loop.sh restart ([2ad0457](https://github.com/macatocz/makato-oss/commit/2ad0457d57518ac09ebcdadd83d11988aacd443b)), closes [#532](https://github.com/macatocz/makato-oss/issues/532)
* **makato-orchestrate:** add ISSUE_NUMBER fingerprint check to validate-plan-body.sh (T14/T15/T16) ([a2d434a](https://github.com/macatocz/makato-oss/commit/a2d434a5246b2746bb73db2bddfaf1d9590a83ef))
* **makato-orchestrate:** add launchd plist template for loop supervisor ([e0d5297](https://github.com/macatocz/makato-oss/commit/e0d5297263121e8fa1d136d6c1d62d28301b169a))
* **makato-orchestrate:** add lesson-prune operator curation skill ([#475](https://github.com/macatocz/makato-oss/issues/475)) ([#498](https://github.com/macatocz/makato-oss/issues/498)) ([edeeb69](https://github.com/macatocz/makato-oss/commit/edeeb692e9b3c6552c771b1c9b85446618e196dd))
* **makato-orchestrate:** add loop HALT notifier (macOS) + launchd template ([#738](https://github.com/macatocz/makato-oss/issues/738)) ([06658e4](https://github.com/macatocz/makato-oss/commit/06658e41428e42d4729aa774bbafb993638b3e2d))
* **makato-orchestrate:** add loop reshape pass for Needs Planning signal ([#350](https://github.com/macatocz/makato-oss/issues/350)) ([#418](https://github.com/macatocz/makato-oss/issues/418)) ([592eddd](https://github.com/macatocz/makato-oss/commit/592eddd5f77a8aec812acc556b1ecb696f781020))
* **makato-orchestrate:** add progress-comment notes for setup phases before build-refine ([#742](https://github.com/macatocz/makato-oss/issues/742)) ([#746](https://github.com/macatocz/makato-oss/issues/746)) ([74ca242](https://github.com/macatocz/makato-oss/commit/74ca24251a1ea794e00c442800a26d8fcaf0049e))
* **makato-orchestrate:** add sync-living-specs.sh for spec-delta to docs/specs/ sync ([fb5fadf](https://github.com/macatocz/makato-oss/commit/fb5fadfc3f2c7655fe312caec7279cf70accb8d9))
* **makato-orchestrate:** auto-generate plan.md before dispatch to prevent HALT-006 ([#490](https://github.com/macatocz/makato-oss/issues/490)) ([0470bb7](https://github.com/macatocz/makato-oss/commit/0470bb70cbfa51bb6a957a43ba1fee9b134a9290))
* **makato-orchestrate:** auto-seed tick integration, toggle, and offline smoke suite ([#373](https://github.com/macatocz/makato-oss/issues/373)) ([#391](https://github.com/macatocz/makato-oss/issues/391)) ([7d468db](https://github.com/macatocz/makato-oss/commit/7d468db03621e713e7ac877aa072f535391d938d))
* **makato-orchestrate:** autonomous build-refine from committed stories.json ([#527](https://github.com/macatocz/makato-oss/issues/527)) ([#529](https://github.com/macatocz/makato-oss/issues/529)) ([fd1e622](https://github.com/macatocz/makato-oss/commit/fd1e622da6b8afb5caba32c7d9c93225a543d8d2))
* **makato-orchestrate:** board Status=Ready as sole dispatch condition (remove status:ready-for-dev) ([0b68c9c](https://github.com/macatocz/makato-oss/commit/0b68c9cefd5e58e2e314927c8debbcbccd9bf20d))
* **makato-orchestrate:** bound the auto-reshape to prevent plan↔build oscillation ([#351](https://github.com/macatocz/makato-oss/issues/351), epic [#319](https://github.com/macatocz/makato-oss/issues/319)) ([33737f4](https://github.com/macatocz/makato-oss/commit/33737f4a5658444fc8c988940a486264d573576e))
* **makato-orchestrate:** bounded parallel issue fleet via N independent loop.sh workers ([#546](https://github.com/macatocz/makato-oss/issues/546)) ([213081c](https://github.com/macatocz/makato-oss/commit/213081c535d42f31766ea5bc87e3ca17e41bf3d9))
* **makato-orchestrate:** capture design-time decisions into workflow-state ([#603](https://github.com/macatocz/makato-oss/issues/603)) ([#645](https://github.com/macatocz/makato-oss/issues/645)) ([a0bb004](https://github.com/macatocz/makato-oss/commit/a0bb0045145436deec330bad377bdec041290683))
* **makato-orchestrate:** classify CI failures and route sensor types to sensor-fixer ([#390](https://github.com/macatocz/makato-oss/issues/390)) ([#406](https://github.com/macatocz/makato-oss/issues/406)) ([2a3cc49](https://github.com/macatocz/makato-oss/commit/2a3cc49217abf2b14438e96519c5e6e4e38701b8))
* **makato-orchestrate:** cloud-hosted loop runner — GHA cron running loop.sh run --once ([#600](https://github.com/macatocz/makato-oss/issues/600)) ([87db6a0](https://github.com/macatocz/makato-oss/commit/87db6a0ea6561a5d314172e55af643ee0bca8c9a))
* **makato-orchestrate:** dependency-aware Ready promotion ([#268](https://github.com/macatocz/makato-oss/issues/268)) ([#327](https://github.com/macatocz/makato-oss/issues/327)) ([daa0ef4](https://github.com/macatocz/makato-oss/commit/daa0ef49d7f8a19c49a4aa1efdeed76153fe9d46))
* **makato-orchestrate:** detect exited-incomplete dispatch and resume via --resume ([#531](https://github.com/macatocz/makato-oss/issues/531)) ([#537](https://github.com/macatocz/makato-oss/issues/537)) ([9e618ea](https://github.com/macatocz/makato-oss/commit/9e618ea4c5ca24aaf33178d51ab2e687dfda8955))
* **makato-orchestrate:** diagnostic stall recovery with auto-restart from preserved state ([#444](https://github.com/macatocz/makato-oss/issues/444)) ([#453](https://github.com/macatocz/makato-oss/issues/453)) ([3f58ac9](https://github.com/macatocz/makato-oss/commit/3f58ac92a3adf1a702009a970e68274add4c5d48))
* **makato-orchestrate:** durable per-issue structural_halt_cycles counter ([#347](https://github.com/macatocz/makato-oss/issues/347)) ([#354](https://github.com/macatocz/makato-oss/issues/354)) ([65ea817](https://github.com/macatocz/makato-oss/commit/65ea817628eb41900739ea1bdd85c63ab87287ec))
* **makato-orchestrate:** emit durable Needs Planning signal at recurrence threshold ([#348](https://github.com/macatocz/makato-oss/issues/348)) ([#410](https://github.com/macatocz/makato-oss/issues/410)) ([8ee32f6](https://github.com/macatocz/makato-oss/commit/8ee32f6de77ccc0f7397474a4445505b5c874a30))
* **makato-orchestrate:** extend documentation-agent with spec-delta living-spec sync step ([72c351b](https://github.com/macatocz/makato-oss/commit/72c351b93254f3eace28f40c3e6994d89905683d))
* **makato-orchestrate:** external supervisor to restart a dead loop.sh ([2fe04f5](https://github.com/macatocz/makato-oss/commit/2fe04f57a7493e9970c3b7a1cd179c12020df565))
* **makato-orchestrate:** fingerprint check in validate-plan-body.sh ([#512](https://github.com/macatocz/makato-oss/issues/512)) ([d839252](https://github.com/macatocz/makato-oss/commit/d8392527bc9acdfae3f7eabb8b33fd190fc80309))
* **makato-orchestrate:** fingerprint check in validate-plan-body.sh ([#512](https://github.com/macatocz/makato-oss/issues/512)) ([d839252](https://github.com/macatocz/makato-oss/commit/d8392527bc9acdfae3f7eabb8b33fd190fc80309))
* **makato-orchestrate:** full/untiered arm — block for human ([#372](https://github.com/macatocz/makato-oss/issues/372)) ([#384](https://github.com/macatocz/makato-oss/issues/384)) ([fb7efd0](https://github.com/macatocz/makato-oss/commit/fb7efd07e72edd61d2f60a67ecbc20209794bbd7))
* **makato-orchestrate:** generalise auto-seed bot veto to any [bot] author ([#425](https://github.com/macatocz/makato-oss/issues/425)) ([83354fc](https://github.com/macatocz/makato-oss/commit/83354fcad29e42bb887ddd3ee1b38f0837470ddf))
* **makato-orchestrate:** gh CLI to REST fallback for critical loop calls ([#458](https://github.com/macatocz/makato-oss/issues/458)) ([e3a0900](https://github.com/macatocz/makato-oss/commit/e3a0900aee84803a2e294623511f14ae97e7dc44)), closes [#447](https://github.com/macatocz/makato-oss/issues/447)
* **makato-orchestrate:** HALT-by-layer diagnostic report ([#593](https://github.com/macatocz/makato-oss/issues/593)) ([#666](https://github.com/macatocz/makato-oss/issues/666)) ([635791b](https://github.com/macatocz/makato-oss/commit/635791b72cf4dd64a4a4602720a00222881aed43))
* **makato-orchestrate:** human session clock-in/clock-out ritual ([#602](https://github.com/macatocz/makato-oss/issues/602)) ([#643](https://github.com/macatocz/makato-oss/issues/643)) ([fc3eb00](https://github.com/macatocz/makato-oss/commit/fc3eb002293bc17be030a69ae0c69a2849f21986))
* **makato-orchestrate:** label-board conflict gate for dispatch ([#356](https://github.com/macatocz/makato-oss/issues/356)) ([2af4ba4](https://github.com/macatocz/makato-oss/commit/2af4ba4d266d2b6c54608b8aa11fb996a856a908))
* **makato-orchestrate:** living-spec delta sync post-merge ([#567](https://github.com/macatocz/makato-oss/issues/567)) ([a751fb7](https://github.com/macatocz/makato-oss/commit/a751fb70a22864071dec4ace2a7ad3c3a51ee587))
* **makato-orchestrate:** living-spec delta sync post-merge ([#567](https://github.com/macatocz/makato-oss/issues/567)) ([a751fb7](https://github.com/macatocz/makato-oss/commit/a751fb70a22864071dec4ace2a7ad3c3a51ee587))
* **makato-orchestrate:** loop auto-reaps local worktrees whose PR is merged ([#265](https://github.com/macatocz/makato-oss/issues/265)) ([#266](https://github.com/macatocz/makato-oss/issues/266)) ([c5db519](https://github.com/macatocz/makato-oss/commit/c5db519a126c12efe7dafd61437624313ddd35e1))
* **makato-orchestrate:** machine-readable retryable/origin classification for HALT codes ([#446](https://github.com/macatocz/makato-oss/issues/446)) ([#449](https://github.com/macatocz/makato-oss/issues/449)) ([e280966](https://github.com/macatocz/makato-oss/commit/e2809663dec2b3666a3a7508f01f281c3d0f25f5))
* **makato-orchestrate:** orphan degraded gate for hand-filed issues ([#357](https://github.com/macatocz/makato-oss/issues/357)) ([#421](https://github.com/macatocz/makato-oss/issues/421)) ([4c763c0](https://github.com/macatocz/makato-oss/commit/4c763c01bc12efc7c03bfead9d4d05de1dc2294f))
* **makato-orchestrate:** per-issue final-envelope aggregation into a run report ([#459](https://github.com/macatocz/makato-oss/issues/459)) ([b4cba9a](https://github.com/macatocz/makato-oss/commit/b4cba9a204b73e77394498dd8d95f19d6774d557)), closes [#448](https://github.com/macatocz/makato-oss/issues/448)
* **makato-orchestrate:** persistent memory store and shared recall ([#470](https://github.com/macatocz/makato-oss/issues/470)) ([#487](https://github.com/macatocz/makato-oss/issues/487)) ([5393f87](https://github.com/macatocz/makato-oss/commit/5393f87a409601b20b03fa2ff8f562ee786b0dd1))
* **makato-orchestrate:** post structured comment on needs-human-review ([#689](https://github.com/macatocz/makato-oss/issues/689)) ([#692](https://github.com/macatocz/makato-oss/issues/692)) ([0d4788c](https://github.com/macatocz/makato-oss/commit/0d4788c99f2df619eeed93056edf5f3bbb0505a1))
* **makato-orchestrate:** pre-dispatch KEY/slug validation against spec folder ([#445](https://github.com/macatocz/makato-oss/issues/445)) ([#456](https://github.com/macatocz/makato-oss/issues/456)) ([904e90a](https://github.com/macatocz/makato-oss/commit/904e90a26a6704dfa74f8d910259b58e6d1fcecf))
* **makato-orchestrate:** proactive GraphQL rate-limit guard + cheaper board poll ([#556](https://github.com/macatocz/makato-oss/issues/556)) ([#560](https://github.com/macatocz/makato-oss/issues/560)) ([09284f2](https://github.com/macatocz/makato-oss/commit/09284f296aab252176878a3bfea5cdbdb9cbfaa1))
* **makato-orchestrate:** PROGRESS.md roadmap via generate-progress.sh ([#601](https://github.com/macatocz/makato-oss/issues/601)) ([#639](https://github.com/macatocz/makato-oss/issues/639)) ([1ace50f](https://github.com/macatocz/makato-oss/commit/1ace50f84ca865b6353b6ec7973eb8be6c05f9b0))
* **makato-orchestrate:** promote generalizable memory at merge ([#471](https://github.com/macatocz/makato-oss/issues/471)) ([#489](https://github.com/macatocz/makato-oss/issues/489)) ([d453de3](https://github.com/macatocz/makato-oss/commit/d453de37074f2370b543f0bbef3ff6ca2a08844e))
* **makato-orchestrate:** prune orphaned specs folders, promoting lessons first ([#501](https://github.com/macatocz/makato-oss/issues/501)) ([f4ad11b](https://github.com/macatocz/makato-oss/commit/f4ad11b79f3494bc8d37c5da3dfacb6a435f8052))
* **makato-orchestrate:** quality-doc skill — per-domain quality scorecard ([#598](https://github.com/macatocz/makato-oss/issues/598)) ([#635](https://github.com/macatocz/makato-oss/issues/635)) ([0009f17](https://github.com/macatocz/makato-oss/commit/0009f1752cc83a25dfc9e374960cddbd09018a48))
* **makato-orchestrate:** reconcile orphaned In progress board cards ([#368](https://github.com/macatocz/makato-oss/issues/368)) ([#414](https://github.com/macatocz/makato-oss/issues/414)) ([7f8f8a1](https://github.com/macatocz/makato-oss/commit/7f8f8a18a0a986a286dff57fb7ad8379103b6094))
* **makato-orchestrate:** route tier:semantic lessons into semantic.jsonl ([#494](https://github.com/macatocz/makato-oss/issues/494)) ([#508](https://github.com/macatocz/makato-oss/issues/508)) ([530e336](https://github.com/macatocz/makato-oss/commit/530e33622ed41b4a243a1b08a6caee1e89aaf088))
* **makato-orchestrate:** serialize structural-failure evidence into reshape context packet ([#349](https://github.com/macatocz/makato-oss/issues/349)) ([9efd51b](https://github.com/macatocz/makato-oss/commit/9efd51ba485f17ea77b92902414b3e0bf21d8a5e))
* **makato-orchestrate:** specify + verify change-memory recall contract ([#720](https://github.com/macatocz/makato-oss/issues/720)) ([e8039cb](https://github.com/macatocz/makato-oss/commit/e8039cb649e5cf56af0d537f24d322b22a6681a4))
* **makato-orchestrate:** thin-body terminal state reconciliation ([#371](https://github.com/macatocz/makato-oss/issues/371)) ([#388](https://github.com/macatocz/makato-oss/issues/388)) ([43a7322](https://github.com/macatocz/makato-oss/commit/43a732262cc03c17a2b6d7f86df8ad2c184505a6))
* **makato-orchestrate:** thread issue-level trace ID across sessions ([#595](https://github.com/macatocz/makato-oss/issues/595)) ([#678](https://github.com/macatocz/makato-oss/issues/678)) ([a79c01b](https://github.com/macatocz/makato-oss/commit/a79c01b9f2853ed1a5526c07c56ac4086e636cde))
* **makato-orchestrate:** tool-dependency pre-flight in loop.sh ([#587](https://github.com/macatocz/makato-oss/issues/587)) ([#641](https://github.com/macatocz/makato-oss/issues/641)) ([043975f](https://github.com/macatocz/makato-oss/commit/043975f94ae1ab5f47fad95f3ab5bfed4d943b89))
* **makato-orchestrate:** Track VCR in loop-status.json + optional queue-advancement gate ([#585](https://github.com/macatocz/makato-oss/issues/585)) ([4a1dd2f](https://github.com/macatocz/makato-oss/commit/4a1dd2f98845f55c80fb159818e71bb9fc8a70e7))
* **makato-orchestrate:** union-merge append-only files in resolve-pr-conflict ([#383](https://github.com/macatocz/makato-oss/issues/383)) ([dbd2677](https://github.com/macatocz/makato-oss/commit/dbd2677285a911722c031adc6d54f6a5715421c9))
* **makato-orchestrate:** wave-ordered loop dispatch from blocked_by graph ([#548](https://github.com/macatocz/makato-oss/issues/548)) ([8dd41f5](https://github.com/macatocz/makato-oss/commit/8dd41f5ab931eba5909c31941c715cd9ee6236f7))
* **makato-orchestrate:** webhook instant dispatch on status:ready-for-dev ([#599](https://github.com/macatocz/makato-oss/issues/599)) ([#637](https://github.com/macatocz/makato-oss/issues/637)) ([9bc1b37](https://github.com/macatocz/makato-oss/commit/9bc1b374eec0b136a570e516879922111ac71b07))
* **makato-orchestrate:** workflow-state prune subcommand — reap stale done state files by age ([#597](https://github.com/macatocz/makato-oss/issues/597)) ([#609](https://github.com/macatocz/makato-oss/issues/609)) ([14e5c23](https://github.com/macatocz/makato-oss/commit/14e5c231b2b1d27d3150e1dd630e4453746a24a4))
* **makato-plan,makato-orchestrate:** dependency labels blocked-by / blocking ([#481](https://github.com/macatocz/makato-oss/issues/481)) ([4d91305](https://github.com/macatocz/makato-oss/commit/4d91305fd4fb688e825cda69815228a7f5443ca2))
* **makato-plan:** add fastapi & temporal-development archetypes to task-skill-map ([#399](https://github.com/macatocz/makato-oss/issues/399)) ([06a2918](https://github.com/macatocz/makato-oss/commit/06a2918828938a09be0f8ff5674d19f00ffcfbb2)), closes [#394](https://github.com/macatocz/makato-oss/issues/394)
* **makato-plan:** add manage-stores skill with register/list/remove sub-commands ([d0a4838](https://github.com/macatocz/makato-oss/commit/d0a4838cccc357ba6d45a896b1de7427bf81fcc4))
* **makato-plan:** add target_repo to created-issues schema + cross-repo smoke test ([d92f2d0](https://github.com/macatocz/makato-oss/commit/d92f2d065caacaf036a337931494ed4b170a52cb))
* **makato-plan:** cross-repo spec stores -- --repo/--store flags + manage-stores ([#565](https://github.com/macatocz/makato-oss/issues/565)) ([67ab3e3](https://github.com/macatocz/makato-oss/commit/67ab3e3a5adb26c4cae7294bac7abce3240d6d8d))
* **makato-plan:** cross-repo spec stores -- --repo/--store flags + manage-stores ([#565](https://github.com/macatocz/makato-oss/issues/565)) ([67ab3e3](https://github.com/macatocz/makato-oss/commit/67ab3e3a5adb26c4cae7294bac7abce3240d6d8d))
* **makato-plan:** decompose emits taxonomic type: label; to-issues honors it ([#272](https://github.com/macatocz/makato-oss/issues/272)) ([#275](https://github.com/macatocz/makato-oss/issues/275)) ([7bde925](https://github.com/macatocz/makato-oss/commit/7bde9256c3d4a31a0dffdec07871bc060c149169))
* **makato-plan:** enforce Fibonacci ≤13 SP cap + split-preferred rule in decompose ([#554](https://github.com/macatocz/makato-oss/issues/554)) ([#557](https://github.com/macatocz/makato-oss/issues/557)) ([a06f014](https://github.com/macatocz/makato-oss/commit/a06f0147db4271c4b59838e77fb3619422a43726))
* **makato-plan:** stores[] schema in config.json + manage-stores.sh register/list/remove ([0a0459d](https://github.com/macatocz/makato-oss/commit/0a0459de99d1495dece045db8f9d18f069029ceb))
* **makato-plan:** to-issues --repo and --store flags for cross-repo issue creation ([e5ce3de](https://github.com/macatocz/makato-oss/commit/e5ce3de36d8dabdb87e1eaab6f21b0547b3cd897))
* **makato-plan:** value-bearing blocked-by:N labels with GHA auto-cleanup ([#608](https://github.com/macatocz/makato-oss/issues/608)) ([#676](https://github.com/macatocz/makato-oss/issues/676)) ([a7ba76e](https://github.com/macatocz/makato-oss/commit/a7ba76eff58e38bd4f85874fcb99b291f14897fd))
* **makato-temporal:** add config/skill-bundles.yml ([#297](https://github.com/macatocz/makato-oss/issues/297)) ([0a749e1](https://github.com/macatocz/makato-oss/commit/0a749e13059313fceecd2b3f46d97e26976f258c))
* **makato-temporal:** add JSONL audit-logging blocks to temporal-development skill ([#710](https://github.com/macatocz/makato-oss/issues/710)) ([#773](https://github.com/macatocz/makato-oss/issues/773)) ([679a64b](https://github.com/macatocz/makato-oss/commit/679a64b64e67bae79f1fc66f7759499465e3aa3f))
* **makato-temporal:** new plugin housing temporal-development skill ([#273](https://github.com/macatocz/makato-oss/issues/273)) ([5b28bfb](https://github.com/macatocz/makato-oss/commit/5b28bfb09d4dc86725bdc3879afb4f1955f08ea9))
* mark issue In Progress at workflow start ([#477](https://github.com/macatocz/makato-oss/issues/477)) ([5eefb0f](https://github.com/macatocz/makato-oss/commit/5eefb0f5bb71c53a3ebc92faa4bdd597d1f92c8c))
* **observability:** Langfuse session tracing hook + plugin/phase tags ([#525](https://github.com/macatocz/makato-oss/issues/525)) ([a57faff](https://github.com/macatocz/makato-oss/commit/a57faff08d210501e7c7b04e57816be7ac777e4c))
* **repo-wide:** add .devcontainer spec for uv + Python 3.14 ([11a972e](https://github.com/macatocz/makato-oss/commit/11a972efe124de155374fe6aece55b59cab037f9))
* **repo-wide:** Add .python-version pin and .devcontainer for cold-start reproducibility ([b649743](https://github.com/macatocz/makato-oss/commit/b649743f6d1cd34a3ded924806e026e8fbbfb2c1))
* **repo-wide:** Add .python-version pin and .devcontainer for cold-start reproducibility ([b649743](https://github.com/macatocz/makato-oss/commit/b649743f6d1cd34a3ded924806e026e8fbbfb2c1))
* **repo-wide:** add .python-version pin to 3.14 ([d501a16](https://github.com/macatocz/makato-oss/commit/d501a16c7ec55c3e66119f055e74d42a79b26274))
* **repo-wide:** bump requires-python to &gt;=3.14 in pyproject.toml ([2430700](https://github.com/macatocz/makato-oss/commit/24307000109ff19caea49270480234dc0c968093)), closes [#588](https://github.com/macatocz/makato-oss/issues/588)
* **repo-wide:** standardize ## Hard Constraints first section in every plugin AGENTS.md + lint gate ([#589](https://github.com/macatocz/makato-oss/issues/589)) ([#664](https://github.com/macatocz/makato-oss/issues/664)) ([addd777](https://github.com/macatocz/makato-oss/commit/addd777256550b362d03c171d74ca33d900e7f91))
* **skill-bundles:** remove unnecessary skills from contribute-skills bundle ([a0aed04](https://github.com/macatocz/makato-oss/commit/a0aed04e055cbf2fb875a11a423a92ec741adbb6))
* **to-issues:** derive effort:* from a points signal ([#431](https://github.com/macatocz/makato-oss/issues/431)) ([cbbc21d](https://github.com/macatocz/makato-oss/commit/cbbc21d0f78e3b840b1f54039f9b91cb7e7b5d73))
* **to-issues:** derive priority:* from tier:* as fallback ([#424](https://github.com/macatocz/makato-oss/issues/424)) ([538bf77](https://github.com/macatocz/makato-oss/commit/538bf77f0bc0044e5d6760a11c992f399a075f66))
* **to-issues:** emit plan-&lt;ISSUE_NUMBER&gt;.md per full-tier story at issue-create time ([9432bdc](https://github.com/macatocz/makato-oss/commit/9432bdc9c2943d26973b401023ef277f40eb4c01))
* **to-issues:** emit plan-&lt;N&gt;.md per full-tier story ([#511](https://github.com/macatocz/makato-oss/issues/511)) ([f2b0e2e](https://github.com/macatocz/makato-oss/commit/f2b0e2eee3c863df4957327bf199118c607cd773))
* **to-issues:** emit plan-&lt;N&gt;.md per full-tier story ([#511](https://github.com/macatocz/makato-oss/issues/511)) ([f2b0e2e](https://github.com/macatocz/makato-oss/commit/f2b0e2eee3c863df4957327bf199118c607cd773))
* verify acceptance criteria before marking issue checkboxes ([#375](https://github.com/macatocz/makato-oss/issues/375)) ([2de78db](https://github.com/macatocz/makato-oss/commit/2de78db7c999a2b25d55405a39082a7824a2a68a))


### 🐛 Bug Fixes

* **.gitignore:** re-include specs/**/build.jsonl audit trail ([#321](https://github.com/macatocz/makato-oss/issues/321)) ([#329](https://github.com/macatocz/makato-oss/issues/329)) ([6dd7b37](https://github.com/macatocz/makato-oss/commit/6dd7b373e72e89db54154878831656b67d8d696e))
* **build-sensors:** reveal untracked files to Gate 0 --all-files scan ([#523](https://github.com/macatocz/makato-oss/issues/523)) ([6483050](https://github.com/macatocz/makato-oss/commit/6483050716b7e589824ea7feb5351d73ab169594))
* **ci:** scope project-board-sync issue concurrency by action ([#468](https://github.com/macatocz/makato-oss/issues/468)) ([#469](https://github.com/macatocz/makato-oss/issues/469)) ([172019e](https://github.com/macatocz/makato-oss/commit/172019e69f150509dd4327b6fdf091f1c30a7f3e))
* **config:** add github_project.id (GraphQL node ID) for board writes ([#741](https://github.com/macatocz/makato-oss/issues/741)) ([c0b6a5b](https://github.com/macatocz/makato-oss/commit/c0b6a5bfa35b59ae6e82b8d95085bc5adb6b8b59))
* **flow:** hide-panels button swallowed by pointerdown capture ([#433](https://github.com/macatocz/makato-oss/issues/433)) ([891c033](https://github.com/macatocz/makato-oss/commit/891c033bd2c772250d677a95b9148d91b9e5b033))
* isolate makato-change orchestrate in a worktree on fresh runs and resumes ([#467](https://github.com/macatocz/makato-oss/issues/467)) ([#485](https://github.com/macatocz/makato-oss/issues/485)) ([7757329](https://github.com/macatocz/makato-oss/commit/7757329e283df954cb4cf38452958397cdab2b51))
* **loop:** auto-seed consults should-materialize-spec before blocking ([#533](https://github.com/macatocz/makato-oss/issues/533)) ([#540](https://github.com/macatocz/makato-oss/issues/540)) ([cad8e2e](https://github.com/macatocz/makato-oss/commit/cad8e2eb67fb409774036421492a11f094e2ef64))
* **loop:** demote exit-127 refine log and numberless-folder reap-specs WARN to debug/info ([#569](https://github.com/macatocz/makato-oss/issues/569)) ([6edba9b](https://github.com/macatocz/makato-oss/commit/6edba9b8c0721a6b6dc96628484ccf3efabaea2c)), closes [#558](https://github.com/macatocz/makato-oss/issues/558)
* **loop:** post-halt-comment derives repo when arg empty ([#450](https://github.com/macatocz/makato-oss/issues/450)) ([#757](https://github.com/macatocz/makato-oss/issues/757)) ([47efcdb](https://github.com/macatocz/makato-oss/commit/47efcdb62e68fbbe2ca5b073d31171c754e776af))
* **loop:** resolve post-halt-comment.sh next to script for consumer repos ([#744](https://github.com/macatocz/makato-oss/issues/744)) ([#745](https://github.com/macatocz/makato-oss/issues/745)) ([8dbc452](https://github.com/macatocz/makato-oss/commit/8dbc452144fb1ac501cde123d03091613928d16e))
* **loop:** skip reconcile for CLOSED issues (terminal-state guard) ([#740](https://github.com/macatocz/makato-oss/issues/740)) ([7bdf998](https://github.com/macatocz/makato-oss/commit/7bdf99856bb0dba6d3925154a4937f6992c5032e))
* **makato-build:** add cross-task regression sweep to TDD outer loop ([#285](https://github.com/macatocz/makato-oss/issues/285)) ([#301](https://github.com/macatocz/makato-oss/issues/301)) ([fcff000](https://github.com/macatocz/makato-oss/commit/fcff000dd01cf13d5f1c340607d6de916e8c8f12))
* **makato-build:** build-verify Gates 1-2 use pre-commit hooks, not raw tools ([#450](https://github.com/macatocz/makato-oss/issues/450)) ([#463](https://github.com/macatocz/makato-oss/issues/463)) ([ff2c63d](https://github.com/macatocz/makato-oss/commit/ff2c63db059674a12f84a5e63a3c12be18f26bce))
* **makato-build:** gate advisory diff-reviewer + coverage-floor escapes ([#290](https://github.com/macatocz/makato-oss/issues/290)) ([#314](https://github.com/macatocz/makato-oss/issues/314)) ([2005beb](https://github.com/macatocz/makato-oss/commit/2005beb470e45cb882ac28c420518a2cf3afc857))
* **makato-build:** guard against string description in check_correctness ([24cb760](https://github.com/macatocz/makato-oss/commit/24cb760c6696fce927cb1ee263d72a0c56f75e11))
* **makato-build:** reconcile documented-but-unwired mechanisms ([#287](https://github.com/macatocz/makato-oss/issues/287)) ([#307](https://github.com/macatocz/makato-oss/issues/307)) ([6cd6809](https://github.com/macatocz/makato-oss/commit/6cd6809ffcf94abb62b9cf5786c1a4820e5973b3))
* **makato-build:** resolve 16 feature-audit gaps (documentation accuracy) ([#788](https://github.com/macatocz/makato-oss/issues/788)) ([dbe6072](https://github.com/macatocz/makato-oss/commit/dbe6072a20dd00bf41f29f99d5979386debcc7a9))
* **makato-build:** route biome 'files were modified' autofix signal ([#437](https://github.com/macatocz/makato-oss/issues/437)) ([5b419cb](https://github.com/macatocz/makato-oss/commit/5b419cb78fd779bf6a99a9b335201fcee8f0da72))
* **makato-contribute:** correct plugin-creator Step 5 preview and default author ([bb2e950](https://github.com/macatocz/makato-oss/commit/bb2e950e529485ac270c1882b4782bd3b7848f86))
* **makato-contribute:** enforce skill-creator Step 15 persist-plan via checklist ([e98cbf9](https://github.com/macatocz/makato-oss/commit/e98cbf952bcdea58f143003b9aef2c9a5c479194))
* **makato-contribute:** remove stale skills-array instruction from sync-from-upstream Step 8 ([f89fe02](https://github.com/macatocz/makato-oss/commit/f89fe02a9df3f3cd767c711798da02f8d983b239))
* **makato-contribute:** replace contains with task_contains in contribute-plugin-creation bundle ([ae98c74](https://github.com/macatocz/makato-oss/commit/ae98c74375d755f1e02d40755a2152e2458282e4))
* **makato-contribute:** resolve 4 feature-audit gaps ([#715](https://github.com/macatocz/makato-oss/issues/715)) ([32ad9cd](https://github.com/macatocz/makato-oss/commit/32ad9cd040525661bf1a6838d80a9813068a6e09))
* **makato-contribute:** resolve 4 feature-audit gaps ([#715](https://github.com/macatocz/makato-oss/issues/715)) ([32ad9cd](https://github.com/macatocz/makato-oss/commit/32ad9cd040525661bf1a6838d80a9813068a6e09))
* **makato-core:** register init skill in makato-flow.inventory.json ([#566](https://github.com/macatocz/makato-oss/issues/566)) ([c15508f](https://github.com/macatocz/makato-oss/commit/c15508faa862288ce62e96a874ef6451e30a11ab))
* **makato-core:** resolve 7 feature-audit gaps (contracts, labels, hook docs) ([70ac0eb](https://github.com/macatocz/makato-oss/commit/70ac0eb0b12fe964a560a07c0c2cfcd37f41c4f9))
* **makato-doc:** clarify JSONL audit constraint for doc-utility skills ([5dc7daf](https://github.com/macatocz/makato-oss/commit/5dc7daf420d13b629ffd7c5c601371b7f15bf581))
* **makato-doc:** correct context7 allowed-tools prefix to mcp__plugin_general_context7__ ([6d62e9c](https://github.com/macatocz/makato-oss/commit/6d62e9cadd16f7ac405529b7c37cdc7286f3f5c6))
* **makato-doc:** remove stale ContextScout/ExternalScout from context7 README ([f9bc31a](https://github.com/macatocz/makato-oss/commit/f9bc31a9c442bc476c730c9b8a62530c575bad7c))
* **makato-doc:** resolve 3 feature-audit gaps ([#713](https://github.com/macatocz/makato-oss/issues/713)) ([0d0a283](https://github.com/macatocz/makato-oss/commit/0d0a283a22eceb076e0eca8b58ef5cd1835a7bc9))
* **makato-doc:** resolve 3 feature-audit gaps ([#713](https://github.com/macatocz/makato-oss/issues/713)) ([0d0a283](https://github.com/macatocz/makato-oss/commit/0d0a283a22eceb076e0eca8b58ef5cd1835a7bc9))
* **makato-doc:** update plugin README version table (context7 1.2.0, markdown 1.4.0) ([97266c4](https://github.com/macatocz/makato-oss/commit/97266c42cd3c5200629bf537055856201fc8e0ee))
* **makato-fastapi:** resolve 5 feature-audit gaps ([#708](https://github.com/macatocz/makato-oss/issues/708)) ([#778](https://github.com/macatocz/makato-oss/issues/778)) ([abbcdd2](https://github.com/macatocz/makato-oss/commit/abbcdd2f2b3de10596fbcd22baa4d00e2e911b90))
* **makato-langgraph:** cross-plugin collision gate + robust shared path resolution ([#335](https://github.com/macatocz/makato-oss/issues/335)) ([21887ed](https://github.com/macatocz/makato-oss/commit/21887edf1948c4ab68d2c91479ba5e3a9015c9df))
* **makato-langgraph:** qualify JSONL audit constraint to exempt reference skills ([baa401d](https://github.com/macatocz/makato-oss/commit/baa401d3d208d904879447f96a2a00d7570e52ba))
* **makato-langgraph:** replace mislabeled static fan-out with correct Send-based map-reduce example ([a25cdc6](https://github.com/macatocz/makato-oss/commit/a25cdc6bcc218daeec5a5993c10fda0c11e528c1))
* **makato-langgraph:** resolve 2 feature-audit gaps (JSONL constraint + Send map-reduce example) ([0cd91f4](https://github.com/macatocz/makato-oss/commit/0cd91f4fe0bb68578e45ebfb146db7c53a11af42))
* **makato-orchestrate:** --repo flag and early-exit REPO validation for dispatch ([#461](https://github.com/macatocz/makato-oss/issues/461)) ([ed61aea](https://github.com/macatocz/makato-oss/commit/ed61aea2da0d5a23a0e35e877eced8beb29fc6ec))
* **makato-orchestrate:** add stale-worktree reaping for crashed runs ([#320](https://github.com/macatocz/makato-oss/issues/320)) ([#338](https://github.com/macatocz/makato-oss/issues/338)) ([959ea7c](https://github.com/macatocz/makato-oss/commit/959ea7c1f068a2cd90cb9ef922878ba18feff1b6))
* **makato-orchestrate:** auto-seed and pre-dispatch gate bypass type:change ([#466](https://github.com/macatocz/makato-oss/issues/466)) ([#479](https://github.com/macatocz/makato-oss/issues/479)) ([5e205d2](https://github.com/macatocz/makato-oss/commit/5e205d2582bdcef176ff3ed8450e9f8e7124515e))
* **makato-orchestrate:** auto-seed skips issues already planned by to-issues ([#626](https://github.com/macatocz/makato-oss/issues/626)) ([d95c050](https://github.com/macatocz/makato-oss/commit/d95c050db428c17aae11cab7bca137cfc200ae87))
* **makato-orchestrate:** auto-seed-block derives slug from footer KEY, not title ([#571](https://github.com/macatocz/makato-oss/issues/571)) ([#573](https://github.com/macatocz/makato-oss/issues/573)) ([1a8ef6b](https://github.com/macatocz/makato-oss/commit/1a8ef6b025d20913e1613e70c95d80e4facfbaa5))
* **makato-orchestrate:** avoid doubled issue-number prefix in loop dispatch branch ([#483](https://github.com/macatocz/makato-oss/issues/483)) ([57f04ad](https://github.com/macatocz/makato-oss/commit/57f04adee054f242ac97261537e0e5e282e4f72f))
* **makato-orchestrate:** board_applied:false in emit-needs-planning-signal ([#682](https://github.com/macatocz/makato-oss/issues/682)) ([#685](https://github.com/macatocz/makato-oss/issues/685)) ([61860ca](https://github.com/macatocz/makato-oss/commit/61860ca85319b7c9eb7f4e3d64617c633b5a43fb))
* **makato-orchestrate:** bound Step 6b review poll with wall-clock timeout ([#283](https://github.com/macatocz/makato-oss/issues/283)) ([#305](https://github.com/macatocz/makato-oss/issues/305)) ([274eecd](https://github.com/macatocz/makato-oss/commit/274eecd0a1b1361e83edefb14b7da378abff0fb3))
* **makato-orchestrate:** don't false-HALT-012 when review is not required ([#726](https://github.com/macatocz/makato-oss/issues/726)) ([6550844](https://github.com/macatocz/makato-oss/commit/6550844cc9fec952c0171142cb7d367ea6552d06))
* **makato-orchestrate:** emit loud degraded warning when jsonschema missing ([#317](https://github.com/macatocz/makato-oss/issues/317)) ([#337](https://github.com/macatocz/makato-oss/issues/337)) ([2ac2b80](https://github.com/macatocz/makato-oss/commit/2ac2b80e125fc327b95622aaf4d877934515dd2e))
* **makato-orchestrate:** enable headless CLI retry to survive transient API stalls ([da5d800](https://github.com/macatocz/makato-oss/commit/da5d8000d615fced4a8f24f7a4df3a40d718bb69))
* **makato-orchestrate:** exclude needs-human-review from Ready re-promotion ([#286](https://github.com/macatocz/makato-oss/issues/286)) ([#303](https://github.com/macatocz/makato-oss/issues/303)) ([62f6afa](https://github.com/macatocz/makato-oss/commit/62f6afaff5cc546803b1212ab91313becaa98d78))
* **makato-orchestrate:** export MAKATO_ORCHESTRATE_SHARED in loop.sh dispatch ([14ad054](https://github.com/macatocz/makato-oss/commit/14ad054e0abde0700eb1287f9370ca5e01d8d262))
* **makato-orchestrate:** gate label stamp on board edit success in reconcile passes ([#653](https://github.com/macatocz/makato-oss/issues/653)) ([f5bc7d5](https://github.com/macatocz/makato-oss/commit/f5bc7d588e9dc345c5784dd1388d5550d10ac8b1))
* **makato-orchestrate:** give CI-failure loop its own budget counter ([#288](https://github.com/macatocz/makato-oss/issues/288)) ([#309](https://github.com/macatocz/makato-oss/issues/309)) ([781c2a1](https://github.com/macatocz/makato-oss/commit/781c2a148eb9ad8bde4a4bb96f4a7a55b2257bfb))
* **makato-orchestrate:** GraphQL rate-limit circuit-breaker in loop ([#683](https://github.com/macatocz/makato-oss/issues/683)) ([#695](https://github.com/macatocz/makato-oss/issues/695)) ([aeeed03](https://github.com/macatocz/makato-oss/commit/aeeed03a1ec1a5bac19a8b6cd778e02b726a868d))
* **makato-orchestrate:** guard watchdog writes by ownership + flake-probe CI failures ([#312](https://github.com/macatocz/makato-oss/issues/312)) ([#328](https://github.com/macatocz/makato-oss/issues/328)) ([02c6ff0](https://github.com/macatocz/makato-oss/commit/02c6ff0e11f16a58f4fce2f707486cdcbb8b9141))
* **makato-orchestrate:** HALT-007B evaluates per-session token delta ([#281](https://github.com/macatocz/makato-oss/issues/281)) ([#294](https://github.com/macatocz/makato-oss/issues/294)) ([e789b7c](https://github.com/macatocz/makato-oss/commit/e789b7cc17b5837a2bbea497d2b84061ef8d8ddc))
* **makato-orchestrate:** HALT-015 for orphaned-card reconcilers with runtime context ([#786](https://github.com/macatocz/makato-oss/issues/786)) ([#790](https://github.com/macatocz/makato-oss/issues/790)) ([a24b87e](https://github.com/macatocz/makato-oss/commit/a24b87e92d43835263154350e914339d351eecf0))
* **makato-orchestrate:** loop bg-session guard + --status passthrough ([#743](https://github.com/macatocz/makato-oss/issues/743)); demote folderless-Ready to Todo ([#783](https://github.com/macatocz/makato-oss/issues/783)) ([#804](https://github.com/macatocz/makato-oss/issues/804)) ([f6c197c](https://github.com/macatocz/makato-oss/commit/f6c197c81a6d2abeda7cef27d9841707fdfc9cb1))
* **makato-orchestrate:** loop claims board card synchronously to stop cross-worktree double-dispatch ([#259](https://github.com/macatocz/makato-oss/issues/259)) ([#261](https://github.com/macatocz/makato-oss/issues/261)) ([eae10a1](https://github.com/macatocz/makato-oss/commit/eae10a175d7e3daa0e9795a3222543af7f70cf95))
* **makato-orchestrate:** loop-supervisor false-positive restart on long dispatch ([#779](https://github.com/macatocz/makato-oss/issues/779)) ([#781](https://github.com/macatocz/makato-oss/issues/781)) ([b42d429](https://github.com/macatocz/makato-oss/commit/b42d4297a584b09ba5d2242f63ac37e865295de2))
* **makato-orchestrate:** make _write_status atomic via same-dir mktemp ([#316](https://github.com/macatocz/makato-oss/issues/316)) ([#336](https://github.com/macatocz/makato-oss/issues/336)) ([3b1e0d3](https://github.com/macatocz/makato-oss/commit/3b1e0d3cb7d3292a297f2a35c39726552b43d5ae))
* **makato-orchestrate:** plan-tier:change overrides co-present type:* in loop routing ([#760](https://github.com/macatocz/makato-oss/issues/760)) ([#766](https://github.com/macatocz/makato-oss/issues/766)) ([6721652](https://github.com/macatocz/makato-oss/commit/67216528edcc0465038a07db96e3f28dfeac6061))
* **makato-orchestrate:** plan-tier:change routes to change lane ([#539](https://github.com/macatocz/makato-oss/issues/539)) ([#542](https://github.com/macatocz/makato-oss/issues/542)) ([a6e9298](https://github.com/macatocz/makato-oss/commit/a6e9298ced2abab772ee61be80db005d3de2ea5c))
* **makato-orchestrate:** PO-agent self-recovery after Stream idle timeout ([#616](https://github.com/macatocz/makato-oss/issues/616)) ([#629](https://github.com/macatocz/makato-oss/issues/629)) ([d032928](https://github.com/macatocz/makato-oss/commit/d03292814239b93b6a1110045f1b1de045cce16a))
* **makato-orchestrate:** promote lessons in po-agent local lane, drop GHA no-op ([#502](https://github.com/macatocz/makato-oss/issues/502)) ([#504](https://github.com/macatocz/makato-oss/issues/504)) ([8e898b9](https://github.com/macatocz/makato-oss/commit/8e898b9e24dcc43dcd9d60be747b3b392f04f762))
* **makato-orchestrate:** re-verify loop.sh stability, fix 3 of 4 known bugs ([#721](https://github.com/macatocz/makato-oss/issues/721)) ([#801](https://github.com/macatocz/makato-oss/issues/801)) ([d7358c4](https://github.com/macatocz/makato-oss/commit/d7358c49b2bfb52045017d6c40673138c760ee63))
* **makato-orchestrate:** reap-and-resume killed PO-agent at phase:pr ([#732](https://github.com/macatocz/makato-oss/issues/732)) ([#802](https://github.com/macatocz/makato-oss/issues/802)) ([f9d2c9e](https://github.com/macatocz/makato-oss/commit/f9d2c9ea966854fb9f40d96a9fbeee1c62ca177f))
* **makato-orchestrate:** reaper landed-detection — ancestry + tracked-only dirty + nested-child ([#265](https://github.com/macatocz/makato-oss/issues/265)) ([#269](https://github.com/macatocz/makato-oss/issues/269)) ([bbd0aa5](https://github.com/macatocz/makato-oss/commit/bbd0aa51a2384a69828e231d8ca9b1b228cbf22e))
* **makato-orchestrate:** reconcile pass reads Status field/option ids from correct config shape ([#492](https://github.com/macatocz/makato-oss/issues/492)) ([#495](https://github.com/macatocz/makato-oss/issues/495)) ([0e2d348](https://github.com/macatocz/makato-oss/commit/0e2d348d487234c621105116877fb13832285e2f))
* **makato-orchestrate:** reconcilers use --project-id in gh item-edit ([#697](https://github.com/macatocz/makato-oss/issues/697)) ([#700](https://github.com/macatocz/makato-oss/issues/700)) ([bf8eebe](https://github.com/macatocz/makato-oss/commit/bf8eebee1d5189ca04e1a9bf97f4ef95e2411012))
* **makato-orchestrate:** reset board card to Ready after api_error dispatch (687-makato-orchestrate--bug--api-error-dispa) ([#698](https://github.com/macatocz/makato-oss/issues/698)) ([131dd89](https://github.com/macatocz/makato-oss/commit/131dd89f7c06096c9380bc7e8903e929db0ece93))
* **makato-orchestrate:** resolve 4 feature-audit gaps (4 partial) ([#706](https://github.com/macatocz/makato-oss/issues/706)) ([#784](https://github.com/macatocz/makato-oss/issues/784)) ([12407ae](https://github.com/macatocz/makato-oss/commit/12407ae3647d3f57b66ef133ded95bc0f414f19f))
* **makato-orchestrate:** resolve board item-id via cheap single-issue GraphQL, not whole-board item-list ([#736](https://github.com/macatocz/makato-oss/issues/736)) ([3291465](https://github.com/macatocz/makato-oss/commit/3291465938be6e78aa9b7fb4ae32e5967ca0e599))
* **makato-orchestrate:** resolve specs/ from main checkout in worktree runs ([#282](https://github.com/macatocz/makato-oss/issues/282)) ([#298](https://github.com/macatocz/makato-oss/issues/298)) ([ffa974b](https://github.com/macatocz/makato-oss/commit/ffa974b5e8c9c2f675d35037fd652317ce7006fa))
* **makato-orchestrate:** retry board poll, stop treating 429 as empty queue ([#289](https://github.com/macatocz/makato-oss/issues/289)) ([#313](https://github.com/macatocz/makato-oss/issues/313)) ([6b17096](https://github.com/macatocz/makato-oss/commit/6b170961a4e3e62ae2f10b5528f61c3323339ec3))
* **makato-orchestrate:** route reconciler board reads through rate-guarded wrapper ([#630](https://github.com/macatocz/makato-oss/issues/630)) ([0e3f29d](https://github.com/macatocz/makato-oss/commit/0e3f29d22f4dfc70b7ee80064c975c52902879af))
* **makato-orchestrate:** scope loop pre-flight gh auth status to target host ([#656](https://github.com/macatocz/makato-oss/issues/656)) ([#659](https://github.com/macatocz/makato-oss/issues/659)) ([b837376](https://github.com/macatocz/makato-oss/commit/b8373761c89d4bb3178646777c06841fa534f822))
* **makato-orchestrate:** shared-epic folder guard in reaper (loop 2.2.0) ([2ca1d63](https://github.com/macatocz/makato-oss/commit/2ca1d6368bd66898130e8dbd39c54c0bee3b0419))
* **makato-orchestrate:** shared-epic folder guard in reaper (loop 2.2.0) ([#607](https://github.com/macatocz/makato-oss/issues/607)) ([ec93f45](https://github.com/macatocz/makato-oss/commit/ec93f45f292dd57ac3a6ac62f9630a43a5ddb771))
* **makato-orchestrate:** skip CLOSED issues in promote-ready candidate selection ([#747](https://github.com/macatocz/makato-oss/issues/747)) ([#768](https://github.com/macatocz/makato-oss/issues/768)) ([7cb252c](https://github.com/macatocz/makato-oss/commit/7cb252cc87999cc4928e6a2eef5d11b0d269feec))
* **makato-orchestrate:** supervise HALT-007B restart subprocess liveness ([#284](https://github.com/macatocz/makato-oss/issues/284)) ([#311](https://github.com/macatocz/makato-oss/issues/311)) ([38b6200](https://github.com/macatocz/makato-oss/commit/38b62004e1e456981462a804e60589f6aed644ca))
* **makato-orchestrate:** update stale status:ready-for-dev reference in auto-seed-block comment ([#733](https://github.com/macatocz/makato-oss/issues/733)) ([409f9a7](https://github.com/macatocz/makato-oss/commit/409f9a78f3b616e1d64f73cae6ff3039ee927f7e))
* **makato-plan:** replace broken project-view fields assertion with field-list probe ([#606](https://github.com/macatocz/makato-oss/issues/606)) ([#647](https://github.com/macatocz/makato-oss/issues/647)) ([fe26c2e](https://github.com/macatocz/makato-oss/commit/fe26c2ec28eb8a75e5829abbcf3c37fc80c40556))
* **makato-plan:** resolve 7 feature-audit gaps ([#703](https://github.com/macatocz/makato-oss/issues/703)) ([#792](https://github.com/macatocz/makato-oss/issues/792)) ([ba24117](https://github.com/macatocz/makato-oss/commit/ba24117effb037312d41d7c31596786ec69d4702))
* **makato-plan:** Step 3 FIELD_NOT_FOUND check uses broken fields.nodes traversal ([#648](https://github.com/macatocz/makato-oss/issues/648)) ([#680](https://github.com/macatocz/makato-oss/issues/680)) ([0ea79b4](https://github.com/macatocz/makato-oss/commit/0ea79b4ad4a00d9f8f3cadf674e9fbe009e9c9a9))
* **makato-sagibeast:** document sagibeast-testbox runner label contract ([#577](https://github.com/macatocz/makato-oss/issues/577)) ([#578](https://github.com/macatocz/makato-oss/issues/578)) ([ffd8898](https://github.com/macatocz/makato-oss/commit/ffd8898219918df1afc6713b532e0b1171446986))
* **makato-sagibeast:** resolve 4 feature-audit gaps ([#714](https://github.com/macatocz/makato-oss/issues/714)) ([bc23bad](https://github.com/macatocz/makato-oss/commit/bc23badab92f005fe9d77173e966678285117205))
* **makato-temporal:** route temporal-development via tech:temporal label ([#358](https://github.com/macatocz/makato-oss/issues/358)) ([1a691a0](https://github.com/macatocz/makato-oss/commit/1a691a04b88f96b3c66ebfe18b73cd2aedf4c5e0))
* **makato-ux:** resolve 4 feature-audit gaps (1 broken, 3 partial) [#712](https://github.com/macatocz/makato-oss/issues/712) ([#771](https://github.com/macatocz/makato-oss/issues/771)) ([70ce204](https://github.com/macatocz/makato-oss/commit/70ce20407dd557ee2a5c19e16413ccc2788f5f65))
* **repo:** tighten check-self-contained.sh matcher; flip CI gate to blocking ([#730](https://github.com/macatocz/makato-oss/issues/730)) ([#800](https://github.com/macatocz/makato-oss/issues/800)) ([72b3a02](https://github.com/macatocz/makato-oss/commit/72b3a02c4dc0658ea14945dd1cd206a177ce4903))
* **scripts:** derive D22 bundle-coverage denominator from live plugin count ([#293](https://github.com/macatocz/makato-oss/issues/293)) ([87d6e40](https://github.com/macatocz/makato-oss/commit/87d6e402b5c39624db9cb7e7deb0a6010e157ddd))
* **scripts:** make regenerate-agents.sh a no-op — stop writing to root AGENTS.md / CLAUDE.md ([50c0c17](https://github.com/macatocz/makato-oss/commit/50c0c17d94f63eba9041003455935d5a1b3b8c86))
* **scripts:** skip root AGENTS.md generation, write routing content directly to CLAUDE.md ([82f67b0](https://github.com/macatocz/makato-oss/commit/82f67b0494f4f6e5adabc1eb1b83225715c705e3))


### ⚡ Performance

* **orchestrate:** cut board-poll GraphQL cost ~100x + adaptive idle backoff ([f27c814](https://github.com/macatocz/makato-oss/commit/f27c814ad59395319fdc4ccb8b1479a8dfbbecae))
* **orchestrate:** cut board-poll GraphQL cost ~100x + adaptive idle backoff ([417f4a5](https://github.com/macatocz/makato-oss/commit/417f4a549da5c2bfcd04b77b92e75790efd88c93)), closes [#516](https://github.com/macatocz/makato-oss/issues/516)


### ♻️ Refactors

* **makato-contribute:** remove manage-pr, consolidate into build-address-pr-comments ([#393](https://github.com/macatocz/makato-oss/issues/393)) ([05eacef](https://github.com/macatocz/makato-oss/commit/05eacefb12b186f4678d3601dd306c2c4a6ad492))
* **makato-core:** rename zoom-out skill to map-codebase-context ([#397](https://github.com/macatocz/makato-oss/issues/397)) ([#403](https://github.com/macatocz/makato-oss/issues/403)) ([97f65be](https://github.com/macatocz/makato-oss/commit/97f65be9e95396724e00ed24649296d0b6616f21))
* **makato-orchestrate:** rename scout agent to task-file-scout ([#397](https://github.com/macatocz/makato-oss/issues/397)) ([#404](https://github.com/macatocz/makato-oss/issues/404)) ([841d306](https://github.com/macatocz/makato-oss/commit/841d306bd6ca3a83e5ce5c5b8052419c824cfb58))
* **makato-orchestrate:** split loop.sh into main flow + functions + config ([#813](https://github.com/macatocz/makato-oss/issues/813)) ([7624e59](https://github.com/macatocz/makato-oss/commit/7624e598cc66a9923c96de84a276b0eee819433a))
* **makato-plan:** rename grill skill to stress-test-artifact ([#397](https://github.com/macatocz/makato-oss/issues/397)) ([#405](https://github.com/macatocz/makato-oss/issues/405)) ([49b431d](https://github.com/macatocz/makato-oss/commit/49b431d982c9d44df8608663829fce2eb8f8674e))


### 🤖 CI

* **makato-orchestrate:** wire loop-change-dispatch integration tests into validate.yml ([#717](https://github.com/macatocz/makato-oss/issues/717)) ([685ffdd](https://github.com/macatocz/makato-oss/commit/685ffdd90877abe98a2c91a1d1f6ffdeb321cf67))

## [0.148.0](https://github.com/macatocz/makato/compare/v0.147.3...v0.148.0) (2026-08-10)


### ✨ Features

* classify plan-tier by decomposition signal, not body length ([#815](https://github.com/macatocz/makato/issues/815)) ([2d39d05](https://github.com/macatocz/makato/commit/2d39d051a22c04ecc9f9e9cad4e87a597a1b94fe))

## [0.147.3](https://github.com/macatocz/makato/compare/v0.147.2...v0.147.3) (2026-08-10)


### ♻️ Refactors

* **makato-orchestrate:** split loop.sh into main flow + functions + config ([#813](https://github.com/macatocz/makato/issues/813)) ([7624e59](https://github.com/macatocz/makato/commit/7624e598cc66a9923c96de84a276b0eee819433a))

## [0.147.2](https://github.com/macatocz/makato/compare/v0.147.1...v0.147.2) (2026-08-10)


### 🐛 Bug Fixes

* **makato-orchestrate:** loop bg-session guard + --status passthrough ([#743](https://github.com/macatocz/makato/issues/743)); demote folderless-Ready to Todo ([#783](https://github.com/macatocz/makato/issues/783)) ([#804](https://github.com/macatocz/makato/issues/804)) ([f6c197c](https://github.com/macatocz/makato/commit/f6c197c81a6d2abeda7cef27d9841707fdfc9cb1))

## [0.147.1](https://github.com/macatocz/makato/compare/v0.147.0...v0.147.1) (2026-08-09)


### 🐛 Bug Fixes

* **makato-orchestrate:** re-verify loop.sh stability, fix 3 of 4 known bugs ([#721](https://github.com/macatocz/makato/issues/721)) ([#801](https://github.com/macatocz/makato/issues/801)) ([d7358c4](https://github.com/macatocz/makato/commit/d7358c49b2bfb52045017d6c40673138c760ee63))
* **makato-orchestrate:** reap-and-resume killed PO-agent at phase:pr ([#732](https://github.com/macatocz/makato/issues/732)) ([#802](https://github.com/macatocz/makato/issues/802)) ([f9d2c9e](https://github.com/macatocz/makato/commit/f9d2c9ea966854fb9f40d96a9fbeee1c62ca177f))
* **repo:** tighten check-self-contained.sh matcher; flip CI gate to blocking ([#730](https://github.com/macatocz/makato/issues/730)) ([#800](https://github.com/macatocz/makato/issues/800)) ([72b3a02](https://github.com/macatocz/makato/commit/72b3a02c4dc0658ea14945dd1cd206a177ce4903))

## [0.147.0](https://github.com/macatocz/makato/compare/v0.146.1...v0.147.0) (2026-08-09)


### ✨ Features

* **makato-observability:** resolve 6 feature-audit gaps ([#707](https://github.com/macatocz/makato/issues/707)) ([#796](https://github.com/macatocz/makato/issues/796)) ([040bf63](https://github.com/macatocz/makato/commit/040bf633bc877f10f0978af2180105c6bfb7ab24))

## [0.146.1](https://github.com/macatocz/makato/compare/v0.146.0...v0.146.1) (2026-08-09)


### 🐛 Bug Fixes

* **makato-core:** resolve 7 feature-audit gaps (contracts, labels, hook docs) ([70ac0eb](https://github.com/macatocz/makato/commit/70ac0eb0b12fe964a560a07c0c2cfcd37f41c4f9))

## [0.146.0](https://github.com/macatocz/makato/compare/v0.145.3...v0.146.0) (2026-08-09)


### ✨ Features

* **makato-database:** resolve 3 feature-audit gaps ([#711](https://github.com/macatocz/makato/issues/711)) ([#793](https://github.com/macatocz/makato/issues/793)) ([07ec952](https://github.com/macatocz/makato/commit/07ec9527d3a395f0b712fe6226290ccaa74b85fa))

## [0.145.3](https://github.com/macatocz/makato/compare/v0.145.2...v0.145.3) (2026-08-09)


### 🐛 Bug Fixes

* **makato-plan:** resolve 7 feature-audit gaps ([#703](https://github.com/macatocz/makato/issues/703)) ([#792](https://github.com/macatocz/makato/issues/792)) ([ba24117](https://github.com/macatocz/makato/commit/ba24117effb037312d41d7c31596786ec69d4702))

## [0.145.2](https://github.com/macatocz/makato/compare/v0.145.1...v0.145.2) (2026-08-09)


### 🐛 Bug Fixes

* **makato-orchestrate:** HALT-015 for orphaned-card reconcilers with runtime context ([#786](https://github.com/macatocz/makato/issues/786)) ([#790](https://github.com/macatocz/makato/issues/790)) ([a24b87e](https://github.com/macatocz/makato/commit/a24b87e92d43835263154350e914339d351eecf0))

## [0.145.1](https://github.com/macatocz/makato/compare/v0.145.0...v0.145.1) (2026-08-09)


### 🐛 Bug Fixes

* **makato-build:** resolve 16 feature-audit gaps (documentation accuracy) ([#788](https://github.com/macatocz/makato/issues/788)) ([dbe6072](https://github.com/macatocz/makato/commit/dbe6072a20dd00bf41f29f99d5979386debcc7a9))

## [0.145.0](https://github.com/macatocz/makato/compare/v0.144.4...v0.145.0) (2026-08-09)


### ✨ Features

* **makato-change:** add build.jsonl audit emission to analyze and execute skills ([ed31482](https://github.com/macatocz/makato/commit/ed314820322a60973508bf65e9a438da331709e3))
* **makato-change:** resolve 4 feature-audit gaps (analyze/execute JSONL, loop.sh MAKATO_ORCHESTRATE_SHARED, resolve-review note) ([79adad3](https://github.com/macatocz/makato/commit/79adad337995283708871e0aa12435ed71e04a77))
* **makato-change:** resolve 4 feature-audit gaps (analyze/execute JSONL, loop.sh MAKATO_ORCHESTRATE_SHARED, resolve-review note) ([79adad3](https://github.com/macatocz/makato/commit/79adad337995283708871e0aa12435ed71e04a77))


### 🐛 Bug Fixes

* **makato-orchestrate:** export MAKATO_ORCHESTRATE_SHARED in loop.sh dispatch ([14ad054](https://github.com/macatocz/makato/commit/14ad054e0abde0700eb1287f9370ca5e01d8d262))

## [0.144.4](https://github.com/macatocz/makato/compare/v0.144.3...v0.144.4) (2026-08-09)


### 🐛 Bug Fixes

* **makato-orchestrate:** resolve 4 feature-audit gaps (4 partial) ([#706](https://github.com/macatocz/makato/issues/706)) ([#784](https://github.com/macatocz/makato/issues/784)) ([12407ae](https://github.com/macatocz/makato/commit/12407ae3647d3f57b66ef133ded95bc0f414f19f))

## [0.144.3](https://github.com/macatocz/makato/compare/v0.144.2...v0.144.3) (2026-08-09)


### 🐛 Bug Fixes

* **makato-orchestrate:** loop-supervisor false-positive restart on long dispatch ([#779](https://github.com/macatocz/makato/issues/779)) ([#781](https://github.com/macatocz/makato/issues/781)) ([b42d429](https://github.com/macatocz/makato/commit/b42d4297a584b09ba5d2242f63ac37e865295de2))

## [0.144.2](https://github.com/macatocz/makato/compare/v0.144.1...v0.144.2) (2026-08-08)


### 🐛 Bug Fixes

* **makato-fastapi:** resolve 5 feature-audit gaps ([#708](https://github.com/macatocz/makato/issues/708)) ([#778](https://github.com/macatocz/makato/issues/778)) ([abbcdd2](https://github.com/macatocz/makato/commit/abbcdd2f2b3de10596fbcd22baa4d00e2e911b90))

## [0.144.1](https://github.com/macatocz/makato/compare/v0.144.0...v0.144.1) (2026-08-08)


### 🐛 Bug Fixes

* **makato-langgraph:** qualify JSONL audit constraint to exempt reference skills ([baa401d](https://github.com/macatocz/makato/commit/baa401d3d208d904879447f96a2a00d7570e52ba))
* **makato-langgraph:** replace mislabeled static fan-out with correct Send-based map-reduce example ([a25cdc6](https://github.com/macatocz/makato/commit/a25cdc6bcc218daeec5a5993c10fda0c11e528c1))
* **makato-langgraph:** resolve 2 feature-audit gaps (JSONL constraint + Send map-reduce example) ([0cd91f4](https://github.com/macatocz/makato/commit/0cd91f4fe0bb68578e45ebfb146db7c53a11af42))

## [0.144.0](https://github.com/macatocz/makato/compare/v0.143.3...v0.144.0) (2026-08-08)


### ✨ Features

* **makato-temporal:** add JSONL audit-logging blocks to temporal-development skill ([#710](https://github.com/macatocz/makato/issues/710)) ([#773](https://github.com/macatocz/makato/issues/773)) ([679a64b](https://github.com/macatocz/makato/commit/679a64b64e67bae79f1fc66f7759499465e3aa3f))

## [0.143.3](https://github.com/macatocz/makato/compare/v0.143.2...v0.143.3) (2026-08-08)


### 🐛 Bug Fixes

* **makato-ux:** resolve 4 feature-audit gaps (1 broken, 3 partial) [#712](https://github.com/macatocz/makato/issues/712) ([#771](https://github.com/macatocz/makato/issues/771)) ([70ce204](https://github.com/macatocz/makato/commit/70ce20407dd557ee2a5c19e16413ccc2788f5f65))

## [0.143.2](https://github.com/macatocz/makato/compare/v0.143.1...v0.143.2) (2026-08-08)


### 🐛 Bug Fixes

* **makato-orchestrate:** skip CLOSED issues in promote-ready candidate selection ([#747](https://github.com/macatocz/makato/issues/747)) ([#768](https://github.com/macatocz/makato/issues/768)) ([7cb252c](https://github.com/macatocz/makato/commit/7cb252cc87999cc4928e6a2eef5d11b0d269feec))

## [0.143.1](https://github.com/macatocz/makato/compare/v0.143.0...v0.143.1) (2026-08-08)


### 🐛 Bug Fixes

* **makato-orchestrate:** plan-tier:change overrides co-present type:* in loop routing ([#760](https://github.com/macatocz/makato/issues/760)) ([#766](https://github.com/macatocz/makato/issues/766)) ([6721652](https://github.com/macatocz/makato/commit/67216528edcc0465038a07db96e3f28dfeac6061))

## [0.143.0](https://github.com/macatocz/makato/compare/v0.142.4...v0.143.0) (2026-08-07)


### ✨ Features

* **makato-orchestrate:** specify + verify change-memory recall contract ([#720](https://github.com/macatocz/makato/issues/720)) ([e8039cb](https://github.com/macatocz/makato/commit/e8039cb649e5cf56af0d537f24d322b22a6681a4))

## [0.142.4](https://github.com/macatocz/makato/compare/v0.142.3...v0.142.4) (2026-08-07)


### 🐛 Bug Fixes

* **loop:** post-halt-comment derives repo when arg empty ([#450](https://github.com/macatocz/makato/issues/450)) ([#757](https://github.com/macatocz/makato/issues/757)) ([47efcdb](https://github.com/macatocz/makato/commit/47efcdb62e68fbbe2ca5b073d31171c754e776af))

## [0.142.3](https://github.com/macatocz/makato/compare/v0.142.2...v0.142.3) (2026-08-07)


### 🤖 CI

* **makato-orchestrate:** wire loop-change-dispatch integration tests into validate.yml ([#717](https://github.com/macatocz/makato/issues/717)) ([685ffdd](https://github.com/macatocz/makato/commit/685ffdd90877abe98a2c91a1d1f6ffdeb321cf67))

## [0.142.2](https://github.com/macatocz/makato/compare/v0.142.1...v0.142.2) (2026-08-07)


### 🐛 Bug Fixes

* **makato-contribute:** correct plugin-creator Step 5 preview and default author ([bb2e950](https://github.com/macatocz/makato/commit/bb2e950e529485ac270c1882b4782bd3b7848f86))
* **makato-contribute:** enforce skill-creator Step 15 persist-plan via checklist ([e98cbf9](https://github.com/macatocz/makato/commit/e98cbf952bcdea58f143003b9aef2c9a5c479194))
* **makato-contribute:** remove stale skills-array instruction from sync-from-upstream Step 8 ([f89fe02](https://github.com/macatocz/makato/commit/f89fe02a9df3f3cd767c711798da02f8d983b239))
* **makato-contribute:** replace contains with task_contains in contribute-plugin-creation bundle ([ae98c74](https://github.com/macatocz/makato/commit/ae98c74375d755f1e02d40755a2152e2458282e4))
* **makato-contribute:** resolve 4 feature-audit gaps ([#715](https://github.com/macatocz/makato/issues/715)) ([32ad9cd](https://github.com/macatocz/makato/commit/32ad9cd040525661bf1a6838d80a9813068a6e09))
* **makato-contribute:** resolve 4 feature-audit gaps ([#715](https://github.com/macatocz/makato/issues/715)) ([32ad9cd](https://github.com/macatocz/makato/commit/32ad9cd040525661bf1a6838d80a9813068a6e09))

## [0.142.1](https://github.com/macatocz/makato/compare/v0.142.0...v0.142.1) (2026-08-07)


### 🐛 Bug Fixes

* **makato-sagibeast:** resolve 4 feature-audit gaps ([#714](https://github.com/macatocz/makato/issues/714)) ([bc23bad](https://github.com/macatocz/makato/commit/bc23badab92f005fe9d77173e966678285117205))

## [0.142.0](https://github.com/macatocz/makato/compare/v0.141.5...v0.142.0) (2026-08-07)


### ✨ Features

* **makato-orchestrate:** add progress-comment notes for setup phases before build-refine ([#742](https://github.com/macatocz/makato/issues/742)) ([#746](https://github.com/macatocz/makato/issues/746)) ([74ca242](https://github.com/macatocz/makato/commit/74ca24251a1ea794e00c442800a26d8fcaf0049e))


### 🐛 Bug Fixes

* **config:** add github_project.id (GraphQL node ID) for board writes ([#741](https://github.com/macatocz/makato/issues/741)) ([c0b6a5b](https://github.com/macatocz/makato/commit/c0b6a5bfa35b59ae6e82b8d95085bc5adb6b8b59))
* **loop:** resolve post-halt-comment.sh next to script for consumer repos ([#744](https://github.com/macatocz/makato/issues/744)) ([#745](https://github.com/macatocz/makato/issues/745)) ([8dbc452](https://github.com/macatocz/makato/commit/8dbc452144fb1ac501cde123d03091613928d16e))
* **loop:** skip reconcile for CLOSED issues (terminal-state guard) ([#740](https://github.com/macatocz/makato/issues/740)) ([7bdf998](https://github.com/macatocz/makato/commit/7bdf99856bb0dba6d3925154a4937f6992c5032e))
* **makato-doc:** clarify JSONL audit constraint for doc-utility skills ([5dc7daf](https://github.com/macatocz/makato/commit/5dc7daf420d13b629ffd7c5c601371b7f15bf581))
* **makato-doc:** correct context7 allowed-tools prefix to mcp__plugin_general_context7__ ([6d62e9c](https://github.com/macatocz/makato/commit/6d62e9cadd16f7ac405529b7c37cdc7286f3f5c6))
* **makato-doc:** remove stale ContextScout/ExternalScout from context7 README ([f9bc31a](https://github.com/macatocz/makato/commit/f9bc31a9c442bc476c730c9b8a62530c575bad7c))
* **makato-doc:** resolve 3 feature-audit gaps ([#713](https://github.com/macatocz/makato/issues/713)) ([0d0a283](https://github.com/macatocz/makato/commit/0d0a283a22eceb076e0eca8b58ef5cd1835a7bc9))
* **makato-doc:** resolve 3 feature-audit gaps ([#713](https://github.com/macatocz/makato/issues/713)) ([0d0a283](https://github.com/macatocz/makato/commit/0d0a283a22eceb076e0eca8b58ef5cd1835a7bc9))
* **makato-doc:** update plugin README version table (context7 1.2.0, markdown 1.4.0) ([97266c4](https://github.com/macatocz/makato/commit/97266c42cd3c5200629bf537055856201fc8e0ee))
* **scripts:** make regenerate-agents.sh a no-op — stop writing to root AGENTS.md / CLAUDE.md ([50c0c17](https://github.com/macatocz/makato/commit/50c0c17d94f63eba9041003455935d5a1b3b8c86))
* **scripts:** skip root AGENTS.md generation, write routing content directly to CLAUDE.md ([82f67b0](https://github.com/macatocz/makato/commit/82f67b0494f4f6e5adabc1eb1b83225715c705e3))

## [0.141.5](https://github.com/macatocz/makato/compare/v0.141.4...v0.141.5) (2026-08-06)


### 🐛 Bug Fixes

* **makato-orchestrate:** resolve board item-id via cheap single-issue GraphQL, not whole-board item-list ([#736](https://github.com/macatocz/makato/issues/736)) ([3291465](https://github.com/macatocz/makato/commit/3291465938be6e78aa9b7fb4ae32e5967ca0e599))

## [0.141.4](https://github.com/macatocz/makato/compare/v0.141.3...v0.141.4) (2026-08-06)


### 🐛 Bug Fixes

* **makato-orchestrate:** update stale status:ready-for-dev reference in auto-seed-block comment ([#733](https://github.com/macatocz/makato/issues/733)) ([409f9a7](https://github.com/macatocz/makato/commit/409f9a78f3b616e1d64f73cae6ff3039ee927f7e))

## [0.141.3](https://github.com/macatocz/makato/compare/v0.141.2...v0.141.3) (2026-08-06)


### 🐛 Bug Fixes

* **makato-orchestrate:** don't false-HALT-012 when review is not required ([#726](https://github.com/macatocz/makato/issues/726)) ([6550844](https://github.com/macatocz/makato/commit/6550844cc9fec952c0171142cb7d367ea6552d06))

## [0.141.2](https://github.com/macatocz/makato/compare/v0.141.1...v0.141.2) (2026-08-05)


### 🐛 Bug Fixes

* **makato-orchestrate:** reconcilers use --project-id in gh item-edit ([#697](https://github.com/macatocz/makato/issues/697)) ([#700](https://github.com/macatocz/makato/issues/700)) ([bf8eebe](https://github.com/macatocz/makato/commit/bf8eebee1d5189ca04e1a9bf97f4ef95e2411012))
* **makato-orchestrate:** reset board card to Ready after api_error dispatch (687-makato-orchestrate--bug--api-error-dispa) ([#698](https://github.com/macatocz/makato/issues/698)) ([131dd89](https://github.com/macatocz/makato/commit/131dd89f7c06096c9380bc7e8903e929db0ece93))

## [0.141.1](https://github.com/macatocz/makato/compare/v0.141.0...v0.141.1) (2026-08-05)


### 🐛 Bug Fixes

* **makato-orchestrate:** GraphQL rate-limit circuit-breaker in loop ([#683](https://github.com/macatocz/makato/issues/683)) ([#695](https://github.com/macatocz/makato/issues/695)) ([aeeed03](https://github.com/macatocz/makato/commit/aeeed03a1ec1a5bac19a8b6cd778e02b726a868d))

## [0.141.0](https://github.com/macatocz/makato/compare/v0.140.0...v0.141.0) (2026-08-05)


### ✨ Features

* **makato-orchestrate:** post structured comment on needs-human-review ([#689](https://github.com/macatocz/makato/issues/689)) ([#692](https://github.com/macatocz/makato/issues/692)) ([0d4788c](https://github.com/macatocz/makato/commit/0d4788c99f2df619eeed93056edf5f3bbb0505a1))

## [0.140.0](https://github.com/macatocz/makato/compare/v0.139.3...v0.140.0) (2026-08-05)


### ✨ Features

* **makato-orchestrate:** board Status=Ready as sole dispatch condition (remove status:ready-for-dev) ([0b68c9c](https://github.com/macatocz/makato/commit/0b68c9cefd5e58e2e314927c8debbcbccd9bf20d))

## [0.139.3](https://github.com/macatocz/makato/compare/v0.139.2...v0.139.3) (2026-08-04)


### 🐛 Bug Fixes

* **makato-orchestrate:** board_applied:false in emit-needs-planning-signal ([#682](https://github.com/macatocz/makato/issues/682)) ([#685](https://github.com/macatocz/makato/issues/685)) ([61860ca](https://github.com/macatocz/makato/commit/61860ca85319b7c9eb7f4e3d64617c633b5a43fb))

## [0.139.2](https://github.com/macatocz/makato/compare/v0.139.1...v0.139.2) (2026-08-04)


### 🐛 Bug Fixes

* **makato-build:** guard against string description in check_correctness ([24cb760](https://github.com/macatocz/makato/commit/24cb760c6696fce927cb1ee263d72a0c56f75e11))

## [0.139.1](https://github.com/macatocz/makato/compare/v0.139.0...v0.139.1) (2026-08-04)


### 🐛 Bug Fixes

* **makato-plan:** Step 3 FIELD_NOT_FOUND check uses broken fields.nodes traversal ([#648](https://github.com/macatocz/makato/issues/648)) ([#680](https://github.com/macatocz/makato/issues/680)) ([0ea79b4](https://github.com/macatocz/makato/commit/0ea79b4ad4a00d9f8f3cadf674e9fbe009e9c9a9))

## [0.139.0](https://github.com/macatocz/makato/compare/v0.138.0...v0.139.0) (2026-08-04)


### ✨ Features

* **makato-orchestrate:** thread issue-level trace ID across sessions ([#595](https://github.com/macatocz/makato/issues/595)) ([#678](https://github.com/macatocz/makato/issues/678)) ([a79c01b](https://github.com/macatocz/makato/commit/a79c01b9f2853ed1a5526c07c56ac4086e636cde))

## [0.138.0](https://github.com/macatocz/makato/compare/v0.137.0...v0.138.0) (2026-08-04)


### ✨ Features

* **makato-plan:** value-bearing blocked-by:N labels with GHA auto-cleanup ([#608](https://github.com/macatocz/makato/issues/608)) ([#676](https://github.com/macatocz/makato/issues/676)) ([a7ba76e](https://github.com/macatocz/makato/commit/a7ba76eff58e38bd4f85874fcb99b291f14897fd))

## [0.137.0](https://github.com/macatocz/makato/compare/v0.136.0...v0.137.0) (2026-08-04)


### ✨ Features

* **makato-contribute:** add harness-audit SKILL.md ([fa85260](https://github.com/macatocz/makato/commit/fa85260cd74a71d050e18c11995e038883468ec5))
* **makato-contribute:** add harness-audit.sh classifier + smoke tests ([4e85f40](https://github.com/macatocz/makato/commit/4e85f40b7ddd42cf3a70d891a193d77d71913581))
* **makato-contribute:** harness-audit skill — AGENTS.md bloat + permissionMode audit ([#590](https://github.com/macatocz/makato/issues/590)) ([1f34aac](https://github.com/macatocz/makato/commit/1f34aac3613468c9d620f4b05778ad78d703a348))
* **makato-contribute:** harness-audit skill — AGENTS.md bloat + permissionMode audit ([#590](https://github.com/macatocz/makato/issues/590)) ([1f34aac](https://github.com/macatocz/makato/commit/1f34aac3613468c9d620f4b05778ad78d703a348))

## [0.136.0](https://github.com/macatocz/makato/compare/v0.135.0...v0.136.0) (2026-08-04)


### ✨ Features

* **makato-build:** add runtime-qa agent definition with R1 envelope contract ([17eaf9e](https://github.com/macatocz/makato/commit/17eaf9e397aafdea46748c97b2dafbeb425fc5a1))
* **makato-build:** register RUNTIME_QA_BLOCKED halt code in halt-codes.md ([a5c93d1](https://github.com/macatocz/makato/commit/a5c93d1ef0aedf6a01cf6fd83d767faefe2bc489))
* **makato-build:** runtime-qa agent — exercise built app via Playwright MCP ([#582](https://github.com/macatocz/makato/issues/582)) ([0f36b97](https://github.com/macatocz/makato/commit/0f36b97e1f6293171af876683d46d55d46ff9c98))
* **makato-build:** runtime-qa agent — exercise built app via Playwright MCP ([#582](https://github.com/macatocz/makato/issues/582)) ([0f36b97](https://github.com/macatocz/makato/commit/0f36b97e1f6293171af876683d46d55d46ff9c98))
* **makato-orchestrate:** add build-runtime-qa Step 6 [#1](https://github.com/macatocz/makato/issues/1)b dispatch to po-agent and progress-comment table ([7b1f7ed](https://github.com/macatocz/makato/commit/7b1f7ed91c9ca693a5a19c65702d89c55d5e64eb))

## [0.135.0](https://github.com/macatocz/makato/compare/v0.134.0...v0.135.0) (2026-08-04)


### ✨ Features

* **makato-orchestrate:** cloud-hosted loop runner — GHA cron running loop.sh run --once ([#600](https://github.com/macatocz/makato/issues/600)) ([87db6a0](https://github.com/macatocz/makato/commit/87db6a0ea6561a5d314172e55af643ee0bca8c9a))

## [0.134.0](https://github.com/macatocz/makato/compare/v0.133.0...v0.134.0) (2026-08-04)


### ✨ Features

* **makato-build:** add stale-artifact sensor routes to finding-routes.json ([8ff2b27](https://github.com/macatocz/makato/commit/8ff2b27102def2ae121f358be1e405a6de781ea5))
* **makato-build:** add stale-artifact-check pre-commit hook (console.log/debugger/temp-file detection) ([521c114](https://github.com/macatocz/makato/commit/521c114bca1102399337bcc7963741f350f617a9))
* **makato-build:** DoD item 8 and build-verify Gate 8 extended to cover debug/stale artifacts ([f71054e](https://github.com/macatocz/makato/commit/f71054ec8dfc4c58312625965b120101cc5f7ba5))
* **makato-build:** parse-sarif.py maps stale-artifact-check hook label to tool stale-artifact ([7fc0282](https://github.com/macatocz/makato/commit/7fc028247f3697862cbb6bc17be4c43f443a22da))
* **makato-build:** stale-artifact sensor lane — flag debug leftovers in diff ([#596](https://github.com/macatocz/makato/issues/596)) ([bac73fd](https://github.com/macatocz/makato/commit/bac73fd9ed16eabd49ed1dd4a7902726da2cde17))
* **makato-build:** stale-artifact sensor lane — flag debug leftovers in diff ([#596](https://github.com/macatocz/makato/issues/596)) ([bac73fd](https://github.com/macatocz/makato/commit/bac73fd9ed16eabd49ed1dd4a7902726da2cde17))

## [0.133.0](https://github.com/macatocz/makato/compare/v0.132.0...v0.133.0) (2026-08-04)


### ✨ Features

* **makato-orchestrate:** HALT-by-layer diagnostic report ([#593](https://github.com/macatocz/makato/issues/593)) ([#666](https://github.com/macatocz/makato/issues/666)) ([635791b](https://github.com/macatocz/makato/commit/635791b72cf4dd64a4a4602720a00222881aed43))

## [0.132.0](https://github.com/macatocz/makato/compare/v0.131.0...v0.132.0) (2026-08-03)


### ✨ Features

* **repo-wide:** standardize ## Hard Constraints first section in every plugin AGENTS.md + lint gate ([#589](https://github.com/macatocz/makato/issues/589)) ([#664](https://github.com/macatocz/makato/issues/664)) ([addd777](https://github.com/macatocz/makato/commit/addd777256550b362d03c171d74ca33d900e7f91))

## [0.131.0](https://github.com/macatocz/makato/compare/v0.130.0...v0.131.0) (2026-08-03)


### ✨ Features

* **makato-build:** canary test-framework pre-flight in build-start (Step 2.75) ([#662](https://github.com/macatocz/makato/issues/662)) ([0ce6cea](https://github.com/macatocz/makato/commit/0ce6cea8047bcfaa0cc1bdc7c91a0265ca85869e))

## [0.130.0](https://github.com/macatocz/makato/compare/v0.129.0...v0.130.0) (2026-08-03)


### ✨ Features

* **makato-build:** add ## Runtime verification section to plan.md and execute as build-verify gate ([#583](https://github.com/macatocz/makato/issues/583)) ([640bea0](https://github.com/macatocz/makato/commit/640bea0e88c489b6ec346db6d3b58d2e20e8bee1))
* **makato-build:** add optional ## Runtime verification section to plan-template and plan-schema ([c5e1b2e](https://github.com/macatocz/makato/commit/c5e1b2eadf76c0c11de2e99aff054df848a15195))
* **makato-build:** build-refine Step 8 elicits ## Runtime verification for service/API stories ([2a52d7c](https://github.com/macatocz/makato/commit/2a52d7cc68315bf618755c6d6b0b7aaf35ea8719))
* **makato-build:** build-verify Gate 6 reads ## Runtime verification from plan.md; plan command takes precedence over gate-scout discovery ([00c3af7](https://github.com/macatocz/makato/commit/00c3af7b7447ae4ec9651214fd1578e4b1415764))


### 🐛 Bug Fixes

* **makato-orchestrate:** scope loop pre-flight gh auth status to target host ([#656](https://github.com/macatocz/makato/issues/656)) ([#659](https://github.com/macatocz/makato/issues/659)) ([b837376](https://github.com/macatocz/makato/commit/b8373761c89d4bb3178646777c06841fa534f822))

## [0.129.0](https://github.com/macatocz/makato/compare/v0.128.0...v0.129.0) (2026-08-03)


### ✨ Features

* **makato-build:** make integration/E2E gate mandatory for &gt;=3-layer changes ([#581](https://github.com/macatocz/makato/issues/581)) ([#657](https://github.com/macatocz/makato/issues/657)) ([a976a3f](https://github.com/macatocz/makato/commit/a976a3fe26c1390eaa8099f6651fbf2e5208a437))
* **makato-orchestrate:** bounded parallel issue fleet via N independent loop.sh workers ([#546](https://github.com/macatocz/makato/issues/546)) ([213081c](https://github.com/macatocz/makato/commit/213081c535d42f31766ea5bc87e3ca17e41bf3d9))


### 🐛 Bug Fixes

* **makato-orchestrate:** gate label stamp on board edit success in reconcile passes ([#653](https://github.com/macatocz/makato/issues/653)) ([f5bc7d5](https://github.com/macatocz/makato/commit/f5bc7d588e9dc345c5784dd1388d5550d10ac8b1))

## [Unreleased]

### Added

* **makato-orchestrate:** `loop-fleet.sh` — bounded parallel issue fleet: run N independent `loop.sh` workers concurrently with per-worker isolated state dir/pidfile, board CAS fail-closed contract, same-folder co-schedule guard, live per-worker dashboard, and N=1 byte-for-byte serial compat ([#546](https://github.com/macatocz/makato/issues/546))

## [0.128.0](https://github.com/macatocz/makato/compare/v0.127.1...v0.128.0) (2026-08-03)


### ✨ Features

* **makato-build:** review-feedback promotion — codify recurring MUST-FIX as pre-commit checks ([#594](https://github.com/macatocz/makato/issues/594)) ([#649](https://github.com/macatocz/makato/issues/649)) ([8126a73](https://github.com/macatocz/makato/commit/8126a73d830b6cf30b71a1eac336eb51b729e88f))

## [0.127.1](https://github.com/macatocz/makato/compare/v0.127.0...v0.127.1) (2026-08-03)


### 🐛 Bug Fixes

* **makato-plan:** replace broken project-view fields assertion with field-list probe ([#606](https://github.com/macatocz/makato/issues/606)) ([#647](https://github.com/macatocz/makato/issues/647)) ([fe26c2e](https://github.com/macatocz/makato/commit/fe26c2ec28eb8a75e5829abbcf3c37fc80c40556))

## [0.127.0](https://github.com/macatocz/makato/compare/v0.126.0...v0.127.0) (2026-08-03)


### ✨ Features

* **repo-wide:** add .devcontainer spec for uv + Python 3.14 ([11a972e](https://github.com/macatocz/makato/commit/11a972efe124de155374fe6aece55b59cab037f9))
* **repo-wide:** Add .python-version pin and .devcontainer for cold-start reproducibility ([b649743](https://github.com/macatocz/makato/commit/b649743f6d1cd34a3ded924806e026e8fbbfb2c1))
* **repo-wide:** Add .python-version pin and .devcontainer for cold-start reproducibility ([b649743](https://github.com/macatocz/makato/commit/b649743f6d1cd34a3ded924806e026e8fbbfb2c1))
* **repo-wide:** add .python-version pin to 3.14 ([d501a16](https://github.com/macatocz/makato/commit/d501a16c7ec55c3e66119f055e74d42a79b26274))
* **repo-wide:** bump requires-python to &gt;=3.14 in pyproject.toml ([2430700](https://github.com/macatocz/makato/commit/24307000109ff19caea49270480234dc0c968093)), closes [#588](https://github.com/macatocz/makato/issues/588)

## [0.126.0](https://github.com/macatocz/makato/compare/v0.125.0...v0.126.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** capture design-time decisions into workflow-state ([#603](https://github.com/macatocz/makato/issues/603)) ([#645](https://github.com/macatocz/makato/issues/645)) ([a0bb004](https://github.com/macatocz/makato/commit/a0bb0045145436deec330bad377bdec041290683))

## [0.125.0](https://github.com/macatocz/makato/compare/v0.124.0...v0.125.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** human session clock-in/clock-out ritual ([#602](https://github.com/macatocz/makato/issues/602)) ([#643](https://github.com/macatocz/makato/issues/643)) ([fc3eb00](https://github.com/macatocz/makato/commit/fc3eb002293bc17be030a69ae0c69a2849f21986))

## [0.124.0](https://github.com/macatocz/makato/compare/v0.123.0...v0.124.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** tool-dependency pre-flight in loop.sh ([#587](https://github.com/macatocz/makato/issues/587)) ([#641](https://github.com/macatocz/makato/issues/641)) ([043975f](https://github.com/macatocz/makato/commit/043975f94ae1ab5f47fad95f3ab5bfed4d943b89))

## [0.123.0](https://github.com/macatocz/makato/compare/v0.122.0...v0.123.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** PROGRESS.md roadmap via generate-progress.sh ([#601](https://github.com/macatocz/makato/issues/601)) ([#639](https://github.com/macatocz/makato/issues/639)) ([1ace50f](https://github.com/macatocz/makato/commit/1ace50f84ca865b6353b6ec7973eb8be6c05f9b0))

## [0.122.0](https://github.com/macatocz/makato/compare/v0.121.0...v0.122.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** webhook instant dispatch on status:ready-for-dev ([#599](https://github.com/macatocz/makato/issues/599)) ([#637](https://github.com/macatocz/makato/issues/637)) ([9bc1b37](https://github.com/macatocz/makato/commit/9bc1b374eec0b136a570e516879922111ac71b07))

## [0.121.0](https://github.com/macatocz/makato/compare/v0.120.1...v0.121.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** quality-doc skill — per-domain quality scorecard ([#598](https://github.com/macatocz/makato/issues/598)) ([#635](https://github.com/macatocz/makato/issues/635)) ([0009f17](https://github.com/macatocz/makato/commit/0009f1752cc83a25dfc9e374960cddbd09018a48))

## [0.120.1](https://github.com/macatocz/makato/compare/v0.120.0...v0.120.1) (2026-08-03)


### 🐛 Bug Fixes

* **makato-orchestrate:** route reconciler board reads through rate-guarded wrapper ([#630](https://github.com/macatocz/makato/issues/630)) ([0e3f29d](https://github.com/macatocz/makato/commit/0e3f29d22f4dfc70b7ee80064c975c52902879af))

## [0.120.0](https://github.com/macatocz/makato/compare/v0.119.0...v0.120.0) (2026-08-03)


### ✨ Features

* **makato-build:** add context/makato/standards/ so makato dogfoods inject-context ([#591](https://github.com/macatocz/makato/issues/591)) ([1f5e129](https://github.com/macatocz/makato/commit/1f5e1295b93681fedee5b3c3d3e36993697bdec4))
* **makato-build:** add context/makato/standards/ so makato dogfoods inject-context ([#591](https://github.com/macatocz/makato/issues/591)) ([1f5e129](https://github.com/macatocz/makato/commit/1f5e1295b93681fedee5b3c3d3e36993697bdec4))

## [0.119.0](https://github.com/macatocz/makato/compare/v0.118.1...v0.119.0) (2026-08-03)


### ✨ Features

* **makato-orchestrate:** Track VCR in loop-status.json + optional queue-advancement gate ([#585](https://github.com/macatocz/makato/issues/585)) ([4a1dd2f](https://github.com/macatocz/makato/commit/4a1dd2f98845f55c80fb159818e71bb9fc8a70e7))


### 🐛 Bug Fixes

* **makato-orchestrate:** PO-agent self-recovery after Stream idle timeout ([#616](https://github.com/macatocz/makato/issues/616)) ([#629](https://github.com/macatocz/makato/issues/629)) ([d032928](https://github.com/macatocz/makato/commit/d03292814239b93b6a1110045f1b1de045cce16a))

## [0.118.1](https://github.com/macatocz/makato/compare/v0.118.0...v0.118.1) (2026-08-02)


### 🐛 Bug Fixes

* **makato-orchestrate:** auto-seed skips issues already planned by to-issues ([#626](https://github.com/macatocz/makato/issues/626)) ([d95c050](https://github.com/macatocz/makato/commit/d95c050db428c17aae11cab7bca137cfc200ae87))

## [0.118.0](https://github.com/macatocz/makato/compare/v0.117.0...v0.118.0) (2026-08-02)


### ✨ Features

* **makato-build:** Gate 6 advisory runtime health-check in build-verify ([#580](https://github.com/macatocz/makato/issues/580)) ([9e695de](https://github.com/macatocz/makato/commit/9e695ded84d441289130d858ad661de40c7cc7d8))

## [0.117.0](https://github.com/macatocz/makato/compare/v0.116.0...v0.117.0) (2026-08-02)


### ✨ Features

* **makato-core:** add init onboarding wizard skill ([#566](https://github.com/macatocz/makato/issues/566)) ([1738f83](https://github.com/macatocz/makato/commit/1738f83e17b08c5b0f77272486535f7e7ba25fec))
* **makato-core:** guided onboarding wizard — makato-core:init skill ([#566](https://github.com/macatocz/makato/issues/566)) ([7ea351f](https://github.com/macatocz/makato/commit/7ea351f793f2963a8ed89d0de51542b062ccff24))
* **makato-core:** guided onboarding wizard — makato-core:init skill ([#566](https://github.com/macatocz/makato/issues/566)) ([7ea351f](https://github.com/macatocz/makato/commit/7ea351f793f2963a8ed89d0de51542b062ccff24))


### 🐛 Bug Fixes

* **makato-core:** register init skill in makato-flow.inventory.json ([#566](https://github.com/macatocz/makato/issues/566)) ([c15508f](https://github.com/macatocz/makato/commit/c15508faa862288ce62e96a874ef6451e30a11ab))

## [0.116.0](https://github.com/macatocz/makato/compare/v0.115.0...v0.116.0) (2026-08-02)


### ✨ Features

* **makato-build:** add build-verify-spec skill ([#568](https://github.com/macatocz/makato/issues/568)) ([#619](https://github.com/macatocz/makato/issues/619)) ([b4db21a](https://github.com/macatocz/makato/commit/b4db21a133ec89a802f93c97183243844cd01ef0))

## [0.115.0](https://github.com/macatocz/makato/compare/v0.114.0...v0.115.0) (2026-08-02)


### ✨ Features

* **makato-plan:** add manage-stores skill with register/list/remove sub-commands ([d0a4838](https://github.com/macatocz/makato/commit/d0a4838cccc357ba6d45a896b1de7427bf81fcc4))
* **makato-plan:** add target_repo to created-issues schema + cross-repo smoke test ([d92f2d0](https://github.com/macatocz/makato/commit/d92f2d065caacaf036a337931494ed4b170a52cb))
* **makato-plan:** cross-repo spec stores -- --repo/--store flags + manage-stores ([#565](https://github.com/macatocz/makato/issues/565)) ([67ab3e3](https://github.com/macatocz/makato/commit/67ab3e3a5adb26c4cae7294bac7abce3240d6d8d))
* **makato-plan:** cross-repo spec stores -- --repo/--store flags + manage-stores ([#565](https://github.com/macatocz/makato/issues/565)) ([67ab3e3](https://github.com/macatocz/makato/commit/67ab3e3a5adb26c4cae7294bac7abce3240d6d8d))
* **makato-plan:** stores[] schema in config.json + manage-stores.sh register/list/remove ([0a0459d](https://github.com/macatocz/makato/commit/0a0459de99d1495dece045db8f9d18f069029ceb))
* **makato-plan:** to-issues --repo and --store flags for cross-repo issue creation ([e5ce3de](https://github.com/macatocz/makato/commit/e5ce3de36d8dabdb87e1eaab6f21b0547b3cd897))

## [0.114.0](https://github.com/macatocz/makato/compare/v0.113.0...v0.114.0) (2026-08-02)


### ✨ Features

* **makato-build:** build-explore read-only thinking-partner skill ([#564](https://github.com/macatocz/makato/issues/564)) ([9ce3ecc](https://github.com/macatocz/makato/commit/9ce3ecc8d5ee48c661b275ea3b7f9e14d20e0361))

## [0.113.0](https://github.com/macatocz/makato/compare/v0.112.0...v0.113.0) (2026-08-02)


### ✨ Features

* **makato-build:** add repair_hint (WHAT/WHY/FIX) field to finding schema ([#611](https://github.com/macatocz/makato/issues/611)) ([78252be](https://github.com/macatocz/makato/commit/78252beadb869851e2520010da26b39aa3d66a60)), closes [#592](https://github.com/macatocz/makato/issues/592)
* **makato-build:** extensible workflow schema system ([#563](https://github.com/macatocz/makato/issues/563)) ([#612](https://github.com/macatocz/makato/issues/612)) ([d60a82e](https://github.com/macatocz/makato/commit/d60a82e749fd460895d802c82cbf6c4f49c40d72))

## [0.112.0](https://github.com/macatocz/makato/compare/v0.111.0...v0.112.0) (2026-08-02)


### ✨ Features

* **makato-orchestrate:** workflow-state prune subcommand — reap stale done state files by age ([#597](https://github.com/macatocz/makato/issues/597)) ([#609](https://github.com/macatocz/makato/issues/609)) ([14e5c23](https://github.com/macatocz/makato/commit/14e5c231b2b1d27d3150e1dd630e4453746a24a4))


### 🐛 Bug Fixes

* **makato-orchestrate:** shared-epic folder guard in reaper (loop 2.2.0) ([#607](https://github.com/macatocz/makato/issues/607)) ([ec93f45](https://github.com/macatocz/makato/commit/ec93f45f292dd57ac3a6ac62f9630a43a5ddb771))

## [0.111.0](https://github.com/macatocz/makato/compare/v0.110.1...v0.111.0) (2026-08-02)


### ✨ Features

* **makato-orchestrate:** add sync-living-specs.sh for spec-delta to docs/specs/ sync ([fb5fadf](https://github.com/macatocz/makato/commit/fb5fadfc3f2c7655fe312caec7279cf70accb8d9))
* **makato-orchestrate:** extend documentation-agent with spec-delta living-spec sync step ([72c351b](https://github.com/macatocz/makato/commit/72c351b93254f3eace28f40c3e6994d89905683d))
* **makato-orchestrate:** living-spec delta sync post-merge ([#567](https://github.com/macatocz/makato/issues/567)) ([a751fb7](https://github.com/macatocz/makato/commit/a751fb70a22864071dec4ace2a7ad3c3a51ee587))
* **makato-orchestrate:** living-spec delta sync post-merge ([#567](https://github.com/macatocz/makato/issues/567)) ([a751fb7](https://github.com/macatocz/makato/commit/a751fb70a22864071dec4ace2a7ad3c3a51ee587))

## [0.110.1](https://github.com/macatocz/makato/compare/v0.110.0...v0.110.1) (2026-08-01)


### 🐛 Bug Fixes

* **makato-sagibeast:** document sagibeast-testbox runner label contract ([#577](https://github.com/macatocz/makato/issues/577)) ([#578](https://github.com/macatocz/makato/issues/578)) ([ffd8898](https://github.com/macatocz/makato/commit/ffd8898219918df1afc6713b532e0b1171446986))

## [0.110.0](https://github.com/macatocz/makato/compare/v0.109.2...v0.110.0) (2026-08-01)


### ✨ Features

* **makato-build:** diff-reviewer gains MODIFIED-requirements verification pass (Step 2.5) ([0dd724a](https://github.com/macatocz/makato/commit/0dd724a58c76d6abe20844d244368f970014dc12))
* **makato-change:** add spec-delta-template.md with ADDED/MODIFIED/REMOVED/RENAMED sections ([88c7582](https://github.com/macatocz/makato/commit/88c75823dced18e5c597c26573628a04d9a351eb))
* **makato-change:** delta spec format for brownfield changes ([#562](https://github.com/macatocz/makato/issues/562)) ([e5eac7b](https://github.com/macatocz/makato/commit/e5eac7b0305f692db32d57baccdd3d0519d18ed6))
* **makato-change:** delta spec format for brownfield changes ([#562](https://github.com/macatocz/makato/issues/562)) ([e5eac7b](https://github.com/macatocz/makato/commit/e5eac7b0305f692db32d57baccdd3d0519d18ed6))
* **makato-change:** execute reads spec-delta.md and passes SPEC_DELTA_CONTEXT to change-implementer ([81f0adf](https://github.com/macatocz/makato/commit/81f0adf0a23c835b25b9a07744f828f6e41ac967))
* **makato-change:** extend design skill to emit spec-delta.md as required output artifact ([b987968](https://github.com/macatocz/makato/commit/b9879681d6cbb655c7958c16f7b50e32cead45e4))

## [0.109.2](https://github.com/macatocz/makato/compare/v0.109.1...v0.109.2) (2026-08-01)


### 🐛 Bug Fixes

* **makato-orchestrate:** auto-seed-block derives slug from footer KEY, not title ([#571](https://github.com/macatocz/makato/issues/571)) ([#573](https://github.com/macatocz/makato/issues/573)) ([1a8ef6b](https://github.com/macatocz/makato/commit/1a8ef6b025d20913e1613e70c95d80e4facfbaa5))

## [0.109.1](https://github.com/macatocz/makato/compare/v0.109.0...v0.109.1) (2026-07-24)


### 🐛 Bug Fixes

* **loop:** demote exit-127 refine log and numberless-folder reap-specs WARN to debug/info ([#569](https://github.com/macatocz/makato/issues/569)) ([6edba9b](https://github.com/macatocz/makato/commit/6edba9b8c0721a6b6dc96628484ccf3efabaea2c)), closes [#558](https://github.com/macatocz/makato/issues/558)

## [0.109.0](https://github.com/macatocz/makato/compare/v0.108.0...v0.109.0) (2026-07-24)


### ✨ Features

* **makato-orchestrate:** proactive GraphQL rate-limit guard + cheaper board poll ([#556](https://github.com/macatocz/makato/issues/556)) ([#560](https://github.com/macatocz/makato/issues/560)) ([09284f2](https://github.com/macatocz/makato/commit/09284f296aab252176878a3bfea5cdbdb9cbfaa1))

## [0.108.0](https://github.com/macatocz/makato/compare/v0.107.0...v0.108.0) (2026-07-24)


### ✨ Features

* **makato-plan:** enforce Fibonacci ≤13 SP cap + split-preferred rule in decompose ([#554](https://github.com/macatocz/makato/issues/554)) ([#557](https://github.com/macatocz/makato/issues/557)) ([a06f014](https://github.com/macatocz/makato/commit/a06f0147db4271c4b59838e77fb3619422a43726))

## [0.107.0](https://github.com/macatocz/makato/compare/v0.106.0...v0.107.0) (2026-07-24)


### ✨ Features

* **makato-orchestrate:** wave-ordered loop dispatch from blocked_by graph ([#548](https://github.com/macatocz/makato/issues/548)) ([8dd41f5](https://github.com/macatocz/makato/commit/8dd41f5ab931eba5909c31941c715cd9ee6236f7))

## [0.106.0](https://github.com/macatocz/makato/compare/v0.105.0...v0.106.0) (2026-07-23)


### ✨ Features

* **loop:** emit Langfuse traces for headless dispatches ([#547](https://github.com/macatocz/makato/issues/547)) ([#549](https://github.com/macatocz/makato/issues/549)) ([3d63188](https://github.com/macatocz/makato/commit/3d6318897a764f370395ecde97326a6ed16da2f9))

## [0.105.0](https://github.com/macatocz/makato/compare/v0.104.2...v0.105.0) (2026-07-23)


### ✨ Features

* **loop:** generic MAKATO_LOOP_PREPOLL_HOOK pre-poll hook (exit 0/2/3) ([#544](https://github.com/macatocz/makato/issues/544)) ([b0b3e4b](https://github.com/macatocz/makato/commit/b0b3e4bc608895e66683faf4c4896781ba252a9a))

## [0.104.2](https://github.com/macatocz/makato/compare/v0.104.1...v0.104.2) (2026-07-23)


### 🐛 Bug Fixes

* **makato-orchestrate:** plan-tier:change routes to change lane ([#539](https://github.com/macatocz/makato/issues/539)) ([#542](https://github.com/macatocz/makato/issues/542)) ([a6e9298](https://github.com/macatocz/makato/commit/a6e9298ced2abab772ee61be80db005d3de2ea5c))

## [0.104.1](https://github.com/macatocz/makato/compare/v0.104.0...v0.104.1) (2026-07-23)


### 🐛 Bug Fixes

* **loop:** auto-seed consults should-materialize-spec before blocking ([#533](https://github.com/macatocz/makato/issues/533)) ([#540](https://github.com/macatocz/makato/issues/540)) ([cad8e2e](https://github.com/macatocz/makato/commit/cad8e2eb67fb409774036421492a11f094e2ef64))

## [0.104.0](https://github.com/macatocz/makato/compare/v0.103.0...v0.104.0) (2026-07-23)


### ✨ Features

* **loop:** detect exited-incomplete dispatch and resume via --resume ([#531](https://github.com/macatocz/makato/issues/531)) ([ed5713e](https://github.com/macatocz/makato/commit/ed5713e41af0127b3fcc25ff497b471322b54538))
* **makato-orchestrate:** detect exited-incomplete dispatch and resume via --resume ([#531](https://github.com/macatocz/makato/issues/531)) ([#537](https://github.com/macatocz/makato/issues/537)) ([9e618ea](https://github.com/macatocz/makato/commit/9e618ea4c5ca24aaf33178d51ab2e687dfda8955))

## [0.103.0](https://github.com/macatocz/makato/compare/v0.102.1...v0.103.0) (2026-07-23)


### ✨ Features

* **makato-orchestrate:** add external supervisor script for loop.sh restart ([2ad0457](https://github.com/macatocz/makato/commit/2ad0457d57518ac09ebcdadd83d11988aacd443b)), closes [#532](https://github.com/macatocz/makato/issues/532)
* **makato-orchestrate:** add launchd plist template for loop supervisor ([e0d5297](https://github.com/macatocz/makato/commit/e0d5297263121e8fa1d136d6c1d62d28301b169a))
* **makato-orchestrate:** external supervisor to restart a dead loop.sh ([2fe04f5](https://github.com/macatocz/makato/commit/2fe04f57a7493e9970c3b7a1cd179c12020df565))

## [0.102.1](https://github.com/macatocz/makato/compare/v0.102.0...v0.102.1) (2026-07-23)


### 🐛 Bug Fixes

* **makato-orchestrate:** enable headless CLI retry to survive transient API stalls ([da5d800](https://github.com/macatocz/makato/commit/da5d8000d615fced4a8f24f7a4df3a40d718bb69))

## [0.102.0](https://github.com/macatocz/makato/compare/v0.101.0...v0.102.0) (2026-07-21)


### ✨ Features

* **makato-orchestrate:** autonomous build-refine from committed stories.json ([#527](https://github.com/macatocz/makato/issues/527)) ([#529](https://github.com/macatocz/makato/issues/529)) ([fd1e622](https://github.com/macatocz/makato/commit/fd1e622da6b8afb5caba32c7d9c93225a543d8d2))

## [0.101.0](https://github.com/macatocz/makato/compare/v0.100.1...v0.101.0) (2026-07-21)


### ✨ Features

* **observability:** Langfuse session tracing hook + plugin/phase tags ([#525](https://github.com/macatocz/makato/issues/525)) ([a57faff](https://github.com/macatocz/makato/commit/a57faff08d210501e7c7b04e57816be7ac777e4c))

## [0.100.1](https://github.com/macatocz/makato/compare/v0.100.0...v0.100.1) (2026-07-21)


### 🐛 Bug Fixes

* **build-sensors:** reveal untracked files to Gate 0 --all-files scan ([#523](https://github.com/macatocz/makato/issues/523)) ([6483050](https://github.com/macatocz/makato/commit/6483050716b7e589824ea7feb5351d73ab169594))

## [0.100.0](https://github.com/macatocz/makato/compare/v0.99.0...v0.100.0) (2026-07-20)


### ✨ Features

* **makato-observability:** add Claude Code session tracing via Langfuse Stop hook ([af59d1c](https://github.com/macatocz/makato/commit/af59d1c941050831b56fa1eaf12dfa35324efbd7))

## [0.99.0](https://github.com/macatocz/makato/compare/v0.98.1...v0.99.0) (2026-07-20)


### ✨ Features

* **to-issues:** emit plan-&lt;ISSUE_NUMBER&gt;.md per full-tier story at issue-create time ([9432bdc](https://github.com/macatocz/makato/commit/9432bdc9c2943d26973b401023ef277f40eb4c01))
* **to-issues:** emit plan-&lt;N&gt;.md per full-tier story ([#511](https://github.com/macatocz/makato/issues/511)) ([f2b0e2e](https://github.com/macatocz/makato/commit/f2b0e2eee3c863df4957327bf199118c607cd773))
* **to-issues:** emit plan-&lt;N&gt;.md per full-tier story ([#511](https://github.com/macatocz/makato/issues/511)) ([f2b0e2e](https://github.com/macatocz/makato/commit/f2b0e2eee3c863df4957327bf199118c607cd773))

## [0.98.1](https://github.com/macatocz/makato/compare/v0.98.0...v0.98.1) (2026-07-20)


### ⚡ Performance

* **orchestrate:** cut board-poll GraphQL cost ~100x + adaptive idle backoff ([f27c814](https://github.com/macatocz/makato/commit/f27c814ad59395319fdc4ccb8b1479a8dfbbecae))

## [0.98.0](https://github.com/macatocz/makato/compare/v0.97.0...v0.98.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** add &lt;!-- issue: #&lt;issue-number&gt; --&gt; fingerprint header to plan template ([dda91de](https://github.com/macatocz/makato/commit/dda91dea1e3d420fd898c00aba735431cdae70ba))
* **makato-orchestrate:** add ISSUE_NUMBER fingerprint check to validate-plan-body.sh (T14/T15/T16) ([a2d434a](https://github.com/macatocz/makato/commit/a2d434a5246b2746bb73db2bddfaf1d9590a83ef))
* **makato-orchestrate:** fingerprint check in validate-plan-body.sh ([#512](https://github.com/macatocz/makato/issues/512)) ([d839252](https://github.com/macatocz/makato/commit/d8392527bc9acdfae3f7eabb8b33fd190fc80309))
* **makato-orchestrate:** fingerprint check in validate-plan-body.sh ([#512](https://github.com/macatocz/makato/issues/512)) ([d839252](https://github.com/macatocz/makato/commit/d8392527bc9acdfae3f7eabb8b33fd190fc80309))

## [0.97.0](https://github.com/macatocz/makato/compare/v0.96.1...v0.97.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** route tier:semantic lessons into semantic.jsonl ([#494](https://github.com/macatocz/makato/issues/494)) ([#508](https://github.com/macatocz/makato/issues/508)) ([530e336](https://github.com/macatocz/makato/commit/530e33622ed41b4a243a1b08a6caee1e89aaf088))

## [0.96.1](https://github.com/macatocz/makato/compare/v0.96.0...v0.96.1) (2026-07-20)


### 🐛 Bug Fixes

* **makato-orchestrate:** promote lessons in po-agent local lane, drop GHA no-op ([#502](https://github.com/macatocz/makato/issues/502)) ([#504](https://github.com/macatocz/makato/issues/504)) ([8e898b9](https://github.com/macatocz/makato/commit/8e898b9e24dcc43dcd9d60be747b3b392f04f762))

## [0.96.0](https://github.com/macatocz/makato/compare/v0.95.0...v0.96.0) (2026-07-20)


### ✨ Features

* **makato-change:** wire memory recall and lesson-write into change lane ([#474](https://github.com/macatocz/makato/issues/474)) ([728b92e](https://github.com/macatocz/makato/commit/728b92ef687139778ee3bf37826c360f3b456ae7))

## [0.95.0](https://github.com/macatocz/makato/compare/v0.94.0...v0.95.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** prune orphaned specs folders, promoting lessons first ([#501](https://github.com/macatocz/makato/issues/501)) ([f4ad11b](https://github.com/macatocz/makato/commit/f4ad11b79f3494bc8d37c5da3dfacb6a435f8052))

## [0.94.0](https://github.com/macatocz/makato/compare/v0.93.0...v0.94.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** add lesson-prune operator curation skill ([#475](https://github.com/macatocz/makato/issues/475)) ([#498](https://github.com/macatocz/makato/issues/498)) ([edeeb69](https://github.com/macatocz/makato/commit/edeeb692e9b3c6552c771b1c9b85446618e196dd))

## [0.93.0](https://github.com/macatocz/makato/compare/v0.92.1...v0.93.0) (2026-07-20)


### ✨ Features

* **makato-build:** build-lane lesson write via write-lessons.sh ([#473](https://github.com/macatocz/makato/issues/473)) ([bd37025](https://github.com/macatocz/makato/commit/bd37025556d1b44f7fa9213233e760f4b52afd0f))

## [0.92.1](https://github.com/macatocz/makato/compare/v0.92.0...v0.92.1) (2026-07-20)


### 🐛 Bug Fixes

* **makato-orchestrate:** reconcile pass reads Status field/option ids from correct config shape ([#492](https://github.com/macatocz/makato/issues/492)) ([#495](https://github.com/macatocz/makato/issues/495)) ([0e2d348](https://github.com/macatocz/makato/commit/0e2d348d487234c621105116877fb13832285e2f))

## [0.92.0](https://github.com/macatocz/makato/compare/v0.91.0...v0.92.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** auto-generate plan.md before dispatch to prevent HALT-006 ([#490](https://github.com/macatocz/makato/issues/490)) ([0470bb7](https://github.com/macatocz/makato/commit/0470bb70cbfa51bb6a957a43ba1fee9b134a9290))

## [0.91.0](https://github.com/macatocz/makato/compare/v0.90.0...v0.91.0) (2026-07-20)


### ✨ Features

* **makato-orchestrate:** promote generalizable memory at merge ([#471](https://github.com/macatocz/makato/issues/471)) ([#489](https://github.com/macatocz/makato/issues/489)) ([d453de3](https://github.com/macatocz/makato/commit/d453de37074f2370b543f0bbef3ff6ca2a08844e))

## [0.90.0](https://github.com/macatocz/makato/compare/v0.89.2...v0.90.0) (2026-07-19)


### ✨ Features

* **makato-orchestrate:** persistent memory store and shared recall ([#470](https://github.com/macatocz/makato/issues/470)) ([#487](https://github.com/macatocz/makato/issues/487)) ([5393f87](https://github.com/macatocz/makato/commit/5393f87a409601b20b03fa2ff8f562ee786b0dd1))

## [0.89.2](https://github.com/macatocz/makato/compare/v0.89.1...v0.89.2) (2026-07-19)


### 🐛 Bug Fixes

* isolate makato-change orchestrate in a worktree on fresh runs and resumes ([#467](https://github.com/macatocz/makato/issues/467)) ([#485](https://github.com/macatocz/makato/issues/485)) ([7757329](https://github.com/macatocz/makato/commit/7757329e283df954cb4cf38452958397cdab2b51))

## [0.89.1](https://github.com/macatocz/makato/compare/v0.89.0...v0.89.1) (2026-07-19)


### 🐛 Bug Fixes

* **makato-orchestrate:** avoid doubled issue-number prefix in loop dispatch branch ([#483](https://github.com/macatocz/makato/issues/483)) ([57f04ad](https://github.com/macatocz/makato/commit/57f04adee054f242ac97261537e0e5e282e4f72f))

## [0.89.0](https://github.com/macatocz/makato/compare/v0.88.0...v0.89.0) (2026-07-19)


### ✨ Features

* **makato-plan,makato-orchestrate:** dependency labels blocked-by / blocking ([#481](https://github.com/macatocz/makato/issues/481)) ([4d91305](https://github.com/macatocz/makato/commit/4d91305fd4fb688e825cda69815228a7f5443ca2))

## [0.88.0](https://github.com/macatocz/makato/compare/v0.87.2...v0.88.0) (2026-07-19)


### ✨ Features

* mark issue In Progress at workflow start ([#477](https://github.com/macatocz/makato/issues/477)) ([5eefb0f](https://github.com/macatocz/makato/commit/5eefb0f5bb71c53a3ebc92faa4bdd597d1f92c8c))


### 🐛 Bug Fixes

* **makato-orchestrate:** auto-seed and pre-dispatch gate bypass type:change ([#466](https://github.com/macatocz/makato/issues/466)) ([#479](https://github.com/macatocz/makato/issues/479)) ([5e205d2](https://github.com/macatocz/makato/commit/5e205d2582bdcef176ff3ed8450e9f8e7124515e))

## [0.87.2](https://github.com/macatocz/makato/compare/v0.87.1...v0.87.2) (2026-07-19)


### 🐛 Bug Fixes

* **ci:** scope project-board-sync issue concurrency by action ([#468](https://github.com/macatocz/makato/issues/468)) ([#469](https://github.com/macatocz/makato/issues/469)) ([172019e](https://github.com/macatocz/makato/commit/172019e69f150509dd4327b6fdf091f1c30a7f3e))

## [0.87.1](https://github.com/macatocz/makato/compare/v0.87.0...v0.87.1) (2026-07-19)


### 🐛 Bug Fixes

* **makato-build:** build-verify Gates 1-2 use pre-commit hooks, not raw tools ([#450](https://github.com/macatocz/makato/issues/450)) ([#463](https://github.com/macatocz/makato/issues/463)) ([ff2c63d](https://github.com/macatocz/makato/commit/ff2c63db059674a12f84a5e63a3c12be18f26bce))
* **makato-orchestrate:** --repo flag and early-exit REPO validation for dispatch ([#461](https://github.com/macatocz/makato/issues/461)) ([ed61aea](https://github.com/macatocz/makato/commit/ed61aea2da0d5a23a0e35e877eced8beb29fc6ec))

## [0.87.0](https://github.com/macatocz/makato/compare/v0.86.0...v0.87.0) (2026-07-18)


### ✨ Features

* **makato-orchestrate:** per-issue final-envelope aggregation into a run report ([#459](https://github.com/macatocz/makato/issues/459)) ([b4cba9a](https://github.com/macatocz/makato/commit/b4cba9a204b73e77394498dd8d95f19d6774d557)), closes [#448](https://github.com/macatocz/makato/issues/448)

## [0.86.0](https://github.com/macatocz/makato/compare/v0.85.0...v0.86.0) (2026-07-18)


### ✨ Features

* **makato-orchestrate:** gh CLI to REST fallback for critical loop calls ([#458](https://github.com/macatocz/makato/issues/458)) ([e3a0900](https://github.com/macatocz/makato/commit/e3a0900aee84803a2e294623511f14ae97e7dc44)), closes [#447](https://github.com/macatocz/makato/issues/447)

## [0.85.0](https://github.com/macatocz/makato/compare/v0.84.0...v0.85.0) (2026-07-17)


### ✨ Features

* **makato-orchestrate:** pre-dispatch KEY/slug validation against spec folder ([#445](https://github.com/macatocz/makato/issues/445)) ([#456](https://github.com/macatocz/makato/issues/456)) ([904e90a](https://github.com/macatocz/makato/commit/904e90a26a6704dfa74f8d910259b58e6d1fcecf))

## [0.84.0](https://github.com/macatocz/makato/compare/v0.83.0...v0.84.0) (2026-07-17)


### ✨ Features

* **makato-orchestrate:** diagnostic stall recovery with auto-restart from preserved state ([#444](https://github.com/macatocz/makato/issues/444)) ([#453](https://github.com/macatocz/makato/issues/453)) ([3f58ac9](https://github.com/macatocz/makato/commit/3f58ac92a3adf1a702009a970e68274add4c5d48))

## [0.83.0](https://github.com/macatocz/makato/compare/v0.82.0...v0.83.0) (2026-07-17)


### ✨ Features

* **makato-observability:** add langfuse ops + langfuse-enrich skills ([#452](https://github.com/macatocz/makato/issues/452)) ([d15dcf8](https://github.com/macatocz/makato/commit/d15dcf8053cbfc8a6db86a3adc92ddeddbc31edc))

## [0.82.0](https://github.com/macatocz/makato/compare/v0.81.0...v0.82.0) (2026-07-17)


### ✨ Features

* **makato-orchestrate:** machine-readable retryable/origin classification for HALT codes ([#446](https://github.com/macatocz/makato/issues/446)) ([#449](https://github.com/macatocz/makato/issues/449)) ([e280966](https://github.com/macatocz/makato/commit/e2809663dec2b3666a3a7508f01f281c3d0f25f5))

## [0.81.0](https://github.com/macatocz/makato/compare/v0.80.0...v0.81.0) (2026-07-16)


### ✨ Features

* **makato-contribute:** full skill-routing coverage + box-level diagram edges ([#441](https://github.com/macatocz/makato/issues/441)) ([4f23863](https://github.com/macatocz/makato/commit/4f23863b4af4c532a8e944e189148543568538fc))

## [0.80.0](https://github.com/macatocz/makato/compare/v0.79.2...v0.80.0) (2026-07-16)


### ✨ Features

* **docs:** generate makato-flow.html graph-data with drift check ([#428](https://github.com/macatocz/makato/issues/428)) ([#439](https://github.com/macatocz/makato/issues/439)) ([d91bd7d](https://github.com/macatocz/makato/commit/d91bd7d5bb01a899948b7239900a430461ce1bca))

## [0.79.2](https://github.com/macatocz/makato/compare/v0.79.1...v0.79.2) (2026-07-15)


### 🐛 Bug Fixes

* **makato-build:** route biome 'files were modified' autofix signal ([#437](https://github.com/macatocz/makato/issues/437)) ([5b419cb](https://github.com/macatocz/makato/commit/5b419cb78fd779bf6a99a9b335201fcee8f0da72))

## [0.79.1](https://github.com/macatocz/makato/compare/v0.79.0...v0.79.1) (2026-07-15)


### 🐛 Bug Fixes

* **flow:** hide-panels button swallowed by pointerdown capture ([#433](https://github.com/macatocz/makato/issues/433)) ([891c033](https://github.com/macatocz/makato/commit/891c033bd2c772250d677a95b9148d91b9e5b033))

## [0.79.0](https://github.com/macatocz/makato/compare/v0.78.0...v0.79.0) (2026-07-15)


### ✨ Features

* **to-issues:** derive effort:* from a points signal ([#431](https://github.com/macatocz/makato/issues/431)) ([cbbc21d](https://github.com/macatocz/makato/commit/cbbc21d0f78e3b840b1f54039f9b91cb7e7b5d73))

## [0.78.0](https://github.com/macatocz/makato/compare/v0.77.0...v0.78.0) (2026-07-15)


### ✨ Features

* **makato-orchestrate:** generalise auto-seed bot veto to any [bot] author ([#425](https://github.com/macatocz/makato/issues/425)) ([83354fc](https://github.com/macatocz/makato/commit/83354fcad29e42bb887ddd3ee1b38f0837470ddf))

## [0.77.0](https://github.com/macatocz/makato/compare/v0.76.0...v0.77.0) (2026-07-15)


### ✨ Features

* **to-issues:** derive priority:* from tier:* as fallback ([#424](https://github.com/macatocz/makato/issues/424)) ([538bf77](https://github.com/macatocz/makato/commit/538bf77f0bc0044e5d6760a11c992f399a075f66))

## [0.76.0](https://github.com/macatocz/makato/compare/v0.75.0...v0.76.0) (2026-07-15)


### ✨ Features

* **makato-orchestrate:** add loop reshape pass for Needs Planning signal ([#350](https://github.com/macatocz/makato/issues/350)) ([#418](https://github.com/macatocz/makato/issues/418)) ([592eddd](https://github.com/macatocz/makato/commit/592eddd5f77a8aec812acc556b1ecb696f781020))
* **makato-orchestrate:** orphan degraded gate for hand-filed issues ([#357](https://github.com/macatocz/makato/issues/357)) ([#421](https://github.com/macatocz/makato/issues/421)) ([4c763c0](https://github.com/macatocz/makato/commit/4c763c01bc12efc7c03bfead9d4d05de1dc2294f))

## [0.75.0](https://github.com/macatocz/makato/compare/v0.74.0...v0.75.0) (2026-07-15)


### ✨ Features

* **makato-orchestrate:** bound the auto-reshape to prevent plan↔build oscillation ([#351](https://github.com/macatocz/makato/issues/351), epic [#319](https://github.com/macatocz/makato/issues/319)) ([33737f4](https://github.com/macatocz/makato/commit/33737f4a5658444fc8c988940a486264d573576e))

## [0.74.0](https://github.com/macatocz/makato/compare/v0.73.0...v0.74.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** reconcile orphaned In progress board cards ([#368](https://github.com/macatocz/makato/issues/368)) ([#414](https://github.com/macatocz/makato/issues/414)) ([7f8f8a1](https://github.com/macatocz/makato/commit/7f8f8a18a0a986a286dff57fb7ad8379103b6094))

## [0.73.0](https://github.com/macatocz/makato/compare/v0.72.0...v0.73.0) (2026-07-14)


### ✨ Features

* **makato-core:** align skill-judge with repo conventions, autonomous scoring ([#415](https://github.com/macatocz/makato/issues/415)) ([650cb67](https://github.com/macatocz/makato/commit/650cb672785da38f6336fe2ee08bdbff5b2c1cbc))
* **makato-orchestrate:** label-board conflict gate for dispatch ([#356](https://github.com/macatocz/makato/issues/356)) ([2af4ba4](https://github.com/macatocz/makato/commit/2af4ba4d266d2b6c54608b8aa11fb996a856a908))

## [0.72.0](https://github.com/macatocz/makato/compare/v0.71.0...v0.72.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** emit durable Needs Planning signal at recurrence threshold ([#348](https://github.com/macatocz/makato/issues/348)) ([#410](https://github.com/macatocz/makato/issues/410)) ([8ee32f6](https://github.com/macatocz/makato/commit/8ee32f6de77ccc0f7397474a4445505b5c874a30))

## [0.71.0](https://github.com/macatocz/makato/compare/v0.70.1...v0.71.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** classify CI failures and route sensor types to sensor-fixer ([#390](https://github.com/macatocz/makato/issues/390)) ([#406](https://github.com/macatocz/makato/issues/406)) ([2a3cc49](https://github.com/macatocz/makato/commit/2a3cc49217abf2b14438e96519c5e6e4e38701b8))

## [0.70.1](https://github.com/macatocz/makato/compare/v0.70.0...v0.70.1) (2026-07-14)


### ♻️ Refactors

* **makato-orchestrate:** rename scout agent to task-file-scout ([#397](https://github.com/macatocz/makato/issues/397)) ([#404](https://github.com/macatocz/makato/issues/404)) ([841d306](https://github.com/macatocz/makato/commit/841d306bd6ca3a83e5ce5c5b8052419c824cfb58))
* **makato-plan:** rename grill skill to stress-test-artifact ([#397](https://github.com/macatocz/makato/issues/397)) ([#405](https://github.com/macatocz/makato/issues/405)) ([49b431d](https://github.com/macatocz/makato/commit/49b431d982c9d44df8608663829fce2eb8f8674e))

## [0.70.0](https://github.com/macatocz/makato/compare/v0.69.0...v0.70.0) (2026-07-14)


### ✨ Features

* **makato-change:** isolate execute write phase in change-implementer subagent ([#402](https://github.com/macatocz/makato/issues/402)) ([af8f87c](https://github.com/macatocz/makato/commit/af8f87cc03b285d9a9536d4d6077929e5fe4aa06)), closes [#396](https://github.com/macatocz/makato/issues/396)


### ♻️ Refactors

* **makato-core:** rename zoom-out skill to map-codebase-context ([#397](https://github.com/macatocz/makato/issues/397)) ([#403](https://github.com/macatocz/makato/issues/403)) ([97f65be](https://github.com/macatocz/makato/commit/97f65be9e95396724e00ed24649296d0b6616f21))

## [0.69.0](https://github.com/macatocz/makato/compare/v0.68.0...v0.69.0) (2026-07-14)


### ✨ Features

* **makato-build:** make context7 lookup mandatory in coder before RED ([#400](https://github.com/macatocz/makato/issues/400)) ([a6ece38](https://github.com/macatocz/makato/commit/a6ece38d4a7c4b717a56fc03d3cb70a3393b904b)), closes [#395](https://github.com/macatocz/makato/issues/395)
* **makato-plan:** add fastapi & temporal-development archetypes to task-skill-map ([#399](https://github.com/macatocz/makato/issues/399)) ([06a2918](https://github.com/macatocz/makato/commit/06a2918828938a09be0f8ff5674d19f00ffcfbb2)), closes [#394](https://github.com/macatocz/makato/issues/394)

## [0.68.0](https://github.com/macatocz/makato/compare/v0.67.0...v0.68.0) (2026-07-14)


### ✨ Features

* **makato-change:** wire progress-comment narration into orchestrate skill (v1.2.0) ([#387](https://github.com/macatocz/makato/issues/387)) ([48641d2](https://github.com/macatocz/makato/commit/48641d2a2ed1258979c3a6d96b64be8f426465e9))


### ♻️ Refactors

* **makato-contribute:** remove manage-pr, consolidate into build-address-pr-comments ([#393](https://github.com/macatocz/makato/issues/393)) ([05eacef](https://github.com/macatocz/makato/commit/05eacefb12b186f4678d3601dd306c2c4a6ad492))

## [0.67.0](https://github.com/macatocz/makato/compare/v0.66.0...v0.67.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** auto-seed tick integration, toggle, and offline smoke suite ([#373](https://github.com/macatocz/makato/issues/373)) ([#391](https://github.com/macatocz/makato/issues/391)) ([7d468db](https://github.com/macatocz/makato/commit/7d468db03621e713e7ac877aa072f535391d938d))

## [0.66.0](https://github.com/macatocz/makato/compare/v0.65.0...v0.66.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** thin-body terminal state reconciliation ([#371](https://github.com/macatocz/makato/issues/371)) ([#388](https://github.com/macatocz/makato/issues/388)) ([43a7322](https://github.com/macatocz/makato/commit/43a732262cc03c17a2b6d7f86df8ad2c184505a6))

## [0.65.0](https://github.com/macatocz/makato/compare/v0.64.0...v0.65.0) (2026-07-14)


### ✨ Features

* **makato-build:** gate-scout discovers uv/pyright/biome/sqlfluff toolchains ([#377](https://github.com/macatocz/makato/issues/377)) ([95da0c6](https://github.com/macatocz/makato/commit/95da0c6c3d806936cd6a1df765fa1a539c82a729))

## [0.64.0](https://github.com/macatocz/makato/compare/v0.63.0...v0.64.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** full/untiered arm — block for human ([#372](https://github.com/macatocz/makato/issues/372)) ([#384](https://github.com/macatocz/makato/issues/384)) ([fb7efd0](https://github.com/macatocz/makato/commit/fb7efd07e72edd61d2f60a67ecbc20209794bbd7))

## [0.63.0](https://github.com/macatocz/makato/compare/v0.62.0...v0.63.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** add _auto_seed_dispatch_light() for light-tier auto-seed ([#370](https://github.com/macatocz/makato/issues/370)) ([#381](https://github.com/macatocz/makato/issues/381)) ([c1fdf87](https://github.com/macatocz/makato/commit/c1fdf87faf702b59835b78382e022cfafdd5ce0a))

## [0.62.0](https://github.com/macatocz/makato/compare/v0.61.0...v0.62.0) (2026-07-14)


### ✨ Features

* **makato-core:** extend create-issue with plan-tier, issue-to-project, and seed-issue (v1.2.0) ([#378](https://github.com/macatocz/makato/issues/378)) ([83becd0](https://github.com/macatocz/makato/commit/83becd0e33e412ee3cea7d0981d6d7204da5b084))

## [0.61.0](https://github.com/macatocz/makato/compare/v0.60.0...v0.61.0) (2026-07-14)


### ✨ Features

* verify acceptance criteria before marking issue checkboxes ([#375](https://github.com/macatocz/makato/issues/375)) ([2de78db](https://github.com/macatocz/makato/commit/2de78db7c999a2b25d55405a39082a7824a2a68a))

## [0.60.0](https://github.com/macatocz/makato/compare/v0.59.0...v0.60.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** add _auto_seed_candidates() to loop.sh ([#369](https://github.com/macatocz/makato/issues/369)) ([#374](https://github.com/macatocz/makato/issues/374)) ([fcd7c84](https://github.com/macatocz/makato/commit/fcd7c84d89336e18d9a5741bd0475ea7d9299e34))

## [0.59.0](https://github.com/macatocz/makato/compare/v0.58.0...v0.59.0) (2026-07-14)


### ✨ Features

* **makato-orchestrate:** durable per-issue structural_halt_cycles counter ([#347](https://github.com/macatocz/makato/issues/347)) ([#354](https://github.com/macatocz/makato/issues/354)) ([65ea817](https://github.com/macatocz/makato/commit/65ea817628eb41900739ea1bdd85c63ab87287ec))

## [0.58.0](https://github.com/macatocz/makato/compare/v0.57.0...v0.58.0) (2026-07-14)


### ✨ Features

* **makato-fastapi:** initial plugin with governance and fastapi skill ([#359](https://github.com/macatocz/makato/issues/359)) ([34a010d](https://github.com/macatocz/makato/commit/34a010d4334501bf2c3c7e4d7a9c1b7dfde5f8db))

## [0.57.0](https://github.com/macatocz/makato/compare/v0.56.1...v0.57.0) (2026-07-14)


### ✨ Features

* **loop:** authoritative dispatch gate tiers 1-2 + exclusion veto ([#318](https://github.com/macatocz/makato/issues/318), [#355](https://github.com/macatocz/makato/issues/355)) ([#362](https://github.com/macatocz/makato/issues/362)) ([5afac3a](https://github.com/macatocz/makato/commit/5afac3a901676f685aca79a3d1d7808c54301fe5))

## [0.56.1](https://github.com/macatocz/makato/compare/v0.56.0...v0.56.1) (2026-07-14)


### 🐛 Bug Fixes

* **makato-temporal:** route temporal-development via tech:temporal label ([#358](https://github.com/macatocz/makato/issues/358)) ([1a691a0](https://github.com/macatocz/makato/commit/1a691a04b88f96b3c66ebfe18b73cd2aedf4c5e0))

## [0.56.0](https://github.com/macatocz/makato/compare/v0.55.0...v0.56.0) (2026-07-13)


### ✨ Features

* **makato-orchestrate:** serialize structural-failure evidence into reshape context packet ([#349](https://github.com/macatocz/makato/issues/349)) ([9efd51b](https://github.com/macatocz/makato/commit/9efd51ba485f17ea77b92902414b3e0bf21d8a5e))

## [0.55.0](https://github.com/macatocz/makato/compare/v0.54.3...v0.55.0) (2026-07-13)


### ✨ Features

* add renovate.json to allowed files in root structure check ([302a58f](https://github.com/macatocz/makato/commit/302a58f7e8af266889d86dff7735071b00aaaa6b))

## [0.54.3](https://github.com/macatocz/makato/compare/v0.54.2...v0.54.3) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** add stale-worktree reaping for crashed runs ([#320](https://github.com/macatocz/makato/issues/320)) ([#338](https://github.com/macatocz/makato/issues/338)) ([959ea7c](https://github.com/macatocz/makato/commit/959ea7c1f068a2cd90cb9ef922878ba18feff1b6))

## [0.54.2](https://github.com/macatocz/makato/compare/v0.54.1...v0.54.2) (2026-07-13)


### 🐛 Bug Fixes

* **makato-langgraph:** cross-plugin collision gate + robust shared path resolution ([#335](https://github.com/macatocz/makato/issues/335)) ([21887ed](https://github.com/macatocz/makato/commit/21887edf1948c4ab68d2c91479ba5e3a9015c9df))

## [0.54.1](https://github.com/macatocz/makato/compare/v0.54.0...v0.54.1) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** emit loud degraded warning when jsonschema missing ([#317](https://github.com/macatocz/makato/issues/317)) ([#337](https://github.com/macatocz/makato/issues/337)) ([2ac2b80](https://github.com/macatocz/makato/commit/2ac2b80e125fc327b95622aaf4d877934515dd2e))
* **makato-orchestrate:** make _write_status atomic via same-dir mktemp ([#316](https://github.com/macatocz/makato/issues/316)) ([#336](https://github.com/macatocz/makato/issues/336)) ([3b1e0d3](https://github.com/macatocz/makato/commit/3b1e0d3cb7d3292a297f2a35c39726552b43d5ae))

## [0.54.0](https://github.com/macatocz/makato/compare/v0.53.1...v0.54.0) (2026-07-13)


### ✨ Features

* **makato-orchestrate:** dependency-aware Ready promotion ([#268](https://github.com/macatocz/makato/issues/268)) ([#327](https://github.com/macatocz/makato/issues/327)) ([daa0ef4](https://github.com/macatocz/makato/commit/daa0ef49d7f8a19c49a4aa1efdeed76153fe9d46))

## [0.53.1](https://github.com/macatocz/makato/compare/v0.53.0...v0.53.1) (2026-07-13)


### 🐛 Bug Fixes

* **makato-build:** gate advisory diff-reviewer + coverage-floor escapes ([#290](https://github.com/macatocz/makato/issues/290)) ([#314](https://github.com/macatocz/makato/issues/314)) ([2005beb](https://github.com/macatocz/makato/commit/2005beb470e45cb882ac28c420518a2cf3afc857))

## [0.53.0](https://github.com/macatocz/makato/compare/v0.52.9...v0.53.0) (2026-07-13)


### ✨ Features

* **makato-build:** add pre-commit gate for context-bundles.yml ([#324](https://github.com/macatocz/makato/issues/324)) ([#332](https://github.com/macatocz/makato/issues/332)) ([e5ecd39](https://github.com/macatocz/makato/commit/e5ecd395a2ea351c08da03ca1c68973ea1e66d85))


### 🐛 Bug Fixes

* **.gitignore:** re-include specs/**/build.jsonl audit trail ([#321](https://github.com/macatocz/makato/issues/321)) ([#329](https://github.com/macatocz/makato/issues/329)) ([6dd7b37](https://github.com/macatocz/makato/commit/6dd7b373e72e89db54154878831656b67d8d696e))

## [0.52.9](https://github.com/macatocz/makato/compare/v0.52.8...v0.52.9) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** guard watchdog writes by ownership + flake-probe CI failures ([#312](https://github.com/macatocz/makato/issues/312)) ([#328](https://github.com/macatocz/makato/issues/328)) ([02c6ff0](https://github.com/macatocz/makato/commit/02c6ff0e11f16a58f4fce2f707486cdcbb8b9141))

## [0.52.8](https://github.com/macatocz/makato/compare/v0.52.7...v0.52.8) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** retry board poll, stop treating 429 as empty queue ([#289](https://github.com/macatocz/makato/issues/289)) ([#313](https://github.com/macatocz/makato/issues/313)) ([6b17096](https://github.com/macatocz/makato/commit/6b170961a4e3e62ae2f10b5528f61c3323339ec3))

## [0.52.7](https://github.com/macatocz/makato/compare/v0.52.6...v0.52.7) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** supervise HALT-007B restart subprocess liveness ([#284](https://github.com/macatocz/makato/issues/284)) ([#311](https://github.com/macatocz/makato/issues/311)) ([38b6200](https://github.com/macatocz/makato/commit/38b62004e1e456981462a804e60589f6aed644ca))

## [0.52.6](https://github.com/macatocz/makato/compare/v0.52.5...v0.52.6) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** give CI-failure loop its own budget counter ([#288](https://github.com/macatocz/makato/issues/288)) ([#309](https://github.com/macatocz/makato/issues/309)) ([781c2a1](https://github.com/macatocz/makato/commit/781c2a148eb9ad8bde4a4bb96f4a7a55b2257bfb))

## [0.52.5](https://github.com/macatocz/makato/compare/v0.52.4...v0.52.5) (2026-07-13)


### 🐛 Bug Fixes

* **makato-build:** reconcile documented-but-unwired mechanisms ([#287](https://github.com/macatocz/makato/issues/287)) ([#307](https://github.com/macatocz/makato/issues/307)) ([6cd6809](https://github.com/macatocz/makato/commit/6cd6809ffcf94abb62b9cf5786c1a4820e5973b3))

## [0.52.4](https://github.com/macatocz/makato/compare/v0.52.3...v0.52.4) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** bound Step 6b review poll with wall-clock timeout ([#283](https://github.com/macatocz/makato/issues/283)) ([#305](https://github.com/macatocz/makato/issues/305)) ([274eecd](https://github.com/macatocz/makato/commit/274eecd0a1b1361e83edefb14b7da378abff0fb3))

## [0.52.3](https://github.com/macatocz/makato/compare/v0.52.2...v0.52.3) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** exclude needs-human-review from Ready re-promotion ([#286](https://github.com/macatocz/makato/issues/286)) ([#303](https://github.com/macatocz/makato/issues/303)) ([62f6afa](https://github.com/macatocz/makato/commit/62f6afaff5cc546803b1212ab91313becaa98d78))

## [0.52.2](https://github.com/macatocz/makato/compare/v0.52.1...v0.52.2) (2026-07-13)


### 🐛 Bug Fixes

* **makato-build:** add cross-task regression sweep to TDD outer loop ([#285](https://github.com/macatocz/makato/issues/285)) ([#301](https://github.com/macatocz/makato/issues/301)) ([fcff000](https://github.com/macatocz/makato/commit/fcff000dd01cf13d5f1c340607d6de916e8c8f12))

## [0.52.1](https://github.com/macatocz/makato/compare/v0.52.0...v0.52.1) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** resolve specs/ from main checkout in worktree runs ([#282](https://github.com/macatocz/makato/issues/282)) ([#298](https://github.com/macatocz/makato/issues/298)) ([ffa974b](https://github.com/macatocz/makato/commit/ffa974b5e8c9c2f675d35037fd652317ce7006fa))

## [0.52.0](https://github.com/macatocz/makato/compare/v0.51.1...v0.52.0) (2026-07-13)


### ✨ Features

* **makato-temporal:** add config/skill-bundles.yml ([#297](https://github.com/macatocz/makato/issues/297)) ([0a749e1](https://github.com/macatocz/makato/commit/0a749e13059313fceecd2b3f46d97e26976f258c))

## [0.51.1](https://github.com/macatocz/makato/compare/v0.51.0...v0.51.1) (2026-07-13)


### 🐛 Bug Fixes

* **makato-orchestrate:** HALT-007B evaluates per-session token delta ([#281](https://github.com/macatocz/makato/issues/281)) ([#294](https://github.com/macatocz/makato/issues/294)) ([e789b7c](https://github.com/macatocz/makato/commit/e789b7cc17b5837a2bbea497d2b84061ef8d8ddc))
* **scripts:** derive D22 bundle-coverage denominator from live plugin count ([#293](https://github.com/macatocz/makato/issues/293)) ([87d6e40](https://github.com/macatocz/makato/commit/87d6e402b5c39624db9cb7e7deb0a6010e157ddd))

## [0.51.0](https://github.com/macatocz/makato/compare/v0.50.0...v0.51.0) (2026-07-13)


### ✨ Features

* interactive suite data-flow diagram + split makato-doc out of makato-core ([#271](https://github.com/macatocz/makato/issues/271)) ([ef8122b](https://github.com/macatocz/makato/commit/ef8122b2cc08c88b39e40d273ce3fcd89b3a7f58))

## [0.50.0](https://github.com/macatocz/makato/compare/v0.49.0...v0.50.0) (2026-07-12)


### ✨ Features

* **makato-contribute:** register technical skills in skill-bundles.yml ([#278](https://github.com/macatocz/makato/issues/278)) ([8810e6b](https://github.com/macatocz/makato/commit/8810e6b4495c19907d7edd2ee198c13d8ba5b06b))

## [0.49.0](https://github.com/macatocz/makato/compare/v0.48.0...v0.49.0) (2026-07-12)


### ✨ Features

* **makato-plan:** decompose emits taxonomic type: label; to-issues honors it ([#272](https://github.com/macatocz/makato/issues/272)) ([#275](https://github.com/macatocz/makato/issues/275)) ([7bde925](https://github.com/macatocz/makato/commit/7bde9256c3d4a31a0dffdec07871bc060c149169))

## [0.48.0](https://github.com/macatocz/makato/compare/v0.47.0...v0.48.0) (2026-07-12)


### ✨ Features

* **skill-bundles:** remove unnecessary skills from contribute-skills bundle ([a0aed04](https://github.com/macatocz/makato/commit/a0aed04e055cbf2fb875a11a423a92ec741adbb6))

## [0.47.0](https://github.com/macatocz/makato/compare/v0.46.1...v0.47.0) (2026-07-12)


### ✨ Features

* **makato-temporal:** new plugin housing temporal-development skill ([#273](https://github.com/macatocz/makato/issues/273)) ([5b28bfb](https://github.com/macatocz/makato/commit/5b28bfb09d4dc86725bdc3879afb4f1955f08ea9))

## [0.46.1](https://github.com/macatocz/makato/compare/v0.46.0...v0.46.1) (2026-07-12)


### 🐛 Bug Fixes

* **makato-orchestrate:** reaper landed-detection — ancestry + tracked-only dirty + nested-child ([#265](https://github.com/macatocz/makato/issues/265)) ([#269](https://github.com/macatocz/makato/issues/269)) ([bbd0aa5](https://github.com/macatocz/makato/commit/bbd0aa51a2384a69828e231d8ca9b1b228cbf22e))

## [0.46.0](https://github.com/macatocz/makato/compare/v0.45.0...v0.46.0) (2026-07-12)


### ✨ Features

* **makato-orchestrate:** loop auto-reaps local worktrees whose PR is merged ([#265](https://github.com/macatocz/makato/issues/265)) ([#266](https://github.com/macatocz/makato/issues/266)) ([c5db519](https://github.com/macatocz/makato/commit/c5db519a126c12efe7dafd61437624313ddd35e1))

## [0.45.0](https://github.com/macatocz/makato/compare/v0.44.3...v0.45.0) (2026-07-12)


### ✨ Features

* **inject-skills:** F5 task-text routing via task_contains bundle key ([#131](https://github.com/macatocz/makato/issues/131)) ([#263](https://github.com/macatocz/makato/issues/263)) ([bf4a7c8](https://github.com/macatocz/makato/commit/bf4a7c8dc09ef355a492e6f67b7e613e5078d313))

## [0.44.3](https://github.com/macatocz/makato/compare/v0.44.2...v0.44.3) (2026-07-12)


### 🐛 Bug Fixes

* **makato-orchestrate:** loop claims board card synchronously to stop cross-worktree double-dispatch ([#259](https://github.com/macatocz/makato/issues/259)) ([#261](https://github.com/macatocz/makato/issues/261)) ([eae10a1](https://github.com/macatocz/makato/commit/eae10a175d7e3daa0e9795a3222543af7f70cf95))

## [0.44.2](https://github.com/macatocz/makato/compare/v0.44.1...v0.44.2) (2026-07-12)


### 🐛 Bug Fixes

* **repo-wide:** reconcile spec-folder conventions + P1 contract drifts ([#233](https://github.com/macatocz/makato/issues/233), [#234](https://github.com/macatocz/makato/issues/234)) ([#258](https://github.com/macatocz/makato/issues/258)) ([7de3c96](https://github.com/macatocz/makato/commit/7de3c9630900ae0a65e5ecddeca15b6afa1fa47c))

## [0.44.1](https://github.com/macatocz/makato/compare/v0.44.0...v0.44.1) (2026-07-12)


### 🐛 Bug Fixes

* two-step spec-folder resolution across build/orchestrate/change ([#233](https://github.com/macatocz/makato/issues/233)) ([#255](https://github.com/macatocz/makato/issues/255)) ([ffd30c3](https://github.com/macatocz/makato/commit/ffd30c3ebfa8887ee2d9035298b02c5d420b1b2c))

## [0.44.0](https://github.com/macatocz/makato/compare/v0.43.1...v0.44.0) (2026-07-12)


### ✨ Features

* **makato-orchestrate:** narrate autonomous run into a live issue comment ([#254](https://github.com/macatocz/makato/issues/254)) ([6ebe8e1](https://github.com/macatocz/makato/commit/6ebe8e1e2ed70683934070c47a777b01ccb9556e))

## [0.43.1](https://github.com/macatocz/makato/compare/v0.43.0...v0.43.1) (2026-07-12)


### 🐛 Bug Fixes

* **makato-orchestrate:** let non-to-issues issues enter the loop unattended ([#231](https://github.com/macatocz/makato/issues/231), [#232](https://github.com/macatocz/makato/issues/232)) ([#252](https://github.com/macatocz/makato/issues/252)) ([7dfb7dc](https://github.com/macatocz/makato/commit/7dfb7dc3fe79ffc385420095e5976700021a088a))

## [0.43.0](https://github.com/macatocz/makato/compare/v0.42.1...v0.43.0) (2026-07-11)


### ✨ Features

* **d22:** D22 system-done gate + maintenance handoff report ([#150](https://github.com/macatocz/makato/issues/150)) ([#250](https://github.com/macatocz/makato/issues/250)) ([88368a8](https://github.com/macatocz/makato/commit/88368a812ae5bcb4a62ae5a50f25cd3d403d25b9))

## [0.42.1](https://github.com/macatocz/makato/compare/v0.42.0...v0.42.1) (2026-07-11)


### 🐛 Bug Fixes

* **makato-build:** unify Finding schema across sensor loop ([#230](https://github.com/macatocz/makato/issues/230)) ([#248](https://github.com/macatocz/makato/issues/248)) ([43bdc8e](https://github.com/macatocz/makato/commit/43bdc8eb134f928c0730519edf0efaa61c94933f))

## [0.42.0](https://github.com/macatocz/makato/compare/v0.41.0...v0.42.0) (2026-07-11)


### ✨ Features

* **audit:** adaptive audit workflow — D16 state, sample sizing, D14 escalation ([#149](https://github.com/macatocz/makato/issues/149)) ([#242](https://github.com/macatocz/makato/issues/242)) ([c3cd09c](https://github.com/macatocz/makato/commit/c3cd09cf58b0204c9a1dfd853e12bdaf4571e35a))

## [0.41.0](https://github.com/macatocz/makato/compare/v0.40.1...v0.41.0) (2026-07-11)


### ✨ Features

* **makato-build:** TEST_ORACLE — acceptanceTestCases[] drives coder RED tests ([#235](https://github.com/macatocz/makato/issues/235)) ([c343b62](https://github.com/macatocz/makato/commit/c343b62cf89002a224dbefee8ad8806f88190503))
* **makato-build:** TEST_ORACLE — acceptanceTestCases[] drives coder RED tests ([#235](https://github.com/macatocz/makato/issues/235)) ([442baff](https://github.com/macatocz/makato/commit/442baff048fe0cc33e0f3bb31e1b4006ab23ebf1))


### 🐛 Bug Fixes

* **plugins:** GH_HOST= prefix on gh project subcommands (completes [#38](https://github.com/macatocz/makato/issues/38)) ([9cae691](https://github.com/macatocz/makato/commit/9cae6917999a9a3e2d08a9da102ca2bb01cadbf6))
* **plugins:** use GH_HOST= prefix instead of --hostname on gh project subcommands ([082d82b](https://github.com/macatocz/makato/commit/082d82b531a5de541fadf57ca9b54e8963988dd7))


### 🤖 CI

* **project-board-sync:** use MAKATO_TOKEN for operational board sync ([57ca623](https://github.com/macatocz/makato/commit/57ca6231ef7f5d9a5710b1bf5e96407c8247f8bc))
* **project-board-sync:** use MAKATO_TOKEN for operational board sync ([3688473](https://github.com/macatocz/makato/commit/368847377c7f282be7511090c881036d8ae3ec98))

## [0.40.1](https://github.com/macatocz/makato/compare/v0.40.0...v0.40.1) (2026-07-11)


### 🐛 Bug Fixes

* **makato-build:** build-verify threads spec_key into Gate-0 sensors ([#229](https://github.com/macatocz/makato/issues/229)) ([6dffc84](https://github.com/macatocz/makato/commit/6dffc84f8c92a29ae1f977224143a5aec0f83f2b))
* **makato-build:** build-verify threads spec_key into Gate-0 sensors ([#229](https://github.com/macatocz/makato/issues/229)) ([db0dbeb](https://github.com/macatocz/makato/commit/db0dbebc9b62ce9790d2a24acb7efafa7bbcc598))
* **makato-plan:** to-issues reads stories.json v2.0 schema ([#228](https://github.com/macatocz/makato/issues/228)) ([f5ffcdb](https://github.com/macatocz/makato/commit/f5ffcdb691f0ecdfe77ac0c02b406cca22c6240b))
* **makato-plan:** to-issues reads stories.json v2.0 schema ([#228](https://github.com/macatocz/makato/issues/228)) ([79eed75](https://github.com/macatocz/makato/commit/79eed754f653652ac0cc89c55215ff25d4304fd6))

## [0.40.0](https://github.com/macatocz/makato/compare/v0.39.1...v0.40.0) (2026-07-10)


### ✨ Features

* **makato-orchestrate:** auto-materialize spec on HALT-006 for plan-tier:light issues ([#200](https://github.com/macatocz/makato/issues/200)) ([5f28cff](https://github.com/macatocz/makato/commit/5f28cff570bb9335200cc05b8c80df7d01cf05f5))

## [0.39.1](https://github.com/macatocz/makato/compare/v0.39.0...v0.39.1) (2026-07-10)


### 🐛 Bug Fixes

* **makato-orchestrate:** deterministic bash port of archive-spec workflow ([#221](https://github.com/macatocz/makato/issues/221)) ([8fe24fb](https://github.com/macatocz/makato/commit/8fe24fb1f4b2b2e9d4eb0dd81176aa7624681ab7))
* **makato-orchestrate:** deterministic bash port of archive-spec workflow ([#221](https://github.com/macatocz/makato/issues/221)) ([2274c10](https://github.com/macatocz/makato/commit/2274c10c3d637de4c0b0ffc88a24fe9854d6794a))

## [0.39.0](https://github.com/macatocz/makato/compare/v0.38.0...v0.39.0) (2026-07-10)


### ✨ Features

* issues.opened auto-onboarding + deterministic plan-tier classifier ([#211](https://github.com/macatocz/makato/issues/211)) ([98b6bff](https://github.com/macatocz/makato/commit/98b6bff26657f4e6a2be0759ed7519e8d96c6f13))
* issues.opened auto-onboarding + deterministic plan-tier classifier ([#211](https://github.com/macatocz/makato/issues/211)) ([1321724](https://github.com/macatocz/makato/commit/1321724e9003b8ee7dae2ff1015cad39b737b96f))
* lightweight planning lane — light-planner + plan-gated promotion ([#212](https://github.com/macatocz/makato/issues/212)) ([ec02484](https://github.com/macatocz/makato/commit/ec024846a8030c92ba8ea8e78bf2322333a4b042))
* **makato-build:** build-verify skill-provenance advisory gate (never fails build) ([#147](https://github.com/macatocz/makato/issues/147)) ([090a66c](https://github.com/macatocz/makato/commit/090a66c83052c0837cdcb6fa974380b4826a4c83))
* **makato-build:** DoD skill-provenance item + passport concurrent-write audit ([#147](https://github.com/macatocz/makato/issues/147)) ([ca8a750](https://github.com/macatocz/makato/commit/ca8a7508f314226a08afa629f4de89b3c0d56695))
* **makato-build:** skill passport + build-verify advisory gate + concurrent-write guard ([#147](https://github.com/macatocz/makato/issues/147)) ([25ccece](https://github.com/macatocz/makato/commit/25ccecef5218e0c26848447e89bf4fb6e2579319))
* **makato-build:** skill passport + build-verify advisory gate + concurrent-write guard ([#147](https://github.com/macatocz/makato/issues/147)) ([25ccece](https://github.com/macatocz/makato/commit/25ccecef5218e0c26848447e89bf4fb6e2579319))
* **makato-build:** skill_passport hierarchical writer + transitive rollup + concurrent-write guard ([#147](https://github.com/macatocz/makato/issues/147)) ([c4ca1a7](https://github.com/macatocz/makato/commit/c4ca1a767ce079a5f2772f9e6ecd9455fe972378))
* **makato-orchestrate:** light-planner agent + plan-gated seed-issue promotion ([#212](https://github.com/macatocz/makato/issues/212)) ([9fd92fb](https://github.com/macatocz/makato/commit/9fd92fb4d26a61beb237510972c16f0b85b681f3))
* **makato-orchestrate:** light-planner agent + plan-gated seed-issue promotion ([#212](https://github.com/macatocz/makato/issues/212)) ([d4b7f07](https://github.com/macatocz/makato/commit/d4b7f073d9b5a898d24cd9896c01235ef2a8f5ad))

## [Unreleased]

### ✨ Features

* **makato-build:** agent skill routing F3 — skill-passport writer + advisory provenance gate ([#147](https://github.com/macatocz/makato/issues/147)): skill-routed agents write `skill-passport.json` nodes (gated by `should_emit_f4_log`); `build-verify` Step 9 compares `skills_invoked_transitively` (via `compute_rollup`) against `skills_expected` (resolved from git diff via `skill-bundles.yml`) and emits advisory warnings per missing skill — gate never fails the build (NFR-R2); `definition-of-done` v2.0.0 adds item 13 (skill-provenance recorded and complete).

## [0.38.0](https://github.com/macatocz/makato/compare/v0.37.0...v0.38.0) (2026-07-10)


### ✨ Features

* **makato-build:** spec_tier:plan-only gate in build-refine ([#210](https://github.com/macatocz/makato/issues/210)) ([cad24ed](https://github.com/macatocz/makato/commit/cad24ed527c1c528a06d93bb2a319cb3adbffef1))
* **makato-build:** spec_tier:plan-only gate in build-refine ([#210](https://github.com/macatocz/makato/issues/210)) ([d5336f6](https://github.com/macatocz/makato/commit/d5336f6ca2ba16b69192fb0fd94cd5fd6d01d2dd))
* **makato-plan:** bootstrap task-skill-map.json with 200+ archetype→skills entries ([#146](https://github.com/macatocz/makato/issues/146)) ([5307218](https://github.com/macatocz/makato/commit/53072189e74619fd8b570eedfbabee771140e872))
* **makato:** agent skill routing F2 — skill propagation chain ([#146](https://github.com/macatocz/makato/issues/146)) ([3fd1958](https://github.com/macatocz/makato/commit/3fd1958aa77396deb815b947150735d7a35833b0))
* **makato:** agent skill routing F2 — skill propagation chain ([#146](https://github.com/macatocz/makato/issues/146)) ([3fd1958](https://github.com/macatocz/makato/commit/3fd1958aa77396deb815b947150735d7a35833b0))


### 🐛 Bug Fixes

* **makato-orchestrate:** add --output-format text to loop.sh dispatch ([8cba7b0](https://github.com/macatocz/makato/commit/8cba7b0f03f63724892c67351ae9ece3a8e83785))
* **makato-orchestrate:** add --output-format text to loop.sh dispatch ([62d9bfa](https://github.com/macatocz/makato/commit/62d9bfa3ee57f4ebac7ee585796abed8fd3d2acd))
* **makato-orchestrate:** keep background po-agent alive past 600s ceiling ([#209](https://github.com/macatocz/makato/issues/209)) ([5143464](https://github.com/macatocz/makato/commit/51434643188611af1473a606e5105f48064f5ed9))

## [0.37.0](https://github.com/macatocz/makato/compare/v0.36.1...v0.37.0) (2026-07-09)


### ✨ Features

* **makato-orchestrate,makato-change:** hand-filed issue support + routing + AUTONOMOUS-MODE ([0ccf02d](https://github.com/macatocz/makato/commit/0ccf02dcbae26d4c8af268abf387cd1e01302682))
* **makato-orchestrate,makato-change:** hand-filed issue support + routing + AUTONOMOUS-MODE ([#144](https://github.com/macatocz/makato/issues/144)) ([d2fd759](https://github.com/macatocz/makato/commit/d2fd759ad7541ccbdcd43567fc928fa79279c7c2))
* **makato-plan:** autonomous status:ready-for-dev label stamp in issue-to-project (v2.8.0) ([8699d45](https://github.com/macatocz/makato/commit/8699d458b03f13d268e75e5204db4d2f4eaa40e6))
* **makato-plan:** autonomous status:ready-for-dev label stamp in issue-to-project (v2.8.0) ([97a94fd](https://github.com/macatocz/makato/commit/97a94fd67f3879c14b094688f6ae0b9be00725e2))
* **makato:** add skill-bundles.yml for remaining plugins ([#145](https://github.com/macatocz/makato/issues/145)) ([cdbf2d2](https://github.com/macatocz/makato/commit/cdbf2d27f949049e68474490f8353b5fdbcd2a30))
* **makato:** rollout skill-bundles.yml to all plugins + aggregate test ([#145](https://github.com/macatocz/makato/issues/145)) ([ebd0a86](https://github.com/macatocz/makato/commit/ebd0a864866a495072114b31756e1bc9c598c041))


### 🐛 Bug Fixes

* **makato-plan:** replace dangling /publish refs with /to-issues ([#203](https://github.com/macatocz/makato/issues/203)) ([00443a2](https://github.com/macatocz/makato/commit/00443a2b75cd8fc707c2b502c6b7b3c442782b43))
* **makato-plan:** replace dangling /publish refs with /to-issues ([#203](https://github.com/macatocz/makato/issues/203)) ([24f0fe2](https://github.com/macatocz/makato/commit/24f0fe2e4c65446fee00f79a39899fb29e94c0f7))

## [0.36.1](https://github.com/macatocz/makato/compare/v0.36.0...v0.36.1) (2026-07-09)


### 🐛 Bug Fixes

* **makato-orchestrate:** thread po-agent input bundle into loop dispatch ([#144](https://github.com/macatocz/makato/issues/144)) ([#198](https://github.com/macatocz/makato/issues/198)) ([b55f2c6](https://github.com/macatocz/makato/commit/b55f2c6f43f3cbd812d9c01441d351cbe4590d95))

## [0.36.0](https://github.com/macatocz/makato/compare/v0.35.0...v0.36.0) (2026-07-09)


### ✨ Features

* **makato-build:** real inject-skills resolver + validator ([#144](https://github.com/macatocz/makato/issues/144)) ([#196](https://github.com/macatocz/makato/issues/196)) ([1803f84](https://github.com/macatocz/makato/commit/1803f845fb54d180097b5a3e1386628b278b0b05))

## [0.35.0](https://github.com/macatocz/makato/compare/v0.34.0...v0.35.0) (2026-07-09)


### ✨ Features

* **makato-orchestrate/makato-core:** archive-spec skill + hooks/ + GHA workflow ([#194](https://github.com/macatocz/makato/issues/194)) ([836f5fa](https://github.com/macatocz/makato/commit/836f5faa96dd51f9f0e9287c3b65416b9c3f0f93))

## [0.34.0](https://github.com/macatocz/makato/compare/v0.33.0...v0.34.0) (2026-07-09)


### ✨ Features

* board Ready → In progress via assign-on-dispatch + project-board-sync workflow ([#33](https://github.com/macatocz/makato/issues/33)) ([#191](https://github.com/macatocz/makato/issues/191)) ([0b9f341](https://github.com/macatocz/makato/commit/0b9f341bdff08ae38c2bf0925b44e51912cc0f1e))

## [0.33.0](https://github.com/macatocz/makato/compare/v0.32.0...v0.33.0) (2026-07-09)


### ✨ Features

* **create-ux:** delegate medium/high-fi wireframes to penpot-uiux-design ([#190](https://github.com/macatocz/makato/issues/190)) ([7d5fc66](https://github.com/macatocz/makato/commit/7d5fc66ac80ea129df3e4f29e4f579534309d352))

## [0.32.0](https://github.com/macatocz/makato/compare/v0.31.3...v0.32.0) (2026-07-09)


### ✨ Features

* **makato-orchestrate:** PO-agent HALT-011 audit-tail guard ([#175](https://github.com/macatocz/makato/issues/175)) ([#189](https://github.com/macatocz/makato/issues/189)) ([2bcd607](https://github.com/macatocz/makato/commit/2bcd607f1dd09762fcbf38e40495d9f7ecb5ee5b))


### 🐛 Bug Fixes

* **makato-orchestrate:** loop.sh sleep-wake dispatch guard ([#171](https://github.com/macatocz/makato/issues/171)) ([#186](https://github.com/macatocz/makato/issues/186)) ([c1218db](https://github.com/macatocz/makato/commit/c1218db61b9adcb217e822e9effa7a163330e6f6))
* **makato-ux:** update penpot-uiux-design skill for cloud MCP ([#188](https://github.com/macatocz/makato/issues/188)) ([0a2a454](https://github.com/macatocz/makato/commit/0a2a4542cc4b8ac36360a92e606d1f37200737d9))

## [0.31.3](https://github.com/macatocz/makato/compare/v0.31.2...v0.31.3) (2026-07-08)


### 🐛 Bug Fixes

* **ci:** fall back to GITHUB_TOKEN when RELEASE_PLEASE_PAT is unset ([#184](https://github.com/macatocz/makato/issues/184)) ([75ae631](https://github.com/macatocz/makato/commit/75ae63143b6e40d1b6ca1eb4facf370109c48528))


### 🤖 CI

* auto-merge release-please PRs (single-branch main flow) ([#181](https://github.com/macatocz/makato/issues/181)) ([#182](https://github.com/macatocz/makato/issues/182)) ([84ebc85](https://github.com/macatocz/makato/commit/84ebc85bbbdf206e2dd969aa9bd0c8f391bc0c90))

## [0.31.2](https://github.com/macatocz/makato/compare/v0.31.1...v0.31.2) (2026-07-08)


### 🐛 Bug Fixes

* **makato-orchestrate:** per-issue workflow-state file layout ([#173](https://github.com/macatocz/makato/issues/173)) ([#179](https://github.com/macatocz/makato/issues/179)) ([7fc7722](https://github.com/macatocz/makato/commit/7fc7722d4d5b0e0bc6cee94be5d0f9bf3bfbdcd8))

## [0.31.1](https://github.com/macatocz/makato/compare/v0.31.0...v0.31.1) (2026-07-08)


### 🐛 Bug Fixes

* **makato-orchestrate:** loop.sh run-mutex pidfile guard ([#172](https://github.com/macatocz/makato/issues/172)) ([#178](https://github.com/macatocz/makato/issues/178)) ([f0c19fb](https://github.com/macatocz/makato/commit/f0c19fb7148a30002dbbc5459bc36cf591e57a2b))
* **makato-orchestrate:** three-layer PO-agent worktree-isolation defence ([#170](https://github.com/macatocz/makato/issues/170)) ([#176](https://github.com/macatocz/makato/issues/176)) ([4cada7d](https://github.com/macatocz/makato/commit/4cada7d5aac892df818f147ba5a56b7fc84aad46))

## [0.31.0](https://github.com/macatocz/makato/compare/v0.30.1...v0.31.0) (2026-07-08)


### ✨ Features

* **makato-build:** add skill-bundles.yml with empty default bundle (D29) ([#168](https://github.com/macatocz/makato/issues/168)) ([5747402](https://github.com/macatocz/makato/commit/5747402d50e09c2337e225442a721a9978e468fc))
* **makato-orchestrate:** loop.sh liveness watchdog for stalled PO-agent ([#164](https://github.com/macatocz/makato/issues/164)) ([#166](https://github.com/macatocz/makato/issues/166)) ([f8c7ca7](https://github.com/macatocz/makato/commit/f8c7ca77bd982c1268cc8a1c3b414ecc880b3ffb))


### 🐛 Bug Fixes

* **makato-build:** mandatory audit contract around gh pr create ([#169](https://github.com/macatocz/makato/issues/169)) ([#174](https://github.com/macatocz/makato/issues/174)) ([f1c974e](https://github.com/macatocz/makato/commit/f1c974e2e069aaf20c1b8d56147a24a53bf98279))

## [0.30.1](https://github.com/macatocz/makato/compare/v0.30.0...v0.30.1) (2026-07-07)


### 🐛 Bug Fixes

* build-refine headless-context defensive guard ([#163](https://github.com/macatocz/makato/issues/163)) ([#165](https://github.com/macatocz/makato/issues/165)) ([919c325](https://github.com/macatocz/makato/commit/919c3253f3cc19a2626e93d719290696bccb3d05))
* **makato-orchestrate:** dispatch po-agent explicitly instead of bare prompt ([#160](https://github.com/macatocz/makato/issues/160)) ([#161](https://github.com/macatocz/makato/issues/161)) ([ca8b02a](https://github.com/macatocz/makato/commit/ca8b02a2807fa1be67ead753d8957f5c1d8f2fa3))
* **makato-orchestrate:** route gh project item-list host via GH_HOST ([#156](https://github.com/macatocz/makato/issues/156)) ([#159](https://github.com/macatocz/makato/issues/159)) ([fbcb965](https://github.com/macatocz/makato/commit/fbcb96529d36bd4e742829c628d62359dc81bf7d))

## [0.30.0](https://github.com/macatocz/makato/compare/v0.29.1...v0.30.0) (2026-07-07)


### ✨ Features

* **makato-build:** skill_routing opt-out parser ([#142](https://github.com/macatocz/makato/issues/142)) ([#157](https://github.com/macatocz/makato/issues/157)) ([d1c530f](https://github.com/macatocz/makato/commit/d1c530fca43f05b65e579d412184b847eaba224c))

## [0.29.1](https://github.com/macatocz/makato/compare/v0.29.0...v0.29.1) (2026-07-07)


### 🐛 Bug Fixes

* **makato-orchestrate:** replace non-existent claude --session/--autonomous flags ([#152](https://github.com/macatocz/makato/issues/152)) ([#154](https://github.com/macatocz/makato/issues/154)) ([d8ddec9](https://github.com/macatocz/makato/commit/d8ddec9c055ab743293822ec404e2c5478369e6a))

## [0.29.0](https://github.com/macatocz/makato/compare/v0.28.2...v0.29.0) (2026-07-06)


### ✨ Features

* **makato-observability:** initial plugin with governance ([#128](https://github.com/macatocz/makato/issues/128)) ([77704a0](https://github.com/macatocz/makato/commit/77704a0331ce02fec235d7dc7ba7c7c6121da578))


### 🐛 Bug Fixes

* **makato-build:** build-simplify Step 3 dispatches gate-scout authoritatively, baseline row carries data.cmd ([#97](https://github.com/macatocz/makato/issues/97)) ([#112](https://github.com/macatocz/makato/issues/112)) ([e6cf64b](https://github.com/macatocz/makato/commit/e6cf64bef2c2a2a91a2987b56114ddde7ac331cb))

## [0.28.2](https://github.com/macatocz/makato/compare/v0.28.1...v0.28.2) (2026-06-30)


### 🐛 Bug Fixes

* **makato-orchestrate:** route Step 6a CI-failure fix through build-implement-tdd ([#119](https://github.com/macatocz/makato/issues/119)) ([#120](https://github.com/macatocz/makato/issues/120)) ([8848ba7](https://github.com/macatocz/makato/commit/8848ba7f876c510f9b65df99933d09a4ae4350e7))


### ♻️ Refactors

* **makato-build:** add log-bypass.sh helper to replace inline autonomous_bypass JSON literals ([#116](https://github.com/macatocz/makato/issues/116)) ([#122](https://github.com/macatocz/makato/issues/122)) ([ae90a5c](https://github.com/macatocz/makato/commit/ae90a5c5e8c75c4d9cc934b05544c7dd0eda302b))
* **makato-build:** consolidate HALT-code registry across orchestrate + build skills ([#115](https://github.com/macatocz/makato/issues/115)) ([#124](https://github.com/macatocz/makato/issues/124)) ([87a7961](https://github.com/macatocz/makato/commit/87a7961780e908463cd6671c7c129f2d105f7dff))
* **makato-build:** extract shared mode-detection, entry-guard, and R1-envelope references ([#114](https://github.com/macatocz/makato/issues/114)) ([#121](https://github.com/macatocz/makato/issues/121)) ([14d3b14](https://github.com/macatocz/makato/commit/14d3b14a08e170cd6f6b08f370391d238ee4d377))
* **makato-build:** stop forwarding --autonomous across cross-skill dispatch ([#117](https://github.com/macatocz/makato/issues/117)) ([#125](https://github.com/macatocz/makato/issues/125)) ([1759ae5](https://github.com/macatocz/makato/commit/1759ae583d203129251da2f56f57df4afd00bb4b))
* **makato-orchestrate:** add workflow-state.sh append-halt + build-log.sh --batch ([#118](https://github.com/macatocz/makato/issues/118)) ([#126](https://github.com/macatocz/makato/issues/126)) ([d528ef3](https://github.com/macatocz/makato/commit/d528ef330c25e0126ba50e28377d7c20c0c677b9))

## [0.28.1](https://github.com/macatocz/makato/compare/v0.28.0...v0.28.1) (2026-06-29)


### 🐛 Bug Fixes

* **makato-build:** diff against origin/&lt;default-branch&gt;, never bare local main ([#98](https://github.com/macatocz/makato/issues/98)) ([#109](https://github.com/macatocz/makato/issues/109)) ([1ed87df](https://github.com/macatocz/makato/commit/1ed87dffc96abd94b23117f5665055272a0f400f))

## [0.28.0](https://github.com/macatocz/makato/compare/v0.27.0...v0.28.0) (2026-06-29)


### ✨ Features

* **makato-orchestrate:** merge-conflict detection and rebase resolution in po-agent (GAP-016, [#45](https://github.com/macatocz/makato/issues/45)) ([#106](https://github.com/macatocz/makato/issues/106)) ([8aac61a](https://github.com/macatocz/makato/commit/8aac61ab0da5c799044c6f61542b96d120ca5793))


### 🐛 Bug Fixes

* **makato-build:** ship specs/**/build.jsonl in-repo so audit trail is reproducible ([#99](https://github.com/macatocz/makato/issues/99)) ([#108](https://github.com/macatocz/makato/issues/108)) ([7971053](https://github.com/macatocz/makato/commit/79710530b370b7798a9f90a8763a4a7f5e557a63))

## [0.27.0](https://github.com/macatocz/makato/compare/v0.26.0...v0.27.0) (2026-06-29)


### ✨ Features

* **makato-build:** re-merge dogfood pytest harness onto main (GAP-064 Part B; closes [#64](https://github.com/macatocz/makato/issues/64), [#58](https://github.com/macatocz/makato/issues/58)) ([#104](https://github.com/macatocz/makato/issues/104)) ([7abf138](https://github.com/macatocz/makato/commit/7abf138791fc100023f70c0280d34fdc49c44f11))

## [0.26.0](https://github.com/macatocz/makato/compare/v0.25.0...v0.26.0) (2026-06-29)


### ✨ Features

* **makato-build:** build-simplify no-test-runner handling (GAP-064 / [#64](https://github.com/macatocz/makato/issues/64) — Part A) ([#100](https://github.com/macatocz/makato/issues/100)) ([39fb4b8](https://github.com/macatocz/makato/commit/39fb4b8934896476a48887c96f08ec8aa8a112c9))

## [0.25.0](https://github.com/macatocz/makato/compare/v0.24.0...v0.25.0) (2026-06-29)


### ✨ Features

* **makato-build:** headless PR-comment handling in autonomous mode (GAP-011, [#36](https://github.com/macatocz/makato/issues/36)) ([#96](https://github.com/macatocz/makato/issues/96)) ([36205cd](https://github.com/macatocz/makato/commit/36205cdaed985723a22b6b45b6c9168287f64933))
* **makato-orchestrate:** CI-failure and review-decision outer fix loops in po-agent (GAP-010, [#34](https://github.com/macatocz/makato/issues/34)) ([#94](https://github.com/macatocz/makato/issues/94)) ([6c1dc42](https://github.com/macatocz/makato/commit/6c1dc427d9dcf0a6bce3b866d3594c9879ee19ed))

## [0.24.0](https://github.com/macatocz/makato/compare/v0.23.1...v0.24.0) (2026-06-29)


### ✨ Features

* **makato-orchestrate:** session-status SessionStart hook (GAP-014, [#31](https://github.com/macatocz/makato/issues/31)) ([#92](https://github.com/macatocz/makato/issues/92)) ([3cebbb1](https://github.com/macatocz/makato/commit/3cebbb1622122464875191b8a9cfb9dba08d947d))

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

* **makato-build:** finding-routes autofix audit; residual MD0xx→makato-doc:markdown ([#59](https://github.com/macatocz/makato/issues/59)) ([#62](https://github.com/macatocz/makato/issues/62)) ([9239c4f](https://github.com/macatocz/makato/commit/9239c4fdf5a82863873fc99850333fe4df221e1e))

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
