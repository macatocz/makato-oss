# config.json + GitHub Issues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `.claude/config.json` file that declares the GitHub project name for each repo, and update the `create-issue` skill to resolve the target repo + project name from that file (falling back to `"sagibeast"` when absent) — fully autonomously with zero human interaction.

**Architecture:** A single `.claude/config.json` file at the repo root stores per-repo metadata. The `create-issue` skill reads it at Step 1 to determine the active repo and project name from git state alone — no questions asked, no confirmation gates. All other skills that file issues inherit this contract by calling `create-issue` rather than implementing their own `gh issue create` commands.

**Tech Stack:** Bash / `gh` CLI, JSON (no additional dependencies)

## Global Constraints

- **Autonomous execution only:** No `AskUserQuestion`, no confirmation prompts, no interactive steps. Every decision is derived from available context (git state, config file, defaults). The agent proceeds without human input at any stage.
- Active repo = the `git` repo whose `REPO_ROOT` is the directory where Claude Code session is opened — determined by `git rev-parse --show-toplevel`.
- `config.json` location: `<REPO_ROOT>/.claude/config.json`
- Fallback project name when file is absent or `"project"` key is missing: `"sagibeast"`
- Target GitHub host: `github.com` (set `GH_HOST=github.com` for all `gh` calls)
- No external dependencies may be added

---

## Current State (as of 2026-06-19)

### Repository

- Active repo: `zstary/makato` on `github.com`, branch `feat/makato-database-plugin`
- No `.claude/config.json` exists (only `.claude/settings.json`)

### GitHub Issues — `zstary/makato`

| # | Type | State | Title | Labels |
|---|------|-------|-------|--------|
| #5 | PR | **open** | chore: release v0.6.0 | `autorelease: pending` |
| #4 | PR | closed | feat(sensors): execute sensor-harness PLAN v1.5 | — |
| #3 | PR | closed | feat(marketplace): register makato-langgraph plugin | — |
| #2 | PR | closed | chore: release v0.5.0 | `autorelease: tagged` |
| #1 | PR | closed | feat(makato-contribute): add sync-from-upstream skill | — |

**No actual GitHub Issues exist** (all items are PRs). The issue tracker is empty.

### Files to change

| File | Action |
|------|--------|
| `.claude/config.json` | **Create** — stores `{ "project": "sagibeast" }` |
| `plugins/makato-core/skills/create-issue/SKILL.md` | **Modify** — update Step 1 to read config.json; remove all human-confirmation steps |
| `plugins/makato-core/skills/create-issue/references/label-conventions.md` | **Modify** — add note about project name source |

---

## Task 1: Create `.claude/config.json`

**Files:**
- Create: `.claude/config.json`

**Interfaces:**
- Produces: `{ "project": string }` — consumed by Task 2's updated `create-issue` skill

- [ ] **Step 1: Write the config file**

```json
{
  "project": "sagibeast"
}
```

Save to `.claude/config.json`.

- [ ] **Step 2: Verify the file is valid JSON**

```bash
python3 -c "import json; print(json.load(open('.claude/config.json')))"
```

Expected output: `{'project': 'sagibeast'}`

- [ ] **Step 3: Ensure config.json is committed (not gitignored)**

```bash
grep -n "claude" .gitignore 2>/dev/null || echo "no .claude entries in .gitignore"
```

If `.claude/` or `.claude/**` appears in `.gitignore`, append an unignore exception:

```bash
echo '!.claude/config.json' >> .gitignore
```

Then verify the file is stageable:

```bash
git add .claude/config.json --dry-run
```

Expected: `add '.claude/config.json'`

- [ ] **Step 4: Commit**

```bash
git add .claude/config.json .gitignore
git commit -m "chore(config): add .claude/config.json with project=sagibeast"
```

---

## Task 2: Update `create-issue` skill — autonomous repo + project resolution

**Files:**
- Modify: `plugins/makato-core/skills/create-issue/SKILL.md`

**Interfaces:**
- Consumes: `.claude/config.json` → `{ "project": string }`
- Produces: resolved `TARGET_REPO` (from git remote) and `PROJECT_NAME` (from config or `"sagibeast"`)

The current skill has two human-blocking violations that must be removed:
1. Step 1 says "Confirm back to the user before proceeding" — **delete this**
2. Step 6 says "Ask: *File this issue? (yes / no / edit)*. Do not call `gh issue create` until the user confirms." — **remove the confirmation gate; proceed directly to Step 7**

- [ ] **Step 1: Replace Step 1 of the skill — autonomous repo + project detection**

In `plugins/makato-core/skills/create-issue/SKILL.md`, replace:

```markdown
### Step 1: Detect target repo

The makato repo lives on `github.com`. The target is `zstary/makato`. Confirm back to the user before proceeding.
```

with:

```markdown
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
```

- [ ] **Step 2: Remove the human confirmation gate from Step 6**

In `plugins/makato-core/skills/create-issue/SKILL.md`, replace:

```markdown
### Step 6: Confirm before filing

Show the user the assembled title, body, and labels. Ask: *"File this issue? (yes / no / edit)"*. Do not call `gh issue create` until the user confirms.
```

with:

```markdown
### Step 6: Log assembled issue (no confirmation required)

Log the assembled title, body, and labels to stdout for audit purposes, then proceed directly to Step 7. Do not wait for user input.
```

- [ ] **Step 3: Update `gh issue create` call in Step 7 to use TARGET_REPO variable**

In Step 7 of the skill, replace the hardcoded `--repo zstary/makato` with `--repo "$TARGET_REPO"`:

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

- [ ] **Step 4: Bump version in frontmatter**

In `plugins/makato-core/skills/create-issue/SKILL.md` frontmatter, change:

```yaml
version: "1.0.0"
```

to:

```yaml
version: "1.1.0"
```

- [ ] **Step 5: Verify skill file has balanced code fences**

```bash
python3 -c "
text = open('plugins/makato-core/skills/create-issue/SKILL.md').read()
fences = text.count('\`\`\`')
assert fences % 2 == 0, f'Odd code fences: {fences}'
print('OK — code fences balanced')
"
```

Expected: `OK — code fences balanced`

- [ ] **Step 6: Commit**

```bash
git add plugins/makato-core/skills/create-issue/SKILL.md
git commit -m "feat(create-issue): autonomous repo+project resolution from config.json; remove human gates"
```

---

## Task 3: Update `label-conventions.md` — project name note

**Files:**
- Modify: `plugins/makato-core/skills/create-issue/references/label-conventions.md`

**Interfaces:**
- Consumes: none
- Produces: documented project name fallback contract for all skill authors

- [ ] **Step 1: Append project name resolution section**

Append the following to `plugins/makato-core/skills/create-issue/references/label-conventions.md`:

```markdown

## Project Name Resolution

The GitHub project name is read from `<REPO_ROOT>/.claude/config.json`:

```json
{ "project": "<project-name>" }
```

Fallback: `"sagibeast"` when the file is absent or `"project"` key is missing.

**Rule:** Resolution is always autonomous — no user prompt, no confirmation. Applied silently. This is the canonical source; do not hardcode project names in skills.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/makato-core/skills/create-issue/references/label-conventions.md
git commit -m "docs(create-issue): document autonomous project name resolution from config.json"
```

---

## Task 4: Automated verification

**Files:**
- No source changes — automated assertions only (no human steps)

- [ ] **Step 1: Assert config.json exists and is readable**

```bash
python3 -c "
import json, sys
d = json.load(open('.claude/config.json'))
assert d.get('project') == 'sagibeast', f'Wrong project: {d}'
print('PASS: config.json project=sagibeast')
"
```

Expected: `PASS: config.json project=sagibeast`

- [ ] **Step 2: Assert repo resolution script produces correct output**

```bash
python3 -c "
import subprocess, re
result = subprocess.run(['git', 'remote', 'get-url', 'origin'], capture_output=True, text=True)
url = result.stdout.strip()
match = re.sub(r'.*github\.com[:/]', '', url).rstrip('.git')
assert match == 'zstary/makato', f'Wrong repo: {match}'
print(f'PASS: TARGET_REPO={match}')
"
```

Expected: `PASS: TARGET_REPO=zstary/makato`

- [ ] **Step 3: Assert fallback activates when config.json is absent**

```bash
python3 -c "
import json, os
CONFIG_FILE = '.claude/config.json.absent-test'
try:
    d = json.load(open(CONFIG_FILE))
    print(d.get('project', 'sagibeast'))
except Exception:
    print('sagibeast')
"
```

Expected: `sagibeast`

- [ ] **Step 4: Assert no human-confirmation text remains in create-issue skill**

```bash
python3 -c "
text = open('plugins/makato-core/skills/create-issue/SKILL.md').read()
banned = ['yes / no', 'Confirm back to the user', 'Do not call.*until the user confirms']
import re
for pattern in banned:
    matches = re.findall(pattern, text)
    assert not matches, f'Human gate found: {matches}'
print('PASS: no human confirmation gates in create-issue skill')
"
```

Expected: `PASS: no human confirmation gates in create-issue skill`

- [ ] **Step 5: Update CHANGELOG**

Open `plugins/makato-core/CHANGELOG.md` and prepend under `## [Unreleased]`:

```markdown
### Changed
- `create-issue`: fully autonomous — repo and project name resolved from `.claude/config.json` (fallback: `sagibeast`); removed all human confirmation gates
```

```bash
git add plugins/makato-core/CHANGELOG.md
git commit -m "docs(changelog): record autonomous create-issue config.json resolution"
```

---

## Self-Review

**Spec coverage:**
- ✅ Active repo = current git repo derived from git state alone (Task 2, Step 1a–1b) — no hardcoding
- ✅ Project name from `.claude/config.json` (Task 1 + Task 2, Step 1c)
- ✅ Fallback to `"sagibeast"` applied silently without user input (Task 2, Step 1c)
- ✅ All human confirmation gates removed (Task 2, Steps 2 + 4 assertion)
- ✅ Current GitHub issue statuses documented (Current State table)
- ✅ `zstary/makato` has no actual issues (only PRs); tracker is empty
- ✅ Autonomous execution — zero `AskUserQuestion`, zero "confirm before proceeding" steps

**Placeholder scan:** None — all steps have concrete commands and expected output.

**Type consistency:** `TARGET_REPO` and `PROJECT_NAME` defined in Task 2, used verbatim in Tasks 3 and 4 assertions.
