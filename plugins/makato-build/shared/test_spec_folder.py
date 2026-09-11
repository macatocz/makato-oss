"""Tests for deterministic makato-build spec-folder resolution."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from spec_folder import SpecFolderAmbiguous, SpecFolderNotFound, resolve_spec_folder


class SpecFolderResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        (self.root / "specs").mkdir()

    def test_numeric_issue_resolves_bare_slug_from_plan_file(self) -> None:
        folder = self.root / "specs" / "db-schema-redesign"
        folder.mkdir()
        (folder / "plan-995.md").write_text("# plan\n", encoding="utf-8")

        self.assertEqual(resolve_spec_folder(self.root, "995"), folder.resolve())

    def test_numeric_issue_resolves_from_created_issues_artifact(self) -> None:
        folder = self.root / "specs" / "db-schema-redesign"
        folder.mkdir()
        (folder / "created-issues.json").write_text(
            json.dumps({"issues": [{"issue_number": 995}]}),
            encoding="utf-8",
        )

        self.assertEqual(resolve_spec_folder(self.root, "#995"), folder.resolve())

    def test_numeric_issue_resolves_from_seed_manifest(self) -> None:
        folder = self.root / "specs" / "db-schema-redesign"
        folder.mkdir()
        (folder / "seed-manifest.json").write_text(
            json.dumps({"issue_number": 995}),
            encoding="utf-8",
        )

        self.assertEqual(resolve_spec_folder(self.root, "995"), folder.resolve())

    def test_direct_prefix_match_is_preserved(self) -> None:
        folder = self.root / "specs" / "DCP-1234-feature"
        folder.mkdir()

        self.assertEqual(resolve_spec_folder(self.root, "DCP-1234"), folder.resolve())

    def test_exact_match_is_preserved(self) -> None:
        folder = self.root / "specs" / "local-example"
        folder.mkdir()

        self.assertEqual(resolve_spec_folder(self.root, "local-example"), folder.resolve())

    def test_ambiguous_issue_match_fails(self) -> None:
        for name in ("feature-a", "feature-b"):
            folder = self.root / "specs" / name
            folder.mkdir()
            (folder / "plan-995.md").write_text("# plan\n", encoding="utf-8")

        with self.assertRaises(SpecFolderAmbiguous):
            resolve_spec_folder(self.root, "995")

    def test_missing_folder_fails_without_synthesizing_a_path(self) -> None:
        with self.assertRaises(SpecFolderNotFound):
            resolve_spec_folder(self.root, "995")


if __name__ == "__main__":
    unittest.main()
