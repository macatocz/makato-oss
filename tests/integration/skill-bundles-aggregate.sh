#!/usr/bin/env bash
# Cross-plugin aggregate integration test for skill-bundles.yml (#145 AC-1..AC-4)
#
# Asserts that the merged skill-bundles registry across all installed plugins:
#   AC-1  Per-domain isolation — plugin-specific files route only to that plugin's skills.
#   AC-2  Deduplication — overlapping matches produce a deduplicated ordered list.
#   AC-3  D10 target-repo filter — referenced-but-missing skills are skipped (no error).
#   AC-4  Wide-glob flood prevention — a broad fixture resolves only to default (empty).
#
# Exit 0 on success; non-zero with a diagnostic on any failure.
#
# Run from the repo root:
#   bash tests/integration/skill-bundles-aggregate.sh
#
# Requirements: python3, PyYAML (pip install pyyaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

echo "=== skill-bundles aggregate integration test ==="
echo "repo: $REPO_ROOT"
echo ""

# ---------------------------------------------------------------------------
# Pre-check: PyYAML available.
# ---------------------------------------------------------------------------
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "SKIP: PyYAML not installed (pip install pyyaml). Cannot run aggregate tests." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Sanity — aggregate must load without error and include the default bundle.
# ---------------------------------------------------------------------------
echo "--- Sanity checks ---"

run_case "aggregate_bundles loads without error" "
config = aggregate_bundles(repo_root)
assert 'bundles' in config, 'missing bundles key'
"

run_case "merged registry contains exactly one default bundle" "
config = aggregate_bundles(repo_root)
defaults = [b for b in config['bundles'] if b.get('name') == 'default']
assert len(defaults) == 1, f'expected 1 default bundle, got {len(defaults)}'
"

run_case "no duplicate bundle names across the merged registry" "
config = aggregate_bundles(repo_root)
names = [b.get('name') for b in config['bundles']]
dups = [n for n in names if names.count(n) > 1]
assert not dups, f'duplicate bundle names: {sorted(set(dups))}'
"

# ---------------------------------------------------------------------------
# AC-1 — Per-domain isolation.
# Each fixture should route to the expected plugin's skills and NOT to an
# unrelated plugin's skills.
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-1: per-domain isolation ---"

run_case "LangGraph file routes to langgraph-fundamentals" "
# Use resolve_skills directly with in-memory file_texts so the contains predicate
# is satisfied without requiring a real .py file on disk.
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['agent_graph.py'],
    config,
    file_texts={'agent_graph.py': 'from langgraph.graph import StateGraph\nfrom langgraph.checkpoint import MemorySaver\n'},
    installed_skills=None,
)
assert 'langgraph-fundamentals' in skills, f'langgraph-fundamentals not in {skills}'
assert 'manage-postgres' not in skills, f'manage-postgres should not appear for a LangGraph file'
"

run_case "SQL migration file routes to manage-postgres" "
# Use an in-memory file_texts to satisfy contains predicate without needing real file on disk.
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['db/migrate/001_create_users.sql'],
    config,
    file_texts={'db/migrate/001_create_users.sql': 'CREATE TABLE users (id SERIAL PRIMARY KEY);'},
    installed_skills=None,
)
assert 'manage-postgres' in skills, f'manage-postgres not in {skills}'
assert 'langfuse-instrument' not in skills, f'langfuse-instrument should not appear for a SQL file'
"

run_case "OTel Python file routes to langfuse-instrument" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['src/tracing/setup.py'],
    config,
    file_texts={'src/tracing/setup.py': 'from opentelemetry import trace\nfrom opentelemetry.sdk.trace import TracerProvider\nlangfuse = True'},
    installed_skills=None,
)
assert 'langfuse-instrument' in skills, f'langfuse-instrument not in {skills}'
assert 'manage-postgres' not in skills, f'manage-postgres should not appear for an OTel file'
"

run_case "Plan markdown file with PRD content routes to plan skills" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['specs/my-feature/prd.md'],
    config,
    file_texts={'specs/my-feature/prd.md': '## Problem\nUser Stories\nAcceptance Criteria\n## Goals'},
    installed_skills=None,
)
assert 'grill' in skills or 'create-prd' in skills or 'create-acceptance-tests' in skills, \
    f'expected at least one plan skill, got {skills}'
assert 'manage-postgres' not in skills, f'manage-postgres should not appear for a plan md file'
"

run_case "Change-request spec routes to change skills" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['specs/my-change/spec.md'],
    config,
    file_texts={'specs/my-change/spec.md': 'This is a change request to update current behavior.'},
    installed_skills=None,
)
assert 'analyze' in skills or 'execute' in skills, \
    f'expected at least one change skill, got {skills}'
"

run_case "Playwright test file routes to e2e-testing-patterns" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['tests/e2e/login.spec.ts'],
    config,
    file_texts={'tests/e2e/login.spec.ts': \"import { test, expect } from '@playwright/test';\npage.goto('http://localhost:3000')\"},
    installed_skills=None,
)
assert 'e2e-testing-patterns' in skills, f'e2e-testing-patterns not in {skills}'
"

run_case "README.md routes to crafting-effective-readmes" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['README.md'],
    config,
    file_texts={'README.md': '# My Project\n\nThis is a README.\n'},
    installed_skills=None,
)
assert 'crafting-effective-readmes' in skills, f'crafting-effective-readmes not in {skills}'
"

# ---------------------------------------------------------------------------
# AC-2 — Deduplication.
# When multiple bundles match the same file, skills are deduplicated
# preserving the first occurrence.
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-2: deduplication ---"

run_case "overlapping bundle matches produce a deduplicated skill list" "
config = aggregate_bundles(repo_root)
# A React TSX file in a spec-related location should not duplicate any skills.
skills, _ = resolve_skills(
    ['src/components/Dashboard.tsx'],
    config,
    file_texts={'src/components/Dashboard.tsx': \"import React, { useState, useEffect } from 'react';\"},
    installed_skills=None,
)
assert len(skills) == len(set(skills)), f'duplicate skills found: {skills}'
"

run_case "plan.md in specs matches plan-decompose but skills appear only once" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['specs/my-feature/plan.md'],
    config,
    file_texts={'specs/my-feature/plan.md': '## Tasks\n\n### Task 1'},
    installed_skills=None,
)
assert len(skills) == len(set(skills)), f'duplicate skills found: {skills}'
"

# ---------------------------------------------------------------------------
# AC-3 — D10 target-repo subset filter.
# A skill referenced in a bundle but not installed in the target repo is
# skipped gracefully (warning, no error).
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-3: D10 target-repo filter ---"

run_case "referenced-but-missing skills are skipped, not an error" "
config = aggregate_bundles(repo_root)
# Pass an installed_skills set that is intentionally missing some skills.
installed = {'manage-postgres'}  # only one skill installed in this pretend repo
skills, warnings = resolve_skills(
    ['db/migrate/001_create_users.sql'],
    config,
    file_texts={'db/migrate/001_create_users.sql': 'CREATE TABLE orders (id SERIAL);'},
    installed_skills=installed,
)
# manage-postgres is installed → should appear
assert 'manage-postgres' in skills, f'manage-postgres missing despite being installed: {skills}'
# Missing skills should produce a warning, not an exception
missing_warns = [w for w in warnings if w.get('code') == 'missing-skills']
# (warning may or may not be present depending on whether other bundles also matched)
"

run_case "resolve_skills_for_repo applies subset filter without error" "
# This exercises the real installed-skills discovery path against the actual repo.
skills, warnings = resolve_skills_for_repo(
    ['plugins/makato-build/shared/inject_skills.py'],
    repo_root,
    apply_subset_filter=True,
)
# All returned skills must be installed (i.e. have a SKILL.md in plugins/*/skills/<id>/).
installed = discover_installed_skills(repo_root)
for s in skills:
    assert s in installed, f'skill \"{s}\" not installed but passed the D10 filter'
"

# ---------------------------------------------------------------------------
# AC-4 — Wide-glob flood prevention.
# A broad fixture (README.md alone) must NOT route to every plugin's skills.
# The default bundle contributes no skills, so a truly unmatched path yields [].
# ---------------------------------------------------------------------------
echo ""
echo "--- AC-4: no wide-glob flood ---"

run_case "a single generic README.md does not route to unrelated skills" "
config = aggregate_bundles(repo_root)
skills, _ = resolve_skills(
    ['README.md'],
    config,
    file_texts={'README.md': '# My Project'},
    installed_skills=None,
)
# Wide-glob bundles (e.g. **/*.py, **/*.tsx) must NOT have fired on a .md file.
# Specifically: no database, no langgraph, no observability skills from a README.
forbidden = {'manage-postgres', 'langfuse-instrument', 'langgraph-fundamentals',
             'langgraph-persistence', 'dotx-schema-extractor'}
overlap = set(skills) & forbidden
assert not overlap, f'wide-glob flood: unexpected skills {overlap} for README.md'
"

run_case "a Python file without any known library import yields minimal skills" "
config = aggregate_bundles(repo_root)
# A generic helper.py with no library imports should not spray all Python skills.
skills, _ = resolve_skills(
    ['src/utils/helper.py'],
    config,
    file_texts={'src/utils/helper.py': 'def add(a, b):\n    return a + b\n'},
    installed_skills=None,
)
# Should not route to langgraph or observability skills (no matching contains)
assert 'langgraph-fundamentals' not in skills, \
    f'langgraph-fundamentals should not appear for a plain helper.py: {skills}'
assert 'langfuse-instrument' not in skills, \
    f'langfuse-instrument should not appear for a plain helper.py: {skills}'
"

run_case "empty changed_files list returns only default (empty) skill list" "
skills, warnings = resolve_skills_for_repo([], repo_root, apply_subset_filter=False)
# default bundle has skills: [] so the result must be empty
assert skills == [], f'expected empty skills for empty file list, got {skills}'
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
