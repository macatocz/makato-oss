#!/usr/bin/env bash
# Structural progress-comment guard smoke tests (#64).
#
# PC1 proves the shared helper creates a comment and persists its integer id
# before the fake OMP harness starts. PC2 proves a GitHub failure warns without
# blocking that harness. All GitHub operations use the existing offline stub.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"
WORKFLOW_STATE="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "  FAIL: $*" >&2
  exit 1
}

echo "=== PC1: progress comment is persisted before harness dispatch ==="
PC1_SPECS="$TMP/pc1/specs"
PC1_GH="$TMP/pc1/gh"
PC1_KEY="progress-guard-test"
PC1_ISSUE=506
PC1_BODY="$TMP/pc1/issue-body.txt"
PC1_HARNESS="$TMP/pc1/fake-harness"
PC1_HARNESS_LOG="$TMP/pc1/harness.log"
mkdir -p "$PC1_SPECS/$PC1_KEY" "$PC1_GH"
printf '%s\n' "> generated from \`specs/$PC1_KEY/stories.json\`" >"$PC1_BODY"
SPECS_DIR="$PC1_SPECS" \
  "$WORKFLOW_STATE" init "$PC1_KEY" "macatocz/makato" \
    "feat/${PC1_ISSUE}-${PC1_KEY}" "$PC1_ISSUE" >/dev/null
cat >"$PC1_HARNESS" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
state="$(bash "$WORKFLOW_STATE" read "$TEST_KEY" "$TEST_ISSUE")"
comment_id="$(jq -r '.progress_comment_id // empty' <<<"$state")"
[[ "$comment_id" =~ ^[1-9][0-9]*$ ]]
[[ -s "$GH_STUB/comment-${comment_id}.md" ]]
printf 'harness-dispatched\n' >"$HARNESS_LOG"
HARNESS
chmod +x "$PC1_HARNESS"
SPECS_DIR="$PC1_SPECS" \
  WORKFLOW_STATE="$WORKFLOW_STATE" \
  TEST_KEY="$PC1_KEY" \
  TEST_ISSUE="$PC1_ISSUE" \
  GH_STUB="$PC1_GH" \
  HARNESS_LOG="$PC1_HARNESS_LOG" \
  MAKATO_PC_GH_STUB="$PC1_GH" \
  MAKATO_LOOP_STATE_DIR="$TMP/pc1/state" \
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$PC1_BODY" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_GATE_DISABLE=1 \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_STALL_DISABLE=1 \
  MAKATO_LOOP_STALL_TEST_CMD="$PC1_HARNESS" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch "$PC1_ISSUE" >/dev/null 2>&1 \
  || fail "dispatch failed or harness started before progress_comment_id was persisted"
[[ -s "$PC1_HARNESS_LOG" ]] || fail "fake harness was not dispatched"
pc1_comment_id="$(
  SPECS_DIR="$PC1_SPECS" "$WORKFLOW_STATE" read "$PC1_KEY" "$PC1_ISSUE" \
    | jq -r '.progress_comment_id // empty'
)"
[[ "$pc1_comment_id" =~ ^[1-9][0-9]*$ ]] \
  || fail "progress_comment_id is not a non-null integer: '$pc1_comment_id'"
echo "  PASS: progress comment id persisted before the fake harness started"

echo "=== PC2: GitHub failure warns but still dispatches harness ==="
PC2_SPECS="$TMP/pc2/specs"
PC2_GH="$TMP/pc2/gh"
PC2_KEY="progress-guard-failure-test"
PC2_ISSUE=507
PC2_BODY="$TMP/pc2/issue-body.txt"
PC2_HARNESS="$TMP/pc2/fake-harness"
PC2_HARNESS_LOG="$TMP/pc2/harness.log"
mkdir -p "$PC2_SPECS/$PC2_KEY" "$PC2_GH"
printf '%s\n' "> generated from \`specs/$PC2_KEY/stories.json\`" >"$PC2_BODY"
SPECS_DIR="$PC2_SPECS" \
  "$WORKFLOW_STATE" init "$PC2_KEY" "macatocz/makato" \
    "feat/${PC2_ISSUE}-${PC2_KEY}" "$PC2_ISSUE" >/dev/null
cat >"$PC2_HARNESS" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
printf 'harness-dispatched\n' >"$HARNESS_LOG"
HARNESS
chmod +x "$PC2_HARNESS"
pc2_output="$(
  SPECS_DIR="$PC2_SPECS" \
  HARNESS_LOG="$PC2_HARNESS_LOG" \
  MAKATO_PC_GH_STUB="$PC2_GH" \
  MAKATO_PC_GH_FAIL=1 \
  MAKATO_LOOP_STATE_DIR="$TMP/pc2/state" \
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$PC2_BODY" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_GATE_DISABLE=1 \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_STALL_DISABLE=1 \
  MAKATO_LOOP_STALL_TEST_CMD="$PC2_HARNESS" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch "$PC2_ISSUE" 2>&1
)" || fail "GitHub failure blocked dispatch: $pc2_output"
grep -q "progress-comment: WARN" <<<"$pc2_output" \
  || fail "expected progress-comment warning; got: $pc2_output"
[[ -s "$PC2_HARNESS_LOG" ]] \
  || fail "fake harness was not dispatched after GitHub failure"
echo "  PASS: GitHub failure warns and does not block the fake harness"

echo "loop progress-comment smoke: 2 passed, 0 failed"
