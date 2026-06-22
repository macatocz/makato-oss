# makato-sagibeast

**Goal**: Provide contract management skills for the Sagibeast (CMAI) platform.

**How**: Through structured prompts and workflows that guide contract creation, document sorting, reviewing contracts, lifecycle management, time evaluation, and financial claims evaluation within the CMAI platform.

**Why**: Reduces manual effort and errors in contract workflows by giving CMAI agents the skills to handle contracts end-to-end.

## What Belongs Here

- Drafting contracts and contract templates from structured inputs
- Summarizing contracts and generating manager-level briefings
- Evaluating financial claims, pricing, and cost items within contracts
- Analyzing facts (skutečnost) and critical paths in contract timelines
- Document extraction and recognition (OCR, PDF, Office documents) applied to contracts
- Citation and retrieval of contract knowledge from a vector database
- Price evaluation — querying price databases and validating typical market prices
- Sorting and classifying contract documents into structured categories

## What Does NOT Belong Here

- General-purpose UX creation or visual design skills
- Database schema definition or infrastructure provisioning
- Generic document editing tools with no contract-management context
- Skills that produce outputs not usable within a contract management workflow
- Skills already covered by other makato plugins (build, plan, change)

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `sagibeast-connect-testbox` | Connect to or resume a sagibeast testbox VM — SSH, port-forward, credential sync, k3d | 1.0.0 |
| `sagibeast-create-testbox` | Provision a sagibeast testbox VM (Multipass, EC2, or Hetzner) for E2E parity testing | 1.0.0 |

## Prerequisites

### MCP Servers

This plugin declares the following MCP servers:

| Server | Purpose |
|--------|---------|
| `sagibeast-cmai` | Placeholder — CMAI external system integration (not yet configured) |

Configure the server connection in `.mcp.json` before use.

## Installation

```bash
claude --plugin-dir ./plugins/makato-sagibeast
```

## Version

0.1.0
