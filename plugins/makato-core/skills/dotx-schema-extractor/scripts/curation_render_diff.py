"""Render a self-contained HTML diff report for the curation pipeline."""

from __future__ import annotations

import dataclasses
import html


@dataclasses.dataclass
class DiffRow:
    """One paragraph-level change, before vs after."""

    paragraph_index: int
    before: str
    after: str
    verdict: str
    key: str | None


_STYLE = """
body { font-family: -apple-system, "Segoe UI", sans-serif; max-width: 1200px;
       margin: 2em auto; padding: 0 1em; color: #222; }
h1 { border-bottom: 2px solid #333; padding-bottom: .3em; }
section { margin: 1.2em 0; padding: .8em; border: 1px solid #ddd; border-radius: 6px; }
.meta { font-size: .85em; color: #555; margin-bottom: .4em; }
.cols { display: grid; grid-template-columns: 1fr 1fr; gap: 1em; }
.before, .after { padding: .6em; background: #f6f8fa; border-radius: 4px;
                  white-space: pre-wrap; font-family: ui-monospace, monospace;
                  font-size: .9em; line-height: 1.5; }
.before { border-left: 4px solid #d73a49; }
.after { border-left: 4px solid #28a745; }
.verdict { display: inline-block; padding: .1em .5em; border-radius: 1em;
           font-size: .8em; font-family: monospace; }
.v-slot, .v-enum { background: #d4edda; color: #155724; }
.v-prose_keep, .v-prose_drop, .v-toss { background: #fff3cd; color: #856404; }
.v-comment_keep_as_description { background: #cce5ff; color: #004085; }
"""


def render_diff_html(rows: list[DiffRow], *, title: str) -> str:
    """Return a complete self-contained HTML document for the diff rows."""
    sections: list[str] = []
    for row in rows:
        verdict_class = f"v-{row.verdict}"
        key_str = f" → <code>{html.escape(row.key)}</code>" if row.key else ""
        sections.append(
            "<section>"
            f"<div class='meta'>¶ {row.paragraph_index} "
            f"<span class='verdict {verdict_class}'>"
            f"{html.escape(row.verdict)}</span>{key_str}</div>"
            "<div class='cols'>"
            f"<div class='before'>{html.escape(row.before)}</div>"
            f"<div class='after'>{html.escape(row.after)}</div>"
            "</div></section>"
        )

    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{html.escape(title)} — diff report</title>"
        f"<style>{_STYLE}</style></head><body>"
        f"<h1>{html.escape(title)} — diff report</h1>"
        f"<p>{len(rows)} changed paragraphs.</p>" + "".join(sections) + "</body></html>"
    )
