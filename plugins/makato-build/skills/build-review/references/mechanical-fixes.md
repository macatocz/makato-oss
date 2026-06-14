# Mechanical Fixes

Mechanical fixes are applied silently in Step 3, before any findings are classified.
They are never reported as findings. They do not trigger a re-review loop.

## What Counts as a Mechanical Fix

Apply these if they are applicable to the project:

**Formatting**
- Indentation inconsistencies (tabs vs. spaces, wrong indent depth) — run the project
  formatter if one is configured (`prettier`, `google-java-format`, `gofmt`, `black`,
  `rustfmt`, etc.)
- Extra blank lines beyond what the style guide allows
- Trailing whitespace on any line

**Imports**
- Unused imports that the compiler or linter flags — remove them
- Import ordering (alphabetical, grouped by stdlib/external/internal) — reorder to match
  the convention already used in the file
- Wildcard imports where specific imports are the convention — expand them if the file
  uses specific imports everywhere else

**Obvious lint suppressions that are no longer needed**
- `@SuppressWarnings`, `// noinspection`, `// eslint-disable` comments that suppress a
  warning no longer present in the changed code — remove them

## What Does NOT Count as a Mechanical Fix

These require a finding (SUGGESTION or CRITICAL depending on severity):

- **Renaming** — even if a name is clearly wrong, renaming is a behavioral change to
  the public interface and may break callers. File a SUGGESTION.
- **Logic changes** — any change to a conditional, loop, or return value is not
  mechanical, even if it looks trivial.
- **Adding or removing tests** — tests encode behavioral contracts. Changes to tests
  are findings, not mechanical fixes.
- **Restructuring method order** — reordering methods or moving code between files
  changes git blame and may conflict with other in-flight work. File a NITPICK if it
  matters.
- **Comment rewording** — if a comment is misleading, file a NITPICK. Do not silently
  rewrite comments; the author's intent may be deliberate.
- **Dependency upgrades** — never a mechanical fix. Always a conscious decision.

## When No Formatter is Configured

If the project has no configured formatter, apply only:
- Trailing whitespace removal
- Unused import removal (only if the import is provably unused — not just probably unused)

Do not manually reformat code when no formatter is configured. Inconsistent formatting
is a NITPICK finding, not a mechanical fix, when there is no authoritative tool to
determine the correct output.
