---
name: create-issue
description: File a structured issue against the makato repo with the correct template, [plugin-name] title prefix, and labels — file issue, report bug, feature request, AI agent issue, file bug, open issue
version: "1.1.0"
---

# create-issue

Files a structured issue against the makato repo. Enforces title prefix, body plan, and labels so the backlog stays self-organizing without manual triage. Fully autonomous — no confirmation prompts, no human gates.

## When to Use

- An AI agent needs to file a bug, feature request, or docs issue.
- A contributor wants the canonical template applied automatically.

## When NOT to Use

- Open-ended question or discussion — direct the user to GitHub Discussions.
- Filing a PR — use `.github/PULL_REQUEST_TEMPLATE.md`.

## Workflow

### Step 1: Detect target repo and project name

**1a. Locate the active repo root:**
```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```
If this fails (not a git repo), abort with an error log: "Cannot file issue — not inside a git repository." Do not prompt the user.

**1b. Determine the GitHub remote:**
```bash
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
TARGET_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
```
This resolves both HTTPS (`https://github.com/OWNER/REPO.git`) and SSH (`git@github.com:OWNER/REPO.git`) formats. Always set `GH_HOST=github.com` for all subsequent `gh` calls.

**1c. Read project name from config — no prompt, apply default silently:**
```bash
CONFIG_FILE="$REPO_ROOT/.claude/config.json"
PROJECT_NAME="$(python3 -c "
import json, sys
try:
    d = json.load(open('$CONFIG_FILE'))
    print(d.get('project', 'sagibeast'))
except Exception:
    print('sagibeast')
" 2>/dev/null)"
```
Fallback is `"sagibeast"` — applied silently without asking the user.

### Step 2: Gather inputs

If all inputs are provided by the calling agent, skip to Step 3 immediately.

Required inputs:
1. **Type** — `bug`, `feature`, `docs`
2. **Plugin scope** — `makato-core`, `makato-plan`, `makato-contribute`, `repo-wide`
3. **Title subject** — short, imperative, no prefix
4. **Body details** — content for the issue template sections

### Step 3: Build the title

Format: `[<plugin-scope>] <type-segment>: <subject>`

Type segment maps from the type input: `bug` → `bug`, `feature` → `feat`, `docs` → `docs`.

Example: `[makato-plan] bug: grill crashes when glossary.md is empty`

### Step 4: Build the body

Read `.github/ISSUE_TEMPLATE/issue.md`, strip the YAML frontmatter, and fill each `<!-- placeholder -->` with the provided content. Keep all section headings — empty sections are fine.

### Step 5: Resolve labels

Load @references/label-conventions.md.

Apply the matching type label (`bug`, `enhancement`, `documentation`) and plugin label (`plugin:<scope>`, omitted for `repo-wide`). Verify with `GH_HOST=github.com gh label list --repo "$TARGET_REPO"`; create missing `plugin:*` labels using the colors in the reference.

### Step 6: Log assembled issue (no confirmation required)

Log the assembled title, body, and labels to stdout for audit purposes, then proceed directly to Step 7. Do not wait for user input.

### Step 7: File the issue

Write the body to a temp file and pass `--body-file` (not `--body` — multi-line markdown breaks shell quoting):

```bash
TMPFILE="$(mktemp /tmp/makato-issue-XXXXXX.md)"
cat > "$TMPFILE" << 'EOF'
<assembled body>
EOF

GH_HOST=github.com gh issue create \
  --repo "$TARGET_REPO" \
  --title "<assembled title>" \
  --body-file "$TMPFILE" \
  --label "<type-label>" \
  --label "<plugin-label>"
```

Omit the second `--label` flag for `repo-wide`.

### Step 8: Report

Print the issue URL and labels applied. Clean up the temp file.
