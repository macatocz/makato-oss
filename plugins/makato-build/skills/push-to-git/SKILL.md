---
name: push-to-git
description: >-
  Create atomic conventional commits from the plan's task structure
  and push the feature branch to remote. One commit per logical task,
  individually bisectable. Confirms push before affecting remote.
  Use after verify, before create-pr.
version: "1.0.0"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/verify` (all gates pass) and before `/create-pr`. The code is clean, tested, and reviewed. This step produces a commit history that maps to the plan's task structure and pushes the branch to remote.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we pushing? (e.g. DCP-1234)"* — or use the passed argument.

Read `spec/<key>/plan.md`. Extract the task list — task titles and their file targets. This defines the commit grouping.

Run `git status` and `git branch --show-current`. Verify the current branch is NOT `main` or `master`. If on a protected branch, stop and tell the user:

> "Cannot commit directly to `<branch>`. Create a feature branch first."

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"push-to-git","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","tasks":<N>}}
```

---

### Step 3 — Verify there is something to commit

Run `git diff --stat HEAD` to confirm there are uncommitted changes. If the working tree is clean (nothing to commit), stop and tell the user — there is nothing to push.

Check for untracked files in source or test directories. Any untracked file that should be part of the implementation is a candidate — do not silently skip it. Report untracked source/test files to the user before proceeding.

---

### Step 4 — Plan commit grouping from task structure

Load `@references/commit-guide.md`.

Map each plan task to its changed files using the task's file targets from `plan.md` and the actual diff (`git diff --name-only HEAD`).

Grouping rules:
- All files that implement one task go in one commit
- Tests for a task go in the **same commit** as the production code for that task — they document the behavior of that code and belong together
- A file touched by multiple tasks goes in the commit for the task that primarily introduced the change
- Any changed file not attributable to a specific task goes in a final catch-all commit: `chore(<scope>): miscellaneous changes from <key>`

Present the planned grouping to the user:

```
Commit 1: feat(invoice): add status field to Invoice entity
          src/Invoice.java, src/InvoiceTest.java
Commit 2: feat(invoice): add InvoiceStatusService with transition logic
          src/InvoiceStatusService.java, src/InvoiceStatusServiceTest.java
```

Wait for the user to confirm or adjust the grouping before proceeding to Step 5.

---

### Step 5 — Create commits

For each planned commit in task order:
1. Stage exactly the files in that commit's group: `git add <file1> <file2> …` — never `git add -A` or `git add .`
2. Create the commit with the conventional message from the plan
3. Verify the commit landed: `git log -1 --oneline`

Do not amend existing commits. If a commit fails, report the error verbatim and stop — do not proceed to the next commit until the failure is resolved.

Log each commit:
```
{"ts":"<ISO8601>","skill":"push-to-git","story":"<key>","step":"commit","status":"ok","data":{"sha":"<short>","message":"<msg>","files":<N>}}
```

---

### Step 6 — Confirm push to remote

Show the user the commits that will be pushed:
```
git log main..HEAD --oneline
```

Ask: *"Ready to push `<N>` commits to `origin/<branch>`? This will trigger CI and be visible to the team."*

Wait for explicit confirmation. If the user declines, the commits are local — they can push manually when ready. Stop here without error.

---

### Step 7 — Push to remote

Run `git push -u origin HEAD`.

On success: record the remote branch name from the push output.

On failure (rejected, no upstream, auth error): report the exact git error verbatim. Do not retry automatically — a push rejection may indicate the remote has diverged and requires a human decision.

Log:
```
{"ts":"<ISO8601>","skill":"push-to-git","story":"<key>","step":"push","status":"ok"|"error","data":{"remote_branch":"<name>"}}
```

---

### Step 8 — Log session end and hand off

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"push-to-git","story":"<key>","step":"session","status":"ok","data":{"commits":<N>,"branch":"<name>"}}
```

Tell the user: *"`<N>` commits pushed to `<branch>`. Next: run `/create-pr`."*
