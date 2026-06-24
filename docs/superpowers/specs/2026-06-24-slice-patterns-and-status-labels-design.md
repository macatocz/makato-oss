<!-- markdownlint-disable MD013 -->
# `slice-patterns.md` Rewrite + `status:` Label Dimension — Design Spec

**Date:** 2026-06-24
**Author:** brainstorming session
**Status:** approved (ready for writing-plans handoff)
**Target:** `to-issues` skill v3.1.0 → v3.2.0
**Branch:** `feat/to-issues-slice-patterns-and-status` (stacked on `feat/to-issues-future-enhancement`)

## Goal

Two coupled changes to the `to-issues` skill, shipped together:

1. **Rewrite `references/slice-patterns.md`** — strip dead content (k8s/AWS context detection that doesn't match sagibeast's stack, an autonomous-vs-needs-human decision tree that duplicates label-based signals) and refocus the file on what only it does: teach contributors how to cut vertical slices. Add three new tracer-bullet shapes (Brain agent, Pipeline, Cross-cutting) alongside the existing Web/API shape so the file covers ~80% of sagibeast's real work topologies instead of ~50%.
2. **Add `status:` as a 5th label dimension** in the v3.0.0 taxonomy. The sagibeast GitHub Project board uses a 4-value Status field (Todo / In Progress / Done / Blocked). `to-issues` emits `status:blocked` on creation when the issue cannot start immediately. The remaining three workflow states (Todo / In-Progress / Done) are managed downstream by a future `manage-github-project` skill (out of scope for this PR — see "Out of Scope" below).

## Why now

The `slice-patterns.md` file shipped in `to-issues` v3.0.0 unchanged from an older project. The `Context Boundary Detection` section emits `context:k8s` and `context:aws-infra` labels — neither is in the v3.0.0 4-dimension taxonomy (`type:` / `tier:` / `tech:` / `module:`), and neither stack is present in sagibeast. The `Autonomous vs Needs Human Decision Tree` section uses a `Specialist` vs `Autonomous` dichotomy that doesn't map to how makato dispatches work today. Both sections are dead-ish content that drift the file's actual value.

Sagibeast simultaneously needs `to-issues` to emit a label that corresponds to its Project board's "Blocked" status — so issues that are gated on upstream blockers (or marked `type:future-enhancement`) surface in the right place. Adding `status:` as a 5th dimension at the same time keeps both changes in one focused PR.

## Architecture

### File-by-file changes

| Path | Change | Reason |
|------|--------|--------|
| `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` | Full rewrite | Drop dead sections; add 3 new tracer shapes; trim checklist |
| `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` | Add `status:` dimension + values + inference rules + color | 5th label dimension lands here |
| `plugins/makato-plan/skills/to-issues/SKILL.md` | Frontmatter `3.1.0` → `3.2.0`; Step 3 adds `status:` inference; documentation table reflects 5 dimensions | Skill version bump + behavior wiring |
| `plugins/makato-plan/CHANGELOG.md` | New `3.2.0` block above existing `3.1.0` | Standard changelog entry |
| `plugins/makato-plan/skills/to-issues/references/issue-template.md` | **No change** | Blocked status is a label, not body content |
| `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` | **No change** | `labels[]` is already a free-form `string[]`; new values pass validation as-is |

### Section 1 — `slice-patterns.md` scope changes

**Removed:**

- The entire `## Context Boundary Detection` section (lines 19–38 of the current file). The `context:k8s` / `context:aws-infra` labels it produces are not in the v3.0.0 taxonomy. Module-dimension labels are now resolved via the ADR-folder-name algorithm in `label-taxonomy.md` (D16) — that algorithm already does this work in a generic, repo-agnostic way.
- The entire `## Autonomous vs Needs Human Decision Tree` section (lines 40–54). Governance signals belong on the issue itself as labels (e.g. a future `review:` dimension if it's wanted), not in a decision tree read once during slicing. The tree's `Specialist` vs `Autonomous Agent` dichotomy is also stale.

**Kept and revised:**

- `## Tracer-Bullet Slice Pattern` — now four named shapes instead of one (see Section 2).
- `## Issue Body Quality Checklist` — trimmed from 5 items to 4 (drop the "Slice type" item, which was the decision tree's output).

### Section 2 — Four tracer-bullet shapes

The original file had one tracer-bullet recipe shaped for web features. Sagibeast's 28 ADRs imply at least four distinct data-flow topologies; forcing every feature into the web shape causes contributors to write tests that assert the wrong thing or pretend layers exist that don't.

The four shapes drop out of grouping sagibeast's ADRs by data-flow topology:

| Group | Topology | ADRs (representative) | Tracer shape |
|---|---|---|---|
| Synchronous request/response | HTTP in → SQL out → HTTP out | 0001, 0002, 0007, 0019, 0020 | **Web/API** |
| Agent reasoning | Trigger in → graph nodes → tool calls → state writes | 0004, 0005, 0010, 0013, 0014 | **Brain agent** |
| Data transformation | File/stream in → transform → persist → retrievable | 0006, 0015, 0017, 0022 | **Pipeline** |
| Cross-cutting wrap | Anything in → augment → anything out + side effect | 0008, 0009, 0011, 0016, 0018 | **Cross-cutting** |
| Config-only | n/a — flat, not layered | 0023, parts of 0019 | Not a tracer — handled in prose |
| Lifecycle / governance | n/a — state-machine, not data-flow | 0021, 0024, 0025, 0026, 0027, 0028 | Not a tracer — handled by labels or by future skills |

**Each tracer-bullet shape has 5 layers and an anti-pattern callout:**

#### 2a. Web/API tracer-bullet

1. Route — FastAPI endpoint that accepts the request
2. Handler / orchestrator — translates HTTP to a domain call (auth, validation, response shaping)
3. Domain function — the actual feature logic, decoupled from FastAPI
4. Persistence — pgvector / Postgres read or write (raw SQL per ADR-0002)
5. Outside test — pytest hitting the route via TestClient, asserting observable output (no internal mocking)

**Anti-pattern:** horizontal slices ("all Postgres schema this sprint, all API endpoints next sprint"). Each horizontal layer is dead code until the others land.

#### 2b. Brain agent / LangGraph node tracer-bullet

1. Trigger — Temporal workflow signal or chat-widget message entering the LangGraph graph
2. Node — the LangGraph state-graph node where work happens (typically wraps a PydanticAI agent)
3. Tool call — agent invokes a tool: skill execution, retrieval, memory read, body-API call
4. State write — Memory Service update (episodic / semantic / procedural per chapter 02) OR LangGraph state edit
5. Outside test — driven from the workflow boundary or node input, asserting state delta + agent response

**Anti-pattern:** implementing tool → node → prompt → trigger separately. Each step is dead code until the chain closes. Cut across all five from day one, even if the agent prompt is initially trivial.

#### 2c. Pipeline tracer-bullet

1. Input source — file upload (Docling-fed PDF/IFC), batch trigger, or stream message
2. Transform — chunk, embed (BGE-M3), tokenise (PII), or convert (Docling)
3. Persist — pgvector vector store, Postgres table, or MinIO/S3 object
4. Retrievable query — the artifact must be reachable by a downstream query (similarity search, key lookup, presigned URL)
5. Outside test — drives the input, asserts the retrievable query returns the artifact in the expected shape

**Anti-pattern:** writing the ingest half without writing the query half. An artifact you can't retrieve is invisible; the slice isn't done until something can read it back.

#### 2d. Cross-cutting tracer-bullet

1. Interception point — middleware position, decorator surface, LangGraph node wrapper, or Langfuse instrumentation hook
2. Augmentation — what the wrapper adds (auth claim, span emission, PII mask, sandbox policy)
3. Passthrough — call the wrapped function; the wrapper must not change the inner contract
4. Side effect — emitted span / written log / enforced policy outcome
5. Outside test — exercise a wrapped call, assert (a) inner contract preserved, (b) side effect observable

**Anti-pattern:** building the wrapper without exercising real wrapped calls in the test. Stub-only tests miss interaction bugs. A real call through real middleware is the only way to know the wrap composes correctly.

**Notes for all four shapes:**

- A slice may use a subset of layers (e.g. read-only slices have no persistence layer — say so explicitly in the issue body).
- Slices that span the Brain↔Body boundary force tracer-bullets on both sides. Issue them separately with `blocked_by` linking, never bundled.
- Config-only work (compose, helm, env wiring) is not tracer-shaped and is handled in prose, not by a 5-layer recipe.

### Section 3 — Issue Body Quality Checklist (4 items)

Trimmed from 5 items to 4. The dropped item ("Slice type — Autonomous or Needs Human") was the output of the deleted decision tree. The remaining items still apply.

A well-formed issue body must include:

1. **Context** — what part of the system this changes and why. For Brain work, name the chapter (e.g. "chapter 02 Memory Service"). For Body work, name the subsystem (ingest / RAG / API client / UI).
2. **What to build** — concrete description of the change. Reference which tracer-bullet shape applies and which of its 5 layers are touched.
3. **Acceptance criteria** — specific, testable conditions. The outside-test layer of the tracer-bullet is what the criteria assert on.
4. **Files** — exact file paths to create or modify, using the expected `src/` layout from sagibeast's `context/codebase/structure.md`.

Missing any of these forces the implementing agent to ask questions mid-session.

### Section 4 — Final file layout

```text
# Slice Patterns Reference

> Expert patterns for vertical slice decomposition in the To Issues skill.

## Tracer-Bullet Slice Pattern
(2-3 sentence intro about cutting end-to-end)

### Web/API tracer-bullet
(5-layer list + anti-pattern)

### Brain agent / LangGraph node tracer-bullet
(5-layer list + anti-pattern)

### Pipeline tracer-bullet
(5-layer list + anti-pattern)

### Cross-cutting tracer-bullet
(5-layer list + anti-pattern)

## Issue Body Quality Checklist
(4-item list)
```

Estimated length: ~110 lines (vs. current 66). Longer, but the new content is grounded in actual sagibeast topology, where the old content was wrong-stack noise.

### Section 5 — `status:` as the 5th label dimension

The sagibeast GitHub Project board has 4 Status field values:

| Status | Color | Project-board description | `status:` label |
|---|---|---|---|
| Todo | green (`0E8A16`) | This item hasn't been started | `status:todo` *(default — usually omitted)* |
| In Progress | yellow (`FBCA04`) | This is actively being worked on | `status:in-progress` |
| Done | deep purple (`5319E7`) | This has been completed | `status:done` |
| Blocked | red (`B60205`) | Currently waiting until there is implemented prerequisity issue or when the project is in shape when it can be implemented | `status:blocked` |

#### Inference rules (added to `label-taxonomy.md`)

`to-issues` emits a `status:` label only when the status is non-default. Newly-created issues are Todo by default (GitHub Projects auto-applies it), so `to-issues` does NOT emit `status:todo` to keep label noise low.

**Emit `status:blocked` when ANY of:**

- The story has unresolved upstream dependencies in `stories[].dependencies.blockedBy` (the same field already used to populate the issue body's `Blocked by:` line). "Unresolved" = the upstream issue doesn't yet exist or hasn't been resolved by an earlier batch-mate.
- The story was inferred as `type:future-enhancement` (per v3.1.0, PR #12). Future-enhancement issues are parked-until-condition-met — that matches the project board's Blocked description verbatim ("when the project is in shape when it can be implemented").
- Explicit story field: `stories[].labels` contains `status:blocked` literally — honor it regardless of inference.

**`status:in-progress` and `status:done` are NOT auto-applied by `to-issues`.** They're documented values for the dimension (so the taxonomy is complete and the labels exist on the repo), but the issue lifecycle that drives those transitions (PR opened, PR merged) happens downstream of `to-issues`. A future `manage-github-project` skill (out of scope — see "Out of Scope") will own those transitions.

#### Label colors

| Prefix | Color | Reason |
|---|---|---|
| `status:todo` | `0E8A16` (green) | Matches project board |
| `status:in-progress` | `FBCA04` (yellow) | Matches project board |
| `status:done` | `5319E7` (deep purple) | Matches project board |
| `status:blocked` | `B60205` (red) | Matches project board; aligns with GitHub's red-for-blocker convention |

**Color collision fix — `tier:` recolored.** The current `label-taxonomy.md` assigns `5319E7` (purple) to `tier:`. That hex is now claimed by `status:done` to match the project board exactly, so `tier:` moves to **`8B5CF6` (violet)** — a clearly-lighter purple-family hue that preserves the visual "phase progression" category while remaining unambiguously distinct from `status:done`'s deep purple. This is the only color change to an existing dimension; `type:` blue, `tech:` green, and `module:` light-blue stay as-is. (Note: `tech:` `0E8A16` and `status:todo` `0E8A16` share green. `status:todo` is reserved-never-auto-emitted by `to-issues`, so the practical collision is nil — left as-is.)

The colors are extensions to the existing label-color table in `label-taxonomy.md`. Existing `type:` blue, `tech:` green, `module:` light-blue stay as-is; `tier:` migrates from purple `5319E7` to violet `8B5CF6` (one-line edit to the existing color row).

#### Documentation update — "5 dimensions" header

The current `label-taxonomy.md` opens with "single source of truth for the 4-dimension label set". This becomes "the 5-dimension label set" with a note that `status:` is **sparse** — emitted only when the status is non-default, unlike `type:` / `tier:` / `tech:` / `module:` which are emitted whenever a value can be resolved.

#### Repo-extensibility for sensitive zones (deferred)

An earlier design proposed `needs_human_review_modules` in `.claude/config.json`. **Dropped from this PR.** It conflated workflow state (blocked vs. todo) with governance signal (this slice needs human review). Governance belongs on a separate `review:` dimension or a future skill; not in `status:`. If wanted later, it's a small additive change.

### What's not in this PR

The actual sync of the GitHub Project board's Status field is **not** implemented here. `to-issues` only emits the `status:blocked` label on issue creation. Moving the issue between project columns based on real workflow events (PR opens → In Progress, PR merges → Done, blocker closes → Todo flips from Blocked) requires lifecycle listeners and the GraphQL `projectV2` API — that's a separate skill, deliberately scoped out.

When new issues are created by `to-issues` and added to the sagibeast project, GitHub auto-applies Todo as the Status field default. `status:blocked` labels are visible as labels on the issue but do NOT drive a project-column move. Closing that gap is PR-B's job.

## Architecture diagram

```text
┌─────────────────────────┐
│  stories.json (input)   │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────────────────────────┐
│  to-issues v3.2.0                           │
│  ┌─────────────────────────────────────┐   │
│  │ Step 3 — Infer labels                │   │
│  │  type:   keyword table               │   │
│  │  tier:   stories[].phase             │   │
│  │  tech:   keyword map + config        │   │
│  │  module: ADR folder match            │   │
│  │  status: blocked-by graph + type:    │   │
│  │          future-enhancement +        │   │
│  │          explicit labels             │   │
│  └─────────────────────────────────────┘   │
│  Step 4 — gh label create (incl. status:)  │
│  Step 5 — gh issue create --label …        │
└────────────┬────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  GitHub Issue with labels:           │
│    type:feat, tier:foundation,       │
│    tech:python, module:body-api,     │
│    status:blocked (if applicable)    │
└────────────┬────────────────────────┘
             │
             ▼   (auto, by GitHub Project default rule)
┌─────────────────────────────────────┐
│  Project board: Status=Todo column   │
│  (status:blocked label is visible    │
│   but does NOT auto-move to Blocked  │
│   column — that's PR-B's job)        │
└─────────────────────────────────────┘
```

PR-B (the future `manage-github-project` skill) plugs into the gap between issue lifecycle events and project column moves. Both PRs share `created-issues.json` as the contract: `to-issues` writes it; PR-B reads it to know which issues to track.

## Components

| Component | Responsibility | Interface |
|---|---|---|
| `slice-patterns.md` | Reference document — 4 tracer-bullet shapes + 4-item checklist | Read by contributors during decompose / slicing |
| `label-taxonomy.md` | Single source of truth for label values, colors, inference rules | Read by `to-issues` Step 3 |
| `SKILL.md` Step 3 | Per-story inference loop applying the taxonomy rules | Emits `labels: string[]` for each story |
| `SKILL.md` Step 4 | Ensure all required labels exist on the repo | Calls `gh label create` for new `status:*` labels |
| `created-issues.json` artifact | Records emitted labels for each issue (already in v3.0.0) | Read by `build-create-pr` and future `manage-github-project` |

## Data flow

1. `stories.json` is read.
2. For each story, Step 3 applies the 5 label-dimension rules:
   - `type:` regex match (v3.0.0) — may produce `type:future-enhancement` (v3.1.0).
   - `tier:` from `stories[].phase` — skipped if type is `future-enhancement` (v3.1.0).
   - `tech:` from keyword map + config extensions.
   - `module:` from ADR folder-name match.
   - `status:` (NEW v3.2.0) — emits `status:blocked` if any of: unresolved `blockedBy`, `type:future-enhancement` inferred, or explicit `status:blocked` in `stories[].labels`. Otherwise no `status:` label.
3. Step 4 ensures all emitted labels exist on the repo, creating new ones with the documented colors.
4. Step 5 calls `gh issue create --label <each label>`. Issue is added to the GitHub Project; Project applies Todo as the default Status field.
5. Step 6 writes `specs/<slug>/created-issues.json` (unchanged shape; new `status:blocked` values pass schema validation as free-form strings).

## Error handling

- Stories with explicit `stories[].labels` containing values like `status:in-progress` or `status:done` are honored verbatim. Operator override is intentional — if a human says "this is already done, just file the issue for the record," respect it.
- If `stories[].dependencies.blockedBy` references an ID that doesn't exist in the same batch and hasn't been resolved by an earlier batch-mate, the story is still emitted with `status:blocked`. The body's `Blocked by:` line will show `_unresolved_` for that ID; the autonomous-mode log records a warning. This is a soft warning, not a halt — the human resolves the dangling reference manually.
- Conflict between inferred `status:blocked` and an explicit `stories[].labels` entry contradicting it: the explicit entry wins, the autonomous-mode log records `[to-issues:auto] story <n>: status inference (blocked) overridden by explicit label (<value>)`.

## Testing strategy

This is a markdown + bash skill, not code. No test runtime is added. Verification is static:

- **CI gates** — `./scripts/check-root-structure.sh` and `./scripts/check-skill-frontmatter.sh` must pass (same as v3.1.0).
- **YAML frontmatter parse** — `python3 -c "import yaml; ..."` confirms top-level `version: "3.2.0"` and nested metadata.
- **Grep-based content checks** — confirm 5 dimensions documented, 4 status colors present, 4 tracer-bullet shapes present, removed sections gone:

  ```bash
  grep -c "status:" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md           # ≥10
  grep -c "Tracer-Bullet\|tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # ≥5
  grep -c "Cross-cutting tracer-bullet" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # 1
  grep -c "Context Boundary Detection\|Autonomous vs Needs Human" plugins/makato-plan/skills/to-issues/references/slice-patterns.md  # 0
  grep -c "B60205\|FBCA04" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md   # ≥2 (blocked + in-progress colors)
  ```

- **DRY_RUN smoke test (optional)** — craft a `stories.json` with one story having unresolved `blockedBy` and one without; run `DRY_RUN=1`. First should produce a labels array containing `status:blocked`; second should not.

## Out of scope

- **GitHub Project board status sync** — defer to PR-B (`manage-github-project` skill). PR-B owns the lifecycle: listening to PR opens / merges / closes and calling `gh project item-edit --field-id <Status> --single-select-option-id <X>` to move issues between board columns. PR-B's own brainstorm will decide its plugin placement, trigger model (hook vs. manual command), and configuration shape.
- **`needs-human-review` governance signal** — was proposed during brainstorming, then dropped. Workflow state (`status:`) and governance state (`review:`) are separate concerns; merging them was wrong. If wanted later, a separate `review:` dimension is the right home — also out of scope for this PR.
- **`status:in-progress` and `status:done` auto-emission** — defined in the taxonomy so the labels exist on the repo, but `to-issues` does not auto-apply them. Those transitions are downstream of issue creation.

## Migration

Backward-compatible. Existing `stories.json` files infer exactly as in v3.1.0; the new `status:` dimension is sparse and additive. No migration steps needed for repos that previously used `to-issues` v3.0.0 / v3.1.0.

## Version bumps

- `plugins/makato-plan/skills/to-issues/SKILL.md` frontmatter: `version: "3.1.0"` → `version: "3.2.0"`.
- `plugins/makato-plan/CHANGELOG.md`: new `**3.2.0**` block above the existing `**3.1.0**` entry under `## \`to-issues\` skill`.
- Conventional commit title: `feat(makato-plan): rewrite slice-patterns and add status: label dimension to to-issues (v3.2.0)`.

## Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Drop Context Boundary Detection from `slice-patterns.md` | Section emitted labels not in the v3.0.0 taxonomy; module dimension handled generically by ADR-folder algorithm |
| D2 | Drop Autonomous-vs-Needs-Human decision tree | Governance is better expressed as labels; decision tree was stale and duplicated label signals |
| D3 | 4 tracer-bullet shapes, not 2 or 6 | Covers ~80% of sagibeast's data-flow topologies; avoids fake patterns for config/lifecycle work |
| D4 | "Cross-cutting" not "Wrapper" or "Intercept" for the 4th shape | Matches existing sagibeast vocabulary in `context/codebase/architecture.md` ("Cross-cutting layers"); zero translation cost |
| D5 | `status:` is sparse (not emitted by default) | Reduces label noise; GitHub Projects auto-applies Todo |
| D6 | `to-issues` only auto-emits `status:blocked`, not `in-progress` / `done` | The latter are lifecycle transitions, not creation-time states |
| D7 | Defer project-board column sync to PR-B (`manage-github-project`) | Separation of concerns: `to-issues` writes labels; a separate skill owns Projects API integration |
| D8 | Branch stacks on `feat/to-issues-future-enhancement` (PR #12) | v3.2.0 builds on v3.1.0; faster than waiting for merge |
| D9 | `needs-human-review` dropped entirely | Workflow state and governance state are separate concerns; conflating them was a brainstorm mistake |
| D10 | `tier:` color migrates `5319E7` → `8B5CF6` (violet) | `status:done` needs `5319E7` to match the project board exactly; `tier:` moves to a lighter purple-family hue. `tech:`/`status:todo` both staying on `0E8A16` is acceptable because `status:todo` is reserved-never-auto-emitted |

## References

- Current `slice-patterns.md`: `plugins/makato-plan/skills/to-issues/references/slice-patterns.md`
- Current `label-taxonomy.md`: `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md`
- Sagibeast ADRs: `/Users/I346175/GITHUB/sagibeast/specs/ADR/` (28 ADRs, 0001..0028)
- Sagibeast architecture: `/Users/I346175/GITHUB/sagibeast/context/codebase/architecture.md`
- Sagibeast structure: `/Users/I346175/GITHUB/sagibeast/context/codebase/structure.md`
- PR #12 (v3.1.0 — `type:future-enhancement`): <https://github.com/zstary/makato/pull/12>
