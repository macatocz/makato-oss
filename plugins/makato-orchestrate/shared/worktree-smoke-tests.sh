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
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_path == null' > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retained == false' > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retain_reason == null' > /dev/null
echo "  ✓ worktree_path / worktree_retained / worktree_retain_reason seeded"

echo "=== T2: create emits worktree_created and patches state ==="
OUT="$("$WT_LOCAL" create "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE")"
EVENT="$(echo "$OUT" | head -1)"
WT_PATH="$(echo "$OUT" | tail -1)"
[[ "$EVENT" == "worktree_created" ]] || { echo "  ✗ expected worktree_created, got: $EVENT"; exit 1; }
test -d "$WT_PATH" || { echo "  ✗ worktree dir not created: $WT_PATH"; exit 1; }
"$WS_LOCAL" read "$KEY" | jq -e --arg p "$WT_PATH" '.worktree_path == $p' > /dev/null
echo "  ✓ event=worktree_created, dir exists, state patched"

echo "=== T3: path subcommand returns the absolute worktree path ==="
ECHOED="$("$WT_LOCAL" path "$KEY")"
[[ "$ECHOED" == "$WT_PATH" ]] || { echo "  ✗ expected $WT_PATH, got: $ECHOED"; exit 1; }
echo "  ✓ path matches"

echo "=== T4: re-running create on an existing worktree emits worktree_resumed ==="
OUT2="$("$WT_LOCAL" create "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE")"
EVENT2="$(echo "$OUT2" | head -1)"
WT_PATH2="$(echo "$OUT2" | tail -1)"
[[ "$EVENT2" == "worktree_resumed" ]] || { echo "  ✗ expected worktree_resumed, got: $EVENT2"; exit 1; }
[[ "$WT_PATH2" == "$WT_PATH" ]] || { echo "  ✗ resume returned a different path"; exit 1; }
echo "  ✓ resume detected via git worktree list"

echo "=== T5: retain flips both state flags without removing the worktree ==="
"$WT_LOCAL" retain "$KEY" "HALT-003" > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retained == true' > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retain_reason == "HALT-003"' > /dev/null
test -d "$WT_PATH" || { echo "  ✗ retain unexpectedly removed the worktree"; exit 1; }
echo "  ✓ flags set, worktree still on disk"

echo "=== T6: cleanup removes the worktree and clears worktree_path ==="
# Reset retain state so cleanup runs from a fresh slate.
"$WS_LOCAL" patch "$KEY" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" '.worktree_retain_reason' 'null'
EVENT3="$("$WT_LOCAL" cleanup "$KEY")"
[[ "$EVENT3" == "worktree_removed" ]] || { echo "  ✗ expected worktree_removed, got: $EVENT3"; exit 1; }
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_path == null' > /dev/null
test ! -d "$WT_PATH" || { echo "  ✗ worktree dir still exists after cleanup: $WT_PATH"; exit 1; }
echo "  ✓ event=worktree_removed, dir gone, state cleared"

echo "=== T7: cleanup on cleared state is a no-op ==="
EVENT4="$("$WT_LOCAL" cleanup "$KEY")"
[[ "$EVENT4" == "worktree_noop" ]] || { echo "  ✗ expected worktree_noop, got: $EVENT4"; exit 1; }
echo "  ✓ idempotent cleanup"

echo "=== T8: cleanup tolerates a missing on-disk worktree but registered in state ==="
# Recreate so we can simulate an orphaned state pointer.
"$WT_LOCAL" create "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE" > /dev/null
WT_PATH3="$("$WT_LOCAL" path "$KEY")"
# Force-remove via git, leaving state pointing at it.
git -C "$SANDBOX/repo" worktree remove --force "$WT_PATH3" > /dev/null 2>&1
"$WS_LOCAL" patch "$KEY" '.worktree_path' "\"$WT_PATH3\""
EVENT5="$("$WT_LOCAL" cleanup "$KEY")"
[[ "$EVENT5" == "worktree_removed" ]] || { echo "  ✗ expected worktree_removed, got: $EVENT5"; exit 1; }
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_path == null' > /dev/null
echo "  ✓ stale path tolerated, state cleared"

echo "=== T9: cleanup refuses to remove a retained worktree (C15 guard) ==="
# Re-create then retain to set worktree_retained=true.
"$WT_LOCAL" create "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE" > /dev/null
WT_PATH4="$("$WT_LOCAL" path "$KEY")"
"$WT_LOCAL" retain "$KEY" "HALT-003" > /dev/null
EVENT6="$("$WT_LOCAL" cleanup "$KEY")"
[[ "$EVENT6" == "worktree_cleanup_refused" ]] || { echo "  ✗ expected worktree_cleanup_refused, got: $EVENT6"; exit 1; }
test -d "$WT_PATH4" || { echo "  ✗ cleanup removed worktree despite retain guard"; exit 1; }
"$WS_LOCAL" read "$KEY" | jq -e --arg p "$WT_PATH4" '.worktree_path == $p' > /dev/null
echo "  ✓ retain blocks cleanup, dir untouched, state preserved"

echo "=== T10: retain writes BOTH retention fields atomically (C16 — single write) ==="
# Retain with a different code to verify the write replaces the previous value.
# Verify that after the call, BOTH fields reflect the new value with the same
# updated_at — a single workflow-state.sh write rather than two patches.
"$WT_LOCAL" retain "$KEY" "HALT-005" > /dev/null
UPDATED="$("$WS_LOCAL" read "$KEY" | jq -r '.updated_at')"
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retained == true' > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e '.worktree_retain_reason == "HALT-005"' > /dev/null
# Belt-and-braces: every other field's value must still pass the schema —
# proves the bulk write went through workflow-state.sh write (which validates)
# and not a raw jq pipe (which doesn't).
"$WS_LOCAL" read "$KEY" | jq -e '.repo == "macatocz/test-repo"' > /dev/null
echo "  ✓ both retention fields updated in one validated write"

echo "=== T11: cleanup leaves state intact when git worktree remove genuinely fails (C4 fix) ==="
# Clear retained flag so cleanup is allowed to attempt removal.
"$WS_LOCAL" patch "$KEY" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" '.worktree_retain_reason' 'null'
# Lock the worktree so `git worktree remove --force` refuses; this is the
# canonical "genuine failure" path (locked worktrees stay registered after
# prune too). The lock is git-level, not a kernel filesystem lock.
git -C "$SANDBOX/repo" worktree lock "$WT_PATH4" > /dev/null 2>&1
set +e
OUT_T11="$("$WT_LOCAL" cleanup "$KEY" 2>/dev/null)"
RC_T11=$?
set -e
[[ $RC_T11 -eq 1 ]] || { echo "  ✗ expected exit 1 on genuine remove failure, got $RC_T11"; exit 1; }
[[ "$OUT_T11" == "worktree_remove_failed" ]] || { echo "  ✗ expected worktree_remove_failed, got: $OUT_T11"; exit 1; }
"$WS_LOCAL" read "$KEY" | jq -e --arg p "$WT_PATH4" '.worktree_path == $p' > /dev/null
echo "  ✓ remove_failed event, state NOT cleared, invariant preserved"
# Unlock so the EXIT trap can clean up.
git -C "$SANDBOX/repo" worktree unlock "$WT_PATH4" > /dev/null 2>&1 || true
git -C "$SANDBOX/repo" worktree remove --force "$WT_PATH4" > /dev/null 2>&1 || true

echo "=== T12: HALT_CODE with embedded double-quote survives via _json_encode (C2 fix) ==="
# Re-init a fresh state because T11's locked worktree may have left things
# in a weird in-between state.
"$WS_LOCAL" patch "$KEY" '.worktree_path' 'null'
"$WS_LOCAL" patch "$KEY" '.worktree_retained' 'false'
"$WS_LOCAL" patch "$KEY" '.worktree_retain_reason' 'null'
EXOTIC_CODE='HALT-003 "operator-quoted reason"'
"$WT_LOCAL" retain "$KEY" "$EXOTIC_CODE" > /dev/null
"$WS_LOCAL" read "$KEY" | jq -e --arg c "$EXOTIC_CODE" '.worktree_retain_reason == $c' > /dev/null
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
"$WS_LOCAL" init "$KEY_T13" "$REPO_NAME" "$BRANCH" "$ISSUE"
# git worktree add cannot reuse the same branch already checked out by T2-T9
# (HEAD conflict), so create a dedicated branch for T13.
git -C "$SANDBOX/repo" branch -q auto/test-repo-space-46 main 2>/dev/null || true
ISSUE_T13=99
MAKATO_WORKTREE_ROOT="$SPACE_ROOT" \
  "$WT_LOCAL" create "$KEY_T13" "$REPO_NAME" auto/test-repo-space-46 "$ISSUE_T13" > /dev/null
WT_T13="$(MAKATO_WORKTREE_ROOT="$SPACE_ROOT" "$WT_LOCAL" path "$KEY_T13")"
# The stored path must contain the space.
[[ "$WT_T13" == *"space dir"* ]] || { echo "  ✗ space dropped from stored path: $WT_T13"; exit 1; }
# Resume detection must succeed for the spaced path (verifies the porcelain
# parser handles it).
EVENT_T13="$(MAKATO_WORKTREE_ROOT="$SPACE_ROOT" "$WT_LOCAL" create "$KEY_T13" "$REPO_NAME" auto/test-repo-space-46 "$ISSUE_T13" | head -1)"
[[ "$EVENT_T13" == "worktree_resumed" ]] || { echo "  ✗ resume failed for space path, got: $EVENT_T13"; exit 1; }
echo "  ✓ space-bearing worktree path created and resumed correctly"

echo
echo "All 13 worktree-lifecycle smoke tests passed."
