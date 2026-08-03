# Workflow Schema Format

The makato-build workflow schema lets teams customise the skill pipeline that
`build-start` assembles for each story session. When `.claude/workflow-schema.yml`
is present in the repository root, `workflow-schema-loader.sh` parses it and
returns the ordered artifact list. When the file is absent, the built-in default
schema in `plugins/makato-build/config/default-workflow-schema.yml` is used and
the pipeline is identical to the current hardcoded behaviour.

Issue: #563

---

## File location

```text
<repo-root>/.claude/workflow-schema.yml
```

The loader searches for this path. Absence is not an error — the built-in default
is returned silently.

---

## Top-level fields

| Field      | Type   | Required | Description |
|-----------|--------|----------|-------------|
| `version` | string | yes      | Schema format version. Currently `"1.0"`. |
| `artifacts` | list | yes      | Ordered list of pipeline artifacts. At least one entry is required. |

---

## `artifacts[]` entry fields

| Field         | Type         | Required | Description |
|--------------|-------------|----------|-------------|
| `id`          | string       | yes      | Unique identifier for this artifact within the schema. Used in `after:` dependency references. |
| `skill`       | string       | yes      | The makato-build skill invoked for this artifact (e.g. `build-refine`, `build-verify`). Custom artifacts may name any skill path. |
| `required`    | boolean      | yes      | When `true`, the skill MUST be run; when `false`, the skill is optional and may be skipped by the runner. |
| `description` | string       | no       | Human-readable summary of what this artifact produces. |
| `after`       | list[string] | no       | IDs of artifacts that must complete before this one may start. Omit or leave empty for the entry point. Forms the dependency edges of the DAG. |

### Dependency syntax (`after:`)

`after:` accepts a YAML list of artifact `id` strings:

```yaml
after: [implement-tdd, implement-goal]
```

Or in block style:

```yaml
after:
  - implement-tdd
  - implement-goal
```

The loader validates the `after:` list for cycles (both direct and transitive).
A circular dependency causes the loader to exit 1 with the full cycle path in the
error message.

### `required` vs optional artifacts

- `required: true` — the skill MUST appear in every pipeline execution.
- `required: false` — the skill is optional. The caller decides whether to invoke
  it based on context (e.g. `grill-with-docs` is optional; `address-pr-comments`
  is only needed after review feedback arrives).

---

## Annotated example

The following schema adds a custom `security-audit` artifact between `verify` and
`sensors`, and marks `grill-with-docs` as required for this repo:

```yaml
version: "1.0"

artifacts:
  - id: refine
    skill: build-refine
    required: true
    description: "Bridge planned story to implementation plan"

  - id: grill-with-docs
    skill: build-grill-with-docs
    required: true            # overridden to required for this repo
    description: "Align plan vocabulary to domain model"
    after: [refine]

  - id: implement-tdd
    skill: build-implement-tdd
    required: false
    description: "TDD inner loop"
    after: [refine]

  - id: implement-goal
    skill: build-implement-goal
    required: false
    description: "Goal-driven inner loop"
    after: [refine]

  - id: simplify
    skill: build-simplify
    required: true
    after: [implement-tdd, implement-goal]

  - id: review
    skill: build-review
    required: true
    after: [simplify]

  - id: verify
    skill: build-verify
    required: true
    after: [review]

  - id: security-audit           # custom artifact not in the built-in default
    skill: security-audit
    required: true
    description: "Internal security scan before pre-commit sensors"
    after: [verify]

  - id: sensors
    skill: build-sensors
    required: true
    after: [security-audit]     # now depends on the custom step

  - id: push-to-git
    skill: build-push-to-git
    required: true
    after: [sensors]

  - id: create-pr
    skill: build-create-pr
    required: true
    after: [push-to-git]

  - id: address-pr-comments
    skill: build-address-pr-comments
    required: false
    after: [create-pr]
```

---

## Cycle detection

The loader uses depth-first search to detect circular dependencies before
returning the ordered artifact list.

**Direct cycle** (`A → B → A`):

```yaml
artifacts:
  - id: A
    skill: build-refine
    required: true
    after: [B]
  - id: B
    skill: build-verify
    required: true
    after: [A]
```

Error output:

```text
workflow-schema-loader: cycle detected: A -> B -> A
```

**Transitive cycle** (`A → B → C → A`):

```yaml
artifacts:
  - id: A
    skill: build-refine
    required: true
    after: [C]
  - id: B
    skill: build-verify
    required: true
    after: [A]
  - id: C
    skill: build-sensors
    required: true
    after: [B]
```

Error output:

```text
workflow-schema-loader: cycle detected: A -> C -> B -> A
```

The loader exits 1 on any cycle. Fix the schema before running `build-start`.

---

## Creating a schema interactively

Run `/makato-core:create-workflow-schema` to launch an interactive wizard that
guides you through artifact selection and generates `.claude/workflow-schema.yml`.

---

## See also

- `plugins/makato-build/config/default-workflow-schema.yml` — built-in default
- `plugins/makato-build/scripts/workflow-schema-loader.sh` — the resolver
- `plugins/makato-build/skills/build-start/SKILL.md` — the consumer
