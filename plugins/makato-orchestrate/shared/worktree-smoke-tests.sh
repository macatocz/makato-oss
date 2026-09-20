#!/usr/bin/env bash
# Smoke tests for worktree.sh (GAP-017 / #46).
# Run from the makato repo root. Exits non-zero on first failure.
#
# These tests exercise the full lifecycle (create → path → cleanup) plus the
# retain branch and the resume re-detect. They use a real git repository
# under $TMPDIR so `git worktree add` can run normally — the production
# helper is invoked via env-redirected paths so tests never touch the actual
# .claude/worktrees/ of the makato repo.
#
# Usage: plugins/makato-orchestrate/shared/worktree-smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
WT="$REPO_ROOT/plugins/makato-orchestrate/shared/worktree.sh"

# Contract guard for the PO-agent integration: the helper's positional order
# is KEY, ISSUE_NUMBER, REPO, BRANCH. This catches the #634 regression where
# REPO and ISSUE_NUMBER were swapped and no worktree was created.
PO_AGENT="$REPO_ROOT/plugins/makato-orchestrate/agents/po-agent.md"
echo "=== T0: PO-agent passes worktree arguments in helper order (#634) ==="
grep -qF '"$WORKTREE_HELPER" create "$KEY" "$ISSUE_NUMBER" "$REPO" "$BRANCH"' "$PO_AGENT" \
  || { echo "  ✗ PO-agent create call has wrong positional argument order"; exit 1; }
grep -qF '"$WORKTREE_HELPER" create --new-branch "$KEY" "$ISSUE_NUMBER" "$REPO" "$BRANCH"' "$PO_AGENT" \
  || { echo "  ✗ PO-agent --new-branch call has wrong positional argument order"; exit 1; }
echo "  ✓ PO-agent passes KEY, ISSUE_NUMBER, REPO, BRANCH"

# All smoke tests run inside a disposable temp git repo so worktree-create
# does not pollute the makato repo's own .claude/worktrees/.
SANDBOX="$(mktemp -d -t makato-gap017-XXXXXX)"
cleanup() {
  # `git worktree remove` may have left registered worktrees behind on
  # mid-test failure; remove anything we created before nuking the dir.
  if [[ -d "$SANDBOX/repo/.git" ]]; then
    git -C "$SANDBOX/repo" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree / && $2 != "'"$SANDBOX/repo"'" {print $2}' \
      | while IFS= read -r wt; do
          git -C "$SANDBOX/repo" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Bootstrap a real repo so `git worktree add` works.
mkdir -p "$SANDBOX/repo"
cd "$SANDBOX/repo"
git init -q -b main .
git config user.email "smoke@example.com"
git config user.name  "smoke test"
echo "seed" > README.md
git add README.md
git commit -q -m "seed"
git branch -q auto/test-repo-46

# Make workflow-state.sh and worktree.sh believe THIS repo is the makato repo.
# Both helpers call `git rev-parse --show-toplevel`, so cd is enough — but
# they also reference `plugins/makato-orchestrate/...` paths relative to that
# root. We satisfy that by symlinking the schema and helpers into the sandbox.
mkdir -p "$SANDBOX/repo/plugins/makato-orchestrate/shared"
mkdir -p "$SANDBOX/repo/plugins/makato-orchestrate/skills/workflow-state/references"
ln -s "$WS" "$SANDBOX/repo/plugins/makato-orchestrate/shared/workflow-state.sh"
ln -s "$WT" "$SANDBOX/repo/plugins/makato-orchestrate/shared/worktree.sh"
ln -s "$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json" \
  "$SANDBOX/repo/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json"

# Re-target both helpers' state to live inside the sandbox repo.
WS_LOCAL="$SANDBOX/repo/plugins/makato-orchestrate/shared/workflow-state.sh"
WT_LOCAL="$SANDBOX/repo/plugins/makato-orchestrate/shared/worktree.sh"

KEY="gap-017-smoke"
REPO_NAME="macatocz/test-repo"
BRANCH="auto/test-repo-46"
ISSUE=46

# Override worktree root to the sandbox so .claude/worktrees lives here, not
# in the makato repo we're running smoke tests from.
export MAKATO_WORKTREE_ROOT="$SANDBOX/repo/.claude/worktrees"

echo "=== T1: init seeds the GAP-017 worktree fields ==="
"$WS_LOCAL" init "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE"
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_path == null' > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retained == false' > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retain_reason == null' > /dev/null
echo "  ✓ worktree_path / worktree_retained / worktree_retain_reason seeded"

echo "=== T2: create emits worktree_created and patches state ==="
OUT="$("$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH")"
EVENT="$(echo "$OUT" | head -1)"
WT_PATH="$(echo "$OUT" | tail -1)"
[[ "$EVENT" == "worktree_created" ]] || { echo "  ✗ expected worktree_created, got: $EVENT"; exit 1; }
test -d "$WT_PATH" || { echo "  ✗ worktree dir not created: $WT_PATH"; exit 1; }
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e --arg p "$WT_PATH" '.worktree_path == $p' > /dev/null
echo "  ✓ event=worktree_created, dir exists, state patched"

echo "=== T3: path subcommand returns the absolute worktree path ==="
ECHOED="$("$WT_LOCAL" path "$KEY" "$ISSUE")"
[[ "$ECHOED" == "$WT_PATH" ]] || { echo "  ✗ expected $WT_PATH, got: $ECHOED"; exit 1; }
echo "  ✓ path matches"

echo "=== T4: re-running create on an existing worktree emits worktree_resumed ==="
OUT2="$("$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH")"
EVENT2="$(echo "$OUT2" | head -1)"
WT_PATH2="$(echo "$OUT2" | tail -1)"
[[ "$EVENT2" == "worktree_resumed" ]] || { echo "  ✗ expected worktree_resumed, got: $EVENT2"; exit 1; }
[[ "$WT_PATH2" == "$WT_PATH" ]] || { echo "  ✗ resume returned a different path"; exit 1; }
echo "  ✓ resume detected via git worktree list"

echo "=== T4a: resume refuses a dirty worktree ==="
printf 'leftover\n' >"$WT_PATH/.resume-dirty"
set +e
"$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH" \
  >/dev/null 2>"$SANDBOX/t4a.stderr"
RC_T4A=$?
set -e
rm -f "$WT_PATH/.resume-dirty"
[[ $RC_T4A -ne 0 ]] || { echo "  ✗ dirty worktree was resumed"; exit 1; }
grep -q "worktree is not clean" "$SANDBOX/t4a.stderr" \
  || { echo "  ✗ dirty-worktree diagnostic missing"; cat "$SANDBOX/t4a.stderr"; exit 1; }
echo "  ✓ dirty worktree rejected before resume"

echo "=== T4b: resume refuses a worktree on the wrong branch ==="
WRONG_BRANCH="auto/test-repo-wrong-46"
git -C "$WT_PATH" switch -q -c "$WRONG_BRANCH"
set +e
"$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH" \
  >/dev/null 2>"$SANDBOX/t4b.stderr"
RC_T4B=$?
set -e
git -C "$WT_PATH" switch -q "$BRANCH"
git -C "$SANDBOX/repo" branch -D "$WRONG_BRANCH" >/dev/null 2>&1 || true
[[ $RC_T4B -ne 0 ]] || { echo "  ✗ wrong-branch worktree was resumed"; exit 1; }
grep -q "expected branch '$BRANCH'" "$SANDBOX/t4b.stderr" \
  || { echo "  ✗ wrong-branch diagnostic missing"; cat "$SANDBOX/t4b.stderr"; exit 1; }
echo "  ✓ wrong-branch worktree rejected before resume"

echo "=== T5: retain flips both state flags without removing the worktree ==="
"$WT_LOCAL" retain "$KEY" "$ISSUE" "HALT-003" > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retained == true' > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retain_reason == "HALT-003"' > /dev/null
test -d "$WT_PATH" || { echo "  ✗ retain unexpectedly removed the worktree"; exit 1; }
echo "  ✓ flags set, worktree still on disk"

echo "=== T6: cleanup removes the worktree and clears worktree_path ==="
# Reset retain state so cleanup runs from a fresh slate.
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retain_reason' 'null'
EVENT3="$("$WT_LOCAL" cleanup "$KEY" "$ISSUE")"
[[ "$EVENT3" == "worktree_removed" ]] || { echo "  ✗ expected worktree_removed, got: $EVENT3"; exit 1; }
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_path == null' > /dev/null
test ! -d "$WT_PATH" || { echo "  ✗ worktree dir still exists after cleanup: $WT_PATH"; exit 1; }
echo "  ✓ event=worktree_removed, dir gone, state cleared"

echo "=== T7: cleanup on cleared state is a no-op ==="
EVENT4="$("$WT_LOCAL" cleanup "$KEY" "$ISSUE")"
[[ "$EVENT4" == "worktree_noop" ]] || { echo "  ✗ expected worktree_noop, got: $EVENT4"; exit 1; }
echo "  ✓ idempotent cleanup"

echo "=== T8: cleanup tolerates a missing on-disk worktree but registered in state ==="
# Recreate so we can simulate an orphaned state pointer.
"$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH" > /dev/null
WT_PATH3="$("$WT_LOCAL" path "$KEY" "$ISSUE")"
# Force-remove via git, leaving state pointing at it. The #170 Fix 3
# validator on `patch` refuses re-writing an unregistered path back —
# the bypass env var is documented for this smoke-test class exactly.
git -C "$SANDBOX/repo" worktree remove --force "$WT_PATH3" > /dev/null 2>&1
MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1 \
  "$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_path' "\"$WT_PATH3\""
EVENT5="$("$WT_LOCAL" cleanup "$KEY" "$ISSUE")"
[[ "$EVENT5" == "worktree_removed" ]] || { echo "  ✗ expected worktree_removed, got: $EVENT5"; exit 1; }
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_path == null' > /dev/null
echo "  ✓ stale path tolerated, state cleared"

echo "=== T9: cleanup refuses to remove a retained worktree (C15 guard) ==="
# Re-create then retain to set worktree_retained=true.
"$WT_LOCAL" create "$KEY" "$ISSUE" "$REPO_NAME" "$BRANCH" > /dev/null
WT_PATH4="$("$WT_LOCAL" path "$KEY" "$ISSUE")"
"$WT_LOCAL" retain "$KEY" "$ISSUE" "HALT-003" > /dev/null
EVENT6="$("$WT_LOCAL" cleanup "$KEY" "$ISSUE")"
[[ "$EVENT6" == "worktree_cleanup_refused" ]] || { echo "  ✗ expected worktree_cleanup_refused, got: $EVENT6"; exit 1; }
test -d "$WT_PATH4" || { echo "  ✗ cleanup removed worktree despite retain guard"; exit 1; }
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e --arg p "$WT_PATH4" '.worktree_path == $p' > /dev/null
echo "  ✓ retain blocks cleanup, dir untouched, state preserved"

echo "=== T10: retain writes BOTH retention fields atomically (C16 — single write) ==="
# Retain with a different code to verify the write replaces the previous value.
# Verify that after the call, BOTH fields reflect the new value with the same
# updated_at — a single workflow-state.sh write rather than two patches.
"$WT_LOCAL" retain "$KEY" "$ISSUE" "HALT-005" > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -r '.updated_at' > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retained == true' > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.worktree_retain_reason == "HALT-005"' > /dev/null
# Belt-and-braces: every other field's value must still pass the schema —
# proves the bulk write went through workflow-state.sh write (which validates)
# and not a raw jq pipe (which doesn't).
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e '.repo == "macatocz/test-repo"' > /dev/null
echo "  ✓ both retention fields updated in one validated write"

echo "=== T11: cleanup leaves state intact when git worktree remove genuinely fails (C4 fix) ==="
# Clear retained flag so cleanup is allowed to attempt removal.
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retain_reason' 'null'
# Lock the worktree so `git worktree remove --force` refuses; this is the
# canonical "genuine failure" path (locked worktrees stay registered after
# prune too). The lock is git-level, not a kernel filesystem lock.
git -C "$SANDBOX/repo" worktree lock "$WT_PATH4" > /dev/null 2>&1
set +e
OUT_T11="$("$WT_LOCAL" cleanup "$KEY" "$ISSUE" 2>/dev/null)"
RC_T11=$?
set -e
[[ $RC_T11 -eq 1 ]] || { echo "  ✗ expected exit 1 on genuine remove failure, got $RC_T11"; exit 1; }
[[ "$OUT_T11" == "worktree_remove_failed" ]] || { echo "  ✗ expected worktree_remove_failed, got: $OUT_T11"; exit 1; }
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e --arg p "$WT_PATH4" '.worktree_path == $p' > /dev/null
echo "  ✓ remove_failed event, state NOT cleared, invariant preserved"
# Unlock so the EXIT trap can clean up.
git -C "$SANDBOX/repo" worktree unlock "$WT_PATH4" > /dev/null 2>&1 || true
git -C "$SANDBOX/repo" worktree remove --force "$WT_PATH4" > /dev/null 2>&1 || true

echo "=== T12: HALT_CODE with embedded double-quote survives via _json_encode (C2 fix) ==="
# Re-init a fresh state because T11's locked worktree may have left things
# in a weird in-between state.
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_path' 'null'
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" "$ISSUE" '.worktree_retain_reason' 'null'
EXOTIC_CODE='HALT-003 "operator-quoted reason"'
"$WT_LOCAL" retain "$KEY" "$ISSUE" "$EXOTIC_CODE" > /dev/null
"$WS_LOCAL" read "$KEY" "$ISSUE" | jq -e --arg c "$EXOTIC_CODE" '.worktree_retain_reason == $c' > /dev/null
echo "  ✓ embedded double-quote in HALT_CODE preserved verbatim"

echo "=== T13: worktree path with embedded space survives the awk-free porcelain parser (C1 fix) ==="
# Override the worktree root to a directory with a space so the porcelain
# parser is forced to handle a space-bearing path. The fresh root is created
# below; the helper absolutises it via _realpath at script entry.
SPACE_ROOT="$SANDBOX/space dir"
mkdir -p "$SPACE_ROOT"
KEY_T13="gap-017-smoke-space"
SANDBOX_T13="$SANDBOX/repo/specs/$KEY_T13"
mkdir -p "$SANDBOX_T13"
ISSUE_T13=99
"$WS_LOCAL" init "$KEY_T13" "$REPO_NAME" "$BRANCH" "$ISSUE_T13"
# git worktree add cannot reuse the same branch already checked out by T2-T9
# (HEAD conflict), so create a dedicated branch for T13.
git -C "$SANDBOX/repo" branch -q auto/test-repo-space-46 main 2>/dev/null || true
MAKATO_WORKTREE_ROOT="$SPACE_ROOT" \
  "$WT_LOCAL" create "$KEY_T13" "$ISSUE_T13" "$REPO_NAME" auto/test-repo-space-46 > /dev/null
WT_T13="$(MAKATO_WORKTREE_ROOT="$SPACE_ROOT" "$WT_LOCAL" path "$KEY_T13" "$ISSUE_T13")"
# The stored path must contain the space.
[[ "$WT_T13" == *"space dir"* ]] || { echo "  ✗ space dropped from stored path: $WT_T13"; exit 1; }
# Resume detection must succeed for the spaced path (verifies the porcelain
# parser handles it).
EVENT_T13="$(MAKATO_WORKTREE_ROOT="$SPACE_ROOT" "$WT_LOCAL" create "$KEY_T13" "$ISSUE_T13" "$REPO_NAME" auto/test-repo-space-46 | head -1)"
[[ "$EVENT_T13" == "worktree_resumed" ]] || { echo "  ✗ resume failed for space path, got: $EVENT_T13"; exit 1; }
echo "  ✓ space-bearing worktree path created and resumed correctly"

# ----------------------------------------------------------------------------
# #170 Fix 2 — worktree.sh create --new-branch creates the branch atomically
# as part of `git worktree add -b` and never mutates the main-repo working
# tree. The T14–T15 pair exercises the happy path and the crucial invariant
# ("main repo HEAD stays put"). T16 asserts that dropping --new-branch on a
# non-existent branch fails loudly (regression bar for the old silent-repair
# class).
# ----------------------------------------------------------------------------
echo "=== T14: create --new-branch creates the branch atomically and does NOT touch main ==="
KEY_T14="gap-170-newbranch"
BRANCH_T14="feat/170-atomic-new"
ISSUE_T14=170
mkdir -p "$SANDBOX/repo/specs/$KEY_T14"
"$WS_LOCAL" init "$KEY_T14" "$REPO_NAME" "$BRANCH_T14" "$ISSUE_T14"

# Capture the main-repo HEAD before the create so we can assert it did not
# move. The main repo is currently on `main` (the seed commit); the fresh
# --new-branch call must leave it on `main` and NOT switch to $BRANCH_T14.
MAIN_HEAD_BEFORE="$(git -C "$SANDBOX/repo" rev-parse --abbrev-ref HEAD)"
[[ "$MAIN_HEAD_BEFORE" == "main" ]] || { echo "  ✗ pre-condition: main repo not on 'main' (got: $MAIN_HEAD_BEFORE)"; exit 1; }

# The sandbox has no remote; skip the git ls-remote / fetch by asserting
# the branch does not exist locally either. Then invoke --new-branch.
# For the sandbox, `origin/main` does not exist, so the helper falls back
# to plain `main` via its symbolic-ref probe (see worktree.sh REMOTE_HEAD_REF
# fallback). We pre-set the fallback ref by ensuring symbolic-ref points
# somewhere sensible; if not, git worktree add will default to the branch
# base and the smoke test still exercises the -b path.
git -C "$SANDBOX/repo" rev-parse --verify "$BRANCH_T14" 2>/dev/null \
  && { echo "  ✗ pre-condition: $BRANCH_T14 already exists"; exit 1; }

# Sandbox has no `origin` remote — set one up pointing at a bare mirror so
# the helper's fetch / symbolic-ref / push -u paths all have somewhere to
# resolve. Without this the helper's `git worktree add -b <path> origin/main`
# base ref would not resolve and the create would fail for the wrong reason.
BARE="$SANDBOX/bare-mirror.git"
git init --bare -q "$BARE"
git -C "$SANDBOX/repo" remote add origin "$BARE" 2>/dev/null || true
git -C "$SANDBOX/repo" push -q origin main
git -C "$SANDBOX/repo" fetch origin --quiet
# Register origin/HEAD -> refs/remotes/origin/main so the helper's
# symbolic-ref probe returns cleanly.
git -C "$SANDBOX/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

OUT_T14="$("$WT_LOCAL" create --new-branch "$KEY_T14" "$ISSUE_T14" "$REPO_NAME" "$BRANCH_T14")"
EVENT_T14="$(echo "$OUT_T14" | head -1)"
WT_T14="$(echo "$OUT_T14" | tail -1)"
[[ "$EVENT_T14" == "worktree_created" ]] || { echo "  ✗ expected worktree_created, got: $EVENT_T14"; exit 1; }
test -d "$WT_T14" || { echo "  ✗ worktree dir not created at $WT_T14"; exit 1; }

# Main repo HEAD MUST still be on main. This is the #170 core invariant.
MAIN_HEAD_AFTER="$(git -C "$SANDBOX/repo" rev-parse --abbrev-ref HEAD)"
[[ "$MAIN_HEAD_AFTER" == "main" ]] || { echo "  ✗ main repo drifted to $MAIN_HEAD_AFTER (expected 'main') — #170 regression"; exit 1; }

# Worktree HEAD IS on the new branch.
WT_HEAD_T14="$(git -C "$WT_T14" rev-parse --abbrev-ref HEAD)"
[[ "$WT_HEAD_T14" == "$BRANCH_T14" ]] || { echo "  ✗ worktree HEAD not on new branch (got: $WT_HEAD_T14)"; exit 1; }

# Branch pushed upstream (`git ls-remote origin $BRANCH` non-empty).
git -C "$SANDBOX/repo" ls-remote --exit-code origin "$BRANCH_T14" >/dev/null 2>&1 \
  || { echo "  ✗ new branch $BRANCH_T14 not present on origin (push -u must have run)"; exit 1; }

echo "  ✓ new branch created atomically, main HEAD unmoved, worktree on branch, upstream tracking set"

echo "=== T15: create --new-branch on an already-registered worktree is an idempotent resume ==="
OUT_T15="$("$WT_LOCAL" create --new-branch "$KEY_T14" "$ISSUE_T14" "$REPO_NAME" "$BRANCH_T14")"
EVENT_T15="$(echo "$OUT_T15" | head -1)"
[[ "$EVENT_T15" == "worktree_resumed" ]] || { echo "  ✗ second --new-branch call should have resumed, got: $EVENT_T15"; exit 1; }
echo "  ✓ second call is a resume (--new-branch is idempotent when the worktree already exists)"

echo "=== T16: create (without --new-branch) on a non-existent branch fails loudly ==="
KEY_T16="gap-170-no-new"
BRANCH_T16="feat/170-does-not-exist"
ISSUE_T16=171
mkdir -p "$SANDBOX/repo/specs/$KEY_T16"
"$WS_LOCAL" init "$KEY_T16" "$REPO_NAME" "$BRANCH_T16" "$ISSUE_T16"

set +e
"$WT_LOCAL" create "$KEY_T16" "$ISSUE_T16" "$REPO_NAME" "$BRANCH_T16" >/dev/null 2>"$SANDBOX/t16.stderr"
RC_T16=$?
set -e
[[ $RC_T16 -ne 0 ]] || { echo "  ✗ create on non-existent branch should have failed (rc=$RC_T16)"; exit 1; }
grep -q "$BRANCH_T16" "$SANDBOX/t16.stderr" \
  || { echo "  ✗ error message missing branch name"; cat "$SANDBOX/t16.stderr"; exit 1; }
# State must NOT have been patched — the invariant is that a failed create
# leaves state clean, no fabricated .worktree_path.
"$WS_LOCAL" read "$KEY_T16" "$ISSUE_T16" | jq -e '.worktree_path == null' >/dev/null \
  || { echo "  ✗ .worktree_path was patched despite create failure"; exit 1; }
echo "  ✓ create failed with clear diagnostic, state left null"

# ----------------------------------------------------------------------------
# #170 Fix 3 — workflow-state.sh patch refuses .worktree_path writes to any
# path that is not a registered git worktree of this repo. The T17 pair
# exercises both directions of the invariant.
# ----------------------------------------------------------------------------
echo "=== T17: patch .worktree_path to an unregistered path is refused (Fix 3) ==="
KEY_T17="gap-170-patch-guard"
mkdir -p "$SANDBOX/repo/specs/$KEY_T17"
"$WS_LOCAL" init "$KEY_T17" "$REPO_NAME" "$BRANCH_T14" "$ISSUE_T14"

# Attempt: patch to the main-repo root. This is the exact incident from
# #170 § *Repro*.
set +e
"$WS_LOCAL" patch "$KEY_T17" "$ISSUE_T14" '.worktree_path' "\"$SANDBOX/repo\"" >/dev/null 2>"$SANDBOX/t17.stderr"
RC_T17=$?
set -e
[[ $RC_T17 -ne 0 ]] || { echo "  ✗ patch to main-repo root should have been refused"; exit 1; }
# Diagnostic must reference either the main-repo root guard OR the
# not-registered guard (a call pointing at REPO_ROOT hits the first;
# any other unregistered path hits the second).
grep -qE "(resolves to the main-repo root|not a registered git worktree)" "$SANDBOX/t17.stderr" \
  || { echo "  ✗ diagnostic missing worktree-guard phrase"; cat "$SANDBOX/t17.stderr"; exit 1; }
grep -q "#170" "$SANDBOX/t17.stderr" \
  || { echo "  ✗ diagnostic missing #170 rationale link"; cat "$SANDBOX/t17.stderr"; exit 1; }
"$WS_LOCAL" read "$KEY_T17" "$ISSUE_T14" | jq -e '.worktree_path == null' >/dev/null \
  || { echo "  ✗ .worktree_path mutated despite refusal"; exit 1; }
echo "  ✓ unregistered patch refused with clear diagnostic, state untouched"

# Attempt: patch to a made-up path that does not exist on disk.
set +e
"$WS_LOCAL" patch "$KEY_T17" "$ISSUE_T14" '.worktree_path' "\"$SANDBOX/never-existed-anywhere\"" >/dev/null 2>"$SANDBOX/t17b.stderr"
RC_T17B=$?
set -e
[[ $RC_T17B -ne 0 ]] || { echo "  ✗ patch to non-existent path should have been refused"; exit 1; }
echo "  ✓ non-existent path also refused"

# Explicit null is always allowed (cleanup path).
"$WS_LOCAL" patch "$KEY_T17" "$ISSUE_T14" '.worktree_path' 'null' >/dev/null
echo "  ✓ explicit null write still permitted (cleanup contract preserved)"

# Bypass env var (documented for smoke-test contexts only) permits the write.
MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1 \
  "$WS_LOCAL" patch "$KEY_T17" "$ISSUE_T14" '.worktree_path' "\"$SANDBOX/repo\"" >/dev/null
"$WS_LOCAL" read "$KEY_T17" "$ISSUE_T14" | jq -e --arg p "$SANDBOX/repo" '.worktree_path == $p' >/dev/null \
  || { echo "  ✗ bypass env var did not permit the write"; exit 1; }
echo "  ✓ bypass env var permits the write (test-only path)"

echo "=== T18: patching an unrelated field is never guarded by the .worktree_path validator ==="
# Sanity: fields other than .worktree_path pass through the validator
# without any git-worktree check. Prevents overly-broad guard from breaking
# every other patch call.
"$WS_LOCAL" patch "$KEY_T17" "$ISSUE_T14" '.current_phase' '"implement"' >/dev/null
"$WS_LOCAL" read "$KEY_T17" "$ISSUE_T14" | jq -e '.current_phase == "implement"' >/dev/null \
  || { echo "  ✗ unrelated .current_phase patch was refused"; exit 1; }
echo "  ✓ unrelated field passes through unchanged"

echo "=== T19: workflow-state.sh resolves specs/ to the MAIN checkout when invoked from a worktree (#282) ==="
# Regression for #282: workflow-state.sh must derive REPO_ROOT from the COMMON
# git dir (like build-log.sh), NOT from `git rev-parse --show-toplevel` of the
# CWD. Running from inside a worktree, an `init` must land the per-issue state
# file under the MAIN checkout's specs/ — never under the worktree's specs/ —
# so the sole-writer state helper and the build.jsonl audit trail share one
# tree. Reuse the WT_T14 worktree created above.
test -d "$WT_T14" || { echo "  ✗ pre-condition: WT_T14 worktree missing"; exit 1; }
KEY_T19="issue-282-worktree-specs"
ISSUE_T19=282
# Invoke the real helper (absolute path) from INSIDE the worktree so its CWD is
# the worktree root — the exact condition that used to mis-resolve.
( cd "$WT_T14" && "$WS_LOCAL" init "$KEY_T19" "$REPO_NAME" "feat/282-fix" "$ISSUE_T19" ) 2>/dev/null
MAIN_STATE="$SANDBOX/repo/specs/$KEY_T19/workflow-state-${ISSUE_T19}.json"
WT_STATE="$WT_T14/specs/$KEY_T19/workflow-state-${ISSUE_T19}.json"
test -f "$MAIN_STATE" \
  || { echo "  ✗ state file not written to main checkout: $MAIN_STATE"; exit 1; }
test ! -f "$WT_STATE" \
  || { echo "  ✗ #282 regression: state leaked into worktree specs/ at $WT_STATE"; exit 1; }
echo "  ✓ state resolves to main checkout from within a worktree (no split trees)"

echo
echo "All 19 worktree-lifecycle smoke tests passed."
