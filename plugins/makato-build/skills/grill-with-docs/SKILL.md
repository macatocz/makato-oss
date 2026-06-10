---
name: grill-with-docs
description: >-
  Align implementation plan terminology to the codebase domain model —
  grill plan, terminology conflicts, glossary.md enrichment, ADR decisions.
  Use after /refine, before /implement-tdd or /implement-goal. Optional but
  recommended for complex stories.
version: "1.1.0"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/refine` (plan.md exists) and before `/implement-tdd` or `/implement-goal`. The implementation plan is in place but may contain spec-language that doesn't match how the codebase actually names things. This skill probes those mismatches and enriches the feature `glossary.md` (produced by `/makato-plan:grill`) with codebase name annotations before any code is written.

Do NOT use as a substitute for `/refine` (this skill does not produce an implementation plan) or as a substitute for `/makato-plan:grill` (that skill stress-tests spec artifacts and owns the canonical domain vocabulary; this one maps that vocabulary to live code symbols).

---

## Workflow

### Step 1 — Resolve work item, load glossary, locate ADR path

Ask: *"Which work item are we aligning? (e.g. DCP-1234)"* — or use the passed argument.

Read `spec/<key>/plan.md` (required). If missing, stop:

> "Run `/refine` first — `plan.md` is required."

Read `spec/<key>/prd.md`, `spec/<key>/design.md`, `spec/<key>/decisions.md` if they exist.

Load `spec/<key>/glossary.md` as baseline if present — this is the feature vocabulary written by `/makato-plan:grill`. Terms already there are established: do not re-ask their meaning unless a codebase probe reveals a conflict. If `glossary.md` does not exist it will be created in Step 6.

**ADR path lookup** — in the primary repo (run `git rev-parse --show-toplevel` from any file target in `plan.md`), probe in order:
```
docs/governance/adr/
docs/adr/
adr/
.adr/
decisions/adr/
doc/adr/
```
First directory that exists → use it. If none found, ask:
> "No ADR directory found in `<repo>`. Create `docs/governance/adr/`, or skip ADRs for this story and capture decisions in `decisions.md` only?"

Wait for the user's choice before continuing. Record the resolved path (or `skip`).

**Complexity check** — count plan tasks, file targets, and loaded spec files. If any threshold is crossed (>7 tasks, >8 file targets, or >3 spec files), surface:

> "This story has [N tasks, M file targets] — complex alignment work. Consider running `/fast` for Opus-quality reasoning before continuing."

Wait for the user's decision before proceeding.

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"grill-with-docs","story":"<key>","step":"session","status":"start","data":{"has_glossary":true|false,"adr_path":"<path>|skip"}}
```

---

### Step 3 — Inventory domain terms from plan + spec

Scan `plan.md` and spec artifacts for domain-specific nouns: entities, states, actions, relationships. Skip generic programming nouns (service, handler, util, repository, controller). Build a candidate list. Skip any term already present in `glossary.md` with no codebase conflict detected — it is already established. Do not ask the user about it again.

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

Write to `spec/<key>/glossary.md`. Lazy-create the file with the makato-plan header format if it doesn't exist:

```markdown
# {Feature name} — Glossary

Feature-scoped vocabulary for this story. Domain terms from shaping; codebase mappings from /grill-with-docs.

## Language

## Relationships

## Flagged ambiguities
```

For **existing entries** (from `/makato-plan:grill`): add a `_Code_: <symbol>` line when the codebase name differs from the canonical term. If the codebase matches the canonical term exactly, leave the entry unchanged.

For **new terms** not yet in `glossary.md`: append a full entry under `## Language` following the format from `@references/context-md-format.md`.

Do not overwrite or rewrite existing definitions — only add `_Code_:` annotations and new entries. The audit trail for revisions lives in `decisions.md`, not in `glossary.md`.

---

### Step 7 — Route decisions: decisions.md vs ADR

Load `@references/adr-criteria.md`.

For each decision surfaced during the interview, apply the routing rule:

1. Check if it already exists in `decisions.md`.
2. Apply the three-criteria test: hard-to-reverse × would surprise a future reader × involved genuine trade-offs.
3. If in `decisions.md` **and** meets all criteria → **promote to ADR**, add cross-reference in the decisions.md entry: `(→ ADR-NNNN)`.
4. If new **and** meets all criteria → **write ADR directly**, also append a brief entry to `decisions.md`.
5. If criteria not met → **append to decisions.md only** (or skip if trivial).

Present each proposed ADR to the user before writing. Skip this step entirely if the ADR path resolved to `skip` in Step 1.

Use `@templates/adr.md` for ADR structure.

---

### Step 8 — Log session end and hand off

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"grill-with-docs","story":"<key>","step":"session","status":"ok","data":{"terms_resolved":<N>,"terms_skipped":<M>,"adrs_written":<K>,"decisions_updated":<J>}}
```

Tell the user: *"Alignment complete. `glossary.md` enriched with `<N>` terms. Next: `/implement-tdd` or `/implement-goal`."*
