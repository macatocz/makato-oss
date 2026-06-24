<!-- markdownlint-disable MD013 -->
# `slice-patterns.md` Rewrite + `status:` Label Dimension — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `to-issues` v3.2.0 — rewrite `references/slice-patterns.md` to drop dead k8s/AWS content and add four sagibeast-shaped tracer-bullet shapes (Web/API, Brain agent, Pipeline, Cross-cutting), then add `status:` as the 5th label dimension with `to-issues` auto-emitting `status:blocked` on creation when the issue cannot start (unresolved `blockedBy` OR `type:future-enhancement`). The remaining three workflow states (`status:todo` / `status:in-progress` / `status:done`) are documented in the taxonomy so labels exist on the repo, but transitions are deferred to a future `manage-github-project` skill (PR-B, out of scope).

**Architecture:** A single PR stacked on `feat/to-issues-future-enhancement` (PR #12, v3.1.0). Five files touched: a full rewrite of one reference file, additive edits to two reference files, a Step 3 wiring change in `SKILL.md` plus a frontmatter version bump, and a new changelog block. No code is added — all changes are markdown and skill directives. Verification is static (grep, YAML parse, CI gates). The change is backward-compatible: existing `stories.json` files infer exactly as in v3.1.0 and the new `status:` dimension is sparse (emitted only when applicable).

**Tech Stack:** Markdown only. No new dependencies. Python3 + `yaml` (already required by `to-issues` v3.0.0) used in verification.

## Global Constraints

- Skill home: `plugins/makato-plan/skills/to-issues/` (unchanged from v3.0.0 / v3.1.0; do not move).
- Branch: `feat/to-issues-slice-patterns-and-status`, stacked on `feat/to-issues-future-enhancement` (per spec D8). Already created and currently checked out at HEAD `6ef87e6` (spec commit).
- Version bump: `to-issues` SKILL.md frontmatter `3.1.0` → `3.2.0`. No other version touched (this is a minor bump, additive, fully backward-compatible — D5/D6 in the spec).
- Conventional-commit title: `feat(makato-plan): rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0)`.
- Self-contained: no `../` paths leaving the skill directory; only `plugins/makato-plan/skills/to-issues/references/*` and `plugins/makato-plan/skills/to-issues/SKILL.md` plus `plugins/makato-plan/CHANGELOG.md` are touched. `issue-template.md` and `created-issues.schema.json` are **not** modified (per spec — `status:blocked` is a label, not body content; `labels[]` is already `string[]`).
- Sparse-dimension rule (D5): `to-issues` emits a `status:*` label **only when non-default**. GitHub Projects auto-applies Todo on creation, so `status:todo` is never auto-emitted.
- Auto-emission scope (D6): `to-issues` only auto-emits `status:blocked`. `status:in-progress` / `status:done` are taxonomy values but lifecycle transitions are not in scope for this skill — they belong to PR-B (`manage-github-project`).
- Operator override (D6, spec §Error handling): if `stories[].labels` contains a literal `status:*` value, honor it verbatim — explicit always wins over inference.
- Inference rule (spec §Section 5): emit `status:blocked` when ANY of: (a) story has unresolved `dependencies.blockedBy` (upstream issue doesn't exist yet and hasn't been resolved by an earlier batch-mate); (b) story was inferred `type:future-enhancement` (per v3.1.0); (c) story explicitly carries `status:blocked` in `stories[].labels`.
- Conflict policy (spec §Error handling): an explicit `stories[].labels` entry that contradicts inference wins; autonomous-mode log records the override.
- Removed sections in `slice-patterns.md` (spec §Section 1 / D1 / D2): the entire `## Context Boundary Detection` block (k8s + AWS Infra + Ambiguity resolution subsections) and the entire `## Autonomous vs Needs Human Decision Tree` block. Plus the 5th checklist item ("Slice type — Autonomous or Needs Human") which was that tree's output.
- Tracer-bullet count (D3): exactly four named shapes (Web/API · Brain agent · Pipeline · Cross-cutting). Not two, not six. Config-only and lifecycle/governance work is acknowledged in prose as not tracer-shaped, not given a fifth recipe.
- Fourth shape name (D4): "Cross-cutting" — not "Wrapper", not "Intercept". Matches sagibeast's existing `context/codebase/architecture.md` vocabulary.
- Out-of-scope guardrails (spec §Out of scope / D7 / D9): no Project-board column sync, no `needs-human-review` governance label, no `status:in-progress` / `status:done` auto-emission. Don't sneak them in.
- No new CI checks: existing `scripts/check-root-structure.sh` and `scripts/check-skill-frontmatter.sh` cover the structural requirements. Add no new scripts.

---

## File Structure

| Status | Path | Responsibility |
|--------|------|----------------|
| Modify | `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` | Full rewrite: drop k8s/AWS context detection, drop autonomous-vs-human decision tree; add four tracer-bullet shapes; trim Issue Body Quality Checklist to 4 items |
| Modify | `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` | Bump opening line from "4-dimension" to "5-dimension"; add `status:` row to the dimensions table; add inference rules subsection for `status:`; add four `status:*` colors to the GitHub-label-creation color table |
| Modify | `plugins/makato-plan/skills/to-issues/SKILL.md` | Frontmatter `version: "3.1.0"` → `version: "3.2.0"`; update the `description:` value to mention the 5-dimension taxonomy; add step 5 to Step 3 (`status:` inference); document the new dimension in the Reference-Files list note that `status:` is sparse |
| Modify | `plugins/makato-plan/CHANGELOG.md` | Add a `**3.2.0**` block above the existing `**3.1.0**` block under `## \`to-issues\` skill` |
| Keep | `plugins/makato-plan/skills/to-issues/references/issue-template.md` | **No change** — `status:` is a label, not body content (spec §Architecture file-by-file) |
| Keep | `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` | **No change** — `labels[]` is already free-form `string[]` and accepts the new values |

---

## Task 1: Rewrite `slice-patterns.md`

**Files:**
- Modify: `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` (full rewrite)
- Test: no separate test file — verification is grep-based in Step 4 below

**Interfaces:**
- Consumes: nothing — this is a reference doc read by contributors during decompose / slicing. The skill loads it on demand when "a slice boundary is ambiguous or the caller asks about vertical-slicing strategy" (per `SKILL.md` Reference Files note).
- Produces: a markdown reference file with five `##` sections — one intro `## Tracer-Bullet Slice Pattern`, four `###` shape subsections (Web/API, Brain agent / LangGraph node, Pipeline, Cross-cutting), and one `## Issue Body Quality Checklist`. Target length ~110 lines (vs. current 66).

- [ ] **Step 1: Write the failing check**

```bash
# Capture the current file's distinguishing markers — these are the strings the new file must NOT contain.
grep -c "Context Boundary Detection" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 1 (currently present)
grep -c "Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 1
grep -c "context:k8s\|context:aws-infra" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 2

# Now define what the new file MUST contain.
grep -cE "Brain agent / LangGraph node tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 0 → after rewrite ≥1
grep -cE "Pipeline tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 0 → after rewrite ≥1
grep -cE "Cross-cutting tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 0 → after rewrite ≥1
grep -cE "Web/API tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 0 → after rewrite ≥1
```

Expected before edit: removed markers present, new markers absent.
Expected after edit: removed markers absent (grep returns 0), four new tracer-bullet headings present (each grep returns ≥1).

- [ ] **Step 2: Make the check pass**

Replace the entire file with the structure below. The four shapes are taken verbatim from spec §Section 2 (`2a`–`2d`) — do not paraphrase the layer lists or anti-patterns. The 4-item Issue Body Quality Checklist is taken from spec §Section 3.

File template (final content):

```markdown
# Slice Patterns Reference

> Expert patterns for vertical slice decomposition in the To Issues skill.

## Tracer-Bullet Slice Pattern

A tracer-bullet slice cuts end-to-end from input to observable output, touching every layer it must touch exactly once. The four shapes below correspond to the four data-flow topologies the sagibeast architecture relies on. Pick the shape that matches the work; if a feature spans the Brain↔Body boundary, issue separate slices for each side with `blocked_by` linking them (do not bundle).

### Web/API tracer-bullet

1. Route — FastAPI endpoint that accepts the request
2. Handler / orchestrator — translates HTTP to a domain call (auth, validation, response shaping)
3. Domain function — the actual feature logic, decoupled from FastAPI
4. Persistence — pgvector / Postgres read or write (raw SQL per ADR-0002)
5. Outside test — pytest hitting the route via TestClient, asserting observable output (no internal mocking)

**Anti-pattern:** horizontal slices ("all Postgres schema this sprint, all API endpoints next sprint"). Each horizontal layer is dead code until the others land.

### Brain agent / LangGraph node tracer-bullet

1. Trigger — Temporal workflow signal or chat-widget message entering the LangGraph graph
2. Node — the LangGraph state-graph node where work happens (typically wraps a PydanticAI agent)
3. Tool call — agent invokes a tool: skill execution, retrieval, memory read, body-API call
4. State write — Memory Service update (episodic / semantic / procedural per chapter 02) OR LangGraph state edit
5. Outside test — driven from the workflow boundary or node input, asserting state delta + agent response

**Anti-pattern:** implementing tool → node → prompt → trigger separately. Each step is dead code until the chain closes. Cut across all five from day one, even if the agent prompt is initially trivial.

### Pipeline tracer-bullet

1. Input source — file upload (Docling-fed PDF/IFC), batch trigger, or stream message
2. Transform — chunk, embed (BGE-M3), tokenise (PII), or convert (Docling)
3. Persist — pgvector vector store, Postgres table, or MinIO/S3 object
4. Retrievable query — the artifact must be reachable by a downstream query (similarity search, key lookup, presigned URL)
5. Outside test — drives the input, asserts the retrievable query returns the artifact in the expected shape

**Anti-pattern:** writing the ingest half without writing the query half. An artifact you can't retrieve is invisible; the slice isn't done until something can read it back.

### Cross-cutting tracer-bullet

1. Interception point — middleware position, decorator surface, LangGraph node wrapper, or Langfuse instrumentation hook
2. Augmentation — what the wrapper adds (auth claim, span emission, PII mask, sandbox policy)
3. Passthrough — call the wrapped function; the wrapper must not change the inner contract
4. Side effect — emitted span / written log / enforced policy outcome
5. Outside test — exercise a wrapped call, assert (a) inner contract preserved, (b) side effect observable

**Anti-pattern:** building the wrapper without exercising real wrapped calls in the test. Stub-only tests miss interaction bugs. A real call through real middleware is the only way to know the wrap composes correctly.

### Notes for all four shapes

- A slice may use a subset of layers (e.g. read-only slices have no persistence layer — say so explicitly in the issue body).
- Slices that span the Brain↔Body boundary force tracer-bullets on both sides. Issue them separately with `blocked_by` linking, never bundled.
- Config-only work (compose, helm, env wiring) is not tracer-shaped and does not need a 5-layer recipe — slice by environment (dev → staging → prod), validating smallest-possible at each step.
- Lifecycle / governance work (skill registration, project-board transitions, kill-switch toggles) is state-machine-shaped, not data-flow-shaped — represent as labels on the issue rather than forcing into a tracer.

## Issue Body Quality Checklist

A well-formed issue body must include:

1. **Context** — what part of the system this changes and why. For Brain work, name the chapter (e.g. "chapter 02 Memory Service"). For Body work, name the subsystem (ingest / RAG / API client / UI).
2. **What to build** — concrete description of the change. Reference which tracer-bullet shape applies and which of its 5 layers are touched.
3. **Acceptance criteria** — specific, testable conditions. The outside-test layer of the tracer-bullet is what the criteria assert on.
4. **Files** — exact file paths to create or modify, using the expected `src/` layout from sagibeast's `context/codebase/structure.md`.

Missing any of these forces the implementing agent to ask questions mid-session.
```

Write this content to `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` with the `Write` tool, overwriting in full.

- [ ] **Step 3: Refactor if needed**

After writing, run the negative grep first — removed sections must not survive in any form (substring or whole-section). If anything matches, the rewrite was incomplete and Step 2 must be redone. Then run the positive grep — four tracer-bullet headings present.

- [ ] **Step 4: Verify**

```bash
# REMOVED content — all four must be zero
grep -c "Context Boundary Detection" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "context:k8s\|context:aws-infra" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "Slice type" plugins/makato-plan/skills/to-issues/references/slice-patterns.md

# PRESENT content — all four must be ≥1
grep -c "### Web/API tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "### Brain agent / LangGraph node tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "### Pipeline tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md
grep -c "### Cross-cutting tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md

# STRUCTURE — exactly four ### tracer-bullet shapes and exactly two ## sections that survive
grep -cE '^### .+ tracer-bullet$' plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 4
grep -cE '^## (Tracer-Bullet Slice Pattern|Issue Body Quality Checklist)$' plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # expect 2

# Length sanity — target ~110 lines, accept 90–130
LINES=$(wc -l < plugins/makato-plan/skills/to-issues/references/slice-patterns.md)
[ "$LINES" -ge 90 ] && [ "$LINES" -le 130 ] && echo "PASS length=$LINES" || { echo "FAIL length=$LINES (want 90–130)"; exit 1; }
```

All commands above must produce the expected counts. If any grep on REMOVED returns >0, the file still has dead content and Task 1 is incomplete. If any grep on PRESENT returns 0, the new shape headings aren't right.

---

## Task 2: Add `status:` dimension to `label-taxonomy.md`

**Files:**
- Modify: `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md`
- Test: no separate test file — verification is grep-based

**Interfaces:**
- Consumes: nothing.
- Produces: an updated taxonomy with a 5th row in the dimensions table for `status:`, a new `## Status Dimension` subsection documenting the four values and the inference rules, and four new entries (`status:todo` / `status:in-progress` / `status:done` / `status:blocked`) in the GitHub-label-creation color table. The opening sentence updated from "4-dimension label set" → "5-dimension label set" with the sparse-dimension caveat.

- [ ] **Step 1: Write the failing check**

```bash
# Current state markers — these MUST change after Task 2.
grep -c "single source of truth for the 4-dimension label set" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 1 before, 0 after
grep -c "The 4 Dimensions" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 1 before, 0 after

# Target state markers — these MUST exist after Task 2.
grep -c "5-dimension label set" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, 1 after
grep -c "The 5 Dimensions" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, 1 after
grep -c "Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, ≥1 after
grep -c "status:blocked" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, ≥3 after (table, rules, colors)
grep -c "status:todo" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, ≥2 after
grep -c "B60205" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, 1 after (blocked color)
grep -c "FBCA04" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0 before, 1 after (in-progress color)
```

- [ ] **Step 2: Make the check pass**

Make four targeted edits (use the `Edit` tool — do not rewrite the file in full; the existing content stays).

**Edit 2a — opening line.** Replace:

```
> Single source of truth for the 4-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file.
```

with:

```
> Single source of truth for the 5-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file. The `status:` dimension is **sparse** — emitted only when the status is non-default; the other four (`type:` / `tier:` / `tech:` / `module:`) are emitted whenever a value can be resolved.
```

**Edit 2b — section heading.** Replace `## The 4 Dimensions` with `## The 5 Dimensions`. Also update the paragraph immediately below it to read:

```
Every issue created by `to-issues` carries one label from each applicable dimension. The first four (`type:` / `tier:` / `tech:` / `module:`) are emitted whenever a value can be resolved; the fifth (`status:`) is sparse — emitted only when the status is non-default (see `Status Dimension` below). A dimension with no resolved value is omitted (the issue is still created).
```

**Edit 2c — extend the dimensions table.** Append a row for `status:` below the existing `module:` row. The full table after this edit reads:

```markdown
| Dimension | Source | Examples |
|-----------|--------|----------|
| **type** | Inferred from story title/body keywords (see table below) | `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore`, `type:future-enhancement` |
| **tier** | `stories[].phase` in `stories.json` (skipped entirely for `type:future-enhancement` — those issues are pre-phase) | `tier:foundation`, `tier:happy-path`, `tier:edge-cases` |
| **tech** | Default keyword list, extensible via `config.json` `labels.tech` | `tech:python`, `tech:bash`, `tech:sql`, `tech:fastapi`, `tech:temporal`, `tech:langgraph`, `tech:pydantic-ai`, `tech:harness`, `tech:skill`, `tech:html`, `tech:react` |
| **module** | ADR folder-name match (see algorithm), extensible via `config.json` `labels.modules` | `module:to-issues`, `module:auth-service`, `module:billing` |
| **status** *(sparse)* | Inferred from `dependencies.blockedBy` + `type:future-enhancement` + explicit `stories[].labels` (see `Status Dimension` below) | `status:blocked` *(auto)*, `status:todo` / `status:in-progress` / `status:done` *(reserved for future `manage-github-project` skill — not auto-emitted)* |
```

**Edit 2d — insert the `## Status Dimension` section.** Place this new section between the closing `## Config-Extension Contract` section and the existing `## GitHub Label Creation` section (or, equivalently, immediately above `## GitHub Label Creation` — the goal is "after the config contract, before the label-creation table").

```markdown
## Status Dimension

The sagibeast GitHub Project board has a 4-value `Status` field that maps 1:1 to the four `status:*` labels:

| Project board status | Color | Description (from project board) | Label |
|---|---|---|---|
| Todo | green (`0E8A16`) | This item hasn't been started | `status:todo` *(default — usually omitted; GitHub Projects auto-applies Todo)* |
| In Progress | yellow (`FBCA04`) | This is actively being worked on | `status:in-progress` *(reserved — not auto-emitted by to-issues)* |
| Done | deep purple (`5319E7`) | This has been completed | `status:done` *(reserved — not auto-emitted by to-issues)* |
| Blocked | red (`B60205`) | Currently waiting until there is implemented prerequisity issue or when the project is in shape when it can be implemented | `status:blocked` *(auto-emitted on creation when applicable)* |

### What `to-issues` auto-emits

`to-issues` only auto-emits one `status:*` value on issue creation: **`status:blocked`**. It is emitted when ANY of the following apply:

1. **Unresolved upstream dependency.** The story has `dependencies.blockedBy` IDs that do not yet exist in the same batch and were not resolved by an earlier batch-mate. "Unresolved" is evaluated after topological sort; a blocker that was created earlier in the same `to-issues` run counts as resolved.
2. **`type:future-enhancement` was inferred** (per v3.1.0, PR #12). Future-enhancement issues are parked-until-condition-met, which matches the project board's Blocked description verbatim ("when the project is in shape when it can be implemented").
3. **Explicit operator override.** The story's `stories[].labels` array contains the literal string `status:blocked`.

`status:in-progress` and `status:done` are taxonomy values so the labels exist on the repo (and downstream skills can apply them), but they are **never** auto-emitted by `to-issues` — lifecycle transitions (PR opened → In Progress, PR merged → Done) are downstream of issue creation and belong to a separate `manage-github-project` skill (out of scope for this skill).

### Operator-override priority

If `stories[].labels` contains a literal `status:*` value, it is honored verbatim regardless of inference. When an explicit value contradicts an inferred one (e.g. story has `dependencies.blockedBy: [42]` AND `stories[].labels: ["status:todo"]`), the explicit value wins and the autonomous-mode log records:

```
[to-issues:auto] story <n>: status inference (blocked) overridden by explicit label (status:todo)
```

### Soft-warning for dangling `blockedBy`

If `dependencies.blockedBy` references an integer ID that doesn't exist anywhere in the batch and wasn't created earlier in the same run, the story is still emitted with `status:blocked`. The body's `Blocked by:` line will show `#<id> (_unresolved_)` for that ID; the autonomous-mode log records:

```
[to-issues:auto] story <n>: dangling blockedBy reference #<id> — issue still created with status:blocked, human follow-up required
```

This is a warning, not a halt — the human resolves the dangling reference manually.
```

**Edit 2e — extend the label color table AND recolor `tier:`.** Find the existing `## GitHub Label Creation` color table. Two changes:

1. **Migrate the existing `tier:` row** from `5319E7` (purple) to `8B5CF6` (violet). Reason: `5319E7` is being claimed by `status:done` to match the sagibeast project board exactly, so `tier:` moves to a clearly-lighter purple-family hue to avoid the collision (spec D10).
2. **Append four new `status:*` rows** below the existing `module:` row.

The full color table after this edit reads:

```markdown
| Prefix     | Color (hex) |
|------------|-------------|
| `type:`    | `1D76DB` (blue) |
| `type:future-enhancement` | `D4C5F9` (lavender — distinguishes from active `type:` work at a glance) |
| `tier:`    | `8B5CF6` (violet — migrated from `5319E7` purple in v3.2.0 to free that hex for `status:done`) |
| `tech:`    | `0E8A16` (green) |
| `module:`  | `BFD4F2` (light blue) |
| `status:todo` | `0E8A16` (green — matches project board; same hue as `tech:` is acceptable since `status:todo` is reserved-never-auto-emitted) |
| `status:in-progress` | `FBCA04` (yellow — matches project board) |
| `status:done` | `5319E7` (deep purple — matches project board) |
| `status:blocked` | `B60205` (red — matches project board; aligns with GitHub's red-for-blocker convention) |
```

**Note on existing repos:** `gh label create` skips silently when a label of the same name already exists; it does NOT overwrite color. Repos that already have a `tier:*` label set with the old `5319E7` color will keep that color on existing labels — the new `8B5CF6` only applies to fresh labels created in repos where `tier:*` doesn't yet exist. To force-recolor existing repos, run `gh label edit "tier:foundation" --color 8B5CF6 --repo $TARGET_REPO` etc. manually. This is documented behavior, not a regression — v3.0.0 already worked this way.

- [ ] **Step 3: Refactor if needed**

Read the file back end-to-end after the five edits. Confirm: (a) no orphan "4 Dimensions" phrasing survives anywhere; (b) the `Status Dimension` subsection lives BETWEEN `## Config-Extension Contract` and `## GitHub Label Creation` (not after the color table); (c) the dimensions table at the top still has exactly one row per dimension with no duplicates.

- [ ] **Step 4: Verify**

```bash
# Required content after edits
grep -c "5-dimension label set" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md           # expect 1
grep -c "^## The 5 Dimensions" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md           # expect 1
grep -c "^## Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md           # expect 1
grep -c "^### What \`to-issues\` auto-emits" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 1
grep -c "^### Operator-override priority" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md    # expect 1
grep -c "^### Soft-warning for dangling \`blockedBy\`" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 1
grep -c "status:blocked" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                 # expect ≥4
grep -c "status:todo\|status:in-progress\|status:done" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect ≥6
grep -c "B60205" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                          # expect 1
grep -c "FBCA04" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                          # expect 1
grep -c "8B5CF6" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                          # expect 1 (new tier: color)

# Forbidden content after edits (the old "4-dimension" phrasing must be gone)
grep -c "4-dimension label set\|^## The 4 Dimensions" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # expect 0

# Color-collision sanity — 5319E7 must appear EXACTLY once (status:done only; tier: has been migrated)
grep -c "5319E7" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                          # expect 1
# And the row claiming 5319E7 must be the status:done row, not the tier: row
grep -E "^\| .status:done.* .5319E7" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md     # must match
grep -cE "^\| .tier:.* .5319E7" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md          # expect 0
grep -cE "^\| .tier:.* .8B5CF6" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md          # expect 1

# Structural ordering — Status Dimension must come BEFORE GitHub Label Creation
STATUS_LINE=$(grep -n "^## Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md | head -1 | cut -d: -f1)
LABELS_LINE=$(grep -n "^## GitHub Label Creation" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md | head -1 | cut -d: -f1)
[ "$STATUS_LINE" -lt "$LABELS_LINE" ] && echo "PASS order" || { echo "FAIL ordering: Status@$STATUS_LINE, Labels@$LABELS_LINE"; exit 1; }
```

Every assertion above must hold.

---

## Task 3: Wire `status:` inference into `SKILL.md`

**Files:**
- Modify: `plugins/makato-plan/skills/to-issues/SKILL.md`
- Test: YAML frontmatter parse + grep-based verification

**Interfaces:**
- Consumes: the new `## Status Dimension` section in `label-taxonomy.md` (Task 2) — `SKILL.md` Step 3 references it for the exact inference rules so this file does not duplicate the rule text.
- Produces: an updated SKILL.md with: (a) frontmatter `version: "3.1.0"` → `version: "3.2.0"`; (b) `description:` updated from "4-dimension label taxonomy" → "5-dimension label taxonomy"; (c) a new bullet 5 in Step 3 ("Infer labels per story") for `status:`; (d) a note in the Reference Files list mentioning the new dimension.

- [ ] **Step 1: Write the failing check**

```bash
# Current state
grep -c '^version: "3.1.0"$' plugins/makato-plan/skills/to-issues/SKILL.md   # expect 1
grep -c '^version: "3.2.0"$' plugins/makato-plan/skills/to-issues/SKILL.md   # expect 0
grep -c "4-dimension label taxonomy" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 1
grep -c "5-dimension label taxonomy" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 0
grep -c "^5\. \*\*status\*\*" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 0 (new bullet)
```

- [ ] **Step 2: Make the check pass**

Make four targeted `Edit`s:

**Edit 3a — frontmatter version bump.** Replace `version: "3.1.0"` with `version: "3.2.0"`.

**Edit 3b — frontmatter description.** In the `description:` block, replace `4-dimension label taxonomy` with `5-dimension label taxonomy` and replace `(type/tier/tech/module)` with `(type/tier/tech/module/status)`. The full description after edit reads:

```yaml
description: >-
  Use when user wants to convert a plan into issues, create implementation tickets, or break
  down a feature into GitHub issues. Generic across makato consumers — reads `.claude/config.json`
  for project name, targets `github.com`, applies a 5-dimension label taxonomy
  (type/tier/tech/module/status), maps stories to ADR folders by name pattern, and emits
  `specs/{slug}/created-issues.json` for downstream plugins.
```

**Edit 3c — bump `last_updated`.** Replace `last_updated: "2026-06-23"` with `last_updated: "2026-06-24"` so the frontmatter reflects the v3.2.0 cut date.

**Edit 3d — add bullet 5 in Step 3 (label inference loop).** Currently Step 3 has four numbered bullets (`type` / `tier` / `tech` / `module`). Append a fifth between bullet 4 (`module`) and the paragraph that begins "In `--interactive` mode...". The bullet reads:

```markdown
5. **status**: emit `status:blocked` when ANY of the following hold, otherwise omit the `status:` dimension entirely (sparse — see `references/label-taxonomy.md` `## Status Dimension`):
   - The story's `dependencies.blockedBy` contains an integer ID that is unresolved at the point of issue creation. "Unresolved" means: (a) the upstream story has no corresponding GitHub issue yet AND (b) the upstream story was not created earlier in the current batch's topological order. Dangling references (ID not in batch at all) also emit `status:blocked` with a soft-warning log line.
   - The story was inferred as `type:future-enhancement` in bullet 1 above (per v3.1.0).
   - The story's `stories[].labels` array contains the literal string `status:blocked` (explicit operator override).
   When an explicit `stories[].labels` value contradicts inference (e.g. the operator wrote `status:todo` on a story that would otherwise infer `status:blocked`), the explicit value wins; log `[to-issues:auto] story <n>: status inference (<inferred>) overridden by explicit label (<explicit>)`.
   `status:in-progress` and `status:done` are taxonomy values but are **never** auto-emitted by this skill — lifecycle transitions belong to a future `manage-github-project` skill.
```

**Edit 3e — Reference Files note.** In the Reference Files section, the line that currently reads:

```
- **MANDATORY** — load `references/label-taxonomy.md` for the 4-dimension taxonomy, type-inference table, ADR-match algorithm, and config-extension contract.
```

becomes:

```
- **MANDATORY** — load `references/label-taxonomy.md` for the 5-dimension taxonomy (`type:` / `tier:` / `tech:` / `module:` / `status:`), type-inference table, ADR-match algorithm, config-extension contract, and the sparse `status:` inference rules in `## Status Dimension`.
```

- [ ] **Step 3: Refactor if needed**

Confirm Step 3's numbered list still parses as a contiguous 1–5 list (no blank line breaking the numbering). Confirm the new bullet 5 appears BEFORE the "In `--interactive` mode..." paragraph (not after — that paragraph applies to the whole list).

- [ ] **Step 4: Verify**

```bash
# Frontmatter
grep -c '^version: "3.2.0"$' plugins/makato-plan/skills/to-issues/SKILL.md   # expect 1
grep -c '^version: "3.1.0"$' plugins/makato-plan/skills/to-issues/SKILL.md   # expect 0
grep -c '^  last_updated: "2026-06-24"$' plugins/makato-plan/skills/to-issues/SKILL.md  # expect 1
grep -c "5-dimension label taxonomy" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 1
grep -c "type/tier/tech/module/status" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 1
grep -c "4-dimension label taxonomy" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 0

# Step 3 wiring
grep -c "^5\. \*\*status\*\*:" plugins/makato-plan/skills/to-issues/SKILL.md  # expect 1
grep -c "status:blocked" plugins/makato-plan/skills/to-issues/SKILL.md  # expect ≥3

# Reference-files note
grep -c "5-dimension taxonomy" plugins/makato-plan/skills/to-issues/SKILL.md  # expect ≥1
grep -c "Status Dimension" plugins/makato-plan/skills/to-issues/SKILL.md  # expect ≥1

# YAML frontmatter still parses
python3 -c "
import yaml
with open('plugins/makato-plan/skills/to-issues/SKILL.md') as f:
    body = f.read()
fm = body.split('---')[1]
data = yaml.safe_load(fm)
assert data['version'] == '3.2.0', f'version={data[\"version\"]!r}'
assert data['name'] == 'to-issues'
assert 'github.com' in data['description']
print('PASS yaml')
"

# CI gate must still pass
bash scripts/check-skill-frontmatter.sh plugins/makato-plan/skills/to-issues
```

All assertions and both scripts must succeed.

---

## Task 4: CHANGELOG entry for v3.2.0

**Files:**
- Modify: `plugins/makato-plan/CHANGELOG.md`
- Test: grep-based ordering check

**Interfaces:**
- Consumes: nothing.
- Produces: a new `**3.2.0**` block inserted directly above the existing `**3.1.0**` block under `## \`to-issues\` skill`. Mirrors the bullet style of the v3.1.0 entry (which is right above the v3.0.0 BREAKING entry).

- [ ] **Step 1: Write the failing check**

```bash
# 3.2.0 must not exist yet
grep -c "^- \*\*3\.2\.0\*\*$" plugins/makato-plan/CHANGELOG.md  # expect 0

# But under to-issues we should already have 3.1.0 and 3.0.0
awk '/^## `to-issues` skill$/,/^## /' plugins/makato-plan/CHANGELOG.md | grep -c '^- \*\*3\.[01]\.0\*\*$'  # expect 2 before edit
```

- [ ] **Step 2: Make the check pass**

Insert this block IMMEDIATELY above the existing `- **3.1.0**` block under `## \`to-issues\` skill` (do not duplicate or move the existing 3.1.0 block):

```markdown
- **3.2.0**
  - Rewrote `references/slice-patterns.md` for sagibeast topology — dropped `Context Boundary Detection` (k8s + AWS context labels that aren't in the v3.0.0 taxonomy and don't match sagibeast's stack) and dropped `Autonomous vs Needs Human Decision Tree` (governance signals belong on labels, not in a decision tree)
  - Added four named tracer-bullet shapes covering ~80% of sagibeast's data-flow topologies: **Web/API** (FastAPI request/response), **Brain agent / LangGraph node** (agent reasoning), **Pipeline** (Docling/BGE-M3/pgvector/MinIO ingest+query), **Cross-cutting** (middleware / Langfuse instrumentation / sandbox policy wraps). Each shape has 5 layers + an anti-pattern callout. Config-only and lifecycle/governance work are explicitly NOT tracer-shaped and handled in prose
  - Trimmed `Issue Body Quality Checklist` from 5 items to 4 (dropped the obsolete "Slice type — Autonomous or Needs Human" item)
  - Added `status:` as the **5th label dimension** (sparse — emitted only when non-default). Four documented values match the sagibeast GitHub Project board's `Status` field: `status:todo` (green `0E8A16`), `status:in-progress` (yellow `FBCA04`), `status:done` (purple `5319E7`), `status:blocked` (red `B60205`)
  - `to-issues` auto-emits **only** `status:blocked` on creation, when ANY of: (a) story has unresolved `dependencies.blockedBy`, (b) story was inferred as `type:future-enhancement`, (c) story's `stories[].labels` array contains the literal `status:blocked`
  - `status:in-progress` and `status:done` are reserved in the taxonomy so labels exist on the repo, but lifecycle transitions are deferred to a future `manage-github-project` skill (out of scope for v3.2.0)
  - Explicit operator override: any `status:*` value present in `stories[].labels` wins over inference; conflicts are logged in autonomous mode
  - `label-taxonomy.md` opening updated from "4-dimension label set" → "5-dimension label set" with a note that `status:` is sparse; dimensions table extended with a 5th row; new `## Status Dimension` subsection added; GitHub-label-creation color table extended with the four `status:*` colors. **`tier:` migrated from `5319E7` (purple) to `8B5CF6` (violet)** to free `5319E7` for `status:done`'s exact project-board match. `gh label create` is no-op-on-existing, so existing `tier:*` labels keep their old color — to force-recolor, run `gh label edit "tier:foundation" --color 8B5CF6 ...` manually.
  - `SKILL.md` Step 3 inference loop gains a 5th bullet (`status:`) that delegates to `references/label-taxonomy.md` `## Status Dimension` for rules. Reference-Files note updated to mention the 5th dimension. Description frontmatter updated from `(type/tier/tech/module)` → `(type/tier/tech/module/status)`
  - Backward compatible: existing `stories.json` infer exactly as in v3.1.0; the `status:` dimension is purely additive and sparse. No schema changes to `created-issues.schema.json` (labels[] already accepts the new values); no body-template changes to `issue-template.md` (status is a label, not body content)
  - Out of scope (deferred to future PRs): GitHub Project board column sync (PR-B `manage-github-project`); `needs-human-review` governance signal (would belong to a separate `review:` dimension if wanted later)
```

- [ ] **Step 3: Refactor if needed**

Verify the v3.2.0 block sits ABOVE the v3.1.0 block (latest-on-top is the file convention per the top-of-file note). Verify no whitespace was lost between the new block and the next-down v3.1.0 block.

- [ ] **Step 4: Verify**

```bash
# New entry present
grep -c '^- \*\*3\.2\.0\*\*$' plugins/makato-plan/CHANGELOG.md  # expect 1

# Old entries still present
grep -c '^- \*\*3\.1\.0\*\*$' plugins/makato-plan/CHANGELOG.md  # expect 1
grep -c '^- \*\*3\.0\.0\*\* (BREAKING)$' plugins/makato-plan/CHANGELOG.md  # expect 1

# Ordering: 3.2.0 above 3.1.0 above 3.0.0 in the to-issues section
ORDER=$(awk '/^## `to-issues` skill$/{f=1; next} /^## /{f=0} f' plugins/makato-plan/CHANGELOG.md | grep -E '^- \*\*3\.[012]\.0\*\*' | sed -E 's/^- \*\*([0-9.]+)\*\*.*/\1/')
EXPECTED=$'3.2.0\n3.1.0\n3.0.0'
[ "$ORDER" = "$EXPECTED" ] && echo "PASS order" || { echo "FAIL order:"; echo "$ORDER"; exit 1; }

# 3.2.0 block references each of: slice-patterns, status:, four shapes, blocked
awk '/^- \*\*3\.2\.0\*\*$/,/^- \*\*3\.1\.0\*\*$/' plugins/makato-plan/CHANGELOG.md | grep -c "slice-patterns"  # ≥1
awk '/^- \*\*3\.2\.0\*\*$/,/^- \*\*3\.1\.0\*\*$/' plugins/makato-plan/CHANGELOG.md | grep -c "status:blocked"  # ≥1
awk '/^- \*\*3\.2\.0\*\*$/,/^- \*\*3\.1\.0\*\*$/' plugins/makato-plan/CHANGELOG.md | grep -c "Cross-cutting\|Pipeline\|Brain agent\|Web/API"  # ≥1
```

---

## Task 5: Integration verification — full skill validation

**Files:**
- No file changes.
- Test: composite CI/CD-equivalent run.

**Interfaces:**
- Consumes: the four files modified in Tasks 1–4.
- Produces: a green verification report. This task is a final gate before the commit in Task 6.

- [ ] **Step 1: Write the failing check**

(Implicit — Tasks 1–4 must already have passed their own Step-4 verifications. This task re-runs them holistically plus repo-level CI gates.)

- [ ] **Step 2: Make the check pass**

No changes — only run verification.

- [ ] **Step 3: Refactor if needed**

If any verification below fails, return to the originating task and fix.

- [ ] **Step 4: Verify**

```bash
set -e
echo "=== A. Files exist and have expected sizes ==="
ls -l plugins/makato-plan/skills/to-issues/references/slice-patterns.md
ls -l plugins/makato-plan/skills/to-issues/references/label-taxonomy.md
ls -l plugins/makato-plan/skills/to-issues/SKILL.md
ls -l plugins/makato-plan/CHANGELOG.md

echo "=== B. CI gates ==="
bash scripts/check-skill-frontmatter.sh plugins/makato-plan/skills/to-issues
bash scripts/check-root-structure.sh

echo "=== C. YAML frontmatter parses with v3.2.0 ==="
python3 -c "
import yaml
body = open('plugins/makato-plan/skills/to-issues/SKILL.md').read()
fm = body.split('---', 2)[1]
data = yaml.safe_load(fm)
assert data['version'] == '3.2.0', f'version={data[\"version\"]!r}'
assert data['metadata']['last_updated'] == '2026-06-24'
assert 'type/tier/tech/module/status' in data['description']
print('PASS yaml v3.2.0')
"

echo "=== D. slice-patterns.md content (Task 1) ==="
grep -c "Context Boundary Detection" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # 0
grep -c "Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # 0
grep -cE '^### .+ tracer-bullet$' plugins/makato-plan/skills/to-issues/references/slice-patterns.md   # 4

echo "=== E. label-taxonomy.md content (Task 2) ==="
grep -c "5-dimension label set" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # 1
grep -c "^## Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # 1
grep -c "B60205" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # 1
grep -c "FBCA04" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # 1
grep -c "8B5CF6" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md  # 1 (new tier: color)

echo "=== E2. Color-collision guarantee ==="
# 5319E7 appears EXACTLY once (claimed by status:done; tier: has been migrated)
[ "$(grep -c '5319E7' plugins/makato-plan/skills/to-issues/references/label-taxonomy.md)" = "1" ] && echo "PASS 5319E7 unique" || { echo "FAIL: 5319E7 appears multiple times"; exit 1; }
# And the row holding 5319E7 is the status:done row
grep -qE '^\| .status:done.* .5319E7' plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "PASS status:done owns 5319E7" || { echo "FAIL: 5319E7 not on status:done row"; exit 1; }
# The tier: row holds 8B5CF6, not 5319E7
grep -qE '^\| .tier:.* .8B5CF6' plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "PASS tier: owns 8B5CF6" || { echo "FAIL: tier: not migrated"; exit 1; }

echo "=== F. SKILL.md wiring (Task 3) ==="
grep -c '^version: "3.2.0"$' plugins/makato-plan/skills/to-issues/SKILL.md  # 1
grep -c "^5\. \*\*status\*\*:" plugins/makato-plan/skills/to-issues/SKILL.md  # 1

echo "=== G. CHANGELOG entry (Task 4) ==="
grep -c '^- \*\*3\.2\.0\*\*$' plugins/makato-plan/CHANGELOG.md  # 1

echo "=== H. Cross-file consistency ==="
# If SKILL.md references 'Status Dimension', that exact heading must exist in taxonomy
grep -q "Status Dimension" plugins/makato-plan/skills/to-issues/SKILL.md && \
  grep -q "^## Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && \
  echo "PASS cross-ref" || { echo "FAIL: SKILL.md references missing heading"; exit 1; }

# No dead references to removed slice-patterns sections from SKILL.md
grep -c "Context Boundary Detection\|Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/SKILL.md  # 0

# v3.2.0 referenced in changelog AND frontmatter — version coherence
CHANGELOG_VER=$(grep -m1 '^- \*\*3\.[0-9]\+\.0\*\*' plugins/makato-plan/CHANGELOG.md | sed -E 's/^- \*\*([0-9.]+)\*\*.*/\1/')
FRONTMATTER_VER=$(awk '/^---$/{c++; next} c==1 && /^version:/{gsub(/"|version: /, ""); print; exit}' plugins/makato-plan/skills/to-issues/SKILL.md)
[ "$CHANGELOG_VER" = "$FRONTMATTER_VER" ] && echo "PASS version coherence ($CHANGELOG_VER)" || { echo "FAIL: changelog=$CHANGELOG_VER frontmatter=$FRONTMATTER_VER"; exit 1; }

echo "=== ALL VERIFICATION PASSED ==="
```

Every step in the script above must run without error. The final line must print.

---

## Task 6: Commit and push

**Files:**
- No content changes — only git operations.

**Interfaces:**
- Consumes: the verified working tree from Task 5.
- Produces: one conventional commit on `feat/to-issues-slice-patterns-and-status` and a push to the remote that opens (or refreshes) a PR.

- [ ] **Step 1: Stage and review the diff one last time**

```bash
git -C "$REPO_ROOT" status --short
git -C "$REPO_ROOT" diff --stat
```

Expected files in the diff (exactly 4):
- `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` (rewrite)
- `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` (additive)
- `plugins/makato-plan/skills/to-issues/SKILL.md` (additive + version bump)
- `plugins/makato-plan/CHANGELOG.md` (additive)

If any other file appears in the diff, investigate before committing.

- [ ] **Step 2: Commit**

```bash
git -C "$REPO_ROOT" add \
  plugins/makato-plan/skills/to-issues/references/slice-patterns.md \
  plugins/makato-plan/skills/to-issues/references/label-taxonomy.md \
  plugins/makato-plan/skills/to-issues/SKILL.md \
  plugins/makato-plan/CHANGELOG.md

git -C "$REPO_ROOT" commit -m "feat(makato-plan): rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0)" \
  -m "Rewrites references/slice-patterns.md with four sagibeast-shaped tracer-bullet shapes (Web/API, Brain agent / LangGraph node, Pipeline, Cross-cutting) replacing the legacy k8s/AWS context-detection and the obsolete autonomous-vs-needs-human decision tree. Issue Body Quality Checklist trimmed to 4 items." \
  -m "Adds status: as the 5th label dimension in references/label-taxonomy.md. Four values match the sagibeast GitHub Project board (status:todo/in-progress/done/blocked). to-issues auto-emits only status:blocked on creation when blockedBy is unresolved, type:future-enhancement was inferred, or stories[].labels carries the explicit value. Other status values are reserved for the future manage-github-project skill (out of scope)." \
  -m "Backward compatible. No schema changes; no body-template changes. SKILL.md version 3.1.0 -> 3.2.0."
```

- [ ] **Step 3: Push**

```bash
git -C "$REPO_ROOT" push -u origin feat/to-issues-slice-patterns-and-status
```

- [ ] **Step 4: Verify**

```bash
# Local branch state
git -C "$REPO_ROOT" log --oneline -3   # newest commit = the v3.2.0 commit; previous = 6ef87e6 spec; previous = 49a5e58 v3.1.0
git -C "$REPO_ROOT" status             # working tree clean
git -C "$REPO_ROOT" branch --show-current  # feat/to-issues-slice-patterns-and-status

# Remote tracking
git -C "$REPO_ROOT" rev-parse HEAD
git -C "$REPO_ROOT" rev-parse @{u}     # equal to HEAD after push
```

Newest commit subject line must match exactly: `feat(makato-plan): rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0)`.

---

## Task 7: Open the PR (or refresh if already open)

**Files:**
- No file changes.

**Interfaces:**
- Consumes: the pushed branch from Task 6.
- Produces: an open GitHub PR on `github.com/zstary/makato` against `main`, stacked on top of PR #12 (which is itself open against `main`). The PR description references the spec at `docs/superpowers/specs/2026-06-24-slice-patterns-and-status-labels-design.md`.

- [ ] **Step 1: Check whether PR is already open**

```bash
GH_HOST=github.com gh pr list --repo zstary/makato --head feat/to-issues-slice-patterns-and-status --json number,state,baseRefName,headRefName --jq '.[]'
```

If a row is returned with `state: OPEN`, skip to Step 4 (the PR already exists and the push from Task 6 has updated it).

- [ ] **Step 2: Create the PR**

```bash
GH_HOST=github.com gh pr create --repo zstary/makato \
  --base main \
  --head feat/to-issues-slice-patterns-and-status \
  --title "feat(makato-plan): rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0)" \
  --body "$(cat <<'EOF'
## Summary

Ships `to-issues` **v3.2.0** — two coupled changes in one PR.

1. **`slice-patterns.md` rewrite.** Drops dead k8s/AWS context detection (labels not in v3.0.0 taxonomy, stack not in sagibeast) and the obsolete autonomous-vs-needs-human decision tree (governance belongs on labels). Adds four sagibeast-shaped tracer-bullet shapes — **Web/API**, **Brain agent / LangGraph node**, **Pipeline**, **Cross-cutting** — covering ~80% of sagibeast's data-flow topologies. Each shape has 5 layers + an anti-pattern callout.
2. **`status:` label dimension.** New 5th dimension, sparse (emitted only when non-default). Four values match the sagibeast GitHub Project board (`Todo` / `In Progress` / `Done` / `Blocked`). `to-issues` auto-emits **only `status:blocked`** when ANY of: (a) unresolved `dependencies.blockedBy`, (b) `type:future-enhancement` inferred, (c) explicit `status:blocked` in `stories[].labels`. The other three values are reserved in the taxonomy so labels exist on the repo, but lifecycle transitions belong to a future `manage-github-project` skill (out of scope — PR-B).

Stacked on top of [#12](https://github.com/zstary/makato/pull/12) (v3.1.0 `type:future-enhancement`). The base branch ref will need to be updated to `main` once #12 merges, or this PR will rebase cleanly when #12 lands first.

## Behavior table

| Story shape | Before (v3.1.0) | After (v3.2.0) |
|---|---|---|
| Story with no `blockedBy`, normal `type:feat` | `type:feat, tier:foundation, tech:python, module:body-api` | unchanged |
| Story with unresolved `blockedBy: [42]` (no such issue yet) | same as above + `Blocked by: #42` line in body | same + `status:blocked` label |
| Story with `type:future-enhancement` keywords | `type:future-enhancement, tech:..., module:...` | same + `status:blocked` label |
| Story with explicit `status:todo` in `stories[].labels` even though `blockedBy` is unresolved | inferred `type:feat...` (status not in v3.1.0) | `type:feat..., status:todo` (explicit wins, autonomous-mode log records the override) |

## Goal Alignment

- Sagibeast GitHub Project board has a 4-value `Status` field. `to-issues` now emits a label that surfaces issues which cannot start immediately (`status:blocked`), while leaving lifecycle transitions to a dedicated downstream skill (`manage-github-project`, PR-B).
- `slice-patterns.md` becomes a useful sagibeast-shaped reference instead of dead legacy content.
- Both changes ship in one focused PR because (a) they share the same skill, (b) both bump the minor version, (c) the same brainstorm decided them.

## Spec

Full design spec: [`docs/superpowers/specs/2026-06-24-slice-patterns-and-status-labels-design.md`](../blob/feat/to-issues-slice-patterns-and-status/docs/superpowers/specs/2026-06-24-slice-patterns-and-status-labels-design.md) (committed as 6ef87e6).

## How to Test

```bash
# Static verification (no runtime — this is a markdown + bash skill)
bash scripts/check-skill-frontmatter.sh plugins/makato-plan/skills/to-issues
bash scripts/check-root-structure.sh
python3 -c "import yaml; d=yaml.safe_load(open('plugins/makato-plan/skills/to-issues/SKILL.md').read().split('---',2)[1]); assert d['version']=='3.2.0'"

# Content checks
grep -c "Context Boundary Detection\|Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/references/slice-patterns.md   # expect 0
grep -cE '^### .+ tracer-bullet$' plugins/makato-plan/skills/to-issues/references/slice-patterns.md                                  # expect 4
grep -c "^## Status Dimension" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                                     # expect 1
grep -c "5-dimension label set" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md                                    # expect 1
grep -c "^5\. \*\*status\*\*:" plugins/makato-plan/skills/to-issues/SKILL.md                                                          # expect 1
```

Optional `DRY_RUN=1` smoke test for inference: craft a `stories.json` with one story carrying `dependencies.blockedBy: [9999]` (non-existent ID) and one with neither blockers nor future-enhancement keywords. Run `DRY_RUN=1 ...` invoking the skill manually; first story's emitted labels array must include `status:blocked`, second's must not.

## Breaking Changes

None. The change is fully backward-compatible: existing `stories.json` files infer exactly as in v3.1.0, the `status:` dimension is sparse, no schema or body-template changes.

## Out of Scope

- GitHub Project board column sync — deferred to PR-B (`manage-github-project` skill).
- `needs-human-review` governance signal — would belong to a separate `review:` dimension if wanted later; not part of `status:`.
- `status:in-progress` / `status:done` auto-emission — reserved in the taxonomy so the labels exist on the repo, but the transitions they represent are downstream of issue creation.

## PR Checklist

- [x] Spec written and committed (6ef87e6)
- [x] Plan written and committed
- [x] Frontmatter version bumped 3.1.0 → 3.2.0
- [x] CHANGELOG entry added above existing 3.1.0 block
- [x] CI gates pass locally (`check-skill-frontmatter.sh`, `check-root-structure.sh`)
- [x] YAML frontmatter parses
- [x] Removed content gone (grep returns 0); new content present (grep returns ≥1)
- [x] Backward compatible — no schema or template changes
EOF
)"
```

- [ ] **Step 3: Confirm PR**

```bash
GH_HOST=github.com gh pr view --repo zstary/makato feat/to-issues-slice-patterns-and-status --json number,url,state,baseRefName,headRefName
```

PR URL is the handoff artifact.

- [ ] **Step 4: Verify**

```bash
# PR exists, points at main, head is our branch, state is OPEN
GH_HOST=github.com gh pr view --repo zstary/makato feat/to-issues-slice-patterns-and-status --json state,baseRefName,headRefName \
  --jq 'if .state == "OPEN" and .baseRefName == "main" and .headRefName == "feat/to-issues-slice-patterns-and-status" then "PASS" else error("FAIL: \(.)") end'

# CI checks have at least been queued (queued/in_progress/success all acceptable here — we're not gating on green at this point)
GH_HOST=github.com gh pr checks --repo zstary/makato feat/to-issues-slice-patterns-and-status || echo "(checks not yet reported — usually appears within a minute)"
```

---

## Cross-Task Decisions

| ID | Decision | Rationale |
|---|---|---|
| P1 | Single-PR scope; both changes shipped together | Spec D8 — same skill, same minor bump, same brainstorm; splitting would double review overhead |
| P2 | No schema or body-template changes | Spec §Architecture — `labels[]` already accepts free-form strings; `status:` is a label, not body content |
| P3 | Edits (not rewrites) for `label-taxonomy.md` and `SKILL.md` | Surgical changes minimize diff noise and keep the v3.0.0 content intact |
| P4 | Rewrite (not edits) for `slice-patterns.md` | The file is 60 lines and ~half is being removed — a rewrite is clearer than 4 separate deletions |
| P5 | Verification is grep + YAML parse + CI scripts only | No code is changing; pytest / runtime tests would be ceremony |
| P6 | Branch base stays on `feat/to-issues-future-enhancement` per Spec D8 | Already created; rebase onto `main` is trivial when PR #12 merges |
| P7 | Soft-warning (not halt) on dangling `blockedBy` references | Matches v3.0.0's partial-failure philosophy — never block issue creation on a fixable warning |
| P8 | Explicit `stories[].labels` wins over inference for `status:` | Operator override is the same principle as v3.0.0's `--interactive` mode; preserves human authority |
| P9 | `tier:` color migrates `5319E7` → `8B5CF6` (violet); `status:todo` stays `0E8A16` despite tech: collision | Spec D10. `status:done` needs `5319E7` to match the project board exactly; `tier:` moves to a clearly-lighter purple-family hue. `status:todo` shares green with `tech:` but is reserved-never-auto-emitted, so the practical collision is nil — leaving it preserves the project-board match for downstream skills. |

## Open Questions

None. All design decisions resolved in the spec (D1–D9) and operationalized as plan decisions (P1–P8).

## Spec Reference

This plan implements the design committed at `docs/superpowers/specs/2026-06-24-slice-patterns-and-status-labels-design.md` (commit `6ef87e6`). Where this plan and the spec differ in wording, the spec is authoritative for intent; this plan is authoritative for execution steps and verification commands.
