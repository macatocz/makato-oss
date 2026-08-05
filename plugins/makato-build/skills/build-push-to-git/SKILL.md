---
name: build-push-to-git
description: >-
  Create atomic conventional commits from the plan's task structure
  and push the feature branch to remote. One commit per logical task,
  individually bisectable. Confirms push before affecting remote.
  Use after verify, before create-pr.
version: "1.6.0"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools: [Bash]
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
---

## When to Use

Use after `/verify` (all gates pass) and before `/create-pr`. The code is clean, tested, and reviewed. This step produces a commit history that maps to the plan's task structure and pushes the branch to remote.

## Mindset

**This step is about history, not just delivery.** The commits you create here are the permanent record a future engineer uses to understand *why* each change was made. A message like `feat(invoice): add status field` is navigable three months later; `misc changes` is not.

Three non-obvious principles:

**1. Every commit must leave the build green.**
The rule "tests go in the same commit as production code" exists because a commit containing only new production code leaves a failing test suite — breaking `git bisect` even though the final state compiles. A bisect-clean sequence is the guarantee this step makes to the team.

**2. Push is the first truly irreversible action.**
Before `git push`, every commit can be rebased, amended, or dropped with no team impact. After push, treat the history as shared. The explicit confirmation gate at Step 6 is not ceremony — it is the last checkpoint where local cleanup is free.

**3. Staging discipline is how you control what the commit records.**
`git add <specific-files>` stages exactly the plan's intent. `git add -A` stages everything in the working tree — including auto-generated files, IDE configs, and secrets written during debugging. Once pushed, stray files are permanent and public.

## Input

When dispatched by the PO-agent (`--autonomous` mode):

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). All `git` invocations below run with `git -C "$WORKTREE_PATH"` (or after `cd "$WORKTREE_PATH"`) so the commit lands on the worktree's branch and `git push` targets the right ref. Pushing from the main checkout would push the wrong branch — a contract violation.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

**MANDATORY: Load `@../../AUTONOMOUS-MODE.md`** before applying this guard — sections *WORKTREE_PATH — workspace-isolation contract*, *Falsy-check pattern*, and *Two roots, one contract* define the derivation formulas used in every step below. Do NOT skip this load even in interactive mode; the REPO_ROOT bash formula is defined there.

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

**MANDATORY: Load `@../../AUTONOMOUS-MODE.md`** when `--autonomous` is present in the dispatch bundle — sections *Activation triggers* and the per-gate default table apply throughout. Do NOT load this section at runtime in a pure interactive session (no dispatch bundle, no `--autonomous` flag).

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
- If an argument was passed: use it.
- If no argument: HALT with `MISSING_INPUT: build-push-to-git in --autonomous mode requires a work-item-key argument`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `shared/log-bypass.sh build-push-to-git "<key>" work-item-key use-arg "$AGENT_ID"` when bypassed.

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

**MANDATORY: Load `@references/commit-guide.md`** at this step — not before. Do NOT load it before Step 4; the conventional-commit format details are irrelevant to the git-state checks above.

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

In **autonomous mode**, skip the confirmation: use each task's `commitMessage` field from `plan.md` verbatim, apply the grouping rules above, log `shared/log-bypass.sh build-push-to-git "<key>" commit-grouping plan-as-drafted "$AGENT_ID"`, and proceed to Step 5.

---

### Step 5 — Create commits

For each planned commit in task order:
1. Stage exactly the files in that commit's group: `git add <file1> <file2> …` — never `git add -A` or `git add .`
2. Create the commit with the conventional message from the plan
3. Verify the commit landed: `git log -1 --oneline`

Do not amend existing commits. WHY: amending rewrites the commit SHA, invalidating the `build.jsonl` log entry that recorded the original SHA (Step 5 JSONL) and making any later commit that built on top of it require a force-push — which the `PUSH_REJECTED` HALT has no auto-recovery path for.

If a commit fails, report the error verbatim and stop — do not proceed to the next commit until the failure is resolved.

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

In **autonomous mode**, skip the prompt: proceed directly to Step 7 (the pre-push hook still fires — autonomous mode does not bypass git hooks). Log `shared/log-bypass.sh build-push-to-git "<key>" push-confirm push "$AGENT_ID"`.

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

**(Optional) Lesson write (#473):** if this session produced a noteworthy lesson — a
bugfix/gotcha pattern (`tier:procedural`) or a durable technical fact (`tier:semantic`) —
append it to the per-issue store so the po-agent's local-lane promote step
(`promote-lessons.sh`, run at the merge-success terminal, po-agent Step 6 item 7) can
lift `generalizable` records into `.makato/memory/`:

```bash
shared/write-lessons.sh "<key>" "<tier>" "<scope>" "<text>" "[tags]"
#   tier  = procedural | semantic
#   scope = generalizable | local   (generalizable → eligible for promotion)
#   tags  = optional comma-separated list
```

This appends one record to `specs/<key>-*/change-lessons.jsonl`; it never writes to
`.makato/memory/` (promotion is `documentation-agent`'s job). Omit the call entirely when
there is nothing notable to record — it is optional and each call is an independent append.
If both `build-verify` and `build-push-to-git` run in one session, record each lesson once
(at whichever terminal step you reach it) to avoid duplicate records.

Tell the user: *"`<N>` commits pushed to `<branch>`."*

In **interactive mode**, then ask using `AskUserQuestion`:
- Question: "Branch is on remote. Create the pull request now?"
- Option A: **Yes, create PR now** — description: "Draft and open the PR using `/build-create-pr` — generates description from spec artifacts"
- Option B: **No, I'll do it later** — description: "Run `/build-create-pr <key>` manually when ready"

If option A: invoke `/build-create-pr <key>` directly.
If option B: tell the user: "Run `/makato-build:build-create-pr <key>` when ready."

In **autonomous mode**, skip the prompt: invoke `/build-create-pr <key>` directly. Autonomous mode signals through the inherited `$AGENT_ID` env var (see `@../../AUTONOMOUS-MODE.md` § *Cross-skill propagation*); the `--autonomous` CLI flag is NOT forwarded on cross-skill dispatch. The downstream context bundle MUST still carry the `WORKTREE_PATH` field verbatim from this skill's input — `build-create-pr` runs its own entry-guard falsy-check and HALTs `MISSING_INPUT` if the field is absent in autonomous mode. The hand-off prompt that dispatches `/build-create-pr` therefore includes `WORKTREE_PATH=<absolute path>` and any other documented bundle fields. Log `shared/log-bypass.sh build-push-to-git "<key>" create-pr-handoff invoke-create-pr "$AGENT_ID" '{"forwarded":["WORKTREE_PATH"]}'`.

## Anti-patterns

**NEVER `git add -A` or `git add .` (Step 5).**
WHY: Both stage every tracked and untracked file in the working tree — including IDE config directories, auto-generated artefacts, and any `.env` or credential file written during the session. A single stray secret staged this way becomes a permanent public record once pushed. `git add <file1> <file2>` is the only safe staging command for this step.

**NEVER amend an existing commit (Step 5).**
WHY: Amending rewrites the SHA. The `build.jsonl` log entry written at Step 5 records the original short SHA as an immutable audit reference. A rewritten SHA produces a ghost reference in that log. More critically, any subsequent commit already built on the original SHA now diverges from the remote after push — producing a non-fast-forward rejection that has no automatic recovery in the `PUSH_REJECTED` HALT path. Create a fixup commit instead; clean up via interactive rebase before Step 6 if needed.

**NEVER retry automatically on push rejection (Step 7).**
WHY: A push rejection may mean another agent or engineer pushed to the same remote branch after your last `git fetch`. Auto-retry with force would silently overwrite their work. HALT with `PUSH_REJECTED` and surface the error — the PO-agent's recovery route decides whether to rebase or escalate to the operator.

**NEVER read spec artefacts from `$WORKTREE_PATH` (entry guard, Step 1).**
WHY: `specs/*` is excluded by the repo-root `.gitignore` and a fresh `git worktree add` creates a worktree with no `specs/` content at all. Reading `$WORKTREE_PATH/specs/<key>-*/plan.md` fails silently (file not found) and surfaces only when commit grouping cannot parse a task list at Step 4. Always use `$REPO_ROOT/specs/<key>-*/plan.md`.

**Do NOT forward `--autonomous` to `/build-create-pr` (Step 8).**
WHY: `$AGENT_ID` is the cross-dispatch signal for autonomous mode. Forwarding `--autonomous` as an explicit CLI flag causes double-activation in `build-create-pr` and may bypass guards that specifically check `$AGENT_ID` presence for safe handoff. Forward `WORKTREE_PATH` in the context bundle — not the flag.

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key, commit-grouping, push-confirm, and create-pr-handoff gates are bypassed per the rules above.
- **Pre-push hook still fires** — autonomous mode bypasses *user* approval, not *infrastructure* checks. If the pre-push hook rejects, return R1 `status:"failure"` with the hook output in `errors[]`.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md`.
- **Do NOT forward `--autonomous`** when invoking `/build-create-pr` at hand-off — `$AGENT_ID` carries the signal across the dispatch boundary (see `@../../AUTONOMOUS-MODE.md` § *Cross-skill propagation*). `WORKTREE_PATH` is still forwarded in the context bundle.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "data": {
    "branch": "<name>",
    "commits": "<N>",
    "remote_branch": "origin/<name>",
    "pre_push_hook_fired": "<true|false>",
    "next_skill_invoked": "build-create-pr | null"
  }
}
```

`agent` is `"build-push-to-git"`. `summary` is `"Pushed N commits to origin/<branch>"` on success.

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `PROTECTED_BRANCH`, `NOTHING_TO_COMMIT`, `COMMIT_FAILED`, `PUSH_REJECTED`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.
