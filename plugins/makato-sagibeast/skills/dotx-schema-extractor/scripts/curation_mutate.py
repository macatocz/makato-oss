"""Pure paragraph-mutation primitives for the curation pipeline.

Each function deep-copies the input paragraph and returns a new one.
Callers reassemble the document by replacing the original paragraph in
the body with the returned element.
"""

from __future__ import annotations

import copy
from xml.etree import ElementTree as ET  # types only; parse via defusedxml

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _runs(para: ET.Element) -> list[ET.Element]:
    return list(para.findall(f"{{{W}}}r"))


def replace_with_jinja_tag(paragraph: ET.Element, run_indices: list[int], key: str) -> ET.Element:
    """Replace runs at ``run_indices`` with one run containing ``{{ key }}``.

    The replacement run carries no formatting beyond the paragraph's
    inherited defaults — no highlight, no rPr.
    """
    new_para = copy.deepcopy(paragraph)
    runs = _runs(new_para)
    if not run_indices or any(i < 0 or i >= len(runs) for i in run_indices):
        return new_para  # caller already validated; defensive

    target_runs = [runs[i] for i in run_indices]

    replacement = ET.Element(f"{{{W}}}r")
    t = ET.SubElement(replacement, f"{{{W}}}t")
    t.text = "{{ " + key + " }}"
    t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")

    insert_at = list(new_para).index(target_runs[0])
    for run in target_runs:
        new_para.remove(run)
    new_para.insert(insert_at, replacement)
    return new_para


def strip_highlight(paragraph: ET.Element, run_indices: list[int]) -> ET.Element:
    """Drop the ``<w:highlight>`` element from each named run's ``<w:rPr>``.

    Leaves the run's text and other formatting intact.
    """
    new_para = copy.deepcopy(paragraph)
    runs = _runs(new_para)
    for idx in run_indices:
        if 0 <= idx < len(runs):
            r_pr = runs[idx].find(f"{{{W}}}rPr")
            if r_pr is None:
                continue
            highlight = r_pr.find(f"{{{W}}}highlight")
            if highlight is not None:
                r_pr.remove(highlight)
    return new_para


def delete_runs(paragraph: ET.Element, run_indices: list[int]) -> ET.Element:
    """Remove the runs at the given indices from a copy of ``paragraph``."""
    new_para = copy.deepcopy(paragraph)
    runs = _runs(new_para)
    for idx in sorted(set(run_indices), reverse=True):
        if 0 <= idx < len(runs):
            new_para.remove(runs[idx])
    return new_para


def delete_comment_triplet(paragraph: ET.Element, comment_id: str) -> ET.Element:
    """Remove commentRangeStart/End and commentReference for ``comment_id``."""
    new_para = copy.deepcopy(paragraph)
    targets: list[ET.Element] = []
    for child in new_para.iter():
        if (
            child.tag
            in (
                f"{{{W}}}commentRangeStart",
                f"{{{W}}}commentRangeEnd",
                f"{{{W}}}commentReference",
            )
            and child.get(f"{{{W}}}id") == comment_id
        ):
            targets.append(child)
    for tgt in targets:
        for parent in new_para.iter():
            if tgt in list(parent):
                parent.remove(tgt)
                break
    # Drop run shells that became empty (only commentReference inside).
    for run in list(new_para.findall(f"{{{W}}}r")):
        if not any(c.tag == f"{{{W}}}t" for c in run.iter()):
            new_para.remove(run)
    return new_para
