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
# Uses Python 3 stdlib only (yaml via pyyaml is NOT used — we parse the
# restricted YAML subset with a hand-written parser matching the pattern
# established in mark-ac-checkboxes.sh / sync-living-specs.sh).
#
# Usage:
#   workflow-schema-loader.sh <repo-root>
#
#   repo-root   Absolute path to the repository root. Required.
#
# Output (stdout, one per line):
#   Each line is a JSON object: {"id":"<id>","skill":"<skill>","required":<bool>}
#
# Exit codes:
#   0   success — artifact list printed to stdout
#   1   error   — cycle detected, parse error, or invalid schema (details on stderr)
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
# Parse YAML and validate DAG using embedded Python 3 (stdlib only).
#
# The YAML format is a restricted subset:
#   - top-level key: artifacts (list)
#   - each list item has: id, skill, required, description (opt), after (opt)
# We parse this with a line-by-line state machine rather than a full YAML
# parser to stay stdlib-only, matching the project's existing pattern.
# ---------------------------------------------------------------------------
python3 - "$SCHEMA_FILE" "$SCHEMA_SOURCE" <<'PYEOF'
import sys
import json

schema_file = sys.argv[1]
schema_source = sys.argv[2]

def parse_schema(path):
    """Parse the restricted YAML schema format into a list of artifact dicts."""
    artifacts = []
    current = None
    in_artifacts = False
    in_after = False
    in_item = False

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

        # Top-level section detection
        if stripped == 'artifacts:':
            in_artifacts = True
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

    return artifacts


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
    artifacts = parse_schema(schema_file)
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
    print(json.dumps({
        "id": a['id'],
        "skill": a['skill'],
        "required": a['required'],
        "description": a.get('description', '')
    }))

PYEOF
