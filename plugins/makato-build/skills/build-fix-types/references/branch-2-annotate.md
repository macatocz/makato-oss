# Branch 2 — Annotate (fix patterns)

MANDATORY: Load this file iff the classification table routed the finding to Branch 2.

## When

Missing return type, missing parameter type, or an annotated return type that mismatches
what the function actually returns and can be tightened
(`reportMissingReturnType`, `reportMissingParameterType`, `reportReturnType`,
mypy `no-untyped-def`, `no-any-return`, `return-value` when annotation is absent).

## Fix patterns

```python
# Before — pyright: reportMissingReturnType + reportMissingParameterType
def total(items):
    return sum(item.price for item in items)

# After
def total(items: list[Item]) -> Decimal:
    return sum(item.price for item in items)
```

## Inference priority order

1. **Call sites in the same file** — what types does the caller actually pass?
2. **Doc-comments mentioning types** — Sphinx `:type:`, Google-style `Args:` blocks.
3. **Test files** — how are fixtures constructed for this function?
4. **Return-expression analysis** — what does `-> type(return_expr)` give?
5. **`list[Any]` / `Any`** — last resort only. If you reach this, escalate to Branch 3
   (polymorphic) or flag as a gap and carry-over.

## reportReturnType (annotation present but wrong)

The annotation exists but the return expression's type doesn't match. Two sub-cases:

| Sub-case | Diagnosis | Fix |
|----------|-----------|-----|
| Annotation is too narrow | Annotated `-> str` but sometimes returns `None` | Widen to `-> str \| None` or add an explicit `return` on the missing path |
| Annotation is too wide | Annotated `-> Any` but always returns `str` | Tighten annotation |

Tightening a too-wide annotation is safe. Widening a too-narrow annotation requires verifying
callers won't break on the wider type — if they will, this is a structural issue; escalate.

## Escalation

If call sites show the same function called with **two incompatible types** (e.g.
`total([Item(...)])` and `total([LineItem(...)])` where the two share no common base),
the function is genuinely polymorphic — fall through to Branch 3 (TypeVar).
