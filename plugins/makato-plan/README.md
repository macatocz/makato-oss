<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
# makato-plan

📖 [Read the docs →](https://github.com/zstary/makato/tree/main/plugins/makato-plan)

**Goal**: Transforms raw Jira features into PI-sized epics with vertically-sliced stories through structured discovery, interviews, and architectural analysis.

**How**: Guides users through progressive interviews and grilling sessions that brainstorm, analyze, produce a PRD, define architecture, and decompose work into sized epics and sliced stories.

**Why**: Ensures features are thoroughly understood, architecturally sound, and broken into actionable work before development begins, reducing rework and misalignment.

**Output**: A `specs/<ITDB-key>-<slug>/` folder containing:
- `brainstorm.md` — clustered ideas and top concepts from divergent-convergent ideation
- `decisions.md` — living decision log, updated by grill sessions throughout all phases
- `glossary.md` — feature-scoped vocabulary captured by `grill` (canonical terms, banned aliases, relationships); read by downstream skills on entry
- `prd.md` — functional product requirements (goals, scope, metrics, vertical story sketches)
- `design.md` — architecture and technical approach (components, APIs, data model, NFRs)
- `prototype.html` — interactive high-fidelity prototype of new UI surfaces (optional)
- `stories.json` — machine-readable vertically-sliced stories with acceptance criteria and Gherkin test cases

After `publish`: a Jira epic with linked stories (+ subtasks), inter-story dependency links, and a Confluence spec page for stakeholders. Jira keys are written back into `stories.json`.

## Shaping Boundary

Stories produced by this plugin are **shaped but not refined**:
- They have clear functional descriptions and acceptance criteria
- They include architectural context
- They do NOT include detailed implementation tasks or sprint-level estimation
- Development teams own the refinement step

## Terminology

This plugin uses domain-specific terms (e.g., *vertical slice*, *slicing phase*, *shape lifecycle phase*, *Three Amigos*, *Refine*). Canonical definitions live in [shared/terminology.md](shared/terminology.md). If a skill prompts you with a term you don't recognize, check there first.

For *feature-specific* vocabulary (the language unique to one Jira feature being shaped), see the per-spec `glossary.md` written by the `grill` skill inside each `specs/{ITDB-KEY}-{slug}/` folder.

## What Belongs Here

- Skills, agents, hooks, and MCP servers that conduct structured interviews/grilling sessions to extract and clarify feature requirements
- Skills that produce PRDs, architecture documents, or design decisions from discovery output
- Skills and agents that decompose features into PI-sized epics and vertically-sliced stories with acceptance criteria
- Skills that gather and consolidate existing material (docs, context, prior art) about a feature
- Skills, hooks, and MCP servers that create or update Jira epics and stories from shaped output

## What Does NOT Belong Here

- Implementation/coding skills (those belong in development-phase plugins)
- Detailed implementation task breakdowns or technical refinement beyond architectural guidance
- Skills that validate or review already-written code or PRs
- Sprint/iteration management or backlog grooming during development
- Skills that create makato plugins or skills (those belong in makato-contribute)
- Generic brainstorming or ideation not tied to a specific Jira feature

## Workflow

Skills follow a sequential shaping pipeline. Each phase produces a disk artifact that feeds the next. The `grill` skill is cross-cutting — invoke it after any phase to stress-test decisions before proceeding.

### Phases

0. **Initialize** — set up workspace and gather existing material
   - [ ] `init-spec` — (planned, future feature) create spec folder, download ITDB attachments, pull wiki context
   - Input: Jira ITDB feature key
   - Output: `specs/<ITDB-key>-<slug>/` folder with downloaded attachments and any existing context
   - Note: Planned standalone skill. Not yet implemented — `brainstorming` currently performs spec-folder setup and attachment download in its Step 1.1. When `init-spec` ships, that work will move here and run once per feature before brainstorming begins.

1. **Discover** — understand the problem space
   - [x] `brainstorming` — divergent-convergent ideation
   - Input: Jira ITDB feature key (creates the spec folder if it doesn't exist; will assume `init-spec` once that ships)
   - Output: `brainstorm.md` + `decisions.md` (top 3-5 concepts, clustered ideas, initial decisions)

2. **Define** — produce a functional PRD
   - [x] `create-prd` — functional product requirements document
   - Input: `brainstorm.md` + `decisions.md`
   - Output: `prd.md` — goals, scope, success metrics, rough vertical story sketches, delivery recommendations
   - Note: Pure document output. Integrates grill before writing. Answers "what" and "why". No Jira/Confluence side-effects.

3. **Design** — architecture and technical approach
   - [x] `create-architecture` — architecture/design document
   - Input: `prd.md` + `decisions.md` + `repositories.yml` + `reference/` (technical docs)
   - Output: `design.md` — system context, component design, technical decisions, data model, API, security, deployment, test strategy
   - Note: Answers "how we build it". Comprehensive architect interview (3 rounds), optional grill integration, interactive HTML review gate. Pure document output — no Jira/Confluence side-effects.

4. **Prototype** — visual/UX validation (optional)
   - [x] `create-prototype` — interactive HTML prototype of new UI surfaces
   - Input: `prd.md` + `design.md` + `decisions.md` + `repositories.yml` + app design system context (tokens, components)
   - Output: `prototype.html` — interactive single-file HTML prototype with integrated review (slide-deck pattern, feedback per surface)
   - Note: Scope = only the new/changed UI surfaces (not the full app). High-fidelity — uses real design tokens from target app's design system. Includes adaptive UX interview (skips if well-specified), optional grill before generation. Uses dedicated `prototype-builder` agent.

5. **Decompose** — slice into deliverable stories
   - [x] `decompose` — vertical story slicing with embedded Three Amigos
   - Input: `prd.md` + `design.md` + `prototype.html` (optional) + `decisions.md` + `repositories.yml`
   - Output: `stories.json` — machine-readable schema of vertically-sliced stories with acceptance criteria
   - Note: Stories are functional slices, not technical tasks. Each story is independently deliverable and testable. Embeds Three Amigos simulation (PO, Dev Lead, QA agents in parallel) for shared understanding. Produces interactive HTML reviews for both three-amigos feedback and final story approval.

   - [x] `create-acceptance-tests` — Gherkin acceptance test cases per story
   - Input: `stories.json` + `prd.md` + `design.md` (optional)
   - Output: Refined Gherkin scenarios (3-5 per story) written back into `stories.json` → `acceptanceTestCases`
   - Note: Refines draft Gherkin from decompose's QA agent into polished, high-level, manually testable scenarios. Dispatches `acceptance-writer` agent per story, runs quality self-review against 6 anti-patterns, presents interactive HTML review for approval.

6. **Publish** — create external artifacts
   - [x] `publish` — create Jira epic + stories + subtasks + Confluence spec page
   - Input: `stories.json` (status: approved) + `prd.md` + `design.md` + `prototype.html` (for linking)
   - Output: Jira epic (linked to ITDB via Parent-Child) + stories (epicLink, inter-story Dependency links, 4 subtasks each) + Confluence spec page (stakeholder overview in DCPL) + jiraKeys written back to stories.json
   - Note: Single atomic skill. Creates in deterministic order: epic → stories → subtasks → dependency links → Confluence. Two confirmation gates (before Jira, before Confluence). Create-or-update idempotency — re-run safely skips existing items. Subtask content is pre-populated at publish time (QA gets acceptance criteria, Documentation gets artifact links, Automate gets Gherkin); the makato-build `refine` skill may enrich further. Creates epic and story subfolders inside the spec folder after publish.

7. **Publish (GitHub)** — emit GitHub issues from shaped stories
   - [x] `to-issues` — create GitHub issues on github.com with 9-dimension label taxonomy
   - Input: `specs/<slug>/stories.json` + `.claude/config.json`
   - Output: GitHub issues created on github.com + `specs/<slug>/created-issues.json` (machine-readable handoff containing issue numbers, URLs, labels, blockers)
   - Note: Generic github.com publisher — parallel to Phase 6's Jira `publish`. Applies type / tier / tech / module / severity / phase / effort / priority / status labels; maps stories to ADR folders for `module:` annotation; severity/phase/effort/priority source from `stories[].metadata` (priority auto-derives from severity when absent); emits `status:blocked` on dependency or `type:future-enhancement` inference. Topologically sorts by `dependencies.blockedBy`. `DRY_RUN=1` supported.

8. **Project board sync** — land created issues on a GitHub Projects v2 board
   - [x] `issue-to-project` — sync `created-issues.json` entries to a github.com Projects v2 board
   - Input: `specs/<slug>/created-issues.json` (from `to-issues`) + `.claude/config.json` → `github_project` block (one-time setup via `issue-to-project --init`)
   - Output: each new issue added to the project board + `specs/<slug>/project-sync.json` (audit artifact). Status defaults to `Todo`; flipped to `Blocked` only when `status:blocked` is in the issue's `labels[]`
   - Note: Strict consumer of `to-issues`'s contract. Never removes items; never overwrites externally-changed Status. `--init` is a one-time wizard per consuming repo. Pre-flight checks for `gh` presence / auth / version / scope. R1 sentinel + HALT codes for orchestrator parsing. Out of v1 scope: PR-open/merge lifecycle (deferred to v2).

### Cross-cutting

- [x] `grill` — adversarial stress-test of any phase artifact
- Input: Any phase artifact + `decisions.md` (+ existing `glossary.md` if present)
- Output: Grill Audit appended to target artifact + updated `decisions.md` + updated `glossary.md` (canonical terms, banned aliases, relationships, flagged ambiguities)
- When: After any phase, before proceeding to next. Optional but recommended.

### Artifact Structure

All artifacts live under `specs/<ITDB-key>-<slug>/` during shaping. The spec folder stays unchanged after publish — publish creates epic and story subfolders inside it.

```
specs/
└── ITDB-1234-checkout-redesign/         ← stable spec folder (never renamed)
    ├── brainstorm.md
    ├── prd.md
    ├── design.md
    ├── decisions.md
    ├── glossary.md                       (feature-scoped vocabulary, written by grill)
    ├── prototype.html
    ├── stories.json                      (contains jiraKeys after publish)
    └── DCP-56000-redesign-checkout-flow/ ← epic folder (created by publish)
        ├── DCP-56001-cart-validation-service-foundation/
        ├── DCP-56002-realtime-validation-errors-cart-ui/
        ├── DCP-56003-quantity-limit-validation-rule/
        └── DCP-56004-validation-timeout-degraded-mode/
```

Story folders are empty after publish — they serve as named anchors for makato-build to populate during sprint planning.

### Artifact Schema Contract

`stories.json` is the handoff schema — machine-readable, not prose. It must contain enough structure for `publish` (or a downstream plugin) to create Jira issues without human reformatting. Schema definition TBD as `decompose` skill is built.

### Flow Diagram

```
ITDB Feature
     │
     ▼
┌───────────┐
│ init-spec │  (planned — future feature; brainstorming sets up the workspace today)
└──────┬────┘
       ▼
┌──────────────┐     ┌───────┐
│ brainstorming │────▶│ grill │ (optional)
└──────┬───────┘     └───────┘
       ▼
┌──────────────┐     ┌───────┐
│  create-prd  │────▶│ grill │ (optional)
└──────┬───────┘     └───────┘
       ▼
┌───────────────────┐ ┌───────┐
│create-architecture│─▶│ grill │ (optional)
└──────┬────────────┘ └───────┘
       ▼
┌─────────────────┐  ┌───────┐
│create-prototype  │─▶│ grill │ (integrated before generation)
└──────┬──────────┘  └───────┘
       ▼
┌───────────┐        ┌───────┐
│ decompose │───────▶│ grill │ (optional)
└──────┬────┘        └───────┘
       ▼
┌─────────────────────────────┐
│ create-acceptance-tests     │  (refine draft Gherkin from decompose)
└──────┬──────────────────────┘
       ▼
┌─────────┐
│ publish │  (epic → stories → Confluence spec)
└─────────┘
       ▼
  Jira Epic + Stories + Confluence Spec Page
```

**Important:** Every PR that adds or modifies a skill MUST update this workflow section.

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `brainstorming` | Structured divergent-convergent ideation using 62 techniques. Targets 50+ ideas, converges to top 3-5 concepts. | 1.1.0 |
| `grill` | Adversarial interview that stress-tests any phase artifact. Challenges decisions, assumptions, and rejected options depth-first. Captures resolved feature vocabulary into per-spec `glossary.md`. | 1.1.0 |
| `create-prd` | Create PRD from brainstorming output. Product strategy interview, grill integration, vertical story sketches, HTML review. | 1.0.0 |
| `create-architecture` | Create architecture design documents from PRD. Architect interview (3 rounds), grill integration, NFR implementation mapping, HTML review. | 1.0.0 |
| `arch-ux` | Create UX design documents with screen inventory, wireframes, interaction patterns, user testing plan, and accessibility notes for PRD UI surfaces. | 1.0.0 |
| `create-prototype` | Create interactive high-fidelity HTML prototypes of new UI surfaces. Design system research, adaptive UX interview, grill integration, integrated review. | 1.0.0 |
| `decompose` | Decompose shaped features into vertically-sliced stories. Three Amigos simulation (PO/Dev/QA agents in parallel), story point estimation, interactive HTML review. | 1.0.0 |
| `create-acceptance-tests` | Refine draft Gherkin scenarios into polished acceptance test cases (3-5 per story). Dispatches acceptance-writer agent per story, quality self-review, HTML review. | 1.0.0 |
| `publish` | Publish shaped stories.json to Jira (Epic + Stories + Subtasks + links) and Confluence (spec page). Two confirmation gates, create-or-update idempotency, pre-populated subtask templates. | 1.0.0 |

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

This plugin relies on MCP servers provided by **makato-core** (required foundation):
- **Jira MCP** — for reading/writing features, epics, and stories
- **Wiki MCP** — for gathering existing documentation and context

This plugin declares its own MCP server (via `.mcp.json`):
- **markitdown** — converts downloaded files (PPTX, PDF, DOCX, images) to markdown for content extraction

## Installation

```bash
claude --plugin-dir ./plugins/makato-plan
```

## Try It

1. Pick (or create) a Jira ITDB feature you'd like to plan — note its key (e.g., `ITDB-1234`).
2. Make sure `makato-core` is installed and its Jira + Wiki MCP servers authenticate against your tenant.
3. Run the pipeline phase by phase from the spec folder root:
   ```
   /makato-plan:brainstorming ITDB-1234
   /makato-plan:create-prd
   /makato-plan:create-architecture
   /makato-plan:create-prototype       # optional, only if UI surfaces are non-trivial
   /makato-plan:decompose
   /makato-plan:create-acceptance-tests
   /makato-plan:publish                # creates real Jira + Confluence — gates appear before each
   ```
4. Inspect the generated `specs/ITDB-1234-<slug>/` folder between phases. Re-run any skill in "Refine" mode if you want to iterate on an artifact.

`publish` has two confirmation gates and is idempotent. If you want to dry-run, stop at the first gate.

## Version

0.1.0
