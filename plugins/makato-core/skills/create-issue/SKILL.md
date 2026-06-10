---
name: create-issue
description: File a structured issue against the makato repo with the correct template, [plugin-name] title prefix, and labels — file issue, report bug, feature request, AI agent issue, file bug, open issue
version: "1.0.0"
---

# create-issue

Files a structured issue against the makato repo. Enforces title prefix, body plan, and labels so the backlog stays self-organizing without manual triage.

## When to Use

- An AI agent needs to file a bug, feature request, or docs issue.
- A contributor wants the canonical template applied automatically.

## When NOT to Use

- Open-ended question or discussion — direct the user to GitHub Discussions.
- Filing a PR — use `.github/PULL_REQUEST_TEMPLATE.md`.

## Workflow

### Step 1: Detect target repo

The makato repo lives on `github.com`. The target is `zstary/makato`. Confirm back to the user before proceeding.

### Step 2: Gather inputs

Use `AskUserQuestion` for the fixed choices:

1. **Type** — `bug`, `feature`, `docs`
2. **Plugin scope** — `makato-core`, `makato-plan`, `makato-contribute`, `repo-wide`

Then collect free-form: **title subject** (short, imperative, no prefix) and **body details** for the template sections.

If the calling agent already has all of this, skip the questions and assemble directly.

### Step 3: Build the title

Format: `[<plugin-scope>] <type-segment>: <subject>`

Type segment maps from the user's type input: `bug` → `bug`, `feature` → `feat`, `docs` → `docs`.

Example: `[makato-plan] bug: grill crashes when glossary.md is empty`

### Step 4: Build the body

Read `.github/ISSUE_TEMPLATE/issue.md`, strip the YAML frontmatter, and fill each `<!-- placeholder -->` with the user's content. Keep all section headings — empty sections are fine.

### Step 5: Resolve labels

Load @references/label-conventions.md.

Apply the matching type label (`bug`, `enhancement`, `documentation`) and plugin label (`plugin:<scope>`, omitted for `repo-wide`). Verify with `gh label list`; create missing `plugin:*` labels using the colors in the reference.

### Step 6: Confirm before filing

Show the user the assembled title, body, and labels. Ask: *"File this issue? (yes / no / edit)"*. Do not call `gh issue create` until the user confirms.

### Step 7: File the issue

Write the body to a temp file and pass `--body-file` (not `--body` — multi-line markdown breaks shell quoting):

```bash
TMPFILE="$(mktemp /tmp/makato-issue-XXXXXX.md)"
cat > "$TMPFILE" << 'EOF'
<assembled body>
EOF

gh issue create \
  --repo zstary/makato \
  --title "<assembled title>" \
  --body-file "$TMPFILE" \
  --label "<type-label>" \
  --label "<plugin-label>"
```

Omit the second `--label` flag for `repo-wide`.

### Step 8: Report

Print the issue URL and labels applied. Clean up the temp file.
