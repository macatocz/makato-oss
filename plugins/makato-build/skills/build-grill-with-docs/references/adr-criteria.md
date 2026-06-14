# ADR Criteria

Rules for when to write an ADR, how to route decisions, and where to place ADR files.

## The Three-Criteria Test

Write an ADR only when ALL THREE are true:

1. **Hard to reverse** — undoing this decision requires significant rework (schema migration, API contract change, cross-team coordination, deleted data).
2. **Surprising without context** — a future maintainer reading the code would wonder "why did they do it this way?" without an explanation.
3. **Genuine trade-offs** — a reasonable engineer could have made a different choice; there were real alternatives with real costs.

If any criterion is missing, skip the ADR. Examples:

| Decision | ADR? | Reason |
|---|---|---|
| Using "revocation" instead of "cancellation" to match the codebase | No | Terminology alignment, not reversibility |
| Storing approval history in a separate table rather than a JSON column | Yes | Hard to migrate later, surprising, real trade-off |
| Using an existing enum rather than a new one | No | Obvious, not surprising, easy to change |
| Accepting eventual consistency on a cross-service write | Yes | Hard to reverse once consumers are built, non-obvious |

## Routing Rule: decisions.md vs ADR

decisions.md is the catch-all; ADR is the filter. Apply in order:

1. Check if the decision exists in `decisions.md`.
2. Apply the three-criteria test.
3. **In decisions.md + meets criteria** → promote to ADR; add `(→ ADR-NNNN)` cross-reference in the decisions.md entry.
4. **New + meets criteria** → write ADR directly; also append a brief entry to decisions.md.
5. **Criteria not met** → append to decisions.md only (or skip if trivial).

Content never flows from ADR back into decisions.md.

## ADR Path Lookup

Probe in this order in the target repo root:

```
docs/governance/adr/    ← daff repo convention (hardcoded for daff repo)
docs/adr/
adr/
.adr/
decisions/adr/
doc/adr/
```

First directory that exists → use it. If none found, ask the user whether to create `docs/governance/adr/` or skip ADRs for this story.

## Auto-Numbering

Scan existing ADR files in the resolved directory. Find the highest four-digit prefix. Increment by 1. Start at `0001` if no files exist. Filename format: `NNNN-kebab-title.md`.

## ADR Template

Use `@templates/adr.md` for structure.
