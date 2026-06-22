"""End-to-end test for apply_decisions on the synthetic .dotx."""

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from fixtures.build_synthetic import build_synthetic_dotx
from scripts.apply_decisions import run_apply
from scripts.curation_decisions import Decision, Manifest, save_manifest


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class TestApplyDecisions(unittest.TestCase):
    def test_emits_mutated_dotx_curated_schema_and_diff(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            dotx_in = td_path / "in.dotx"
            data = build_synthetic_dotx()
            dotx_in.write_bytes(data)

            decisions_path = td_path / "decisions.json"
            manifest = Manifest(
                schema_version=1,
                source_schema_sha256="aaa",
                template_sha256=_sha(data),
                started_at="2026-06-09T10:00:00+00:00",
                decisions=[
                    Decision(
                        raw_key="nazev_stavby_zde",
                        raw_source="highlight",
                        anchor={
                            "paragraph_index": 0,
                            "label": "Název stavby zde",
                            "color": "cyan",
                        },
                        verdict="slot",
                        key="stavba_nazev",
                        kind="text",
                        enum=None,
                        description="Název stavby z evidence",
                        decided_at="2026-06-09T10:00:00+00:00",
                    ),
                    Decision(
                        raw_key="dd_mm_rrrr",
                        raw_source="highlight",
                        anchor={
                            "paragraph_index": 1,
                            "label": "DD.MM.RRRR",
                            "color": "yellow",
                        },
                        verdict="toss",
                        key=None,
                        kind=None,
                        enum=None,
                        description="",
                        decided_at="2026-06-09T10:00:00+00:00",
                    ),
                ],
            )
            save_manifest(manifest, decisions_path)

            dotx_out = td_path / "out.dotx"
            schema_out = td_path / "schema_curated.json"
            diff_out = td_path / "diff_report.html"

            run_apply(
                dotx_in=dotx_in,
                decisions_path=decisions_path,
                dotx_out=dotx_out,
                schema_out=schema_out,
                diff_out=diff_out,
            )

            self.assertTrue(dotx_out.exists())
            self.assertTrue(schema_out.exists())
            self.assertTrue(diff_out.exists())

            with zipfile.ZipFile(dotx_out) as zf:
                doc = zf.read("word/document.xml").decode("utf-8")
            self.assertIn("{{ stavba_nazev }}", doc)
            self.assertNotIn("Název stavby zde", doc)
            self.assertNotIn("DD.MM.RRRR", doc)

            schema = json.loads(schema_out.read_text())
            keys = [f["key"] for f in schema["fields"]]
            self.assertIn("stavba_nazev", keys)
            self.assertIn("curation", schema)
            self.assertEqual(schema["curation"]["stats"]["raw_total"], 2)
            self.assertEqual(schema["curation"]["stats"]["kept"], 1)
            self.assertEqual(schema["curation"]["stats"]["tossed"], 1)

            self.assertIn("diff report", diff_out.read_text())

    def test_refuses_when_template_sha_mismatches(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            dotx_in = td_path / "in.dotx"
            dotx_in.write_bytes(build_synthetic_dotx())

            decisions_path = td_path / "decisions.json"
            save_manifest(
                Manifest(
                    schema_version=1,
                    source_schema_sha256="aaa",
                    template_sha256="WRONG_SHA",
                    started_at="2026-06-09T10:00:00+00:00",
                    decisions=[],
                ),
                decisions_path,
            )

            with self.assertRaises(ValueError) as ctx:
                run_apply(
                    dotx_in=dotx_in,
                    decisions_path=decisions_path,
                    dotx_out=td_path / "x.dotx",
                    schema_out=td_path / "x.json",
                    diff_out=td_path / "x.html",
                )
            self.assertIn("template_sha256", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
