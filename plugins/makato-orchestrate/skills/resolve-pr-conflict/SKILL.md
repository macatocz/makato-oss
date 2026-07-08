---
name: resolve-pr-conflict
description: Detect and resolve a merge conflict on an open PR branch inside the PO-agent worktree — rebase-first, merge -X ours fallback, HALT-008 when irreconcilable. Invoked by the PO-agent outer loop after a conflict signal or CI rebase-check failure. Returns R1 envelope.
version: "1.1.0"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools: Bash(git *) Bash(gh *) Bash(jq *) Bash(python3 *) Read
---

## When to Use

Invoked exclusively by the PO-agent outer loop (GAP-016 / #45) after one of two
conflict signals:

1. `gh pr create` exits non-zero and stderr contains `"conflict"` or
   `"cannot be rebased automatically"`.
2. `gh pr checks --json name,conclusion` returns a check named `*rebase*` or
   `*merge*` with `conclusion: "failure"`.

Not intended for interactive use — it is a headless resolution subroutine. In
interactive mode it may be invoked directly on a dirty feature branch.

**When NOT to use:** Do not invoke on protected branches (`main`, `master`,
`development`) — the Entry Router blocks this. Do not invoke when the worktree
was not created by the PO-agent (state file would be absent).

---

## Workflow

### Step 1 — Entry Router

Runs before any other step on every invocation.

**Detect mode:** autonomous when `$AGENT_ID` is set OR `--autonomous` is passed
OR the caller context bundle contains `task_id`. Interactive otherwise.

**Resolve worktree path:** in autonomous mode read from workflow-state via
the canonical helper (it resolves `specs/<key>-*/workflow-state-<issue>.json`
for the given KEY / ISSUE — per-issue file layout, #173 — never hand-construct
the path; the spec folder uses a `<key>-<slug>` suffix that the helper resolves
via prefix match):

```bash
WORKTREE_PATH=$(shared/workflow-state.sh read "$KEY" "$ISSUE" | jq -r '.worktree_path // empty')
if [[ -z "$WORKTREE_PATH" ]]; then
  echo "ERROR: workflow-state has no worktree_path for KEY=$KEY ISSUE=$ISSUE" >&2
  exit 1
fi
```

The PO-agent's dispatch bundle carries `ISSUE_NUMBER` alongside `KEY` — this
skill must be dispatched with both arguments in autonomous mode.

In interactive mode use `git rev-parse --show-toplevel`.

**Verify branch is not protected:**

```bash
BRANCH=$(cd "$WORKTREE_PATH" && git branch --show-current)
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" || "$BRANCH" == "development" ]]; then
  echo "ERROR: cannot run conflict resolution on protected branch $BRANCH" >&2
  exit 1
fi
```

Constraint: if the branch is protected → HALT `SAFETY_BOUNDARY`. Never attempt
resolution on a protected branch — those branches have CI-enforced protection and
force-pushing them rewrites shared history. The deny-list intentionally covers
all three common default-branch names (`main`, `master`, `development`)
regardless of which one Step 2 selects as the rebase target, so the safety net
holds for every consumer repo convention.

In autonomous mode all decisions follow the strategy table in Steps 3–4. Do not
call `AskUserQuestion` — every branch is taken without user input.

Log session start AND the canonical `merge_conflict_detected` event (GAP-016
/ #45 AC9 — the entry signals to downstream audit that the PO-agent's outer
loop dispatched conflict resolution, distinct from a CI-failure dispatch):

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"session","status":"start","data":{"branch":"<BRANCH>","worktree_path":"<PATH>"}}'

shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"merge_conflict_detected","status":"warn","data":{"branch":"<BRANCH>","worktree_path":"<PATH>"}}'
```

---

### Step 2 — Resolve target branch and fetch latest

The skill rebases against `development` when the consumer repo uses it as
its default branch (AgenticSystem PRD `code-conflict-prevention.md` convention),
otherwise against `main`. Detection runs against the remote refs in the
worktree's `origin` so the choice always reflects the actual remote state,
not local `HEAD` (which can drift if a contributor renamed branches).

```bash
cd "$WORKTREE_PATH"
git fetch origin --prune

# Pick development if it exists on origin, otherwise main. The two-step
# check avoids the false positive of a stale local-only `development`
# ref that no longer matches the remote.
if git ls-remote --exit-code --heads origin development >/dev/null 2>&1; then
  TARGET_BRANCH="development"
elif git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  TARGET_BRANCH="main"
else
  echo "ERROR: neither origin/development nor origin/main exists" >&2
  exit 1
fi

# Fetch the resolved target ref so origin/<TARGET_BRANCH> is current.
git fetch origin "$TARGET_BRANCH"
```

If `git fetch` fails → log warn, HALT `NETWORK_ERROR`. If neither
`development` nor `main` exists on origin → HALT `NETWORK_ERROR` with
reason `"target branch not found on origin"` (the consumer repo has a
non-standard default; rebase resolution is not applicable and the human
operator must take over).

Log the resolved target so a downstream reader can see which branch was
used (helpful when a repo switches its default branch mid-project):

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"target-resolved","status":"ok","data":{"target_branch":"<TARGET_BRANCH>"}}'
```

---

### Step 3 — Attempt 1: Rebase

```bash
cd "$WORKTREE_PATH"
git rebase "origin/$TARGET_BRANCH"
REBASE_EXIT=$?
```

**If `REBASE_EXIT == 0`:**

```bash
UNRESOLVED=$(git diff --name-only --diff-filter=U)
```

- `$UNRESOLVED` empty → rebase clean, go to Step 5.
- `$UNRESOLVED` non-empty → treat as conflict, go to Step 4.

**If `REBASE_EXIT != 0`:** rebase stopped on a conflict, go to Step 4.

Log the attempt:

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"rebase-attempt","status":"<ok|warn>","data":{"exit_code":<N>,"strategy":"rebase"}}'
```

---

### Step 4 — Abort rebase, attempt merge -X ours

Constraint: always call `git rebase --abort` before falling back to merge.
Leaving a rebase in-progress state corrupts the worktree's HEAD and makes
subsequent git operations fail with "rebase in progress" errors.

```bash
cd "$WORKTREE_PATH"
git rebase --abort 2>/dev/null || true
git merge "origin/$TARGET_BRANCH" -X ours --no-edit \
  -m "fix: resolve conflicts on $(git branch --show-current) (merge -X ours)"
MERGE_EXIT=$?
```

Constraint: always use `-X ours` (feature branch wins on conflict) for the
feature → `$TARGET_BRANCH` direction. `-X theirs` would silently prefer the
target branch's version and discard the PR's own changes. `-X ours` does
NOT discard the target's non-conflicting changes — only conflicting hunks
are resolved in favour of the feature branch.

**If `MERGE_EXIT == 0`:**

```bash
UNRESOLVED=$(git diff --name-only --diff-filter=U)
```

- `$UNRESOLVED` empty → merge clean, go to Step 5.
- `$UNRESOLVED` non-empty → merge exited 0 but left conflict markers; treat as failure.

**If `MERGE_EXIT != 0` OR unresolved files remain:**

```bash
git merge --abort 2>/dev/null || true
```

Go to Step 6 (HALT).

Log the merge attempt:

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"merge-fallback","status":"<ok|error>","data":{"exit_code":<N>,"strategy":"merge-X-ours","unresolved_files":[...]}}'
```

---

### Step 5 — Force-push resolved branch

Constraint: always use `--force-with-lease`, never bare `--force`. Force-with-lease
refuses if the remote has commits not in the local ref, preventing silent history
overwrite on a PR that someone else has pushed to concurrently. Do not delete and
recreate the branch to resolve the conflict — the open PR is tied to the branch
name; recreating it breaks the PR URL and all CI status links. Resolve in-place
and force-push.

```bash
cd "$WORKTREE_PATH"
git push --force-with-lease origin "$BRANCH"
```

If `--force-with-lease` fails → log warn, HALT `PUSH_REJECTED`.

Log:

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"push-resolved","status":"ok","data":{"strategy":"<rebase|merge-X-ours>","branch":"<BRANCH>"}}'

shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"rebase_resolved","status":"ok","data":{"strategy":"<rebase|merge-X-ours>","branch":"<BRANCH>"}}'
```

The dual log entry is intentional: `push-resolved` is the step-named audit
matching the body convention used in Steps 3–4; `rebase_resolved` is the
canonical GAP-016 / #45 AC9 event name surfaced to the PO-agent's outer-loop
audit reader. Both rows are loud successes — never written on the HALT path.

Return R1 success envelope:

```json
{
  "schema": "r1",
  "agent": "resolve-pr-conflict",
  "status": "success",
  "summary": "Conflict resolved on <branch> via <rebase|merge-X-ours>; branch force-pushed.",
  "files_changed": [],
  "errors": [],
  "data": {
    "strategy": "rebase | merge-X-ours",
    "branch": "<branch>",
    "worktree_path": "<path>"
  }
}
```

---

### Step 6 — HALT: irreconcilable conflict

Both strategies failed. The conflict requires human judgment.

1. Increment `merge_conflict_cycles` in workflow-state (schema field added
   per GAP-016 / #45 AC5). Use `workflow-state.sh patch` (typed, schema-
   validated) rather than ad-hoc jq — the PO-agent is the sole writer
   contract still holds because resolve-pr-conflict runs *inside* the
   PO-agent's outer loop and inherits its allow-list. The cap check is
   performed by the **caller** (PO-agent Step 6 #3) before dispatching
   this skill; reaching Step 6 here means rebase + `merge -X ours` both
   failed at the git level, and HALT-008 fires unconditionally regardless
   of the counter value. The increment exists so subsequent dispatches in
   the same run honour the cap on the PO-agent side.

   ```bash
   CYCLES=$(shared/workflow-state.sh read "$KEY" | jq '.merge_conflict_cycles // 0')
   NEW_CYCLES=$((CYCLES + 1))
   shared/workflow-state.sh patch "$KEY" .merge_conflict_cycles "$NEW_CYCLES"
   shared/worktree.sh retain "$KEY" merge_conflict
   ```

   The `worktree.sh retain` call flips `.worktree_retained = true` and
   `.worktree_retain_reason = "merge_conflict"` — AC7 mandates the worktree
   survives the HALT so a human can inspect the conflict state.

2. Apply `needs-human-review` label:

   ```bash
   gh issue edit "$ISSUE_NUMBER" --add-label "needs-human-review" --repo "$REPO"
   ```

3. Append lesson (GAP-015 / #37 schema — typed `append-lesson`
   subcommand). The helper injects `ts`, truncates `description` at
   200 chars, and accepts the conflicted file list as variadic
   positional args. `mapfile` is used (not `$(…)` word-splitting) so
   paths containing spaces survive intact:

   ```bash
   mapfile -t CONFLICT_FILES < <(git diff --name-only --diff-filter=U)
   shared/workflow-state.sh append-lesson "$KEY" "$NEW_CYCLES" merge_conflict \
     "irreconcilable conflict on $BRANCH after rebase + merge -X ours" \
     "${CONFLICT_FILES[@]}"
   ```

4. Log the canonical `rebase_failed` event (GAP-016 / #45 AC9) AND the
   session-end HALT row. The two rows are distinct: `rebase_failed`
   surfaces the conflict outcome on its own audit step so a downstream
   reader can count merge-conflict halts without joining `session` rows;
   `session` carries the terminal-state envelope for orchestrate.jsonl
   parity:

   ```bash
   shared/build-log.sh "$KEY" \
     '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"rebase_failed","status":"error","data":{"halt_code":"HALT-008","reason":"irreconcilable_conflict","merge_conflict_cycles":<N>,"branch":"<BRANCH>"}}'

   shared/build-log.sh "$KEY" \
     '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"session","status":"error","data":{"halt_code":"HALT-008","reason":"irreconcilable_conflict","merge_conflict_cycles":<N>,"worktree_retained":true}}'
   ```

5. Return R1 failure envelope:

   ```json
   {
     "schema": "r1",
     "agent": "resolve-pr-conflict",
     "status": "failure",
     "summary": "HALT-008: irreconcilable conflict on <branch> after rebase + merge-X-ours. Worktree retained.",
     "errors": ["HALT-008: merge_conflict_cycles=<N>"],
     "data": {
       "halt_code": "HALT-008",
       "merge_conflict_cycles": 3,
       "worktree_retained": true,
       "unresolved_files": []
     }
   }
   ```

---

## HALT Codes

| Code | Trigger | Recovery |
|---|---|---|
| `HALT-008` | Both rebase and merge-X-ours leave unresolved files, OR `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3) — see `halt-conditions.md` HALT-008 for the dual-origin documentation | Human resolves conflict in retained worktree, re-pushes, re-triggers PO-agent loop |
| `SAFETY_BOUNDARY` | Branch is `main`, `master`, or `development` | Check out a feature branch first |
| `NETWORK_ERROR` | `git fetch origin <target>` fails OR neither `origin/development` nor `origin/main` exists | Verify network / GitHub access, confirm the consumer repo's default branch is `development` or `main`, retry |
| `PUSH_REJECTED` | `--force-with-lease` refused | Fetch and inspect remote changes; re-run skill |

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `MAKATO_MAX_MERGE_CONFLICT_CYCLES` | `3` | Hard ceiling on irreconcilable-conflict retries within a single run. When the post-increment `merge_conflict_cycles` reaches this value, Step 6 fires HALT-008 unconditionally. Distinct from `MAX_OUTER_ITERATIONS` (the re-plan-loop ceiling enforced by `kill-switch poll`) — a run can exhaust BOTH ceilings independently. |
