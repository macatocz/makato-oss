#!/usr/bin/env bash
# Smoke tests for shared/progress-comment.sh. Run from the makato repo root.
# Fully offline: gh is stubbed via MAKATO_PC_GH_STUB (a scratch dir backing
# fake comments as files); workflow-state.sh runs for real against a sandbox
# spec folder under specs/ (gitignored). Cleans up on exit.
#
# Usage: plugins/makato-orchestrate/shared/progress-comment-smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PC="$REPO_ROOT/plugins/makato-orchestrate/shared/progress-comment.sh"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

KEY="progress-comment-smoke"
REPO="macatocz/test"
ISSUE=999
SANDBOX="$REPO_ROOT/specs/${KEY}"
GH_STUB="$(mktemp -d)"
export MAKATO_PC_GH_STUB="$GH_STUB"

cleanup() { rm -rf "$SANDBOX" "$GH_STUB"; [[ -z "${ROOT_CASE_TMP:-}" ]] || rm -rf "$ROOT_CASE_TMP"; }
trap cleanup EXIT
cleanup 2>/dev/null || true
mkdir -p "$SANDBOX" "$GH_STUB"

pass=0
fail=0

# check <label> <condition-cmd...>  — passes when the command exits 0.
check() {
  local label="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  ✗ %s\n' "$label"
  fi
}

# Fresh workflow-state for each run.
"$WS" init "$KEY" "$REPO" feat/pc-smoke "$ISSUE" >/dev/null

# Convenience: id currently stored in state (empty if null).
state_id() { "$WS" read "$KEY" "$ISSUE" | jq -r '.progress_comment_id // empty'; }
# Convenience: body of the stub comment with the given id.
stub_body() { cat "$GH_STUB/comment-$1.md" 2>/dev/null || true; }

echo "=== T1: start creates the live comment + persists its id ==="
"$PC" start "$KEY" "$ISSUE" "$REPO" \
  --skill build-verify --agent "review agent" \
  --input "plan, branch feat/x" --goal "run all quality checks" >/dev/null
ID1="$(state_id)"
check "progress_comment_id persisted to state" test -n "$ID1"
check "stub comment file created" test -f "$GH_STUB/comment-$ID1.md"

echo "=== T2: header + START block present, in English, with a clock ==="
BODY="$(stub_body "$ID1")"
check "header line present"       grep -q "Autonomous progress (issue #999)" <<<"$BODY"
check "START marker present"       grep -q "START: build-verify" <<<"$BODY"
check "GOAL present"               grep -q "GOAL: run all quality checks" <<<"$BODY"
check "agent chain present"        grep -q "agent: po-agent → review agent" <<<"$BODY"
check "input present"              grep -q "input: plan, branch feat/x" <<<"$BODY"
check "entry starts with HH:MM:SS clock" grep -qE '^- [0-9]{2}:[0-9]{2}:[0-9]{2} \| START' <<<"$BODY"

echo "=== T3: done EDITS the same comment (no new comment) ==="
"$PC" "done" "$KEY" "$ISSUE" "$REPO" \
  --skill build-verify --result "all passed" --summary "quality verified" >/dev/null
ID2="$(state_id)"
check "comment id unchanged after done" test "$ID1" = "$ID2"
BODY="$(stub_body "$ID1")"
check "DONE marker appended"       grep -q "DONE: build-verify" <<<"$BODY"
check "result present"             grep -q "result: all passed" <<<"$BODY"
check "summary present"            grep -q "summary: quality verified" <<<"$BODY"
check "START still present (append, not replace)" grep -q "START: build-verify" <<<"$BODY"
NUM_FILES=$(find "$GH_STUB" -name 'comment-*.md' | wc -l | tr -d ' ')
check "exactly one comment file exists" test "$NUM_FILES" = "1"

echo "=== T4: note appends a free-form timestamped line ==="
"$PC" note "$KEY" "$ISSUE" "$REPO" --text "Autonomous run started for issue #999" >/dev/null
BODY="$(stub_body "$ID1")"
check "note text present"          grep -q "Autonomous run started for issue #999" <<<"$BODY"
check "note line starts with clock" grep -qE '^- [0-9]{2}:[0-9]{2}:[0-9]{2} \| Autonomous' <<<"$BODY"

echo "=== T5: best-effort — gh failure never fails the caller (exit 0) ==="
set +e
MAKATO_PC_GH_FAIL=1 "$PC" start "$KEY" "$ISSUE" "$REPO" \
  --skill build-implement-tdd --goal "write code" >/dev/null 2>&1
RC=$?
set -e
check "exit 0 despite gh failure" test "$RC" -eq 0

echo "=== T6: refetch failure falls back to a fresh follow-up comment ==="
# Point state at a non-existent comment id → _gh_get_body fails → fallback create.
"$WS" patch "$KEY" "$ISSUE" .progress_comment_id 424242 >/dev/null
"$PC" "done" "$KEY" "$ISSUE" "$REPO" \
  --skill build-push-to-git --result "pushed" --summary "changes saved" >/dev/null
NEW_ID="$(state_id)"
check "fell back to a new comment id" test "$NEW_ID" != "424242"
check "fallback comment file exists"  test -f "$GH_STUB/comment-$NEW_ID.md"
check "fallback carries the DONE entry" grep -q "DONE: build-push-to-git" "$GH_STUB/comment-$NEW_ID.md"

echo "=== T7: rollover to a follow-up comment past MAKATO_PC_MAX_BODY ==="
# Reset to a clean live comment, then force a tiny cap so the next append rolls over.
"$WS" patch "$KEY" "$ISSUE" .progress_comment_id null >/dev/null
"$PC" start "$KEY" "$ISSUE" "$REPO" --skill build-verify --goal "kontrola" >/dev/null
ROLL_BEFORE="$(state_id)"
MAKATO_PC_MAX_BODY=10 "$PC" note "$KEY" "$ISSUE" "$REPO" --text "this overflows the tiny limit" >/dev/null
ROLL_AFTER="$(state_id)"
check "rollover created a new comment id" test "$ROLL_BEFORE" != "$ROLL_AFTER"

echo "=== T8: MAKATO_PROGRESS_COMMENT_DISABLE=1 is a silent no-op ==="
BEFORE_ID="$(state_id)"
set +e
MAKATO_PROGRESS_COMMENT_DISABLE=1 "$PC" note "$KEY" "$ISSUE" "$REPO" --text "should be ignored" >/dev/null 2>&1
RC=$?
set -e
check "disabled → exit 0" test "$RC" -eq 0
check "disabled → state id unchanged" test "$(state_id)" = "$BEFORE_ID"

echo "=== T9: unknown subcommand exits 2 ==="
set +e
"$PC" bogus "$KEY" "$ISSUE" "$REPO" >/dev/null 2>&1
RC=$?
set -e
check "unknown subcommand → exit 2" test "$RC" -eq 2

echo "=== T10: worktree-created note appears with clock ==="
# Reset to a known live comment, then fire the worktree-created setup note.
"$WS" patch "$KEY" "$ISSUE" .progress_comment_id null >/dev/null
"$PC" start "$KEY" "$ISSUE" "$REPO" --skill build-verify --goal "prime comment" >/dev/null
"$PC" note "$KEY" "$ISSUE" "$REPO" --text "Worktree ready (branch: feat/test-branch)" >/dev/null
WT_ID="$(state_id)"
WT_BODY="$(stub_body "$WT_ID")"
check "T10: worktree-ready text present"       grep -q "Worktree ready (branch: feat/test-branch)" <<<"$WT_BODY"
check "T10: note line starts with HH:MM:SS"   grep -qE '^- [0-9]{2}:[0-9]{2}:[0-9]{2} \| Worktree ready' <<<"$WT_BODY"

echo "=== T11: plan-validated note appears with clock ==="
"$PC" note "$KEY" "$ISSUE" "$REPO" --text "Plan validated — proceeding to build-refine" >/dev/null
PV_BODY="$(stub_body "$(state_id)")"
check "T11: plan-validated text present"       grep -q "Plan validated — proceeding to build-refine" <<<"$PV_BODY"
check "T11: note line starts with HH:MM:SS"   grep -qE '^- [0-9]{2}:[0-9]{2}:[0-9]{2} \| Plan validated' <<<"$PV_BODY"

echo "=== T12: comment id persists in a linked target root without WARN ==="
ROOT_CASE_TMP="$(mktemp -d)"
ROOT_CASE_MAIN="$ROOT_CASE_TMP/main"
ROOT_CASE_TARGET="$ROOT_CASE_TMP/target"
mkdir -p "$ROOT_CASE_MAIN"
git -C "$ROOT_CASE_MAIN" init -q -b main
git -C "$ROOT_CASE_MAIN" config user.email "progress-comment-test@example.com"
git -C "$ROOT_CASE_MAIN" config user.name "Progress Comment Test"
printf 'seed\n' > "$ROOT_CASE_MAIN/README.md"
git -C "$ROOT_CASE_MAIN" add README.md
git -C "$ROOT_CASE_MAIN" commit -q -m seed
git -C "$ROOT_CASE_MAIN" worktree add -q -b target "$ROOT_CASE_TARGET" HEAD
mkdir -p "$ROOT_CASE_TARGET/.claude/worktrees"
ROOT_CASE_RUN="$ROOT_CASE_TARGET/.claude/worktrees/x"
git -C "$ROOT_CASE_TARGET" worktree add -q --detach "$ROOT_CASE_RUN" HEAD

ROOT_KEY="progress-comment-target-root-137"
ROOT_ISSUE=13701
(cd "$ROOT_CASE_RUN" && env SPECS_DIR="$ROOT_CASE_TARGET/specs" \
  MAKATO_TARGET_REPO_ROOT="$ROOT_CASE_TARGET" \
  "$WS" init "$ROOT_KEY" "$REPO" feat/target-progress "$ROOT_ISSUE" >/dev/null)
(cd "$ROOT_CASE_RUN" && env -u SPECS_DIR MAKATO_TARGET_REPO_ROOT="$ROOT_CASE_TARGET" \
  "$PC" start "$ROOT_KEY" "$ROOT_ISSUE" "$REPO" --skill build-verify \
  --goal "persist progress comment" >/dev/null 2>"$ROOT_CASE_TMP/stderr")
ROOT_STATE="$ROOT_CASE_TARGET/specs/$ROOT_KEY/workflow-state-$ROOT_ISSUE.json"
ROOT_MAIN_STATE="$ROOT_CASE_MAIN/specs/$ROOT_KEY/workflow-state-$ROOT_ISSUE.json"
ROOT_COMMENT_ID="$(jq -r '.progress_comment_id // empty' "$ROOT_STATE" 2>/dev/null || true)"
check "T12: progress_comment_id persisted under target specs" test -n "$ROOT_COMMENT_ID"
check "T12: main checkout received no duplicate state file" test ! -e "$ROOT_MAIN_STATE"
check "T12: root split produced no progress-comment WARN" \
  bash -c '! grep -q "WARN.*could not persist progress_comment_id" "$1"' _ "$ROOT_CASE_TMP/stderr"
check "T12: associated comment was created" test -f "$GH_STUB/comment-$ROOT_COMMENT_ID.md"

echo ""
echo "progress-comment smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
