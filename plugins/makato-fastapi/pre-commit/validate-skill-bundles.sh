#!/usr/bin/env bash
# validate-skill-bundles.sh — pre-commit gate for skill-bundles.yml (D18 authoring-time)
#
# RELATIONSHIP TO THE LANGGRAPH COPY
# ---------------------------------------------------------------------------
# This file is byte-for-byte identical to
#   plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh
# which is the CANONICAL entry point wired into .pre-commit-config.yaml.
# The fastapi copy exists for local parity only — plugin contributors can run
# it directly (e.g. `bash plugins/makato-fastapi/pre-commit/validate-skill-bundles.sh
# plugins/makato-fastapi/config/skill-bundles.yml`) without knowing which
# plugin owns the pre-commit hook.
#
# When updating the validation logic, update BOTH copies together.  A future
# consolidation can introduce a shared entry point in makato-build; for now
# keeping the copies explicit is safer than a symlink that breaks on shallow
# clones or some CI checkout strategies.
# ---------------------------------------------------------------------------
#
# Rejects any bundle that pairs a WIDE glob with a skill recommendation but
# omits BOTH the `contains:` file-content predicate AND the `task_contains:`
# task-text predicate. A wide glob is one with ZERO literal path segments
# (every segment contains `*` or `?`) — e.g. `**/*`, `**/*.py`, `**/*graph*.py`.
# Without either content filter, such a glob would spray skill suggestions
# across an entire language's files. The resolver (D19) uses `contains:` for
# file-routing precision; `task_contains:` (F5) is the equivalent precision
# filter for task-text routing. Either one satisfies the gate.
#
# Also rejects any bundle name that collides with a bundle name already defined
# in another plugin (F2: cross-plugin name collision gate).
#
# Exemptions:
#   * The `default` bundle (its `**/*` glob is the deliberate catch-all).
#   * Any bundle whose `skills:` list is empty ([]) — it recommends nothing, so
#     breadth is harmless.
#   * A bundle with a non-empty `task_contains:` list — task-text is itself
#     the precision filter, so no file `contains:` is required.
#
# Exit codes:
#   0  all staged skill-bundles.yml files pass (or none are staged)
#   1  at least one wide-glob-without-precision-filter violation (message on stderr)
#      OR a cross-plugin bundle-name collision (message on stderr)
#   2  a staged skill-bundles.yml could not be parsed, or repo/shared-dir absent
#
# Invocation:
#   pre-commit `language: system` hook with `files: config/skill-bundles\.yml$`,
#   or standalone: `validate-skill-bundles.sh [<file> ...]`. With no arguments
#   it inspects the git-staged skill-bundles.yml files.
set -euo pipefail

# ---------------------------------------------------------------------------
# Collect the files to check: explicit args, else staged skill-bundles.yml.
# ---------------------------------------------------------------------------
files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # Staged, added/copied/modified files matching skill-bundles.yml.
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E '(^|/)skill-bundles\.yml$' || true)
fi

if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# F3: Resolve paths robustly — no hardcoded relative literals.
# Use `git rev-parse --show-toplevel` from SCRIPT_DIR so this works in any
# checkout or worktree without depending on CWD.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "validate-skill-bundles: could not determine repository root (git rev-parse --show-toplevel failed)" >&2
  exit 2
}

# shared/ lives at <repo>/plugins/makato-build/shared/
SHARED_DIR="$REPO_ROOT/plugins/makato-build/shared"
if [ ! -d "$SHARED_DIR" ]; then
  echo "validate-skill-bundles: makato-build/shared not found at expected path: $SHARED_DIR" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# The validation logic lives in Python so it can reuse the resolver's
# `_glob_specificity` definition of "literal segment" — the single source of
# truth for what "wide" means. Keeping the definition in one place stops the
# gate and the resolver from drifting.
# ---------------------------------------------------------------------------
python3 - "$SHARED_DIR" "$REPO_ROOT" "${files[@]}" <<'PY'
import sys
from pathlib import Path
from collections import defaultdict

shared_dir = sys.argv[1]
repo_root = Path(sys.argv[2])
targets = sys.argv[3:]
sys.path.insert(0, shared_dir)

try:
    import yaml
except ImportError:
    print("validate-skill-bundles: PyYAML is required but not installed.", file=sys.stderr)
    sys.exit(2)

from inject_skills import _glob_specificity  # single source of truth for "literal segment"

violations = []
parse_errors = []

for target in targets:
    p = Path(target)
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        parse_errors.append(f"{target}: {exc}")
        continue

    for bundle in data.get("bundles", []) or []:
        name = bundle.get("name", "<unnamed>")
        if name == "default":
            continue
        skills = bundle.get("skills") or []
        if not skills:
            continue  # recommends nothing → breadth is harmless
        has_contains = bool(bundle.get("contains"))
        if has_contains:
            continue  # file content-filtered → precise regardless of glob width
        has_task_contains = bool(bundle.get("task_contains"))
        if has_task_contains:
            continue  # task-text filtered → task_contains is the precision filter (F5)
        for glob in bundle.get("globs", []) or []:
            if _glob_specificity(glob) == 0:
                violations.append((target, name, glob))

if parse_errors:
    for msg in parse_errors:
        print(f"validate-skill-bundles: could not parse {msg}", file=sys.stderr)
    sys.exit(2)

if violations:
    print(
        "validate-skill-bundles: wide glob without a precision content filter.\n"
        "\n"
        "A glob with no literal path segments (e.g. `**/*`, `**/*.py`, "
        "`**/*graph*.py`) matches an entire language's files. When such a bundle "
        "recommends skills it MUST declare either a `contains:` predicate (file "
        "content filter) or a `task_contains:` predicate (task-text filter) so "
        "suggestions are scoped to the relevant context.\n",
        file=sys.stderr,
    )
    for target, name, glob in violations:
        print(f"  {target}: bundle '{name}' glob '{glob}' is wide but has no contains: or task_contains:", file=sys.stderr)
    print(
        "\nFix: add a `contains:` list (for file-routing) or a `task_contains:` list "
        "(for task-text routing) to the bundle, narrow the glob to include a literal "
        "directory segment, or move the skills into a content-filtered bundle.",
        file=sys.stderr,
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# F2: Cross-plugin bundle-name collision gate.
# Collect names from ALL skill-bundles.yml files across all plugins and
# report any name that appears in more than one file.
# ---------------------------------------------------------------------------
name_to_files = defaultdict(list)
all_bundle_files = sorted(repo_root.glob("plugins/*/config/skill-bundles.yml"))

for bf in all_bundle_files:
    try:
        bdata = yaml.safe_load(bf.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        continue  # silently skip unreadable files — per-file validation covers them
    for bundle in bdata.get("bundles", []) or []:
        bname = bundle.get("name", "")
        if bname and bname != "default":
            name_to_files[bname].append(str(bf))

collisions = {name: files for name, files in name_to_files.items() if len(files) > 1}

if collisions:
    print(
        "validate-skill-bundles: cross-plugin bundle-name collision detected.\n"
        "\n"
        "Bundle names must be unique across all plugins. Duplicate names cause "
        "silent routing bugs when inject_skills aggregates bundles at runtime.\n",
        file=sys.stderr,
    )
    for name, files in sorted(collisions.items()):
        print(f"  bundle '{name}' is defined in:", file=sys.stderr)
        for f in files:
            print(f"    {f}", file=sys.stderr)
    print(
        "\nFix: rename one of the colliding bundles to a unique name.",
        file=sys.stderr,
    )
    sys.exit(1)

sys.exit(0)
PY
