# Routing Registration — two independent paths

A **technical** skill (see the one-minute test in `skill-bundles-rules.md`) must be
registered on **both** routing paths, or a coder will only see it in narrow cases.
The paths are independent; a skill can match on either.

| Path | Config | Fires when | Reaches the coder for |
|------|--------|-----------|-----------------------|
| Glob bundle | `plugins/<plugin>/config/skill-bundles.yml` | a changed file matches a glob (+ optional `contains`) | work that **touches existing files** of that domain |
| Task-archetype | `plugins/makato-plan/config/task-skill-map.json` | a sub-task title matches an archetype key at decompose time | **green-field** work where the domain files don't exist yet |

Register both so the skill surfaces whether the coder edits existing code OR the
decomposer classifies a from-scratch task. Registering only one leaves a gap.

## Glob bundle — domain vs self-dev (the common mistake)

A plugin's registry usually has a self-referential `<prefix>-skills` bundle whose
glob is `plugins/<plugin>/skills/**/*.md`. That glob fires **only when someone edits
the makato plugin's own skill files** — never when a coder writes a user's
application code. Appending your new skill to *only* that bundle means it is
effectively unroutable for real work.

For a domain skill you MUST also add (or extend) a **domain bundle** whose glob
matches the files a user actually writes when the skill's domain is in play:

```yaml
  - name: <prefix>-<domain>          # e.g. langgraph, database-orm, fastapi
    globs:
      - "**/*graph*.py"              # the user-code files this domain lives in
    contains:                        # REQUIRED when the glob is wide (0 literal segments)
      - "from langgraph"
    task_contains:                   # RECOMMENDED — mirrors the task-map trigger
      - "langgraph"
      - "StateGraph"
    skills:
      - <skill-name>
```

Decision:

- **Skill acts on user-authored source files** (a library/framework/SDK pattern,
  a file-format handler, a lint/type/security fixer) → add/extend a **domain
  bundle** with a glob over those files. Add the self-dev `<prefix>-skills` entry
  only if editing the plugin's own skill docs should also surface it.
- **Skill acts only on makato's own plugin files** (contributor tooling) →
  the self-dev `<prefix>-skills` bundle is the correct and only target.

If a matching domain bundle already exists (e.g. `langgraph`, `database-orm`,
`fastapi`), append `<skill-name>` to its `skills:` list rather than creating a new
one. Never leave a wide glob (`**/*`, `**/*.py`) without a `contains` or
`task_contains` filter — the pre-commit gate rejects it.

## Task-archetype map — `task-skill-map.json`

Schema: `{ "<archetype>": ["<plugin>:<skill-id>", ...] }`. Keys are verb-first task
archetypes matched case-insensitively as substrings against sub-task titles by
`decompose`. Add the new skill to every archetype whose work would call for it, and
add a new archetype key if none fits:

```json
  "implement-langgraph-agent": ["makato-langgraph:langgraph-fundamentals", "makato-langgraph:langgraph-agent-patterns"],
  "<new-archetype>": ["<plugin>:<skill-name>"]
```

- Use the fully-qualified `<plugin>:<skill-id>` form — a bare id will not resolve.
- Prefer extending existing archetype keys over inventing near-duplicates.
- The file requires ≥ 200 entries; you are adding to it, never trimming it.

## Skip both paths for interactive/meta skills

If the one-minute test says the skill is interactive/meta (interview-first,
approval-gated, orchestrator, issue/PR/board manager), register on **neither** path
and state that decision in the Step 16 summary. Injecting such a skill into a
headless agent is pure noise.
