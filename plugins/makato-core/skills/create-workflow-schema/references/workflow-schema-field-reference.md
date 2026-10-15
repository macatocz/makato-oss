# Workflow Schema Field Reference

> MANDATORY: Load this reference when the user asks about a specific YAML field, multi-dependency
> `after:` syntax, loader parsing constraints, or any edge case not covered by the main skill body.
> Do NOT load during normal wizard execution.

## Top-level fields

| Field             | Type    | Required             | Description                                                                                                          |
| ----------------- | ------- | -------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `version`         | string  | yes                  | Schema format version. Always `"1.0"`.                                                                               |
| `artifacts`       | list    | for custom pipelines | Ordered artifact entries. Omit only for an execution-only override; the loader then uses the built-in artifact list. |
| `skill_execution` | mapping | no                   | Provider-neutral per-skill role/effort defaults and overrides. May appear before or after `artifacts`.               |

## Skill execution settings

`skill_execution` configures how a skill is launched; it does not select a concrete provider model.
OMP `modelRoles` maps each role alias to concrete model selector(s). The loader adds resolved `role`
and `effort` fields to every artifact's JSON output.

| Field                                         | Type    | Description                                                                                                              |
| --------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------ |
| `skill_execution.defaults.role`               | string  | OMP role name. Defaults to `DEFAULT`; any valid configured role name is accepted.                                        |
| `skill_execution.defaults.effort`             | string  | Thinking effort: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `auto`, or `inherit`. Defaults to `inherit`. |
| `skill_execution.skills`                      | mapping | Per-skill overrides, keyed by quoted plugin-qualified name such as `"makato-build:build-review"`.                        |
| `skill_execution.skills[plugin:skill].role`   | string  | Overrides the role for that skill only.                                                                                  |
| `skill_execution.skills[plugin:skill].effort` | string  | Overrides thinking effort for that skill only. `inherit` omits the thinking flag.                                        |

Project values merge field by field, not as whole records. Precedence is built-in defaults <
built-in skill override < project defaults < project skill override. A later mapping that supplies
only `effort` does not replace an earlier `role`.

```yaml
skill_execution:
  defaults:
    role: DEFAULT
    effort: inherit
  skills:
    "makato-plan:create-prd":
      role: PLAN
      effort: high
    "makato-change:resolve-review":
      role: REVIEW
      effort: medium
    "makato-build:build-review":
      role: REVIEW
      effort: high
```

`DEFAULT` routes through OMP's `@default` role; `PLAN` uses the built-in `@plan` role. `REVIEW` is
custom, not a built-in OMP role: configure `modelRoles.review` explicitly in OMP config. The skill
resolver does not edit global or project OMP configuration. Role names are emitted uppercase by the
loader and lowercased by the launcher when selecting OMP's `@role` alias.

A local schema may contain only `skill_execution`. In that case the loader uses the built-in
`artifacts` list while applying project execution overrides. Arbitrary custom artifact skills remain
supported: an unregistered skill resolves from the merged defaults and an exact project skill
override, if present.

Direct file reads and slash-skill invocations do not switch the active model; use
`plugins/makato-build/scripts/run-skill.py` for schema-aware dispatch. See `docs/workflow-schema.md`
for the launcher command and OMP `modelRoles` example. Skill execution configuration is separate
from existing per-agent model settings (such as `modelRole` in agent frontmatter); it does not
rewrite or replace the models selected for nested agents.

---

## Artifact entry fields

| Field         | Type           | Required | Description                                                                                                               |
| ------------- | -------------- | -------- | ------------------------------------------------------------------------------------------------------------------------- |
| `id`          | string         | yes      | Unique kebab-case identifier. Referenced by other artifacts in `after:`.                                                  |
| `skill`       | string         | yes      | Skill name (e.g. `build-verify`) or plugin-qualified name (e.g. `my-plugin:my-skill`).                                    |
| `required`    | bool           | yes      | `true` — pipeline aborts if this artifact is skipped. `false` — pipeline continues.                                       |
| `description` | string         | no       | Inline-quoted string only. Block scalars (`>`, `\|`) are silently truncated by the loader's hand-written parser.          |
| `after`       | list of string | no       | IDs of artifacts that must complete before this one runs. Omit (do not write `after: []`) when there are no dependencies. |

## `after:` array semantics

`after:` declares direct predecessors in the DAG — the artifacts whose output this artifact
consumes. The loader computes the full transitive closure; you only need to list **immediate**
predecessors.

**Single dependency:**

```yaml
after: [verify]
```

**Multiple dependencies (fan-in):**

```yaml
after: [implement-tdd, implement-goal]
```

This means "run after whichever of implement-tdd / implement-goal completes last." Both must reach
done-state before this artifact is dispatched.

**No dependencies (root node):** Omit `after:` entirely. Do not write `after: []` — the hand-written
parser does not recognise the empty-list form reliably.

## Loader parsing constraints

The artifact parser in `workflow-schema-loader.sh` recognizes the restricted fields `id`, `skill`,
`required`, `description`, and `after`. It stops when it reaches a new top-level section; a
following `skill_execution` mapping is never interpreted as artifact fields.

- `description:` values must be **inline-quoted strings**; do not use `>` or `|` block scalars in
  the artifact list.
- Use `true`/`false` for `required:`. The artifact parser does not normalize `yes`/`no`.
- Keep artifact indentation consistent (2 spaces); mixed tabs/spaces can skip fields.
- `skill_execution` is read by `shared/skill_execution.py` with PyYAML, not by the restricted
  artifact parser. Python 3 and the PyYAML runtime package are required. Quote plugin-qualified keys
  such as `"makato-build:build-review"`. Invalid values, duplicate mapping keys, or malformed YAML
  produce a loader error on stderr.

## Multi-dependency edge cases

### Diamond DAG

```text
refine → implement-tdd ─┐
       → implement-goal ─┴→ simplify → review → verify
```

`simplify` lists `after: [implement-tdd, implement-goal]`. The loader's topological sort correctly
waits for both even when one implementation mode is skipped — it tracks done-state per artifact, not
per branch.

### Custom artifact inserted mid-pipeline

A `security-audit` artifact consuming source code and feeding `sensors`:

```yaml
- id: security-audit
  skill: my-plugin:security-audit
  required: true
  description: "SAST scan over changed files"
  after: [implement-tdd, implement-goal]
```

And update `sensors` to add `security-audit` to its `after:` list:

```yaml
- id: sensors
  skill: build-sensors
  required: true
  description: "Run pre-commit sensors; dispatch sensor-fixer per finding"
  after: [verify, security-audit]
```

Inserting mid-pipeline requires updating the downstream artifact's `after:` list — the wizard's Step
5 collects the insertion point but the user must confirm the downstream edit.

### Isolating an optional artifact

To make `grill-with-docs` skippable without breaking the rest of the pipeline: keep it
`required: false` and do **not** put it in any other artifact's `after:` list. `build-start` will
offer to skip optional artifacts; if skipped the DAG proceeds without waiting for it.
