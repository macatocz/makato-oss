#!/usr/bin/env bash
# validate-context-bundles.sh — pre-commit gate for context-bundles.yml (#324)
#
# Rejects any context-bundles.yml that would trigger HALT-006 at runtime:
#   * missing `default` bundle
#   * duplicate bundle names
#   * bundle entry missing the required `name` field
#
# Delegates to inject_context.resolve_bundles() — the single source of truth for
# all HALT-006 conditions — so the gate and the runtime resolver cannot drift.
#
# Exit codes:
#   0  all staged context-bundles.yml files pass (or none are staged)
#   1  at least one HALT-006 condition detected (message on stderr)
#   2  a staged context-bundles.yml could not be parsed (PyYAML missing or invalid YAML)
#
# Invocation:
#   pre-commit `language: system` hook with `files: context-bundles\.yml$`,
#   or standalone: `validate-context-bundles.sh [<file> ...]`. With no arguments
#   it inspects the git-staged context-bundles.yml files.
set -euo pipefail

# ---------------------------------------------------------------------------
# Collect the files to check: explicit args, else staged context-bundles.yml.
# ---------------------------------------------------------------------------
files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E '(^|/)context-bundles\.yml$' || true)
fi

if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Delegate to inject_context.resolve_bundles — the single source of truth for
# HALT-006 conditions. An empty changed-files list is passed because all
# schema-validation guards fire before any file-matching code runs.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/../shared" && pwd)"

python3 - "$SHARED_DIR" "${files[@]}" <<'PY'
import sys
from pathlib import Path

shared_dir = sys.argv[1]
targets = sys.argv[2:]
sys.path.insert(0, shared_dir)

try:
    import yaml
except ImportError:
    print(
        "validate-context-bundles: PyYAML is required but not installed.\n"
        "Install it with: pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(2)

from inject_context import BundleResolutionError, resolve_bundles

errors = []
parse_errors = []

for target in targets:
    p = Path(target)
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        parse_errors.append(f"{target}: {exc}")
        continue

    try:
        resolve_bundles([], data)
    except BundleResolutionError as exc:
        errors.append((target, str(exc)))

if parse_errors:
    for msg in parse_errors:
        print(f"validate-context-bundles: could not parse {msg}", file=sys.stderr)
    sys.exit(2)

if errors:
    print(
        "validate-context-bundles: HALT-006 condition detected in context-bundles.yml.\n"
        "\n"
        "The resolver requires a bundle named `default` (catch-all fallback). "
        "Every bundle entry must also declare a unique `name` field. "
        "A commit that introduces any of these conditions will trigger a runtime "
        "HALT-006 in the autonomous pipeline.\n",
        file=sys.stderr,
    )
    for target, msg in errors:
        print(f"  {target}: {msg}", file=sys.stderr)
    print(
        "\nFix: ensure context-bundles.yml declares a `default` bundle with "
        "`globs: ['**/*']`, all bundle names are unique, and every bundle entry "
        "has a `name` field.",
        file=sys.stderr,
    )
    sys.exit(1)

sys.exit(0)
PY
