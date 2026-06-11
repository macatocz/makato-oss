#!/usr/bin/env python3
"""Extract a JSON schema from a Word .dotx/.docx template.

The schema is the output contract for an LLM document-generation agent.
Reads OOXML directly via zipfile and a defusedxml-parsed ElementTree —
no third-party deps beyond defusedxml.

Usage:
    python extract_schema.py --input template.dotx --output schema.json \\
        [--no-instructions] [--no-repeats] [--summary-md schema.md]
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import logging
import re
import sys
import unicodedata
import zipfile
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET  # types only; parse via defusedxml

import defusedxml.ElementTree as defused_etree  # noqa: N813

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}',
)
logger = logging.getLogger(__name__)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
W14 = "http://schemas.microsoft.com/office/word/2010/wordml"

MIN_REPEAT_ROWS = 2
MAX_LABEL_CHARS = 80
MAX_DESCRIPTION_CHARS = 200
MAX_GROUNDING_CHARS = 120


@dataclasses.dataclass
class Field:
    """One variable slot in the template."""

    key: str
    label: str
    kind: str  # text | enum | date | number | instruction
    source: str  # sdt | mergefield | docproperty | placeholder | highlight
    required: bool = True
    description: str = ""
    enum: list[str] | None = None
    format: str | None = None
    occurrences: int = 1
    first_paragraph_text: str = ""

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "key": self.key,
            "label": self.label,
            "kind": self.kind,
            "source": self.source,
            "required": self.required,
            "description": self.description,
            "occurrences": self.occurrences,
            "first_paragraph_text": self.first_paragraph_text,
        }
        if self.enum is not None:
            out["enum"] = self.enum
        if self.format is not None:
            out["format"] = self.format
        return out


def slugify(text: str, max_words: int = 6) -> str:
    """Convert text to snake_case ASCII-safe key."""
    if not text:
        return "field"
    folded = unicodedata.normalize("NFKD", text)
    ascii_only = "".join(c for c in folded if not unicodedata.combining(c))
    cleaned = re.sub(r"[^a-zA-Z0-9_\s-]", " ", ascii_only).strip().lower()
    words = re.split(r"\s+", cleaned)[:max_words]
    slug = "_".join(w for w in words if w)
    slug = re.sub(r"_+", "_", slug).strip("_")
    return slug or "field"


def truncate(text: str, limit: int = MAX_GROUNDING_CHARS) -> str:
    """Collapse whitespace and truncate to limit characters."""
    cleaned = re.sub(r"\s+", " ", text).strip()
    return cleaned[:limit]


def text_of(elem: ET.Element) -> str:
    """Concatenate every <w:t> descendant of elem."""
    return "".join(t.text or "" for t in elem.iter(f"{{{W}}}t"))


def read_part(zf: zipfile.ZipFile, name: str) -> ET.Element | None:
    """Read one OOXML part as an ElementTree root, or None if missing."""
    try:
        with zf.open(name) as fp:
            return defused_etree.fromstring(fp.read())
    except KeyError:
        return None


def list_parts(zf: zipfile.ZipFile) -> list[str]:
    """Return body parts whose fields belong in the schema."""
    parts = ["word/document.xml"]
    for name in zf.namelist():
        if re.match(r"word/(header|footer)\d+\.xml", name):
            parts.append(name)
    return parts


# --------------------- SDT extractor --------------------- #


def _classify_sdt(sdt_pr: ET.Element) -> tuple[str, list[str] | None, str | None]:
    """Return (kind, enum, date_format) for an <w:sdtPr>."""
    combo = sdt_pr.find(f"{{{W}}}comboBox")
    ddl = sdt_pr.find(f"{{{W}}}dropDownList")
    date_el = sdt_pr.find(f"{{{W}}}date")
    list_el = combo if combo is not None else ddl

    if list_el is not None:
        enum: list[str] = []
        for item in list_el.findall(f"{{{W}}}listItem"):
            value = item.get(f"{{{W}}}value") or item.get(f"{{{W}}}displayText")
            if value and value not in enum and value != "Zvolte položku.":
                enum.append(value)
        return "enum", enum, None

    if date_el is not None:
        fmt_el = date_el.find(f"{{{W}}}dateFormat")
        date_format = fmt_el.get(f"{{{W}}}val") if fmt_el is not None else "DD.MM.YYYY"
        return "date", None, date_format

    return "text", None, None


def _is_checkbox_sdt(sdt_pr: ET.Element) -> bool:
    """True for SDTs that are pure UI checkboxes — skip from schema."""
    return sdt_pr.find(f"{{{W14}}}checkbox") is not None


def extract_sdts(root: ET.Element) -> list[Field]:
    """Walk every <w:sdt>; emit one Field each."""
    fields: list[Field] = []
    for sdt in root.iter(f"{{{W}}}sdt"):
        sdt_pr = sdt.find(f"{{{W}}}sdtPr")
        sdt_content = sdt.find(f"{{{W}}}sdtContent")
        if sdt_pr is None or _is_checkbox_sdt(sdt_pr):
            continue
        tag_el = sdt_pr.find(f"{{{W}}}tag")
        alias_el = sdt_pr.find(f"{{{W}}}alias")
        tag = tag_el.get(f"{{{W}}}val") if tag_el is not None else None
        alias = alias_el.get(f"{{{W}}}val") if alias_el is not None else None

        kind, enum, date_format = _classify_sdt(sdt_pr)
        content_text = text_of(sdt_content) if sdt_content is not None else ""
        label = alias or tag or truncate(content_text, 40) or "field"
        key = slugify(tag or alias or label)

        fields.append(
            Field(
                key=key,
                label=label,
                kind=kind,
                source="sdt",
                description=alias or content_text,
                enum=enum,
                format=date_format,
                first_paragraph_text=truncate(content_text),
            )
        )
    return fields


# --------------------- Field codes --------------------- #


def extract_field_codes(root: ET.Element) -> list[Field]:
    """Find MERGEFIELD and DOCPROPERTY codes in <w:instrText>."""
    fields: list[Field] = []
    for instr in root.iter(f"{{{W}}}instrText"):
        text = (instr.text or "").strip()
        merge = re.search(r"MERGEFIELD\s+([^\s\\]+)", text)
        if merge:
            name = merge.group(1).strip(' "')
            fields.append(
                Field(
                    key=slugify(name),
                    label=name,
                    kind="text",
                    source="mergefield",
                    description=f"MERGEFIELD {name}",
                )
            )
            continue
        doc_prop = re.search(r"DOCPROPERTY\s+([^\s\\]+)", text)
        if doc_prop:
            name = doc_prop.group(1).strip(' "')
            fields.append(
                Field(
                    key=slugify(name),
                    label=name,
                    kind="text",
                    source="docproperty",
                    description=f"DOCPROPERTY {name}",
                )
            )
    return fields


# --------------------- Plain-text placeholders --------------------- #


PLACEHOLDER_PATTERNS = (
    re.compile(r"\{\{\s*([a-zA-Z_][\w.]{0,80})\s*\}\}"),
    re.compile(r"\[([A-Z_][A-Z0-9_]{2,40})\]"),
    re.compile(r"<([A-Z_][A-Z0-9_]{2,40})>"),
)


def extract_placeholders(root: ET.Element) -> list[Field]:
    """Extract {{var}}, [VAR], <VAR> patterns from visible text."""
    fields: list[Field] = []
    for para in root.iter(f"{{{W}}}p"):
        para_text = text_of(para)
        if not para_text:
            continue
        for pattern in PLACEHOLDER_PATTERNS:
            for match in pattern.finditer(para_text):
                name = match.group(1)
                fields.append(
                    Field(
                        key=slugify(name),
                        label=name,
                        kind="text",
                        source="placeholder",
                        description=f"plain-text placeholder: {match.group(0)}",
                        first_paragraph_text=truncate(para_text),
                    )
                )
    return fields


# --------------------- Highlighted instructions --------------------- #


# Word's <w:highlight> values: black, blue, cyan, darkBlue, darkCyan, darkGray,
# darkGreen, darkMagenta, darkRed, darkYellow, green, lightGray, magenta,
# none, red, white, yellow.
DEFAULT_HIGHLIGHT_COLORS: tuple[str, ...] = ("cyan", "yellow")


def _run_highlight_color(run: ET.Element, allowed: frozenset[str]) -> str | None:
    """Return the highlight color if it's in the allowed set, else None."""
    r_pr = run.find(f"{{{W}}}rPr")
    if r_pr is None:
        return None
    hi = r_pr.find(f"{{{W}}}highlight")
    if hi is None:
        return None
    val = hi.get(f"{{{W}}}val")
    return val if val in allowed else None


def _sdt_run_ids(root: ET.Element) -> set[int]:
    """IDs of every <w:r> inside an <w:sdt> — to skip double-counting."""
    ids: set[int] = set()
    for sdt in root.iter(f"{{{W}}}sdt"):
        for r in sdt.iter(f"{{{W}}}r"):
            ids.add(id(r))
    return ids


def _flush_highlight(
    fields: list[Field],
    current_text: list[str],
    current_color: str | None,
    para_text: str,
) -> None:
    """Emit a Field for the current accumulated highlighted span."""
    if not current_text or not current_color:
        return
    span = "".join(current_text).strip()
    if not span:
        return
    fields.append(
        Field(
            key=slugify(span),
            label=truncate(span, MAX_LABEL_CHARS),
            kind="instruction",
            source="highlight",
            description=(f"{current_color} highlight: " f"{truncate(span, MAX_DESCRIPTION_CHARS)}"),
            first_paragraph_text=truncate(para_text),
        )
    )


def extract_highlights(root: ET.Element, allowed_colors: frozenset[str]) -> list[Field]:
    """Extract runs whose properties carry a highlighted color.

    Only colors in ``allowed_colors`` count. Each contiguous highlighted
    span within a paragraph yields one field. Skip spans inside an SDT —
    those are already captured by extract_sdts.
    """
    fields: list[Field] = []
    sdt_runs = _sdt_run_ids(root)

    for para in root.iter(f"{{{W}}}p"):
        para_text = text_of(para)
        current_text: list[str] = []
        current_color: str | None = None
        for run in para.findall(f"{{{W}}}r"):
            if id(run) in sdt_runs:
                continue
            color = _run_highlight_color(run, allowed_colors)
            run_text = text_of(run)
            if color and color == current_color:
                current_text.append(run_text)
                continue
            _flush_highlight(fields, current_text, current_color, para_text)
            current_text = [run_text] if color else []
            current_color = color
        _flush_highlight(fields, current_text, current_color, para_text)
    return fields


# --------------------- Word comments --------------------- #


def _load_comments_map(zf: zipfile.ZipFile) -> dict[str, str]:
    """Return {comment_id: comment_text} from word/comments.xml."""
    root = read_part(zf, "word/comments.xml")
    if root is None:
        return {}
    out: dict[str, str] = {}
    for c in root.iter(f"{{{W}}}comment"):
        cid = c.get(f"{{{W}}}id")
        if cid is None:
            continue
        out[cid] = truncate(text_of(c), MAX_DESCRIPTION_CHARS)
    return out


def _anchored_text(para: ET.Element, start: ET.Element, ranges: dict[str, ET.Element]) -> str:
    """Concatenate text between commentRangeStart and matching End in para."""
    cid = start.get(f"{{{W}}}id")
    end = ranges.get(cid or "")
    if end is None:
        return ""
    chunks: list[str] = []
    capture = False
    for child in para.iter():
        if child is start:
            capture = True
            continue
        if child is end:
            break
        if capture and child.tag == f"{{{W}}}t":
            chunks.append(child.text or "")
    return "".join(chunks).strip()


def extract_comments(root: ET.Element, comments_map: dict[str, str]) -> list[Field]:
    """Emit one Field per Word comment that anchors a span of text.

    The comment text becomes the description (the human's instruction);
    the anchored span becomes the label, and the slug becomes the key.
    """
    fields: list[Field] = []
    for para in root.iter(f"{{{W}}}p"):
        starts = list(para.iter(f"{{{W}}}commentRangeStart"))
        if not starts:
            continue
        ends_by_id = {e.get(f"{{{W}}}id") or "": e for e in para.iter(f"{{{W}}}commentRangeEnd")}
        for start in starts:
            cid = start.get(f"{{{W}}}id") or ""
            if cid not in comments_map:
                continue
            anchor = _anchored_text(para, start, ends_by_id)
            if not anchor:
                anchor = truncate(text_of(para), MAX_LABEL_CHARS)
            comment_text = comments_map[cid]
            fields.append(
                Field(
                    key=slugify(comment_text or anchor),
                    label=truncate(anchor, MAX_LABEL_CHARS) or "comment",
                    kind="instruction",
                    source="comment",
                    description=f"Word comment: {comment_text}",
                    first_paragraph_text=truncate(text_of(para)),
                )
            )
    return fields


# --------------------- Repeat detection --------------------- #


def _row_signature(row: ET.Element) -> tuple[bool, ...]:
    """Tuple capturing the SDT shape of a table row."""
    return tuple(
        sdt.find(f"{{{W}}}sdtPr/{{{W}}}tag") is not None for sdt in row.iter(f"{{{W}}}sdt")
    )


def detect_table_repeats(root: ET.Element) -> list[dict[str, Any]]:
    """Find <w:tbl> with ≥2 body rows of identical SDT-pattern."""
    repeats: list[dict[str, Any]] = []
    for tbl_idx, tbl in enumerate(root.iter(f"{{{W}}}tbl")):
        rows = tbl.findall(f"{{{W}}}tr")
        if len(rows) < MIN_REPEAT_ROWS:
            continue
        body_sigs = [_row_signature(r) for r in rows[1:]]
        if not body_sigs or not all(s == body_sigs[0] for s in body_sigs):
            continue
        if not body_sigs[0]:
            continue  # rows have no SDTs — not a schema repeat
        row_fields = extract_sdts(rows[1])
        if not row_fields:
            continue
        row_text = truncate(text_of(rows[0]), MAX_LABEL_CHARS)
        repeat_key = slugify(row_text) or f"repeat_{tbl_idx}"
        repeats.append(
            {
                "key": repeat_key,
                "row_template": [f.to_dict() for f in row_fields],
                "evidence": (f"table {tbl_idx}, {len(rows)} rows, header: {row_text}"),
            }
        )
    return repeats


# --------------------- Pipeline --------------------- #


def deduplicate(fields: list[Field]) -> list[Field]:
    """Collapse fields with the same key; bump occurrences."""
    by_key: dict[str, Field] = {}
    for field in fields:
        existing = by_key.get(field.key)
        if existing is None:
            by_key[field.key] = field
            continue
        existing.occurrences += 1
        if existing.kind == "text" and field.kind != "text":
            existing.kind = field.kind
            existing.enum = field.enum
            existing.format = field.format
    return list(by_key.values())


def _validate_input(input_path: Path) -> None:
    """Reject unsupported file types early."""
    suffix = input_path.suffix.lower()
    if suffix not in {".dotx", ".docx", ".dotm", ".docm"}:
        raise ValueError(f"Unsupported file type: {suffix}. Expected .dotx/.docx.")


def _build_warnings(fields: list[Field], repeats: list[dict[str, Any]]) -> list[str]:
    """Surface places the heuristics weren't confident."""
    warnings: list[str] = []
    instructions = sum(1 for f in fields if f.kind == "instruction")
    if instructions:
        warnings.append(
            f"{instructions} instruction-kind fields need human review — "
            "decide concrete keys and types before handing to the agent"
        )
    if repeats:
        warnings.append(f"{len(repeats)} repeat groups inferred heuristically — verify")
    return warnings


def extract_all(
    input_path: Path,
    *,
    include_instructions: bool,
    detect_repeats: bool,
    include_comments: bool,
    highlight_colors: frozenset[str],
) -> dict[str, Any]:
    """Run extraction and return the schema dict."""
    _validate_input(input_path)
    sha = hashlib.sha256(input_path.read_bytes()).hexdigest()
    fields: list[Field] = []
    repeats: list[dict[str, Any]] = []

    with zipfile.ZipFile(input_path) as zf:
        comments_map = _load_comments_map(zf) if include_comments else {}
        for part_name in list_parts(zf):
            root = read_part(zf, part_name)
            if root is None:
                continue
            fields.extend(extract_sdts(root))
            fields.extend(extract_field_codes(root))
            fields.extend(extract_placeholders(root))
            if include_instructions:
                fields.extend(extract_highlights(root, highlight_colors))
            if include_comments and comments_map:
                fields.extend(extract_comments(root, comments_map))
            if detect_repeats and part_name == "word/document.xml":
                repeats.extend(detect_table_repeats(root))

    deduped = deduplicate(fields)
    warnings = _build_warnings(deduped, repeats)

    return {
        "template": {
            "path": str(input_path),
            "sha256": sha,
            "extracted_at": dt.datetime.now(dt.UTC).isoformat(),
        },
        "fields": [f.to_dict() for f in deduped],
        "repeats": repeats,
        "warnings": warnings,
    }


def write_summary_md(schema: dict[str, Any], path: Path) -> None:
    """Write a human-readable markdown summary alongside the JSON."""
    tpl = schema["template"]
    lines: list[str] = [
        "# Template schema summary",
        "",
        f"- **template**: `{tpl['path']}`",
        f"- **sha256**: `{tpl['sha256'][:16]}…`",
        f"- **extracted_at**: {tpl['extracted_at']}",
        "",
        f"## Fields ({len(schema['fields'])})",
        "",
        "|key|kind|source|label|",
        "|---|---|---|---|",
    ]
    for f in schema["fields"]:
        lines.append(f"|`{f['key']}`|{f['kind']}|{f['source']}|" f"{truncate(f['label'], 60)}|")
    lines.append("")
    if schema["repeats"]:
        lines += [f"## Repeats ({len(schema['repeats'])})", ""]
        for r in schema["repeats"]:
            lines.append(
                f"- `{r['key']}` — {len(r['row_template'])} fields per row " f"({r['evidence']})"
            )
        lines.append("")
    if schema["warnings"]:
        lines += ["## Warnings", ""]
        lines += [f"- {w}" for w in schema["warnings"]]
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary-md", type=Path, default=None)
    parser.add_argument(
        "--include-instructions",
        dest="include_instructions",
        action="store_true",
        default=True,
    )
    parser.add_argument("--no-instructions", dest="include_instructions", action="store_false")
    parser.add_argument(
        "--detect-repeats",
        dest="detect_repeats",
        action="store_true",
        default=True,
    )
    parser.add_argument("--no-repeats", dest="detect_repeats", action="store_false")
    parser.add_argument(
        "--include-comments",
        dest="include_comments",
        action="store_true",
        default=True,
        help="Treat Word comments as instruction fields (default: on).",
    )
    parser.add_argument("--no-comments", dest="include_comments", action="store_false")
    parser.add_argument(
        "--highlight-colors",
        type=str,
        default=",".join(DEFAULT_HIGHLIGHT_COLORS),
        help=(
            "Comma-separated <w:highlight> values to treat as instruction "
            "markers. Default: cyan,yellow. Other valid Word values include "
            "green, red, magenta, blue, darkYellow, lightGray, etc."
        ),
    )
    return parser


def _parse_colors(raw: str) -> frozenset[str]:
    """Split a CSV color list and reject empties."""
    colors = {c.strip() for c in raw.split(",") if c.strip()}
    if not colors:
        raise ValueError("--highlight-colors must list at least one color")
    return frozenset(colors)


def main() -> int:
    args = _build_parser().parse_args()
    if not args.input.exists():
        logger.error("Input not found: %s", args.input)
        return 2
    try:
        highlight_colors = _parse_colors(args.highlight_colors)
        schema = extract_all(
            args.input.resolve(),
            include_instructions=args.include_instructions,
            detect_repeats=args.detect_repeats,
            include_comments=args.include_comments,
            highlight_colors=highlight_colors,
        )
    except ValueError as e:
        logger.error("Extraction failed: %s", e)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(schema, ensure_ascii=False, indent=2))
    if args.summary_md:
        write_summary_md(schema, args.summary_md)

    fields_count = len(schema["fields"])
    controls = sum(1 for f in schema["fields"] if f["source"] == "sdt")
    comments_count = sum(1 for f in schema["fields"] if f["source"] == "comment")
    repeats_count = len(schema["repeats"])
    print(
        f"fields={fields_count} controls={controls} "
        f"comments={comments_count} repeats={repeats_count} "
        f"warnings={len(schema['warnings'])}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
