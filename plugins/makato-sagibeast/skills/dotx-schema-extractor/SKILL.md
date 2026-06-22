---
name: dotx-schema-extractor
description: Extract a JSON schema from a Word .dotx (or .docx) template by inventorying every variable field — content controls (SDT), MERGEFIELDs, DOCPROPERTY, plain-text placeholder patterns ({{var}}, [VAR], <VAR>), colored-highlighted human instructions, and Word comments. The schema becomes the output contract that an LLM agent fills before docxtpl renders the final document. Use this skill whenever the user asks to "extract schema from a template", "find variable fields in a .dotx", "build a JSON contract from a Word template", "convert template instructions into a schema", "what fields does this template need", or whenever a Word/.dotx/.docx file is involved AND the user wants a structured catalogue of its fillable slots — even if the word "schema" is not used.
version: "1.0.0"
---
## What this skill does

Given a `.dotx` or `.docx`, walk the underlying OOXML and produce a JSON
schema that lists every place a value must be supplied. This becomes the
contract for a generation agent: the agent emits JSON keyed by the schema,
then `docxtpl` (or equivalent) renders the final document.

The schema is **output-shaped** — agent-facing, not validation-shaped. It
tells the agent **what to produce**, not how the renderer enforces it.

## Why each marker matters

The Documents templates use different mechanisms — sometimes
in the same paragraph — to mark "fill me in":

| Marker                                                           | Where it shows up                                                                                                                                                                                  | Schema field source                                        |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Content control (SDT) — plainText, comboBox, dropDownList, date | Modern Word forms                                                                                                                                                                                  | `tag` if present, else `alias`, else slug from context |
| MERGEFIELD                                                       | Classic mail-merge                                                                                                                                                                                 | Field name from `MERGEFIELD <name>`                      |
| DOCPROPERTY                                                      | Document-property fields                                                                                                                                                                           | Property name                                              |
| Placeholder text patterns —`{{var}}`, `[VAR]`, `<VAR>`    | Plain text inserted into the body                                                                                                                                                                  | The captured token                                         |
| Colored-highlighted runs                                         | Human-facing instructions ("write X here"). Practical rule: if it tells a human "write X here", it becomes `{{ x }}` for the agent. Highlight colors are configurable via `--highlight-colors` | A slug derived from the highlighted text                   |
| Word comments                                                    | `commentRangeStart`/`commentRangeEnd` anchored spans paired with `<w:comment>` text in `word/comments.xml`. The comment is the human's instruction; the anchored span is the label.        | A slug derived from the comment text                       |

If the skill catches only one of these and ignores the others, the agent
will silently miss fields. Detect all six.

## Decision flow

```text
1. Is the file a .dotx or .docx?           → if no, stop and say so.
2. Unzip and parse word/document.xml,      → also headers/footers.
3. Walk every <w:sdt> →                     → emit one field per SDT.
4. Walk every field code (MERGEFIELD,      → emit one field per code.
   DOCPROPERTY) inside <w:instrText>.
5. Walk visible text from <w:t> and run    → emit one field per unique
   regexes for {{x}}, [VAR], <VAR>.          pattern hit.
6. Walk every run with colored      → emit one field per highlighted
   highlight (w:highlight w:val="color").     span, slug from the text.
7. Detect repeats:                          → group adjacent SDTs sharing
                                              tag/alias OR find table rows
                                              whose only variable content
                                              repeats with identical
                                              structure → emit as JSON
                                              array.
8. Deduplicate by canonical key.            → preserve order of first
                                              appearance.
9. Emit JSON. Echo a markdown summary.
```

For the XML pattern of each step, see `references/markers.md`.

## How to invoke

The skill ships a deterministic Python extractor. Prefer it over
re-implementing the parse:

```bash
python "${SKILL_DIR}/scripts/extract_schema.py" \
    --input "/path/to/template.dotx" \
    --output "/path/to/schema.json" \
    [--include-instructions]              # highlighted runs as fields (default: on)
    [--no-instructions]                   # ignore highlighted runs
    [--include-comments]                  # Word comments as fields (default: on)
    [--no-comments]                       # ignore Word comments
    [--highlight-colors color1,color2]      # comma-separated <w:highlight> values
    [--detect-repeats]                    # heuristic table merge (default: on)
    [--no-repeats]
    [--summary-md schema.md]              # human-readable summary alongside JSON
```

The script writes JSON to `--output` and prints a one-line stats summary
to stdout (`fields=N controls=M comments=C repeats=K warnings=W`). When
you run it, surface that summary back to the user — it's the headline
result.

### Choosing highlight colors

Word's `<w:highlight w:val>` allows: `black`, `blue`, `cyan`, `darkBlue`,
`darkCyan`, `darkGray`, `darkGreen`, `darkMagenta`, `darkRed`,
`darkYellow`, `green`, `lightGray`, `magenta`, `none`, `red`, `white`,
`yellow`. 

## Output schema (the schema OF the schema)

The script emits this shape:

```json
{
  "template": {"path": "...", "sha256": "...", "extracted_at": "ISO-8601"},
  "fields": [
    {
      "key": "stavba_nazev",
      "label": "Název stavby",
      "kind": "text",
      "source": "sdt",
      "required": true,
      "description": "instruction text, alias, or placeholder",
      "enum": ["..."],
      "format": "DD.MM.YYYY",
      "occurrences": 3,
      "first_paragraph_text": "..."
    }
  ],
  "repeats": [
    {
      "key": "skutecnosti",
      "row_template": [{}],
      "evidence": "table at body[42], 3 example rows"
    }
  ],
  "warnings": ["string — anomalies the human should check"]
}
```

`kind` is one of: `text`, `enum`, `date`, `number`, `instruction`.
`source` is one of: `sdt`, `mergefield`, `docproperty`, `placeholder`,
`highlight`, `comment`. `enum` is populated only when `kind == "enum"`.
`format` is populated only when `kind == "date"`. `first_paragraph_text`
is ~120 chars of grounding context.

### Field-key derivation rules — apply in order

1. SDT `<w:tag>` if present → snake_case it.
2. Otherwise SDT `<w:alias>` → snake_case.
3. Otherwise the captured placeholder token (`{{ x }}` → `x`).
4. Otherwise the first 6 words of highlighted/instruction text →
   snake_case.
5. If the resulting key collides with one already emitted, append `_2`,
   `_3`, …

### `kind` derivation

- `comboBox` / `dropDownList` → `enum`, populate `enum` from
  `<w:listItem w:value>`.
- `<w:date>` SDT → `date`, capture `<w:dateFormat>`.
- Highlighted run (color in `--highlight-colors`) without an SDT around
  it → `instruction` (still emit it; agents need to know).
- Word comment anchoring a span of text → `instruction` with
  `source: "comment"`.
- Everything else → `text`.

Diacritics: keep them in `label` and `description`; strip + ASCII-fold them
in `key` so the JSON is portable across Python/JS consumers.

## Repeat detection

A repeat is a table or paragraph block whose structure recurs with
placeholder content varying. Heuristics, in order:

1. A `<w:tbl>` with ≥2 rows whose row pattern (count and types of SDTs/
   placeholders per row) is identical → emit as `repeat` with
   `row_template` from the first row.
2. A run of `<w:p>` paragraphs each containing exactly one SDT with the
   same `tag` → group as `repeat`.
3. Heading patterns like "Skutečnost č. AAA…", "Skutečnost č. BBB…" with
   identical sub-structure (detected by repeated section-numbering style)
   → emit a `repeat` whose row_template covers the section's variable
   fields.

Repeats found this way are heuristic. Always populate `evidence` with the
locator and the row count, and add to `warnings` when the row pattern was
non-trivial to infer — the user must verify before wiring the schema into
the agent.

## What to do after extraction

1. Run the extractor.
2. Open `schema.json`. Read the `warnings` array out loud — these are the
   places the heuristics weren't confident.
3. For every `kind: "instruction"` field, propose a concrete key name to
   the user (the slug is a draft) and ask whether it should be free-text,
   enum, or date.
4. Resolve each warning. Edit the schema in place — the script is one-shot,
   not idempotent across edits, so once humans curate it, do not re-run
   extraction over the same file without diffing.
5. Hand the resulting schema to the document-generation agent as its
   output contract; pair it with the `.dotx` and a docxtpl renderer.

## When the script can't help

If the input is a corrupt OOXML, a `.doc` (binary, not XML), or a PDF, stop
and say so — do not paper over with manual reading. The skill assumes Open
XML.

## Curation workflow

The default extractor produces a raw inventory of every marker.
Curation is a two-phase workflow that turns the raw inventory into
a hand-curated contract paired with an AI-ready .dotx:

### Phase 1 — chat walkthrough

Run inline in chat. The assistant reads `eval_0_schema.json`,
pre-tosses the obvious junk buckets (placeholder dates, section
numbers, single-token fillers like `XX` or `ANO/NE`), then presents
each remaining field one at a time with a proposed verdict. The
user replies with `yes | rename <key> | retype <kind> | enum <a,b,c> | prose | toss | skip`. Decisions accumulate in
`<workspace>/iteration-2/decisions.json`.

### Phase 2 — batch apply

```bash
python scripts/apply_decisions.py \
  --dotx-in "<original.dotx>" \
  --decisions <workspace>/iteration-2/decisions.json \
  --dotx-out "<workspace>/iteration-2/<name>_AI.dotx" \
  --schema-out <workspace>/iteration-2/schema_curated.json \
  --diff-out <workspace>/iteration-2/diff_report.html
```

The script:

- Refuses if the original .dotx SHA256 differs from
  `template_sha256` recorded in the manifest.
- Mutates an in-memory copy of `word/document.xml` and
  `word/comments.xml` per the verdict vocabulary
  (`slot` / `enum` / `prose_keep` / `prose_drop` /
  `comment_keep_as_description` / `toss`).
- Writes the AI-ready `.dotx`, the curated schema (with a top-level
  `curation` envelope key), and a self-contained HTML diff report.

The original `.dotx` is never opened for writing.

## Reference files

- `scripts/extract_schema.py` — the deterministic extractor. Read it before
  modifying behavior; it is intentionally small and pure-stdlib (zipfile +
  xml.etree).
- `references/markers.md` — XML patterns for each of the five marker types,
  with examples lifted from the real CMAI templates.
- `references/output-contract.md` — full JSON schema of the output and
  every field's semantics.
- `references/cmai-template-notes.md` — CMAI-specific gotchas (Czech
  diacritics, headings like "Skutečnost č. AAAAAAA", FIDIC clause
  references).

Read these files only when you need them — the SKILL.md alone is enough to
drive the script for the common case.
