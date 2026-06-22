"""Unit tests for anchor-location helpers."""

import io
import unittest
import zipfile

import defusedxml.ElementTree as defused_etree  # noqa: N813
from fixtures.build_synthetic import build_synthetic_dotx
from scripts.curation_anchors import (
    find_comment_triplet,
    find_highlight_span,
)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _load_paragraphs():
    data = build_synthetic_dotx()
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        doc = defused_etree.fromstring(zf.read("word/document.xml"))
    return list(doc.iter(f"{{{W}}}p"))


class TestFindHighlightSpan(unittest.TestCase):
    def test_locates_cyan_run_in_first_paragraph(self):
        paragraphs = _load_paragraphs()
        run_indices = find_highlight_span(paragraphs[0], label="Název stavby zde", color="cyan")
        assert run_indices is not None
        self.assertEqual(len(run_indices), 1)

    def test_locates_yellow_run_in_second_paragraph(self):
        paragraphs = _load_paragraphs()
        run_indices = find_highlight_span(paragraphs[1], label="DD.MM.RRRR", color="yellow")
        self.assertIsNotNone(run_indices)

    def test_returns_none_when_label_missing(self):
        paragraphs = _load_paragraphs()
        result = find_highlight_span(paragraphs[2], label="anything", color="cyan")
        self.assertIsNone(result)

    def test_returns_none_when_color_mismatch(self):
        paragraphs = _load_paragraphs()
        result = find_highlight_span(paragraphs[0], label="Název stavby zde", color="yellow")
        self.assertIsNone(result)


class TestFindCommentTriplet(unittest.TestCase):
    def test_locates_all_three_markers_for_comment_id_zero(self):
        paragraphs = _load_paragraphs()
        triplet = find_comment_triplet(paragraphs[0], comment_id="0")
        assert triplet is not None
        start, end, _ref = triplet
        self.assertEqual(start.tag, f"{{{W}}}commentRangeStart")
        self.assertEqual(end.tag, f"{{{W}}}commentRangeEnd")

    def test_returns_none_when_no_such_comment(self):
        paragraphs = _load_paragraphs()
        self.assertIsNone(find_comment_triplet(paragraphs[1], "99"))


if __name__ == "__main__":
    unittest.main()
