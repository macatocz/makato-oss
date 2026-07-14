---
name: create-issue
description: File a structured issue against the makato repo with the correct template, [plugin-name] title prefix, and labels — file issue, report bug, feature request, AI agent issue, file bug, open issue
version: "1.2.0"
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

### Step 5.5: Infer and apply plan-tier label

Infer the plan tier in priority order:

1. `type=bug` → `plan-tier:change`
2. `type=feature` or `type=docs`, and the body contains any of: `architecture`, `migration`, `breaking`, `multi-phase`, `epic`, `multiple stories` → `plan-tier:full`
3. All other `feature`/`docs` → `plan-tier:light`

Create the label if it does not exist in the repo (color `FBCA04`, description `Plan tier for autonomous dispatch`):

```bash
gh label create "plan-tier:<tier>" \
  --repo "$TARGET_REPO" \
  --color "FBCA04" \
  --description "Plan tier for autonomous dispatch" 2>/dev/null || true
```

Apply the label to the issue immediately after it is filed (Step 7) — store `PLAN_TIER` for use in Steps 8.5 and 8.6:

```bash
GH_HOST=github.com gh issue edit "$ISSUE_NUMBER" \
  --repo "$TARGET_REPO" \
  --add-label "plan-tier:$PLAN_TIER"
```

Log `[create-issue] plan-tier: <tier>`.

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

Capture the issue number and URL from the `gh` output for use in later steps:

```bash
ISSUE_URL="$(GH_HOST=github.com gh issue create ...)"  # gh prints the URL to stdout
ISSUE_NUMBER="$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')"
```

Apply the `plan-tier:<tier>` label (resolved in Step 5.5):

```bash
GH_HOST=github.com gh issue edit "$ISSUE_NUMBER" \
  --repo "$TARGET_REPO" \
  --add-label "plan-tier:$PLAN_TIER"
```

### Step 8.5: Board placement via issue-to-project (conditional)

**Preconditions — skip with WARN if either fails:**

```bash
ITP_SKILL="$REPO_ROOT/plugins/makato-plan/skills/issue-to-project/SKILL.md"
[[ -f "$ITP_SKILL" ]] || { echo "[create-issue] WARN: SKIP issue-to-project — skill not found at $ITP_SKILL"; ITP_SKIP=1; }
python3 -c "import json; json.load(open('$REPO_ROOT/.claude/config.json'))['github_project']" 2>/dev/null \
  || { echo "[create-issue] WARN: SKIP issue-to-project — github_project not configured in .claude/config.json"; ITP_SKIP=1; }
```

**When both preconditions pass:**

1. Derive slug (mirrors seed-issue Step 4 algorithm):
   ```bash
   SLUG="$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' \
     | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//' \
     | cut -c1-40 | sed 's/-$//')"
   SPEC_SLUG="${ISSUE_NUMBER}-${SLUG}"
   ```

2. Create spec folder and write a minimal `created-issues.json`:
   ```bash
   mkdir -p "$REPO_ROOT/specs/$SPEC_SLUG"
   ```
   Write `$REPO_ROOT/specs/$SPEC_SLUG/created-issues.json`:
   ```json
   {
     "slug": "<SPEC_SLUG>",
     "repo": "<TARGET_REPO>",
     "issues": [
       {
         "number": <ISSUE_NUMBER>,
         "html_url": "<ISSUE_URL>",
         "title": "<ISSUE_TITLE>",
         "labels": ["<type-label>", "<plugin-label-or-omit>", "plan-tier:<PLAN_TIER>"]
       }
     ]
   }
   ```
   Omit the plugin label entry for `repo-wide` issues (no plugin label on the issue).

3. Invoke the skill:
   Use the Skill tool to invoke `/makato-plan:issue-to-project <SPEC_SLUG>`.

   If the Skill tool call fails for any reason, log `[create-issue] WARN: issue-to-project failed — issue filed but not yet on board` and continue. Never abort.

### Step 8.6: Seed via seed-issue (conditional)

**Precondition — skip with WARN if fails:**

```bash
SEED_SKILL="$REPO_ROOT/plugins/makato-orchestrate/skills/seed-issue/SKILL.md"
[[ -f "$SEED_SKILL" ]] || { echo "[create-issue] WARN: SKIP seed-issue — skill not found at $SEED_SKILL"; SEED_SKIP=1; }
```

**When precondition passes:**

Invoke the skill:
Use the Skill tool to invoke `/makato-orchestrate:seed-issue <ISSUE_NUMBER>`.

seed-issue reads the `plan-tier:*` label already on the issue, classifies new-work vs change from `type:feature`/`type:change`, adds the provenance footer, stamps `status:ready-for-dev`, and moves the board card to `Status=Ready`. No `--type` flag needed.

If the Skill tool call fails, log `[create-issue] WARN: seed-issue failed — issue filed but not seeded for autonomous dispatch` and continue. Never abort.

### Step 9: Report

Print the issue URL and a summary of every step taken or skipped:

```
[create-issue] done:
  issue    : #<N> <URL>
  labels   : <type-label>, <plugin-label>, plan-tier:<tier>
  board    : added via issue-to-project ✓  /  SKIP (<reason>)
  seeded   : status:ready-for-dev stamped via seed-issue ✓  /  SKIP (<reason>)
```

Clean up the temp file.
