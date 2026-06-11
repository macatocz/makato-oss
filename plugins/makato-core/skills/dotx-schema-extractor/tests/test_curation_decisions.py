"""Unit tests for decisions manifest I/O."""

import tempfile
import unittest
from pathlib import Path

from scripts.curation_decisions import (
    Decision,
    Manifest,
    load_manifest,
    next_pending,
    save_manifest,
)


class TestDecisionRoundTrip(unittest.TestCase):
    def test_decision_to_dict_and_back(self):
        d = Decision(
            raw_key="strucny_popis_skutecnosti_ktere_zpu",
            raw_source="highlight",
            anchor={"paragraph_index": 12, "run_indices": [3, 4, 5]},
            verdict="slot",
            key="skutecnosti_strucny_popis",
            kind="text",
            enum=None,
            description="Stručný popis skutečností",
            decided_at="2026-06-09T10:00:00+00:00",
        )
        roundtrip = Decision.from_dict(d.to_dict())
        self.assertEqual(roundtrip, d)

    def test_save_and_load_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "decisions.json"
            m = Manifest(
                schema_version=1,
                source_schema_sha256="aaa",
                template_sha256="bbb",
                started_at="2026-06-09T10:00:00+00:00",
                decisions=[],
            )
            save_manifest(m, path)
            loaded = load_manifest(path)
            self.assertEqual(loaded.template_sha256, "bbb")
            self.assertEqual(loaded.decisions, [])

    def test_load_returns_empty_when_file_missing(self):
        m = load_manifest(Path("/nonexistent/decisions.json"))
        self.assertEqual(m.decisions, [])
        self.assertIsNone(m.template_sha256)


class TestNextPending(unittest.TestCase):
    def test_returns_first_undecided_field(self):
        manifest = Manifest(
            schema_version=1,
            source_schema_sha256=None,
            template_sha256=None,
            started_at=None,
            decisions=[
                Decision(
                    raw_key="alpha",
                    raw_source="highlight",
                    anchor={},
                    verdict="toss",
                    key=None,
                    kind=None,
                    enum=None,
                    description="",
                    decided_at="",
                )
            ],
        )
        raw_fields = [
            {"key": "alpha", "source": "highlight"},
            {"key": "beta", "source": "highlight"},
            {"key": "gamma", "source": "comment"},
        ]
        idx, field = next_pending(manifest, raw_fields)
        self.assertEqual(idx, 1)
        self.assertIsNotNone(field)
        assert field is not None
        self.assertEqual(field["key"], "beta")

    def test_returns_minus_one_when_all_decided(self):
        manifest = Manifest(
            schema_version=1,
            source_schema_sha256=None,
            template_sha256=None,
            started_at=None,
            decisions=[
                Decision(
                    raw_key="alpha",
                    raw_source="highlight",
                    anchor={},
                    verdict="toss",
                    key=None,
                    kind=None,
                    enum=None,
                    description="",
                    decided_at="",
                )
            ],
        )
        raw_fields = [{"key": "alpha", "source": "highlight"}]
        idx, field = next_pending(manifest, raw_fields)
        self.assertEqual(idx, -1)
        self.assertIsNone(field)


if __name__ == "__main__":
    unittest.main()
