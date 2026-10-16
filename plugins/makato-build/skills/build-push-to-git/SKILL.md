---
name: build-push-to-git
description: >-
  Create atomic conventional commits from the plan's task structure
  and push the feature branch to remote. One commit per logical task,
  individually bisectable. Confirms push before affecting remote.
  Use after verify, before create-pr.
version: "1.7.1"
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
- `REPO` — target `OWNER/REPO`; forward unchanged (resolve from origin
  when absent).
- `MAKATO_BUILD_ROOT` and optional sibling roots — installed plugin paths;
  preserve them at every dispatch, never probe the consumer repo for plugins.
- `SPEC_FOLDER` / `JSONL_PATH` — main-checkout spec folder and build log.
- `EXISTING_PR_NUMBER` — known open PR for this worktree branch.
- `CI_REPAIR_ACTIVE=true` — the caller owns the shared CI gate. Requires
  `EXISTING_PR_NUMBER` and selects **push-only** behavior: create the repair
  commits and push, but never create/reopen a PR or dispatch `build-fix-ci`.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

**MANDATORY: Read `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`** before applying
this guard — sections *WORKTREE_PATH — workspace-isolation contract*,
*Falsy-check pattern*, and *Two roots, one contract* define the derivation
formulas used in every step below.

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables, then apply
the workspace-isolation entry guard from
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` before Step 1's `git status`. In
autonomous mode an empty `WORKTREE_PATH` is a HALT with
`errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in
interactive mode the guard falls back to `git rev-parse --show-toplevel`. After
resolution, `cd "$WORKTREE_PATH"` — every `git`/`gh` command below runs from
this CWD.

**Spec-artefact reads use `REPO_ROOT`, not `WORKTREE_PATH`; `MAKATO_TARGET_REPO_ROOT`
selects the root when set, otherwise the common-dir fallback.**

```bash
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)}"
SPEC_FOLDER="$(
  python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"
)"
```

Reading `plan.md` in Step 1 below means the `SPEC_FOLDER` returned by
`python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"`,
never `$WORKTREE_PATH/specs/...`. See `AUTONOMOUS-MODE.md` § *Two roots, one
contract* for the full rationale.

### Existing-PR repair guard

Before staging or committing, if `CI_REPAIR_ACTIVE=true`, require a
positive `EXISTING_PR_NUMBER`. Resolve `REPO` from the supplied
`OWNER/REPO` or, when absent, from
`gh repo view "$(git remote get-url origin)" --json nameWithOwner --jq .nameWithOwner`
with origin's `GH_HOST`, then inspect that PR with explicit
`--repo "$REPO"`. It must be open and identify this worktree's branch and
origin repository. Missing repair inputs → `MISSING_INPUT`; failed lookup
or identity mismatch → `CI_BLOCKED` (or `GH_AUTH_FAILED` for auth errors).
Return terminal R1 failure without push, PR creation, or CI dispatch. Keep
the repair-ownership flag intact until the caller receives the result. This
flag suppresses only follow-on PR/CI dispatch, never review/verification
requirements or git hooks. Normal interactive push is unchanged.

### Downstream skill dispatch

In OMP mode (`MAKATO_HARNESS_MODE` unset or not `claude`), invoke workflow
skills with `python3 "${MAKATO_SKILL_RUNNER:-$MAKATO_BUILD_ROOT/scripts/run-skill.py}"`
using `--repo-root "$REPO_ROOT" --cwd "$WORKTREE_PATH"` and a complete
`--context-file`; inherit the configured harness/role selection. Do not
inline Skill/Task workflow execution or choose a different model. Claude mode
keeps native skill dispatch. Wait for completion and parse the final R1;
launcher errors or missing/malformed R1 block success. If autonomous mode was
activated only by its CLI flag and `AGENT_ID` is absent, put
`AUTONOMOUS_MODE:true` plus `task_id` (the work-item key when no dispatch id
exists) in the child context; do not accidentally revert standalone runs to
interactive mode.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we pushing? (e.g. DCP-1234, or pass it directly: `/makato-build:build-push-to-git DCP-1234`)"* — or use the passed argument.

Resolve `SPEC_FOLDER` with the shared resolver, then read `plan.md` from that
folder (NOT under `$WORKTREE_PATH`). Extract the task list — task titles and
their file targets. This defines the commit grouping.

Run `git status` and `git branch --show-current`. Verify the current branch is NOT `main` or `master`. If on a protected branch, stop and tell the user:

> "Cannot commit directly to `<branch>`. Create a feature branch first."

### Step 1a — Mode detection

**MANDATORY: Read `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`** when
`--autonomous` is present in the dispatch bundle — sections *Activation
triggers* and the per-gate default table apply throughout. Do NOT read this
section in a pure interactive session.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
- If an argument was passed: use it.
- If no argument: HALT with `MISSING_INPUT: build-push-to-git in --autonomous mode requires a work-item-key argument`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-push-to-git "<key>" work-item-key use-arg "$AGENT_ID"` when bypassed.

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","tasks":<N>}}'
```

---

### Step 3 — Verify there is something to commit

Run `git diff --stat HEAD` and inspect untracked implementation files to
identify changes. In the normal flow, a clean tree retains the existing
`NOTHING_TO_COMMIT` behavior. In existing-PR repair mode, a clean tree may
contain already-created, unpushed repair commits: skip empty commit creation
and continue to Step 7. Return the actual pushed HEAD; the CI owner, not this
skill, decides whether a no-change repair made progress.

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

In **autonomous mode**, skip the confirmation: use each task's `commitMessage` field from `plan.md` verbatim, apply the grouping rules above, log `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-push-to-git "<key>" commit-grouping plan-as-drafted "$AGENT_ID"`, and proceed to Step 5.

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

Show the user the commits that will be pushed (resolve the integration target via
`"$MAKATO_BUILD_ROOT/shared/default-branch.sh"` so a stale local `main` does not
include commits from already-merged PRs — #98):
```
DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"
git fetch origin --quiet
git log "$DEFAULT_REF..HEAD" --oneline
```

In **interactive mode**, ask: *"Ready to push `<N>` commits to `origin/<branch>`? This will trigger CI and be visible to the team."* Wait for explicit confirmation. If the user declines, the commits are local — they can push manually when ready. Stop here without error.

In **autonomous mode**, skip the prompt: proceed directly to Step 7 (the pre-push hook still fires — autonomous mode does not bypass git hooks). Log `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-push-to-git "<key>" push-confirm push "$AGENT_ID"`.

---

### Step 7 — Push to remote

Run `git push -u origin HEAD`.

On success: record the remote branch name and full
`HEAD_SHA="$(git -C "$WORKTREE_PATH" rev-parse HEAD)"`. In existing-PR mode,
read that PR's `headRefOid` using explicit `--repo "$REPO"` and require it
to match `HEAD_SHA` before reporting the push as successful.

On failure (rejected, no upstream, auth error): report the exact git error verbatim. Do not retry automatically — a push rejection may indicate the remote has diverged and requires a human decision.

Log:
```
{"ts":"<ISO8601>","skill":"build-push-to-git","story":"<key>","step":"push","status":"ok"|"error","data":{"remote_branch":"<name>"}}
```

---

### Step 8 — Log session end and hand off

Do not emit a terminal success yet: the normal autonomous handoff includes
`build-create-pr` and its shared CI gate. Close the session only after the
selected path below finishes. A commit/push failure closes with
`step:"session",status:"error"` and returns R1 failure with the exact error.

**(Optional) Lesson write (#473):** if this session produced a noteworthy lesson — a
bugfix/gotcha pattern (`tier:procedural`) or a durable technical fact (`tier:semantic`) —
append it to the per-issue store so the po-agent's local-lane promote step
(`promote-lessons.sh`, run at the merge-success terminal, po-agent Step 6 item 7) can
lift `generalizable` records into `.makato/memory/`:

```bash
"$MAKATO_BUILD_ROOT/shared/write-lessons.sh" "<key>" "<tier>" "<scope>" "<text>" "[tags]"
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

**Existing-PR repair mode (`CI_REPAIR_ACTIVE=true`):** stop the pipeline here.
Return R1 success for the push only, with `github_pr_number=EXISTING_PR_NUMBER`,
`head_sha=HEAD_SHA`, `pushed:true`, and `next_skill_invoked:null`. Log the
terminal session `status:"ok"` with those fields. Do not run either PR creation
or the shared CI gate; the waiting `build-fix-ci` caller resumes inspection
of this SHA. This path is not a green-CI claim.

In **interactive mode**, then ask using `AskUserQuestion`:
- Question: "Branch is on remote. Create the pull request now?"
- Option A: **Yes, create PR now** — description: "Draft and open the PR using `/build-create-pr` — generates description from spec artifacts"
- Option B: **No, I'll do it later** — description: "Run `/build-create-pr <key>` manually when ready"

If option A: invoke `/build-create-pr <key>` directly.
If option B: tell the user: "Run `/makato-build:build-create-pr <key>` when ready."

In **normal autonomous mode**, skip the prompt and dispatch
`makato-build:build-create-pr` with the work-item-key through the downstream
skill boundary above. `AGENT_ID` carries activation; do not forward the
`--autonomous` CLI flag. `WORKTREE_PATH` must be forwarded verbatim in the
context bundle with `REPO_ROOT`, `REPO`, `MAKATO_BUILD_ROOT`, optional sibling
roots, `SPEC_FOLDER`, `JSONL_PATH`, and any known `EXISTING_PR_NUMBER`. Log
`"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-push-to-git "<key>" create-pr-handoff invoke-create-pr "$AGENT_ID"`.

Wait for `build-create-pr`, which itself waits for `build-fix-ci`. Copy
its `github_pr_number`, `pr_url`, `head_sha`, `ci_status`,
`repair_cycles`, `unresolved_checks`, and `halt_code` into this skill's R1.
Preserve any actual context-handoff/resume data alongside a partial result.
The CI repair may have advanced HEAD after the initial push: return that final
SHA, never the initial `HEAD_SHA` in place of it. Preserve this PR metadata
and diagnostics on failure/partial too; never lose the existing PR when a
follow-on gate blocks. Normal autonomous success requires child
`status:"success"` and `ci_status:"green"`; any non-success, malformed
result, or launcher failure returns non-success without another PR/CI loop.

After the interactive choice or normal autonomous result, emit exactly one
terminal session event with `status:"ok"` only for the selected path's
success; otherwise `status:"error"`. Include known PR/HEAD/CI fields and
`halt_code` alongside `commits` and `branch` in its data. Do not overwrite
child errors or partial status with a generic "pushed" success.

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

Autonomous mode is activated per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` §
*Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key, commit-grouping, push-confirm, and create-pr-handoff gates are bypassed per the rules above.
- **Pre-push hook still fires** — autonomous mode bypasses *user* approval, not *infrastructure* checks. If the pre-push hook rejects, return R1 `status:"failure"` with the hook output in `errors[]`.
- **Log every bypass** to `build.jsonl` via `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"` with the `autonomous_bypass` event schema documented in `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`.
- **Do NOT forward `--autonomous`** on cross-skill dispatch; forward the
  explicit roots/artifact/PR context instead, with inherited `AGENT_ID`.
- **Existing-PR repairs are push-only** when `CI_REPAIR_ACTIVE=true`;
  `build-fix-ci` remains the sole owner of CI inspection and repair.
- **Wait for the normal create-pr/CI handoff** and propagate its full R1 outcome.
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
    "next_skill_invoked": "build-create-pr" | null,
    "repos_pushed": <N>,
    "github_pr_number": <N-or-null>,
    "pr_url": "<url-or-null>",
    "head_sha": "<full-final-pushed-sha>",
    "pushed": true,
    "ci_status": "green" | "blocked" | "pending" | null,
    "repair_cycles": <N-or-null>,
    "unresolved_checks": [],
    "halt_code": "<child-or-push-halt-code>" | null
  }
}
```

`agent` is `"build-push-to-git"`. Normal autonomous success includes
confirmed green CI on the returned SHA. Existing-PR repair success confirms
only the push: `ci_status:null`, `repair_cycles:null`, and
`next_skill_invoked:null`; the caller must run/continue the shared CI gate.
On child non-success preserve the child's status, errors, and CI fields even
when `pushed:true`.

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `PROTECTED_BRANCH`, `NOTHING_TO_COMMIT`, `COMMIT_FAILED`, `PUSH_REJECTED`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.
