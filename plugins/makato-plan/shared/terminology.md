<!-- markdownlint-disable MD013 MD040 -->
# makato-plan Terminology

Canonical definitions for terms used across makato-plan skills, references, and templates. This file is the **plugin-level terminology reference** — it documents the vocabulary contributors and consumers need to read the skills. It is distinct from the runtime, feature-scoped glossary that the `grill` skill writes per spec (see `specs/{ITDB-KEY}-{slug}/glossary.md` inside each spec folder).

**For skill authors:** when you introduce a term that needs explanation, add it here and reference the entry from your skill at the point of use (`shared/terminology.md#anchor` — the `shared/` symlink lives in each skill that consumes it). Do not redefine terms inline.

**For users:** if a skill prompts you with a term you do not recognize, search this file. Anchors are stable; deep-link with `#term-name`.

**Entry shape:**

```
### term

One- to two-sentence definition.

**See also:** [related-term](#related-term)
**Not to be confused with:** *similar-term* (one-line distinction).
```

The `See also` and `Not to be confused with` lines are optional and only present when they add value.

---

## 1. Lifecycle & Boundary

### shape

The overall act of transforming a raw Jira feature into PI-sized epics with vertically-sliced stories ready for development. The plugin name (`makato-plan`) refers to this activity.

**See also:** [shaping boundary](#shaping-boundary)

### shaping boundary

The line between *what* a feature delivers (in scope) and *how* development teams will build it (out of scope). Stories that exit shaping are functionally clear and have acceptance criteria but do not have detailed task breakdowns, sprint estimates, or implementation plans.

### ITDB

The Jira project that hosts raw, unshaped feature requests at SAP. An ITDB key (e.g., `ITDB-1234`) is the entry point for every shaping run — every spec folder is named after one.

**See also:** [spec folder](#spec-folder), [PI](#pi)

### PI

"Program Increment" — the SAP planning cadence (~one quarter). Every epic is sized to fit a single PI and is tagged with a Jira component named `PI | YY/QQ` (e.g., `PI | 26/03`).

**See also:** [PI component](#pi-component)

### spec folder

The working directory for one shaped feature, located at `specs/{ITDB-KEY}-{slug}/`. Holds all artifacts produced during shaping (`brainstorm.md`, `prd.md`, `design.md`, `prototype.html`, `decisions.md`, `stories.json`, `repositories.yml`, `reviews/`, `reference/`). Created by `brainstorming` Step 1.1 and read by every downstream skill.

### reference folder

The `reference/` subfolder inside a spec folder. Holds technical inputs the user provides (architecture diagrams, T-shirt sizings, PPTX/PDF source material). Files dropped into `reference/original/` get converted to markdown via `markitdown` MCP. Skills read but do not write here.

---

## 2. Skills & Sub-Agents

### brainstorming

The first makato-plan skill — divergent-then-convergent ideation on an ITDB feature. Produces `brainstorm.md` and seeds `decisions.md`.

### grill

A relentless interview skill that stress-tests a plan or design until each branch of the decision tree is resolved. Used between major skills (e.g., between PRD and architecture) when the user wants to be challenged.

### create-prd

Produces `prd.md` (problem, scope, success metrics, story sketches, phased rollout) from brainstorming output.

### create-architecture

Produces `design.md` (component design, data model, API design, technical decisions) from PRD + architectural inputs in `reference/`.

### create-prototype

Produces `prototype.html` — a high-fidelity interactive UI prototype — when a feature has user-facing surfaces worth visualizing before decomposition.

### decompose

Produces `stories.json` from PRD + architecture (+ optional prototype). Embeds a Three Amigos simulation. Output is the canonical machine-readable contract consumed by `create-acceptance-tests` and `publish`.

### create-acceptance-tests

Refines draft Gherkin scenarios from decompose's QA agent into polished acceptance test cases (3-5 per foundation/happy-path story, 1-3 per edge-case story). Writes back into `stories.json` → `acceptanceTestCases`.

### publish

Creates the Jira epic, stories, subtasks, and links in the target project, plus a Confluence spec page in DCPL. Reads `stories.json`; writes Jira keys back into it.

### Three Amigos

A simulation in `decompose` Step 5 that runs three sub-agents in parallel against the proposed story list: **po-reviewer** (Product Owner perspective — value, scope, phase), **qa-reviewer** (testability, edge cases, draft Gherkin), **dev-reviewer** (technical feasibility, dependencies, risk). Their outputs feed Round 1 refinements.

**See also:** [po-reviewer](#po-reviewer), [qa-reviewer](#qa-reviewer), [dev-reviewer](#dev-reviewer)

### po-reviewer

The Product Owner sub-agent in the Three Amigos simulation. Challenges value delivery, scope boundaries, user outcomes, and phase assignment.

### qa-reviewer

The QA Engineer sub-agent in the Three Amigos simulation. Challenges testability, identifies edge cases, and produces 1-3 draft Gherkin scenarios per story. Drafts feed `description.successScenarios[]` in `stories.json` and seed the input for `create-acceptance-tests`.

### dev-reviewer

The Lead Developer sub-agent in the Three Amigos simulation. Challenges technical feasibility, dependencies, estimates, and implementation risk.

### context-scout

A read-only sub-agent reused across makato-plan skills to scan `context/{REPO_NAME}/` for files relevant to a feature. Returns paths and excerpts; does not modify files.

### doc-writer

A sub-agent that turns structured input into styled HTML review documents and writes canonical markdown artifacts. Used by every long-form skill to keep doc generation out of the main agent's context.

### prototype-builder

The creative sub-agent invoked by `create-prototype` to generate the interactive HTML prototype.

### acceptance-writer

The sub-agent invoked by `create-acceptance-tests` that refines QA draft scenarios into polished acceptance test cases.

---

## 3. Artifacts

> All artifacts live in the [spec folder](#spec-folder). Each is produced by exactly one skill and may be read by many.

### brainstorm.md

Output of `brainstorming`. Captures observations, decisions, and top concepts from the ideation session.

### prd.md

Output of `create-prd`. The "what and why" — problem statement, personas, story sketches, scope, success metrics, phased rollout. Driver for `create-architecture` and `decompose`.

### design.md

Output of `create-architecture`. The "how" — component design, data model, API design, security, deployment, test strategy. Driver for `decompose`.

### prototype.html

Output of `create-prototype`. Optional visual artifact validating UI surfaces before decomposition.

### decisions.md

Living document, updated across every skill. Two tables: **Decision Details** (what was decided, by whom, in which shape lifecycle phase) and **Open Questions** (unresolved items parked during interviews).

**See also:** [Open Questions](#open-questions), [Decision Details](#decision-details), [shape lifecycle phase](#shape-lifecycle-phase)

### stories.json

Output of `decompose`, refined by `create-acceptance-tests`, consumed by `publish`. The canonical machine-readable contract for the epic, its stories, and their fields. Schema: `decompose/references/stories-json-schema.md`.

### repositories.yml

Lists the repositories affected by the feature with role markers (`primary` / `supporting`). Created by `create-prd` and refined as later skills learn more. Drives team mapping in `decompose`. Schema: `shared/repositories-yml-schema.md`.

### reviews/

Subdirectory of the spec folder holding HTML review documents generated by `doc-writer` (one per skill that produces a major artifact). Opened in the browser for user approval.

---

## 4. Story-level Concepts

### epic

The Jira-level container for a shaped feature. One epic per shaping run, sized to one PI, parented under the originating ITDB issue.

**See also:** [story](#story), [subtask](#subtask)

### story

A vertically-sliced unit of work that delivers a user outcome end-to-end. Sized in story points. Links upward to the epic via `epicLink` and may depend on other stories.

**Not to be confused with:** *story sketch* — see entry.

### story sketch

The 3-5 rough vertical slices captured in `prd.md`. Pre-decomposition; not yet refined, not yet sliced for splits or edge cases. `decompose` consumes sketches as starting input and produces actual stories.

### subtask

A Jira sub-task created under each story by `publish`. Always four per story: **Implementation**, **QA Verification**, **Documentation**, **Automate acceptance test cases**. Persisted in `stories.json` as `story.subtaskKeys` (an object keyed by name).

### vertical slice

A story that delivers a user outcome across all relevant layers (UI, API, data, persistence) in a single demoable increment, rather than one layer at a time. The opposite of a horizontal slice. Foundational to the slicing philosophy in `decompose`.

**See also:** [walking skeleton](#walking-skeleton), [slicing phase](#slicing-phase)

### walking skeleton

The first story in any decomposition: the thinnest possible end-to-end vertical slice that proves the architecture and establishes the path. Always assigned to the foundation slicing phase.

**See also:** [slicing phase](#slicing-phase)

### slicing phase

The bucket a story is assigned to during decomposition: `foundation`, `happy-path`, or `edge-cases`. Equivalent to "Phase 1 / Phase 2 / Phase 3" in `phase-assignment-rules.md` — same concept, two notations. The `phase` field in `stories.json` always uses the name form.

**Not to be confused with:** [shape lifecycle phase](#shape-lifecycle-phase) — that is when a *decision* was made (Discover / Plan / Execute), not which slice a *story* belongs to.

### feature toggle

A runtime flag that gates a story's behavior. Captured once per epic in `decompose` Round 2.5 and applied to gated stories. Five fields: `name`, `defaultState`, `alreadyInPlace`, `newNeeded`, `longTermUsage`.

### Definition of Done

The product-level conditions that must be true for the entire feature (not a single story) to be shippable. Captured in `prd.md` and lifted into `stories.json` as `epic.definitionOfDone[]`. Renders into the Jira description DoD panel.

**Not to be confused with:** *acceptance test* — DoD is feature-level, ATs are per-story.

### success scenario

A high-level, business-language Gherkin scenario captured during decomposition by qa-reviewer. Lives in `stories.json` as `story.description.successScenarios[]`. Seeds the input for `create-acceptance-tests`. Schema: `shared/scenario-schema.md`.

**Not to be confused with:** [acceptance test](#acceptance-test) — see entry.

### acceptance test

A polished Gherkin scenario produced by `create-acceptance-tests` from a draft success scenario. Lives in `stories.json` as `story.acceptanceTestCases[]`. Same schema as success scenarios but held to stricter quality rules.

### draft scenario

The qa-reviewer's first-pass Gherkin output during the Three Amigos simulation. Stored as `successScenarios[]`; not yet polished. `create-acceptance-tests` refines drafts into [acceptance tests](#acceptance-test).

---

## 5. Process Concepts

### interview round

A structured conversational pass during a skill (e.g., `decompose` Step 4 has Rounds 1, 2, 2.5, 3). Each round has a fixed scope and a defined output. Skills may not skip rounds.

### refinement / update mode

The "Refine" branch a skill takes when its primary artifact already exists in the spec folder. Rules in `shared/refinement-contract.md`: enumerate change candidates, preserve untouched sections byte-for-byte, surface AI-inferred changes for approval, emit a `changes[]` summary.

### Refine

The user-facing label for [refinement / update mode](#refinement--update-mode). Appears as an option in the Step 1.4 (or 1.5) `AskUserQuestion` of every long-form skill: "Create new, Refine, or Cancel."

### Draft vs Approved

Every long-form artifact (`brainstorm.md`, `prd.md`, `design.md`) carries a `**Status**` line. Set to `Draft` on creation, transitioned to `Approved` only when the producing skill's final approval gate fires. Downstream skills read this line to decide whether to prompt the user before proceeding.

### Open Questions

The unresolved-items table in `decisions.md`. Every skill appends to it when the user parks a question. Each entry has Q#, the question, the skill that raised it, priority (High/Medium/Low), and notes.

### Decision Details

The resolved-decisions table in `decisions.md`. Every skill that records a major decision appends one row, including chosen option, category, [shape lifecycle phase](#shape-lifecycle-phase), and date.

### shape lifecycle phase

The column in `decisions.md` that tracks when in the shaping lifecycle a decision was made: `Discover` (brainstorming, PRD), `Plan` (architecture, prototype, decompose), `Execute` (publish and beyond). Distinct from [slicing phase](#slicing-phase).

### parking

The act of writing an unresolved question into [Open Questions](#open-questions) instead of forcing an answer in the current interview. Triggered when the user says "I don't know" or "we'd need to check with X."

---

## 6. Jira & Confluence Terms (as used by `publish`)

### epicLink

The Jira custom field on a story that points to its parent epic. Set by `publish` Step 8 when creating each story.

### Parent-Child link

The Jira issue link type used between the originating ITDB issue (parent) and the shaped epic (child). Direction: `sourceIssue` is the ITDB parent, `targetIssue` is the epic. Created by `publish` Step 7.

### Dependency link

The Jira issue link type used between two stories when one cannot be implemented before the other. Direction: `sourceIssue` is the blocked story (`depends on`), `targetIssue` is the blocker. Created by `publish` Step 10.

### PI component

A Jira component named `PI | YY/QQ` (e.g., `PI | 26/03`) that tags every issue belonging to that Program Increment. `publish` Step 5 looks up the matching component by case-insensitive trimmed name match.

**See also:** [PI](#pi)

### DCP

The internal name of the platform makato-plan was originally built for. The Confluence space `DCPL` and the parent page id `2134905309` are DCP defaults that publish hard-codes (tracked as backlog item L4).

### story panel

Removed — the Jira/Confluence story panel concept no longer applies. The `publish` skill generates GitHub Issues and local handoff files instead.

### subtaskKeys

The object on each story in `stories.json` that maps subtask name → Jira key after `publish` runs. Used by Step 14 to update the Documentation subtask with the Confluence link. Keyed by name (`"Documentation": "DCP-..."`) rather than positionally — see audit item H3.

---

## Related Schemas (not glossary entries — defined elsewhere)

- `shared/repositories-yml-schema.md` — schema for `repositories.yml`
- `shared/scenario-schema.md` — Gherkin scenario shape (`given`/`when`/`then`/`and[]`)
- `shared/refinement-contract.md` — rules for "Refine" update mode
- `decompose/references/stories-json-schema.md` — full `stories.json` schema
- `create-acceptance-tests/references/acceptance-test-cases-schema.md` — scenario shape for `acceptanceTestCases[]`
- `decompose/references/phase-assignment-rules.md` — slicing phase decision matrix
- `publish/references/github-issue-template.md` — GitHub Issue body template used by `publish`
