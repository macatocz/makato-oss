# build-fix-types test fixtures

This directory holds a minimal Python file that intentionally violates several
pyright / mypy rules so the `build-fix-types` skill can be exercised end-to-end
in `sensor-fixer`'s loop.

A full smoke-test harness for sensor-fixer is tracked separately in
[issue #58](https://github.com/macatocz/makato/issues/58). Until that lands,
this directory provides a **manual verification recipe** that confirms the
route map points type findings at `build-fix-types` (not `build-simplify`).

## Files

| File | Purpose |
|------|---------|
| `type-error-sample.py` | Four functions, each violating one rule that maps to a different branch in `SKILL.md` |
| `README.md` | This file — recipe to reproduce and verify the route |

## Expected branch coverage

| Function | Rule | Branch |
|----------|------|--------|
| `narrow_target` | `pyright:reportOptionalMemberAccess` | 1 (Narrow) |
| `annotate_target` | `pyright:reportMissingParameterType` | 2 (Annotate) |
| `typevar_target` (call site `_b`) | `pyright:reportArgumentType` | 3 (TypeVar) |
| `missing_stub_target` | `pyright:reportUnknownMemberType` | 6 (type: ignore) |

**Note — Branch 3:** The `typevar_target` call site `_b = typevar_target(["a", "b"])` emits
`reportArgumentType` (not `reportGeneralTypeIssues`). The correct sensor-fixer resolution
is to introduce `TypeVar` so the function is genuinely polymorphic.
`reportArgumentType` is explicitly routed to `makato-build:build-fix-types` in
`finding-routes.json` (added in review pass 1).

Branches 4 (Protocol) and 5 (cast) have no fixture functions — their real-world triggers
require either an override mismatch with a concrete base class or a specific inference
failure context that is impractical to produce in a stand-alone fixture without a full
type stub setup. They are documented in `SKILL.md` Section 4 instead.

## Manual route verification

From the repo root, confirm the route map reaches `build-fix-types` for every
expected pyright rule:

```bash
jq -r '
  .routes
  | to_entries[]
  | select(.value.skill == "makato-build:build-fix-types")
  | .key
' plugins/makato-build/shared/finding-routes.json
```

Expected output (at least these keys; exact list grows as more pyright codes are added to
`finding-routes.json`):

```
mypy:*
pyright:reportArgumentType
pyright:reportGeneralTypeIssues
pyright:reportIncompatibleMethodOverride
pyright:reportIndexIssue
pyright:reportInvalidTypeVarUse
pyright:reportMissingParameterType
pyright:reportMissingReturnType
pyright:reportOperatorIssue
pyright:reportOptionalMemberAccess
pyright:reportOptionalSubscript
pyright:reportPossiblyUnbound
pyright:reportReturnType
pyright:reportUnknownMemberType
```

## Confirm langgraph routes are untouched

The pre-existing specialized routes must not be swallowed by the new generic
type-error route:

```bash
jq -r '.routes["pyright:langgraph-reducer-mismatch"].skill,
       .routes["pyright:asyncpg-*"].skill' \
  "$MAKATO_BUILD_ROOT/shared/finding-routes.json"
```

Expected:

```
makato-langgraph:langgraph-reflexion
makato-langgraph:langgraph-fundamentals
```

## End-to-end (when sensor-fixer smoke harness lands — #58)

1. Place the fixture inside a temporary git branch.
2. Stage the fixture; let pyright (configured in `pyproject.toml` of the
   target repo) emit a SARIF report.
3. `parse-sarif.py` normalises findings; `sensor-fixer` dispatches each one.
4. For each fixture function above, `build-resolve-finding` follows Branch 2
   (tech-skill route), loads `build-fix-types`, and applies the per-branch
   fix.
5. Assert: post-run, pyright reports zero findings against the fixture file,
   and `specs/<key>/build.jsonl` contains one `step:"classify"` entry per
   fixture function, each naming the expected branch.

This step is **not** part of this PR — it lands together with issue #58's
smoke harness.
