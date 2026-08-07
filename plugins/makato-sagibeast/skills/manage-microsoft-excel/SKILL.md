---
name: manage-microsoft-excel
description: >-
  Use this skill any time a spreadsheet file is the primary input or output.
  Covers: open, read, edit, or fix an existing .xlsx, .xlsm, .csv, or .tsv
  file (adding columns, computing formulas, formatting, charting, cleaning
  messy data); create a new spreadsheet from scratch or from other data
  sources; convert between tabular file formats. Trigger especially when the
  user references a spreadsheet file by name or path — even casually (like
  "the xlsx in my downloads") — and wants something done to it or produced
  from it. Also trigger for cleaning or restructuring messy tabular data files
  (malformed rows, misplaced headers, junk data) into proper spreadsheets.
  The deliverable must be a spreadsheet file. Do NOT trigger when the primary
  deliverable is a Word document, HTML report, standalone Python script,
  database pipeline, or Google Sheets API integration, even if tabular data
  is involved.
version: "1.1.0"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
metadata:
  authors: [makato-sagibeast]
  last_updated: "2026-08-05"
  argument-hint: "<excel_file_path> [task description]"
---

# manage-microsoft-excel

## Mindset

Spreadsheets used in financial or contract workflows are **living documents** —
other users will change inputs and expect formulas to recalculate. Every
decision here is made through that lens: prefer dynamic formulas over computed
constants, preserve template conventions over personal style, and treat
formula errors as hard defects, not cosmetic issues.

---

## Tool Selection Decision Tree

```
Task involves formulas, formatting, charts, or merging multiple sheets?
  YES → openpyxl  (preserves formula strings, full style control)
  NO  → Is the task purely data analysis, aggregation, or bulk export?
          YES → pandas  (vectorized ops, faster for large tables)
          NO  → Mixed: read with pandas, write final output with openpyxl
```

**openpyxl gotcha table** (things Claude does NOT reliably get right without reminding):

| Issue | Rule |
|---|---|
| 1-based indexing | `row=1, col=1` → cell A1. DataFrame row 5 = Excel row 6 (header offset). |
| `data_only=True` | Reads cached values instead of formula strings. If you save after loading with `data_only=True`, all formulas are **permanently destroyed** — no undo. |
| Formula strings as text | openpyxl writes `=SUM(A1:A9)` as a string; values are NOT evaluated until recalc.py runs. |
| Column mapping | Excel column 64 = BL, not BK. Always verify with `get_column_letter(n)` before writing formulas that reference far-right columns. |

---

## Core Workflow

0. **Pre-flight: verify recalc.py** — confirm the script is present before investing time in
   formula writing. Skip this step for pure pandas data-analysis tasks that produce no formulas.

   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   test -f "$REPO_ROOT/scripts/recalc.py" || {
     echo "HALT: scripts/recalc.py not found in $REPO_ROOT. Either ship this file in the target repo or skip formula writing for this session."
     exit 1
   }
   ```

1. **Plan** — identify whether task needs formulas/formatting (openpyxl) or bulk data (pandas)
2. **Load / create** — open existing file or create new workbook
3. **Write Excel formulas** (not Python-computed constants — see Anti-patterns)
4. **Save** the file
5. **Recalculate** — run `scripts/recalc.py` (MANDATORY when formulas were written)
6. **Verify** — check JSON output; if `status: errors_found`, fix and re-run (max 3 attempts)
7. **Deliver** — confirm output file path and summarize changes made

### Recalculate — exact invocation

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
python "$REPO_ROOT/scripts/recalc.py" <excel_file> [timeout_seconds]
```

MANDATORY: resolve `REPO_ROOT` with `git rev-parse --show-toplevel`, never with `pwd`
or a relative path — the relative path `scripts/recalc.py` silently breaks when called
from any directory other than the repo root.

MANDATORY load: references/recalc-workflow.md — read before first recalc.py invocation
for the full JSON schema, error-to-fix table, retry loop, timeout guidance, and encrypted
file handling.

Do NOT load references/recalc-workflow.md for pure pandas data-analysis tasks that
produce no formulas.

---

## Financial Models

MANDATORY load: references/financial-model-standards.md — read whenever building or
editing a financial model (income statement, DCF, LBO, budget, pricing model, or any
file where cells drive downstream valuation decisions).

Do NOT load references/financial-model-standards.md for generic data cleaning, CSV
conversion, or reporting tasks with no financial calculations.

Quick reference (full spec in the reference file):

- **Blue text** = hardcoded inputs; **black** = formulas; **green** = cross-sheet links; **red** = external links
- Currency format: `$#,##0;($#,##0);-` (zeros as `-`, negatives in parentheses)
- Year headers: text strings, not numbers
- ALL assumption cells referenced by formula, never embedded as literals
- Delivery gate: zero `#REF!` / `#DIV/0!` / `#VALUE!` / `#N/A` / `#NAME?` errors

---

## Anti-patterns

### NEVER compute values in Python and hardcode them into cells

**WHY**: The spreadsheet becomes static. When source data changes, the user must
re-run the script to update it — the model is no longer live. A formula like `=SUM(B2:B9)`
recalculates automatically; a hardcoded `5000` does not.

```python
# WRONG — computed in Python, written as a constant
total = df['Sales'].sum()
sheet['B10'] = total          # dies when data changes

# CORRECT — let Excel own the calculation
sheet['B10'] = '=SUM(B2:B9)'
```

This applies to ALL calculations: totals, percentages, ratios, growth rates, averages.

### NEVER open with `data_only=True` and then save

**WHY**: openpyxl has no formula cache of its own — it relies on the cached values Excel
last wrote. Loading `data_only=True` replaces formula strings with those cached numbers.
Saving after this destroys every formula in the file, permanently, with no warning or
error message. The file looks correct until someone changes an input and nothing updates.

```python
# WRONG
wb = load_workbook('model.xlsx', data_only=True)
wb.save('model.xlsx')   # all formulas gone, file silently corrupted

# CORRECT — two separate loads for two separate purposes
# To READ values: load data_only=True, do not save
wb_values = load_workbook('model.xlsx', data_only=True)
# To EDIT formulas/formatting: load without data_only, save
wb_edit = load_workbook('model.xlsx')
```

### NEVER merge cells in data ranges

**WHY**: Merged cells break `SUM`, `OFFSET`, `INDEX/MATCH`, and any range-based formula
that spans the merge. They also break pandas `read_excel` — the merged cell value appears
only in the top-left cell, and all others read as NaN. Merged cells are acceptable in
print-layout title rows outside data ranges, nowhere else.

### NEVER skip recalc.py after writing formulas

**WHY**: An `.xlsx` file produced by openpyxl contains formula *strings* with no computed
values. Excel and Google Sheets display the formula text (or stale cached zeros) until
the file is opened in a spreadsheet application that re-evaluates it. The user receives
a broken file. Always run recalc.py before delivering any file that contains formulas.

### NEVER use volatile functions (NOW, TODAY, RAND, INDIRECT) in large models without warning the user

**WHY**: Volatile functions recalculate on every keystroke in Excel, making large models
sluggish. In recalc.py they cause the file's recalculated values to differ from any
static snapshot. If the user needs a timestamp or random seed, use a hardcoded value
with a source comment, not a volatile function.

### NEVER use VLOOKUP across large cross-sheet ranges in new models

**WHY**: VLOOKUP is column-order dependent — inserting a column between the lookup key
and the return column silently returns wrong values. Use `INDEX(MATCH())` instead:
column-order agnostic and clearer on audit. VLOOKUP is acceptable when editing an
existing model that already uses it — do not refactor it unprompted.

### NEVER impose color coding or formatting on files with existing conventions

**WHY**: The financial model color standards in this skill are defaults, not mandates.
A file that uses orange for inputs and grey for formulas has an established convention
its users know. Overwriting it with the standard colors is confusing and wastes review
time. Always study existing formatting first.

---

## Formula Verification Checklist

Run this before every delivery that involves formulas:

- [ ] 2-3 sample cell references manually verified against source data
- [ ] Excel column numbers confirmed with `get_column_letter(n)` for columns > Z
- [ ] Row offsets checked: DataFrame row N → Excel row N+1 (header in row 1)
- [ ] NaN / empty-cell denominators guarded against `#DIV/0!`
- [ ] Cross-sheet references use correct syntax: `Sheet1!A1` (not `Sheet1.A1`)
- [ ] recalc.py run and JSON status is `"success"`

---

## Code Style

When generating Python for Excel operations:

- Write minimal code; no unnecessary comments or print statements
- For Excel file content: add cell comments for complex formulas, document data sources
  for hardcoded values (see financial-model-standards.md for citation format)

---

## Output Audit Entry

Emit a JSONL audit entry at session end:

```json
{"event": "manage-microsoft-excel.session_end", "file": "<output_path>",
 "formulas_written": true, "recalc_status": "success", "errors_fixed": 0}
```
