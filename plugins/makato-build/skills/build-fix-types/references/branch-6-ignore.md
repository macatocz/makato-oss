# Branch 6 — type: ignore (last resort)

MANDATORY: Load this file iff the classification table routed the finding to Branch 6,
OR iff a Branch 1–5 escalation falls through here.

## When

The type system fundamentally cannot represent the situation. Most common cause: external
library with no stubs, or wrong/outdated stubs. Reached via the classification table for
`reportUnknownMemberType`, mypy `import-untyped`, `import-not-found`, `attr-defined`, OR
as the final escalation when branches 1–5 all fail.

**Every Branch 6 application logs `status: "warn"` to `build.jsonl`.**

## Pre-conditions (check before applying)

Before reaching for `# type: ignore`, confirm:

1. You arrived here via a matching classification-table row OR logged a `decision` entry
   documenting the fallthrough chain from a prior branch.
2. No upstream stub package exists (`types-<library>` on PyPI). Check:
   ```bash
   pip index versions types-<library-name> 2>/dev/null | head -1
   ```
3. For `import-untyped` / `import-not-found`: the library genuinely has no stubs.
   If a stub package exists, install it and re-run — Branch 6 is not needed.

## Fix pattern

```python
# Before — pyright: reportUnknownMemberType (numpy partial stubs)
result = np.somefunc(arr).private_attr

# After
result = np.somefunc(arr).private_attr  # type: ignore[attr-defined]  # reason: numpy stubs missing private_attr; runtime-validated by test_numpy_compat.py
```

## Required format (both fields mandatory)

```
# type: ignore[<error-code>]  # reason: <one-line explanation>
```

- `<error-code>` must be the specific pyright/mypy error code — not a wildcard.
- `reason:` must identify why the suppression is valid and what runtime evidence exists.

## Logging requirement (mandatory)

Append to `build.jsonl` via `shared/build-log.sh`:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"suppress","status":"warn","data":{"file":"src/example.py","line":42,"error_code":"attr-defined","reason":"numpy stubs missing private_attr"}}
```

The `warn` status signals to post-merge review sessions that this finding was suppressed, not
fixed, and should be revisited when the upstream library publishes stubs.

## Do NOT use Branch 6 for

- Unrecognized rule codes (return `status: "error"` instead — see "No match" in the
  classification table).
- Any finding where branches 1–5 were not genuinely considered and logged as skipped.
- Any finding where a stub package exists but is not installed.
