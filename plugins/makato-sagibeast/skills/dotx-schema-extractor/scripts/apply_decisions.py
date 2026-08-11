"""Phase-2 batch apply: decisions.json + original .dotx -> curated outputs.

Reads the original .dotx (read-only), mutates an in-memory copy of
``word/document.xml`` and ``word/comments.xml``, then writes the
derived ``.dotx``, the curated ``schema_curated.json``, and a
self-contained ``diff_report.html``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import logging
import sys
import zipfile
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET  # types only; parse via defusedxml

import defusedxml.ElementTree as defused_etree  # noqa: N813
from scripts.curation_anchors import find_comment_triplet, find_highlight_span
from scripts.curation_decisions import Decision, Manifest, load_manifest
from scripts.curation_mutate import (
    delete_comment_triplet,
    delete_runs,
    replace_with_jinja_tag,
    strip_highlight,
)
from scripts.curation_render_diff import DiffRow, render_diff_html

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}',
)
logger = logging.getLogger(__name__)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def _para_text(para: ET.Element) -> str:
    return "".join(t.text or "" for t in para.iter(f"{{{W}}}t"))


def _verify_template_sha(dotx_in: Path, manifest: Manifest) -> None:
    actual = hashlib.sha256(dotx_in.read_bytes()).hexdigest()
    if manifest.template_sha256 and manifest.template_sha256 != actual:
        raise ValueError(f"template_sha256 mismatch: manifest={manifest.template_sha256[:12]}…, actual={actual[:12]}…")


def _apply_one_decision(paragraph: ET.Element, decision: Decision) -> ET.Element | None:
    """Return the mutated paragraph or ``None`` if anchor not found."""
    anchor = decision.anchor
    if decision.raw_source == "highlight":
        run_indices = find_highlight_span(
            paragraph,
            label=anchor.get("label", ""),
            color=anchor.get("color", "cyan"),
        )
        if run_indices is None:
            return None
        if decision.verdict in ("slot", "enum"):
            if not decision.key:
                raise ValueError(f"slot/enum verdict requires a key (raw_key={decision.raw_key})")
            return replace_with_jinja_tag(paragraph, run_indices=run_indices, key=decision.key)
        if decision.verdict == "prose_keep":
            return strip_highlight(paragraph, run_indices=run_indices)
        if decision.verdict in ("prose_drop", "toss"):
            return delete_runs(paragraph, run_indices=run_indices)
    if decision.raw_source == "comment":
        comment_id = anchor.get("comment_id")
        if comment_id is None:
            return None
        triplet = find_comment_triplet(paragraph, str(comment_id))
        if triplet is None:
            return None
        if decision.verdict in ("toss", "comment_keep_as_description"):
            return delete_comment_triplet(paragraph, str(comment_id))
    return None


def _curated_schema(decisions: list[Decision], decisions_path: Path) -> dict[str, Any]:
    fields: list[dict[str, Any]] = []
    raw_total = len(decisions)
    kept = 0
    tossed = 0
    promoted = 0
    prose_kept = 0
    for d in decisions:
        if d.verdict in ("slot", "enum"):
            field: dict[str, Any] = {
                "key": d.key,
                "label": d.description or d.key,
                "kind": d.kind or "text",
                "source": "curated",
                "required": True,
                "description": d.description,
            }
            if d.verdict == "enum" and d.enum is not None:
                field["enum"] = d.enum
            fields.append(field)
            kept += 1
        elif d.verdict == "comment_keep_as_description":
            promoted += 1
        elif d.verdict == "prose_keep":
            prose_kept += 1
        else:  # prose_drop, toss
            tossed += 1
    return {
        "fields": fields,
        "repeats": [],
        "warnings": [],
        "curation": {
            "decisions_path": decisions_path.name,
            "curated_at": dt.datetime.now(dt.timezone.utc).isoformat(),  # noqa: UP017
            "stats": {
                "raw_total": raw_total,
                "kept": kept,
                "tossed": tossed,
                "prose_kept": prose_kept,
                "comments_promoted": promoted,
            },
        },
    }


def run_apply(
    *,
    dotx_in: Path,
    decisions_path: Path,
    dotx_out: Path,
    schema_out: Path,
    diff_out: Path,
) -> None:
    """End-to-end phase-2 apply."""
    manifest = load_manifest(decisions_path)
    _verify_template_sha(dotx_in, manifest)

    with zipfile.ZipFile(dotx_in, mode="r") as zf:
        parts = {name: zf.read(name) for name in zf.namelist()}

    doc_root = defused_etree.fromstring(parts["word/document.xml"])
    body = doc_root.find(f"{{{W}}}body")
    paragraphs = list(body.findall(f"{{{W}}}p")) if body is not None else []
    diff_rows: list[DiffRow] = []

    decisions_by_para: dict[int, list[Decision]] = {}
    for d in manifest.decisions:
        idx = d.anchor.get("paragraph_index")
        if idx is None:
            continue
        decisions_by_para.setdefault(int(idx), []).append(d)

    for idx, decisions_here in decisions_by_para.items():
        if idx >= len(paragraphs):
            logger.warning("paragraph index %d out of range; skipping", idx)
            continue
        original = paragraphs[idx]
        before_text = _para_text(original)
        mutated = original
        for decision in decisions_here:
            result = _apply_one_decision(mutated, decision)
            if result is None:
                logger.warning(
                    "decision %s could not be located in paragraph %d",
                    decision.raw_key,
                    idx,
                )
                continue
            mutated = result
            diff_rows.append(
                DiffRow(
                    paragraph_index=idx,
                    before=before_text,
                    after=_para_text(mutated),
                    verdict=decision.verdict,
                    key=decision.key,
                )
            )
        if body is not None and mutated is not original:
            body_children = list(body)
            body[body_children.index(original)] = mutated

    parts["word/document.xml"] = ET.tostring(doc_root, xml_declaration=True, encoding="utf-8")

    dotx_out.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, content in parts.items():
            zf.writestr(name, content)
    dotx_out.write_bytes(buf.getvalue())

    schema_out.parent.mkdir(parents=True, exist_ok=True)
    schema = _curated_schema(manifest.decisions, decisions_path)
    schema_out.write_text(json.dumps(schema, ensure_ascii=False, indent=2))

    diff_out.parent.mkdir(parents=True, exist_ok=True)
    diff_out.write_text(
        render_diff_html(diff_rows, title=dotx_in.stem),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotx-in", required=True, type=Path)
    parser.add_argument("--decisions", required=True, type=Path)
    parser.add_argument("--dotx-out", required=True, type=Path)
    parser.add_argument("--schema-out", required=True, type=Path)
    parser.add_argument("--diff-out", required=True, type=Path)
    args = parser.parse_args()
    try:
        run_apply(
            dotx_in=args.dotx_in,
            decisions_path=args.decisions,
            dotx_out=args.dotx_out,
            schema_out=args.schema_out,
            diff_out=args.diff_out,
        )
    except ValueError as e:
        logger.error("apply failed: %s", e)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
