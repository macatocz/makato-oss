---
name: inject-skills
description: >-
  Resolve a list of changed files against the merged skill-bundles.yml registry
  and return an ordered, deduplicated list of recommended skills to prepend into
  an agent's system prompt before dispatch. Implements glob-specificity ordering
  (D9), OR-substring content hints (D19), task-text routing via task_contains
  (F5), cross-plugin bundle aggregation, a target-repo subset filter (D10), and
  graceful missing-skill skip (D18).
version: "1.1.0"
argument-hint: "[--changed-files <file1> <file2> ...] [--target-repo <path>] [--task-text <text>]"
---

# inject-skills

## When to Use

Use before dispatching any sub-agent that should receive context-appropriate
skill recommendations based on the files it will touch, the task description,
or both. Called by `knowledge-scout` at Step 0 (alongside `inject-context`)
and, in future stories, by the PO-agent outer loop and
`build-implement-tdd` / `build-implement-goal` before they dispatch the `coder`
agent.

**Do NOT invoke directly** — this skill is dispatched programmatically by other
skills and agents in the makato-build pipeline. It is not intended for
interactive use.

## Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `changed_files` | `List[str]` | yes | Repo-relative paths to files the target agent will read or write. May be empty (`[]`) — the skill must not error for an empty list. |
| `target_repo` | `str` | yes | Absolute filesystem path to the makato checkout being built. Used to aggregate every `plugins/*/config/skill-bundles.yml` and to discover the installed skill set. |
| `task_text` | `str` | no | Optional task description / issue body for F5 task-text routing. When provided, bundles that declare `task_contains` are also matched against this text (see § *Task-text routing (F5)*). When absent or empty, behaviour is identical to the pre-F5 file-only mode. |

Both required fields are validated at entry. If either is missing or
`target_repo` is not a string, return a `warnings` entry describing the problem
and an empty `recommended_skills` list — do NOT raise an exception.

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
authoritative source for matching semantics. The full-path entry point is
`resolve_skills_for_repo(changed_files, target_repo, *, task_text=None)`; the
pure core is
`resolve_skills(changed_files, config, *, file_texts, installed_skills, task_text=None)`.

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
3. **Task-text routing (F5).** Independently of file matching, a bundle that
   declares a non-empty `task_contains` list is also selected when **at least
   one** substring in that list appears in `task_text` (OR-semantics, case-
   sensitive substring match — the same rule as `contains`). A task-only
   selection contributes specificity score **0** and does NOT add any file to
   the `no-match-fallback` warning (that warning is file-scoped). When
   `task_text` is absent or empty, this path is inactive and all `task_contains`
   predicates are ignored — resolution is byte-for-byte identical to the pre-F5
   behaviour.
4. **Order by specificity (D9).** Bundles are applied in decreasing order of
   glob specificity — the count of literal path segments (segments with no `*`
   or `?`) in the matching glob. A bundle's rank is the MAX score it achieved on
   any file (or 0 for a task-only match). Ties break by declaration order, then
   by config-file path. The `default` bundle is always appended last.
5. **Deduplicate.** Skill identifiers are deduplicated preserving the FIRST
   occurrence.
6. **Filter to installed skills (D10).** `discover_installed_skills(target_repo)`
   enumerates `plugins/*/skills/*/` directory names. Resolved skills not in that
   set are dropped from `recommended_skills` and reported via a `missing-skills`
   warning (D18) — never an exception. This lets a bundle reference a skill that
   a given repo has not installed without breaking resolution.
7. **Warn on no-match fallback.** If a changed file matches no non-`default`
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
  recommends skills **must** declare either a `contains:` predicate (file
  content filter) or a `task_contains:` predicate (task-text filter). The
  pre-commit gate `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh`
  rejects a wide-glob bundle that carries neither. A narrow glob (≥ 1 literal
  segment) is exempt.
- `task_contains:` is the F5 task-text routing key (a D19-sibling). It is a
  list of substrings matched against the caller-supplied `task_text` parameter
  (issue body + `plan.md`). A bundle that declares `task_contains` is selected
  when at least one substring is found in `task_text`, regardless of which
  files are in the diff — enabling routing for green-field tasks where the
  relevant library files do not yet exist. When no `task_text` is supplied,
  `task_contains` predicates are inactive.
- `skills` entries must be installed skill directory names; a name that is not
  installed in the target repo is silently skipped at runtime (D18), so the
  pre-commit validator is the strict authoring-time gate.

## Phase 1 exit gate (S3 / #145 — passed)

All installed plugins now publish `config/skill-bundles.yml`. The aggregate integration
test (`tests/integration/skill-bundles-aggregate.sh`) runs green across the merged
registry. This marks the exit condition for Phase 1 of the skill-injection epic and
**unblocks S4 (#146 — decompose upgrade)**.

Plugins that ship bundles as of this gate:

| Plugin | Config path |
|--------|-------------|
| `makato-build` | `plugins/makato-build/config/skill-bundles.yml` (owns `default`) |
| `makato-langgraph` | `plugins/makato-langgraph/config/skill-bundles.yml` |
| `makato-change` | `plugins/makato-change/config/skill-bundles.yml` |
| `makato-contribute` | `plugins/makato-contribute/config/skill-bundles.yml` |
| `makato-core` | `plugins/makato-core/config/skill-bundles.yml` |
| `makato-database` | `plugins/makato-database/config/skill-bundles.yml` |
| `makato-observability` | `plugins/makato-observability/config/skill-bundles.yml` |
| `makato-orchestrate` | `plugins/makato-orchestrate/config/skill-bundles.yml` |
| `makato-plan` | `plugins/makato-plan/config/skill-bundles.yml` |
| `makato-sagibeast` | `plugins/makato-sagibeast/config/skill-bundles.yml` |
| `makato-ux` | `plugins/makato-ux/config/skill-bundles.yml` |

The pre-commit gate (`plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh`)
enforces the wide-glob-without-precision-filter rule across all future bundle authoring.

## See also

- `plugins/makato-build/shared/inject_skills.py` — reference implementation.
- `plugins/makato-build/skills/inject-context/SKILL.md` — the context-bundle
  sibling that shares the glob-specificity ordering contract.
- `plugins/makato-build/agents/knowledge-scout.md` — Step 0 caller; Step 0e
  documents the `task_text` opt-in for task-text routing.
- `plugins/makato-langgraph/config/skill-bundles.yml` — canonical bundle example
  with `task_contains` seed data.
- `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh` — authoring gate.
- `tests/integration/skill-bundles-aggregate.sh` — cross-plugin aggregate test.
