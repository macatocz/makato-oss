# PDF Forms and Advanced Operations Reference

Load this file BEFORE filling PDF forms, performing PII redaction, or using
advanced features (pypdfium2, JavaScript libraries, content-stream operations).

---

## PDF Form Filling

### Detecting Form Type

Before filling, determine whether the form uses AcroForms or XFA:

```python
from pypdf import PdfReader

reader = PdfReader("form.pdf")
fields = reader.get_fields()
if fields:
    print("AcroForm fields:", list(fields.keys()))
else:
    # Check for XFA (XML Forms Architecture — used by Adobe LiveCycle)
    if "/XFA" in reader.trailer.get("/Root", {}).get("/AcroForm", {}):
        print("XFA form — pypdf cannot fill; use pdf-lib or Adobe SDK")
    else:
        print("No form fields detected — PDF is not a form")
```

XFA forms are common in government procurement templates (ISVS, datové schránky
exports). pypdf cannot fill XFA forms — use the pdf-lib JavaScript approach
below or notify the user.

### Filling AcroForms with pypdf

```python
from pypdf import PdfReader, PdfWriter

reader = PdfReader("contract_form.pdf")
writer = PdfWriter()
writer.append(reader)

# List available fields first (do this once to map field names)
fields = reader.get_fields()
for name, field in fields.items():
    print(f"  {name}: type={field.field_type}, value={field.value}")

# Fill fields by exact name
writer.update_page_form_field_values(
    writer.pages[0],
    {
        "Contractor_Name": "Novák s.r.o.",
        "Contract_Date": "2026-08-05",
        "Contract_Value": "150 000 Kč",
    }
)

# Flatten the form (lock fields — prevents editing after submission)
# Set flatten=True only when the form is final; flattening is irreversible
with open("contract_form_filled.pdf", "wb") as f:
    writer.write(f)
```

**Flatten vs non-flatten**: Flattening converts form fields to static content
(they can no longer be edited). Use flatten=True for final contract submissions;
leave unflattened when the form may be revised.

### Multi-page Forms

`update_page_form_field_values` applies to one page at a time. For multi-page
forms, iterate over pages:

```python
for page in writer.pages:
    writer.update_page_form_field_values(page, field_values)
```

Some AcroForm templates define fields at the document level, not per-page. If
per-page filling produces no result, use:

```python
writer.update_named_dest_page_form_field_values(field_values)
```

---

## PII Redaction (GDPR-Compliant)

Visual overlays are NOT redaction. Content-stream removal is required.

### Install pikepdf

```bash
pip install pikepdf
```

### Coordinate Mapping

pdfplumber reports bounding boxes in PDF user-space (origin bottom-left).
pikepdf uses the same coordinate system on most PDFs, but some PDFs have a
non-zero `MediaBox` origin or a page rotation — translate coordinates:

```python
import pdfplumber
import pikepdf
from pikepdf import Pdf, Dictionary, Array, Name, Rectangle

def get_page_mediabox_origin(pdf_path: str, page_idx: int) -> tuple[float, float]:
    with pikepdf.open(pdf_path) as pdf:
        page = pdf.pages[page_idx]
        mb = page.MediaBox
        return float(mb[0]), float(mb[1])  # (x_origin, y_origin)
```

### Full Redaction Flow

```python
import pdfplumber
import pikepdf
from pikepdf import Pdf, Dictionary, Array, Name, Rectangle
import re

def redact_pii(input_path: str, output_path: str, patterns: dict) -> int:
    """
    Redacts matched PII by adding a pikepdf redaction annotation and
    applying it. Returns count of redactions applied.
    """
    # Step 1: detect using pdfplumber for accurate coordinates
    hits = []
    with pdfplumber.open(input_path) as plumber_pdf:
        for page_num, page in enumerate(plumber_pdf.pages):
            for name, pattern in patterns.items():
                for word in page.extract_words():
                    if pattern.search(word["text"]):
                        hits.append({
                            "page": page_num,
                            "bbox": (word["x0"], word["top"],
                                     word["x1"], word["bottom"]),
                            "pattern": name,
                            "text": word["text"],
                        })

    # Step 2: apply via pikepdf content-stream redaction
    with pikepdf.open(input_path) as pdf:
        for hit in hits:
            page = pdf.pages[hit["page"]]
            x0, top, x1, bottom = hit["bbox"]
            # PDF y-axis is bottom-up; pdfplumber top is from top
            # Convert: pdf_y = page_height - plumber_top
            page_height = float(page.MediaBox[3]) - float(page.MediaBox[1])
            pdf_y0 = page_height - bottom
            pdf_y1 = page_height - top

            # Add redaction annotation (Redact subtype)
            annot = Dictionary(
                Type=Name("/Annot"),
                Subtype=Name("/Redact"),
                Rect=Array([x0, pdf_y0, x1, pdf_y1]),
                IC=Array([0, 0, 0]),  # black fill
                F=pikepdf.Pdf.make_indirect(pdf, 4),  # print flag
            )
            if "/Annots" not in page:
                page["/Annots"] = Array()
            page["/Annots"].append(pdf.make_indirect(annot))

        # Apply redactions (removes content stream text under annotations)
        pdf.save(output_path, compress_streams=False)

    return len(hits)
```

Note: `compress_streams=False` is required for PDF 1.5+ files that use
cross-reference streams — omitting it causes a `PdfError` on save.

### Verification After Redaction

Always verify that redaction removed the text from the content stream, not just
visually:

```python
with pdfplumber.open(output_path) as pdf:
    for page in pdf.pages:
        text = page.extract_text() or ""
        for name, pattern in patterns.items():
            if pattern.search(text):
                raise ValueError(f"Redaction failed: {name} still present in {output_path}")
```

---

## pypdfium2 (Advanced Use Cases)

pypdfium2 is a Python binding to the PDFium rendering engine (used in Chrome).
Use it when:
- Rendering contract PDFs to high-fidelity images (better than pdf2image for
  PDFs with complex graphics or unusual fonts)
- Accessing JavaScript-based PDF forms (pypdfium2 executes embedded JS)
- Extracting text with accurate reading order from complex layouts

```bash
pip install pypdfium2
```

```python
import pypdfium2 as pdfium

pdf = pdfium.PdfDocument("complex_contract.pdf")
page = pdf[0]

# Render to bitmap at 300 DPI (scale = DPI / 72.0)
bitmap = page.render(scale=300/72, rotation=0)
pil_image = bitmap.to_pil()

# Extract text with reading-order guarantee
text_page = page.get_textpage()
print(text_page.get_text_range())  # reading-order text
```

pypdfium2 does not support writing PDFs. Use pypdf for write operations.

---

## pdf-lib (JavaScript — for Node.js or browser environments)

Use pdf-lib when the contract workflow runs in a JavaScript environment
(browser form, Node.js API) or when the form uses XFA that Python cannot fill.

```javascript
import { PDFDocument, rgb } from 'pdf-lib';
import fs from 'fs';

async function fillForm(inputPath, outputPath, fieldValues) {
  const pdfBytes = fs.readFileSync(inputPath);
  const pdfDoc = await PDFDocument.load(pdfBytes);
  const form = pdfDoc.getForm();

  for (const [fieldName, value] of Object.entries(fieldValues)) {
    try {
      const field = form.getTextField(fieldName);
      field.setText(value);
    } catch (e) {
      console.warn(`Field not found: ${fieldName}`);
    }
  }

  const filledBytes = await pdfDoc.save();
  fs.writeFileSync(outputPath, filledBytes);
}
```

pdf-lib supports flattening via `form.flatten()` before `pdfDoc.save()`.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `PdfReadError: EOF marker not found` | Truncated download or corrupt transfer | `qpdf --linearize input.pdf output.pdf` to repair |
| pikepdf `PdfError` on save | Cross-reference streams (PDF 1.5+) | Add `compress_streams=False` to `pdf.save()` |
| Form fields not updated after `update_page_form_field_values` | Multi-page form with document-level fields | Use `update_named_dest_page_form_field_values` |
| XFA form — `get_fields()` returns `None` | pypdf cannot handle XFA | Use pdf-lib or notify user |
| Redaction text still extractable after save | Content stream not cleared | Verify pikepdf version ≥ 8; use `compress_streams=False` |
| pypdfium2 import error on macOS ARM | Binary incompatibility | `pip install pypdfium2 --force-reinstall` |
