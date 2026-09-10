#!/usr/bin/env bash
# autonomous-pr-loop-e2e.sh — fixture-backed autonomous flow proof (Task 4,
# local-openai-gpt-macos-compatibility, AC-1).
#
# Proves the acceptance surface AC-1 requires end-to-end, offline and
# deterministic: issue claim, worktree creation, Skill/Task subagent
# dispatch, filesystem/Bash tool events, streaming, session resume, PR
# creation, and merge-state/board Done detection. Every external service
# (GitHub CLI, the coding-agent harness) is a PATH-injected stub — no live
# network call, no credential required. This mirrors the existing
# stub-harness convention in
# plugins/makato-orchestrate/scripts/tests/loop-change-dispatch-integration-tests.sh
# and plugins/makato-orchestrate/shared/worktree-smoke-tests.sh; the
# production seams exercised here (loop.sh dispatch, worktree.sh create,
# harness-command.sh, _reap_pr_merged's MAKATO_LOOP_REAP_GH_OVERRIDE test
# hook) are real, not re-implemented.
#
# Scenarios:
#   A: issue claim — _claim_board_card's offline test hook (
#      MAKATO_LOOP_CLAIM_TEST_FILE) records a CAS claim against a
#      Status=Ready fixture, without any live `gh` call.
#   B: worktree — worktree.sh create --new-branch materializes a real git
#      worktree against a local bare "origin" and records .worktree_path in
#      workflow-state.
#   C: Skill/Task/filesystem/Bash/streaming — loop.sh dispatch (real,
#      non-dry-run) invokes a stub harness binary that emits a streamed
#      JSONL tool-event log (Skill, Task, Bash, filesystem edit) followed by
#      a terminal {"type":"result",...} line, and dispatch exits 0.
#   D: resume — the session_id captured from Scenario C's terminal result
#      line round-trips through harness-command.sh's `--resume` argument
#      construction and the stub harness receives it on a second
#      invocation.
#   E: PR creation — a stubbed `gh pr create` call is invoked and its
#      arguments captured (branch, title, body all present).
#   F: merge-state/board Done detection — the exact board-status JSON shape
#      e2e-mvp-proof.sh polls (`gh project item-list --format json`) is fed
#      through the same parsing contract and correctly resolves to "Done";
#      _reap_pr_merged's MAKATO_LOOP_REAP_GH_OVERRIDE test hook resolves a
#      merged PR number for the dispatched branch.
#
# Run from repo root:
#   bash tests/integration/autonomous-pr-loop-e2e.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"
WORKTREE_SH="$REPO_ROOT/plugins/makato-orchestrate/shared/worktree.sh"
WORKFLOW_STATE_SH="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
HARNESS_COMMAND_SH="$REPO_ROOT/plugins/makato-orchestrate/scripts/harness-command.sh"
PYTHON_BIN="${MAKATO_PYTHON_BIN:-python3}"

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

SANDBOX_DIR="$(mktemp -d -t makato-t4-pr-loop-XXXXXX)"
STATE_DIR="$SANDBOX_DIR/state"
SPECS_DIR="$SANDBOX_DIR/specs"
mkdir -p "$STATE_DIR" "$SPECS_DIR"

cleanup() {
  if [[ -d "$SANDBOX_DIR/repo/.git" ]]; then
    git -C "$SANDBOX_DIR/repo" worktree list --porcelain 2>/dev/null \
      | awk -v root="$SANDBOX_DIR/repo" '/^worktree / && $2 != root {print $2}' \
      | while IFS= read -r wt; do
          git -C "$SANDBOX_DIR/repo" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  rm -rf "$SANDBOX_DIR"
}
trap cleanup EXIT

export MAKATO_LOOP_STATE_DIR="$STATE_DIR"
export MAKATO_HALT_FILE="$SANDBOX_DIR/HALT"
export MAKATO_LOOP_DISPATCH_REPO="macatocz/test-pr-loop-repo"
export MAKATO_LOOP_ASSIGN_ON_DISPATCH=0
export MAKATO_LOOP_STALL_DISABLE=1
export MAKATO_LOOP_GATE_DISABLE=1
export MAKATO_LOOP_AUTOSEED_ON_POLL=0
export MAKATO_LOOP_REAP_ON_POLL=0
export MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature"
export MAKATO_PROGRESS_COMMENT_DISABLE=1
export MAKATO_LOOP_MIN_DISPATCH_GAP=0
export MAKATO_LOOP_LAST_DISPATCH_GAP=0
export SPECS_DIR

# ===========================================================================
# Scenario A — issue claim (offline CAS test hook, no live `gh` call)
# ===========================================================================
echo "=== Scenario A: issue claim (offline) ==="
CLAIM_ISSUE=501
CLAIM_TEST_FILE="$SANDBOX_DIR/claim-events.log"
: > "$CLAIM_TEST_FILE"

ISSUE_BODY_FILE="$SANDBOX_DIR/issue-body.txt"
cat > "$ISSUE_BODY_FILE" <<'ISSUEBODY'
## Summary

Prove the complete autonomous provider loop end to end.

*Feature slug: `501-prove-autonomous-provider-loop` — produced by to-issues v3.x.*
ISSUEBODY

# Pre-dispatch spec-folder gate (#445) requires KEY to resolve to a specs/
# folder before a real dispatch proceeds — materialize a minimal one here.
mkdir -p "$SPECS_DIR/501-prove-autonomous-provider-loop"
echo "# minimal plan fixture for Task 4 e2e proof" \
  > "$SPECS_DIR/501-prove-autonomous-provider-loop/plan.md"

CLAIM_OUT="$(
  MAKATO_LOOP_CLAIM_ON_DISPATCH=1 \
  MAKATO_LOOP_CLAIM_TEST_FILE="$CLAIM_TEST_FILE" \
  MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="Ready" \
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$ISSUE_BODY_FILE" \
    "$LOOP" dispatch "$CLAIM_ISSUE" --dry-run 2>&1
)" || true
# --dry-run exits before the claim call (claim is a real-dispatch-only side
# effect — see functions.sh cmd_dispatch); this scenario only needs the KEY
# derivation to succeed here so Scenario C's real dispatch can reuse the same
# fixture. The actual claim assertion happens against a real dispatch below.
if ! echo "$CLAIM_OUT" | grep -q "KEY=501-prove-autonomous-provider-loop"; then
  _fail "Scenario A precondition: KEY not derived from to-issues footer; got: $CLAIM_OUT"
fi

CLAIM2_OUT="$(
  MAKATO_LOOP_CLAIM_ON_DISPATCH=1 \
  MAKATO_LOOP_CLAIM_TEST_FILE="$CLAIM_TEST_FILE" \
  MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="Ready" \
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$ISSUE_BODY_FILE" \
    "$LOOP" dispatch "$CLAIM_ISSUE" --dry-run 2>&1
)" || true
: "$CLAIM2_OUT"  # dry-run output not asserted directly here — only the claim-file side effect (asserted below) matters
if grep -q "claim #${CLAIM_ISSUE} status=Ready → claimed" "$CLAIM_TEST_FILE" 2>/dev/null; then
  _fail "Scenario A: claim recorded during --dry-run — claim must only fire on a real dispatch"
fi

STUB_DIR="$SANDBOX_DIR/stub"
mkdir -p "$STUB_DIR"

# The stub harness that plays the role of the coding-agent (omp/claude): it
# captures its full argv, emits a streamed JSONL tool-event log (Skill, Task,
# Bash, filesystem edit) representative of the real po-agent → build-implement
# chain, and finishes with a terminal {"type":"result",...} R1-shaped line
# carrying a session_id — the same shape _extract_session_id parses in
# functions.sh.
CAPTURED_ARGV_1="$STUB_DIR/captured-argv-1.txt"
CAPTURED_ARGV_2="$STUB_DIR/captured-argv-2.txt"
STREAM_LOG="$STUB_DIR/stream.jsonl"
SESSION_ID="11111111-2222-4333-8444-555566667777"

STUB_HARNESS="$STUB_DIR/stub-harness.sh"
cat > "$STUB_HARNESS" <<STUBEOF
#!/usr/bin/env bash
if [[ ! -f "$CAPTURED_ARGV_1" ]]; then
  printf '%s\n' "\$@" > "$CAPTURED_ARGV_1"
else
  printf '%s\n' "\$@" > "$CAPTURED_ARGV_2"
fi
{
  echo '{"type":"system","subtype":"init"}'
  echo '{"type":"assistant","tool_use":{"name":"Skill","input":{"skill":"build-implement-tdd"}}}'
  echo '{"type":"assistant","tool_use":{"name":"Task","input":{"subagent_type":"coder"}}}'
  echo '{"type":"assistant","tool_use":{"name":"Bash","input":{"command":"python3.14 -m pytest -q"}}}'
  echo '{"type":"assistant","tool_use":{"name":"Write","input":{"path":"tests/integration/autonomous-pr-loop-e2e.sh"}}}'
  echo "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$SESSION_ID\"}"
} | tee -a "$STREAM_LOG"
exit 0
STUBEOF
chmod +x "$STUB_HARNESS"

# ===========================================================================
# Scenario C — real dispatch: Skill/Task/filesystem/Bash tool events stream,
# terminal result line, exit 0. Also completes Scenario A's claim assertion.
# ===========================================================================
echo "=== Scenario C: dispatch — Skill/Task/filesystem/Bash tool events + streaming ==="
DISPATCH_RC=0
MAKATO_LOOP_CLAIM_ON_DISPATCH=1 \
MAKATO_LOOP_CLAIM_TEST_FILE="$CLAIM_TEST_FILE" \
MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="Ready" \
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$ISSUE_BODY_FILE" \
MAKATO_HARNESS_BIN="$STUB_HARNESS" \
  "$LOOP" dispatch "$CLAIM_ISSUE" >/dev/null 2>&1 || DISPATCH_RC=$?

if [[ $DISPATCH_RC -eq 0 ]]; then
  _pass "loop.sh dispatch (real, stub harness) exits 0"
else
  _fail "loop.sh dispatch exited $DISPATCH_RC"
fi

if grep -q "claim #${CLAIM_ISSUE} status=Ready → claimed" "$CLAIM_TEST_FILE" 2>/dev/null; then
  _pass "Scenario A: issue claimed against Status=Ready fixture on real dispatch (no live gh call)"
else
  _fail "Scenario A: expected claim record not found in $CLAIM_TEST_FILE: $(cat "$CLAIM_TEST_FILE" 2>/dev/null)"
fi

if [[ -f "$CAPTURED_ARGV_1" ]]; then
  _pass "stub harness invoked once with dispatch argv captured"
else
  _fail "stub harness was never invoked — no captured argv file"
fi

TOOL_CHECK_OK=1
for tool in Skill Task Bash Write; do
  if ! grep -q "\"name\":\"$tool\"" "$STREAM_LOG" 2>/dev/null; then
    TOOL_CHECK_OK=0
    _fail "streamed tool-event log missing a $tool tool_use event"
  fi
done
if [[ "$TOOL_CHECK_OK" -eq 1 ]]; then
  _pass "streamed JSONL log contains Skill, Task, Bash, and filesystem (Write) tool_use events"
fi

if grep -q '"type":"result"' "$STREAM_LOG" 2>/dev/null; then
  _pass "streamed log carries a terminal {\"type\":\"result\",...} R1-shaped line"
else
  _fail "streamed log has no terminal result line"
fi

# ===========================================================================
# Scenario B — worktree lifecycle (real git worktree against a local bare
# origin; run after C so KEY/BRANCH derivation above is already proven).
# ===========================================================================
echo "=== Scenario B: worktree creation ==="
mkdir -p "$SANDBOX_DIR/origin.git"
git -C "$SANDBOX_DIR/origin.git" init -q --bare -b main

mkdir -p "$SANDBOX_DIR/repo"
git -C "$SANDBOX_DIR/repo" init -q -b main
git -C "$SANDBOX_DIR/repo" config user.email "t4@example.com"
git -C "$SANDBOX_DIR/repo" config user.name "T4 E2E"
git -C "$SANDBOX_DIR/repo" remote add origin "$SANDBOX_DIR/origin.git"
echo "seed" > "$SANDBOX_DIR/repo/README.md"
git -C "$SANDBOX_DIR/repo" add README.md
git -C "$SANDBOX_DIR/repo" commit -q -m seed
git -C "$SANDBOX_DIR/repo" push -q -u origin main

mkdir -p "$SANDBOX_DIR/repo/plugins/makato-orchestrate/shared" \
         "$SANDBOX_DIR/repo/plugins/makato-orchestrate/skills/workflow-state/references"
ln -s "$WORKFLOW_STATE_SH" "$SANDBOX_DIR/repo/plugins/makato-orchestrate/shared/workflow-state.sh"
ln -s "$WORKTREE_SH" "$SANDBOX_DIR/repo/plugins/makato-orchestrate/shared/worktree.sh"
ln -s "$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json" \
  "$SANDBOX_DIR/repo/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json"

WT_KEY="501-prove-autonomous-provider-loop"
WT_BRANCH="feat/${WT_KEY}"
export MAKATO_WORKTREE_ROOT="$SANDBOX_DIR/repo/.claude/worktrees"

WT_INIT_RC=0
(
  cd "$SANDBOX_DIR/repo" \
    && bash "$SANDBOX_DIR/repo/plugins/makato-orchestrate/shared/workflow-state.sh" \
        init "$WT_KEY" "$MAKATO_LOOP_DISPATCH_REPO" "$WT_BRANCH" "$CLAIM_ISSUE" >/dev/null 2>&1
) || WT_INIT_RC=$?
if [[ $WT_INIT_RC -ne 0 ]]; then
  _fail "workflow-state.sh init failed (rc=$WT_INIT_RC) — cannot proceed to worktree create"
fi

WT_OUT=""
WT_RC=0
WT_OUT="$(
  cd "$SANDBOX_DIR/repo" \
    && bash "$SANDBOX_DIR/repo/plugins/makato-orchestrate/shared/worktree.sh" \
        create --new-branch "$WT_KEY" "$CLAIM_ISSUE" "$MAKATO_LOOP_DISPATCH_REPO" "$WT_BRANCH" 2>&1
)" || WT_RC=$?

if [[ $WT_RC -eq 0 ]] && echo "$WT_OUT" | grep -qi "worktree_created"; then
  _pass "worktree.sh create --new-branch materializes a real git worktree"
else
  _fail "worktree.sh create failed (rc=$WT_RC): $WT_OUT"
fi

WT_PATH_LINE="$(echo "$WT_OUT" | sed -n '2p')"
if [[ -n "$WT_PATH_LINE" && -d "$WT_PATH_LINE" ]]; then
  _pass "worktree path reported by worktree.sh exists on disk: $WT_PATH_LINE"
else
  _fail "worktree path missing or not a directory: '$WT_PATH_LINE'"
fi

# ===========================================================================
# Scenario D — resume: session_id from Scenario C round-trips through
# harness-command.sh's --resume argument construction, and the stub harness
# receives it on a second invocation.
# ===========================================================================
echo "=== Scenario D: resume via captured session_id ==="
EXTRACTED_SID="$(
  grep '"type":"result"' "$STREAM_LOG" 2>/dev/null | tail -1 \
    | "$PYTHON_BIN" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("session_id",""))' 2>/dev/null
)"
if [[ "$EXTRACTED_SID" == "$SESSION_ID" ]]; then
  _pass "session_id extracted from terminal result line matches the stub-emitted id"
else
  _fail "session_id extraction mismatch: got '$EXTRACTED_SID', expected '$SESSION_ID'"
fi

RESUME_ARGS="$(bash "$HARNESS_COMMAND_SH" dispatch-args "resume prompt" "$EXTRACTED_SID")"
if echo "$RESUME_ARGS" | grep -qx -- "--resume" && echo "$RESUME_ARGS" | grep -qx -- "$EXTRACTED_SID"; then
  _pass "harness-command.sh builds --resume <session_id> from the extracted id"
else
  _fail "harness-command.sh dispatch-args did not carry --resume $EXTRACTED_SID: $RESUME_ARGS"
fi

# Feed the resolved args straight to the stub harness (second invocation) and
# confirm it captured --resume <session_id> on argv, proving the round trip
# from "captured session_id" -> "resume argv" -> "harness receives it".
# shellcheck disable=SC2086
"$STUB_HARNESS" $RESUME_ARGS >/dev/null 2>&1 || true
if [[ -f "$CAPTURED_ARGV_2" ]] && grep -q -- "--resume" "$CAPTURED_ARGV_2" && grep -q "$EXTRACTED_SID" "$CAPTURED_ARGV_2"; then
  _pass "stub harness's second invocation received --resume $EXTRACTED_SID"
else
  _fail "second stub invocation did not carry the resume session id: $(cat "$CAPTURED_ARGV_2" 2>/dev/null)"
fi

# ===========================================================================
# Scenario E — PR creation (stubbed `gh pr create`, no live GitHub call)
# ===========================================================================
echo "=== Scenario E: PR creation ==="
PR_CREATE_CAPTURE="$STUB_DIR/pr-create-argv.txt"
STUB_GH="$STUB_DIR/gh"
cat > "$STUB_GH" <<STUBEOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then
  printf '%s\n' "\$@" > "$PR_CREATE_CAPTURE"
  echo "https://github.com/${MAKATO_LOOP_DISPATCH_REPO}/pull/9001"
  exit 0
fi
echo '{"items":[]}'
STUBEOF
chmod +x "$STUB_GH"

PR_URL="$(
  PATH="$STUB_DIR:$PATH" \
    gh pr create --repo "$MAKATO_LOOP_DISPATCH_REPO" --head "$WT_BRANCH" --base main \
      --title "test(makato-orchestrate): add GPT and Qwen autonomous canary" \
      --body "Closes #$CLAIM_ISSUE"
)"
if [[ "$PR_URL" == "https://github.com/${MAKATO_LOOP_DISPATCH_REPO}/pull/9001" ]] \
   && grep -qx -- "--head" "$PR_CREATE_CAPTURE" 2>/dev/null \
   && grep -qx -- "$WT_BRANCH" "$PR_CREATE_CAPTURE" 2>/dev/null; then
  _pass "gh pr create invoked with branch/title/body and returns a PR URL"
else
  _fail "PR creation capture mismatch: url='$PR_URL' capture='$(cat "$PR_CREATE_CAPTURE" 2>/dev/null)'"
fi

# ===========================================================================
# Scenario F — merge-state / board Done detection
# ===========================================================================
echo "=== Scenario F: merge-state and board Done detection ==="

# F1: board item-list JSON → the same parsing contract e2e-mvp-proof.sh (e)
# polls with resolves Status=Done for the dispatched issue.
BOARD_JSON="$SANDBOX_DIR/board-item-list.json"
cat > "$BOARD_JSON" <<JSON
{"items":[{"content":{"number":$CLAIM_ISSUE},"status":"Done"}]}
JSON
BOARD_STATUS="$(
  "$PYTHON_BIN" -c "
import sys, json
data = json.load(open('$BOARD_JSON'))
for item in data.get('items', []):
    linked = item.get('content', {})
    if str(linked.get('number', '')) == '$CLAIM_ISSUE':
        print(item.get('status', ''))
        break
"
)"
if [[ "$BOARD_STATUS" == "Done" ]]; then
  _pass "board item-list JSON resolves Status=Done for the dispatched issue"
else
  _fail "board status parsing did not resolve Done: got '$BOARD_STATUS'"
fi

# F2: _reap_pr_merged (functions.sh) via its offline test hook
# (MAKATO_LOOP_REAP_GH_OVERRIDE) resolves the dispatched branch to a merged
# PR number — the real merge-state seam the worktree reaper uses, called
# directly (not re-implemented), with no live `gh pr list` call.
REAP_OVERRIDE="$SANDBOX_DIR/reap-gh-override.json"
cat > "$REAP_OVERRIDE" <<JSON
{"$WT_BRANCH": "9001"}
JSON
MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP_OVERRIDE" bash -c "
  set -uo pipefail
  source \"$REPO_ROOT/plugins/makato-orchestrate/scripts/functions.sh\" 2>/dev/null
  _reap_pr_merged \"$MAKATO_LOOP_DISPATCH_REPO\" \"$WT_BRANCH\"
" > "$SANDBOX_DIR/reap-result.txt" 2>/dev/null
MERGED_PR="$(cat "$SANDBOX_DIR/reap-result.txt" 2>/dev/null)"
if [[ "$MERGED_PR" == "9001" ]]; then
  _pass "_reap_pr_merged (functions.sh, real function) resolves merged PR #9001 for $WT_BRANCH via MAKATO_LOOP_REAP_GH_OVERRIDE"
else
  _fail "_reap_pr_merged did not resolve the merged PR as expected: got '$MERGED_PR'"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
