# Skill-Bundles Registry Rules

## When to register a skill (technical only)

`inject-skills` is the **only** consumer of this registry. It prepends a skill into
a programmatically-dispatched sub-agent's system prompt when the agent touches
matching files (or a task matches `task_contains`). This is unrelated to the
`decompose → to-issues` planning lane and `task-skill-map.json` — those are a
separate routing path. So register a skill here **only if it is technical / routable**.

**One-minute test — both must be YES to register:**

1. Could a headless coder agent, already mid-task, act on this skill's content with
   **no human present**? (If the skill's first meaningful step is an interview,
   approval gate, or phase hand-off → NO → do not register.)
2. Can you write a glob or `task_contains` predicate that fires **only** when this
   skill's domain is in play? (If it would only match a wide `**/*` glob with no
   precision filter → NO → do not register.)

| Signal | Technical (register) | Interactive/meta (skip) |
|--------|----------------------|-------------------------|
| Invocation | Dispatched by another skill/agent | Invoked directly by a human |
| First step | Reads context and acts | Asks a question / waits for approval |
| Output | Advisory context a coder acts on silently | Planning artifact for human review |
| Mode | Autonomous / headless-safe | Blocks on human decision |
| Primary action | Modifies/verifies a concrete artifact | Orchestrates a phase or manages issues/PRs/boards |

- **Register:** `langgraph-*`, `manage-postgres`, `build-fix-types`, `build-verify`,
  `build-implement-tdd`, `e2e-testing-patterns`, `temporal-development`.
- **Skip:** `brainstorming`, `grill`, `create-prd`, `decompose`, `to-issues`,
  `makato-plugin-creator`, `makato-skill-creator`, `sync-from-upstream`, `loop`, `seed-issue`.

Edge cases: a skill with both an interactive and an AUTONOMOUS-MODE path (e.g.
`build-simplify`) counts as technical — the autonomous path is the registry's
consumer. A constructor-scaffolder hybrid is technical only if its clarifying
question is optional or inferable from file context; if mandatory and blocking, skip.

## What it is

`plugins/<plugin>/config/skill-bundles.yml` maps changed-file globs (plus optional
content-hint predicates) to recommended skills that `inject-skills` prepends into an
agent's system prompt before dispatch. A newly created **technical** skill (see the
gate above) must be registered here, or `inject-skills` will never recommend it.

## Schema

```yaml
version: "1.0"

bundles:
  - name: <globally-unique-bundle-name>
    globs:
      - "<path-glob>"
    contains:        # optional — OR-substring file-content filter
      - "<substring>"
    task_contains:   # optional — OR-substring task-text filter (F5)
      - "<substring>"
    skills:
      - <installed-skill-directory-name>
```

- `name` — globally unique across the **merged** registry (all plugins); a
  collision raises HALT-006. Always prefix with the plugin's short name
  (`<prefix>` = plugin name without `makato-`), e.g. `contribute-skills`.
- `contains` / `task_contains` — optional OR-substring precision filters (see the
  wide-glob rule below).
- `skills` — installed skill directory names; a name not installed in the target
  repo is silently skipped at runtime (D18), so this file is the strict gate.

## The self-referential `<prefix>-skills` bundle

Every plugin's registry has one bundle that fires when an agent edits the plugin's
own skill files:

```yaml
  - name: <prefix>-skills
    globs:
      - "plugins/<plugin>/skills/**/*.md"
    skills:
      - <every technical skill in the plugin>
```

This is the bundle a newly-created skill is appended to. Its glob has ≥ 3 literal
segments, so it is a **narrow** glob and needs no `contains` filter.

## Wide-glob precision-filter gate

A **wide glob** has ZERO literal path segments — every segment contains `*` or `?`
(e.g. `**/*`, `**/*.py`). A bundle whose glob is wide **and** recommends skills
**must** declare either a `contains:` or a `task_contains:` predicate, or the
pre-commit gate `validate-skill-bundles.sh` rejects it. A **narrow** glob (≥ 1
literal segment) is exempt. The `<prefix>-skills` bundle is always narrow, so this
rule only matters if you add extra content-routed bundles.

## Never add a `default` bundle

`makato-build` owns the single suite-wide `default` bundle (glob `**/*`). A
per-plugin registry contains only that plugin's non-default bundles. Adding a
second `default` breaks the merged-registry invariant.

## Validation

```bash
./plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh plugins/<plugin>/config/skill-bundles.yml
```

Exit `0` = pass, `1` = wide-glob-without-precision-filter violation, `2` = parse error.
