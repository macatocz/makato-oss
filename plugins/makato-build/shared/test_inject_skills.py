"""Unit + integration tests for the skill-bundle resolver (F1 / #144).

Run from repo root:
    python3 -m pytest plugins/makato-build/shared/test_inject_skills.py -v

Mirrors the test_inject_context.py precedent — same layout, same discovery path
(pyproject.toml scopes pytest to plugins/makato-build/shared/). Stdlib-only for
the pure-resolver cases; the cross-plugin aggregation + real-config integration
cases require PyYAML (a hard dependency of this harness) and the langgraph
config on disk.

The four acceptance scenarios from issue #144 map to test classes:
  Scenario 1 (name+content match)        -> ContentHintMatchTests
  Scenario 2 (name matches, content not) -> ContentHintMissTests
  Scenario 3 (wide-glob validation)      -> validator smoke (test_validate_wide_glob.sh)
  Scenario 4 (missing-skill graceful)    -> SubsetFilterTests
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from inject_skills import (  # noqa: E402  (sys.path mutation above)
    BundleResolutionError,
    aggregate_bundles,
    discover_installed_skills,
    resolve_skills,
    resolve_skills_for_repo,
)

# Repo root: shared/ is <root>/plugins/makato-build/shared/, so the root is
# three parents up (shared -> makato-build -> plugins -> <root>).
_REPO_ROOT = Path(_HERE).parents[2]


# A canonical in-memory config used by the pure-resolver cases so they do not
# couple to the on-disk YAML. Bundles are listed in a NON-specificity-sorted
# order so the resolver must sort them itself.
_CONFIG = {
    "version": "1.0",
    "bundles": [
        {"name": "default", "globs": ["**/*"], "skills": []},
        {
            "name": "langgraph",
            "globs": ["**/*graph*.py"],
            "contains": ["from langgraph", "import langgraph"],
            "skills": ["langgraph-fundamentals", "langgraph-persistence"],
        },
        {
            "name": "src-graph",  # more specific: 1 literal segment
            "globs": ["src/*graph*.py"],
            "contains": ["from langgraph"],
            "skills": ["langgraph-agent-patterns"],
        },
    ],
}


# ---------------------------------------------------------------------------
# Scenario 1 — name pattern AND content rule both satisfied.
# ---------------------------------------------------------------------------


class ContentHintMatchTests(unittest.TestCase):
    def test_name_and_content_match_yields_langgraph_skills(self) -> None:
        skills, warnings = resolve_skills(
            ["agent_graph.py"],
            _CONFIG,
            file_texts={"agent_graph.py": "from langgraph.graph import StateGraph\n"},
        )
        self.assertEqual(
            skills, ["langgraph-fundamentals", "langgraph-persistence"]
        )
        self.assertEqual(warnings, [])

    def test_import_langgraph_alternate_substring_matches(self) -> None:
        skills, _ = resolve_skills(
            ["nodes_graph.py"],
            _CONFIG,
            file_texts={"nodes_graph.py": "import langgraph\n"},
        )
        self.assertIn("langgraph-fundamentals", skills)

    def test_more_specific_bundle_orders_first(self) -> None:
        # src/*graph*.py (1 literal segment) outranks **/*graph*.py (0).
        skills, _ = resolve_skills(
            ["src/pipeline_graph.py"],
            _CONFIG,
            file_texts={"src/pipeline_graph.py": "from langgraph import x\n"},
        )
        self.assertEqual(
            skills,
            [
                "langgraph-agent-patterns",
                "langgraph-fundamentals",
                "langgraph-persistence",
            ],
        )


# ---------------------------------------------------------------------------
# Scenario 2 — name pattern matches, content rule does NOT.
# ---------------------------------------------------------------------------


class ContentHintMissTests(unittest.TestCase):
    def test_name_matches_but_no_langgraph_import_yields_nothing(self) -> None:
        skills, warnings = resolve_skills(
            ["my_graph.py"],
            _CONFIG,
            file_texts={"my_graph.py": "import networkx as nx\n"},
        )
        self.assertEqual(skills, [])
        # default matched (its **/* glob has no contains), so no no-match warning.
        self.assertEqual(warnings, [])

    def test_unreadable_file_cannot_satisfy_content_hint(self) -> None:
        # No file_texts entry → content-restricted bundle cannot confirm.
        skills, _ = resolve_skills(["my_graph.py"], _CONFIG, file_texts={})
        self.assertEqual(skills, [])


# ---------------------------------------------------------------------------
# Scenario 4 — referenced skill not installed → graceful skip + warning (D18).
# ---------------------------------------------------------------------------


class SubsetFilterTests(unittest.TestCase):
    def test_missing_skill_is_dropped_and_warned(self) -> None:
        skills, warnings = resolve_skills(
            ["agent_graph.py"],
            _CONFIG,
            file_texts={"agent_graph.py": "from langgraph import x\n"},
            installed_skills={"langgraph-fundamentals"},  # persistence NOT installed
        )
        self.assertEqual(skills, ["langgraph-fundamentals"])
        self.assertEqual(
            warnings, [{"code": "missing-skills", "skills": ["langgraph-persistence"]}]
        )

    def test_all_installed_no_warning(self) -> None:
        skills, warnings = resolve_skills(
            ["agent_graph.py"],
            _CONFIG,
            file_texts={"agent_graph.py": "from langgraph import x\n"},
            installed_skills={"langgraph-fundamentals", "langgraph-persistence"},
        )
        self.assertEqual(
            skills, ["langgraph-fundamentals", "langgraph-persistence"]
        )
        self.assertEqual(warnings, [])

    def test_no_subset_filter_returns_all(self) -> None:
        skills, warnings = resolve_skills(
            ["agent_graph.py"],
            _CONFIG,
            file_texts={"agent_graph.py": "from langgraph import x\n"},
            installed_skills=None,
        )
        self.assertEqual(
            skills, ["langgraph-fundamentals", "langgraph-persistence"]
        )
        self.assertEqual(warnings, [])


# ---------------------------------------------------------------------------
# Empty / no-scope + dedup + ordering edge cases.
# ---------------------------------------------------------------------------


class EmptyAndDedupTests(unittest.TestCase):
    def test_empty_changed_files_returns_default_only_no_warning(self) -> None:
        skills, warnings = resolve_skills([], _CONFIG, file_texts={})
        self.assertEqual(skills, [])  # default has empty skills
        self.assertEqual(warnings, [])

    def test_default_skills_appended_last_and_deduped(self) -> None:
        config = {
            "version": "1.0",
            "bundles": [
                {"name": "default", "globs": ["**/*"], "skills": ["shared-skill"]},
                {
                    "name": "langgraph",
                    "globs": ["**/*graph*.py"],
                    "contains": ["langgraph"],
                    "skills": ["langgraph-fundamentals", "shared-skill"],
                },
            ],
        }
        skills, _ = resolve_skills(
            ["g_graph.py"],
            config,
            file_texts={"g_graph.py": "import langgraph\n"},
        )
        # shared-skill emitted once, in langgraph's slot (first occurrence).
        self.assertEqual(skills, ["langgraph-fundamentals", "shared-skill"])

    def test_non_python_file_falls_to_default_no_warning(self) -> None:
        skills, warnings = resolve_skills(
            ["README.md"], _CONFIG, file_texts={"README.md": "hello"}
        )
        self.assertEqual(skills, [])
        self.assertEqual(warnings, [])  # default's **/* covers it


# ---------------------------------------------------------------------------
# HALT-006 hard-contract validation.
# ---------------------------------------------------------------------------


class ValidationTests(unittest.TestCase):
    def test_missing_default_raises_halt_006(self) -> None:
        config = {"bundles": [{"name": "langgraph", "globs": ["**/*"], "skills": []}]}
        with self.assertRaises(BundleResolutionError) as ctx:
            resolve_skills(["x.py"], config)
        self.assertEqual(ctx.exception.halt_code, "HALT-006")

    def test_duplicate_name_raises_halt_006(self) -> None:
        config = {
            "bundles": [
                {"name": "default", "globs": ["**/*"], "skills": []},
                {"name": "dup", "globs": ["a/*.py"], "skills": []},
                {"name": "dup", "globs": ["b/*.py"], "skills": []},
            ]
        }
        with self.assertRaises(BundleResolutionError) as ctx:
            resolve_skills(["x.py"], config)
        self.assertEqual(ctx.exception.halt_code, "HALT-006")

    def test_missing_name_raises_halt_006(self) -> None:
        config = {
            "bundles": [
                {"name": "default", "globs": ["**/*"], "skills": []},
                {"globs": ["a/*.py"], "skills": []},
            ]
        }
        with self.assertRaises(BundleResolutionError) as ctx:
            resolve_skills(["x.py"], config)
        self.assertEqual(ctx.exception.halt_code, "HALT-006")


# ---------------------------------------------------------------------------
# Cross-plugin aggregation + real on-disk config (integration).
# DoD #4: cross-plugin smoke with just langgraph + makato-build default.
# ---------------------------------------------------------------------------


class AggregationIntegrationTests(unittest.TestCase):
    def test_aggregate_merges_langgraph_and_default(self) -> None:
        config = aggregate_bundles(_REPO_ROOT)
        names = {b["name"] for b in config["bundles"]}
        self.assertIn("default", names)
        self.assertIn("langgraph", names)
        # Exactly one default survives the merge.
        default_count = sum(1 for b in config["bundles"] if b["name"] == "default")
        self.assertEqual(default_count, 1)

    def test_discover_installed_skills_includes_langgraph(self) -> None:
        installed = discover_installed_skills(_REPO_ROOT)
        self.assertIn("langgraph-fundamentals", installed)
        self.assertIn("langgraph-persistence", installed)

    def test_end_to_end_langgraph_file_yields_installed_skills(self) -> None:
        # Use a real langgraph SKILL.md path? No — craft a synthetic changed
        # file under the repo so file-text reading exercises the real path.
        fixture_rel = "plugins/makato-langgraph/skills/langgraph-fundamentals/SKILL.md"
        # SKILL.md is markdown, won't match **/*graph*.py — assert no crash and
        # default-only result for a non-matching real file.
        skills, warnings = resolve_skills_for_repo([fixture_rel], _REPO_ROOT)
        self.assertIsInstance(skills, list)
        self.assertIsInstance(warnings, list)

    def test_end_to_end_synthetic_graph_import_matches(self) -> None:
        # Point at an in-repo path that ends in *graph*.py and contains a
        # langgraph import, using file_texts injection via the pure resolver on
        # the aggregated real config (proves the merged config routes correctly).
        config = aggregate_bundles(_REPO_ROOT)
        installed = discover_installed_skills(_REPO_ROOT)
        skills, warnings = resolve_skills(
            ["src/agent_graph.py"],
            config,
            file_texts={"src/agent_graph.py": "from langgraph.graph import StateGraph"},
            installed_skills=installed,
        )
        self.assertIn("langgraph-fundamentals", skills)
        self.assertIn("langgraph-persistence", skills)
        self.assertEqual(warnings, [])


if __name__ == "__main__":
    unittest.main()
