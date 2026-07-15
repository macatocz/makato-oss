#!/usr/bin/env bash
# Smoke tests for the design → execute skill-injection path (#429)
#
# Asserts that:
#   AC-7a  resolve_skills_for_repo returns expected technology skills for a representative
#          affected-file set (e.g. FastAPI/Postgres/LangGraph source files).
#   AC-7b  The design.md template contains the ## Recommended Skills section.
#   AC-7c  execute Step 2.1 references the field sourced from design (not hand-inserted).
#   AC-7d  The empty-result contract: an affected-file set with no bundle match produces
#          no recommended_skills output (section omitted, not an empty array).
#
# Exit 0 on success; non-zero with a diagnostic on the first failure.
#
# Run from the repo root:
#   bash plugins/makato-change/shared/skill-injection-smoke-tests.sh
#
# Requirements: python3, PyYAML (pip install pyyaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PASS=0
FAIL=0
ERRORS=()

# ---------------------------------------------------------------------------
# Helper — run a single Python assertion and track pass/fail.
# ---------------------------------------------------------------------------
run_case() {
  local label="$1"
  local code="$2"
  if python3 - "$REPO_ROOT" <<PY
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
sys.path.insert(0, str(repo_root / "plugins" / "makato-build" / "shared"))

from inject_skills import aggregate_bundles, discover_installed_skills, resolve_skills, resolve_skills_for_repo, BundleResolutionError

$code
PY
  then
    echo "  PASS: $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $label"
    FAIL=$(( FAIL + 1 ))
    ERRORS+=("$label")
  fi
}

# ---------------------------------------------------------------------------
# Helper — run a shell assertion and track pass/fail.
# ---------------------------------------------------------------------------
run_shell_case() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $label"
    FAIL=$(( FAIL + 1 ))
    ERRORS+=("$label")
  fi
}

echo "=== makato-change skill-injection smoke tests (#429) ==="
echo "repo: $REPO_ROOT"
echo ""

# ---------------------------------------------------------------------------
# Pre-check: PyYAML available.
# ---------------------------------------------------------------------------
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "SKIP: PyYAML not installed (pip install pyyaml). Cannot run skill-injection tests." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# AC-7a: representative file sets route to expected technology skills.
# These prove change requests now get the same coverage coder would receive for
# the same files.
# ---------------------------------------------------------------------------
echo "--- AC-7a: technology skill routing for change-request file sets ---"

run_case "FastAPI source file routes to a web-framework skill" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['src/api/routes.py'],
    config,
    file_texts={'src/api/routes.py': 'from fastapi import FastAPI, APIRouter\nfrom fastapi.responses import JSONResponse\napp = FastAPI()\n'},
    installed_skills=None,
)
# The fastapi or equivalent web-framework skill should be present.
# We check that SOME skill is returned — the exact name depends on what the bundle
# declares, and the D10 filter is intentionally bypassed here (installed_skills=None).
# The important assertion is that the resolver does NOT return an empty list for a
# file with a known framework import.
assert len(skills) > 0, f'expected at least one skill for a FastAPI file, got {skills!r}'
"

run_case "Postgres migration file routes to manage-postgres" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['db/migrate/0001_add_users.sql'],
    config,
    file_texts={'db/migrate/0001_add_users.sql': 'CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT);\nCREATE INDEX idx_users_name ON users(name);'},
    installed_skills=None,
)
assert 'manage-postgres' in skills, f'manage-postgres not in {skills!r}'
"

run_case "LangGraph agent file routes to langgraph-fundamentals" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['agents/my_graph.py'],
    config,
    file_texts={'agents/my_graph.py': 'from langgraph.graph import StateGraph\nfrom langgraph.checkpoint import MemorySaver\nbuilder = StateGraph()\n'},
    installed_skills=None,
)
assert 'langgraph-fundamentals' in skills, f'langgraph-fundamentals not in {skills!r}'
"

run_case "resolve_skills_for_repo end-to-end with subset filter for a makato-change skill file" "
# Representative affected-file set for a change request touching makato-change skills.
# The change-skills bundle (plugins/makato-change/skills/**/*.md) should route to
# design/execute/analyze skills (verified via the D10 installed-skills filter).
skills, warnings = resolve_skills_for_repo(
    ['plugins/makato-change/skills/design/SKILL.md'],
    repo_root,
    apply_subset_filter=True,
)
# All returned skills must pass the D10 installed-skills filter.
installed = discover_installed_skills(repo_root)
for s in skills:
    assert s in installed, f'skill \"{s}\" returned but not installed (D10 violated): {skills!r}'
# At least one change-workflow skill must be returned (the change-skills bundle).
change_skills = {'orchestrate', 'analyze', 'design', 'execute', 'resolve-review'}
overlap = set(skills) & change_skills
assert len(overlap) > 0, f'expected at least one change-workflow skill, got {skills!r}'
"

# ---------------------------------------------------------------------------
# AC-7b: design.md template contains the ## Recommended Skills section.
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-7b: design.md template structure ---"

TEMPLATE_PATH="$REPO_ROOT/plugins/makato-change/skills/design/templates/design.md"

run_shell_case "design.md template exists" \
  test -f "$TEMPLATE_PATH"

run_shell_case "design.md template contains ## Recommended Skills section" \
  grep -q "## Recommended Skills" "$TEMPLATE_PATH"

run_shell_case "design.md template documents the execute Step 2.1 forward wiring" \
  grep -q "execute" "$TEMPLATE_PATH"

# ---------------------------------------------------------------------------
# AC-7c: execute Step 2.1 prose references design as the source of the field.
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-7c: execute Step 2.1 references design as source ---"

EXECUTE_SKILL="$REPO_ROOT/plugins/makato-change/skills/execute/SKILL.md"

run_shell_case "execute SKILL.md exists" \
  test -f "$EXECUTE_SKILL"

run_shell_case "execute Step 2.1 references design Step 4.5 as the field source" \
  grep -q "design.*Step 4.5\|Step 4.5.*design" "$EXECUTE_SKILL"

run_shell_case "execute Step 2.1 references ## Recommended Skills section in design.md" \
  grep -q "## Recommended Skills" "$EXECUTE_SKILL"

run_shell_case "execute Step 2.2 wires RECOMMENDED_SKILLS into the dispatch bundle" \
  grep -q "RECOMMENDED_SKILLS" "$EXECUTE_SKILL"

# ---------------------------------------------------------------------------
# AC-7d: empty-result contract — no bundle match → no skills → section omitted.
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-7d: empty-result contract ---"

run_case "empty changed_files list returns an empty skill list (no section)" "
skills, _ = resolve_skills_for_repo([], repo_root, apply_subset_filter=False)
# Default bundle has skills: [] so the result must be empty.
assert skills == [], f'expected empty skills for empty file list, got {skills!r}'
"

run_case "an unknown file extension produces at most the default skills (no flood)" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['some/binary.unknown_ext'],
    config,
    file_texts={'some/binary.unknown_ext': ''},
    installed_skills=None,
)
# An unknown extension should not cause an exception and should not route to
# technology skills. If any skills are returned they come only from the default bundle.
default_bundles = [b for b in config['bundles'] if b.get('name') == 'default']
default_skills = set()
for b in default_bundles:
    default_skills.update(b.get('skills', []))
non_default = [s for s in skills if s not in default_skills]
assert non_default == [], f'unexpected non-default skills for unknown extension: {non_default!r}'
"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo ""
  echo "Failed cases:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

exit 0
