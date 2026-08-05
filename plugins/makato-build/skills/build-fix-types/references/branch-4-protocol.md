# Branch 4 — Protocol (fix patterns)

MANDATORY: Load this file iff the classification table routed the finding to Branch 4.

## When

Call site expects a structural type — "anything with `.read()` and `.close()`" — rather than
a concrete base class. Common with override mismatches and duck-typed interfaces.
Triggered by `reportIncompatibleMethodOverride`, mypy `override`, mypy `misc` with
structural keywords ("incompatible", "mismatch").

## Fix patterns

```python
# Before — pyright: reportIncompatibleMethodOverride
def write(target: TextIO, data: str) -> None:
    target.write(data)

# Caller has a custom Buffer class with .write(str) but no TextIO base.

# After — define a structural Protocol capturing only the surface you need
from typing import Protocol

class Writable(Protocol):
    def write(self, data: str, /) -> int | None: ...

def write(target: Writable, data: str) -> None:
    target.write(data)
```

## Protocol surface sizing

Only include **methods and attributes actually used** in the function body — no more.
An over-specified Protocol is harder for callers to satisfy and defeats the duck-typing
intent. The minimum Protocol that makes the type checker happy is the correct Protocol.

## Where to define the Protocol

| Situation | Placement |
|-----------|-----------|
| Used only in one module | Module-level, same file |
| Used across multiple modules | Separate `protocols.py` or `_types.py` in the package |
| Replaces an existing abstract base class | Consider whether the ABC should be converted |

## Override mismatch (mypy: override)

When the subclass method signature doesn't match the parent, the two sub-cases differ:

| Sub-case | Fix |
|----------|-----|
| Parent is under your control | Widen the parent signature or add an `@overload` |
| Parent is an external class | Introduce a Protocol that captures the sub-interface you need; stop subclassing |

**Never silently change the parent signature** without verifying all other subclasses still
satisfy it — this is a structural change that can break callers in other modules.

## Escalation

If the receiver is from an external library with no stubs, prefer Branch 5 (cast) when you
can document a runtime invariant. Only fall through to Branch 6 if no runtime guarantee
can be cited (e.g., the stub is absent and the receiver type is verified solely by
the library's documentation, not by code under your control).
