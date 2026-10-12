# makato-sagibeast

**Goal**: Provide skills for the Sagibeast (CMAI) platform covering contract document processing
(Word/PDF/Excel), testbox environment provisioning and connection, and integration with the CMAI
contract management system.

**How**: Through structured prompts and workflows that guide contract creation, document extraction
and sorting, review and lifecycle management, time and financial-claims evaluation — plus
testbox-provisioning and connection skills that give CMAI agents the development environments they
run those contract workflows in.

**Why**: Reduces manual effort and errors in contract workflows by giving CMAI agents the skills
to handle contracts end-to-end.

## What Belongs Here

- Drafting contracts and contract templates from structured inputs
- Summarizing contracts and generating manager-level briefings
- Evaluating financial claims, pricing, and cost items within contracts
- Analyzing facts (skutecnost) and critical paths in contract timelines
- Document extraction and recognition (OCR, PDF, Office documents) applied to contracts
- Citation and retrieval of contract knowledge from a vector database
- Price evaluation — querying price databases and validating typical market prices
- Sorting and classifying contract documents into structured categories
- Testbox VM provisioning and connectivity for CMAI agents

## What Does NOT Belong Here

- General-purpose UX creation or visual design skills
- General database schema definition (CMAI-related schemas may live here)
- Generic document editing tools with no contract-management context
- Skills that produce outputs not usable within a contract management workflow
- Skills already covered by other makato plugins (build, plan, change)

## Workflow

Two independent track — document processing and testbox environment management:

```
Document processing
─────────────────────────────────────────────────────────────────────
 .dotx / .docx template
        │
        ▼
 ┌────────────────────────┐
 │ dotx-schema-extractor  │  Input:  .dotx or .docx file path
 └────────────────────────┘  Output: schema.json + optional summary

 PDF file(s)
        │
        ▼
 ┌────────────────────────┐
 │ manage-pdf             │  Input:  PDF file(s), desired operation
 └────────────────────────┘  Output: processed PDF / extracted text

 Spreadsheet file
        │
        ▼
 ┌────────────────────────┐
 │ manage-microsoft-excel │  Input:  .xlsx / .csv / .tsv file path
 └────────────────────────┘  Output: cleaned / restructured spreadsheet


Testbox environment management
─────────────────────────────────────────────────────────────────────
 Provider choice (Multipass / EC2 / Hetzner)
        │
        ▼
 ┌────────────────────────────┐
 │ sagibeast-create-testbox   │  Input:  provider, optional cpu/mem/disk
 └────────────┬───────────────┘  Output: provisioned VM + ~/.ssh/config entry
              │
              ▼
 ┌────────────────────────────┐
 │ sagibeast-connect-testbox  │  Input:  testbox VM (provisioned above)
 └────────────────────────────┘  Output: SSH session / port-forward / k3d
```

## Skills

### Runtime refresh

Use `/sagibeast-refresh-runtime [host] [revision] [--check-only]` to apply the latest
Sagibeast code to an existing Compose deployment. It discovers the deployed checkout and
upstream, preserves local changes and data, rebuilds images, recreates application services
and network dependents, and verifies freshness and behavior. Version: 1.0.0.

See [the refresh workflow](skills/sagibeast-refresh-runtime/SKILL.md).

### Skill catalog

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`dotx-schema-extractor`](skills/dotx-schema-extractor/SKILL.md) | Extract a JSON schema from a Word `.dotx` or `.docx` template by inventorying every variable field — content controls (SDT), MERGEFIELDs, DOCPROPERTY, plain-text placeholder patterns (`{{var}}`, `[VAR]`, `<VAR>`), colored-highlighted instructions, and Word comments. (interactive) | A `.dotx` or `.docx` Word template file path | JSON schema (`schema.json`) listing all fillable variable fields with key, label, kind, and optional repeats; plus an optional human-readable summary markdown | 1.0.0 |
| [`manage-microsoft-excel`](skills/manage-microsoft-excel/SKILL.md) | Use any time a spreadsheet file is the primary input or output — open, read, edit, fix, or create `.xlsx`/`.xlsm`/`.csv`/`.tsv` files; add columns, compute formulas, reformat, chart, clean messy data, or convert between tabular formats. Deliverable must be a spreadsheet file. (interactive) | Existing `.xlsx`/`.xlsm`/`.csv`/`.tsv` file path, or description of a spreadsheet to create from scratch | Modified or newly created `.xlsx`/`.csv` spreadsheet with zero formula errors and professional formatting | 1.0.0 |
| [`manage-pdf`](skills/manage-pdf/SKILL.md) | Handle any PDF operation — reading or extracting text/tables, combining or merging multiple PDFs, splitting, rotating pages, adding watermarks, creating new PDFs, filling PDF forms, encrypting/decrypting, extracting images, and OCR on scanned PDFs. (interactive) | One or more PDF file paths; optionally desired operation (merge, split, rotate, fill form, OCR, encrypt, extract) | Processed PDF file(s), extracted text/tables as text or structured data, or OCR'd searchable PDF | 1.0.0 |
| [`sagibeast-connect-testbox`](skills/sagibeast-connect-testbox/SKILL.md) | Connect to or resume an existing sagibeast testbox VM — handles SSH session, port-forwarding, 1Password credential sync, k3d cluster bootstrap, step-ca trust, and IDE remote-dev setup (VSCode, JetBrains). (interactive) | Existing testbox VM provisioned via `sagibeast-create-testbox`; optional flags: `port-forward <local>:<remote>`, `--sync-creds`, `--k3d`, `--step-ca`, `--ide vscode`, `--ide jetbrains`, `--tmux` | Active SSH session, established port-forward tunnel, bootstrapped k3d cluster, or synced credentials depending on argument | 1.0.1 |
| [`sagibeast-create-testbox`](skills/sagibeast-create-testbox/SKILL.md) | Provision a new sagibeast testbox VM (Multipass, EC2, or Hetzner) for E2E parity testing when Docker Compose on host is insufficient — cross-node ADR-0023 perimeter, team-shared long-running E2E rigs, or stable-egress-IP scenarios. (interactive) | Provider choice (Multipass / EC2 / Hetzner); optional: runtime, cpus, memGB, diskGB, os | Provisioned and configured testbox VM accessible via SSH as `sagibeast.testbox`; SSH config entry added to `~/.ssh/config` | 1.0.0 |

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-sagibeast/AGENTS.md` | Governance file — goal, what belongs/does not, skill authoring rules, file structure, versioning policy, and PR checklist |
| `plugins/makato-sagibeast/.claude-plugin/plugin.json` | Plugin manifest — name, description, author; no version field (repo versioned via release-please) |
| `plugins/makato-sagibeast/README.md` | User-facing documentation — goal, workflow diagram, skills table, plugin connections, prerequisites, installation, and version |
| `plugins/makato-sagibeast/CHANGELOG.md` | Version history updated with each PR per plugin convention |
| `plugins/makato-sagibeast/CLAUDE.md` | Routes to AGENTS.md via `@AGENTS.md` include directive |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|------------|
| Complementary | `makato-build` | Testbox VMs provisioned by makato-sagibeast are the runtime environment where makato-build deploys and tests CMAI agents |
| Complementary | `makato-langgraph` | LangGraph-based CMAI agents are built with makato-langgraph skills; makato-sagibeast provides the hosting and testbox environment they run in |

## Prerequisites / MCP Servers

| Server | Purpose | Required |
|--------|---------|----------|
| `sagibeast-cmai` | Placeholder for CMAI external system integration — not yet configured. Configure the server connection in `.mcp.json` before use. | No |

External prerequisites:

- Multipass, AWS EC2, or Hetzner account for testbox VM provisioning (`sagibeast-create-testbox`)
- 1Password CLI (`op`) installed and authenticated for credential sync (`sagibeast-connect-testbox --sync-creds`)
- LibreOffice installed for Excel formula recalculation (`manage-microsoft-excel`)
- Python with `pypdf`, `pdfplumber`, and OCR tooling for PDF processing (`manage-pdf`)
- Python with `python-docx` or direct OOXML parsing for Word template extraction (`dotx-schema-extractor`)
- `sagibeast-cmai` MCP server configured in `.mcp.json` before CMAI external system integration

## Installation

```bash
claude --plugin-dir ./plugins/makato-sagibeast
```

## Version

0.1.0
