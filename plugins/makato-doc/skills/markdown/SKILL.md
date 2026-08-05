---
name: markdown
description: >-
  Use when creating or editing .md files, fixing lint errors, setting up
  markdown tooling, or ensuring markdown renders correctly across GitHub, CI
  pipelines, and docs-as-code exporters (pandoc, MkDocs, GitBook). Triggers
  on: "markdown", ".md file", "format markdown", "markdownlint",
  "prettier markdown", "MD013", "MD040", "code fence", "lint error", "pre-commit
  hook", or any request to write, validate, or fix markdown structure.
  Do NOT use for non-markdown files, content quality review, or when the file
  already passes all lint checks.
version: "1.4.0"
allowed-tools: Bash(prettier *) Bash(markdownlint *) Bash(which *) Bash(git diff*) Bash(git log*) Read Grep
argument-hint: "[file or directory to format/validate]"
metadata:
  authors: [makato-doc]
  last_updated: "2026-08-05"
---

# Markdown

## Philosophy

Markdown's strength is portability: the same source renders in GitHub, docs sites, editors,
and CLI tools. That portability collapses when documents are formatted inconsistently —
a table that renders in one tool breaks another, a code fence without a language tag silently
fails syntax highlighting, and a document that renders locally may fail CI lint checks.

This skill applies two complementary tools in a fixed order: **prettier** handles formatting
(consistent spacing, wrapping, table alignment) and **markdownlint** handles structure
(code fence languages, heading hierarchy, list formatting). Prettier must run before lint
because prettier may reformat text that lint would flag differently — running lint first creates
false positives that disappear after formatting.

The expert judgment this skill encodes: MD040 (code fence language tags) is the one rule never
worth suppressing. An unlabeled fence hides whether content is code, prose, pseudo-code, or
output — a distinction that matters for any automated processing of the document. Suppressing
MD040 in config is an invitation to accumulate unlabeled fences that are impossible to classify
later.

## Mindset

**Scope determines blast radius.** Running `prettier --write "**/*.md"` on a large repo
reformats files the author didn't touch, creating a diff that obscures the actual change.
The "narrowest scope that satisfies the request" principle is not caution — it is precision.
A review-scoped fix (only changed files) makes the intent of the change auditable in PR review.

**Config amendment preserves project intent.** A project's `.markdownlint.json` encodes
deliberate decisions about which violations are acceptable for that specific project type.
Scraped docs, internal wikis, and generated references each have different suppression needs.
Overwriting destroys those decisions; amending preserves them.

**MD013 enforcement is inconsistent across renderers — CI is stricter than GitHub preview.**
GitHub's web UI wraps lines at the viewport width, so MD013 violations are invisible in
preview but fail CI. Always run markdownlint locally before pushing; a document that looks
clean in GitHub may still fail CI markdownlint checks.

**Front-matter YAML must have no trailing spaces on any line.** A trailing space after a
value (e.g. `title: My Title` followed by a space character) is valid YAML but some parsers
treat the trailing space as part of the string value, causing frontmatter extraction to fail
silently — the metadata is lost while the document renders normally, masking the error until
an automated pipeline reads it.

**The prettier→lint order is not arbitrary.** Prettier normalises whitespace, wraps prose,
and aligns tables. These transformations may introduce or resolve violations that markdownlint
would flag. Running lint before prettier produces false positives that disappear after
formatting — wasted effort and a confusing intermediate state.

Write well-structured markdown, then validate with the two-tool chain: **prettier**
(formatting) → **markdownlint** (structure).

Always run in that order. Prettier may fix what markdownlint would flag; running lint first
wastes effort.

**MANDATORY**: load [`references/lint-rules.md`](references/lint-rules.md) when diagnosing
specific markdownlint violations, fixing suppression annotations, or configuring
`.markdownlint.json` — it contains rule-by-rule fix patterns, configuration examples, and
batch fix commands.

**Do NOT load** `references/lint-rules.md` for general markdown writing tasks — only load
when actively fixing lint errors or configuring linting rules.

**MANDATORY**: load [`references/pre-commit-setup.md`](references/pre-commit-setup.md) when
wiring prettier and markdownlint into a pre-commit hook (lint-staged/husky, pre-commit
framework, or plain git hook) — it contains the correct hook ordering rationale, pitfalls
for each framework, xargs safety guards, and the CI-vs-local divergence pattern.

**Do NOT load** `references/pre-commit-setup.md` for routine formatting passes on existing
documents.

## Prerequisite Check

Before running either tool, verify both are available:

```bash
which prettier markdownlint
```

If either is missing, stop and report which tool is absent. Install with
`npm install -g prettier` or `npm install -g markdownlint-cli` as appropriate.
Do not proceed until both tools are confirmed present (HALT code: `TOOL_UNAVAILABLE`).

## Scope

Determine scope before running. Default to the narrowest scope that satisfies the request —
formatting files the user didn't touch creates unexpected diffs.

```text
Did the user name specific files or a directory? → specific
In a git repo + "format my changes" / pre-commit? → changed
In a git repo + "check my PR" / "validate branch"? → branch
"format everything" / first-time setup / not in a git repo? → full
```

If a git-scoped command returns no `.md` files, tell the user — don't silently fall through to full.

## Workflow

Pick the command block that matches the scope determined above.

Guard each git-scoped command against empty output before passing to xargs:

```bash
# Specific files
prettier --prose-wrap always --print-width 100 --write path/to/file.md
markdownlint --config .markdownlint.json path/to/file.md

# Changed files (unstaged + staged vs HEAD)
# Guard: if no .md files exist in diff, stop and notify — do not run xargs with empty input
CHANGED=$(git diff --name-only --diff-filter=AM HEAD | grep '\.md$' || true)
[ -z "$CHANGED" ] && echo "No changed .md files." && exit 0
echo "$CHANGED" | xargs prettier --prose-wrap always --print-width 100 --write
echo "$CHANGED" | xargs markdownlint --config .markdownlint.json

# Branch files (current branch vs main — substitute master or origin/HEAD if needed)
BRANCH=$(git diff --name-only --diff-filter=AM main...HEAD | grep '\.md$' || true)
[ -z "$BRANCH" ] && echo "No .md files in branch diff." && exit 0
echo "$BRANCH" | xargs prettier --prose-wrap always --print-width 100 --write
echo "$BRANCH" | xargs markdownlint --config .markdownlint.json

# Full scan
prettier --prose-wrap always --print-width 100 --write "**/*.md"
markdownlint --config .markdownlint.json "**/*.md"
```

If `.markdownlint.json` does not exist, create it first (see Config section). If it already exists,
amend it — never overwrite (see Existing Config section).

## Existing Config

**Always read `.markdownlint.json` before touching it.** The project may have intentional rules that
must be preserved.

```text
Does .markdownlint.json exist?
  NO  → create it using the baseline from the Config section
  YES → read it, then amend:
          for each rule in the baseline:
            rule already present → keep the existing value unchanged
            rule missing         → add it from the baseline
          show the user a diff of what will be added before writing
          (interactive mode) or apply silently (autonomous mode)
```

**Conflict resolution** — when an existing value differs from the baseline recommendation:

| Existing value | Baseline                                     | Action                                                                                           |
| -------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `MD013: 120`   | `MD013: false`                               | Keep existing — it's more specific, the project chose it deliberately                            |
| `MD024: false` | `MD024: { "allow_different_nesting": true }` | Flag to user: the baseline is more precise; suggest upgrading but do not change without approval |
| `MD040: false` | enforce (never suppress)                     | Flag as a problem: suppressing MD040 hides structural issues; recommend removing the suppression |

Never silently change a value the project has already set. Show the proposed amendment and get
confirmation before writing.

## Config

### `.markdownlint.json` — baseline for skill/doc repos

```json
{
  "default": true,
  "MD013": false,
  "MD024": { "allow_different_nesting": true },
  "MD026": false,
  "MD028": false,
  "MD029": false,
  "MD033": false,
  "MD036": false,
  "MD041": false,
  "MD051": false,
  "MD052": false
}
```

#### Why each suppression

| Rule  | Reason to suppress                                                                                                                                                      |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MD013 | Prettier handles wrapping; table cells can't be split and always exceed 80 chars                                                                                        |
| MD024 | Same heading name under different parent sections is valid (e.g. `### Syntax` in each of three diagram sections) — use `allow_different_nesting: true` not full disable |
| MD026 | Strunk-style reference docs use punctuated headings by convention                                                                                                       |
| MD028 | Blank lines inside blockquotes appear in scraped/source documents                                                                                                       |
| MD029 | Intentional continuation lists (numbered lists that resume from a prior list)                                                                                           |
| MD033 | Inline HTML appears in scraped research documents and academic references                                                                                               |
| MD036 | `**Bold**` used as informal section labels in scraped/source documents                                                                                                  |
| MD041 | Reference files are fragments, not standalone documents; H1 is in the parent                                                                                            |
| MD051 | Fragment links in scraped documents reference headings present in the original source                                                                                   |
| MD052 | Reference-style link labels in scraped documents may not resolve locally                                                                                                |

Do not suppress MD040. Always add a language tag — see Code Fences below.

## Code Fences

Every fenced code block must have a language. No bare ` ``` `.

When the content does not fit a named language, use `text`. Never leave the tag blank.

Common mappings: `bash` (shell), `yaml`, `json`, `markdown`, `text` (plain text /
pseudo-code / multi-line prose), `mermaid`, `sql`, `go`, `python`, `js` / `ts`.

## When to Use

| When to use | When NOT to use |
| ----------- | --------------- |
| Creating or editing any `.md` file | Editing non-markdown files — use language-specific linters |
| Fixing markdownlint or prettier errors | Reviewing content quality — this covers formatting only |
| Setting up markdown tooling for a new repo | File already passes all lint checks — no action needed |
| Configuring pre-commit hooks for markdown | — |

**Entry decision tree:**

1. What is the scope? Single file, branch diff, or full repo? (See Scope section.)
2. Does `.markdownlint.json` or `.prettierrc` exist? → Use existing config. Missing → create from templates.
3. Do you want to suppress a rule? → Check `## Suppressing a Rule` section first.
4. Setting up a pre-commit hook? → Load `references/pre-commit-setup.md` (MANDATORY).

**Reference:** `references/lint-rules.md` — **MANDATORY** when adding new suppression rules or
troubleshooting unfamiliar violations. **Do NOT load** for routine formatting passes.

## Anti-patterns

- **NEVER overwrite `.markdownlint.json`** without reading it first and amending only missing
  rules. WHY: every project accumulates intentional suppressions for generated content,
  scraped docs, and legacy decisions; silent overwrite destroys those decisions and forces
  the team to reconstruct them from scratch.

- **NEVER run markdownlint before prettier** in any tool sequence (interactive, autonomous,
  or pre-commit hooks). WHY: prettier normalises whitespace, wraps prose, and realigns table
  columns — these transformations change line content that markdownlint has already validated.
  Running lint first means validating content that the formatter will immediately rewrite,
  producing false positives that disappear after formatting and hard-to-reproduce CI failures.
  The correct order is always: prettier → markdownlint.

- **NEVER leave a bare ` ``` ` fence** without a language tag. WHY: MD040 exists because an
  unlabeled fence is structurally ambiguous — no automated tool can determine whether the
  content is code, shell output, pseudo-code, or prose. This ambiguity is permanent once
  committed; suppressing MD040 in config multiplies it across the entire codebase.

- **NEVER fully disable MD024** — use `allow_different_nesting: true` instead. WHY: full
  disable hides true duplicate headings at the same level (a navigation bug) while the nesting
  variant only permits same-name headings under different parent sections, which is valid and
  common in structured docs.

- **NEVER suppress MD040 in config**. WHY: adding `"MD040": false` silences all unlabeled
  fences repo-wide with no indication of which are intentional. Each individual case must be
  evaluated and tagged — `text` is a valid tag for content that has no named language.

- **NEVER use prettier's `--prose-wrap preserve`** for new files. WHY: it produces inconsistent
  line lengths that differ between editors and cannot be round-tripped; two contributors editing
  the same file with different editor widths produce diverging line breaks on every save.
  Use `--prose-wrap always` with `--print-width 100`.

- **NEVER suppress MD013 (line-length) for content prose** via config. WHY: the 100-character
  limit is a proxy for rendering width in PDF export and side-by-side diff views; GitHub's
  renderer wraps at viewport width making violations invisible there, but pandoc and most PDF
  exporters treat hard line breaks as paragraph breaks — a 100-character line in source becomes
  a visually cut sentence in exported docs. Use prettier's wrapping instead.

- **NEVER place HTML comments `<!-- -->` inside markdown table cells**. WHY: markdown table
  parsing is line-based and processes pipe characters before HTML parsing; comment tokens
  inside a cell are not consumed by the HTML tokenizer before the table parser splits the row,
  so the comment markers render as visible literal text in HTML and PDF output.

- **NEVER add inline suppression comments without a reason comment**. WHY: `<!-- markdownlint-disable MD013 -->`
  without explanation is undocumented technical debt — six months later it looks like a bug,
  gets removed by a cleanup, and re-introduces the violation. The comment explaining why it
  exists is the only defence against this cycle.

- **NEVER assume a markdown file is valid because it renders in GitHub**. WHY: GitHub's
  renderer applies implicit fixes (closes unclosed tags, normalises whitespace) that downstream
  tools such as MkDocs and GitBook do not. Rendering success in GitHub creates false confidence
  that CI will also pass.

- **NEVER mix tab and space indentation in nested lists**. WHY: CommonMark defines tab as
  equivalent to 4 spaces only in certain continuation-paragraph contexts; this rule is
  implemented differently across all major renderers, so a file that renders as nested lists
  in one processor renders as flat lists in another.

- **NEVER pass an empty file list to xargs** without a guard. WHY: on some platforms
  `xargs prettier` with no stdin input runs prettier with no arguments, which may format all
  files in the current directory — a full-repo blast-radius violation. Always guard with
  `[ -z "$FILES" ] && exit 0` before the xargs call.

## Fixing Common Violations

| Violation                 | Fix                                                |
| ------------------------- | -------------------------------------------------- |
| MD040 bare code fence     | Add language tag: ` ```text `                      |
| MD034 bare URL in prose   | Wrap: `[description](url)`                         |
| MD024 duplicate heading   | Prefix with parent context                         |
| MD030 list marker spacing | Run prettier — it normalises automatically         |
| MD022 heading blank lines | Run prettier — it inserts them automatically       |
| MD010 hard tabs           | Run prettier — it converts to spaces automatically |

## Suppressing a Rule

**NEVER suppress a rule without explicit user confirmation.** Before adding any rule to
`.markdownlint.json`, present the user with all three of the following using a selectable
prompt (use AskUserQuestion with options):

1. **Rule description** — what the rule enforces and why it exists
2. **Current violation** — the exact line(s) triggering it, quoted verbatim
3. **Compliant alternative** — how the content would need to be rewritten to pass without
   suppression

Present two options: **A) Suppress the rule** / **B) Fix the content**. Wait for selection
before proceeding.

Example AskUserQuestion prompt:

```text
MD033 prohibits inline HTML (keeps markdown portable across renderers that strip raw HTML).

Violation at line 42:
  <br/>

To fix without suppressing:
  Use two trailing spaces or a blank line to create a line break instead.

Options:
  A) Suppress MD033 in .markdownlint.json
  B) Fix the content (replace <br/> with blank line)
```

Only add the suppression after the user explicitly selects A. If they select B,
make the edit and re-run markdownlint before proceeding.

**Autonomous mode exception:** In autonomous mode, never suppress rules at all.
Fix the content to comply. If fixing would require semantic changes beyond formatting,
HALT with `AMBIGUOUS_TARGET` including the rule ID and violating line.

## Autonomous Execution

This skill supports dual-mode execution.

### Mode Detection

Autonomous mode activates when ANY of:

- `agent_id` is present in session context
- Caller passes context bundle with `task_id` field

### Autonomous Behavior

In autonomous mode:

1. **Never ask for confirmation** — apply prettier + markdownlint fixes silently
2. **Never suppress rules** — fix content to comply; HALT if fix requires semantic changes
3. **Scope from context:** use context bundle `files` array or fall back to git-changed `.md` files
4. **Create `.markdownlint.json`** if missing using baseline config (no user prompt)
5. **Return R1 JSON** on completion

### R1 Return Format

```json
{
  "status": "COMPLETED",
  "summary": "Formatted 3 files, fixed 7 lint violations",
  "artifacts": ["docs/README.md", "docs/setup.md", "CHANGELOG.md"],
  "task_id": "...",
  "files_formatted": 3,
  "violations_fixed": 7,
  "violations_remaining": 0
}
```

### HALT Codes

| Code | Meaning |
| ------ | ------- |
| `MISSING_CONTEXT` | No `.md` files in scope (no args, no git changes, no context bundle files) |
| `AMBIGUOUS_TARGET` | Lint violation requires semantic change (not just formatting) |
| `TOOL_UNAVAILABLE` | prettier or markdownlint not installed |
