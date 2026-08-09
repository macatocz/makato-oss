---
name: inject-skills
description: >-
  Resolve a list of changed file paths against the merged skill-bundles.yml
  registry (aggregated across all installed plugins) and return an ordered,
  deduplicated list of recommended skill identifiers to prepend into an agent's
  system prompt before dispatch. Key mechanisms: glob-specificity ordering
  (most-literal-segment glob wins), OR-substring content hints (file-text
  matching), task-text routing (issue body / plan.md substring matching for
  green-field tasks where target files do not yet exist), cross-plugin bundle
  aggregation, target-repo subset filtering, and graceful missing-skill skip.
  Called by knowledge-scout at Step 0. Never invoke directly — programmatic use
  only. Trigger keywords: skill routing, inject skills, recommend skills,
  knowledge-scout dispatch, skill-bundles.yml.
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

**Do NOT load** when you need rule-file paths for the agent's context window —
that is `inject-context`'s responsibility. `inject-skills` returns skill
_identifiers_ (e.g. `langgraph-fundamentals`), not file paths. Do NOT load when
assembling task context rather than an agent dispatch bundle.

> **Domain-specific recommendations require bundles.** For a consuming plugin's
> skills to appear in recommendations, that plugin must ship at least one bundle
> in its own `config/skill-bundles.yml` (or `shared/skill-bundles.yml`). Without
> a bundle file, `inject-skills` has no mapping and produces no recommendations
> for that plugin's skill identifiers, regardless of what files change. See
> `plugins/makato-build/shared/skill-bundles.yml` for a worked example.

## Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `changed_files` | `List[str]` | yes | Repo-relative paths to files the target agent will read or write. May be empty (`[]`) — the skill must not error for an empty list. |
| `target_repo` | `str` | yes | Absolute filesystem path to the makato checkout being built. Used to aggregate every `plugins/*/config/skill-bundles.yml` and to discover the installed skill set. |
| `task_text` | `str` | no | Optional task description / issue body for task-text routing. When provided, bundles that declare `task_contains` are also matched against this text (OR-semantics). When absent or empty, behaviour is identical to file-only mode. |

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

**Terminology used in the algorithm below:**
- **Glob-specificity**: count of literal path segments (segments with no `*` or
  `?`) in a glob. Higher = more specific = higher rank. `src/graph.py` → 2;
  `**/langgraph/**` → 1; `**/*.py` → 0.
- **Content hint** (`contains`): per-bundle list of substrings matched against
  the file's text (OR-semantics). A bundle without `contains` is glob-only.
- **Task hint** (`task_contains`): per-bundle list of substrings matched against
  `task_text` (OR-semantics). Fires regardless of file matches; contributes
  specificity score 0; never adds files to the `no-match-fallback` warning.

### 7-step resolution algorithm

1. **Aggregate the registry (cross-plugin).** `aggregate_bundles(target_repo)`
   merges every `plugins/*/config/skill-bundles.yml` in sorted-path order into
   one config. Each plugin contributes its non-`default` bundles; exactly one
   `default` bundle is retained (the first encountered) so the merged registry
   always has a single unambiguous fallback. If no plugin ships a `default`
   bundle, `BundleResolutionError` (HALT-006) is raised.
2. **Match each changed file.** A bundle matches a file when any of its `globs`
   matches **and** its content-hint predicate is satisfied: a bundle with
   a `contains` list matches only if at least one substring appears in the
   file's text (OR-semantics); a bundle with no `contains` is glob-only. A file
   that is not on disk or unreadable cannot satisfy a `contains` predicate.
3. **Task-text routing.** Independently of file matching, a bundle that
   declares a non-empty `task_contains` list is also selected when **at least
   one** substring in that list appears in `task_text` (OR-semantics, case-
   sensitive substring match — the same rule as `contains`). A task-only
   selection contributes specificity score **0** and does NOT add any file to
   the `no-match-fallback` warning (that warning is file-scoped). When
   `task_text` is absent or empty, all `task_contains` predicates are ignored —
   resolution is byte-for-byte identical to file-only mode.
4. **Order by specificity.** Bundles are applied in decreasing order of
   glob specificity. A bundle's rank is the MAX score it achieved on
   any file (or 0 for a task-only match). Ties break by declaration order, then
   by config-file path. The `default` bundle is always appended last.
5. **Deduplicate.** Skill identifiers are deduplicated preserving the FIRST
   occurrence.
6. **Filter to installed skills.** `discover_installed_skills(target_repo)`
   enumerates `plugins/*/skills/*/` directory names. Resolved skills not in that
   set are dropped from `recommended_skills` and reported via a `missing-skills`
   warning — never an exception. This lets a bundle reference a skill that
   a given repo has not installed without breaking resolution.
7. **Warn on no-match fallback.** If a changed file matches no non-`default`
   bundle and `default`'s own globs don't cover it either, the file is recorded
   in a `no-match-fallback` warning. With the canonical `default.globs == ["**/*"]`
   this warning is latent/defensive. An empty `changed_files` list is a valid
   no-scope case and emits no warning.

### Edge-case decision tree

**New or not-yet-existing files (green-field task):**
→ File-content hints (`contains`) cannot match (no text to read).
→ Use `task_text` (issue body + plan.md) — bundles declaring `task_contains`
  fire on task description alone. This is the designed path for green-field
  routing: when the relevant library files don't exist yet, the task description
  is the only signal available.

**`task_text` absent and changed files match only the `default` bundle:**
→ `no-match-fallback` warning fires (informational). The agent runs with
  default skills. This is a signal to bundle authors that the file pattern is
  uncovered — not a build failure.

**Same bundle selected by both file match and task hint:**
→ File-match specificity wins for ordering. No double-counting — the bundle
  appears exactly once, ordered by its file-match score.

**`target_repo` unavailable or not a string:**
→ Validation fails at entry → return empty `recommended_skills` + warning.
  Do NOT raise. The caller's HALT handler is the correct escalation path.

**`changed_files` is empty but `task_text` is provided:**
→ Task-hint bundles can still fire; `default` bundle is appended last; no
  `no-match-fallback` warning (empty file set is a valid no-scope case).

## Error Handling

| Condition | Action |
|-----------|--------|
| `changed_files` is an empty list | Valid no-scope case; return `default`-bundle skills + any task-hint matches; no warning. |
| A bundle's skill not installed in `target_repo` | Skip the skill; emit `missing-skills` warning; never raise. |
| `default` bundle absent from merged config | Raise `BundleResolutionError(halt_code="HALT-006")`. Caller (knowledge-scout) translates to build.jsonl HALT entry. |
| Bundle missing `name` field | Raise `BundleResolutionError(halt_code="HALT-006")`. |
| Duplicate `name` across the merged registry | Raise `BundleResolutionError(halt_code="HALT-006")`. |
| `target_repo` missing or not a string | Warn; return empty lists; do NOT raise. |
| Unknown/extra keys in input or bundle | Ignore silently. |

## Anti-patterns

Each item below reflects a failure mode specific to this resolver's architecture.

**NEVER raise for a valid `changed_files` input, including an empty list.**
Why: `knowledge-scout` calls this before dispatching any agent. An exception
propagates as a hard HALT even when `changed_files` is intentionally empty
(task-text-only dispatch or a no-file story). The empty-list case is a
legitimate signal, not an error — treating it as one silently blocks an entire
build session.

**NEVER raise when a bundle references a skill not installed in `target_repo`.**
Why: the merged registry spans all plugins. A bundle in `makato-langgraph` may
name a skill that a project using only `makato-build` + `makato-change` has not
adopted. Raising here would break every caller on a single optional-skill
absence in one unrelated plugin's config — a failure completely invisible to the
affected project's authors.

**NEVER author a wide-glob bundle (zero literal segments, e.g. `**/*`,
`**/*.py`) without a `contains` or `task_contains` predicate.**
Why: such a bundle matches every changed file in every session and injects
domain-specific skills (e.g., LangGraph skills) on completely unrelated diffs.
The pre-commit gate `validate-skill-bundles.sh` enforces this at authoring time;
violating it at runtime contaminates every agent's skill list with irrelevant
recommendations, degrading signal-to-noise for agents that rely on these lists.

**NEVER include task-hint-matched bundles in the `no-match-fallback` warning.**
Why: `task_contains` routing is a file-independent signal. Folding task-matched
bundles into the unmatched-files set would falsely alarm callers that a file
lacks bundle coverage when the bundle intentionally routes on task description
alone, generating spurious warnings on every green-field task.

**NEVER let a duplicate bundle `name` pass silently.**
Why: bundles aggregate across plugins in sorted-path order. A silent duplicate
retains the first declaration and discards the second plugin's skill list — the
second plugin's skills would never be recommended with no error or warning,
creating a permanent blind spot that is nearly impossible to diagnose from
runtime behavior alone.

**NEVER perform filesystem reads inside the pure `resolve_skills()` function.**
Why: the pure core is unit-tested in isolation without filesystem mocks. Mixing
I/O into the pure function breaks the test/production symmetry that keeps the
resolver's contract verifiable. All filesystem work belongs in
`aggregate_bundles`, `discover_installed_skills`, and `resolve_skills_for_repo`.

## Authoring skill bundles

> **Domain-scoped recommendations require a plugin-local bundle.** Domain-specific
> recommendations require at minimum one bundle in a consuming plugin's
> `skill-bundles.yml`. Without a plugin-specific bundle, no domain-scoped skill
> recommendations are generated for that plugin's files — only the `default` bundle
> (owned by `makato-build`) applies, which recommends no skills.

See `plugins/makato-langgraph/config/skill-bundles.yml` for the canonical
example (the first F1 bundle). Key rules for authors:

- Give each bundle a **globally-unique** `name` — names are merged across every
  plugin, so a collision raises HALT-006. Prefer a descriptive, plugin-scoped
  name (e.g., `langgraph-agents-bundle`) to avoid cross-plugin collisions.
- A **wide glob** (zero literal segments, e.g. `**/*` or `**/*.py`) that
  recommends skills **must** declare either a `contains:` predicate (file
  content filter) or a `task_contains:` predicate (task-text filter). The
  pre-commit gate `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh`
  rejects a wide-glob bundle that carries neither. A narrow glob (≥ 1 literal
  segment) is exempt.
- `task_contains:` is the task-text routing key (a content-hint sibling). It is
  a list of substrings matched against the caller-supplied `task_text` parameter
  (issue body + `plan.md`). A bundle that declares `task_contains` is selected
  when at least one substring is found in `task_text`, regardless of which files
  are in the diff — enabling routing for green-field tasks where the relevant
  library files do not yet exist. When no `task_text` is supplied, `task_contains`
  predicates are inactive.
- `skills` entries must be installed skill directory names. A name that is not
  installed in the target repo is silently skipped at runtime, so the
  pre-commit validator is the strict authoring-time gate.

## See also

Load the resources below at the exact point of need described — not up-front.

- `plugins/makato-build/shared/inject_skills.py` — reference implementation.
  **MANDATORY** when diagnosing a resolver mismatch, extending resolution logic
  (specificity algorithm, content hints, task hints), or verifying that a new
  edge case is handled correctly.
- `plugins/makato-build/skills/inject-context/SKILL.md` — the context-bundle
  sibling that shares the glob-specificity ordering contract. **MANDATORY** when
  writing a new resolver that must share the ordering contract or when
  `inject-context` and `inject-skills` results need to be reconciled.
- `plugins/makato-build/agents/knowledge-scout.md` — Step 0 caller; Step 0e
  documents the `task_text` opt-in for task-text routing. **MANDATORY** when
  diagnosing why `inject-skills` was not called or when the caller's Step 0
  behavior needs to change.
- `plugins/makato-langgraph/config/skill-bundles.yml` — canonical bundle example
  with `task_contains` seed data. **MANDATORY** when authoring a new bundle.
- `plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh` — authoring
  gate. **MANDATORY** when the pre-commit gate rejects a bundle or when adding
  new validation rules to the wide-glob check.
- `tests/integration/skill-bundles-aggregate.sh` — cross-plugin aggregate test.
  **MANDATORY** when a new plugin adds its first `skill-bundles.yml`.
