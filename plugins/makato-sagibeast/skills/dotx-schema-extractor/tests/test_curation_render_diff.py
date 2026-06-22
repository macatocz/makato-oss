"""Unit tests for the diff_report.html renderer."""

import unittest

from scripts.curation_render_diff import DiffRow, render_diff_html


class TestRenderDiffHtml(unittest.TestCase):
    def test_emits_self_contained_html_with_each_row(self):
        rows = [
            DiffRow(
                paragraph_index=0,
                before="Stavba: Název stavby zde",
                after="Stavba: {{ stavba_nazev }}",
                verdict="slot",
                key="stavba_nazev",
            ),
            DiffRow(
                paragraph_index=1,
                before="Termín: DD.MM.RRRR",
                after="Termín: ",
                verdict="toss",
                key=None,
            ),
        ]
        html = render_diff_html(rows, title="Synthetic")
        self.assertIn("<!doctype html>", html.lower())
        self.assertIn("Synthetic", html)
        self.assertIn("Stavba:", html)
        self.assertIn("{{ stavba_nazev }}", html)
        self.assertIn("toss", html)

    def test_html_escapes_special_characters(self):
        rows = [
            DiffRow(
                paragraph_index=0,
                before="<script>alert(1)</script>",
                after="safe",
                verdict="prose_drop",
                key=None,
            )
        ]
        html = render_diff_html(rows, title="t")
        self.assertNotIn("<script>alert(1)</script>", html)
        self.assertIn("&lt;script&gt;", html)


if __name__ == "__main__":
    unittest.main()
