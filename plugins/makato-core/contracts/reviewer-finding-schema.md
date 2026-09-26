# Contract: Reviewer Finding Schema

## Purpose

Defines the standard output schema for all reviewer agents across makato plugins. Any agent that produces a code/story review MUST emit findings using this schema so that upstream consumers (PO-agent, build-review, orchestrate) can parse verdicts without brittle regex.

## Severity Tiers

Every finding MUST be classified as exactly one of:

| Tier | Meaning | Autonomous-mode effect |
|------|---------|----------------------|
| **CRITICAL** | Correctness bug, security issue, or acceptance-criteria gap that MUST be fixed. Would produce wrong output, expose data, violate contract, or cause runtime failure. | Re-triggers fix loop |
| **MAJOR** | Correctness-adjacent defect — a real but lower-likelihood bug, missing guard, unhandled edge case that degrades behaviour, or untested failure path. More than a preference, less than a blocker. | Re-triggers fix loop |
| **SUGGESTION** | Structural improvement that makes code clearer, more maintainable, or more efficient WITHOUT changing observable behaviour. Does not block correctness or security. | Advisory only |
| **NITPICK** | Style or minor clarity; purely informational; no functional impact whatsoever. | Advisory only |

**Decision order**: if a user would experience a wrong result or security exposure → CRITICAL. Else if correctness-adjacent → MAJOR. Else if a future developer would work harder to maintain it → SUGGESTION. Else → NITPICK.

## Verdicts

Every review MUST emit exactly one verdict as the first bold line of output:

```
**Verdict**: APPROVED | APPROVED WITH SUGGESTIONS | REQUIRES CHANGES
```

### Verdict Rules

| Condition | Verdict |
|-----------|---------|
| Any CRITICAL finding present | **REQUIRES CHANGES** |
| Any MAJOR finding present, no CRITICAL | **APPROVED WITH SUGGESTIONS** |
| Only SUGGESTION/NITPICK findings or none | **APPROVED** |

## Finding Fields

Each finding MUST include:

| Field | Required | Description |
|-------|----------|-------------|
| `severity` | yes | One of: CRITICAL, MAJOR, SUGGESTION, NITPICK |
| `file` | yes | Affected file path |
| `line` | when applicable | Line number or range |
| `category` | yes | One of: correctness, edge-case, error-handling, security, contract, test-coverage, optimization, value, feasibility, testability |
| `description` | yes | What the problem is |
| `evidence` | yes | Exact code reference or citation proving the finding |

## Adopting Agents

| Agent | Plugin | Notes |
|-------|--------|-------|
| `diff-reviewer` | makato-build | Full R1 data envelope + per-AC verdicts |
| `code-reviewer` | makato-change | Severity classification + verdict line |
| `dev-reviewer` | makato-plan | Feasibility/risk findings during Three Amigos |
| `po-reviewer` | makato-plan | Value/scope findings during Three Amigos |
| `qa-reviewer` | makato-plan | Testability findings + Gherkin during Three Amigos |

## See Also

- `build-jsonl.md` — audit trail schema
- `spec-folder.md` — spec artifact directory contract
