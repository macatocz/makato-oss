#!/usr/bin/env bash
# build-verify-spec.sh — spec-level verifier for makato-build (#568).
#
# Three-dimensional verification:
#   COMPLETENESS — plan-<N>.md checkbox audit (all - [x] checked?)
#   CORRECTNESS  — stories.json successScenarios satisfied by the diff?
#   COHERENCE    — spec-delta.md MODIFIED requirements evidenced by the diff?
#
# This script is a thin bash wrapper that resolves spec artifacts and then
# delegates all logic to plugins/makato-build/shared/build_verify_spec.py
# (stdlib Python, no external dependencies).
#
# Usage:
#   build-verify-spec.sh <SPEC_KEY> [<diff-file>]
#
#   SPEC_KEY    — resolves spec folder via specs/<SPEC_KEY>-*/ prefix-match glob
#                 (falls back to specs/<SPEC_KEY>/ exact match)
#   diff-file   — path to a diff file. When absent, runs `git diff HEAD`.
#                 Pass `-` to read from stdin.
#
# Environment:
#   REPO_ROOT   — override repo root (useful in tests and autonomous mode).
#                 When absent, resolved via `git rev-parse --show-toplevel`.
#
# Exit codes:
#   0  — all checks pass (or only SUGGESTION findings in COHERENCE)
#   1  — CRITICAL finding: unchecked task, CORRECTNESS GAP, or COHERENCE GAP
#   2  — usage error / missing spec folder
#
set -euo pipefail

SPEC_KEY="${1:?usage: build-verify-spec.sh <SPEC_KEY> [<diff-file>]}"
DIFF_ARG="${2:-}"

# ---- Resolve repo root ---------------------------------------------------
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null \
        || { echo "build-verify-spec: cannot determine REPO_ROOT — set REPO_ROOT env or run from a git repo" >&2; exit 2; })"
fi

# ---- Plugin and Python module paths ---------------------------------------
# Resolve paths from this installed plugin, not from the consumer repository.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Locate build_verify_spec.py.
# Priority: PY_MODULE env var (tests), then the installed plugin's shared dir.
if [[ -n "${PY_MODULE:-}" ]]; then
    : # already set by caller (test env)
else
    PY_MODULE="$PLUGIN_ROOT/shared/build_verify_spec.py"
fi

if [[ ! -f "$PY_MODULE" ]]; then
    # Second fallback: REPO_ROOT-relative canonical path
    PY_MODULE="$REPO_ROOT/plugins/makato-build/shared/build_verify_spec.py"
fi

if [[ ! -f "$PY_MODULE" ]]; then
    echo "build-verify-spec: cannot locate build_verify_spec.py (tried plugin shared/ and REPO_ROOT)" >&2
    exit 2
fi

# ---- Resolve spec folder -------------------------------------------------
SPEC_RESOLVER="$PLUGIN_ROOT/shared/spec_folder.py"
if [[ ! -f "$SPEC_RESOLVER" ]]; then
    echo "build-verify-spec: spec resolver not found at '$SPEC_RESOLVER'" >&2
    exit 2
fi
if ! SPEC_DIR="$(python3 "$SPEC_RESOLVER" "$REPO_ROOT" "$SPEC_KEY" 2>&1)"; then
    echo "build-verify-spec: $SPEC_DIR" >&2
    exit 2
fi

# ---- Resolve plan file ---------------------------------------------------
# Pick the latest plan-<N>.md (highest N); fall back to plan.md (legacy)
PLAN_FILE=""
for f in "$SPEC_DIR"/plan-[0-9]*.md; do
    [[ -f "$f" ]] && PLAN_FILE="$f"
done
if [[ -z "$PLAN_FILE" && -f "$SPEC_DIR/plan.md" ]]; then
    PLAN_FILE="$SPEC_DIR/plan.md"
fi
if [[ -z "$PLAN_FILE" ]]; then
    echo "build-verify-spec: no plan-*.md found in $SPEC_DIR" >&2
    exit 2
fi

# ---- Resolve diff --------------------------------------------------------
DIFF_TMP=""
cleanup() { [[ -n "${DIFF_TMP:-}" ]] && rm -f "$DIFF_TMP"; }
trap cleanup EXIT

if [[ -z "$DIFF_ARG" ]]; then
    DIFF_TMP="$(mktemp)"
    git -C "$REPO_ROOT" diff HEAD > "$DIFF_TMP" 2>/dev/null || true
    DIFF_FILE="$DIFF_TMP"
elif [[ "$DIFF_ARG" == "-" ]]; then
    DIFF_TMP="$(mktemp)"
    cat > "$DIFF_TMP"
    DIFF_FILE="$DIFF_TMP"
else
    DIFF_FILE="$DIFF_ARG"
fi

# ---- Resolve optional files ----------------------------------------------
STORIES_FILE=""
[[ -f "$SPEC_DIR/stories.json" ]] && STORIES_FILE="$SPEC_DIR/stories.json"

DELTA_FILE=""
[[ -f "$SPEC_DIR/spec-delta.md" ]] && DELTA_FILE="$SPEC_DIR/spec-delta.md"

# ---- Delegate to Python module -------------------------------------------
exec python3 "$PY_MODULE" \
    "$PLAN_FILE" \
    "$DIFF_FILE" \
    "${STORIES_FILE:-}" \
    "${DELTA_FILE:-}"
