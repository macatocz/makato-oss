#!/usr/bin/env bash
# check-session-tail-smoke-tests.sh — smoke tests for the PO-agent
# post-dispatch audit-tail guard (#175 AC4).
#
# Exercises `shared/check-session-tail.sh` against fixture `build.jsonl`
# files covering the four verdicts (ok / error / silent / no-log) plus a
# handful of realistic edge cases the guard has to survive.
#
# Usage:
#   plugins/makato-orchestrate/shared/check-session-tail-smoke-tests.sh
#
# Exit: 0 if all tests pass, 1 on the first failure (each failing test
# prints the fixture path + observed vs expected verdict before exit).
#
# Test isolation: each fixture is a scratch file under $CLAUDE_JOB_DIR/tmp
# (or /tmp) and reached via MAKATO_BUILD_JSONL_OVERRIDE so the helper
# never touches the repo's real specs/ tree.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/plugins/makato-orchestrate/shared/check-session-tail.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/session-tail-smoke-$$"
mkdir -p "$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# assert_verdict FIXTURE SKILL EXPECTED_VERDICT EXPECTED_HALT_CODE_OR_NULL DESC
# ---------------------------------------------------------------------------
assert_verdict() {
  local fixture="$1" skill="$2" expected_verdict="$3" expected_halt="$4" desc="$5"
  local raw
  raw="$(MAKATO_BUILD_JSONL_OVERRIDE="$fixture" \
    "$GUARD" fixture-key "$skill" 2>&1)" || {
    printf '  ✗ %s — guard exited non-zero: %s\n' "$desc" "$raw" >&2
    FAIL=$((FAIL + 1))
    return
  }

  local verdict halt_code
  verdict="$(jq -r '.verdict' <<<"$raw")"
  halt_code="$(jq -r '.halt_code // "null"' <<<"$raw")"

  if [[ "$verdict" != "$expected_verdict" ]]; then
    printf '  ✗ %s — verdict %s (expected %s)\n    output: %s\n' \
      "$desc" "$verdict" "$expected_verdict" "$raw" >&2
    FAIL=$((FAIL + 1))
    return
  fi

  if [[ "$halt_code" != "$expected_halt" ]]; then
    printf '  ✗ %s — halt_code %s (expected %s)\n    output: %s\n' \
      "$desc" "$halt_code" "$expected_halt" "$raw" >&2
    FAIL=$((FAIL + 1))
    return
  fi

  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$desc"
}

echo "check-session-tail smoke tests (issue #175 AC4)"
echo ""

# ---------------------------------------------------------------------------
# T1 — verdict:"ok" (happy path — AC3).
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t1.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{"branch":"feat/x","commits":3}}
{"ts":"2026-07-09T10:00:01.000Z","skill":"build-create-pr","story":"fixture","step":"pr_created","status":"start","data":{}}
{"ts":"2026-07-09T10:00:02.000Z","skill":"build-create-pr","story":"fixture","step":"pr_created","status":"ok","data":{"pr_url":"https://github.com/x/y/pull/1"}}
{"ts":"2026-07-09T10:00:03.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"ok","data":{"pr_url":"https://github.com/x/y/pull/1"}}
EOF
assert_verdict "$SANDBOX/t1.jsonl" build-create-pr ok null \
  "T1 — terminal session:ok yields verdict:ok (AC3 happy path)"

# ---------------------------------------------------------------------------
# T2 — verdict:"error" with halt_code (AC1).
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t2.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:01.000Z","skill":"build-create-pr","story":"fixture","step":"pr_created","status":"start","data":{}}
{"ts":"2026-07-09T10:00:02.000Z","skill":"build-create-pr","story":"fixture","step":"pr_created","status":"error","data":{"halt_code":"GH_AUTH_FAILED"}}
{"ts":"2026-07-09T10:00:03.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"error","data":{"halt_code":"GH_AUTH_FAILED"}}
EOF
assert_verdict "$SANDBOX/t2.jsonl" build-create-pr error GH_AUTH_FAILED \
  "T2 — terminal session:error yields verdict:error + halt_code (AC1)"

# ---------------------------------------------------------------------------
# T3 — verdict:"silent" — session:start but no terminal (AC2, #143 repro).
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t3.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{"branch":"feat/x"}}
{"ts":"2026-07-09T10:00:01.000Z","skill":"build-create-pr","story":"fixture","step":"pr-draft-approval","status":"warn","data":{"bypass":"open-pr-as-drafted"}}
EOF
assert_verdict "$SANDBOX/t3.jsonl" build-create-pr silent null \
  "T3 — start seen, no terminal session line yields verdict:silent (AC2, #143 repro)"

# ---------------------------------------------------------------------------
# T4 — verdict:"no-log" — empty file.
# ---------------------------------------------------------------------------
: > "$SANDBOX/t4.jsonl"
assert_verdict "$SANDBOX/t4.jsonl" build-create-pr no-log null \
  "T4 — empty build.jsonl yields verdict:no-log"

# ---------------------------------------------------------------------------
# T5 — verdict:"no-log" — file has entries but none for the target skill.
# The guard is scoped per-skill so an unrelated skill's ok line doesn't
# leak into another skill's verdict.
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t5.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-verify","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:02.000Z","skill":"build-verify","story":"fixture","step":"session","status":"ok","data":{}}
EOF
assert_verdict "$SANDBOX/t5.jsonl" build-create-pr no-log null \
  "T5 — other-skill entries only yields verdict:no-log for target skill"

# ---------------------------------------------------------------------------
# T6 — verdict:"error" with halt_code=null when sub-skill misbehaved
# (terminal session:error but no data.halt_code — belt-and-braces).
# The guard MUST still recognise the terminal line; the PO-agent then
# falls back to R1's errors[] prefix parse per halt-codes.md.
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t6.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:03.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"error","data":{}}
EOF
assert_verdict "$SANDBOX/t6.jsonl" build-create-pr error null \
  "T6 — terminal session:error without data.halt_code still yields verdict:error"

# ---------------------------------------------------------------------------
# T7 — Multiple skills interleaved. The tail-limit window (default 20)
# must still isolate the target skill's session correctly.
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t7.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-verify","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:01.000Z","skill":"build-verify","story":"fixture","step":"session","status":"ok","data":{}}
{"ts":"2026-07-09T10:00:02.000Z","skill":"build-push-to-git","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:03.000Z","skill":"build-push-to-git","story":"fixture","step":"session","status":"ok","data":{}}
{"ts":"2026-07-09T10:00:04.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{}}
{"ts":"2026-07-09T10:00:05.000Z","skill":"build-create-pr","story":"fixture","step":"pr-draft-approval","status":"warn","data":{"bypass":"open-pr-as-drafted"}}
EOF
assert_verdict "$SANDBOX/t7.jsonl" build-create-pr silent null \
  "T7 — silent build-create-pr after successful build-verify + build-push-to-git"

# ---------------------------------------------------------------------------
# T8 — Guard is idempotent — a second invocation on the same tail
# produces the same output. Regression guard against future changes that
# might mutate state or read stdin.
# ---------------------------------------------------------------------------
first="$(MAKATO_BUILD_JSONL_OVERRIDE="$SANDBOX/t2.jsonl" "$GUARD" fixture-key build-create-pr)"
second="$(MAKATO_BUILD_JSONL_OVERRIDE="$SANDBOX/t2.jsonl" "$GUARD" fixture-key build-create-pr)"
if [[ "$first" == "$second" ]]; then
  PASS=$((PASS + 1))
  echo "  ✓ T8 — guard is idempotent across repeated invocations"
else
  FAIL=$((FAIL + 1))
  printf '  ✗ T8 — guard output differed between calls\n    first:  %s\n    second: %s\n' "$first" "$second" >&2
fi

# ---------------------------------------------------------------------------
# T9 — Malformed lines in the tail (a sensor-fixer variant that emitted
# non-JSON debug output) must not crash the guard. It should skip the
# malformed line and still return a well-formed verdict from the good
# lines. Regression guard against the -c -s pipeline which crashed on
# any single non-JSON byte in the tail.
# ---------------------------------------------------------------------------
cat >"$SANDBOX/t9.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"start","data":{}}
this-is-not-json
{"ts":"2026-07-09T10:00:02.000Z","skill":"build-create-pr","story":"fixture","step":"session","status":"ok","data":{}}
EOF
assert_verdict "$SANDBOX/t9.jsonl" build-create-pr ok null \
  "T9 — malformed line skipped; verdict derived from well-formed entries"

# ---------------------------------------------------------------------------
# T10 — Missing file (spec folder never existed for this key).
# Same as empty, but exercises the pre-jq early exit.
# ---------------------------------------------------------------------------
rm -f "$SANDBOX/t10-missing.jsonl"
assert_verdict "$SANDBOX/t10-missing.jsonl" build-create-pr no-log null \
  "T10 — missing build.jsonl yields verdict:no-log (early exit)"

# ---------------------------------------------------------------------------
# T11 — an explicit linked target root wins; unset env preserves common-dir.
# ---------------------------------------------------------------------------
ROOT_CASE="$SANDBOX/target-root"
ROOT_CASE_MAIN="$ROOT_CASE/main"
ROOT_CASE_TARGET="$ROOT_CASE/target"
mkdir -p "$ROOT_CASE_MAIN"
git -C "$ROOT_CASE_MAIN" init -q -b main
git -C "$ROOT_CASE_MAIN" config user.email "session-tail-test@example.com"
git -C "$ROOT_CASE_MAIN" config user.name "Session Tail Test"
printf 'seed\n' > "$ROOT_CASE_MAIN/README.md"
git -C "$ROOT_CASE_MAIN" add README.md
git -C "$ROOT_CASE_MAIN" commit -q -m seed
git -C "$ROOT_CASE_MAIN" worktree add -q -b target "$ROOT_CASE_TARGET" HEAD
mkdir -p "$ROOT_CASE_TARGET/.claude/worktrees"
ROOT_CASE_RUN="$ROOT_CASE_TARGET/.claude/worktrees/x"
git -C "$ROOT_CASE_TARGET" worktree add -q --detach "$ROOT_CASE_RUN" HEAD

ROOT_CASE_KEY="session-tail-target-root-137"
ROOT_CASE_TARGET_SPEC="$ROOT_CASE_TARGET/specs/$ROOT_CASE_KEY-some-slug"
ROOT_CASE_MAIN_SPEC="$ROOT_CASE_MAIN/specs/$ROOT_CASE_KEY-some-slug"
mkdir -p "$ROOT_CASE_TARGET_SPEC" "$ROOT_CASE_MAIN_SPEC"
cp "$SANDBOX/t1.jsonl" "$ROOT_CASE_TARGET_SPEC/build.jsonl"
cp "$SANDBOX/t2.jsonl" "$ROOT_CASE_MAIN_SPEC/build.jsonl"

ROOT_TARGET_OUTPUT="$(cd "$ROOT_CASE_RUN" && env -u MAKATO_BUILD_JSONL_OVERRIDE \
  MAKATO_TARGET_REPO_ROOT="$ROOT_CASE_TARGET" \
  "$GUARD" "$ROOT_CASE_KEY" build-create-pr)"
ROOT_FALLBACK_OUTPUT="$(cd "$ROOT_CASE_RUN" && env -u MAKATO_BUILD_JSONL_OVERRIDE \
  -u MAKATO_TARGET_REPO_ROOT \
  "$GUARD" "$ROOT_CASE_KEY" build-create-pr)"
ROOT_TARGET_VERDICT="$(jq -r '.verdict' <<<"$ROOT_TARGET_OUTPUT")"
ROOT_FALLBACK_VERDICT="$(jq -r '.verdict' <<<"$ROOT_FALLBACK_OUTPUT")"
if [[ "$ROOT_TARGET_VERDICT" == "ok" && "$ROOT_FALLBACK_VERDICT" == "error" ]]; then
  PASS=$((PASS + 1))
  echo "  ✓ T11 — explicit target root wins; unset env still reads common-dir main"
else
  FAIL=$((FAIL + 1))
  printf '  ✗ T11 — target verdict=%s (expected ok), fallback=%s (expected error)\n' \
    "$ROOT_TARGET_VERDICT" "$ROOT_FALLBACK_VERDICT" >&2
fi

echo ""
echo "check-session-tail smoke tests: $PASS passed, $FAIL failed."
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All 11 tests passed."
