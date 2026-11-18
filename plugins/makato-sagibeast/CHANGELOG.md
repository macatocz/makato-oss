# Changelog — makato-sagibeast

## [Unreleased]

### Fixed
- **`dotx-schema-extractor` tests are collectable again from the repo-level `pytest` run.** `tests/conftest.py` now inserts the skill root (parent of `tests/`) at `sys.path[0]` so the sibling `scripts` package resolves (`from scripts.curation_* import ...`) — the previous conftest only added the `tests/` dir (for `fixtures`), leaving five test modules failing collection with `ModuleNotFoundError: No module named 'scripts.curation_*'` and interrupting the whole repo suite. Position-0 insertion wins over the many other bare `scripts/` dirs across the monorepo under pytest's prepend import mode.

### Added
- `sagibeast-migrate-instance` 1.0.0 — operator runbook for moving a live Sagibeast deployment
  between Vast.ai instances: one batched owner-decision round (hardware, move-don't-upgrade
  release, cold-sync backup, custody, rotation, window, source destruction), parallel access setup,
  target provisioning, `vast-host-move.sh` preflight/images/warm and cold sync, scripted cutover
  with expected durations and rollback, post-cutover runners/reboot/cleanup, JSONL audit in the
  host-move receipts directory, and `references/pitfalls.md` (symptom → cause → fix). Operator-gated,
  so not registered in `config/skill-bundles.yml` or `task-skill-map.json`.
- `sagibeast-refresh-runtime` 1.0.0 — safely refresh deployed code and recreate application
  services, workers and network dependents, with read-only inspection and runtime verification.
- `config/skill-bundles.yml` (#145) — bundles `sagibeast-skills`, `sagibeast-word-templates`, `sagibeast-excel`, `sagibeast-pdf`, `sagibeast-testbox` route Word/PDF/Excel/YAML/SH files to the appropriate Sagibeast skills via the inject-skills resolver.
- `sagibeast-connect-testbox` skill — connect, port-forward, credential sync, k3d on existing testbox
- `sagibeast-create-testbox` skill — provision Multipass/EC2/Hetzner testbox VM for E2E parity

### Changed

- `sagibeast-refresh-runtime` — **1.0.0 → 1.0.1**
  - frozen runtime images must be rebuilt when `pyproject.toml`/`uv.lock` change (guard error
    `FATAL: /app/pyproject.toml differs`); host moves point to `sagibeast-migrate-instance`
- README skill catalog: versions aligned with SKILL.md (connect-testbox 1.1.0, create-testbox
  2.0.0, excel 1.1.0, pdf 1.1.0); added `sagibeast-refresh-runtime` and `sagibeast-migrate-instance`
  rows. AGENTS.md "What Belongs Here"/file structure list the deployment-operations skills.
- Repo `scripts/vast-provision-all.sh` refuses hosts that carry `/etc/default/sagibeast`
  (production or migrated installs); `docs/vast-ai-access.md` drops the stale instance table and
  nightly-stop text and points to `sagibeast-migrate-instance`.

- `sagibeast-connect-testbox` — **1.0.1 → 1.1.0**
  - added navigation table mapping goals to arguments/steps
  - added 10 NEVER anti-patterns covering silent session freezes, tmux discipline, bilateral PG port-forward confusion, tenant skill tree detection, background tunnel flag discipline, credential sync ordering, k3d/production cluster cross-connection, per-developer namespace discipline, agent forwarding scope, and ForwardAgent requirement
  - added no-argument routing via `AskUserQuestion` to avoid silently running the full workflow
  - terminology aligned with ADR-0020 (bilateral PG split) and ADR-0024 (L1/L2/L3 layer naming)
  - added `## Output Audit Entry` section with JSONL template covering connect, port-forward, sync-creds, k3d, step-ca, ide, and tmux events

- `sagibeast-create-testbox` — **1.1.0 → 1.2.0**
  - added `## Output Audit Entry` section with JSONL template covering preflight, cloud-init, launch, ssh-config, bootstrap, and runner-register events
  - fixed `sed` invocation in step [2/5] "Prepare cloud-init" to be portable across macOS (BSD sed, requires `-i ''`) and Linux (GNU sed, uses plain `-i`); replaced single cross-platform command with an OS-detection block; removed the manual "Replace `sed -i ''` with `sed -i` on Linux" note

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
