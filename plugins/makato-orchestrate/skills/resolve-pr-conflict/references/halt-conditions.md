# HALT Conditions — resolve-pr-conflict

## HALT-008: Irreconcilable Conflict

**Dual-origin triggers** — fires on either of two independent paths:

| Origin | Condition | Notes |
|---|---|---|
| Strategy exhaustion | Both rebase (Step 3) AND partitioned merge (Step 4) leave `git diff --diff-filter=U` non-empty | The union pass already ran on append-only files; remaining unresolved paths contain semantic conflicts that require human judgment |
| Cycle ceiling | Post-increment `merge_conflict_cycles >= MAKATO_MAX_MERGE_CONFLICT_CYCLES` (default 3) | The PO-agent outer loop re-dispatches this skill on retry; ceiling prevents infinite re-dispatch loops |

The two origins are independent: a run can trigger HALT-008 from strategy exhaustion on the first attempt (cycles=1 < 3) or from the cycle ceiling even if the merge would have been clean (rare race where a concurrent PR merges between retries).

**State mutations on HALT-008:**
1. `merge_conflict_cycles` incremented in workflow-state
2. `worktree_retained = true`, `worktree_retain_reason = "merge_conflict"` — worktree survives for human inspection
3. `needs-human-review` label applied to issue
4. `post-halt-comment.sh HALT-008` posts structured comment (best-effort)
5. Lesson appended to workflow-state

**Recovery:** Human resolves conflict in retained worktree, re-pushes branch, re-triggers PO-agent loop.

---

## SAFETY_BOUNDARY

**Trigger:** Branch is `main`, `master`, or `development`.

Force-pushing protected branches rewrites shared history and breaks all open PRs targeting them. The deny-list covers all three common default-branch names regardless of which one is selected as the rebase target. No recovery — check out a feature branch first.

---

## NETWORK_ERROR

**Trigger:** `git fetch origin <target>` fails OR neither `origin/development` nor `origin/main` exists on remote.

**Recovery:** Verify network / GitHub access; confirm the consumer repo's default branch is `development` or `main`; retry.

---

## PUSH_REJECTED

**Trigger:** `git push --force-with-lease` is refused (remote has commits not in the local ref).

Someone pushed to the PR branch concurrently. `--force-with-lease` correctly blocked the overwrite.

**Recovery:** Fetch and inspect remote changes; re-run skill. If the remote commits are the resolution itself (double-dispatch), the skill is idempotent — the worktree will rebase cleanly on re-run.
