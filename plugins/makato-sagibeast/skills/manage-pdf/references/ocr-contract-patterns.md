# OCR Contract Patterns Reference

Load this file BEFORE performing OCR on any scanned contract or invoice.

---

## DPI Selection

| Document type | DPI | Reason |
|---|---|---|
| Standard A4 contract body text (≥10pt) | 300 | Minimum for reliable character recognition |
| Small-print clauses, footnotes (8–9pt) | 400 | Lower DPI causes merged characters |
| Rubber stamp / handwritten annotations | 400 | High contrast variation requires more resolution |
| Fax-quality scans (already degraded) | 300 (no upscaling) | Upscaling fax artifacts worsens OCR; accept lower confidence |

## Tesseract PSM Selection for Contracts

| Content type | PSM | Notes |
|---|---|---|
| Contract body (prose paragraphs) | `--psm 6` | Uniform text block; default for contracts |
| Invoice line-item table | `--psm 4` | Single column of varying sizes; better for tabular structures |
| Signature blocks / stamps | `--psm 7` | Single line; avoids multi-line merging |
| Mixed contract + tables | `--psm 3` | Auto-detect; use only when layout is unpredictable |

Always specify `--oem 3` (LSTM engine) — OEM 0 (legacy) produces inferior results on modern contract fonts.

## Language Packs

Czech/Slovak contracts require the `ces` (Czech) language pack, not just `eng`:

```python
pytesseract.image_to_string(img, lang="ces+eng", config="--psm 6 --oem 3")
```

The `+` operator tells Tesseract to apply both language models — useful for contracts with English headings and Czech body text (common in international procurement).

Installing language packs (if missing):

```bash
# macOS
brew install tesseract-lang

# Ubuntu/Debian
sudo apt-get install tesseract-ocr-ces tesseract-ocr-slk
```

## Pre-processing for Degraded Scans

Deskewing and binarization significantly improve accuracy on fax-quality or
low-contrast scans. Apply before passing to pytesseract:

```python
from PIL import Image, ImageFilter, ImageOps
import numpy as np

def preprocess_for_ocr(img: Image.Image) -> Image.Image:
    # Convert to grayscale
    img = img.convert("L")
    # Increase contrast (helps for faded stamps or light toner)
    img = ImageOps.autocontrast(img, cutoff=2)
    # Sharpen slightly to help character edge detection
    img = img.filter(ImageFilter.SHARPEN)
    return img
```

For severe skew (documents scanned at an angle), use `deskew` library:

```bash
pip install deskew
```

```python
from deskew import determine_skew
from skimage.transform import rotate
import numpy as np
from PIL import Image

def deskew_image(img: Image.Image) -> Image.Image:
    arr = np.array(img)
    angle = determine_skew(arr)
    if abs(angle) > 0.5:  # skip tiny corrections (noise threshold)
        arr = rotate(arr, angle, resize=True, mode='constant', cval=255)
    return Image.fromarray(arr.astype(np.uint8))
```

## Confidence Thresholds for Unattended Pipelines

When running OCR in an automated contract ingestion pipeline (no human review):

```python
import pytesseract
import json

def ocr_with_confidence(img, lang="ces+eng") -> dict:
    data = pytesseract.image_to_data(
        img, lang=lang, config="--psm 6 --oem 3",
        output_type=pytesseract.Output.DICT
    )
    confidences = [int(c) for c in data['conf'] if int(c) >= 0]
    avg_conf = sum(confidences) / len(confidences) if confidences else 0

    return {
        "text": pytesseract.image_to_string(img, lang=lang, config="--psm 6 --oem 3"),
        "avg_confidence": avg_conf,
        "low_confidence": avg_conf < 60,   # flag for human review
    }
```

Threshold guidance:
- `avg_confidence >= 80`: accept automatically
- `60 <= avg_confidence < 80`: accept with review flag in audit log
- `avg_confidence < 60`: route to human review queue; do not ingest automatically

## Post-OCR Number Correction

Common OCR misreads in contract numbers and IBANs:

| OCR output | Likely actual | Context |
|---|---|---|
| `l` (lowercase L) | `1` | Inside numeric sequences |
| `O` (uppercase O) | `0` | Inside numeric sequences |
| `5` | `S` | In company name acronyms only |
| `I` (uppercase i) | `1` | Inside numeric sequences |

Apply targeted correction only inside detected numeric fields (IČO, IBANs, invoice numbers) — do not apply globally or you corrupt text.

```python
def fix_numeric_ocr(s: str) -> str:
    """Correct common OCR misreads inside numeric strings."""
    return s.replace('l', '1').replace('O', '0').replace('I', '1')
```

## Audit Entry for OCR Operations

```json
{"event": "manage-pdf.ocr", "input_file": "<path>", "pages": 0,
 "dpi": 300, "lang": "ces+eng", "avg_confidence": 0.0, "flagged_for_review": false}
```
