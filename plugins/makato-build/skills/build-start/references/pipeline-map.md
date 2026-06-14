# Pipeline Map

Reference for `/start` Step 3: implementation mode selection and full pipeline overview.

## Phases

| Phase | Skill | Interactive? | Optional? | Input | Output |
|-------|-------|:---:|:---:|-------|--------|
| Refine | `/refine` | Yes | No | `specs/<key>-*/` artifacts | `plan.md` in spec folder |
| Align | `/grill-with-docs` | Yes | Yes | `plan.md` + codebase | enriched `glossary.md`, ADRs |
| Implement | `/implement-tdd` or `/implement-goal` | No (autonomous) | No | `plan.md` | working code + tests |
| Simplify | `/simplify` | Yes | No | implemented code | simplified code |
| Review | `/review` | No (autonomous) | No | simplified code | reviewed, fixed code |
| Verify | `/verify` | No (autonomous) | No | reviewed code | all gates passing |
| Push | `/push-to-git` | Yes (confirm) | No | verified code | commits on remote branch |
| Create PR | `/create-pr` | Yes | No | pushed branch | open pull request |

## Mode Selection Guide

### Choose TDD when the story primarily involves:
- Business logic (services, domain objects, calculations)
- API endpoints (controllers, request/response handling)
- Data processing (transformers, mappers, validators)
- Event handling or workflow transitions
- Anything where the *contract* can be written as a test before the code exists

TDD cycle per task: **RED** (write failing unit + integration tests) → **GREEN** (unit
tests pass) → **INTEGRATE** (integration tests pass against real dependencies) → **VERIFY**
(full suite passes).

### Choose Goal when the story primarily involves:
- UI components (the component must render before tests can assert on it)
- Configuration changes (the system must start before tests verify the config)
- Database schema migrations (the migration must run before tests verify the schema)
- CLI tools or scripts where behavior is observed by running, not by unit assertions

Goal cycle per task: **BUILD** (implement) → **VERIFY RUNTIME** (runs without error) →
**TEST** (write tests against the running implementation) → **VERIFY** (full suite passes).

### Mixed plans
`/refine` will label each task `mode: tdd` or `mode: goal`. A single story can produce a
mixed plan — the mode chosen at `/start` is the *default* hint for refine; the final
per-task mode is decided during refinement. If in doubt, choose TDD and let refine
override per-task.

## Hook-Triggered Phases

The `post-implement` hook fires automatically after a successful `/implement-tdd` or
`/implement-goal` session and continues to `/simplify`. No user action required between
implement and simplify.

## Optional Phases

**grill-with-docs** — recommended for complex stories where spec terminology may conflict
with codebase domain language. Produces `_Code_:` annotations in `glossary.md` in the spec folder
and ADRs for hard-to-reverse decisions. Skip for straightforward stories where the plan
terminology clearly maps to the codebase.
