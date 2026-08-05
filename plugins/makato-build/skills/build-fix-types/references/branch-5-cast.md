# Branch 5 — cast (fix patterns)

MANDATORY: Load this file iff the classification table routed the finding to Branch 5.

## When

The type is provably correct from context but the checker cannot infer it — dynamic attribute
lookup, runtime-typed JSON, dataclass introspection, `@property` with complex return chains.
Triggered by `reportGeneralTypeIssues` (contains "cannot infer"), mypy `assignment` (contains
"cannot infer"). Used when branches 1–4 don't fit because nothing in the **types** is
wrong — only the inference.

## Fix pattern

```python
# Before — pyright: reportGeneralTypeIssues (cannot infer)
config = load_json("config.json")
host = config["host"]              # type: Any | object

# After — cast with mandatory justification comment
from typing import cast
host = cast(str, config["host"])   # validated by ConfigSchema.validate() in main.py
```

## Required justification comment

Every `cast(...)` MUST include an end-of-line comment on the same line that answers:
- **what** the runtime guarantee is, AND
- **where** that guarantee is enforced (the call site or schema validator).

```python
# Pattern: cast(TargetType, expr)  # <source of truth that guarantees TargetType>
conn = cast(Connection, pool.acquire())   # pool.acquire() always returns Connection per asyncpg docs
row_id = cast(int, result["id"])          # DB schema enforces NOT NULL INTEGER; validated by migration
```

## The cast trap — verify before casting

`cast` is a lie to the type checker — it suppresses the error without fixing anything.
The two questions to answer before every cast:

1. **Is there a runtime guarantee?** A schema validator, a DB constraint, an assertion in
   the caller — something that prevents the value from being the wrong type at runtime.
2. **Is that guarantee under your control?** If it lives in an external library's internal
   implementation, it can change. A cast on a fragile invariant is worse than a `# type: ignore`.

If you cannot answer both questions confidently, do not cast — fall through to Branch 6.

## Common provable-invariant patterns

| Pattern | Provable invariant | Cast justified? |
|---------|--------------------|-----------------|
| Pydantic/dataclass field access after `model.model_validate(data)` | Schema enforces the type | Yes |
| `json.loads()` result from a known, validated schema | Upstream schema validates structure | Yes |
| Dynamic `getattr(obj, name)` where `name` is from a literal enum | Enum constrains the attribute name | Yes |
| Third-party library return typed as `Any` in stubs | Library docs guarantee type | Borderline — also consider Branch 6 |
| User-supplied dictionary key access | No guarantee at call time | No — cast is wrong here |

## Escalation

If there is no runtime guarantee to cite, do not use `cast` — fall through to Branch 6
and document the reason as "no provable invariant".
