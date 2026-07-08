---
name: inject-skills
description: >-
  Resolve a list of changed files against skill-bundles.yml and return an
  ordered, deduplicated list of recommended skills to prepend into an agent's
  system prompt before dispatch. S1 stub — always returns an empty list.
version: "0.1.0"
argument-hint: "[--changed-files <file1> <file2> ...] [--target-repo <path>]"
---

# inject-skills

## When to Use

Use before dispatching any sub-agent that should receive context-appropriate
skill recommendations based on the files it will touch. Called by the
PO-agent outer loop and by `build-implement-tdd` / `build-implement-goal`
before they dispatch the `coder` agent.

**Do NOT invoke directly** — this skill is dispatched programmatically by
other skills and agents in the makato-build pipeline. It is not intended
for interactive use.

**This is an S1 stub.** Real resolution logic (glob matching, bundle
deduplication, specificity ordering) is implemented in the S2 story. Until
then the skill always returns an empty list and emits no warnings.

## Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `changed_files` | `List[str]` | yes | Relative or absolute paths to files that will be read or written by the target agent. May be empty (`[]`) — the skill must not error for an empty list. |
| `target_repo` | `str` | yes | Absolute filesystem path to the root of the repository being built. Used to locate `plugins/makato-build/config/skill-bundles.yml`. |

Both fields are validated at entry. If either is missing or `target_repo`
is not a string, return a `warnings` entry describing the problem and an
empty `recommended_skills` list — do NOT raise an exception.

## Output

The skill always returns a JSON-compatible dict with two keys:

```json
{
  "recommended_skills": [],
  "warnings": []
}
```

| Field | Type | Description |
|-------|------|-------------|
| `recommended_skills` | `List[str]` | Ordered, deduplicated skill identifiers to inject. Empty in S1. |
| `warnings` | `List[str]` | Human-readable diagnostic messages. Empty when no issues were detected. |

## Behavior

### S1 stub (current)

1. **Load `skill-bundles.yml`** from
   `<target_repo>/plugins/makato-build/config/skill-bundles.yml` for
   forward-compatibility. If the file is missing or unreadable, append a
   warning to `warnings` but continue — do not raise an error.
2. **Accept any `changed_files` input**, including an empty list. The stub
   performs no glob matching.
3. **Return `{recommended_skills: [], warnings: []}`** unconditionally.
   No bundle resolution, no specificity ordering, no deduplication logic.

### S2 planned behavior (not yet implemented)

- For each changed file, every bundle whose `globs` match is selected.
- Bundles are ordered by decreasing glob specificity (literal-segment
  count). The `default` bundle is always appended last.
- Skill identifiers are deduplicated preserving first occurrence.
- A missing `default` bundle raises `BundleResolutionError` (HALT-006).
- Unmatched files fall back to `default` and emit a warning.

See `plugins/makato-build/config/skill-bundles.yml` for the bundle schema
and resolution contract.

## Error Handling

- **Never raise an exception** for a valid `changed_files` input (any
  non-null list of strings, including empty).
- Missing `skill-bundles.yml`: warn, return empty lists.
- Invalid `target_repo` type: warn, return empty lists.
- Unknown/extra keys in input: ignore silently.
