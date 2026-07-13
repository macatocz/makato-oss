# Changelog — makato-temporal

## [Unreleased]

### Added
- `config/skill-bundles.yml` — skill-routing bundles consumed by makato-build
  inject-skills. A `temporal-skills` bundle routes the `temporal-development`
  skill when editing the plugin's own skill files, and a `temporal-code` bundle
  routes it for Temporal SDK code (Python, TypeScript, Java, Rust) via
  `contains:` file-content hints plus `task_contains:` task-text routing. Closes
  the D22 bundle-coverage gap (13/13 plugins).

## [0.1.0] — 2026-07-12

### Added
- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- `temporal-development` skill migrated from `makato-langgraph`, pruned to Python, TypeScript, Java, Rust, and core references, aligned to makato standards and the sagibeast durable-execution architecture
