#!/usr/bin/env bash
# workflow-schema-loader.sh — resolve the workflow schema and return an ordered
# artifact list for makato-build pipeline assembly.
#
# When .claude/workflow-schema.yml is absent: prints the built-in default
# artifact list from plugins/makato-build/config/default-workflow-schema.yml
# (exit 0).
#
# When .claude/workflow-schema.yml is present: parses YAML, validates the DAG
# for cycles (direct and transitive), then prints the topologically sorted
# artifact list to stdout (exit 0). On parse error or cycle: prints a clear
# error message to stderr and exits 1.
#
# Artifact lists use a restricted hand-written YAML parser. Skill execution
# settings are resolved by shared/skill_execution.py, which requires PyYAML.
#
# Usage:
#   workflow-schema-loader.sh <repo-root>
#
#   repo-root   Absolute path to the repository root. Required.
#
# Output (stdout, one per line):
#   Each line is a JSON object with artifact fields plus resolved "role" and "effort".
#
# Exit codes:
#   0   success — artifact list printed to stdout
#   1   error   — cycle, parse/execution-config error, or invalid schema (details on stderr)
#   2   usage   — missing required argument
#
# Issue: #563

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "workflow-schema-loader: usage: workflow-schema-loader.sh <repo-root>" >&2
  exit 2
fi

REPO_ROOT="$1"
CUSTOM_SCHEMA="$REPO_ROOT/.claude/workflow-schema.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SCHEMA="$SCRIPT_DIR/../config/default-workflow-schema.yml"

# ---------------------------------------------------------------------------
# Determine which schema file to load
# ---------------------------------------------------------------------------
if [[ -f "$CUSTOM_SCHEMA" ]]; then
  SCHEMA_FILE="$CUSTOM_SCHEMA"
  SCHEMA_SOURCE="custom"
else
  SCHEMA_FILE="$DEFAULT_SCHEMA"
  SCHEMA_SOURCE="default"
fi

# ---------------------------------------------------------------------------
# Validate schema file is not empty
# ---------------------------------------------------------------------------
if [[ ! -s "$SCHEMA_FILE" ]]; then
  echo "workflow-schema-loader: parse error: schema file is empty: $SCHEMA_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse artifacts and validate DAG using embedded Python 3. The parser stops at
# top-level section boundaries so skill_execution and later sections are ignored.
# Artifacts retain their restricted hand-written YAML subset; execution settings
# are resolved with the shared PyYAML-backed resolver.
# ---------------------------------------------------------------------------
python3 - "$SCHEMA_FILE" "$SCHEMA_SOURCE" "$REPO_ROOT" "$DEFAULT_SCHEMA" "$SCRIPT_DIR/../shared" <<'PYEOF'
import sys
import json
from pathlib import Path

schema_file = sys.argv[1]
schema_source = sys.argv[2]
repo_root = Path(sys.argv[3])
default_schema = Path(sys.argv[4])
sys.path.insert(0, sys.argv[5])

try:
    from skill_execution import resolve_execution
except Exception as e:
    print(f"workflow-schema-loader: execution config error: cannot load resolver: {e}", file=sys.stderr)
    sys.exit(1)

def parse_schema(path):
    """Parse artifact YAML only; return artifact-section metadata."""
    artifacts = []
    current = None
    in_artifacts = False
    in_after = False
    in_item = False
    has_artifacts = False
    has_skill_execution = False
    with open(path, "r") as f:
        lines = f.readlines()

    if not any(line.strip() and not line.strip().startswith('#') for line in lines):
        print(f"workflow-schema-loader: parse error: schema file is empty: {path}", file=sys.stderr)
        sys.exit(1)

    for raw_line in lines:
        line = raw_line.rstrip()
        stripped = line.strip()

        # Skip comments and blank lines
        if not stripped or stripped.startswith('#'):
            continue

        # A new top-level key ends artifacts parsing. Record execution-only
        # project schemas so the built-in artifact list can still be used.
        if line and not line[0].isspace():
            key = stripped.partition(':')[0].strip().strip('"').strip("'")
            if key == 'artifacts' and stripped.partition(':')[2].strip() == '':
                if current is not None:
                    artifacts.append(current)
                    current = None
                in_artifacts = True
                in_after = False
                in_item = False
                has_artifacts = True
                continue
            if in_artifacts and current is not None:
                artifacts.append(current)
                current = None
            in_artifacts = False
            in_after = False
            in_item = False
            if key == 'skill_execution':
                has_skill_execution = True
            continue

        if not in_artifacts:
            continue

        # Detect new list item (starts with "  - " at 2-space indent)
        if stripped.startswith('- ') and line.startswith('  - '):
            if current is not None:
                artifacts.append(current)
            current = {'id': None, 'skill': None, 'required': True,
                       'description': '', 'after': []}
            in_after = False
            in_item = True
            # Parse inline key: value after the dash
            kv = stripped[2:].strip()
            _parse_kv(current, kv)
            continue

        if not in_item or current is None:
            continue

        # Indented sub-key (4+ spaces) or after-list item
        if stripped.startswith('- ') and in_after:
            # after list item: "    - some-id"
            val = stripped[2:].strip().strip('"').strip("'")
            current['after'].append(val)
            continue

        if ':' in stripped and not stripped.startswith('-'):
            in_after = False
            key, _, rest = stripped.partition(':')
            key = key.strip()
            val = rest.strip().strip('"').strip("'")
            if key == 'after':
                in_after = True
                # handle inline list like: after: [a, b]
                if val.startswith('[') and val.endswith(']'):
                    inner = val[1:-1].strip()
                    if inner:
                        current['after'] = [
                            x.strip().strip('"').strip("'")
                            for x in inner.split(',')
                            if x.strip()
                        ]
                    in_after = False
            elif key == 'id':
                current['id'] = val
            elif key == 'skill':
                current['skill'] = val
            elif key == 'required':
                current['required'] = val.lower() not in ('false', '0', 'no')
            elif key == 'description':
                current['description'] = val

    if current is not None:
        artifacts.append(current)

    return artifacts, has_artifacts, has_skill_execution


def _parse_kv(item, kv):
    """Parse a single 'key: value' string into item dict."""
    if ':' not in kv:
        return
    key, _, rest = kv.partition(':')
    key = key.strip()
    val = rest.strip().strip('"').strip("'")
    if key == 'id':
        item['id'] = val
    elif key == 'skill':
        item['skill'] = val
    elif key == 'required':
        item['required'] = val.lower() not in ('false', '0', 'no')
    elif key == 'description':
        item['description'] = val


def detect_cycle(artifacts):
    """
    Detect cycles in the artifact DAG using iterative DFS.
    Returns (True, cycle_path_string) if a cycle exists, else (False, '').
    """
    # Build adjacency list by id
    adj = {a['id']: list(a.get('after', [])) for a in artifacts}
    ids = list(adj.keys())

    # DFS colour: 0=white, 1=grey(in-stack), 2=black(done)
    colour = {i: 0 for i in ids}
    parent = {i: None for i in ids}

    def find_cycle_from(start):
        stack = [(start, iter(adj.get(start, [])))]
        colour[start] = 1
        path = [start]
        while stack:
            node, children = stack[-1]
            try:
                child = next(children)
                if child not in colour:
                    # Unknown id in after[] — skip (structural errors caught elsewhere)
                    continue
                if colour[child] == 1:
                    # Back edge: cycle found — reconstruct path
                    cycle_start_idx = path.index(child)
                    cycle = path[cycle_start_idx:] + [child]
                    return ' -> '.join(cycle)
                if colour[child] == 0:
                    colour[child] = 1
                    path.append(child)
                    stack.append((child, iter(adj.get(child, []))))
            except StopIteration:
                colour[node] = 2
                path.pop() if path else None
                stack.pop()
        return None

    for node_id in ids:
        if colour[node_id] == 0:
            cycle_path = find_cycle_from(node_id)
            if cycle_path:
                return True, cycle_path

    return False, ''


def topological_sort(artifacts):
    """
    Return artifacts in topological order (dependency-first).
    Assumes no cycles (call detect_cycle first).
    """
    adj = {a['id']: list(a.get('after', [])) for a in artifacts}
    by_id = {a['id']: a for a in artifacts}
    visited = set()
    order = []

    def visit(node_id):
        if node_id in visited:
            return
        visited.add(node_id)
        for dep in adj.get(node_id, []):
            if dep in by_id:
                visit(dep)
        order.append(node_id)

    for a in artifacts:
        visit(a['id'])

    return [by_id[i] for i in order if i in by_id]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try:
    artifacts, has_artifacts, has_skill_execution = parse_schema(schema_file)
    if schema_source == 'custom' and not has_artifacts and has_skill_execution:
        artifacts, has_artifacts, _ = parse_schema(default_schema)
except Exception as e:
    print(f"workflow-schema-loader: parse error: {e}", file=sys.stderr)
    sys.exit(1)

if not artifacts:
    print(f"workflow-schema-loader: parse error: no artifacts found in schema: {schema_file}", file=sys.stderr)
    sys.exit(1)

# Validate all artifact ids are present
for a in artifacts:
    if not a.get('id'):
        print(f"workflow-schema-loader: parse error: artifact missing required field 'id'", file=sys.stderr)
        sys.exit(1)
    if not a.get('skill'):
        print(f"workflow-schema-loader: parse error: artifact '{a['id']}' missing required field 'skill'", file=sys.stderr)
        sys.exit(1)

# Detect cycles
has_cycle, cycle_path = detect_cycle(artifacts)
if has_cycle:
    print(f"workflow-schema-loader: cycle detected: {cycle_path}", file=sys.stderr)
    sys.exit(1)

# Sort topologically and emit
sorted_artifacts = topological_sort(artifacts)
for a in sorted_artifacts:
    try:
        execution = resolve_execution(
            repo_root,
            a['skill'],
            default_schema=default_schema,
            allow_unknown=True,
        )
    except Exception as e:
        print(f"workflow-schema-loader: execution config error: {e}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps({
        "id": a['id'],
        "skill": a['skill'],
        "required": a['required'],
        "description": a.get('description', ''),
        "role": execution['role'],
        "effort": execution['effort'],
    }))

PYEOF
