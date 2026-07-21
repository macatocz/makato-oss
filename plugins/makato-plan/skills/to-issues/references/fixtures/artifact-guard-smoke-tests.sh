#!/usr/bin/env bash
# Smoke tests for the to-issues Step 6a planning-artifact guard (#527).
#
# to-issues is a prose skill — its logic lives in SKILL.md and is executed by
# an agent, not a script. This file is the *executable spec* for the
# deterministic core of Step 6a: it re-implements the `git add` + tracked-check
# guard exactly as the prose describes it, runs it against throwaway git
# repositories, and asserts the acceptance criteria for #527:
#
#   1. When the repo's .gitignore permits specs/**/stories.json (the negations
#      are present), `git add` stages both artifacts and the guard PASSES.
#   2. When the repo's .gitignore still blocks specs/**/stories.json (the
#      negations are absent), the artifact stays untracked and the guard HALTS
#      (UNTRACKED_ARTIFACTS).
#   3. This repo's OWN .gitignore carries the negations after the `!specs/**/`
#      directory-descent escape — so the autonomous build-refine lane works in
#      makato itself, not just in a consumer that opts in.
#
# If the prose in SKILL.md Step 6a changes the guard, update this reference
# implementation in lockstep — a drift here means the spec and its guard
# disagree.
#
# Pure bash + git. No gh, no network, no agent.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s → %s\n' "$name" "$actual"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual"
  fi
}

# guard <repo-root> <slug>: the deterministic core of to-issues Step 6a.
# Prints "pass" (both artifacts tracked after `git add`) or
# "halt:UNTRACKED_ARTIFACTS" (at least one stayed untracked). Mirrors the
# SKILL.md prose byte-for-byte in intent.
guard() {
  local root="$1" slug="$2"
  local stories="$root/specs/$slug/stories.json"
  local created="$root/specs/$slug/created-issues.json"
  git -C "$root" add -- "$stories" "$created" 2>/dev/null || true
  local f
  for f in "$stories" "$created"; do
    if [ -z "$(git -C "$root" ls-files -- "$f")" ]; then
      echo "halt:UNTRACKED_ARTIFACTS"
      return 0
    fi
  done
  echo "pass"
}

# init_repo <dir> <gitignore-body>: throwaway git repo with the given
# .gitignore and a stories.json + created-issues.json under specs/<slug>/.
init_repo() {
  local dir="$1" ignore="$2" slug="feat-x"
  mkdir -p "$dir/specs/$slug"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.io
  git -C "$dir" config user.name t
  printf '%s\n' "$ignore" >"$dir/.gitignore"
  echo '{"slug":"feat-x","stories":[{"id":"S1"}]}' >"$dir/specs/$slug/stories.json"
  echo '{"schema_version":"1","slug":"feat-x","issues":[]}' >"$dir/specs/$slug/created-issues.json"
  git -C "$dir" add .gitignore
  git -C "$dir" commit -qm init
}

echo "to-issues Step 6a artifact-guard smoke tests (#527)"

# --- T1: negations present → guard passes ----------------------------------
GOOD="$TMP/good"
init_repo "$GOOD" 'specs/**
!specs/**/
!specs/**/build.jsonl
!specs/**/spec.md
!specs/**/stories.json
!specs/**/created-issues.json'
check "negations present → guard passes" "pass" "$(guard "$GOOD" feat-x)"

# --- T2: negations absent → guard halts ------------------------------------
BAD="$TMP/bad"
init_repo "$BAD" 'specs/**
!specs/**/
!specs/**/build.jsonl
!specs/**/spec.md'
check "negations absent → guard halts" "halt:UNTRACKED_ARTIFACTS" \
  "$(guard "$BAD" feat-x)"

# --- T3: negations BEFORE the directory-descent escape → still blocked -----
# The ordering caveat from the spec: a negation placed before `!specs/**/`
# never lets Git descend into the dir, so the file stays ignored.
MISORDERED="$TMP/misordered"
init_repo "$MISORDERED" 'specs/**
!specs/**/stories.json
!specs/**/created-issues.json'
check "negations before !specs/**/ → still blocked" "halt:UNTRACKED_ARTIFACTS" \
  "$(guard "$MISORDERED" feat-x)"

# --- T4: makato's OWN .gitignore carries the negations, correctly ordered --
# stories.json / created-issues.json must be trackable in makato itself.
stories_ignored="$(git -C "$REPO_ROOT" check-ignore \
  specs/feat-probe/stories.json 2>/dev/null || true)"
created_ignored="$(git -C "$REPO_ROOT" check-ignore \
  specs/feat-probe/created-issues.json 2>/dev/null || true)"
check "makato .gitignore: stories.json trackable" "" "$stories_ignored"
check "makato .gitignore: created-issues.json trackable" "" "$created_ignored"

# --- T5: a non-negated specs artifact stays ignored in makato (control) ----
wfs_ignored="$(git -C "$REPO_ROOT" check-ignore \
  specs/feat-probe/workflow-state.json 2>/dev/null || true)"
check "makato .gitignore: workflow-state.json still ignored (control)" \
  "specs/feat-probe/workflow-state.json" "$wfs_ignored"

# --- Summary ---------------------------------------------------------------
echo ""
echo "to-issues artifact-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
