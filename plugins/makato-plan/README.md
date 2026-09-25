<!-- markdownlint-disable MD013 MD031 MD032 MD040 -->
# makato-plan

**Goal**: Transforms raw feature requests into vertically-sliced GitHub issues through structured
discovery, interviews, architectural analysis, and UX design — producing acceptance-tested stories
ready for development.

**How**: Guides users through a sequential shaping pipeline: divergent-convergent brainstorming,
product requirements definition, architecture design, optional UX design and interactive HTML
prototype, story decomposition with a Three Amigos simulation (PO, Dev Lead, and QA agents running
in parallel), acceptance test refinement, and GitHub issue publication to a Projects v2 board. The
`stress-test-artifact` skill is cross-cutting and can be invoked after any phase to stress-test decisions before
proceeding.

**Why**: Features shaped through this pipeline are thoroughly understood, architecturally grounded,
and broken into independently deliverable work before development begins — reducing rework and
misalignment. Stories exiting this plugin are shaped but not refined: they carry acceptance criteria
and architectural context, but no detailed implementation tasks or estimates.

## What Belongs Here

- Skills, agents, hooks, and MCP servers that conduct structured interviews and grilling sessions
  to extract and clarify feature requirements
- Skills that produce PRDs, architecture documents, UX design documents, or design decisions from
  discovery output
- Skills and agents that decompose features into PI-sized epics and vertically-sliced stories with
  acceptance criteria
- Skills that gather and consolidate existing material (docs, context, prior art) about a feature
- Skills, hooks, and MCP servers that create or update GitHub issues and project-board items from
  shaped output

## What Does NOT Belong Here

- Implementation or coding skills (belong in development-phase plugins)
- Detailed implementation task breakdowns or technical refinement beyond architectural guidance
- Skills that validate or review already-written code or PRs
- Sprint or iteration management or backlog grooming during development
- Skills that create makato plugins or skills (belong in makato-contribute)
- Generic brainstorming or ideation not tied to a specific feature

## Workflow

Skills follow a sequential shaping pipeline. Each phase produces a disk artifact that feeds the
next. `stress-test-artifact` is cross-cutting — invoke it after any phase to stress-test decisions before
proceeding. `excalidraw` is a utility that can be used inside any phase that benefits from a visual.

```
Feature request / work item description
         │
         ▼
┌─────────────────┐
│  brainstorming  │  Input:  feature description or GitHub issue URL
└────────┬────────┘  Output: brainstorm.md + decisions.md
         │
         │  ◀── stress-test-artifact (optional cross-cutting stress-test after any phase)
         ▼
┌─────────────────┐
│   create-prd    │  Input:  brainstorm.md + decisions.md
└────────┬────────┘  Output: prd.md
         │
         ▼
┌───────────────────────┐
│  create-architecture  │  Input:  prd.md + decisions.md + repositories.yml
└────────┬──────────────┘  Output: design.md
         │
         ▼
┌─────────────────┐  (optional — skip when UI Required: No)
│   create-ux     │  Input:  prd.md + design.md + decisions.md
└────────┬────────┘  Output: ux.md
         │
         ▼
┌──────────────────────┐  (optional — skip when no new UI surfaces)
│  create-prototype    │  Input:  prd.md + design.md + ux.md + decisions.md
└────────┬─────────────┘  Output: prototype.html
         │
         ▼
┌─────────────────┐
│    decompose    │  Input:  prd.md + design.md + ux.md + prototype.html
└────────┬────────┘  Output: stories.json (with draft Gherkin)
         │
         ▼
┌──────────────────────────┐
│  create-acceptance-tests │  Input:  stories.json + prd.md + design.md
└────────┬─────────────────┘  Output: stories.json (refined acceptanceTestCases)
         │
         ▼
┌──────────────┐
│  to-issues   │  Input:  stories.json + .claude/config.json
└────────┬─────┘  Output: GitHub issues + created-issues.json
         │
         ▼
┌──────────────────────┐
│  issue-to-project    │  Input:  created-issues.json + .claude/config.json
└────────┬─────────────┘  Output: issues on GitHub Projects v2 board
         ▼
  GitHub Projects v2 board — ready for makato-build / makato-orchestrate
```

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [brainstorming](skills/brainstorming/SKILL.md) | Structured divergent-convergent ideation on a feature using 62 techniques, targeting 50+ ideas, converging to top 3-5 concepts with rationale. Creates the spec folder if it does not exist. (interactive) | Feature description, GitHub issue URL, or existing spec slug; optionally imports attachments from the GitHub issue | `specs/{slug}/brainstorm.md` (clustered ideas, top concepts) and `specs/{slug}/decisions.md` (initial decisions) | 1.2.0 |
| [stress-test-artifact](skills/stress-test-artifact/SKILL.md) | Adversarial interview that stress-tests any phase artifact — challenges decisions, assumptions, and rejected options depth-first. Cross-cutting skill invokable after any phase. Captures resolved feature vocabulary into per-spec `glossary.md`. (interactive) | Any phase artifact (brainstorm.md, prd.md, design.md, etc.) + decisions.md + glossary.md (if present) | Grill Audit section appended to target artifact + updated decisions.md + updated/created glossary.md | 1.2.0 |
| [create-prd](skills/create-prd/SKILL.md) | Creates a Product Requirements Document from brainstorming output via a product strategy interview, stress-test-artifact integration, vertical story sketches, and HTML review gate. Pure document output — no external side-effects. (interactive) | `specs/{slug}/brainstorm.md` + decisions.md | `specs/{slug}/prd.md` (goals, scope, success metrics, rough vertical story sketches, delivery recommendations) | 1.1.0 |
| [create-architecture](skills/create-architecture/SKILL.md) | Creates an Architecture Design Document from PRD artifacts via a 3-round architect interview, stress-test-artifact integration, NFR implementation mapping, and interactive HTML review gate. Pure document output — no external side-effects. (interactive) | `specs/{slug}/prd.md` + decisions.md + repositories.yml (if present) + reference/ folder (technical docs, PPTX/PDF converted via markitdown MCP) | `specs/{slug}/design.md` (system context, component design, technical decisions, data model, API, security, deployment, test strategy) | 1.0.4 |
| [create-ux](skills/create-ux/SKILL.md) | Creates a UX design document with screen inventory, wireframes, interaction patterns, user testing plan, and accessibility notes for PRD UI surfaces. Optional phase — skipped when PRD has UI Required: No. (interactive) | `specs/{slug}/prd.md` (required, UI Required: Yes/Minimal) + design.md (optional) + decisions.md | `specs/{slug}/ux.md` (screen inventory, user flows, screen states, information architecture, accessibility, developer handoff notes) | 1.0.0 |
| [create-prototype](skills/create-prototype/SKILL.md) | Creates an interactive, high-fidelity single-file HTML prototype of new UI surfaces using the target app's design system tokens. Optional phase for UI-bearing features. Dispatches prototype-builder agent. Pure visual/UX validation — no external side-effects. (interactive) | `specs/{slug}/prd.md` + design.md + ux.md (optional) + decisions.md + repositories.yml (for design system research) | `specs/{slug}/prototype.html` (interactive single-file HTML prototype with integrated review chrome) | 1.0.2 |
| [decompose](skills/decompose/SKILL.md) | Decomposes shaped features into independently deliverable, vertically-sliced stories with acceptance criteria. Embeds a Three Amigos simulation (PO, Dev Lead, QA agents in parallel) for shared understanding. Emits taxonomic `type:` (+ Three-Amigos-produced `severity:`/`priority:`/`effort:`) labels into `stories[].labels[]` so `to-issues` need not guess type from text (#272). Produces interactive HTML reviews for three-amigos feedback and final story approval. (interactive) | `specs/{slug}/prd.md` + design.md + ux.md (optional) + prototype.html (optional) + decisions.md + repositories.yml | `specs/{slug}/stories.json` (machine-readable vertically-sliced stories with acceptance criteria and draft Gherkin scenarios) | 1.3.0 |
| [create-acceptance-tests](skills/create-acceptance-tests/SKILL.md) | Refines draft Gherkin scenarios from decompose's QA agent into polished, high-level, manually testable acceptance test cases (3-5 per foundation/happy-path story, 1-3 per edge-case story). Dispatches acceptance-writer agent per story, runs quality self-review against 6 anti-patterns, presents interactive HTML review. (interactive) | `specs/{slug}/stories.json` (with draft successScenarios) + prd.md + design.md (optional) | Refined Gherkin scenarios written back into stories.json acceptanceTestCases field | 1.0.2 |
| [to-issues](skills/to-issues/SKILL.md) | Creates GitHub issues on github.com from stories.json with a 10-dimension label taxonomy (type/tier/tech/module/severity/phase/effort/priority/points/status). Resolves `type:` from an explicit in-enum `stories[].labels[]` entry first, falling back to text inference (#272). Topologically sorts by dependencies.blockedBy. DRY_RUN=1 supported. (interactive) | `specs/{slug}/stories.json` + `.claude/config.json` (for project name and ADR folder path) | GitHub issues created on github.com + `specs/{slug}/created-issues.json` (machine-readable handoff with issue numbers, URLs, labels, blockers) | 3.6.0 |
| [issue-to-project](skills/issue-to-project/SKILL.md) | Syncs created-issues.json entries to a GitHub Projects v2 board. Includes lifecycle sync (sync-lifecycle), reconciliation, board-wide audit (--board-audit), webhook-mode sync (--from-webhook), fields-only backfill, and autonomous Todo→Ready promotion with a ready-for-dev label stamp (v2.8.0). Never removes items; never overwrites externally-changed Status. (interactive) | `specs/{slug}/created-issues.json` (from to-issues) + `.claude/config.json` github_project block (one-time setup via --init) | Each issue added to the GitHub Projects v2 board + `specs/{slug}/project-sync.json` (audit artifact) | 2.8.0 |
| [excalidraw](skills/excalidraw/SKILL.md) | Generates Excalidraw diagrams from text descriptions in Obsidian (.md), Standard (.excalidraw), or Animated (.excalidraw) output formats. Supports flowcharts, mind maps, hierarchy, relationship, comparison, timeline, matrix, and freeform diagrams. | Text description of the diagram (flowchart, architecture, mind map, etc.) | Diagram file in the current working directory: `[topic].[type].md` (Obsidian) or `[topic].[type].excalidraw` (Standard/Animated) | 1.3.1 |
| [excalidraw-diagram-generator](skills/excalidraw-diagram-generator/SKILL.md) | Generates `.excalidraw` diagrams from natural-language descriptions, including flowcharts, relationship, mind map, architecture, data-flow, swimlane, class, sequence, and ER diagrams. | Description of the concepts, entities, steps, and relationships to visualize | `<descriptive-name>.excalidraw` with optional templates, icon helpers, and reusable diagram resources | 1.0.0 |
| [manage-stores](skills/manage-stores/SKILL.md) | CLI helper for managing stores[] in .claude/config.json — register, list, remove; enables `to-issues --store <id>` to resolve target repos without repeating owner/repo; delegates to `scripts/manage-stores.sh` | `.claude/config.json` stores[] | updated `.claude/config.json` | 1.1.0 |

## Agents

| Agent | Model | Permission | Purpose | Dispatched by |
|-------|-------|------------|---------|---------------|
| context-scout | haiku | bypassPermissions (read/grep/glob allowed; write/edit/bash denied) | Read-only scan of `context/{REPO_NAME}/` directories for files relevant to a given feature. Returns synthesized insights (not raw paths) for the calling skill. | Most plan skills |
| acceptance-writer | sonnet | bypassPermissions | Refines draft Gherkin scenarios from decompose's QA agent into 3-5 polished, high-level, manually testable acceptance test cases per story written in business language. | create-acceptance-tests (once per story in stories.json) |
| dev-reviewer | sonnet | bypassPermissions | Lead Developer perspective for Three Amigos story review — challenges technical feasibility, dependencies, estimates, and implementation risk. | decompose (Three Amigos simulation) |
| po-reviewer | sonnet | bypassPermissions | Product Owner perspective for Three Amigos story review — challenges value delivery, scope boundaries, user outcomes, and phase assignment. | decompose (Three Amigos simulation) |
| qa-reviewer | sonnet | bypassPermissions | QA Engineer perspective for Three Amigos story review — challenges testability, identifies edge cases, and produces 1-3 draft Gherkin scenarios per story. | decompose (Three Amigos simulation), stress-test-artifact (story review) |
| prototype-builder | opus | bypassPermissions (read/edit/bash/grep/glob allowed) | Generates high-fidelity interactive single-file HTML prototypes from design context and UX decisions, using the target app's design system tokens. Creative agent — never calls AskUserQuestion. | create-prototype, create-ux |
| doc-writer | sonnet | bypassPermissions (read/edit/bash/grep/glob allowed) | Generates styled HTML review documents and writes canonical markdown artifacts from structured input. Template-driven — never invents structure or content. | Most plan skills (brainstorming, create-prd, create-architecture, decompose, etc.) |

## Shared Resources

| File | Purpose |
|------|---------|
| `shared/terminology.md` | Plugin-level definitions for domain terms used in skill prose (vertical slice, slicing phase, shape lifecycle phase, Three Amigos, Refine). Audience: contributors and consumers reading the skills — not loaded at runtime. |
| `shared/repositories-yml-schema.md` | Schema contract for the repositories.yml file; consumed by create-prd, create-architecture, create-prototype, and decompose to understand affected repositories and team mappings. |
| `shared/scenario-schema.md` | Gherkin scenario shape contract; used by decompose's `successScenarios[]` and create-acceptance-tests' `acceptanceTestCases[]` fields. |
| `shared/refinement-contract.md` | Rules for the Refine update mode; consumed by create-prd, create-architecture, create-prototype, and decompose when an artifact already exists and the user chooses to update rather than replace it. |

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-plan/AGENTS.md` | Primary contributor guide: goal, shaping boundary, what belongs/does not belong, skill authoring rules, agent table, shared/ contract, versioning policy, and PR checklist. |
| `plugins/makato-plan/.claude-plugin/plugin.json` | Plugin marketplace metadata: name, description, author. No version field (repo versioned via release-please + git tags). |
| `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` | 10-dimension label taxonomy for GitHub issue creation (type/tier/tech/module/severity/phase/effort/priority/points/status) — mandatory load for every to-issues run. |
| `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | github_project block contract and validation rules for .claude/config.json — mandatory load for every issue-to-project run. |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Consumes from | makato-core | Prerequisite: gh CLI (authenticated) is required for GitHub interactions in to-issues and issue-to-project. makato-core provides shared developer utilities and suite infrastructure. |
| Produces for | makato-build | Emits `created-issues.json` (from to-issues) containing GitHub issue numbers and URLs that makato-build consumes as work item inputs for the build pipeline (build-start, build-refine). |
| Produces for | makato-orchestrate | Emits `created-issues.json` that makato-orchestrate's autonomous control plane consumes to drive GitHub Issues to merged PRs unattended via the PO-agent loop. |
| Complements | makato-contribute | makato-contribute's makato-skill-creator and makato-plugin-creator skills scaffold new skills and plugins within the suite; makato-plan does not perform this — it defers to makato-contribute. |
| Complements | makato-change | makato-change's analyze and design phases may re-invoke makato-plan skills (e.g. stress-test-artifact, create-prd, decompose) when a change request requires full reshaping rather than targeted code modification. |

## Configuration — `config/general.json`

Central config file controlling all runtime behavior. Schema: `schemas/general.config.schema.json`.

| Property | Values | Default | Effect |
|----------|--------|---------|--------|
| **TeamSize** | `Solo`, `Team` | `Solo` | **Solo**: skips ownership/team questions, MD-only numbered reviews (§1, §1.1 …), no HTML. **Team**: full team identification, HTML interactive reviews. |
| **Status** | `Development` / `Dev`, `Production` / `Prod` | `Development` | **Development**: skips deployment, rollout, migration, and feature toggle sections — focuses on technical solution planning only. **Production**: full pipeline with all deployment and release planning. |
| agents | object | (see file) | Per-agent settings: maxTurns, maxFindings, tokenBudget. |
| brainstorming | object | `{ defaultSessionDepth: "standard" }` | Brainstorming session defaults. |
| toIssues | object | `{ mode: "interactive", dryRun: false }` | to-issues skill defaults. |
| issueToProject | object | `{ readyQueueMode: "manual" }` | issue-to-project skill defaults. |
| storyConstraints | object | `{ maxStoryPoints: 13, validPointValues: [1,2,3,5,8,13] }` | Story point validation rules. |
| excalidraw | object | `{ defaultOutputMode: "obsidian" }` | Excalidraw output format default. |

## Prerequisites / MCP Servers

| Server | Purpose | Required |
|--------|---------|----------|
| markitdown | Converts downloaded files (PPTX, PDF, DOCX, images) to markdown for content extraction. Used by create-architecture when reference/original/ contains unconverted technical documents. | No |

External prerequisites:

- `gh` CLI authenticated to github.com (required by to-issues and issue-to-project for all GitHub
  interactions)
- Python 3 (used by to-issues and issue-to-project to parse JSON artifacts and validate schemas)
- `git` (used by to-issues and issue-to-project to resolve repo root and remote URL)
- markitdown MCP server (used by create-architecture to convert PPTX/PDF/DOCX reference files to
  markdown)

## Installation

```bash
claude --plugin-dir ./plugins/makato-plan
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
