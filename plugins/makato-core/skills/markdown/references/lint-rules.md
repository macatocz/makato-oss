# Markdownlint Rule Reference

## Most Common Violations and Fixes

### MD013 — Line length (default: 80, project: 150)

Lines over 150 chars fail. Safe patterns:
- Break long URLs: put on its own line or in a reference-style link
- Code blocks are exempt (`code_blocks: false`)
- Tables are exempt (`tables: false`)

```markdown
[Link text][ref]

[ref]: https://very-long-url.example.com/path/to/page
```

### MD022 — Headings should be surrounded by blank lines

```markdown
<\!-- BAD -->
## Heading
text immediately after

<\!-- GOOD -->
## Heading

text after blank line
```

### MD031 — Fenced code blocks need blank lines around them

```markdown
<\!-- BAD -->
text
```code
block
```
more text

<\!-- GOOD -->
text

```code
block
```

more text
```

### MD032 — Lists need blank lines before and after

```markdown
<\!-- BAD -->
Intro paragraph:
- item 1
- item 2
Next paragraph.

<\!-- GOOD -->
Intro paragraph:

- item 1
- item 2

Next paragraph.
```

### MD040 — Fenced code blocks need a language

```markdown
<\!-- BAD -->
```
code without language
```

<\!-- GOOD -->
```bash
code with language
```
```

### MD041 — First line must be H1

Every SKILL.md must have an H1 as the first non-frontmatter line.

### MD060 — Table column separators need spaces

```markdown
<\!-- BAD -->
|---|---|

<\!-- GOOD -->
| --- | --- |
```

## Configuration Examples

### Project .markdownlint.json

```json
{
  "default": true,
  "MD013": { "line_length": 150, "tables": false, "code_blocks": false },
  "MD024": { "allow_different_nesting": true },
  "MD028": false
}
```

### Per-file suppression (use sparingly)

```markdown
<\!-- markdownlint-disable MD013 -->
Very long line that cannot be broken without losing meaning.
<\!-- markdownlint-enable MD013 -->
```

### Inline suppression

```markdown
This line intentionally exceeds limits <\!-- markdownlint-disable-line MD013 -->
```

## Common Batch Fix Commands

```bash
# Check specific file
npx markdownlint-cli2 path/to/file.md

# Check with config
npx markdownlint-cli2 --config .markdownlint.json "**/*.md"
```
