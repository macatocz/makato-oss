"""Anchor-location helpers for OOXML paragraph mutations.

Pure functions over ``defusedxml.ElementTree`` paragraphs. No I/O.
"""

from __future__ import annotations

from xml.etree import ElementTree as ET  # types only; parse via defusedxml

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _run_text(run: ET.Element) -> str:
    """Concatenate <w:t> descendants of a single <w:r> run."""
    return "".join(t.text or "" for t in run.iter(f"{{{W}}}t"))


def _run_highlight(run: ET.Element) -> str | None:
    r_pr = run.find(f"{{{W}}}rPr")
    if r_pr is None:
        return None
    hi = r_pr.find(f"{{{W}}}highlight")
    if hi is None:
        return None
    return hi.get(f"{{{W}}}val")


def find_highlight_span(paragraph: ET.Element, label: str, color: str) -> list[int] | None:
    """Locate contiguous run indices whose joined text equals ``label``.

    All matched runs must carry ``<w:highlight w:val=color>``. Returns
    a list of indices into the paragraph's ``<w:r>`` children, or
    ``None`` if no unique match.
    """
    runs = paragraph.findall(f"{{{W}}}r")
    target = label.strip()
    if not target:
        return None

    matches: list[list[int]] = []
    for start in range(len(runs)):
        if _run_highlight(runs[start]) != color:
            continue
        accumulated = ""
        span: list[int] = []
        for end in range(start, len(runs)):
            if _run_highlight(runs[end]) != color:
                break
            accumulated += _run_text(runs[end])
            span.append(end)
            if accumulated.strip() == target:
                matches.append(list(span))
                break
            if len(accumulated) > len(target):
                break

    if len(matches) != 1:
        return None
    return matches[0]


def find_comment_triplet(paragraph: ET.Element, comment_id: str) -> tuple[ET.Element, ET.Element, ET.Element] | None:
    """Locate the (start, end, reference) triplet for one comment id.

    Returns ``None`` if any of the three is missing in this paragraph.
    """
    start = end = ref = None
    for child in paragraph.iter():
        if child.tag == f"{{{W}}}commentRangeStart" and child.get(f"{{{W}}}id") == comment_id:
            start = child
        elif child.tag == f"{{{W}}}commentRangeEnd" and child.get(f"{{{W}}}id") == comment_id:
            end = child
        elif child.tag == f"{{{W}}}commentReference" and child.get(f"{{{W}}}id") == comment_id:
            ref = child
    if start is None or end is None or ref is None:
        return None
    return start, end, ref
