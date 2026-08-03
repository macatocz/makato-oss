#!/usr/bin/env bash
# build-verify-spec-smoke-tests.sh — offline fixture-based regression suite
# for build-verify-spec (makato-build #568, Task 2).
#
# Three scenarios following the mark-ac-checkboxes-smoke-tests.sh pattern:
#   S1: all tasks checked, all successScenarios matched → exit 0
#   S2: unchecked task → exit 1, COMPLETENESS deficit visible in output
#   S3: unmatched successScenario (GAP) → exit 1, CORRECTNESS shows 1 GAP
#
# Fully offline: fixture files injected via temp sandbox.
# No git or network required.
#
# Run from the repo root:
#   plugins/makato-build/skills/build-verify-spec/references/build-verify-spec-smoke-tests.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-build/skills/build-verify-spec/references/build-verify-spec.sh"
PY_MODULE="$REPO_ROOT/plugins/makato-build/shared/build_verify_spec.py"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/build-verify-spec-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ---- run helper -------------------------------------------------------------
# Creates a spec folder under SANDBOX/specs/<key>-smoke/, writes fixtures,
# runs the script, and captures output.
#   run_smoke <key> <plan> <diff> [<stories_json>] [<delta_md>]
run_smoke() {
    local key="$1" plan="$2" diff_text="$3"
    local stories="${4:-}" delta="${5:-}"

    local spec_dir="$SANDBOX/specs/${key}-smoke"
    rm -rf "$spec_dir"
    mkdir -p "$spec_dir"

    printf '%s' "$plan"  > "$spec_dir/plan-1.md"
    printf '%s' "$diff_text" > "$SANDBOX/diff.txt"

    [[ -n "$stories" ]] && printf '%s' "$stories" > "$spec_dir/stories.json"
    [[ -n "$delta"   ]] && printf '%s' "$delta"   > "$spec_dir/spec-delta.md"

    set +e
    OUT="$(REPO_ROOT="$SANDBOX" PY_MODULE="$PY_MODULE" \
        bash "$SCRIPT" "$key" "$SANDBOX/diff.txt" 2>&1)"
    RC=$?
    set -e
}

# ---- fixtures ---------------------------------------------------------------

PLAN_PASS='## Tasks

### Task 1: Alpha
- [x] Alpha implemented
- [x] Alpha tested

### Task 2: Beta
- [x] Beta implemented and tested
'

PLAN_FAIL='## Tasks

### Task 1: Alpha
- [x] Alpha done

### Task 2: Beta
- [ ] Beta NOT done yet
'

STORIES_PASS='{
  "version":"2.0","slug":"smoke",
  "stories":[{"sequence":1,"summary":"s","description":{"successScenarios":[
    {"title":"Scenario 1: widget initializes","given":"a developer runs build_widget","when":"widget is created","then":"status is initialized"}
  ]}}]
}'

STORIES_GAP='{
  "version":"2.0","slug":"smoke",
  "stories":[{"sequence":1,"summary":"s","description":{"successScenarios":[
    {"title":"Completely unrelated zxqvbnm feature","given":"zxqvbnm_frobnicate configured","when":"xyzzy invocation happens","then":"quux returned"}
  ]}}]
}'

DIFF_PASS='diff --git a/widget.py b/widget.py
--- a/widget.py
+++ b/widget.py
@@ -0,0 +1,5 @@
+def build_widget():
+    status = "initialized"
+    return {"widget": True, "status": status}
'

# ---- S1: all tasks checked + all scenarios confirmed → exit 0 ---------------
echo "=== S1: all tasks checked, all successScenarios confirmed → exit 0 ==="
run_smoke "s1" "$PLAN_PASS" "$DIFF_PASS" "$STORIES_PASS"
[[ $RC -eq 0 ]] || fail "S1: expected exit 0, got $RC. Output: $OUT"
echo "$OUT" | grep -q "COMPLETENESS" || fail "S1: COMPLETENESS section missing"
echo "$OUT" | grep -q "CORRECTNESS"  || fail "S1: CORRECTNESS section missing"
echo "$OUT" | grep -q "CRITICAL"     && fail "S1: unexpected CRITICAL finding in output" || true
pass "S1: all checks pass, exit 0"

# ---- S2: unchecked task → exit 1, COMPLETENESS deficit visible ---------------
echo "=== S2: unchecked task → exit 1, COMPLETENESS shows deficit ==="
run_smoke "s2" "$PLAN_FAIL" "$DIFF_PASS"
[[ $RC -eq 1 ]] || fail "S2: expected exit 1, got $RC. Output: $OUT"
echo "$OUT" | grep -q "CRITICAL"         || fail "S2: CRITICAL not present"
echo "$OUT" | grep -q "Beta NOT done yet" || fail "S2: unchecked item label not shown"
pass "S2: unchecked task detected, exit 1"

# ---- S3: GAP in successScenarios → exit 1, CORRECTNESS shows 1 GAP ----------
echo "=== S3: unmatched successScenario → exit 1, CORRECTNESS shows GAP ==="
run_smoke "s3" "$PLAN_PASS" "$DIFF_PASS" "$STORIES_GAP"
[[ $RC -eq 1 ]] || fail "S3: expected exit 1, got $RC. Output: $OUT"
echo "$OUT" | grep -q "GAP"    || fail "S3: GAP verdict not shown"
echo "$OUT" | grep -q "CRITICAL" || fail "S3: CRITICAL not present"
pass "S3: GAP scenario detected, exit 1"

echo ""
echo "All smoke tests passed."
