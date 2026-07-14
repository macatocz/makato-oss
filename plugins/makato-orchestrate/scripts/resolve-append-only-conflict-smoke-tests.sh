#!/usr/bin/env bash
# Smoke tests for scripts/resolve-append-only-conflict.sh (append-only union merge).
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/resolve-append-only-conflict-smoke-tests.sh
#
# Scenarios:
#   T1: missing args exits 1
#   T2: path that is not unmerged exits 1
#   T3: modify/modify CHANGELOG conflict — both prepended blocks survive, 0 markers
#   T4: resolved path is staged (no longer in `git ls-files -u`)
#   T5: summary reports strategy "union" and markers_remaining 0
#   T6: add/add conflict (no merge base) — had_base:false, both sides kept
#   T7: non-conflicting interleaved edits still merge (union is a superset)
#   T8: after resolving the only conflict, `git commit` succeeds (merge completes)
#
# Fully offline: builds a throwaway git repo per run, drives a real merge to the
# conflicted state, then invokes the script. Mirrors mark-ac-checkboxes-smoke-tests.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/resolve-append-only-conflict.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/resolve-append-only-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# init_repo <dir> — a fresh git repo with deterministic identity, isolated from
# the caller's global config.
init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "smoke@makato.test"
  git -C "$dir" config user.name "Smoke Test"
  git -C "$dir" config commit.gpgsign false
}

# --- T1: missing args -------------------------------------------------------
echo "=== T1: missing args exits 1 ==="
if "$SCRIPT" 2>/dev/null; then fail "T1: expected non-zero exit"; fi
pass "T1: missing args rejected"

# --- T2: path not unmerged --------------------------------------------------
echo "=== T2: non-unmerged path exits 1 ==="
R2="$SANDBOX/t2"; init_repo "$R2"
( cd "$R2"
  printf 'hello\n' > file.txt
  git add file.txt; git commit -qm init
  if "$SCRIPT" file.txt 2>/dev/null; then exit 42; fi
) || { rc=$?; [[ $rc -eq 42 ]] && fail "T2: clean path was accepted"; }
pass "T2: clean (non-unmerged) path rejected"

# build_conflict <dir> — a repo whose main and feature branches each prepend a
# distinct block to CHANGELOG.md, producing a modify/modify conflict on merge.
# Leaves the repo mid-merge with CHANGELOG.md unmerged. Echoes nothing.
build_conflict() {
  local dir="$1"; init_repo "$dir"
  cd "$dir"
  printf '# Changelog\n\n## 1.0.0\n- initial\n' > CHANGELOG.md
  git add CHANGELOG.md; git commit -qm base
  git checkout -q -b feature
  printf '# Changelog\n\n## 1.2.0 (feature)\n- feature line\n\n## 1.0.0\n- initial\n' > CHANGELOG.md
  git commit -qam feature
  git checkout -q main
  printf '# Changelog\n\n## 1.1.0 (main)\n- main line\n\n## 1.0.0\n- initial\n' > CHANGELOG.md
  git commit -qam main
  # Merge feature into main → conflict on the prepended region.
  git merge feature --no-commit --no-ff >/dev/null 2>&1 || true
}

# --- T3: modify/modify — both blocks survive, 0 markers ---------------------
echo "=== T3: modify/modify — both prepended blocks survive ==="
R3="$SANDBOX/t3"
( build_conflict "$R3"
  git -C "$R3" diff --name-only --diff-filter=U | grep -q '^CHANGELOG.md$' \
    || { echo "T3-setup: expected CHANGELOG.md conflict" >&2; exit 1; }
  cd "$R3"
  "$SCRIPT" CHANGELOG.md >/dev/null
  grep -qF '## 1.1.0 (main)' CHANGELOG.md    || { echo "T3: main block lost" >&2; exit 1; }
  grep -qF '## 1.2.0 (feature)' CHANGELOG.md || { echo "T3: feature block lost" >&2; exit 1; }
  ! grep -qE '^(<<<<<<<|=======|>>>>>>>)' CHANGELOG.md || { echo "T3: markers remain" >&2; exit 1; }
) || fail "T3: union did not preserve both blocks"
pass "T3: both changelog blocks preserved, no markers"

# --- T4: resolved path is staged --------------------------------------------
echo "=== T4: resolved path staged (cleared from ls-files -u) ==="
R4="$SANDBOX/t4"
( build_conflict "$R4"
  cd "$R4"
  "$SCRIPT" CHANGELOG.md >/dev/null
  git ls-files -u -- CHANGELOG.md | grep -q . && { echo "T4: still unmerged" >&2; exit 1; }
  git diff --cached --name-only | grep -q '^CHANGELOG.md$' || { echo "T4: not staged" >&2; exit 1; }
) || fail "T4: path not staged/cleared"
pass "T4: resolved path staged and unmerged state cleared"

# --- T5: summary JSON -------------------------------------------------------
echo "=== T5: summary reports union strategy, 0 markers ==="
R5="$SANDBOX/t5"
( build_conflict "$R5"
  cd "$R5"
  OUT="$("$SCRIPT" CHANGELOG.md)"
  echo "$OUT" | grep -q '"strategy":"union"' || { echo "T5: strategy missing ($OUT)" >&2; exit 1; }
  echo "$OUT" | grep -q '"markers_remaining":0' || { echo "T5: markers field wrong ($OUT)" >&2; exit 1; }
  echo "$OUT" | grep -q '"resolved":true' || { echo "T5: resolved field wrong ($OUT)" >&2; exit 1; }
) || fail "T5: summary JSON malformed"
pass "T5: summary JSON correct"

# --- T6: add/add conflict (no base) -----------------------------------------
echo "=== T6: add/add conflict — had_base:false, both sides kept ==="
R6="$SANDBOX/t6"; init_repo "$R6"
( cd "$R6"
  printf 'seed\n' > seed.txt; git add seed.txt; git commit -qm seed
  git checkout -q -b feature
  printf '## feature-only\n- f\n' > NEWFILE.md    # file added ONLY on feature
  git add NEWFILE.md; git commit -qm feat-add
  git checkout -q main
  printf '## main-only\n- m\n' > NEWFILE.md        # same path added on main
  git add NEWFILE.md; git commit -qm main-add
  git merge feature --no-commit --no-ff >/dev/null 2>&1 || true
  git ls-files -u -- NEWFILE.md | grep -q . || { echo "T6-setup: no add/add conflict" >&2; exit 1; }
  OUT="$("$SCRIPT" NEWFILE.md)"
  echo "$OUT" | grep -q '"had_base":false' || { echo "T6: had_base not false ($OUT)" >&2; exit 1; }
  grep -qF '## main-only' NEWFILE.md    || { echo "T6: main side lost" >&2; exit 1; }
  grep -qF '## feature-only' NEWFILE.md || { echo "T6: feature side lost" >&2; exit 1; }
) || fail "T6: add/add union failed"
pass "T6: add/add union keeps both sides, had_base:false"

# --- T7: non-conflicting interleaved edits ----------------------------------
echo "=== T7: distinct-region edits merge as a superset ==="
R7="$SANDBOX/t7"; init_repo "$R7"
( cd "$R7"
  printf 'top\nMID\nbottom\n' > f.md; git add f.md; git commit -qm base
  git checkout -q -b feature
  printf 'TOPFEAT\ntop\nMID\nbottom\n' > f.md; git commit -qam feat  # edit at top
  git checkout -q main
  printf 'top\nMID\nbottom\nBOTMAIN\n' > f.md; git commit -qam main  # edit at bottom
  git merge feature --no-commit --no-ff >/dev/null 2>&1 || true
  # This may auto-merge cleanly; only run script if actually unmerged.
  if git ls-files -u -- f.md | grep -q .; then
    "$SCRIPT" f.md >/dev/null
  fi
  grep -qF 'TOPFEAT' f.md || { echo "T7: feature edit lost" >&2; exit 1; }
  grep -qF 'BOTMAIN' f.md || { echo "T7: main edit lost" >&2; exit 1; }
) || fail "T7: interleaved edits not preserved"
pass "T7: distinct-region edits preserved"

# --- T8: merge completes after resolution -----------------------------------
echo "=== T8: git commit succeeds after resolving the sole conflict ==="
R8="$SANDBOX/t8"
( build_conflict "$R8"
  cd "$R8"
  "$SCRIPT" CHANGELOG.md >/dev/null
  git commit -qm "merge: union-resolve CHANGELOG" || { echo "T8: commit failed" >&2; exit 1; }
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "T8: merge still in progress" >&2; exit 1
  fi
) || fail "T8: merge did not complete"
pass "T8: merge completed after union resolution"

echo ""
echo "All resolve-append-only-conflict smoke tests passed."
