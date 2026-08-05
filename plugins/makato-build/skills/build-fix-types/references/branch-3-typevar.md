# Branch 3 — TypeVar / Generic (fix patterns)

MANDATORY: Load this file iff the classification table routed the finding to Branch 3.

## When

A function or class is polymorphic — the same code body is used with multiple element types
— but is currently annotated with a concrete type or `Any`. Triggered by
`reportInvalidTypeVarUse`, `reportArgumentType` (polymorphic call sites), `reportGeneralTypeIssues`
(contains "is not assignable" with polymorphic call sites), mypy `type-var`.

## Diagnosis: is the function genuinely polymorphic?

Before introducing a TypeVar, confirm that two or more call sites pass **different but
structurally unrelated types** to the same parameter. If the call sites all pass related
types (share a base class), a concrete annotation or Protocol covers the case — TypeVar
would over-engineer.

| Situation | Evidence | Fix |
|-----------|----------|-----|
| `f([1,2])` and `f(["a","b"])` in the same codebase | Two unrelated element types | TypeVar |
| `f(Dog())` and `f(Cat())` where both extend `Animal` | Common base exists | Annotate with `Animal` (Branch 2) |
| Caller uses duck-typed interface (`obj.read()`) | Structural, not nominal | Protocol (Branch 4) |

## Fix patterns — function

```python
# Before — pyright: reportInvalidTypeVarUse / reportArgumentType (polymorphic)
def first(items: list[int]) -> int:
    return items[0]

# After
from typing import TypeVar
T = TypeVar("T")

def first(items: list[T]) -> T:
    return items[0]
```

## Fix patterns — class

```python
# Before
class Repository:
    def get(self, id: int) -> Any: ...

# After
from typing import Generic, TypeVar
T = TypeVar("T")

class Repository(Generic[T]):
    def get(self, id: int) -> T: ...
```

## TypeVar naming conventions

| Scope | Name | Convention |
|-------|------|-----------|
| Single unconstrained type | `T` | Standard |
| Second unconstrained type | `S` or `U` | Standard |
| Constrained to specific types | `T = TypeVar("T", int, str)` | List types explicitly |
| Covariant (read-only) | `T_co = TypeVar("T_co", covariant=True)` | Used in return-only positions |
| Contravariant (write-only) | `T_contra = TypeVar("T_contra", contravariant=True)` | Used in argument-only positions |

**Variance matters when the TypeVar is on a Generic class**, not a standalone function.
Wrong variance causes the type checker to reject valid subtype relationships. Default
(invariant) is safe for function-level TypeVars.

## Escalation

If the polymorphism is structural rather than type-parameter (call sites use objects that
share a method but not a base class), fall through to Branch 4 (Protocol).
