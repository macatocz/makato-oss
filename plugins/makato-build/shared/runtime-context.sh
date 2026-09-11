#!/usr/bin/env bash
# Resolve installed makato plugin roots without depending on the consumer CWD.
#
# Usage:
#   runtime-context.sh plugin-root <makato-build|makato-plan|makato-orchestrate>
#
# The active runner normally exposes CLAUDE_PLUGIN_ROOT, OMP_PLUGIN_ROOT, or
# PLUGIN_ROOT. Explicit MAKATO_*_ROOT values are preferred for sibling plugins
# because each installed plugin can have a different cache directory.

set -euo pipefail

PLUGIN_NAME="${2:-makato-build}"

case "$PLUGIN_NAME" in
  makato-build)
    ROOT_OVERRIDE="${MAKATO_BUILD_ROOT:-}"
    ROOT_ENV="MAKATO_BUILD_ROOT"
    ;;
  makato-orchestrate)
    ROOT_OVERRIDE="${MAKATO_ORCHESTRATE_ROOT:-}"
    ROOT_ENV="MAKATO_ORCHESTRATE_ROOT"
    ;;
  makato-plan)
    ROOT_OVERRIDE="${MAKATO_PLAN_ROOT:-}"
    ROOT_ENV="MAKATO_PLAN_ROOT"
    ;;
  *)
    echo "runtime-context: unsupported plugin '$PLUGIN_NAME'" >&2
    exit 2
    ;;
esac

_is_plugin_root() {
  local candidate="$1"
  [[ -f "$candidate/.claude-plugin/plugin.json" ]] || return 1
  python3 - "$candidate/.claude-plugin/plugin.json" "$PLUGIN_NAME" <<'PY'
import json
import sys

path, expected = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if data.get("name") == expected else 1)
PY
}

if [[ -n "$ROOT_OVERRIDE" ]] && _is_plugin_root "$ROOT_OVERRIDE"; then
  printf '%s\n' "$(cd "$ROOT_OVERRIDE" && pwd)"
  exit 0
fi

if [[ "$PLUGIN_NAME" == "makato-build" ]]; then
  for candidate in "${CLAUDE_PLUGIN_ROOT:-}" "${OMP_PLUGIN_ROOT:-}" "${PLUGIN_ROOT:-}"; do
    if [[ -n "$candidate" ]] && _is_plugin_root "$candidate"; then
      printf '%s\n' "$(cd "$candidate" && pwd)"
      exit 0
    fi
  done
fi

# Source-checkout fallback: useful for makato-oss development and CI fixtures.
REPO_ROOT="${REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]] && git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  REPO_ROOT="$git_root"
fi
if [[ -n "$REPO_ROOT" ]]; then
  candidate="$REPO_ROOT/plugins/$PLUGIN_NAME"
  if _is_plugin_root "$candidate"; then
    printf '%s\n' "$(cd "$candidate" && pwd)"
    exit 0
  fi
fi

# OMP keeps sibling plugin roots in its registry. This fallback is deliberately
# runner-specific and only runs when an explicit sibling root was not supplied.
if [[ "$PLUGIN_NAME" != "makato-build" ]] && command -v omp >/dev/null 2>&1; then
  install_path="$(
    omp plugin list --json 2>/dev/null |
      python3 -c 'import json,sys
name=sys.argv[1]
try:
    data=json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
for item in data.get("marketplace", []):
    if item.get("id", "").split("@", 1)[0] == name:
        entries=item.get("entries", [])
        if entries and entries[0].get("installPath"):
            print(entries[0]["installPath"])
            break
' "$PLUGIN_NAME"
  )"
  if [[ -n "$install_path" ]] && _is_plugin_root "$install_path"; then
    printf '%s\n' "$(cd "$install_path" && pwd)"
    exit 0
  fi
fi

echo "runtime-context: unable to resolve installed root for $PLUGIN_NAME; set $ROOT_ENV or the runner plugin-root variable" >&2
exit 1
