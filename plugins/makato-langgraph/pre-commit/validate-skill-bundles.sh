#!/usr/bin/env bash
# validate-skill-bundles.sh — pre-commit gate for skill-bundles.yml (D18 authoring-time)
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
#   2  a staged skill-bundles.yml could not be parsed
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
# The validation logic lives in Python so it can reuse the resolver's
# `_glob_specificity` definition of "literal segment" — the single source of
# truth for what "wide" means. Keeping the definition in one place stops the
# gate and the resolver from drifting.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shared/ is a sibling-of-a-sibling: <repo>/plugins/makato-build/shared/
SHARED_DIR="$(cd "$SCRIPT_DIR/../../makato-build/shared" && pwd)"

python3 - "$SHARED_DIR" "${files[@]}" <<'PY'
import sys
from pathlib import Path

shared_dir = sys.argv[1]
targets = sys.argv[2:]
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

sys.exit(0)
PY
