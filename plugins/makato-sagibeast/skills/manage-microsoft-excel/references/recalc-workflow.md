# recalc.py Workflow Reference

Full contract for invoking `scripts/recalc.py` and interpreting its output.

---

## Why recalc.py is mandatory

openpyxl writes Excel formulas as **literal strings** — it does not evaluate them. A file
saved by openpyxl has formula text in cells but no calculated values. LibreOffice
recalculates the file in headless mode and writes the evaluated values back, making the
file behave identically to one saved by Excel itself.

Without recalc.py, any file with formulas will show `0`, stale values, or blank cells
when opened in Excel or Google Sheets.

---

## Invocation

```bash
# Resolve repo root first — never rely on cwd
REPO_ROOT=$(git rev-parse --show-toplevel)
python "$REPO_ROOT/scripts/recalc.py" <excel_file> [timeout_seconds]
```

Default timeout is 30 seconds. For models with many cross-sheet formulas, use 60–120.

Example:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
python "$REPO_ROOT/scripts/recalc.py" output.xlsx 60
```

---

## Output JSON schema

```json
{
  "status": "success",
  "total_errors": 0,
  "total_formulas": 42,
  "error_summary": {
    "#REF!": {
      "count": 2,
      "locations": ["Sheet1!B5", "Sheet1!C10"]
    }
  }
}
```

`error_summary` is only present when `status` is `"errors_found"`.

---

## Error → Fix mapping

| Error code | Root cause | Fix |
|---|---|---|
| `#REF!` | Cell reference points to deleted row/column or out-of-bounds range | Rebuild the formula; check for off-by-one in openpyxl (1-based) |
| `#DIV/0!` | Formula divides by a cell that is zero or empty | Wrap denominator: `=IF(B2=0,"",A2/B2)` |
| `#VALUE!` | Formula receives wrong data type (e.g., text where number expected) | Check source cells; cast if needed |
| `#NAME?` | Formula function name unrecognized or typo | Verify function name spelling; check for locale-specific function names |
| `#N/A` | VLOOKUP / MATCH / INDEX found no match | Use `IFERROR` or confirm lookup range covers the value |

---

## Retry loop pattern

```
write formulas → recalc.py → errors_found?
   yes → fix identified cells → recalc.py again (max 3 attempts)
   no  → done
```

If errors persist after 3 attempts, open the file in LibreOffice manually to inspect.
Circular references are NOT reported as standard errors — LibreOffice silently resolves
them to 0 or last value. Check for unintended circulars explicitly if results look wrong.

---

## LibreOffice absence / timeout

- If `recalc.py` exits with a non-zero code and prints `LibreOffice not found`, install
  LibreOffice and retry. The script does not install it automatically.
- If recalc.py times out: increase `timeout_seconds`. A 200-row DCF with cross-sheet
  lookups typically needs 30–60 s; a complex 10-tab model may need 120 s.
- On first run in a sandboxed environment the script configures the LibreOffice macro
  profile via `scripts/office/soffice.py` — this adds ~10 s to the first invocation only.

---

## Encrypted / password-protected files

`recalc.py` cannot open password-protected `.xlsx` files. Remove the password in Excel
or LibreOffice before passing the file to the script.
