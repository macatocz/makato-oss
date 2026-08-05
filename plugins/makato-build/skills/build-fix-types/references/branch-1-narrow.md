# Branch 1 — Narrow (fix patterns)

MANDATORY: Load this file iff the classification table routed the finding to Branch 1.

## When

Value type is wider than the call site requires. Most common: `T | None` where `T` is
needed (`reportOptionalMemberAccess`, `reportOptionalSubscript`, `reportPossiblyUnbound`,
`reportOperatorIssue`, mypy `union-attr`, `optional`, most `assignment` findings).

## Fix patterns — pick the one that matches the construct

```python
# Before — pyright: reportOptionalMemberAccess
def f(x: str | None) -> int:
    return len(x)               # ✘  x might be None

# assert pattern — caller contract forbids None; signature is shared/generated
def f(x: str | None) -> int:
    assert x is not None        # narrowed to str
    return len(x)

# if-guard pattern — None is a valid runtime case with defined behavior
def f(x: str | None) -> int:
    if x is None:
        return 0
    return len(x)

# isinstance pattern — wider union (not just None)
def g(x: int | str) -> str:
    if isinstance(x, int):
        return str(x)
    return x
```

## Decision: assert vs if-guard vs isinstance

| Situation | Pick |
|-----------|------|
| None is logically impossible here; broader signature is shared | `assert x is not None` |
| None has a defined runtime meaning (early return, default value) | `if x is None: <handle>` |
| Union of two or more concrete types | `isinstance` guard |

**Never use `assert` when the None case is a legitimate input** — it raises `AssertionError`
in production (assertions can be stripped with `-O`). Use an `if`-guard instead.

## Edge: reportPossiblyUnbound

Initialise the variable before any conditional that might skip its assignment:

```python
# Before — unbound on the else path
if condition:
    result = compute()
return result                  # possibly unbound

# After
result: SomeType | None = None
if condition:
    result = compute()
return result
```

Prefer initialising to `None` with an explicit annotation over leaving the variable absent —
this makes the unguarded path's behavior visible rather than hiding it.

## Escalation

If narrowing one use site doesn't help (the value is used in many places and each would need
its own guard), log a `decision` entry with reason `"narrow not safe – widespread use"`.
Fall through in order: Branch 2 if the annotation is missing, Branch 3 if the function is
polymorphic across incompatible types, Branch 4 if structural subtyping is required, Branch 5
if the type is provably correct but not inferrable.
