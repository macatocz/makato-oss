---
name: create-pr
description: >-
  Generate a pull request from the pushed feature branch. Drafts
  the PR description from spec artifacts — acceptance criteria map
  to How to Test, design decisions surface in the description. Presents draft for user approval before opening.
  Interactive. Use after push-to-git, before address-pr-comments.
version: "1.0.1"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/push-to-git` (branch is on remote) and before `/address-pr-comments`. The code is committed and pushed. This step generates a PR description from spec artifacts and opens the pull request for human review.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we creating a PR for? (e.g. DCP-1234)"* — or use the passed argument. A work item key is optional; if none is provided, the PR can still be created without an issue link.

Verify the branch is pushed: run `git status -sb` and check that the upstream tracking branch exists and no local commits are ahead of it. If commits are ahead of remote, stop and tell the user:

> "Branch has unpushed commits. Run `/push-to-git` first."

Read:
- `spec/<key>/stories.json` — acceptance criteria for this work item (if key was provided and file exists)
- `spec/<key>/prd.md` — goals, scope, motivation (if exists)
- `spec/<key>/plan.md` — completed tasks, for "What changed" bullets (if exists)
- `.github/PULL_REQUEST_TEMPLATE.md` — the project's required PR template

Run `git log main..HEAD --oneline` to see the commits included in this PR.

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl` (only if a key was provided):
```
{"ts":"<ISO8601>","skill":"create-pr","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","commits":<N>}}
```

---

### Step 3 — Draft the PR description

Load `@references/pr-description-guide.md`. Use `.github/PULL_REQUEST_TEMPLATE.md` (already read in Step 1) as the body structure — populate each of its sections from spec artifacts. This ensures the produced PR matches the template enforced by the project rather than a free-form body.

**PR title**: `feat: <story title>` — title from `stories.json` or `plan.md`; if no spec, derive from commit messages. Append ` (DCP-1234)` or ` (#42)` when a work item key is available. The full title must fit on one line in GitHub's PR list view: keep it under 72 characters total. Truncate or rephrase the story title if needed; never truncate the issue reference.

Fill each template section as follows:

**Description of Changes > What changed**: one bullet per plan task — task title + one sentence on what was changed. If no `plan.md` exists, derive from commit messages.

**Goal Alignment**: plugin name, goal statement (read `AGENTS.md` in the target repo), one sentence connecting this story to the goal.

**Links**: see Step 6 for issue tracker handling.

**How to Test**: one numbered step per acceptance criterion from `stories.json` — make each concrete (name the command, the input, the expected output). If no `stories.json` exists, write steps derived from the commit messages and changed code.

**Breaking Changes**: check the diff for changes to public APIs, database schemas, or shared contracts. Check `Yes` if any are found and describe the migration path.

**AI-assisted**: pre-check "Code implementation", "Commit messages", "PR description".

**PR Checklist**: pre-check all items that are verifiably true (conventional commit title ✓, CHANGELOG updated ✓, self-contained skills ✓, version bumped if behavior changed).

**Additional Changelog Entries**: leave empty — this is a single-story PR.

---

### Step 4 — Present draft for user review

Present the complete draft PR (title + full description body) to the user.

Ask: *"Does this PR description look correct? Reply with any edits, or 'approved' to open the PR."*

Apply any edits the user requests. Re-present if edits are substantial. Do not open the PR until the user gives explicit approval.

---

### Step 5 — Create the pull request

Run:
```
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

Base branch: `main`. If the project uses a different default base (e.g. `develop`), check `gh repo view --json defaultBranchRef` or ask the user before creating.

On failure: report the exact `gh` error verbatim. Common causes: not authenticated (`gh auth login`), no remote set, title too long. Do not retry silently.

On success: capture the PR URL from the output.

---

### Step 6 — Link PR to issue tracker (optional)

This step depends on what tracking context is available. Do not block or ask the user if no reference was provided.

**Case 1 — GitHub issue reference provided (e.g. GH#42):**
Add `Closes #42` (or `Fixes #42`) to the PR body's Links section *before* calling `gh pr create` in Step 5. GitHub auto-closes the issue on merge. No separate API call needed.

**Case 2 — No issue reference provided:**
Skip linking entirely. Do not ask the user to supply one. Log `"issue_linked": false` and proceed.

---

### Step 7 — Log session end and hand off

Append to `spec/<key>/build.jsonl` (only if a key was provided):
```
{"ts":"<ISO8601>","skill":"create-pr","story":"<key>","step":"session","status":"ok","data":{"pr_url":"<url>","issue_linked":true|false,"issue_type":"github"|"none"}}
```

Tell the user: *"PR open: `<URL>`. Next: wait for review, then use `/address-pr-comments` to handle feedback."*
