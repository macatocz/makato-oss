"""Smoke test for the synthetic .dotx fixture builder."""

import io
import unittest
import zipfile

from fixtures.build_synthetic import build_synthetic_dotx


class TestSyntheticFixture(unittest.TestCase):
    def test_builds_a_valid_zip_with_required_parts(self):
        data = build_synthetic_dotx()
        self.assertIsInstance(data, bytes)
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            names = set(zf.namelist())
        self.assertIn("[Content_Types].xml", names)
        self.assertIn("_rels/.rels", names)
        self.assertIn("word/document.xml", names)
        self.assertIn("word/comments.xml", names)
        self.assertIn("word/_rels/document.xml.rels", names)

    def test_document_contains_each_marker_type(self):
        data = build_synthetic_dotx()
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            doc = zf.read("word/document.xml").decode("utf-8")
            comments = zf.read("word/comments.xml").decode("utf-8")
        self.assertIn('w:val="cyan"', doc)
        self.assertIn('w:val="yellow"', doc)
        self.assertIn("commentRangeStart", doc)
        self.assertIn("commentRangeEnd", doc)
        self.assertIn("commentReference", doc)
        self.assertIn('w:id="0"', comments)


if __name__ == "__main__":
    unittest.main()
