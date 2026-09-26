# Reviewer Finding Schema (Local Copy)

> Canonical source: `makato-core/contracts/reviewer-finding-schema.md`

## Severity Tiers

| Tier | Meaning |
|------|---------|
| **CRITICAL** | Correctness bug, security issue, or acceptance-criteria gap that MUST be fixed |
| **MAJOR** | Correctness-adjacent defect — real but lower-likelihood bug, missing guard, untested failure path |
| **SUGGESTION** | Structural improvement without changing observable behaviour |
| **NITPICK** | Style or minor clarity; purely informational |

## Verdicts

Every review MUST emit exactly one verdict as the first bold line:

```
**Verdict**: APPROVED | APPROVED WITH SUGGESTIONS | REQUIRES CHANGES
```

| Condition | Verdict |
|-----------|---------|
| Any CRITICAL finding present | **REQUIRES CHANGES** |
| Any MAJOR finding present, no CRITICAL | **APPROVED WITH SUGGESTIONS** |
| Only SUGGESTION/NITPICK or none | **APPROVED** |

## Finding Fields

Each finding includes: `severity`, `file`, `line`, `category`, `description`, `evidence`.

Categories for Three Amigos: `value`, `feasibility`, `testability`, `scope`, `risk`, `dependency`.
