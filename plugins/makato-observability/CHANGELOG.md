# Changelog — makato-observability

<!-- markdownlint-disable MD013 -->

## [Unreleased]

### Added

- `langfuse-instrument` skill — wires OpenTelemetry SDK to a Langfuse OTLP HTTP endpoint for LangGraph-based agents (see the skill's SKILL.md for the 7-step workflow)
- 6 references under `skills/langfuse-instrument/references/`: `deployment-paths.md`, `langgraph-otel-integration.md`, `otel-setup.md`, `span-attribute-conventions.md`, `inprocess-exporter.md`, `troubleshooting.md`
- 3 templates under `skills/langfuse-instrument/templates/`: `otel-setup.py`, `otel-inprocess-exporter.py`, `env-local.example`

### Changed

- AGENTS.md § Goal / How / Why rewritten to name the primary code path as "OpenTelemetry SDK + OTLP HTTP export" (was: "native LangChain-callback bridge"). LangGraph consumers in scope run without the LangChain wrapper; the callback recipe does not apply and is now explicitly out of scope.
- Plugin description in `plugin.json` and `.claude-plugin/marketplace.json` synced to the OTel-SDK framing.
- Decision test tightened to "…observable at runtime through OpenTelemetry (typically exporting to Langfuse via OTLP)…"

## [0.1.0] — 2026-07-06

### Added

- Initial plugin scaffold with governance files
- Plugin manifest (`plugin.json`) with vendor-neutral description
- Contributor guide (`AGENTS.md`) including § *Langfuse deployment stance*
- Contributor + user documentation (`README.md`)
- `shared/` directory placeholder for the future semantic-conventions catalogue, cardinality-budget templates, and span-attribute conventions
- `skills/` directory placeholder — first planned skill (`langfuse-instrument` via OpenTelemetry SDK + OTLP HTTP export to a Langfuse endpoint) added via `makato-skill-creator` in a follow-up PR
- Marketplace registration in `.claude-plugin/marketplace.json`
- Marketplace registration in `.claude-plugin/marketplace.json`
