---
name: manage-pdf
description: >-
  Use this skill whenever the user wants to do anything with PDF files in a
  contract management context. Covers: reading or extracting clauses and
  structured data from contract PDFs, OCR on scanned invoices or signed
  contracts, PII redaction for data-protection compliance, combining or
  splitting contract documents, filling PDF forms, adding watermarks or
  encryption, and creating PDFs from contract data. Trigger keywords: .pdf,
  extract clauses, scanned invoice, OCR contract, redact PII, fill form,
  merge PDFs, split pages, watermark, encrypt PDF, contract document.
version: "1.1.0"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
metadata:
  authors: [makato-sagibeast]
  last_updated: "2026-08-05"
  argument-hint: "<pdf_file_path> [task description]"
---

# manage-pdf

## Mindset

Contract PDFs are **evidence artifacts** — they record commitments, prices, and
signatures. Every operation must preserve fidelity: text extraction must be
character-accurate, redaction must be irreversible (not just visually hidden),
and any output delivered back to a contract workflow must be auditable.

Read-only analysis tasks (extract, OCR, parse tables) are low-consequence.
Destructive tasks (encrypt, password-remove, redact, overwrite) are
**high-consequence** — prefer writing to a new file and confirming before
discarding the original.

---

## Library Selection Decision Tree

```
Is the PDF scanned (image-only, no embedded text layer)?
  YES → pytesseract + pdf2image  (OCR pipeline; see OCR section)
  NO  → Does the task need table extraction or spatial layout?
          YES → pdfplumber  (coordinate-based, best for invoices/tables)
          NO  → Does the task need merge/split/rotate/encrypt/watermark?
                  YES → pypdf  (low-level page manipulation)
                  NO  → Does the task create a new PDF from contract data?
                          YES → reportlab  (canvas for complex; Platypus for prose)
                          NO  → pdftotext CLI  (fastest plain-text dump)
```

Key rule: **never mix pdfplumber and pypdf in the same write operation.**
pdfplumber is read-only; pypdf is the write layer. Attempting to save a
pdfplumber object via pypdf produces a corrupt file with no error.

---

## Contract-Specific Workflows

### 1 — Clause Extraction from Native PDFs

Native-text contract PDFs (not scanned) have an internal text ordering that
does NOT match visual reading order when columns, headers, or footnotes exist.
pdfplumber's coordinate-aware extraction handles this; pypdf's `extract_text()`
joins lines by internal PDF order which can interleave footnotes with body text.

```python
import pdfplumber, re

CLAUSE_PATTERN = re.compile(r'^(\d+\.\d*)\s+(.+)', re.MULTILINE)

def extract_clauses(pdf_path: str) -> list[dict]:
    clauses = []
    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages, start=1):
            # crop() removes headers/footers that pollute clause text
            body = page.crop((
                page.bbox[0],
                page.bbox[1] + 40,   # trim 40pt top margin (page header)
                page.bbox[2],
                page.bbox[3] - 40,   # trim 40pt bottom margin (page footer)
            ))
            text = body.extract_text(x_tolerance=2, y_tolerance=3) or ""
            for match in CLAUSE_PATTERN.finditer(text):
                clauses.append({
                    "clause_id": match.group(1),
                    "text": match.group(2).strip(),
                    "page": page_num,
                })
    return clauses
```

`x_tolerance` / `y_tolerance` — contract PDFs from Word often have tight
character spacing; tolerance=2 prevents words being split at glyph boundaries.

### 2 — Scanned Invoice / Contract OCR

Scanned contracts (signed originals, faxed invoices) require OCR. The critical
contract-domain setting is `--psm 6` (uniform block of text) — the default
`--psm 3` (auto) misreads column-separated price tables as paragraph text.

MANDATORY load: references/ocr-contract-patterns.md — read before performing
OCR on any scanned contract or invoice. Contains DPI guidance, language packs
for multilingual contracts, post-OCR correction heuristics, and confidence
thresholds for unattended pipelines.

Do NOT load references/ocr-contract-patterns.md for native-text PDFs that
already have an embedded text layer (check with `pdfplumber.open(f).pages[0].extract_text()`
— non-empty means native).

Quick reference (full guidance in the reference file):

```python
from pdf2image import convert_from_path
import pytesseract

def ocr_contract(pdf_path: str, lang: str = "eng") -> str:
    # 300 DPI minimum for A4 contract text; 400 DPI for small print / stamp text
    images = convert_from_path(pdf_path, dpi=300)
    full_text = []
    for i, img in enumerate(images):
        # psm 6 = uniform text block; best for contract body paragraphs
        # psm 4 = single column of varying text; use for invoices with line items
        page_text = pytesseract.image_to_string(
            img, lang=lang,
            config="--psm 6 --oem 3"
        )
        full_text.append(f"--- Page {i+1} ---\n{page_text}")
    return "\n".join(full_text)
```

### 3 — PII Redaction for Contract Documents

**Redaction is irreversible; visual-only hiding is not redaction.**

A common contract-workflow mistake is drawing a black rectangle over PII on
the PDF canvas — the underlying text is still in the PDF's content stream and
can be extracted with `pdftotext`. True redaction requires removing the content
stream text.

MANDATORY load: references/pdf-forms-and-advanced.md — read before any
redaction task. Contains the correct pikepdf-based content-stream redaction
approach, coordinate mapping, and the audit-log format for GDPR compliance.

Do NOT load references/pdf-forms-and-advanced.md for read-only extraction,
OCR, or merge/split tasks.

Quick reference for the two-step detection + redact pattern:

```python
import pdfplumber, re

PII_PATTERNS = {
    "email": re.compile(r'[\w.+-]+@[\w-]+\.\w{2,}'),
    "iban": re.compile(r'[A-Z]{2}\d{2}[\w\s]{11,30}'),
    "ico": re.compile(r'\b\d{8}\b'),          # Czech company ID (IČO)
    "rc":  re.compile(r'\b\d{6}/\d{3,4}\b'), # Czech birth number (RČ)
}

def find_pii_bboxes(pdf_path: str) -> list[dict]:
    """Returns list of {page, pattern_name, bbox, text} for confirmed PII hits."""
    hits = []
    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages, start=1):
            words = page.extract_words(x_tolerance=2)
            # reconstruct line segments to match multi-word IBANs
            text = page.extract_text() or ""
            for name, pattern in PII_PATTERNS.items():
                for m in pattern.finditer(text):
                    # map match back to word bboxes for precise coordinate
                    hits.append({"page": page_num, "pattern": name,
                                 "match": m.group()})
    return hits
```

Coordinate-to-redaction mapping requires pikepdf (see reference file) — the
bounding box from pdfplumber uses PDF user-space coordinates which must be
translated to pikepdf's page coordinate system.

### 4 — Structured Table Extraction from Invoices

Invoice PDFs from accounting systems (SAP, Pohoda, Helios) embed tables as
positioned text, not proper PDF table objects. pdfplumber infers table grid
lines from text alignment — calibrate `snap_tolerance` when the default (3)
misses columns.

```python
with pdfplumber.open("invoice.pdf") as pdf:
    page = pdf.pages[0]
    # snap_tolerance=5 catches columns whose left edges vary by up to 5pt
    # (common in Czech invoice templates with proportional fonts)
    settings = {
        "vertical_strategy": "text",
        "horizontal_strategy": "text",
        "snap_tolerance": 5,
        "join_tolerance": 3,
    }
    tables = page.extract_tables(table_settings=settings)
```

When `extract_tables()` returns nothing on a visually obvious table: the PDF
uses ruled lines (not text alignment) — switch to `vertical_strategy: "lines"`
and `horizontal_strategy: "lines"`.

---

## Standard Operations

### Merge / Split / Rotate

Low-consequence operations; use pypdf directly.

```python
from pypdf import PdfReader, PdfWriter

# Merge
writer = PdfWriter()
for pdf_path in ["contract.pdf", "annex-1.pdf", "annex-2.pdf"]:
    writer.append(pdf_path)  # append() preferred over page-by-page add_page

with open("merged.pdf", "wb") as f:
    writer.write(f)

# Split: extract pages 0-4 (1-5 in 1-based numbering)
writer = PdfWriter()
reader = PdfReader("full_contract.pdf")
for page in reader.pages[0:5]:
    writer.add_page(page)
with open("contract_pages_1_5.pdf", "wb") as f:
    writer.write(f)
```

### PDF Form Filling

MANDATORY load: references/pdf-forms-and-advanced.md — read before filling any
PDF form. Contains AcroForm field enumeration, pypdf vs pdf-lib selection, and
handling of flattened vs non-flattened forms.

Do NOT load references/pdf-forms-and-advanced.md for non-form tasks (merge,
split, extraction, OCR).

### Encryption and Password Removal

High-consequence — always write to a new output file; do not overwrite the
original in place.

```python
from pypdf import PdfReader, PdfWriter

# Add encryption (owner password controls print/copy permissions)
writer = PdfWriter()
writer.append("contract.pdf")
writer.encrypt(
    user_password="view_password",
    owner_password="owner_password",
    use_128bit=True,   # 40-bit is broken; always use 128+ for contract docs
)
with open("contract_encrypted.pdf", "wb") as f:
    writer.write(f)

# Remove password (requires knowing the password — not a bypass)
reader = PdfReader("contract_encrypted.pdf")
reader.decrypt("view_password")
writer = PdfWriter()
writer.append_pages_from_reader(reader)
with open("contract_decrypted.pdf", "wb") as f:
    writer.write(f)
```

---

## Anti-patterns

### NEVER draw a black rectangle over PII and call it "redacted"

**WHY**: pypdf's `add_annotation()` and reportlab overlays write a visual layer
on top of text — they do NOT remove the content stream. Any reader calling
`pdftotext` or pdfplumber on the "redacted" file recovers the original text
verbatim. This creates a GDPR / data-protection liability and a false sense of
security. True redaction requires removing the text from the content stream
with pikepdf — see references/pdf-forms-and-advanced.md.

### NEVER call pypdf's `extract_text()` on scanned PDFs and rely on the result

**WHY**: Scanned PDFs have no embedded text layer. `extract_text()` returns an
empty string (or garbage from a thin font layer) without raising an error. The
caller sees an empty result and may wrongly conclude the contract has no text,
skip OCR, and report the document as empty. Always confirm a PDF has a text
layer before using `extract_text()`: check that `len(reader.pages[0].extract_text()) > 50`.
Below that threshold, treat as scanned and route through the OCR pipeline.

### NEVER use Unicode subscript/superscript characters in reportlab PDFs

**WHY**: reportlab's built-in Type-1 fonts (Helvetica, Times-Roman, Courier)
do not include Unicode subscript/superscript glyphs (₀₁₂, ⁰¹²). They render
as solid black boxes — not missing-glyph boxes, but solid fill — with no error
or warning during `doc.build()`. The error only surfaces when the PDF is opened.
Use `<sub>` / `<super>` XML tags in `Paragraph` objects instead, or manually
adjust font size and y-position for canvas-drawn text.

### NEVER mix pdfplumber and pypdf in a write pipeline

**WHY**: pdfplumber is a read-only wrapper around pdfminer. A `pdfplumber.PDF`
object cannot be passed to a `pypdf.PdfWriter` — the internal page objects are
incompatible types. Attempting this raises an `AttributeError` that is easy to
misread as a data error. Always read with pdfplumber, then open the same file
independently with `pypdf.PdfReader` for any write step.

### NEVER use qpdf's `--decrypt` to strip passwords you do not own

**WHY**: qpdf can remove 40-bit RC4 encryption without the password; 128-bit
AES contracts require knowing the password. Using `--decrypt` without
`--password` on a 128-bit file silently produces a file that still requires
the password — no error is raised if the decryption appears to complete. Always
verify the output is actually accessible with a blank password before discarding
the original.

### NEVER deliver a contract PDF with formulas or computed values baked in
without source traceability

**WHY**: reportlab writes static text. If you compute a total in Python
(`total = sum(items)`) and render it with `drawString`, the PDF shows the
number with no formula. If the source data changes, the PDF is wrong with no
indication. For contract documents, always include source metadata (e.g., a
footer citing "Generated from invoice_data.json on {date}") so the recipient
knows the document is a point-in-time snapshot.

---

## Error Handling

| Symptom | Likely Cause | Fix |
|---|---|---|
| `extract_text()` returns `""` on every page | Scanned PDF (no text layer) | Route through OCR pipeline |
| pdfplumber table returns `None` | No table detected with current strategy | Try `vertical_strategy: "lines"` |
| reportlab renders black boxes for some chars | Unicode sub/superscripts in font | Use `<sub>`/`<super>` tags |
| pypdf `PdfReadError: EOF marker not found` | Truncated or corrupt PDF | Try `strict=False`; if fails, use `qpdf --linearize` to repair |
| OCR output garbled numbers on invoices | Wrong Tesseract PSM | Use `--psm 4` for single-column invoices |
| pikepdf `PdfError` on redaction | PDF uses cross-reference streams (PDF 1.5+) | Add `compress_streams=False` when saving |
| qpdf decrypt appears to succeed but file still prompts for password | 128-bit AES without correct password | Obtain correct password; qpdf cannot brute-force AES |

---

## Quick Reference

| Task | Library | Contract-domain note |
|---|---|---|
| Extract clauses (native PDF) | pdfplumber | Crop headers/footers; use `x_tolerance=2` |
| Extract invoice tables | pdfplumber | Use `text` strategy; tune `snap_tolerance` |
| OCR scanned contracts | pytesseract + pdf2image | 300 DPI; `--psm 6` for body, `--psm 4` for line items |
| PII redaction (GDPR) | pikepdf | Content-stream removal, not visual overlay |
| Merge contract + annexes | pypdf | Use `writer.append()` not page-by-page loop |
| Fill PDF form | pypdf / pdf-lib | See references/pdf-forms-and-advanced.md |
| Encrypt contract PDF | pypdf | Always 128-bit AES; write to new file |
| Create PDF from data | reportlab | Static snapshot; include generation metadata footer |
| CLI text dump | pdftotext | `-layout` preserves column alignment |

---

## Output Audit Entry

Emit a JSONL audit entry at session end (required per plugin AGENTS.md):

```json
{"event": "manage-pdf.session_end", "input_file": "<path>",
 "output_file": "<path_or_null>", "operation": "<extract|ocr|redact|merge|split|form|encrypt|create>",
 "pages_processed": 0, "pii_hits": 0}
```
