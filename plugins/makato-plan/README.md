<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
# makato-plan

📖 [Read the docs →](https://github.com/zstary/makato/tree/main/plugins/makato-plan)

**Goal**: Transforms raw feature requests into vertically-sliced GitHub issues through structured discovery, interviews, architectural analysis, and UX design — producing acceptance-tested stories ready for development.

**How**: Guides users through progressive interviews and grilling sessions that brainstorm, analyze, produce a PRD, define architecture, design UX, decompose work into sliced stories, write acceptance tests, and publish those stories as GitHub issues wired to a GitHub Projects v2 board.

**Why**: Ensures features are thoroughly understood, architecturally sound, and broken into actionable work before development begins, reducing rework and misalignment.

**Output**: A `specs/<slug>/` folder containing:
- `brainstorm.md` — clustered ideas and top concepts from divergent-convergent ideation
- `decisions.md` — living decision log, updated by grill sessions throughout all phases
- `glossary.md` — feature-scoped vocabulary captured by `grill` (canonical terms, banned aliases, relationships); read by downstream skills on entry
- `prd.md` — functional product requirements (goals, scope, metrics, vertical story sketches)
- `design.md` — architecture and technical approach (components, APIs, data model, NFRs)
- `ux.md` — UX design (screen inventory, wireframes, interaction patterns, accessibility) — optional, only when UI surfaces are non-trivial
- `prototype.html` — interactive high-fidelity prototype of new UI surfaces — optional
- `stories.json` — machine-readable vertically-sliced stories with acceptance criteria and Gherkin test cases

After `to-issues` + `issue-to-project`: shaped stories exist as GitHub issues on a GitHub Projects v2 board, and `stories.json`'s downstream sibling `created-issues.json` carries the GitHub issue numbers and URLs for makato-build / makato-orchestrate to consume.

## Shaping Boundary

Stories produced by this plugin are **shaped but not refined**:
- They have clear functional descriptions and acceptance criteria
- They include architectural context
- They do NOT include detailed implementation tasks or estimation
- Development teams own the refinement step

## Terminology

This plugin uses domain-specific terms (e.g., *vertical slice*, *slicing phase*, *shape lifecycle phase*, *Three Amigos*, *Refine*). Canonical definitions live in [shared/terminology.md](shared/terminology.md). If a skill prompts you with a term you don't recognize, check there first.

For *feature-specific* vocabulary (the language unique to one feature being shaped), see the per-spec `glossary.md` written by the `grill` skill inside each `specs/<slug>/` folder.

## What Belongs Here

- Skills, agents, hooks, and MCP servers that conduct structured interviews/grilling sessions to extract and clarify feature requirements
- Skills that produce PRDs, architecture documents, UX design documents, or design decisions from discovery output
- Skills and agents that decompose features into vertically-sliced stories with acceptance criteria
- Skills that gather and consolidate existing material (docs, context, prior art) about a feature
- Skills, hooks, and MCP servers that create or update GitHub issues and project-board items from shaped output

## What Does NOT Belong Here

- Implementation/coding skills (those belong in development-phase plugins)
- Detailed implementation task breakdowns or technical refinement beyond architectural guidance
- Skills that validate or review already-written code or PRs
- Iteration management or backlog grooming during development
- Skills that create makato plugins or skills (those belong in makato-contribute)
- Generic brainstorming or ideation not tied to a specific feature

## Workflow

Skills follow a sequential shaping pipeline. Each phase produces a disk artifact that feeds the next. The `grill` skill is cross-cutting — invoke it after any phase to stress-test decisions before proceeding.

### Phases

0. **Initialize** — set up workspace and gather existing material
   - [ ] `init-spec` — (planned, future feature) create spec folder, pull context and reference material
   - Input: feature description or work item reference
   - Output: `specs/<slug>/` folder with any gathered context
   - Note: Planned standalone skill. Not yet implemented — `brainstorming` currently performs spec-folder setup in its Step 1.1. When `init-spec` ships, that work will move here and run once per feature before brainstorming begins.

1. **Discover** — understand the problem space
   - [x] `brainstorming` — divergent-convergent ideation
   - Input: feature description (creates the spec folder if it doesn't exist; will defer to `init-spec` once that ships)
   - Output: `brainstorm.md` + `decisions.md` (top 3-5 concepts, clustered ideas, initial decisions)

2. **Define** — produce a functional PRD
   - [x] `create-prd` — functional product requirements document
   - Input: `brainstorm.md` + `decisions.md`
   - Output: `prd.md` — goals, scope, success metrics, rough vertical story sketches, delivery recommendations
   - Note: Pure document output. Integrates grill before writing. Answers "what" and "why". No external side-effects.

3. **Design** — architecture and technical approach
   - [x] `create-architecture` — architecture/design document
   - Input: `prd.md` + `decisions.md` + `repositories.yml` + `reference/` (technical docs)
   - Output: `design.md` — system context, component design, technical decisions, data model, API, security, deployment, test strategy
   - Note: Answers "how we build it". Comprehensive architect interview (3 rounds), optional grill integration, interactive HTML review gate. Pure document output — no external side-effects.

4. **UX** — user experience design (optional, when UI surfaces are non-trivial)
   - [x] `create-ux` — UX design document with screen inventory, wireframes, interaction patterns, accessibility notes
   - Input: `prd.md` + `design.md` + `decisions.md`
   - Output: `ux.md` — screen inventory, user flows, screen states, information architecture, accessibility, developer handoff notes
   - Note: Skipped when PRD has `UI Required: No`. Complements `create-prototype` — UX defines the design, prototype demonstrates it.

5. **Prototype** — visual/UX validation (optional)
   - [x] `create-prototype` — interactive HTML prototype of new UI surfaces
   - Input: `prd.md` + `design.md` + `ux.md` (optional) + `decisions.md` + `repositories.yml` + app design system context (tokens, components)
   - Output: `prototype.html` — interactive single-file HTML prototype with integrated review (slide-deck pattern, feedback per surface)
   - Note: Scope = only the new/changed UI surfaces (not the full app). High-fidelity — uses real design tokens from target app's design system. Includes adaptive UX interview (skips if well-specified), optional grill before generation. Uses dedicated `prototype-builder` agent.

6. **Decompose** — slice into deliverable stories
   - [x] `decompose` — vertical story slicing with embedded Three Amigos
   - Input: `prd.md` + `design.md` + `ux.md` (optional) + `prototype.html` (optional) + `decisions.md` + `repositories.yml`
   - Output: `stories.json` — machine-readable schema of vertically-sliced stories with acceptance criteria
   - Note: Stories are functional slices, not technical tasks. Each story is independently deliverable and testable. Embeds Three Amigos simulation (PO, Dev Lead, QA agents in parallel) for shared understanding. Produces interactive HTML reviews for both three-amigos feedback and final story approval.

   - [x] `create-acceptance-tests` — Gherkin acceptance test cases per story
   - Input: `stories.json` + `prd.md` + `design.md` (optional)
   - Output: Refined Gherkin scenarios (3-5 per story) written back into `stories.json` → `acceptanceTestCases`
   - Note: Refines draft Gherkin from decompose's QA agent into polished, high-level, manually testable scenarios. Dispatches `acceptance-writer` agent per story, runs quality self-review against 6 anti-patterns, presents interactive HTML review for approval.

7. **Publish** — emit GitHub issues from shaped stories
   - [x] `to-issues` — create GitHub issues on github.com with 10-dimension label taxonomy
   - Input: `specs/<slug>/stories.json` + `.claude/config.json`
   - Output: GitHub issues created on github.com + `specs/<slug>/created-issues.json` (machine-readable handoff containing issue numbers, URLs, labels, blockers)
   - Note: Generic github.com publisher. Applies type / tier / tech / module / severity / phase / effort / priority / points / status labels; maps stories to ADR folders for `module:` annotation; severity/phase/effort/priority source from `stories[].metadata` (priority auto-derives from severity when absent); emits `status:blocked` on dependency or `type:future-enhancement` inference. Topologically sorts by `dependencies.blockedBy`. `DRY_RUN=1` supported.

8. **Project board sync** — land created issues on a GitHub Projects v2 board
   - [x] `issue-to-project` — sync `created-issues.json` entries to a github.com Projects v2 board
   - Input: `specs/<slug>/created-issues.json` (from `to-issues`) + `.claude/config.json` → `github_project` block (one-time setup via `issue-to-project --init`)
   - Output: each new issue added to the project board + `specs/<slug>/project-sync.json` (audit artifact). Status defaults to `Todo`; flipped to `Blocked` only when `status:blocked` is in the issue's `labels[]`
   - Note: Strict consumer of `to-issues`'s contract. Never removes items; never overwrites externally-changed Status. `--init` is a one-time wizard per consuming repo. Pre-flight checks for `gh` presence / auth / version / scope. R1 sentinel + HALT codes for orchestrator parsing. Includes `sync-lifecycle`, `reconcile`, `--from-webhook`, `--board-audit`, and `--fields-only` modes (v2.3.0+).

### Cross-cutting

- [x] `grill` — adversarial stress-test of any phase artifact
- Input: Any phase artifact + `decisions.md` (+ existing `glossary.md` if present)
- Output: Grill Audit appended to target artifact + updated `decisions.md` + updated `glossary.md` (canonical terms, banned aliases, relationships, flagged ambiguities)
- When: After any phase, before proceeding to next. Optional but recommended.

- [x] `excalidraw` — generate Excalidraw diagrams from text descriptions
- Input: text description of the diagram (flowchart, architecture, mind map)
- Output: Excalidraw JSON in Obsidian, Standard, or Animated output format
- When: Inside any phase that benefits from a visual — typically `create-architecture` for system context or `create-ux` for user flows.

### Artifact Structure

All artifacts live under `specs/<slug>/` during shaping. The spec folder stays unchanged after the publish phase — `to-issues` and `issue-to-project` emit handoff JSON beside the existing artifacts rather than mutating them.

```
specs/
└── checkout-redesign/                  ← stable spec folder (never renamed)
    ├── brainstorm.md
    ├── prd.md
    ├── design.md
    ├── decisions.md
    ├── glossary.md                     (feature-scoped vocabulary, written by grill)
    ├── ux.md                           (optional)
    ├── prototype.html                  (optional)
    ├── stories.json                    (shaped stories with acceptance criteria)
    ├── created-issues.json             (GitHub issue numbers and URLs, emitted by to-issues)
    └── project-sync.json               (board-sync audit, emitted by issue-to-project)
```

### Artifact Schema Contract

`stories.json` is the handoff schema — machine-readable, not prose. It must contain enough structure for `to-issues` (or a downstream plugin) to create GitHub issues without human reformatting. Schema definition lives in the `decompose` skill.

### Flow Diagram

```
Feature / Work Item
     │
     ▼
┌───────────┐
│ init-spec │  (planned — future feature; brainstorming sets up the workspace today)
└──────┬────┘
       ▼
┌───────────────┐    ┌───────┐
│ brainstorming │───▶│ grill │ (optional)
└──────┬────────┘    └───────┘
       ▼
┌──────────────┐     ┌───────┐
│  create-prd  │────▶│ grill │ (optional)
└──────┬───────┘     └───────┘
       ▼
┌───────────────────┐ ┌───────┐
│create-architecture│▶│ grill │ (optional)
└──────┬────────────┘ └───────┘
       ▼
┌───────────┐        ┌───────┐
│ create-ux │───────▶│ grill │ (optional, only when UI is non-trivial)
└──────┬────┘        └───────┘
       ▼
┌──────────────────┐ ┌───────┐
│ create-prototype │▶│ grill │ (integrated before generation, optional)
└──────┬───────────┘ └───────┘
       ▼
┌───────────┐        ┌───────┐
│ decompose │───────▶│ grill │ (optional)
└──────┬────┘        └───────┘
       ▼
┌─────────────────────────────┐
│ create-acceptance-tests     │  (refine draft Gherkin from decompose)
└──────┬──────────────────────┘
       ▼
┌────────────┐
│ to-issues  │  (create GitHub issues from stories.json)
└──────┬─────┘
       ▼
┌───────────────────┐
│ issue-to-project  │  (add to GitHub Projects v2 board)
└──────┬────────────┘
       ▼
  GitHub Issues on Project Board
```

**Important:** Every PR that adds or modifies a skill MUST update this workflow section.

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `brainstorming` | Structured divergent-convergent ideation using 62 techniques. Targets 50+ ideas, converges to top 3-5 concepts. | 1.1.0 |
| `grill` | Adversarial interview that stress-tests any phase artifact. Challenges decisions, assumptions, and rejected options depth-first. Captures resolved feature vocabulary into per-spec `glossary.md`. | 1.1.0 |
| `create-prd` | Create PRD from brainstorming output. Product strategy interview, grill integration, vertical story sketches, HTML review. | 1.0.0 |
| `create-architecture` | Create architecture design documents from PRD. Architect interview (3 rounds), grill integration, NFR implementation mapping, HTML review. | 1.0.0 |
| `create-ux` | Create UX design documents with screen inventory, wireframes, interaction patterns, user testing plan, and accessibility notes for PRD UI surfaces. | 1.0.0 |
| `create-prototype` | Create interactive high-fidelity HTML prototypes of new UI surfaces. Design system research, adaptive UX interview, grill integration, integrated review. | 1.0.0 |
| `decompose` | Decompose shaped features into vertically-sliced stories. Three Amigos simulation (PO/Dev/QA agents in parallel), relative sizing, interactive HTML review. | 1.0.0 |
| `create-acceptance-tests` | Refine draft Gherkin scenarios into polished acceptance test cases (3-5 per story). Dispatches acceptance-writer agent per story, quality self-review, HTML review. | 1.0.0 |
| `to-issues` | Create GitHub issues from `stories.json` with 10-dimension label taxonomy (type/tier/tech/module/severity/phase/effort/priority/points/status). Topologically sorts by `dependencies.blockedBy`. Emits `created-issues.json` for downstream consumers. | 3.4.0 |
| `issue-to-project` | Sync `created-issues.json` entries to a GitHub Projects v2 board. Includes lifecycle sync (Status transitions from PR events), reconciliation, board-wide audit, and fields-only backfill modes. | 2.7.0 |
| `excalidraw` | Generate Excalidraw diagrams from text descriptions in Obsidian, Standard, or Animated output formats. | 1.3.1 |

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| `acceptance-writer` | Sonnet | Refines draft Gherkin into 3-5 polished, manually testable scenarios per story |
| `context-scout` | Haiku | Read-only scan of `context/{repo}/` for relevant files |
| `doc-writer` | Sonnet | Generates HTML reviews and writes markdown artifacts |
| `prototype-builder` | Sonnet | Generates high-fidelity interactive HTML prototypes from design context |
| `po-reviewer` | Sonnet | Product Owner perspective for Three Amigos story review |
| `dev-reviewer` | Sonnet | Lead Developer perspective for Three Amigos story review |
| `qa-reviewer` | Sonnet | QA Engineer perspective for Three Amigos story review |

## Prerequisites

This plugin declares its own MCP server (via `.mcp.json`):
- **markitdown** — converts downloaded files (PPTX, PDF, DOCX, images) to markdown for content extraction

GitHub interaction is performed via the `gh` CLI (no MCP dependency); `to-issues` and `issue-to-project` invoke it directly.

## Installation

```bash
claude --plugin-dir ./plugins/makato-plan
```

## Try It

1. Identify the feature or GitHub issue you want to plan — note a short slug (e.g., `checkout-redesign`).
2. Make sure `makato-core` is installed and `gh` is authenticated.
3. Run the pipeline phase by phase from the spec folder root:
   ```
   /makato-plan:brainstorming checkout-redesign
   /makato-plan:create-prd
   /makato-plan:create-architecture
   /makato-plan:create-ux              # optional, only if UI surfaces are non-trivial
   /makato-plan:create-prototype       # optional, only if UI surfaces are non-trivial
   /makato-plan:decompose
   /makato-plan:create-acceptance-tests
   /makato-plan:to-issues              # creates real GitHub issues — DRY_RUN=1 to preview
   /makato-plan:issue-to-project       # adds them to the GitHub Projects v2 board
   ```
4. Inspect the generated `specs/checkout-redesign/` folder between phases. Re-run any skill in "Refine" mode if you want to iterate on an artifact.

`to-issues` supports `DRY_RUN=1` to preview the GitHub issues that would be created without making any changes.

## Version

0.1.0
