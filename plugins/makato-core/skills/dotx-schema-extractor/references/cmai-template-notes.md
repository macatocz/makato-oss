# CMAI template notes

Specifics for the Časová analýza family. The extractor is generic, but
these gotchas are common enough in CMAI work that they belong here.

## Source templates

|Path|Purpose|
|---|---|
|`Podklady CMS/Casova Analyza stavby/Časová analýza_vzor.dotx`|Old checklist-only template. Tiny — almost nothing variable.|
|`Podklady CMS/Casova Analyza stavby/Časová_analýza_vzor_local.dotx`|Local copy of the same.|
|`Podklady CMS/Vzorové dokumenty CM/Casova_analyza/Aktualizace/Časová analýza_aktualizovaný vzor_VH + AP.dotx`|The current canonical template — 12 SDTs, 1298 cyan + 418 yellow highlight runs, 38 Word comments.|

For new agent work always target the **aktualizovaný vzor**. The
extractor produces ~118 fields against it, dominated by cyan-highlight
instructions.

## Czech diacritics

`label` and `description` keep diacritics so the human reading the
schema can match them against the rendered Word document. `key` is
ASCII-folded (`Skutečnost` → `skutecnost`) so the JSON contract is
portable across Python, JavaScript, and JSON Schema validators that
balk at non-ASCII keys.

The mapping is NFKD-fold then strip combining marks. It is not
reversible — never round-trip a key back to a Czech label by guessing.

## "Skutečnost č. AAAAAAA" placeholders

Section headings in the aktualizovaný vzor read:

```text
3.1 Skutkový průběh Skutečnosti č. AAAAAAA
4.1 Skutkový průběh Skutečnosti č. BBBBBB
```

The literal `AAAAAAA` / `BBBBBB` runs are placeholders, not data. They
appear unhighlighted in the source but mark a repeating section. The
extractor's table-repeat heuristic does NOT catch these — the
repetition is at heading-section granularity, not table-row.

For now: capture them as `kind: instruction` (since they show up in
highlighted runs nearby) and ask the human to promote the surrounding
section to a `repeats[]` entry keyed `skutecnosti`. A future improvement
to the extractor could detect heading sequences with identical sub-tree
structure.

## FIDIC clause references

Phrases like `Pod-čl. 8.4 OP` are content, not slots — they will be
filled by the agent via free-text per Skutečnost. The extractor does
not detect these specifically; they show up as instruction-highlight
fields with descriptions like `Pod-čl. ZZZ OP` when present in the
template's example placeholders.

## Tabulka 8 — the delay calculation table

Per the user research note, Tabulka 8 carries variable rows per
Skutečnost (milestones with `narokovany`, `kvantifikovany`, `uznatny`,
`prodlouzeni`). When the template has at least 2 example rows with
identical SDT shape, the table-repeat heuristic emits this as
`repeats[].key = tabulka_8` (or similar slug derived from the header).

The current aktualizovaný vzor has these rows fully prose-formatted
with cyan highlights rather than per-cell SDTs, so the heuristic
returns `repeats: []`. Expect to add manual repeat entries for
`milniky` and `skutecnosti` when handing the schema to the agent.

## Checkboxes in the old `Časová analýza_vzor.dotx`

The pre-2024 template uses Word checkbox SDTs for a checklist.
`extract_sdts` skips these (`<w14:checkbox>`) — they are UI affordances,
not schema fields. If a downstream agent really does need to populate
checklist state, capture it via a separate convention; do not rely on
this skill to detect it.

## Word comments

The aktualizovaný vzor carries 38 Word comments with human guidance
("Choose item", "Add detail here"). The extractor pairs each
`commentRangeStart`/`commentRangeEnd` in `document.xml` with the
comment text in `word/comments.xml` and emits a field with
`source: "comment"`, `kind: "instruction"`. The comment text becomes
the `description`; the anchored span becomes the `label`.

Some comments anchor a position rather than a span — in that case the
extractor falls back to the paragraph text for the label so the field
still has grounding context. Pass `--no-comments` to skip them
entirely.
