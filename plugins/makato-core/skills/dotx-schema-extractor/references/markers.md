# Markers — XML patterns by source

This is the bestiary the extractor walks. Examples are lifted from the real
CMAI templates so you can grep them directly.

## SDT (Structured Document Tag) — `source: sdt`

The dominant marker in `Časová analýza_aktualizovaný vzor_VH + AP.dotx`
(34 SDTs).

### Plain-text SDT

```xml
<w:sdt>
  <w:sdtPr>
    <w:alias w:val="Název stavby"/>
    <w:tag w:val="Stavby"/>
    <w:placeholder><w:docPart w:val="..."/></w:placeholder>
  </w:sdtPr>
  <w:sdtContent>
    <w:r><w:t>Zvolte položku.</w:t></w:r>
  </w:sdtContent>
</w:sdt>
```

→ `kind: "text"`, `key: slug(tag) || slug(alias)`.

### comboBox SDT — closed enum

```xml
<w:sdt>
  <w:sdtPr>
    <w:alias w:val="Objednatel"/>
    <w:tag w:val="Objednatel"/>
    <w:comboBox>
      <w:listItem w:displayText="Ředitelství silnic a dálnic ČR"
                  w:value="Ředitelství silnic a dálnic ČR"/>
      <w:listItem w:displayText="Správa železnic"
                  w:value="Správa železnic"/>
    </w:comboBox>
  </w:sdtPr>
  ...
</w:sdt>
```

→ `kind: "enum"`, `enum: [...]`.

### dropDownList SDT

Same as comboBox but `<w:dropDownList>`. Treat identically.

### date SDT

```xml
<w:sdt>
  <w:sdtPr>
    <w:date w:fullDate="2020-07-10T00:00:00Z">
      <w:dateFormat w:val="dd.MM.yyyy"/>
    </w:date>
  </w:sdtPr>
  <w:sdtContent>
    <w:r><w:t>10.07.2020</w:t></w:r>
  </w:sdtContent>
</w:sdt>
```

→ `kind: "date"`, `format: <w:dateFormat>`.

### Checkbox SDT — skip

```xml
<w:sdt>
  <w:sdtPr>
    <w14:checkbox><w14:checked w14:val="0"/></w14:checkbox>
  </w:sdtPr>
  ...
</w:sdt>
```

The extractor explicitly skips these — they are UI affordances, not
schema fields.

## MERGEFIELD — `source: mergefield`

```xml
<w:r>
  <w:fldChar w:fldCharType="begin"/>
</w:r>
<w:r>
  <w:instrText xml:space="preserve"> MERGEFIELD ClientName \* MERGEFORMAT </w:instrText>
</w:r>
```

Regex: `MERGEFIELD\s+([^\s\\]+)`. → `kind: "text"`.

## DOCPROPERTY — `source: docproperty`

```xml
<w:instrText> DOCPROPERTY DocumentTitle \* MERGEFORMAT </w:instrText>
```

Regex: `DOCPROPERTY\s+([^\s\\]+)`. → `kind: "text"`.

## Plain-text placeholders — `source: placeholder`

Patterns scanned across the concatenated `<w:t>` text of each paragraph:

|Pattern|Regex|Example|
|---|---|---|
|Jinja2-style|`\{\{\s*([a-zA-Z_][\w.]{0,80})\s*\}\}`|`{{ stavba.nazev }}` → `stavba.nazev`|
|BRACKET|`\[([A-Z_][A-Z0-9_]{2,40})\]`|`[CLIENT_NAME]` → `CLIENT_NAME`|
|ANGLE|`<([A-Z_][A-Z0-9_]{2,40})>`|`<CLIENT_NAME>` → `CLIENT_NAME`|

The lower-bound of 2-3 letters keeps the regex from matching XML tags
or short fragments. The bracket/angle patterns require ALL CAPS to
distinguish from prose.

## Highlighted instructions — `source: highlight`

The CMAI aktualizovaný vzor uses cyan highlights extensively (1298
runs) plus yellow on choices (418 runs). Other Word `<w:highlight>`
values include `green`, `red`, `magenta`, `blue`, `darkYellow`,
`lightGray`, etc. — see `--highlight-colors`.

```xml
<w:r>
  <w:rPr>
    <w:highlight w:val="cyan"/>
  </w:rPr>
  <w:t>stručný popis Skutečností které způsobují zpoždění</w:t>
</w:r>
```

Detection rules:

1. The color must be in the user-supplied set (default `cyan,yellow`).
   Other Word colors are content emphasis, not instructions.
2. Contiguous runs sharing the same highlight color collapse into
   one field. A break in color or a non-highlighted run flushes
   the span.
3. Runs inside a `<w:sdt>` are excluded — they're double-counted
   otherwise.

→ `kind: "instruction"`, `key` from first 6 words slug.

## Word comments — `source: comment`

The CMAI aktualizovaný vzor carries 38 comments. Each comment lives
in `word/comments.xml`, anchored in `word/document.xml` by a
`commentRangeStart`/`commentRangeEnd` pair sharing a numeric `w:id`:

```xml
<!-- in word/document.xml -->
<w:p>
  <w:r><w:t>Analýza časových nároků</w:t></w:r>
  <w:commentRangeStart w:id="0"/>
  <w:r><w:t>č. 1</w:t></w:r>
  <w:commentRangeEnd w:id="0"/>
  <w:r><w:commentReference w:id="0"/></w:r>
</w:p>

<!-- in word/comments.xml -->
<w:comment w:id="0" w:author="VH" w:date="2024-09-30T12:00:00Z">
  <w:p><w:r><w:t>Nechat u delších staveb, kde je šance na vypracování více analýz</w:t></w:r></w:p>
</w:comment>
```

Detection:

1. Build `{id: comment_text}` from `word/comments.xml`.
2. For each `<w:commentRangeStart>` in the body, capture text between
   that element and its matching End within the same paragraph.
3. Emit `kind: "instruction"`, `source: "comment"`. The `description`
   is the comment text (the human's instruction); the `label` is the
   anchored span (what the comment is about); the `key` is a slug
   derived from the comment text (since that's what makes it unique).

If the anchored span is empty (some comments anchor to a single
position with no text between Start and End), the extractor falls
back to the paragraph text for the label.

## Why "instruction" is its own kind

Highlighted text often is not a simple value — it's a directive like
"DD.MM.RRRR" or "stručný popis Skutečností" telling a human what to
write. The schema preserves them so the agent sees the human's intent,
but flags `kind: "instruction"` so the human reviewer can promote each
to `text`/`enum`/`date` with a real key before final use.
