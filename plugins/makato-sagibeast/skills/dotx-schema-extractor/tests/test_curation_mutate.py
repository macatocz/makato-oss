"""Unit tests for paragraph mutation primitives."""

import io
import unittest
import zipfile

import defusedxml.ElementTree as defused_etree  # noqa: N813
from fixtures.build_synthetic import build_synthetic_dotx
from scripts.curation_mutate import (
    delete_comment_triplet,
    delete_runs,
    replace_with_jinja_tag,
    strip_highlight,
)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _paragraphs():
    data = build_synthetic_dotx()
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        return list(defused_etree.fromstring(zf.read("word/document.xml")).iter(f"{{{W}}}p"))


def _para_text(p):
    return "".join(t.text or "" for t in p.iter(f"{{{W}}}t"))


def _has_highlight(p) -> bool:
    return p.find(f".//{{{W}}}highlight") is not None


class TestReplaceWithJinjaTag(unittest.TestCase):
    def test_replaces_cyan_span_with_jinja_tag(self):
        para = _paragraphs()[0]
        new_para = replace_with_jinja_tag(para, run_indices=[1], key="stavba_nazev")
        self.assertIn("{{ stavba_nazev }}", _para_text(new_para))
        self.assertNotIn("Název stavby zde", _para_text(new_para))
        self.assertFalse(_has_highlight(new_para))

    def test_does_not_mutate_original_paragraph(self):
        para = _paragraphs()[0]
        before = _para_text(para)
        replace_with_jinja_tag(para, run_indices=[1], key="stavba_nazev")
        self.assertEqual(_para_text(para), before)


class TestStripHighlight(unittest.TestCase):
    def test_drops_highlight_property_keeps_text(self):
        para = _paragraphs()[1]
        new_para = strip_highlight(para, run_indices=[1])
        self.assertIn("DD.MM.RRRR", _para_text(new_para))
        self.assertFalse(_has_highlight(new_para))


class TestDeleteRuns(unittest.TestCase):
    def test_removes_runs_at_given_indices(self):
        para = _paragraphs()[1]
        new_para = delete_runs(para, run_indices=[1])
        self.assertNotIn("DD.MM.RRRR", _para_text(new_para))
        self.assertIn("Termín:", _para_text(new_para))


class TestDeleteCommentTriplet(unittest.TestCase):
    def test_removes_all_three_comment_markers(self):
        para = _paragraphs()[0]
        new_para = delete_comment_triplet(para, comment_id="0")
        self.assertEqual(0, len(list(new_para.iter(f"{{{W}}}commentRangeStart"))))
        self.assertEqual(0, len(list(new_para.iter(f"{{{W}}}commentRangeEnd"))))
        self.assertEqual(0, len(list(new_para.iter(f"{{{W}}}commentReference"))))


class TestImmutability(unittest.TestCase):
    """All mutation primitives must leave the caller's element untouched."""

    def test_primitives_do_not_mutate_caller(self):
        for op in (
            lambda p: strip_highlight(p, run_indices=[1]),
            lambda p: delete_runs(p, run_indices=[1]),
            lambda p: delete_comment_triplet(p, comment_id="0"),
        ):
            para = _paragraphs()[0]
            before = _para_text(para)
            op(para)
            self.assertEqual(_para_text(para), before)


if __name__ == "__main__":
    unittest.main()
