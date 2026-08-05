# Financial Model Standards

Industry-standard conventions for financial model spreadsheets. Apply these whenever
building or editing a financial model unless existing template conventions override.

---

## Color Coding

| Color | RGB | Meaning |
|---|---|---|
| Blue text | (0, 0, 255) | Hardcoded inputs — values a user will change for scenarios |
| Black text | (0, 0, 0) | ALL formulas and calculations |
| Green text | (0, 128, 0) | Links pulling from other worksheets within the same workbook |
| Red text | (255, 0, 0) | External links to other files |
| Yellow background | (255, 255, 0) | Key assumptions needing attention or cells that need updating |

Blue/black/green/red text are a _financial analyst convention_, not a personal preference.
Reviewers and auditors rely on this coding to distinguish input cells from derived cells
without opening the formula bar.

---

## Number Formatting

| Data type | Format string | Notes |
|---|---|---|
| Currency | `$#,##0;($#,##0);-` | Zeros as `-`, negatives in parentheses |
| Percentages | `0.0%` | One decimal; same zero/negative rules |
| Valuation multiples | `0.0x` | EV/EBITDA, P/E, etc. |
| Year headers | Text string | `"2024"` not the number `2024` (avoids `2,024` mis-format) |

**Why parentheses for negatives**: Accounting convention. `-123` is ambiguous in dense
tables; `(123)` is unambiguous and survives column-width truncation without losing the sign.

**Why units in headers**: `Revenue ($mm)` eliminates scale ambiguity. A model reviewed
by someone unfamiliar with the file must never have to guess whether a number is in
dollars, thousands, or millions.

---

## Formula Construction

### Assumptions placement

- ALL growth rates, margins, multiples, discount rates, etc. live in dedicated assumption
  cells, not embedded in formulas.
- Use cell references: `=B5*(1+$B$6)` not `=B5*1.05`.
- Absolute-reference assumption cells (`$B$6`) so they do not drift when rows/columns
  are inserted.

### Documentation for hardcoded values

Format: `Source: [System/Document], [Date], [Specific Reference], [URL if applicable]`

Examples:
- `Source: Company 10-K, FY2024, Page 45, Revenue Note, https://sec.gov/...`
- `Source: Bloomberg Terminal, 2025-08-15, AAPL US Equity`
- `Source: FactSet, 2025-08-20, Consensus Estimates Screen`

Place source citations in cell comments, or in the adjacent cell if the assumption is at
the end of a table row where a comment would be invisible in print layout.

---

## Delivery Gate

Every financial model MUST pass this gate before delivery:

- [ ] Zero formula errors (#REF!, #DIV/0!, #VALUE!, #N/A, #NAME?)
- [ ] Color coding applied: blue inputs, black formulas, green cross-sheet links, red external links
- [ ] Units in all headers that contain currency or scaled values
- [ ] Assumption cells are referenced, not hardcoded in formulas
- [ ] Hardcoded values have source citations
- [ ] Year headers formatted as text strings
