#!/usr/bin/env bash
# Resolve the remote-tracking ref of the repository's default branch.
#
# Returns a string of the form `origin/<default-branch>` (e.g. `origin/main`).
# Build skills use this ref — never the bare local `main` — when diffing the
# feature branch against the integration target. Issue #98: a local `main`
# can lag `origin/main` between operator pulls; `git diff main...HEAD` on a
# stale checkout pulls in commits that already shipped from already-merged PRs,
# so `build-simplify` / `build-review` would touch code they did not author.
#
# Resolution order:
#   1. `git symbolic-ref refs/remotes/origin/HEAD` — the canonical pointer
#      written by `git clone` / `git remote set-head origin --auto`.
#   2. If that fails (no HEAD pointer cached locally), try `origin/main` and
#      `origin/master` in that order.
#   3. If `origin` is missing entirely, fall back to the local default branch
#      so the caller still gets a usable ref — emit a warning to stderr so the
#      operator knows the staleness guarantee is degraded.
#
# Usage:
#   DEFAULT_REF="$(./shared/default-branch.sh)"        # e.g. "origin/main"
#   git diff "$DEFAULT_REF...HEAD" --name-only
#
# The caller is responsible for `git fetch origin --quiet` before diffing if
# absolute freshness matters; this script only resolves the ref name.
set -euo pipefail

# 1. Canonical pointer written by `git clone`.
if HEAD_REF="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
  # HEAD_REF looks like `refs/remotes/origin/main` → strip the prefix.
  printf '%s\n' "${HEAD_REF#refs/remotes/}"
  exit 0
fi

# 2. Probe the common defaults explicitly. `git show-ref --verify --quiet` is
#    cheap and silent on miss.
for candidate in main master; do
  if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
    printf 'origin/%s\n' "$candidate"
    exit 0
  fi
done

# 3. Last resort — no `origin` remote tracking ref found. Emit a warning and
#    fall back to the local branch so the caller still produces a diff, even
#    if it is the stale-main diff this helper exists to prevent.
echo "[default-branch.sh] WARNING: no origin/* default branch ref found; falling back to local 'main'" >&2
for candidate in main master; do
  if git show-ref --verify --quiet "refs/heads/$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "[default-branch.sh] ERROR: cannot resolve a default branch ref" >&2
exit 1
