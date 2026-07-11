---
name: build-fix-types
description: >-
  Per-finding decision tree that resolves Python type errors reported by pyright or
  mypy via 6 ranked branches — narrow, annotate, TypeVar/Generic, Protocol, cast,
  type:ignore-with-justification. Dispatched by build-resolve-finding for any
  `pyright:*` or `mypy:*` finding routed here in `shared/finding-routes.json`.
  Never invoked directly by the user.
version: "1.0.0"
tools: All tools
---

# build-fix-types

## 1. Overview

This skill is the **type-error repair engine** invoked by `build-resolve-finding` whenever
a pyright or mypy finding is routed here through `plugins/makato-build/shared/finding-routes.json`.
It receives a single normalized finding, classifies it into one of six fix branches,
applies the corresponding code edit in place, and returns a structured outcome to the
caller.

The six branches, ordered from least invasive to most invasive:

1. **Narrow** — the value is wider than the call site needs (e.g. `str | None` where
   `str` is required). Add a guard (`assert`, `isinstance`, `is not None`) so the type
   checker can narrow the union.
2. **Annotate** — the function has missing return / parameter annotations and the type
   can be inferred from usage. Add the explicit annotation.
3. **TypeVar / Generic** — a function or class is polymorphic in practice (same code
   used with different element types). Introduce `TypeVar` or `Generic[T]`.
4. **Protocol** — the call site needs structural subtyping (duck typing). Define a
   `Protocol` capturing the required surface.
5. **cast** — the value is provably correct but the checker cannot infer it. Wrap in
   `cast(TargetType, value)` with an inline justification comment.
6. **type: ignore** — the type system cannot model the situation (missing stubs in an
   external library, fundamentally untyped third-party code). Add
   `# type: ignore[error-code]  # reason: ...`. **Only reachable when none of branches
   1–5 patterns match.** Logged as `warn` for later review.

**Knowledge of *which* branch fits *which* error lives here in the classification table
(Section 3) — never in `build-resolve-finding`.** The orchestrator only dispatches; this
skill decides and acts.

## 2. Inputs

The caller passes a single finding object (same shape used everywhere else in the
sensor-fixer pipeline — the canonical Finding contract is [`shared/finding-schema.md`](../../shared/finding-schema.md)):

```json
{
  "tool": "pyright | mypy",
  "rule": "<rule id, e.g. reportOptionalMemberAccess, union-attr>",
  "path": "<repo-relative file path>",
  "line": 123,
  "message": "<verbatim sensor message>",
  "severity": "low | medium | high | critical",
  "autofix_available": false,
  "repo_root": "/abs/path/to/repo",
  "attempt": 1,
  "model_override": null
}
```

`autofix_available` is always `false` for findings reaching this skill — type checkers
do not provide automated fixes. `attempt` increments on retry by the caller.

## 3. Classification (Step 1)

Match the finding's `(tool, rule, message keywords)` against the dispatch table below.
The first row that matches wins. If no row matches, **do not fall through to Branch 6** —
return `status: "error"` with `fix_applied: false` so the caller (build-resolve-finding)
escalates to carry-over. An unrecognized type error code should be reviewed by a human,
not silently suppressed. Log a `decision` entry naming the unmatched `(tool, rule)` so
the classification table can be extended.

### Pyright codes

| Rule | Message keyword | Branch | Reason |
|------|-----------------|--------|--------|
| `reportOptionalMemberAccess` | — | 1 (Narrow) | Member access on `T | None` |
| `reportOptionalSubscript` | — | 1 (Narrow) | Subscript on `T | None` |
| `reportPossiblyUnbound` | — | 1 (Narrow) | Variable may be unbound on some path |
| `reportMissingReturnType` | — | 2 (Annotate) | Return type omitted |
| `reportMissingParameterType` | — | 2 (Annotate) | Parameter type omitted |
| `reportInvalidTypeVarUse` | — | 3 (TypeVar) | Existing TypeVar misused |
| `reportArgumentType` | — | 3 (TypeVar) | Argument type mismatch — function called with incompatible type; often needs TypeVar to be genuinely polymorphic. If the function is not polymorphic, use Branch 1 (Narrow) or Branch 2 (Annotate). |
| `reportReturnType` | — | 2 (Annotate) | Return type annotation present but wrong — tighten or correct annotation |
| `reportOperatorIssue` | — | 1 (Narrow) | Operator unsupported for union type — narrow first; Branch 4 (Protocol) if structural |
| `reportIndexIssue` | — | 1 (Narrow) | Subscript/index type error — narrow index or container |
| `reportIncompatibleMethodOverride` | — | 4 (Protocol) | Override signature mismatch — structural subtype |
| `reportGeneralTypeIssues` | contains `\| None` | 1 (Narrow) | Generic error with None in union |
| `reportGeneralTypeIssues` | contains `cannot infer` | 5 (cast) | Inference failure, type provable |
| `reportGeneralTypeIssues` | contains `is not assignable`, with polymorphic call sites | 3 (TypeVar) | Same fn used with multiple element types |
| `reportGeneralTypeIssues` | (no keyword above) | 5 (cast) | Default for generic issues — try cast first |
| `reportUnknownMemberType` | — | 6 (ignore) | Member type from missing/wrong stubs |

### Mypy codes

| Rule | Message keyword | Branch | Reason |
|------|-----------------|--------|--------|
| `union-attr` | — | 1 (Narrow) | Attribute access on union including None |
| `optional` | — | 1 (Narrow) | Implicit Optional handling |
| `no-untyped-def` | — | 2 (Annotate) | Function definition missing annotations |
| `return-value` | annotation absent | 2 (Annotate) | No return type declared — add annotation |
| `return-value` | annotation exists but wrong | 1 (Narrow) | Return type incompatible — narrow the return expression or fix annotation to match |
| `no-any-return` | — | 2 (Annotate) | Function returns Any but annotated otherwise |
| `type-var` | — | 3 (TypeVar) | TypeVar binding error |
| `override` | — | 4 (Protocol) | Method override signature mismatch |
| `assignment` | contains `cannot infer` | 5 (cast) | Inference failure |
| `assignment` | (no keyword above) | 1 (Narrow) | Most assignment errors are narrowing |
| `misc` | (structural keyword: `incompatible`, `mismatch`) | 4 (Protocol) | Structural subtype required |
| `import-untyped` | — | 6 (ignore) | Library has no type stubs |
| `import-not-found` | — | 6 (ignore) | Library missing entirely from stub paths |
| `attr-defined` | — | 6 (ignore) | Attribute missing from library stub |

### No match

If no row matches, return `status: "error"` with `fix_applied: false` and log a
`decision` entry naming the unmatched `(tool, rule)`. The caller (`build-resolve-finding`)
escalates this to carry-over so a human reviews it. **Do not apply Branch 6** for
unrecognized codes — silently suppressing an unknown type error is worse than leaving
the finding unresolved. The `mypy:*` glob in `finding-routes.json` routes all mypy
findings here; this skill covers common mypy codes but not the full space. Carry-over
is the correct outcome for any code not in the table above.

## 4. Decision Branches

### Branch 1 — Narrow

**Trigger:** value type is a union including `None` (or another superset) at a call site
that requires the narrower type. Most common in practice.

**Fix patterns** (pick the one that matches the construct):

```python
# Before — pyright: reportOptionalMemberAccess
def f(x: str | None) -> int:
    return len(x)               # ✘  x might be None

# After (assert pattern)
def f(x: str | None) -> int:
    assert x is not None        # narrowed to str
    return len(x)

# After (guard pattern — preferred when None is a real runtime case)
def f(x: str | None) -> int:
    if x is None:
        return 0
    return len(x)

# After (isinstance pattern — when narrowing a wider union)
def g(x: int | str) -> str:
    if isinstance(x, int):
        return str(x)
    return x
```

**Pick `if`-guard over `assert`** when the `None` case has a meaningful runtime
behavior; `assert` is for cases where the caller contract forbids `None` but the
signature is shared.

**Escalation:** if no narrowing construct is safe (e.g. the value is used in many
places, narrowing in one place doesn't help), log `decision` with reason
`"narrow not safe"` and fall through through the remaining branches in order:
Branch 2 (if the type annotation is missing), Branch 3 (if the function is polymorphic
across multiple call-site types), Branch 4 (if structural subtyping is required), Branch 5
(if the type is provably correct but uninferrable), Branch 6 (last resort).

### Branch 2 — Annotate

**Trigger:** missing return type, missing parameter type, or annotated return type that
mismatches what the function actually returns and can be tightened.

**Fix patterns:**

```python
# Before — pyright: reportMissingReturnType
def total(items):
    return sum(item.price for item in items)

# After
def total(items: list[Item]) -> Decimal:
    return sum(item.price for item in items)
```

Infer types from:
1. Usage of the function inside the file (call sites, return chain).
2. Doc-comments mentioning types.
3. Test files referencing the function.
4. Reasonable defaults: `list[Any]` only as a last resort — escalate to Branch 3 if a
   real generic shape is visible.

**Escalation:** if usage shows the same function called with two incompatible types
(e.g. `total([Item(...)])` and `total([LineItem(...)])` where the two are unrelated),
fall through to Branch 3 (TypeVar).

### Branch 3 — TypeVar / Generic

**Trigger:** the function or class is polymorphic — same code body used with multiple
element types — but is currently annotated with a concrete type or `Any`.

**Fix patterns:**

```python
# Before — pyright: reportInvalidTypeVarUse / reportGeneralTypeIssues polymorphic
def first(items: list[Item]) -> Item:
    return items[0]

# After
from typing import TypeVar
T = TypeVar("T")

def first(items: list[T]) -> T:
    return items[0]
```

For classes, use `Generic[T]`:

```python
from typing import Generic, TypeVar
T = TypeVar("T")

class Repository(Generic[T]):
    def get(self, id: int) -> T: ...
```

**Escalation:** if the polymorphism is structural rather than type-parameter
(call sites use objects that share a method but not a base class), fall through to
Branch 4 (Protocol).

### Branch 4 — Protocol

**Trigger:** call site expects a structural type — "anything with `.read()` and
`.close()`" — rather than a concrete base class. Common with override mismatches
and duck-typed interfaces.

**Fix patterns:**

```python
# Before — pyright: reportIncompatibleMethodOverride
def write(target: TextIO, data: str) -> None:
    target.write(data)

# Caller has a custom Buffer class with .write(str) but no TextIO base.

# After
from typing import Protocol

class Writable(Protocol):
    def write(self, data: str, /) -> int | None: ...

def write(target: Writable, data: str) -> None:
    target.write(data)
```

**Escalation:** if the receiver is from an external library with no stubs, first try
Branch 5 (cast) — if you can document a provable runtime invariant for the receiver type,
use `cast(ProtocolType, receiver)` rather than suppressing the error. Only fall through
to Branch 6 if no runtime guarantee can be cited (e.g. the stub is genuinely absent and
the receiver type is verified solely by the library's documentation, not by code under
your control).

### Branch 5 — cast

**Trigger:** the type is provably correct from context, but the checker cannot infer it
(e.g. dynamic attribute lookup, runtime-typed JSON, dataclass introspection). Used when
branches 1–4 don't fit because nothing in the **types** is wrong — only the inference.

**Fix patterns:**

```python
# Before — pyright: reportGeneralTypeIssues (cannot infer)
config = load_json("config.json")
host = config["host"]              # type is Any | object

# After
from typing import cast
config = load_json("config.json")
host = cast(str, config["host"])   # JSON schema guarantees str, validated upstream
```

**Hard rule:** every `cast(...)` MUST be followed (same line, end-of-line comment) by
a one-line justification — what the runtime guarantee is and where it's enforced.

```python
host = cast(str, config["host"])  # validated by ConfigSchema in main.py
```

**Escalation:** if there is no runtime guarantee to cite, do not use `cast` — fall
through to Branch 6 (and document the reason as "no provable invariant").

### Branch 6 — type: ignore (last resort)

**Trigger:** the type system fundamentally cannot represent the situation. Most common
cause: external library with no stubs, or wrong/outdated stubs.

**Hard rules (D4 + D7):**

- **Only reachable when no rule in the classification table (Section 3) matches branches
  1–5.** If you reach Branch 6 via fallthrough from another branch, that fallthrough
  must be logged as a `decision` entry first.
- **Bare `# type: ignore` is disallowed.** Every suppression MUST narrow the ignored
  error code: `# type: ignore[<error-code>]`.
- **Reason comment is required.** Format: `# type: ignore[code]  # reason: <one-line>`.
- **Log `status: "warn"` to `build.jsonl`** with the finding, the reason, and the
  fallthrough chain. Future review sessions can list all suppressions and re-evaluate.

**Fix pattern:**

```python
# Before — pyright: reportUnknownMemberType (numpy partial stubs)
result = np.somefunc(arr).private_attr

# After
result = np.somefunc(arr).private_attr  # type: ignore[attr-defined]  # reason: numpy stubs missing private_attr; runtime-validated by test_numpy_compat.py
```

## 5. Hard Rules (apply to every branch)

1. **Read disk state before editing.** The sensor-fixer loop may have already modified
   the file via a previous finding in the same run. Always re-read the file before
   applying the fix to avoid stomping on an earlier patch.
2. **One finding, one edit.** Never bundle fixes for adjacent findings. The caller
   re-runs the type checker after each fix; multi-finding edits make the loop
   non-deterministic.
3. **Preserve existing tests.** Type fixes must not change runtime semantics. If a guard
   added in Branch 1 would change behavior (e.g. `if x is None: return 0` where the
   original raised `TypeError`), escalate as a structural finding and request `/refine`.
4. **No bare `# type: ignore`.** Always `# type: ignore[<code>]` with a reason comment.
5. **Branch 6 logs `warn`.** Every suppression appends a `warn` entry to `build.jsonl`.

## 6. Output Contract

Return a single JSON object to the caller:

```json
{
  "status": "ok | warn | error",
  "branch": 1,
  "file": "src/example.py",
  "line": 42,
  "fix_applied": true,
  "fix_description": "Added `assert x is not None` to narrow Optional[str]"
}
```

Field semantics:
- `status: "ok"` — fix applied via branches 1–5; expected to pass re-verification.
- `status: "warn"` — fix applied via branch 6 (type: ignore). The caller should still
  re-verify but flag this finding for human review.
- `status: "error"` — could not apply any fix safely; finding escalates to carry-over
  in `build-resolve-finding`.
- `branch` — integer 1–6 indicating which branch was used.
- `fix_applied` — `true` if the file was edited, `false` if the skill bailed out
  (status will be `"error"` in that case).
- `fix_description` — one-line human-readable description of the edit.

## 7. Logging

Append JSONL entries to `specs/<story-key>/build.jsonl` via `shared/build-log.sh`.
Required entries:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"session","status":"start","data":{"tool":"pyright","rule":"reportOptionalMemberAccess","path":"src/example.py","line":42}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"classify","status":"ok","data":{"branch":1,"reason":"reportOptionalMemberAccess → Narrow"}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"apply","status":"ok","data":{"file":"src/example.py","line":42,"fix_description":"Added assert"}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"session","status":"ok","data":{"branch":1,"fix_applied":true}}
```

Branch 6 application MUST also log:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"suppress","status":"warn","data":{"file":"src/example.py","line":42,"error_code":"attr-defined","reason":"numpy stubs missing private_attr"}}
```

Use bare `shared/build-log.sh` (no `../`) — Claude resolves it from the plugin root.

## 8. When to Use

Dispatched by `build-resolve-finding` Branch 2 (tech-skill route) for any finding
matching `pyright:*` or `mypy:*` in `shared/finding-routes.json`. **Not invoked directly
by the user.** If a user types `/build-fix-types`, the skill should respond with:

> "This skill is the per-finding type-error engine dispatched by `build-resolve-finding`.
> It is not invoked directly. To trigger it, run `/build-sensors` against a branch with
> pyright/mypy violations, or pass a finding JSON via `build-resolve-finding`."
