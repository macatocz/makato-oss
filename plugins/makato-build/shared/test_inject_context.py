"""Unit + integration tests for the context-bundle resolver.

Run from repo root:
    python3 -m unittest discover plugins/makato-build/shared -p 'test_*.py'

Stdlib only (mirrors `parse-sarif.py --selftest` precedent). PyYAML is required
for the integration test because the production config is YAML — the integration
test will be skipped if PyYAML is unavailable.
"""

from __future__ import annotations

import os
import sys
import unittest

# Allow `from inject_context import …` whether discovery is run from the repo
# root or from the shared/ directory itself. unittest's discovery uses the
# discovery path's parent as sys.path[0], so we also add the directory holding
# this file.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from inject_context import (  # noqa: E402  (sys.path mutation above)
    BundleResolutionError,
    resolve_bundles,
)

# A canonical in-memory config used by every unit case so the tests do not
# couple to the production YAML file. Bundles are intentionally listed in an
# order that is NOT specificity-sorted so the resolver must do the sort itself.
_CONFIG = {
    "version": "1.0",
    "bundles": [
        {
            "name": "default",
            "globs": ["**/*"],
            "rules": ["rules/default.md", "rules/shared.md"],
        },
        {
            "name": "python",
            "globs": ["**/*.py", "**/*.pyi"],
            "rules": ["rules/python.md", "rules/shared.md"],
        },
        {
            "name": "typescript",
            "globs": ["**/*.ts", "**/*.tsx"],
            "rules": ["rules/typescript.md", "rules/shared.md"],
        },
        {
            "name": "sql",
            "globs": ["**/*.sql", "**/migrations/**"],
            "rules": ["rules/sql.md"],
        },
    ],
}


class SingleMatchTests(unittest.TestCase):
    """Case 1 — Single matching glob → that bundle's rules + default appended."""

    def test_single_python_file_yields_python_then_default(self) -> None:
        rules, warning = resolve_bundles(["src/main.py"], _CONFIG)

        # python's rules first, default's rules last, dedup applied on
        # `rules/shared.md` which appears in both.
        self.assertEqual(
            rules,
            ["rules/python.md", "rules/shared.md", "rules/default.md"],
        )
        self.assertIsNone(warning)


class MultiMatchAndDedupTests(unittest.TestCase):
    """Case 2 — Multi-match → declaration/specificity order + dedup-first."""

    def test_python_and_typescript_both_appear_default_last_and_no_duplicates(
        self,
    ) -> None:
        rules, warning = resolve_bundles(["src/foo.ts", "src/bar.py"], _CONFIG)

        # Order is governed by specificity (descending), then by declaration
        # order at the same specificity tier. `default` is always last.
        # `rules/shared.md` is in python, typescript, and default — dedup must
        # keep the first occurrence only.
        self.assertIn("rules/python.md", rules)
        self.assertIn("rules/typescript.md", rules)
        self.assertEqual(rules.count("rules/shared.md"), 1)
        # default rules MUST be last (after both python and typescript)
        self.assertEqual(rules[-1], "rules/default.md")
        py_idx = rules.index("rules/python.md")
        ts_idx = rules.index("rules/typescript.md")
        default_idx = rules.index("rules/default.md")
        self.assertLess(py_idx, default_idx)
        self.assertLess(ts_idx, default_idx)
        self.assertIsNone(warning)


class SpecificityTests(unittest.TestCase):
    """Case 3 — More-specific glob wins over a less-specific one."""

    def test_python_beats_default_for_a_py_file(self) -> None:
        # Both python (**/*.py) and default (**/*) match foo.py. The resolver
        # MUST sort by glob specificity — measured as literal-segment count
        # (higher = more specific) — so python's rules precede default's.
        rules, warning = resolve_bundles(["foo.py"], _CONFIG)

        self.assertLess(
            rules.index("rules/python.md"),
            rules.index("rules/default.md"),
            "python rules must precede default rules for a .py file",
        )
        self.assertIsNone(warning)

    def test_sql_migrations_path_matches_sql_bundle(self) -> None:
        # `migrations/001_init.sql` matches both `**/*.sql` and
        # `**/migrations/**`. Both belong to the same bundle, so dedup is
        # within-bundle — sql's rule list must appear once.
        rules, warning = resolve_bundles(["migrations/001_init.sql"], _CONFIG)

        self.assertIn("rules/sql.md", rules)
        self.assertEqual(rules.count("rules/sql.md"), 1)
        self.assertIsNone(warning)


class EmptyInputTests(unittest.TestCase):
    """Case 4 — Empty changed_files → default-only output, no warning."""

    def test_empty_list_returns_default_rules_only(self) -> None:
        rules, warning = resolve_bundles([], _CONFIG)

        self.assertEqual(rules, ["rules/default.md", "rules/shared.md"])
        self.assertIsNone(
            warning,
            "empty input is a valid 'no work to scope' case, not a warning",
        )


class NoMatchWarningTests(unittest.TestCase):
    """Case 5 — File doesn't match any non-default bundle → fallback + warn."""

    def test_unmatched_extension_falls_back_to_default_with_warning(self) -> None:
        # Build a config WITHOUT the catch-all `**/*` default so we can show a
        # file that truly matches nothing except after the fallback.
        config_strict = {
            "version": "1.0",
            "bundles": [
                {
                    "name": "default",
                    "globs": ["**/never-matches-anything-real"],
                    "rules": ["rules/default.md"],
                },
                {
                    "name": "python",
                    "globs": ["**/*.py"],
                    "rules": ["rules/python.md"],
                },
            ],
        }
        rules, warning = resolve_bundles(["README.md"], config_strict)

        self.assertEqual(rules, ["rules/default.md"])
        self.assertIsNotNone(warning, "no-match path must emit a warning")
        assert warning is not None  # narrow for the next assertions
        self.assertEqual(warning["code"], "no-match-fallback")
        self.assertIn("README.md", warning["unmatched_files"])


class MissingDefaultTests(unittest.TestCase):
    """Case 6 — Config has no `default` bundle → HALT-006."""

    def test_missing_default_raises_bundle_resolution_error_with_halt_code(
        self,
    ) -> None:
        config_no_default = {
            "version": "1.0",
            "bundles": [
                {
                    "name": "python",
                    "globs": ["**/*.py"],
                    "rules": ["rules/python.md"],
                },
            ],
        }

        with self.assertRaises(BundleResolutionError) as cm:
            resolve_bundles(["foo.py"], config_no_default)

        self.assertEqual(cm.exception.halt_code, "HALT-006")
        self.assertIn("default", str(cm.exception).lower())


class SchemaValidationTests(unittest.TestCase):
    """Bundle-schema guards surfaced by the diff-reviewer (C-1, C-2)."""

    def test_duplicate_bundle_name_raises_with_halt_code(self) -> None:
        # Two bundles named `python` would silently alias in a name→bundle
        # dict, causing the first definition's rules to be lost. The resolver
        # must reject this rather than emit a confusing rule list.
        config_dup = {
            "version": "1.0",
            "bundles": [
                {"name": "python", "globs": ["**/*.py"], "rules": ["rules/A.md"]},
                {"name": "python", "globs": ["**/*.py"], "rules": ["rules/B.md"]},
                {"name": "default", "globs": ["**/*"], "rules": ["rules/d.md"]},
            ],
        }

        with self.assertRaises(BundleResolutionError) as cm:
            resolve_bundles(["foo.py"], config_dup)

        self.assertEqual(cm.exception.halt_code, "HALT-006")
        self.assertIn("python", str(cm.exception))

    def test_bundle_missing_name_raises_with_halt_code(self) -> None:
        # A bundle entry without a `name` field used to raise a bare KeyError
        # — opaque for callers that only catch BundleResolutionError.
        config_no_name = {
            "version": "1.0",
            "bundles": [
                {"globs": ["**/*.py"], "rules": ["rules/X.md"]},
                {"name": "default", "globs": ["**/*"], "rules": ["rules/d.md"]},
            ],
        }

        with self.assertRaises(BundleResolutionError) as cm:
            resolve_bundles(["foo.py"], config_no_name)

        self.assertEqual(cm.exception.halt_code, "HALT-006")
        self.assertIn("name", str(cm.exception).lower())

    def test_bundle_with_empty_globs_is_silently_inert(self) -> None:
        # A bundle declared with `globs: []` must not crash and must not match
        # any file. Functionally equivalent to omitting the bundle entirely.
        config_empty_globs = {
            "version": "1.0",
            "bundles": [
                {"name": "inert", "globs": [], "rules": ["rules/never.md"]},
                {"name": "default", "globs": ["**/*"], "rules": ["rules/d.md"]},
            ],
        }

        rules, warning = resolve_bundles(["foo.py"], config_empty_globs)

        self.assertNotIn("rules/never.md", rules)
        self.assertEqual(rules, ["rules/d.md"])
        self.assertIsNone(warning)


class IntegrationTests(unittest.TestCase):
    """Loads the real context-bundles.yml and exercises the resolver."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            import yaml  # noqa: F401
        except ImportError:  # pragma: no cover - skip when PyYAML absent
            raise unittest.SkipTest("PyYAML not installed")

        # repo_root = three levels up from this file:
        #   plugins/makato-build/shared/test_inject_context.py
        cls.repo_root = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
        cls.config_path = os.path.join(
            cls.repo_root,
            "plugins",
            "makato-build",
            "config",
            "context-bundles.yml",
        )
        if not os.path.exists(cls.config_path):
            raise unittest.SkipTest(f"production config not found at {cls.config_path}")

    def _load(self) -> dict:
        import yaml

        with open(self.config_path, encoding="utf-8") as fh:
            return yaml.safe_load(fh)

    def test_production_yaml_declares_canonical_bundles(self) -> None:
        data = self._load()

        names = {b["name"] for b in data["bundles"]}
        self.assertGreaterEqual(
            len(data["bundles"]), 4, "must define at least 4 bundles"
        )
        self.assertEqual(
            names & {"typescript", "python", "sql", "default"},
            {"typescript", "python", "sql", "default"},
            "all four canonical bundles must be present",
        )
        # Schema sanity per bundle.
        for bundle in data["bundles"]:
            self.assertIn("name", bundle)
            self.assertIn("globs", bundle)
            self.assertIn("rules", bundle)
            self.assertIsInstance(bundle["globs"], list)
            self.assertIsInstance(bundle["rules"], list)
            self.assertGreater(len(bundle["globs"]), 0)

    def test_resolver_against_real_config_with_mixed_workload(self) -> None:
        config = self._load()
        changed = [
            "src/foo.ts",
            "src/bar.py",
            "migrations/001_init.sql",
            "README.md",
        ]
        rules, warning = resolve_bundles(changed, config)

        # No warning — every file matches something (default glob is `**/*`).
        self.assertIsNone(warning)

        # All three tech-specific bundles AND default must appear.
        joined = "\n".join(rules)
        self.assertIn("standards/typescript.md", joined)
        self.assertIn("standards/python.md", joined)
        self.assertIn("standards/sql.md", joined)

        # Default rules must be at the end of the list. Resolve the actual
        # default-bundle rule paths from the parsed config rather than hard-
        # coding substrings — keeps this assertion robust when the production
        # config renames or reorders default rules.
        default_bundle = next(b for b in config["bundles"] if b["name"] == "default")
        default_rule_set = set(default_bundle["rules"])
        # Every default rule that survived dedup must appear in the output.
        default_indices = [i for i, r in enumerate(rules) if r in default_rule_set]
        self.assertGreater(
            len(default_indices), 0, "default rules must appear in output"
        )
        last_default_index = max(default_indices)
        non_default_indices = [
            i for i, r in enumerate(rules) if r not in default_rule_set
        ]
        self.assertTrue(
            all(i < last_default_index for i in non_default_indices),
            "default rules must be after all bundle-specific rules",
        )

        # Dedup: every path appears exactly once.
        self.assertEqual(len(rules), len(set(rules)), "no duplicate rule paths")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
