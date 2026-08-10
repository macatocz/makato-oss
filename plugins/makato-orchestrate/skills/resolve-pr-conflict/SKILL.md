---
name: resolve-pr-conflict
description: Detect and resolve a merge conflict on an open PR branch inside the PO-agent worktree — rebase-first, then a partitioned merge fallback (union for append-only files like CHANGELOG, -X ours for the rest), HALT-008 when irreconcilable. Invoked by the PO-agent outer loop after a conflict signal or CI rebase-check failure. Returns R1 envelope.
version: "1.2.0"
metadata:
  authors: [makato-orchestrate]
  last_updated: "2026-08-05"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools: Bash(git *) Bash(gh *) Bash(jq *) Bash(python3 *) Bash(plugins/makato-orchestrate/scripts/resolve-append-only-conflict.sh *) Read
---

## Do NOT Load This Skill When

- The current branch is `main`, `master`, or `development` — the Entry Router will block with `SAFETY_BOUNDARY`, and no useful work can be done.
- The worktree was NOT created by the PO-agent (no `workflow-state.json` for the given KEY/ISSUE) — autonomous mode cannot resolve the worktree path and will fail at Step 1.
- You want to resolve an in-progress interactive rebase or merge on your own working branch — use the `resolving-merge-conflicts` skill instead.

---

## Mindset

> Start with the least-destructive strategy. Never widen the conflict surface. Escalate to HALT over guessing.

This skill is a **headless resolution subroutine**, not a conversational assistant. In autonomous mode it never asks the user anything — every branch is deterministic. The three-level escalation exists because each level trades safety for coverage:

1. **Rebase** — history-clean, zero conflict surface widening. Succeeds for the 90 % case where commits are independent.
2. **Partitioned merge** — union on append-only files (data-safe for changelogs and audit logs), ours-wins on everything else (PR changes are preserved). Succeeds for the "two PRs touched CHANGELOG" pattern.
3. **HALT-008** — fires when human judgment is irreplaceable. The worktree is retained so the human can inspect the exact conflict state.

The critical insight: the partition between union and ours-wins is the expert decision. Do not extend the union allow-list casually — union on a source file produces duplicate symbols; union on a lockfile produces unparseable JSON. See `references/append-only-classes.md` for the invariant checklist.

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

---

## Anti-Patterns

Dedicated section — every item is an experience-only NEVER with its causal WHY.

**NEVER use bare `--force` on the push (Step 5).** Always use `--force-with-lease`.
WHY: bare `--force` overwrites remote commits unconditionally. If a concurrent push arrived between your rebase and your push, `--force` silently discards it. `--force-with-lease` refuses when the remote ref has advanced, turning a silent data-loss into a retryable `PUSH_REJECTED` HALT.

**NEVER delete and recreate the branch to resolve a conflict.**
WHY: the open PR is tied to the branch name. Deleting the branch closes the PR, destroys all CI status links, invalidates review threads, and loses the GitHub PR URL. Always resolve in-place and force-push.

**NEVER apply `git merge -X ours` directly (without a plain merge first).**
WHY: `-X ours` resolves every conflicting hunk silently in favour of the feature branch — including on append-only files like CHANGELOG where the target branch's new entry is simply discarded. There is no conflict marker and no indication of data loss. The two-step approach (plain `--no-commit` merge to surface all unmerged paths, then partition by class) makes every resolved path visible in the Step 4 log.

**NEVER apply `git merge -X theirs`.**
WHY: this silently discards the PR's own changes in favour of the target branch. The whole purpose of the skill is to land the PR's changes — preferring theirs is the opposite of correct. If you are tempted by `-X theirs`, you are likely resolving the wrong branch direction.

**NEVER skip `git rebase --abort` before the merge fallback.**
WHY: a rebase left in-progress corrupts the worktree's HEAD. Subsequent git operations fail with "rebase in progress" errors until the abort is issued. The `|| true` guard ensures the abort does not fail the script when the rebase already exited cleanly.

**NEVER extend the union allow-list without verifying all three invariants** (both sides only add lines; order is not load-bearing; duplicate lines do not break consumers). See `references/append-only-classes.md`.
WHY: union on a JSON config file produces duplicate keys (silent parse error or exception). Union on `package-lock.json` produces an unparseable lockfile. Union on a Python source file produces duplicate `import` statements or double-registered handlers. Each of these failures is invisible at merge time and only surfaces at runtime.

**NEVER run conflict resolution on a protected branch (`main`, `master`, `development`).**
WHY: these branches have CI-enforced protection and shared history. Force-pushing them rewrites the base for every open PR targeting them — a single wrong resolution can cascade into dozens of broken PRs. The Entry Router's deny-list covers all three common default-branch names unconditionally.

**NEVER hand-construct the spec folder path or the workflow-state file path.**
WHY: the spec folder uses a `<key>-<slug>` suffix resolved by prefix match. Hand-constructing it will silently resolve to the wrong folder if the slug contains hyphens or if the issue has a long title. Always use `shared/workflow-state.sh read "$KEY" "$ISSUE"` — the helper encapsulates the prefix-match logic.

**NEVER call `AskUserQuestion` in autonomous mode.**
WHY: this skill runs inside the PO-agent's outer loop which is fully unattended. Any user prompt will stall the loop indefinitely. Every decision must follow the deterministic strategy table in Steps 3–4. Autonomous mode is detected at Step 1; the code path never reaches an interactive branch.

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

### Step 4 — Abort rebase, attempt partitioned merge (union for append-only, ours for the rest)

Constraint: always call `git rebase --abort` before falling back to merge.
Leaving a rebase in-progress state corrupts the worktree's HEAD and makes
subsequent git operations fail with "rebase in progress" errors.

**Why a plain merge first, not `merge -X ours` directly.** `git merge -X ours`
resolves *every* conflicting hunk in favour of the feature branch **without
reporting a conflict** — including on an append-only file like a CHANGELOG,
where each branch prepends its own release block. There, `-X ours` silently
discards the target branch's newly-added entry: the merge "succeeds" and the
data loss is invisible. So the fallback runs a *plain* merge to surface all
conflicts as unmerged paths, then resolves them by class:

- **Append-only files** (CHANGELOG, AUTHORS, `*.jsonl` audit logs, and similar
  files where both sides only *add* lines) → 3-way **union** merge via
  `scripts/resolve-append-only-conflict.sh`, which keeps every line from both
  sides in order. This is the fix for the common "two PRs both touched the
  changelog" conflict — neither side's entry is lost.
- **All other files** → `-X ours` semantics: the feature branch wins the
  conflicting hunk (`git checkout --ours` + `git add`). Non-conflicting changes
  from the target are already merged and are untouched.

> MANDATORY: Load `references/append-only-classes.md` before extending the
> `is_append_only()` allow-list. Union is only safe for files matching all
> three invariants documented there.

```bash
cd "$WORKTREE_PATH"
git rebase --abort 2>/dev/null || true

# Plain merge to surface all conflicts as unmerged paths (do NOT use -X here).
git merge "origin/$TARGET_BRANCH" --no-commit --no-ff
MERGE_EXIT=$?

mapfile -t UNRESOLVED < <(git diff --name-only --diff-filter=U)
```

If `MERGE_EXIT == 0` and `UNRESOLVED` is empty → merge was clean, commit is
already pending; run `git commit --no-edit` and go to Step 5.

Otherwise partition the unresolved paths. An "append-only" file is matched by
basename/extension against a fixed allow-list — the classes where a union merge
is provably safe (both sides only add lines, order within the file is not
load-bearing beyond "newest on top", which union preserves per-side):

```bash
# Append-only allow-list. Extend deliberately — union is only safe for files
# where both sides append/prepend and never rewrite shared lines.
is_append_only() {
  local f; f="$(basename "$1")"
  case "$f" in
    CHANGELOG.md|CHANGELOG|AUTHORS|AUTHORS.md|CONTRIBUTORS|CONTRIBUTORS.md) return 0 ;;
  esac
  case "$1" in
    *.jsonl) return 0 ;;   # append-only audit logs (build.jsonl, orchestrate.jsonl)
  esac
  return 1
}

RESOLVED_UNION=(); RESOLVED_OURS=()
for f in "${UNRESOLVED[@]}"; do
  if is_append_only "$f"; then
    # Union-merge: keep both sides' additions. Stages the file on success.
    if plugins/makato-orchestrate/scripts/resolve-append-only-conflict.sh "$f" >/dev/null; then
      RESOLVED_UNION+=("$f")
    fi
  else
    # ours-wins for the conflicting hunks; non-conflicting target changes stay.
    git checkout --ours -- "$f" && git add -- "$f" && RESOLVED_OURS+=("$f")
  fi
done

# Any path still unmerged after partitioning is irreconcilable here.
mapfile -t STILL_UNRESOLVED < <(git diff --name-only --diff-filter=U)
```

Constraint: `-X ours` (or the `checkout --ours` equivalent used here) always
means the **feature branch** wins for the feature → `$TARGET_BRANCH` direction.
`-X theirs` would silently prefer the target branch's version and discard the
PR's own changes. Union is used *only* for the append-only allow-list, where
neither side should be discarded.

**If `STILL_UNRESOLVED` is empty:** all conflicts resolved. Commit the merge and
go to Step 5:

```bash
git commit --no-edit \
  -m "fix: resolve conflicts on $(git branch --show-current) (union: ${RESOLVED_UNION[*]:-none}; ours: ${RESOLVED_OURS[*]:-none})"
```

**If `STILL_UNRESOLVED` is non-empty:**

```bash
git merge --abort 2>/dev/null || true
```

Go to Step 6 (HALT).

Log the merge attempt (record which files took which strategy so a downstream
reader can audit why a changelog was union-merged vs. a source file taking ours):

```bash
shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"merge-fallback","status":"<ok|error>","data":{"exit_code":<N>,"strategy":"partitioned","union_files":[...],"ours_files":[...],"unresolved_files":[...]}}'
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
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"push-resolved","status":"ok","data":{"strategy":"<rebase|partitioned-merge>","branch":"<BRANCH>"}}'

shared/build-log.sh "$KEY" \
  '{"ts":"<ISO>","skill":"resolve-pr-conflict","story":"<KEY>","step":"rebase_resolved","status":"ok","data":{"strategy":"<rebase|partitioned-merge>","branch":"<BRANCH>"}}'
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
  "summary": "Conflict resolved on <branch> via <rebase|partitioned-merge>; branch force-pushed.",
  "files_changed": [],
  "errors": [],
  "data": {
    "strategy": "rebase | partitioned-merge",
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
   this skill; reaching Step 6 here means rebase + the partitioned merge
   (union for append-only, ours for the rest) both left files unresolved
   at the git level, and HALT-008 fires unconditionally regardless
   of the counter value. The increment exists so subsequent dispatches in
   the same run honour the cap on the PO-agent side.

   ```bash
   CYCLES=$(shared/workflow-state.sh read "$KEY" "$ISSUE_NUMBER" | jq '.merge_conflict_cycles // 0')
   NEW_CYCLES=$((CYCLES + 1))
   shared/workflow-state.sh patch "$KEY" "$ISSUE_NUMBER" .merge_conflict_cycles "$NEW_CYCLES"
   shared/worktree.sh retain "$KEY" merge_conflict
   ```

   The `worktree.sh retain` call flips `.worktree_retained = true` and
   `.worktree_retain_reason = "merge_conflict"` — AC7 mandates the worktree
   survives the HALT so a human can inspect the conflict state.

2. Apply `needs-human-review` label and post a structured comment (best-effort):

   ```bash
   gh issue edit "$ISSUE_NUMBER" --add-label "needs-human-review" --repo "$REPO"
   shared/post-halt-comment.sh HALT-008 "$ISSUE_NUMBER" "$REPO" || true
   ```

3. Append lesson (GAP-015 / #37 schema — typed `append-lesson`
   subcommand). The helper injects `ts`, truncates `description` at
   200 chars, and accepts the conflicted file list as variadic
   positional args. `mapfile` is used (not `$(…)` word-splitting) so
   paths containing spaces survive intact:

   ```bash
   mapfile -t CONFLICT_FILES < <(git diff --name-only --diff-filter=U)
   shared/workflow-state.sh append-lesson "$KEY" "$ISSUE_NUMBER" "$NEW_CYCLES" merge_conflict \
     "irreconcilable conflict on $BRANCH after rebase + partitioned merge (union/ours)" \
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
     "summary": "HALT-008: irreconcilable conflict on <branch> after rebase + partitioned merge (union/ours). Worktree retained.",
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

> MANDATORY: Load `references/halt-conditions.md` when diagnosing a HALT or implementing recovery — it documents the dual-origin logic for HALT-008 and the full state-mutation sequence.

| Code | Trigger | Recovery |
|---|---|---|
| `HALT-008` | Both rebase and the partitioned merge (union for append-only, ours for the rest) leave unresolved files, OR `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3) — see `references/halt-conditions.md` HALT-008 for the dual-origin documentation | Human resolves conflict in retained worktree, re-pushes, re-triggers PO-agent loop |
| `SAFETY_BOUNDARY` | Branch is `main`, `master`, or `development` | Check out a feature branch first |
| `NETWORK_ERROR` | `git fetch origin <target>` fails OR neither `origin/development` nor `origin/main` exists | Verify network / GitHub access, confirm the consumer repo's default branch is `development` or `main`, retry |
| `PUSH_REJECTED` | `--force-with-lease` refused | Fetch and inspect remote changes; re-run skill |

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `MAKATO_MAX_MERGE_CONFLICT_CYCLES` | `3` | Hard ceiling on irreconcilable-conflict retries within a single run. When the post-increment `merge_conflict_cycles` reaches this value, Step 6 fires HALT-008 unconditionally. Distinct from `MAX_OUTER_ITERATIONS` (the re-plan-loop ceiling enforced by `kill-switch poll`) — a run can exhaust BOTH ceilings independently. |

## Smoke Tests

To validate the union-merge helper used in Step 4 interactively:

```bash
plugins/makato-orchestrate/scripts/tests/resolve-append-only-conflict-smoke-tests.sh
```

8 scenarios (T1–T8) covering clean union, single-side additions, both-sides prepend, and malformed-marker edge cases. Exits non-zero on any failure.
