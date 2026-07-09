---
name: inject-skills
description: >-
  Resolve a list of changed files against the merged skill-bundles.yml registry
  and return an ordered, deduplicated list of recommended skills to prepend into
  an agent's system prompt before dispatch. Implements glob-specificity ordering
  (D9), OR-substring content hints (D19), cross-plugin bundle aggregation, a
  target-repo subset filter (D10), and graceful missing-skill skip (D18).
version: "1.0.0"
argument-hint: "[--changed-files <file1> <file2> ...] [--target-repo <path>]"
---

# inject-skills

## When to Use

Use before dispatching any sub-agent that should receive context-appropriate
skill recommendations based on the files it will touch. Called by
`knowledge-scout` at Step 0 (alongside `inject-context`) and, in future stories,
by the PO-agent outer loop and `build-implement-tdd` / `build-implement-goal`
before they dispatch the `coder` agent.

**Do NOT invoke directly** — this skill is dispatched programmatically by other
skills and agents in the makato-build pipeline. It is not intended for
interactive use.

## Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `changed_files` | `List[str]` | yes | Repo-relative paths to files the target agent will read or write. May be empty (`[]`) — the skill must not error for an empty list. |
| `target_repo` | `str` | yes | Absolute filesystem path to the makato checkout being built. Used to aggregate every `plugins/*/config/skill-bundles.yml` and to discover the installed skill set. |

Both fields are validated at entry. If either is missing or `target_repo` is
not a string, return a `warnings` entry describing the problem and an empty
`recommended_skills` list — do NOT raise an exception.

## Output

```json
{
  "recommended_skills": ["langgraph-fundamentals", "langgraph-persistence"],
  "warnings": []
}
```

| Field | Type | Description |
|-------|------|-------------|
| `recommended_skills` | `List[str]` | Ordered, deduplicated skill identifiers to inject. Empty when nothing matches. |
| `warnings` | `List[dict]` | Structured diagnostics. Each has a `code`: `no-match-fallback` (`{unmatched_files: [...]}`) or `missing-skills` (`{skills: [...]}`). Empty when no issues. |

## Behavior

The reference implementation lives at
`plugins/makato-build/shared/inject_skills.py`. It — and this document — are the
authoritative source for matching semantics. Call
`resolve_skills_for_repo(changed_files, target_repo)`; the pure core is
`resolve_skills(changed_files, config, *, file_texts, installed_skills)`.

1. **Aggregate the registry (cross-plugin).** `aggregate_bundles(target_repo)`
   merges every `plugins/*/config/skill-bundles.yml` in sorted-path order into
   one config. Each plugin contributes its non-`default` bundles; exactly one
   `default` bundle is retained (the first encountered) so the merged registry
   always has a single unambiguous fallback. If no plugin ships a `default`
   bundle, `BundleResolutionError` (HALT-006) is raised.
2. **Match each changed file.** A bundle matches a file when any of its `globs`
   matches **and** its content-hint predicate is satisfied (D19): a bundle with
   a `contains` list matches only if at least one substring appears in the
   file's text (OR-semantics); a bundle with no `contains` is glob-only. A file
   that is not on disk or unreadable cannot satisfy a `contains` predicate.
3. **Order by specificity (D9).** Bundles are applied in decreasing order of
   glob specificity — the count of literal path segments (segments with no `*`
   or `?`) in the matching glob. A bundle's rank is the MAX score it achieved on
   any file. Ties break by declaration order, then by config-file path. The
   `default` bundle is always appended last.
4. **Deduplicate.** Skill identifiers are deduplicated preserving the FIRST
   occurrence.
5. **Filter to installed skills (D10).** `discover_installed_skills(target_repo)`
   enumerates `plugins/*/skills/*/` directory names. Resolved skills not in that
   set are dropped from `recommended_skills` and reported via a `missing-skills`
   warning (D18) — never an exception. This lets a bundle reference a skill that
   a given repo has not installed without breaking resolution.
6. **Warn on no-match fallback.** If a changed file matches no non-`default`
   bundle and `default`'s own globs don't cover it either, the file is recorded
   in a `no-match-fallback` warning. With the canonical `default.globs == ["**/*"]`
   this warning is latent/defensive. An empty `changed_files` list is a valid
   no-scope case and emits no warning.

## Error Handling

- **Never raise an exception** for a valid `changed_files` input (any non-null
  list of strings, including empty).
- Missing/uninstalled skill named by a bundle: skip it, emit a `missing-skills`
  warning (D18) — do NOT raise.
- Merged config missing the `default` bundle, a bundle missing its `name`, or a
  duplicate bundle name: raise `BundleResolutionError` with `halt_code="HALT-006"`.
  The caller (knowledge-scout) translates this into a build.jsonl / HALT entry.
- Invalid `target_repo` type: warn, return empty lists.
- Unknown/extra keys in input or in a bundle: ignore silently.

## Authoring skill bundles

See `plugins/makato-langgraph/config/skill-bundles.yml` for the canonical
example (the first F1 bundle). Key rules for authors:

- Give each bundle a **globally-unique** `name` — names are merged across every
  plugin, so a collision raises HALT-006. Prefer a descriptive,
  plugin-relevant name.
- A **wide glob** (zero literal segments, e.g. `**/*` or `**/*.py`) that
  recommends skills **must** declare a `contains:` predicate. The pre-commit
  gate `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh` rejects a
  wide-glob-without-contains bundle before commit. Narrow the glob or add a
  content filter.
- `skills` entries must be installed skill directory names; a name that is not
  installed in the target repo is silently skipped at runtime (D18), so the
  pre-commit validator is the strict authoring-time gate.

## See also

- `plugins/makato-build/shared/inject_skills.py` — reference implementation.
- `plugins/makato-build/skills/inject-context/SKILL.md` — the context-bundle
  sibling that shares the glob-specificity ordering contract.
- `plugins/makato-build/agents/knowledge-scout.md` — Step 0 caller.
- `plugins/makato-langgraph/config/skill-bundles.yml` — canonical bundle example.
- `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh` — authoring gate.
