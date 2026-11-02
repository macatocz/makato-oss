#!/usr/bin/env bash
# Smoke tests for scripts/reconcile-before-resume.sh (issue #8).
# Fully offline: gh is replaced by a stub that returns canned JSON.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/reconcile-before-resume-smoke-tests.sh
#
# Scenarios:
#   T-RBR-1  phase=pr, PR open + CI green → exit 0, branch=a
#   T-RBR-2  phase=pr, PR open + CI failure → exit 2, branch=b
#   T-RBR-3  phase=pr, CI in_progress stub with zero timeout → exit 2 + branch=c in audit
#   T-RBR-4  phase=pr, no open PR → exit 1 + poison_pill_detected + workflow-state cleared
#   T-RBR-5  phase=build (not pr) → exit 0 immediately, no audit entry written
#   T-RBR-6  blocked review runtime → exit 4 and preserve blocked reason in audit
#   T-RBR-7  running review runtime → normal authorized resume with audit
#
# Loop-supervisor integration:
#   T-SUP-1  reconcile exits 0 → supervisor emits action=restart (DRY_RUN)
#   T-SUP-2  reconcile exits 1 → supervisor emits action=reconcile_abort
#   T-SUP-3  reconcile exits 4 → supervisor refuses restart and propagates exit 4
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE="$SCRIPT_DIR/../reconcile-before-resume.sh"
SUPERVISOR="$SCRIPT_DIR/../loop-supervisor.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a workflow-state fixture file.
make_wf() {
  local path="$1" phase="$2" issue="$3" branch="${4:-feat/8-test}"
  printf '{"current_phase":"%s","issue_number":%s,"branch":"%s"}\n' \
    "$phase" "$issue" "$branch" > "$path"
}

# Write a gh stub that returns canned pr-list and pr-checks JSON.
# $1=path $2=pr_list_json $3=pr_checks_json
make_gh_stub() {
  local path="$1"
  local pr_list; pr_list="$2"
  local pr_checks; pr_checks="$3"
  cat > "$path" << GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"pr list"*)   printf '%s\n' '${pr_list}' ;;
  *"pr checks"*) printf '%s\n' '${pr_checks}' ;;
  *"issue edit"*) exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
  chmod +x "$path"
}

# Run reconcile with a stub gh and a temp audit log.
# Prints the last audit action to stdout; returns the reconcile exit code.
run_reconcile() {
  local wf="$1" gh_stub="$2" audit="$3"
  local extra_args=("${@:4}")
  local _rc=0
  MAKATO_RECONCILE_GH_CMD="$gh_stub" \
  MAKATO_SUPERVISOR_AUDIT="$audit" \
  MAKATO_PR_CI_TIMEOUT_SECS="${MAKATO_PR_CI_TIMEOUT_SECS:-600}" \
    bash "$RECONCILE" --workflow-state "$wf" --repo "test/repo" "${extra_args[@]}" 2>/dev/null \
    || _rc=$?
  return "$_rc"
}

make_runtime_stub() {
  local path="$1" decision="$2" reason="$3"
  cat > "$path" <<PYEOF
import json
print(json.dumps({"decision": "$decision", "reason": "$reason"}))
PYEOF
}

# Run loop-supervisor with a stub reconcile script.
run_supervisor_with_reconcile() {
  local sb="$1" reconcile_exit="$2"
  local stub; stub="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit %d\n' "$reconcile_exit" > "$stub"
  chmod +x "$stub"
  local supervisor_exit=0

  MAKATO_REPO_ROOT="$sb" \
  MAKATO_LOOP_STATE_DIR="$sb/state" \
  MAKATO_LOOP_PIDFILE="$sb/state/loop.pid" \
  MAKATO_HALT_FILE="$sb/HALT" \
  MAKATO_LOOP_SCRIPT="$sb/loop.sh" \
  MAKATO_RECONCILE_SCRIPT="$stub" \
  MAKATO_SUPERVISOR_AUDIT="$sb/state/audit.jsonl" \
  MAKATO_SUPERVISOR_GH_CMD="true" \
  MAKATO_SUPERVISOR_DRY_RUN=1 \
    bash "$SUPERVISOR" 2>/dev/null || supervisor_exit=$?

  local action
  action="$(jq -r '.action' "$sb/state/audit.jsonl" 2>/dev/null | tail -1 || echo "")"
  rm -f "$stub"
  printf '%s:%s\n' "$action" "$supervisor_exit"
}

new_supervisor_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/loop.sh"
  chmod +x "$d/loop.sh"
  echo "99999999" > "$d/state/loop.pid"
  printf '{"queue_depth":1,"last_dispatch_at":"2020-01-01T00:00:00.000Z"}\n' \
    > "$d/state/loop-status.json"
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
echo "T-RBR-1: phase=pr, PR open + CI green → exit 0, audit branch=a"
{
  wf="$(mktemp)"; gh="$(mktemp)"; audit="$(mktemp)"
  make_wf "$wf" pr 8
  make_gh_stub "$gh" \
    '[{"number":42}]' \
    '[{"name":"ci","conclusion":"success","state":"COMPLETED"}]'

  rc=0; run_reconcile "$wf" "$gh" "$audit" || rc=$?
  branch="$(jq -r '.branch' "$audit" | tail -1)"

  if [[ "$rc" -eq 0 && "$branch" == "a" ]]; then
    pass "T-RBR-1"
  else
    fail "T-RBR-1" "exit=$rc (want 0), branch=$branch (want a)"
  fi
  rm -f "$wf" "$gh" "$audit"
}

# ---------------------------------------------------------------------------
echo "T-RBR-2: phase=pr, PR open + CI failure → exit 2, audit branch=b"
{
  wf="$(mktemp)"; gh="$(mktemp)"; audit="$(mktemp)"
  make_wf "$wf" pr 8
  make_gh_stub "$gh" \
    '[{"number":42}]' \
    '[{"name":"ci","conclusion":"failure","state":"COMPLETED"}]'

  rc=0; run_reconcile "$wf" "$gh" "$audit" || rc=$?
  branch="$(jq -r '.branch' "$audit" | tail -1)"

  if [[ "$rc" -eq 2 && "$branch" == "b" ]]; then
    pass "T-RBR-2"
  else
    fail "T-RBR-2" "exit=$rc (want 2), branch=$branch (want b)"
  fi
  rm -f "$wf" "$gh" "$audit"
}

# ---------------------------------------------------------------------------
echo "T-RBR-3: phase=pr, CI in_progress with zero timeout → exit 2 + branch=c in audit"
{
  wf="$(mktemp)"; gh="$(mktemp)"; audit="$(mktemp)"
  make_wf "$wf" pr 8
  # PR found, but CI check has null conclusion (in-progress)
  make_gh_stub "$gh" \
    '[{"number":42}]' \
    '[{"name":"ci","conclusion":null,"state":"IN_PROGRESS"}]'

  rc=0
  MAKATO_PR_CI_TIMEOUT_SECS=0 MAKATO_RECONCILE_GH_CMD="$gh" MAKATO_SUPERVISOR_AUDIT="$audit" \
    bash "$RECONCILE" --workflow-state "$wf" --repo "test/repo" 2>/dev/null || rc=$?

  branch="$(jq -r '.branch' "$audit" | tail -1)"
  action="$(jq -r '.action' "$audit" | tail -1)"

  if [[ "$rc" -eq 2 && "$branch" == "c" && "$action" == "reconcile_result" ]]; then
    pass "T-RBR-3"
  else
    fail "T-RBR-3" "exit=$rc (want 2), branch=$branch (want c), action=$action (want reconcile_result)"
  fi
  rm -f "$wf" "$gh" "$audit"
}

# ---------------------------------------------------------------------------
echo "T-RBR-4: phase=pr, no open PR → exit 1 + poison_pill_detected + workflow-state cleared"
{
  wf="$(mktemp)"; gh="$(mktemp)"; audit="$(mktemp)"
  make_wf "$wf" pr 8

  make_gh_stub "$gh" '[]' '[]'

  rc=0; run_reconcile "$wf" "$gh" "$audit" || rc=$?

  # Check audit contains poison_pill_detected entry
  poison="$(jq -r 'select(.action=="poison_pill_detected") | .action' "$audit" 2>/dev/null | head -1)"
  # Check workflow-state was zeroed out
  phase_after="$(jq -r '.current_phase' "$wf" 2>/dev/null)"
  issue_after="$(jq -r '.issue_number' "$wf" 2>/dev/null)"

  if [[ "$rc" -eq 1 && "$poison" == "poison_pill_detected" \
        && "$phase_after" == "null" && "$issue_after" == "null" ]]; then
    pass "T-RBR-4"
  else
    fail "T-RBR-4" "exit=$rc (want 1), poison=$poison (want poison_pill_detected), phase_after=$phase_after issue_after=$issue_after"
  fi
  rm -f "$wf" "$gh" "$audit"
}

# ---------------------------------------------------------------------------
echo "T-RBR-5: phase=build (not pr) → exit 0, no audit entry written"
{
  wf="$(mktemp)"; audit="$(mktemp)"
  make_wf "$wf" build 8

  rc=0
  MAKATO_RECONCILE_GH_CMD="true" \
  MAKATO_SUPERVISOR_AUDIT="$audit" \
    bash "$RECONCILE" --workflow-state "$wf" --repo "test/repo" 2>/dev/null || rc=$?

  entry_count="$(jq -s 'length' "$audit" 2>/dev/null || echo 0)"

  if [[ "$rc" -eq 0 && "$entry_count" -eq 0 ]]; then
    pass "T-RBR-5"
  else
    fail "T-RBR-5" "exit=$rc (want 0), audit_entries=$entry_count (want 0)"
  fi
  rm -f "$wf" "$audit"
}

# ---------------------------------------------------------------------------
echo "T-RBR-6: phase=verify with blocked review runtime → exit 4 and audit reason"
{
  sb="$(mktemp -d)"
  git init -q "$sb"
  mkdir -p "$sb/state" "$sb/plugins/makato-build/shared"
  wf="$sb/state/workflow-state.json"
  printf '{"current_phase":"verify","issue_number":8,"worktree_path":"%s"}\n' "$sb" > "$wf"
  make_runtime_stub "$sb/plugins/makato-build/shared/review_runtime.py" blocked cap_exhausted
  audit="$sb/state/audit.jsonl"
  rc=0
  MAKATO_BUILD_ROOT="$sb/plugins/makato-build" MAKATO_SUPERVISOR_AUDIT="$audit" \
    bash "$RECONCILE" --workflow-state "$wf" 2>/dev/null || rc=$?
  reason="$(jq -r '.branch' "$audit" 2>/dev/null || echo missing)"
  if [[ "$rc" -eq 4 && "$reason" == "cap_exhausted" ]]; then
    pass "T-RBR-6"
  else
    fail "T-RBR-6" "exit=$rc (want 4), audit reason=$reason (want cap_exhausted)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T-RBR-7: phase=review with running runtime → resume same attempt without skip"
{
  sb="$(mktemp -d)"
  git init -q "$sb"
  mkdir -p "$sb/state" "$sb/plugins/makato-build/shared"
  wf="$sb/state/workflow-state.json"
  printf '{"current_phase":"review","issue_number":8,"worktree_path":"%s"}\n' "$sb" > "$wf"
  make_runtime_stub "$sb/plugins/makato-build/shared/review_runtime.py" running ""
  audit="$sb/state/audit.jsonl"
  rc=0
  MAKATO_BUILD_ROOT="$sb/plugins/makato-build" MAKATO_SUPERVISOR_AUDIT="$audit" \
    bash "$RECONCILE" --workflow-state "$wf" 2>/dev/null || rc=$?
  decision="$(jq -r '.branch' "$audit" 2>/dev/null || echo missing)"
  if [[ "$rc" -eq 0 && "$decision" == "running" ]]; then
    pass "T-RBR-7"
  else
    fail "T-RBR-7" "exit=$rc (want 0), audit decision=$decision (want running)"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T-SUP-1: MAKATO_RECONCILE_SCRIPT exits 0 → supervisor emits action=restart"
{
  sb="$(new_supervisor_sandbox)"
  action="$(run_supervisor_with_reconcile "$sb" 0)"
  if [[ "$action" == "restart:0" ]]; then
    pass "T-SUP-1"
  else
    fail "T-SUP-1" "expected restart:0, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T-SUP-2: MAKATO_RECONCILE_SCRIPT exits 1 → supervisor emits action=reconcile_abort"
{
  sb="$(new_supervisor_sandbox)"
  action="$(run_supervisor_with_reconcile "$sb" 1)"
  if [[ "$action" == "reconcile_abort:0" ]]; then
    pass "T-SUP-2"
  else
    fail "T-SUP-2" "expected reconcile_abort:0, got '$action'"
  fi
  rm -rf "$sb"
}
echo "T-SUP-3: MAKATO_RECONCILE_SCRIPT exits 4 → supervisor blocks restart"
{
  sb="$(new_supervisor_sandbox)"
  action="$(run_supervisor_with_reconcile "$sb" 4)"
  if [[ "$action" == "reconcile_abort:4" ]]; then
    pass "T-SUP-3"
  else
    fail "T-SUP-3" "expected reconcile_abort:4, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS tests passed."
else
  echo "$PASS passed, $FAIL FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
