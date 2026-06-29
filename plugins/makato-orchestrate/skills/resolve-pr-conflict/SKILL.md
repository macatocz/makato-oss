---
name: resolve-pr-conflict
description: Detect and resolve a merge conflict on an open PR branch inside the PO-agent worktree — rebase-first, merge -X ours fallback, HALT-008 when irreconcilable. Invoked by the PO-agent outer loop after a conflict signal or CI rebase-check failure. Returns R1 envelope.
version: "1.0.0"
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

**Resolve worktree path:** in autonomous mode read from workflow-state:

```bash
jq -r '.worktree_path' ".claude/state/workflow-${KEY}.json"
```

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
force-pushing them rewrites shared history.

In autonomous mode all decisions follow the strategy table in Steps 3–4. Do not
call `AskUserQuestion` — every branch is taken without user input.

Log session start:

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"session","status":"start","data":{"branch":"<BRANCH>","worktree_path":"<PATH>"}}'
```

---

### Step 2 — Fetch latest main

```bash
cd "$WORKTREE_PATH"
git fetch origin main
```

If `git fetch` fails → log warn, HALT `NETWORK_ERROR`.

---

### Step 3 — Attempt 1: Rebase

```bash
cd "$WORKTREE_PATH"
git rebase origin/main
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
git merge origin/main -X ours --no-edit \
  -m "fix: resolve conflicts on $(git branch --show-current) (merge -X ours)"
MERGE_EXIT=$?
```

Constraint: always use `-X ours` (feature branch wins on conflict) for the
feature → main direction. `-X theirs` would silently prefer main's version and
discard the PR's own changes. `-X ours` does NOT discard main's non-conflicting
changes — only conflicting hunks are resolved in favour of the feature branch.

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
```

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

1. Increment `merge_conflict_cycles` in workflow-state (GAP-017 / #46 field).
   In autonomous mode: if `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES`
   (default 3, env-configurable) fire HALT-008 immediately without retry.

   ```bash
   STATE_FILE=".claude/state/workflow-${KEY}.json"
   CYCLES=$(jq '.merge_conflict_cycles // 0' "$STATE_FILE")
   NEW_CYCLES=$((CYCLES + 1))
   jq ".merge_conflict_cycles = $NEW_CYCLES | .worktree_retained = true | .worktree_retain_reason = \"merge_conflict\"" \
     "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
   ```

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

4. Log HALT:

   ```bash
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
| `HALT-008` | Both rebase and merge-X-ours leave unresolved files | Human resolves conflict in retained worktree, re-pushes, re-triggers PO-agent loop |
| `SAFETY_BOUNDARY` | Branch is `main`, `master`, or `development` | Check out a feature branch first |
| `NETWORK_ERROR` | `git fetch origin main` fails | Verify network / GitHub access, retry |
| `PUSH_REJECTED` | `--force-with-lease` refused | Fetch and inspect remote changes; re-run skill |
