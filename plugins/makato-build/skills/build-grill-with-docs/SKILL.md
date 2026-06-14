---
name: build-grill-with-docs
description: >-
  Align implementation plan terminology to the codebase domain model —
  grill plan, terminology conflicts, glossary.md enrichment, ADR decisions.
  Use after /refine, before /implement-tdd or /implement-goal. Optional but
  recommended for complex stories.
version: "1.3.1"
model: opus
argument-hint: "[work-item-key]"

Use after `/refine` (plan.md exists) and before `/implement-tdd` or `/implement-goal`. The implementation plan is in place but may contain spec-language that doesn't match how the codebase actually names things. This skill probes those mismatches and enriches the feature `glossary.md` (produced by `/daff-shape:grill`) with codebase name annotations before any code is written.

Do NOT use as a substitute for `/refine` (this skill does not produce an implementation plan) or as a substitute for `/daff-shape:grill` (that skill stress-tests spec artifacts and owns the canonical domain vocabulary; this one maps that vocabulary to live code symbols).

---

## Workflow

### Step 1 — Resolve work item, load glossary, locate ADR path

Ask: *"Which work item are we aligning? (e.g. DCP-1234)"* — or use the passed argument.

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`) (required). If missing, stop:

> "Run `/refine` first — `plan.md` is required."

Read `prd.md`, `design.md`, `decisions.md` from the resolved spec folder if they exist.

Load `glossary.md` from the resolved spec folder as baseline if present — this is the feature vocabulary written by `/daff-shape:grill`. Terms already there are established: do not re-ask their meaning unless a codebase probe reveals a conflict. If `glossary.md` does not exist it will be created in Step 6.

**ADR path lookup** — load `@references/adr-criteria.md` for the probe order. Scan the primary repo root and use the first match. If none found, ask:
> "No ADR directory found in `<repo>`. Create `docs/governance/adr/`, or skip ADRs for this story and capture decisions in `decisions.md` only?"

Wait for the user's choice before continuing. Record the resolved path (or `skip`).

**ADR fallback**: if the user chooses to skip or the ADR directory cannot be created, do not silently drop ADR-worthy decisions. For each decision that meets the ADR criteria (Step 7), append it to `decisions.md` in the resolved spec folder with an `[ADR-PENDING]` marker and a note: `(ADR path unresolved — promote to ADR when directory is available)`. This preserves the decision for future promotion without blocking the session.

**Complexity check** — count plan tasks, file targets, and loaded spec files. If any threshold is crossed (>7 tasks, >8 file targets, or >3 spec files), surface:

> "This story has [N tasks, M file targets] — complex alignment work. Consider running `/fast` for Opus-quality reasoning before continuing."

Wait for the user's decision before proceeding.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"start","data":{"has_glossary":true|false,"adr_path":"<path>|skip"}}'
```

---

### Step 3 — Inventory domain terms from plan + spec

Scan `plan.md` and spec artifacts for domain-specific nouns: entities, states, actions, relationships. Skip generic programming nouns (service, handler, util, repository, controller). Build a candidate list. Skip any term already present in `glossary.md` with no codebase conflict detected — it is already established. Do not ask the user about it again.

Dispatch the `knowledge-scout` agent with REPO_ROOT (the target codebase root), REPO_NAME (last path segment of REPO_ROOT), and the candidate term list as KEYWORDS. This is best-effort — proceed normally if the agent returns `loaded: false`.

If the agent returns findings: inject any `## Hard Constraints`, `## Standards`, and learnings-based findings as additional conflict evidence in the candidate list. A term already documented as resolved in `learnings/` does not need to be raised in the alignment interview — mark it as confirmed and note the source.

---

### Step 4 — Probe codebase for canonical names

For each candidate term, search the codebase: class names, field names, enum values, table/column names, API path segments, method names. Build a conflict map: *spec term → codebase term(s)*. Flag conflicts and synonyms. Mark confirmed clean matches.

If codebase exploration answers a question outright, record the answer and skip asking the user.

Load `@references/context-md-format.md` — the format all resolved terms will use.

---

### Step 5 — Conduct alignment interview

Number every question (Q1, Q2…). For each conflict or ambiguity: state the conflict, surface the codebase evidence, propose a canonical resolution, wait for confirmation. Resolve depth-first — exhaust each branch before moving to the next topic.

- Record each resolved term immediately (do not batch).
- Stress-test with edge cases when a term's boundary is unclear.
- If the user says "skip": park as open question, move on.

---

### Step 6 — Enrich glossary.md

Write to `glossary.md` in the resolved spec folder. Lazy-create the file with the daff-shape header format if it doesn't exist:

```markdown
# {Feature name} — Glossary

Feature-scoped vocabulary for this story. Domain terms from shaping; codebase mappings from /grill-with-docs.

## Language

## Relationships

## Flagged ambiguities
```

For **existing entries** (from `/daff-shape:grill`): add a `_Code_: <symbol>` line when the codebase name differs from the canonical term. If the codebase matches the canonical term exactly, leave the entry unchanged.

For **new terms** not yet in `glossary.md`: append a full entry under `## Language` following the format from `@references/context-md-format.md`.

Do not overwrite or rewrite existing definitions — only add `_Code_:` annotations and new entries. The audit trail for revisions lives in `decisions.md`, not in `glossary.md`.

---

### Step 7 — Route decisions: decisions.md vs ADR

Load `@references/adr-criteria.md`.

For each decision surfaced during the interview, apply the three-criteria test and routing rule from `adr-criteria.md`. Present each proposed ADR to the user before writing. Skip this step entirely if the ADR path resolved to `skip` in Step 1.

Use `@templates/adr.md` for ADR structure.

---

### Step 8 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"ok","data":{"terms_resolved":<N>,"terms_skipped":<M>,"adrs_written":<K>,"decisions_updated":<J>}}'
```

Tell the user: *"Alignment complete. `glossary.md` enriched with `<N>` terms. Next: `/implement-tdd` or `/implement-goal`."*
