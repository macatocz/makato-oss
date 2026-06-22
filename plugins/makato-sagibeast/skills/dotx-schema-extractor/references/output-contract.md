# Output contract — JSON schema

The full shape of `schema.json`. Stable across versions of this skill.
Add new keys, never repurpose old ones.

## Top-level

```json
{
  "template": { ... },
  "fields":   [ ... ],
  "repeats":  [ ... ],
  "warnings": [ ... ]
}
```

### `template`

|key|type|notes|
|---|---|---|
|`path`|string|Absolute path to the source `.dotx`/`.docx`|
|`sha256`|string|Hex digest of the file contents — use to detect template change|
|`extracted_at`|string|ISO-8601 UTC timestamp|

### `fields[]`

One entry per unique variable slot. Keys are stable across re-runs as
long as the template hasn't changed.

|key|type|required|notes|
|---|---|---|---|
|`key`|string|yes|`snake_case`, ASCII-folded; the agent's JSON key|
|`label`|string|yes|Human-readable label, diacritics preserved|
|`kind`|string|yes|`text` \| `enum` \| `date` \| `number` \| `instruction`|
|`source`|string|yes|`sdt` \| `mergefield` \| `docproperty` \| `placeholder` \| `highlight` \| `comment`|
|`required`|bool|yes|Defaults `true`; set `false` only when the template makes optionality explicit|
|`description`|string|yes|Free-text grounding — alias, instruction text, or placeholder context|
|`occurrences`|int|yes|How many times the field appeared (after dedup)|
|`first_paragraph_text`|string|yes|≤120 chars of surrounding paragraph for human grounding|
|`enum`|string[]|when `kind=enum`|Allowed values from `<w:listItem w:value>`|
|`format`|string|when `kind=date`|`<w:dateFormat w:val>` from the SDT, e.g. `dd.MM.yyyy`|

### `repeats[]`

Heuristic groups. Always populate `evidence` so the human can re-locate
the source. Empty array when no repeats inferred.

|key|type|notes|
|---|---|---|
|`key`|string|`snake_case` slug for the repeat group (becomes a JSON array key)|
|`row_template`|object[]|Same shape as `fields[]`; describes one row|
|`evidence`|string|Locator like `table 4, 6 rows, header: Tabulka 8`|

### `warnings[]`

Plain strings. Each warning is something a human must verify before
shipping the schema to a generation agent. Examples:

- `107 instruction-kind fields need human review — decide concrete keys
  and types before handing to the agent`
- `2 repeat groups inferred heuristically — verify`
- (when neither rule fires) — empty array, no `null`s.

### `curation` (optional)

Present only on schemas produced by `apply_decisions.py`. Top-level
key alongside `template`, `fields`, `repeats`, `warnings`.

| key | type | notes |
| --- | --- | --- |
| `decisions_path` | string | Filename (basename) of the `decisions.json` that drove this curation |
| `curated_at` | string | ISO-8601 UTC timestamp |
| `stats.raw_total` | int | Number of decisions in the manifest |
| `stats.kept` | int | Decisions with verdict `slot` or `enum` |
| `stats.tossed` | int | Decisions with verdict `prose_drop` or `toss` |
| `stats.prose_kept` | int | Decisions with verdict `prose_keep` (text retained, no schema field) |
| `stats.comments_promoted` | int | Decisions with verdict `comment_keep_as_description` |

Consumers can use `curation.stats` for at-a-glance triage before
inspecting individual fields.

## Stability promise

- `key` values are stable for unchanged templates: same SDT tag, same
  placeholder text, same highlighted phrase yields the same key.
- `template.sha256` lets a downstream tool decide whether to re-extract.
- New `kind` or `source` values may be added in future versions; agents
  should treat unknown values as `text`/`sdt` defaults rather than
  failing.

## What is NOT in this output

- The Word XML — extraction is one-way; the renderer reads the original
  `.dotx`, not this JSON.
- Style information (font, color, indentation) — the schema is
  semantics-only.
- Validation rules beyond `enum` membership and `date` format —
  cardinality, regex constraints, cross-field rules belong in the
  agent's system prompt or a separate validator.
