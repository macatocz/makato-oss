# Changelog — makato-sagibeast

## [Unreleased]

### Added
- `config/skill-bundles.yml` (#145) — bundles `sagibeast-skills`, `sagibeast-word-templates`, `sagibeast-excel`, `sagibeast-pdf`, `sagibeast-testbox` route Word/PDF/Excel/YAML/SH files to the appropriate Sagibeast skills via the inject-skills resolver.
- `sagibeast-connect-testbox` skill — connect, port-forward, credential sync, k3d on existing testbox
- `sagibeast-create-testbox` skill — provision Multipass/EC2/Hetzner testbox VM for E2E parity

### Changed

- `sagibeast-create-testbox` — **1.0.0 → 1.1.0** (#572)
  - documented the GitHub Actions runner label contract: registration MUST pass `--labels self-hosted,sagibeast-testbox` explicitly (the custom label is not derived from the runner name). Added a fourth "provision completely" mindset item and a `config.sh --labels …` registration step with a verify line under [6/6]. Without the label, testbox-routed workflows (`post-merge.yml` etc.) hang `queued` for GitHub's 24 h ceiling and surface a red `sync-status` check on every PR.

### Changed — sagibeast-alignment audit (2026-06-25)

- `sagibeast-connect-testbox` — **1.0.0 → 1.0.1**
  - replaced "Docker Compose locally (Track 1)" with "Docker Compose locally (L2 — ADR-0024)" to match ADR-0024 three-layer naming (L1/L2/L3)
  - fixed port-forward caution: "two Brain-PG instances exist in staging" → "Brain-PG (Class A) and Body-PG (Class B) are separate instances" to accurately reflect ADR-0020 bilateral PG split

## [0.1.0] — 2026-06-22

### Added
- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- MCP server declarations (sagibeast-cmai placeholder)
- Shared directory scaffold for document utilities (OCR, PDF, Office)
