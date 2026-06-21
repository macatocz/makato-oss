# Markdown

Write well-structured markdown and validate it with prettier and markdownlint.

## Purpose

Markdown is easy to write badly. Inconsistent formatting, bare code fences, duplicate headings, and
bare URLs all pass silently until a linter catches them — or until a reader notices.

This skill enforces a two-tool chain: **prettier** fixes formatting, **markdownlint** checks
structure. Running them in the right order, with the right config, produces clean markdown that
renders correctly in GitHub, GitLab, VS Code, and any CommonMark-compliant renderer.

## When to Use

- Writing or editing any `.md` file
- Setting up markdown tooling in a new project
- Fixing markdownlint errors you don't recognise
- Ensuring markdown renders correctly before committing

### Trigger phrases

- "format this markdown"
- "fix the markdown"
- "markdownlint errors"
- "add a code fence language"
- "MD040", "MD024", "MD034" (lint rule codes)
- "create a README"

## How It Works

1. **Format** — run prettier to normalise whitespace, table alignment, list indentation, and prose
   wrapping
2. **Validate** — run markdownlint to catch structural issues prettier doesn't fix (missing code
   fence languages, duplicate headings, bare URLs)
3. **Fix** — address any remaining violations using the fix table in the skill

Always run prettier before markdownlint. Prettier may resolve issues lint would otherwise flag, and
may introduce new ones if run after.

## Key Features

### Two-Tool Chain

```bash
prettier --prose-wrap always --print-width 100 --write "**/*.md"
markdownlint --config .markdownlint.json "**/*.md"
```

### Baseline Config

The skill provides a `.markdownlint.json` baseline with documented rationale for every suppressed
rule. Each suppression is intentional — the config distinguishes stylistic rules (off by default)
from structural rules (always enforced).

MD040 (bare code fences) is never suppressed. Every fenced block gets a language tag.

### Code Fence Language Reference

| Content                             | Tag        |
| ----------------------------------- | ---------- |
| Shell commands                      | `bash`     |
| YAML                                | `yaml`     |
| JSON                                | `json`     |
| Markdown                            | `markdown` |
| Plain text, pseudo-code, multi-line | `text`     |
| Mermaid diagrams                    | `mermaid`  |

When in doubt, use `text`.

### Common Violation Fixes

| Violation                 | Fix                                          |
| ------------------------- | -------------------------------------------- |
| MD040 bare code fence     | Add language tag: ` ```text `                |
| MD034 bare URL in prose   | Wrap: `[description](url)`                   |
| MD024 duplicate heading   | Prefix with parent context                   |
| MD030 list marker spacing | Run prettier — it normalises automatically   |
| MD022 heading blank lines | Run prettier — it inserts them automatically |
| MD010 hard tabs           | Run prettier — it converts to spaces         |

## Prerequisites

Both tools must be installed:

```bash
# prettier
npm install -g prettier

# markdownlint-cli
npm install -g markdownlint-cli
```

Verify with:

```bash
prettier --version
markdownlint --version
```
