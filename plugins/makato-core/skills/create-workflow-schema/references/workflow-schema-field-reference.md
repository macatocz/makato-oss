# Workflow Schema Field Reference

> MANDATORY: Load this reference when the user asks about a specific YAML field,
> multi-dependency `after:` syntax, loader parsing constraints, or any edge case
> not covered by the main skill body. Do NOT load during normal wizard execution.

## Top-level fields

| Field     | Type   | Required | Description                              |
|-----------|--------|----------|------------------------------------------|
| `version` | string | yes      | Schema format version. Always `"1.0"`.   |
| `artifacts` | list | yes      | Ordered (by you) list of artifact entries. The loader reorders by DAG topology. |

## Artifact entry fields

| Field         | Type           | Required | Description |
|---------------|----------------|----------|-------------|
| `id`          | string         | yes      | Unique kebab-case identifier. Referenced by other artifacts in `after:`. |
| `skill`       | string         | yes      | Skill name (e.g. `build-verify`) or plugin-qualified name (e.g. `my-plugin:my-skill`). |
| `required`    | bool           | yes      | `true` — pipeline aborts if this artifact is skipped. `false` — pipeline continues. |
| `description` | string         | no       | Inline-quoted string only. Block scalars (`>`, `\|`) are silently truncated by the loader's hand-written parser. |
| `after`       | list of string | no       | IDs of artifacts that must complete before this one runs. Omit (do not write `after: []`) when there are no dependencies. |

## `after:` array semantics

`after:` declares direct predecessors in the DAG — the artifacts whose output this
artifact consumes. The loader computes the full transitive closure; you only need to
list **immediate** predecessors.

**Single dependency:**
```yaml
after: [verify]
```

**Multiple dependencies (fan-in):**
```yaml
after: [implement-tdd, implement-goal]
```
This means "run after whichever of implement-tdd / implement-goal completes last."
Both must reach done-state before this artifact is dispatched.

**No dependencies (root node):**
Omit `after:` entirely. Do not write `after: []` — the hand-written parser does not
recognise the empty-list form reliably.

## Loader parsing constraints

The parser in `workflow-schema-loader.sh` handles only the restricted YAML subset
described above. Constraints not enforced by standard YAML parsers:

- `description:` values must be **inline-quoted strings**. A `>-` or `|` block scalar
  causes the parser to ingest continuation lines as stray artifact entries.
- `true`/`false` only for `required:`. The parser does not normalise `yes`/`no`.
- Indentation must be consistent (2-space). Mixed tab/space indentation causes silent
  field skips.
- Comments (`#`) are allowed anywhere and are preserved in the file (they are ignored
  by the parser).

## Multi-dependency edge cases

### Diamond DAG
```
refine → implement-tdd ─┐
       → implement-goal ─┴→ simplify → review → verify
```
`simplify` lists `after: [implement-tdd, implement-goal]`. The loader's topological
sort correctly waits for both even when one implementation mode is skipped — it tracks
done-state per artifact, not per branch.

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
Inserting mid-pipeline requires updating the downstream artifact's `after:` list —
the wizard's Step 5 collects the insertion point but the user must confirm the
downstream edit.

### Isolating an optional artifact
To make `grill-with-docs` skippable without breaking the rest of the pipeline:
keep it `required: false` and do **not** put it in any other artifact's `after:` list.
`build-start` will offer to skip optional artifacts; if skipped the DAG proceeds
without waiting for it.
