---
name: create-issue
description: >-
  File a structured issue against the makato repo with the correct template,
  [plugin-name] title prefix, and labels — file issue, report bug, feature
  request, AI agent issue, file bug, open issue
version: "1.4.0"
allowed-tools: [Bash, Python, Skill]
metadata:
  authors: [makato-core]
  last_updated: "2026-08-05"
---

# create-issue

Files a structured issue against the makato repo. Enforces title prefix, body template, and labels so the backlog stays self-organizing without manual triage. Fully autonomous — no confirmation prompts, no human gates.

**Mental model — this skill is a router, not a writer.** It does not decide what an issue should say; it enforces structural invariants (title prefix, body template, label taxonomy, provenance footer) so every downstream consumer (`issue-to-project`, `seed-issue`, `loop`) can process the issue without guessing field values. Apply documented defaults silently. Never prompt the user for optional fields.

**Escalation rule:** Abort only when `git rev-parse --show-toplevel` fails (Step 1) — no target repo can be resolved. WARN-and-continue for all post-creation failures: missing skill files, missing config keys, `gh` calls that fail after the issue number is captured.

## When to Use

- An AI agent needs to file a bug, feature request, or docs issue.
- A contributor wants the canonical template applied automatically.

## When NOT to Use

- Open-ended question or discussion — direct the user to GitHub Discussions.
- Filing a PR — use `.github/PULL_REQUEST_TEMPLATE.md`.

## Anti-patterns

**NEVER pass `--body` to `gh issue create` for multi-line content** — shell interpolation at `$()` boundaries and unmatched quotes silently truncate or corrupt markdown. Always write to a `mktemp` file and pass `--body-file`.

**NEVER omit `GH_HOST=github.com` from any `gh` call** — when the git remote points to an enterprise GitHub host (e.g. `github.mycompany.com`), the `gh` CLI resolves there by default, silently routing the issue to an instance where the project board, automation labels, and `seed-issue` hooks are absent.

**NEVER auto-create `bug`, `enhancement`, or `documentation` type labels** — these three are fixture labels with exact color codes expected by `issue-to-project` board-field queries. A near-duplicate (wrong color, mismatched casing, typo) creates a label the board query won't match, silently blocking Status promotion for every issue that inherits it. If a type label is missing from the repo, surface it to the user.

**NEVER infer `plan-tier:full` from body length or subjective complexity** — `plan-tier` is a dispatch-routing signal; an incorrect `full` tier forces a multi-phase planning run for a single-story task, unnecessarily blocking autonomous dispatch. Use only the keyword list from Step 5.5 (`architecture`, `migration`, `breaking`, `multi-phase`, `epic`, `multiple stories`).

**NEVER pass taxonomy labels to `gh issue create`** — pass only `type-label` and `plugin-label` at create time. Taxonomy labels (`type:feat`, `priority:p1`, `plan-tier:light`, etc.) must flow through `gh issue edit` in Step 7. Applying them at create risks a partial label set if the GitHub API commits the issue before the second mutation lands.

## Workflow

### Step 1: Detect target repo and project name

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "[create-issue] ERROR: not inside a git repository"; exit 1; }

REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
# Normalises both HTTPS (https://github.com/OWNER/REPO.git) and SSH (git@github.com:OWNER/REPO.git)
TARGET_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
```

Always set `GH_HOST=github.com` on all subsequent `gh` calls (see Anti-patterns).

Read project name from `.claude/config.json`; fall back to `"sagibeast"` silently — never prompt:

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

### Step 2: Gather inputs

If all inputs are provided by the calling agent, skip to Step 3 immediately.

When inputs are missing, use **AskUserQuestion** with selectable options — do not accept freeform prose for structured fields:

- **Type** — options: `bug`, `feature`, `docs`
- **Plugin scope** — options: `makato-core`, `makato-plan`, `makato-contribute`, `repo-wide`
- **Title subject** — short, imperative phrase, no prefix (freeform)
- **Body details** — content for the issue template sections (freeform)

### Step 3: Build the title

Format: `[<plugin-scope>] <type-segment>: <subject>`

Type segment: `bug` → `bug`, `feature` → `feat`, `docs` → `docs`.

Example: `[makato-plan] bug: grill crashes when glossary.md is empty`

### Step 4: Build the body

Read `.github/ISSUE_TEMPLATE/issue.md`, strip the YAML frontmatter, and fill each `<!-- placeholder -->` with the provided content. Keep all section headings — empty sections are fine.

### Step 5: Resolve labels

> **MANDATORY: Load @references/label-conventions.md now** — it contains plugin label color codes and the type-label fixture rule (do not auto-create type labels).
> **Do NOT load this reference before Step 5** — it is not needed for Steps 1–4.

Apply the matching type label (`bug`, `enhancement`, `documentation`) and plugin label (`plugin:<scope>`, omitted for `repo-wide`). Verify with `GH_HOST=github.com gh label list --repo "$TARGET_REPO"`. Create missing `plugin:*` labels using the colors in the reference. If a type label is absent from the repo, surface it to the user and do not proceed — never auto-create it.

Also derive the **taxonomy type label** from the type input — used by `issue-to-project` to populate the Type-label board field:

| Type input | GitHub label | Taxonomy label |
|---|---|---|
| `bug` | `bug` | `type:fix` |
| `feature` | `enhancement` | `type:feat` |
| `docs` | `documentation` | `type:docs` |

Store `TYPE_LABEL` (GitHub label), `PLUGIN_LABEL` (or empty for repo-wide), and `TYPE_TAXONOMY` (taxonomy label) as variables.

Initialize the label accumulator — this list will be used verbatim in `created-issues.json` at Step 8.5:

```bash
APPLIED_LABELS=("$TYPE_LABEL")
[[ -n "$PLUGIN_LABEL" ]] && APPLIED_LABELS+=("$PLUGIN_LABEL")
APPLIED_LABELS+=("$TYPE_TAXONOMY")
```

### Step 5.6: Infer priority and effort from body

Parse the issue body for explicit priority and effort hints (scan for keywords `priority:p0/p1/p2/p3` or `effort:xs/s/m/l/xl` in the body text, case-insensitive). When absent, apply defaults:

- **Priority** — default `priority:p1` (P1 is the standard backlog priority for new work)
- **Effort** — skip if not found in body (no default; leave for the developer to set)
- **Points** — skip if not found in body (no default; set by `seed-issue` / `makato-plan`)

When a priority or effort value is found or defaulted:

```bash
PRIORITY_LABEL="priority:${PRIORITY_VALUE}"   # e.g. priority:p1
APPLIED_LABELS+=("$PRIORITY_LABEL")
```

Create the label in the repo if absent (color `E4E669`, description `Issue priority`):

```bash
gh label create "$PRIORITY_LABEL" \
  --repo "$TARGET_REPO" \
  --color "E4E669" \
  --description "Issue priority" 2>/dev/null || true
```

If an effort was found in body (`effort:xs|s|m|l|xl`):

```bash
EFFORT_LABEL="effort:${EFFORT_VALUE}"
APPLIED_LABELS+=("$EFFORT_LABEL")
gh label create "$EFFORT_LABEL" \
  --repo "$TARGET_REPO" \
  --color "BFD4F2" \
  --description "Effort estimate" 2>/dev/null || true
```

Log resolved values: `[create-issue] taxonomy: priority=$PRIORITY_VALUE effort=${EFFORT_VALUE:-unset}`.

### Step 5.5: Infer and apply plan-tier label

Infer the plan tier in priority order (NEVER use body length as a signal — see Anti-patterns):

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

Store `PLAN_TIER` for use in Step 7 (batch taxonomy edit) and Steps 8.5/8.6.

Log `[create-issue] plan-tier: <tier>`.

### Step 6: Log assembled issue (no confirmation required)

Log the assembled title, body, and labels to stdout for audit purposes, then proceed directly to Step 7. Do not wait for user input.

### Step 7: File the issue

Write the body to a temp file and pass `--body-file` (NEVER `--body` — see Anti-patterns):

```bash
TMPFILE="$(mktemp /tmp/makato-issue-XXXXXX.md)"
cat > "$TMPFILE" << 'EOF'
<assembled body>
EOF

ISSUE_URL="$(GH_HOST=github.com gh issue create \
  --repo "$TARGET_REPO" \
  --title "<assembled title>" \
  --body-file "$TMPFILE" \
  --label "$TYPE_LABEL" \
  ${PLUGIN_LABEL:+--label "$PLUGIN_LABEL"})"
ISSUE_NUMBER="$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')"
```

Apply the `plan-tier:<tier>` label and all taxonomy labels accumulated in `APPLIED_LABELS` (excluding `type-label` and `plugin-label` already applied at create time) via a single `gh issue edit` call — NEVER split across multiple edit calls:

```bash
# Build --add-label flags: plan-tier + all taxonomy labels not already on the issue
EXTRA_LABELS=("plan-tier:$PLAN_TIER")
for lbl in "${APPLIED_LABELS[@]}"; do
  if [[ "$lbl" != "$TYPE_LABEL" && "$lbl" != "$PLUGIN_LABEL" ]]; then
    EXTRA_LABELS+=("$lbl")
  fi
done

LABEL_FLAGS=()
for lbl in "${EXTRA_LABELS[@]}"; do
  LABEL_FLAGS+=("--add-label" "$lbl")
done

GH_HOST=github.com gh issue edit "$ISSUE_NUMBER" \
  --repo "$TARGET_REPO" \
  "${LABEL_FLAGS[@]}"
```

After this step, append `plan-tier:$PLAN_TIER` to `APPLIED_LABELS` so Step 8.5 includes it:

```bash
APPLIED_LABELS+=("plan-tier:$PLAN_TIER")
```

### Step 8.5: Board placement via issue-to-project (conditional)

**Preconditions — WARN-and-continue if either fails:**

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
   Write `$REPO_ROOT/specs/$SPEC_SLUG/created-issues.json` using all labels accumulated in `APPLIED_LABELS` (includes type-label, plugin-label, type taxonomy, priority, effort if present, plan-tier):
   ```python
   import json, pathlib
   labels = APPLIED_LABELS  # full list built across Steps 5–7
   artifact = {
       "slug": SPEC_SLUG,
       "repo": TARGET_REPO,
       "issues": [
           {
               "number": ISSUE_NUMBER,
               "html_url": ISSUE_URL,
               "title": ISSUE_TITLE,
               "labels": labels,
           }
       ]
   }
   path = pathlib.Path(f"{REPO_ROOT}/specs/{SPEC_SLUG}/created-issues.json")
   path.write_text(json.dumps(artifact, indent=2) + "\n")
   ```
   This gives `issue-to-project` the full taxonomy signal set (priority, tier via type taxonomy, effort) to populate board fields — matching the output that `to-issues` produces from `stories.json`.

3. Invoke the skill:
   Use the Skill tool to invoke `/makato-plan:issue-to-project <SPEC_SLUG>`.

   If the Skill tool call fails for any reason, log `[create-issue] WARN: issue-to-project failed — issue filed but not yet on board` and continue. Never abort.

### Step 8.6: Seed via seed-issue (conditional)

**Precondition — WARN-and-continue if fails:**

```bash
SEED_SKILL="$REPO_ROOT/plugins/makato-orchestrate/skills/seed-issue/SKILL.md"
[[ -f "$SEED_SKILL" ]] || { echo "[create-issue] WARN: SKIP seed-issue — skill not found at $SEED_SKILL"; SEED_SKIP=1; }
```

**When precondition passes:**

Invoke the skill: Use the Skill tool to invoke `/makato-orchestrate:seed-issue <ISSUE_NUMBER>`.

`seed-issue` reads the `plan-tier:*` label already on the issue, classifies new-work vs change from `type:feature`/`type:change`, adds the provenance footer, stamps `status:ready-for-dev`, and moves the board card to `Status=Ready`. No `--type` flag needed.

If the Skill tool call fails, log `[create-issue] WARN: seed-issue failed — issue filed but not seeded for autonomous dispatch` and continue. Never abort.

### Step 9: Report

Print the issue URL and a summary of every step taken or skipped:

```
[create-issue] done:
  issue    : #<N> <URL>
  labels   : <all APPLIED_LABELS joined by ", ">
  board    : added via issue-to-project ✓  /  SKIP (<reason>)
  seeded   : status:ready-for-dev stamped via seed-issue ✓  /  SKIP (<reason>)
```

Clean up: `rm -f "$TMPFILE"`.
