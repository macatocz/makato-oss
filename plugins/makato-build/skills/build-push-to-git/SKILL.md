---
name: build-push-to-git
description: >-
  Create atomic conventional commits from the plan's task structure
  and push the feature branch to remote. One commit per logical task,
  individually bisectable. Confirms push before affecting remote.
  Use after verify, before create-pr.
version: "1.5.0"
argument-hint: "[work-item-key] [--autonomous]"
---

## When to Use

Use after `/verify` (all gates pass) and before `/create-pr`. The code is clean, tested, and reviewed. This step produces a commit history that maps to the plan's task structure and pushes the branch to remote.

## Input

When dispatched by the PO-agent (`--autonomous` mode):

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). All `git` invocations below run with `git -C "$WORKTREE_PATH"` (or after `cd "$WORKTREE_PATH"`) so the commit lands on the worktree's branch and `git push` targets the right ref. Pushing from the main checkout would push the wrong branch — a contract violation.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1's `git status`. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` — every `git`/`gh` command below runs from this CWD.

**Spec-artefact reads use `REPO_ROOT`, not `WORKTREE_PATH`.** `specs/<key>-*/` is gitignored at the repo root and exists only on the main checkout — a fresh `git worktree add` produces a worktree with NO `specs/` content. Resolve `REPO_ROOT` once at entry alongside the worktree:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

Reading `plan.md` in Step 1 below means `$REPO_ROOT/specs/<key>-*/plan.md`, never `$WORKTREE_PATH/specs/...`. See `AUTONOMOUS-MODE.md` § *Two roots, one contract* for the full rationale.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we pushing? (e.g. DCP-1234, or pass it directly: `/daff-build:build-push-to-git DCP-1234`)"* — or use the passed argument.

Read `plan.md` from the resolved spec folder under `$REPO_ROOT` (`$REPO_ROOT/specs/<key>-*/plan.md`, NOT under `$WORKTREE_PATH`). Extract the task list — task titles and their file targets. This defines the commit grouping.

Run `git status` and `git branch --show-current`. Verify the current branch is NOT `main` or `master`. If on a protected branch, stop and tell the user:

> "Cannot commit directly to `<branch>`. Create a feature branch first."

### Step 1a — Mode detection

Load `@../../AUTONOMOUS-MODE.md` for the activation contract (§ *Activation triggers*) and the per-gate default table. The skill runs in `--interactive` mode by default; autonomous mode opts in per dispatch.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
- If an argument was passed: use it.
- If no argument: HALT with `MISSING_INPUT: build-push-to-git in --autonomous mode requires a work-item-key argument`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-push-to-git","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"work-item-key","bypassed":true,"default_taken":"use-arg","trigger":"<agent_id|cli_flag|task_id_bundle>"}}'` when bypassed.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","tasks":<N>}}'
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

**Commit message drafts**: use the `commitMessage` field from each task in `plan.md` as the proposed commit message. Present it alongside the file grouping for user confirmation.

Present the planned grouping with proposed messages to the user:

```
Commit 1: feat(invoice): add status field to Invoice entity
          src/Invoice.java, src/InvoiceTest.java
Commit 2: feat(invoice): add InvoiceStatusService with transition logic
          src/InvoiceStatusService.java, src/InvoiceStatusServiceTest.java
```

In **interactive mode**, wait for the user to confirm or adjust the grouping and commit messages before proceeding to Step 5.

In **autonomous mode**, skip the confirmation: use each task's `commitMessage` field from `plan.md` verbatim, apply the grouping rules above, log `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-push-to-git","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"commit-grouping","bypassed":true,"default_taken":"plan-as-drafted","trigger":"<agent_id|cli_flag|task_id_bundle>"}}'`, and proceed to Step 5.

---

### Step 5 — Create commits

For each planned commit in task order:
1. Stage exactly the files in that commit's group: `git add <file1> <file2> …` — never `git add -A` or `git add .`
2. Create the commit with the conventional message from the plan
3. Verify the commit landed: `git log -1 --oneline`

Do not amend existing commits. If a commit fails, report the error verbatim and stop — do not proceed to the next commit until the failure is resolved.

Log each commit:
```
{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"commit","status":"ok","data":{"sha":"<short>","message":"<msg>","files":<N>}}
```

---

### Step 6 — Confirm push to remote

Show the user the commits that will be pushed (resolve the integration target via `shared/default-branch.sh` so a stale local `main` does not include commits from already-merged PRs — #98):
```
DEFAULT_REF="$(shared/default-branch.sh)"
git fetch origin --quiet
git log "$DEFAULT_REF..HEAD" --oneline
```

In **interactive mode**, ask: *"Ready to push `<N>` commits to `origin/<branch>`? This will trigger CI and be visible to the team."* Wait for explicit confirmation. If the user declines, the commits are local — they can push manually when ready. Stop here without error.

In **autonomous mode**, skip the prompt: proceed directly to Step 7 (the pre-push hook still fires — autonomous mode does not bypass git hooks). Log `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-push-to-git","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"push-confirm","bypassed":true,"default_taken":"push","trigger":"<agent_id|cli_flag|task_id_bundle>"}}'`.

---

### Step 7 — Push to remote

Run `git push -u origin HEAD`.

On success: record the remote branch name from the push output.

On failure (rejected, no upstream, auth error): report the exact git error verbatim. Do not retry automatically — a push rejection may indicate the remote has diverged and requires a human decision.

Log:
```
{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"push","status":"ok"|"error","data":{"remote_branch":"<name>"}}
```

---

### Step 8 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"session","status":"ok","data":{"commits":<N>,"branch":"<name>"}}'
```

Tell the user: *"`<N>` commits pushed to `<branch>`."*

In **interactive mode**, then ask using `AskUserQuestion`:
- Question: "Branch is on remote. Create the pull request now?"
- Option A: **Yes, create PR now** — description: "Draft and open the PR using `/build-create-pr` — generates description from spec artifacts"
- Option B: **No, I'll do it later** — description: "Run `/build-create-pr <key>` manually when ready"

If option A: invoke `/build-create-pr <key>` directly.
If option B: tell the user: "Run `/makato-build:build-create-pr <key>` when ready."

In **autonomous mode**, skip the prompt: invoke `/build-create-pr <key> --autonomous` directly (the `--autonomous` flag MUST be forwarded explicitly per the cross-skill propagation rule in `@../../AUTONOMOUS-MODE.md`). The downstream context bundle MUST also carry the `WORKTREE_PATH` field verbatim from this skill's input — `build-create-pr` runs its own entry-guard falsy-check and HALTs `MISSING_INPUT` if the field is absent in autonomous mode. The hand-off prompt that dispatches `/build-create-pr` therefore includes both `--autonomous` and `WORKTREE_PATH=<absolute path>` so the bundle and the CLI half of the activation contract stay aligned. Log `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-push-to-git","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"create-pr-handoff","bypassed":true,"default_taken":"invoke-create-pr","trigger":"<agent_id|cli_flag|task_id_bundle>","forwarded":["--autonomous","WORKTREE_PATH"]}}'`.

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key, commit-grouping, push-confirm, and create-pr-handoff gates are bypassed per the rules above.
- **Pre-push hook still fires** — autonomous mode bypasses *user* approval, not *infrastructure* checks. If the pre-push hook rejects, return R1 `status:"failure"` with the hook output in `errors[]`.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md`.
- **Forward `--autonomous` explicitly** when invoking `/build-create-pr` at hand-off.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "data": {
    "branch": "<name>",
    "commits": <N>,
    "remote_branch": "origin/<name>",
    "pre_push_hook_fired": <true|false>,
    "next_skill_invoked": "build-create-pr" | null
  }
}
```

`agent` is `"build-push-to-git"`. `summary` is `"Pushed N commits to origin/<branch>"` on success.

### HALT Codes

| Code | Meaning |
|------|---------|
| `MISSING_INPUT` | `--autonomous` invoked without a work-item-key argument |
| `PROTECTED_BRANCH` | Step 1 found the branch is `main` / `master` |
| `NOTHING_TO_COMMIT` | Step 3 found the working tree clean |
| `COMMIT_FAILED` | Step 5 — a git commit returned non-zero |
| `PUSH_REJECTED` | Step 7 — `git push` rejected (diverged remote, pre-push hook failure, auth) |
