---
name: inject-context
description: >-
  Resolve a list of changed file paths against the canonical
  `config/context-bundles.yml` registry and return a deterministic,
  deduplicated, ordered list of rule-file paths for `knowledge-scout` to
  pre-read. Implements glob-specificity-first ordering with `default` bundle
  appended last, surfaces a no-match-fallback warning to callers, and raises
  HALT-006 when the `default` bundle is absent. Dispatched as a shared helper
  by `knowledge-scout` Step 0; never invoked directly by the user.
version: "1.0.0"
---

# inject-context

> **MANDATORY load trigger:** `knowledge-scout` MUST load this skill at Step 0
> (before SPECS_ROOT discovery) whenever it processes a task with a changed-file
> list.
>
> **Do NOT load** this skill directly from user prompts, other skills, or any
> agent other than `knowledge-scout`. It has no user-facing interaction surface.

## 1. Overview

This skill is the **context-bundle resolver** that `knowledge-scout` calls before its
existing dcp-specs discovery process. Given a task's predicted changed-file list, it
returns the ordered rule-file paths the scout should pre-read.

The resolver does NOT read rule-file contents — it returns paths only. Reading is the
scout's job (so file-not-found tolerance, encoding, and size limits stay localised in
the scout, not duplicated here).

## 2. Inputs

The caller passes:

| Field | Type | Description |
|-------|------|-------------|
| `changed_files` | `list[str]` | Project-relative paths the task will create or modify. May be empty (treated as a valid no-scope case — see § 4 contract item 5). |
| `config` | `dict` | Parsed `context-bundles.yml`. The caller is responsible for the YAML parse. |

The production config lives at `plugins/makato-build/config/context-bundles.yml`. Its
schema is:

```yaml
version: "1.0"
bundles:
  - name: <unique kebab-case identifier>
    globs: [<fnmatch-style pattern>, …]   # `**` matches any depth; `*` and `?` do not cross `/`
    rules: [<rule-file path>, …]          # may reference `context/{repo}/` patterns; caller substitutes `{repo}`
```

At least four canonical bundles are required by convention: `typescript`, `python`, `sql`,
and `default`. Adding more bundles is a non-breaking change; removing `default` is a
breaking change that fires HALT-006.

## 3. Output

The resolver returns a 2-tuple:

```python
(rules: list[str], warning: dict | None)
```

`rules` is the ordered, deduplicated list of rule-file paths the scout must pre-read,
in the order they are listed.

`warning` is `None` on the happy path. When a changed file matches no bundle's globs
(not even `default`'s), the warning takes shape:

```json
{
  "code": "no-match-fallback",
  "unmatched_files": ["<path>", "..."]
}
```

The caller (`knowledge-scout`) is responsible for translating this into a `build.jsonl`
entry of the form:

```json
{"ts":"…","skill":"knowledge-scout","story":"<key>","step":"resolve-bundles","status":"warn","data":{"code":"no-match-fallback","unmatched_files":[…]}}
```

## 4. Resolution Contract

The contract is enforced by `plugins/makato-build/shared/inject_context.py`. Any
behavioural change here is a contract change for `knowledge-scout` and must bump this
skill's `version`.

1. **Match.** For each changed file, every bundle whose globs match is selected. A
   bundle matches a file when any one of its globs matches.
2. **Order by specificity.** Bundles are applied in decreasing order of glob
   **specificity**, where specificity = the count of literal path segments in the
   **best-matching glob across all changed files** (i.e. the max specificity score the
   bundle achieved on any one file). This is a per-bundle ranking, not a per-file
   ranking — see § 4.7 for the exact tie-breaking rule.
   - `src/foo.py` → 2 literal segments
   - `**/migrations/**` → 1 literal segment (`migrations`)
   - `**/*.py` → 0 literal segments
   - `**/*` → 0 literal segments

   Ties at the same specificity tier are broken by config-declaration order. Python's
   stable sort guarantees this is deterministic.
3. **`default` always last.** The bundle named `default` is appended last, regardless of
   its specificity score. This makes the catch-all `**/*` glob safe to use without
   surprising other bundles.
4. **Dedup preserving first occurrence.** A rule path listed in both `python` and
   `default` (or any two bundles) is emitted in the first bundle's slot only.
5. **Empty input is not a warning.** An empty `changed_files` list returns only
   `default`'s rules, with `warning = None`. Empty inputs are a valid "no work to scope"
   case and should not trigger fallback logging.
6. **No-match falls back AND warns.** When a file matches no non-default bundle AND
   `default`'s own globs don't match it either, the resolver still returns `default`'s
   rules and emits a `no-match-fallback` warning naming the unmatched files. The caller
   logs the warning; the resolver never writes to disk. **Note:** with the canonical
   production config (`default.globs == ["**/*"]`) every file matches the default's own
   globs, so this warning is latent/defensive — only reachable when an operator narrows
   `default.globs` deliberately.
7. **Missing `default` raises HALT-006.** If the config has no bundle named `default`,
   the resolver raises `BundleResolutionError` with
   `halt_code == "HALT-006"`. The caller is responsible for translating that into a
   halt entry in `workflow-state.json` per
   `plugins/makato-orchestrate/halt-conditions.md`. The resolver itself never emits a
   halt — it only signals.
8. **Schema validation raises HALT-006 too.** A bundle entry without a `name` field, or
   two bundles sharing the same `name`, also raises `BundleResolutionError` with
   `halt_code == "HALT-006"`. These are treated as the same operator-fixable category
   as the missing-default case (the registry is malformed).

## 5. Reference Implementation

The resolver is implemented in `plugins/makato-build/shared/inject_context.py`. Public
API:

```python
import yaml
from inject_context import resolve_bundles, BundleResolutionError

with open("plugins/makato-build/config/context-bundles.yml") as fh:
    config = yaml.safe_load(fh)

rules, warning = resolve_bundles(
    changed_files=["src/foo.ts", "src/bar.py", "migrations/001_init.sql"],
    config=config,
)
```

Tests live in `plugins/makato-build/shared/test_inject_context.py` and run via stdlib
`unittest` (no pytest dependency) from the repo root:

```sh
python3 -m unittest discover plugins/makato-build/shared -p 'test_*.py'
```

Test coverage: single-match, multi-match + dedup, specificity precedence, empty input,
no-match fallback, missing-default → HALT-006, and an integration check that loads the
real `context-bundles.yml` and exercises a mixed file workload.

## 6. Usage by `knowledge-scout`

`knowledge-scout` invokes the resolver in its Step 0 (before SPECS_ROOT discovery). The
canonical call shape is:

1. Parse `plugins/makato-build/config/context-bundles.yml` (PyYAML — already a project
   dependency).
2. Substitute the `{repo}` token in each rule path with the value of the agent's
   `REPO_NAME` input.
3. Call `resolve_bundles(changed_files, config)`.
4. On `BundleResolutionError` with `halt_code == "HALT-006"`: emit the halt entry and
   return.
5. On `warning is not None`: append the warning to `build.jsonl` as `status: "warn"` and
   continue with the returned `rules` list.
6. Pre-read every rule path that exists on disk. Missing rule files are tolerated
   silently (the registry references aspirational `context/{repo}/` paths that may not
   exist in every target repo).

### Caller decision tree for response states

After step 3, exactly one of three states is reached. The correct response differs by
state:

```
resolve_bundles() returns
│
├─ raises BundleResolutionError (halt_code="HALT-006")
│     → ABORT. Emit halt entry to workflow-state.json and build.jsonl.
│       Do NOT continue with a partial rule list.
│       Operator must fix context-bundles.yml and retry.
│       Recovery: operator-only (not agent-fixable at runtime).
│
├─ returns (rules, warning=non-None)   ["no-match-fallback"]
│     → CONTINUE with the returned rules list (it is still valid).
│       Log warning to build.jsonl as status="warn".
│       The scout proceeds normally — the default bundle covers the gap.
│       Recovery: advisory only; scout should surface it so an operator
│       can add a matching bundle to context-bundles.yml later.
│
└─ returns (rules, warning=None)       [happy path]
      → CONTINUE. Pre-read the rules list and proceed to SPECS_ROOT discovery.
```

Key invariant: the `HALT-006` path is the **only** state that must stop the loop.
The `no-match-fallback` warning is a quality signal, not a blocker — the scout always
has at least the `default` bundle's rules to work from.

## 7. R1 Output Contract

This skill produces no R1 envelope of its own — it is a pure-function helper consumed by
`knowledge-scout`. The scout's R1 envelope reflects any HALT-006 or warning surfaced by
the resolver (see `plugins/makato-build/agents/RETURN-CONTRACT.md`).

## 8. Anti-patterns

NEVER pass absolute paths in `changed_files`.
> WHY: Specificity scoring counts literal path segments split on `/`. An absolute path
> like `/home/user/repo/src/foo.py` produces a large literal-segment count that
> swamps all other bundles' scores, producing a nonsensical ranking. The contract
> assumes project-relative paths; the integration tests only exercise relative inputs.
> Absolute paths will not raise an error — they will silently mis-rank every bundle.

NEVER re-implement glob matching inline instead of calling `resolve_bundles`.
> WHY: The resolver uses a custom recursive `_match_glob` that gives `**` true
> globstar semantics (matches zero or more whole path segments). Python's stdlib
> `fnmatch` does NOT special-case `**` — it treats `**` like `*` and lets it swallow
> `/`, so `fnmatch.fnmatch("src/sub/foo.py", "**/*.py")` returns `False`. Callers
> that bypass the resolver and use raw `fnmatch` will produce incorrect bundle
> selections that are hard to debug because the mismatch only appears for nested paths.

NEVER swallow a `BundleResolutionError` and continue with an empty rules list.
> WHY: A `BundleResolutionError` signals a malformed registry (missing `default`,
> missing `name`, duplicate `name`). Continuing without a valid rules list means the
> scout operates with zero context rules and will silently skip all hard-constraint
> injection. The downstream coder then runs without project standards. The error must
> be translated to HALT-006 and the session must stop so the operator can repair the
> registry before re-dispatch.

NEVER skip the `{repo}` token substitution (step 2) before passing paths to the scout.
> WHY: Rule paths in `context-bundles.yml` contain the literal string `{repo}` (e.g.
> `context/{repo}/standards/typescript.md`). Passing unsubstituted paths to the scout's
> file-read step will silently produce misses for every rule file — the path doesn't
> exist on disk as-is. Missing rule files are tolerated silently (§6 step 6), so
> there is no error; the scout simply has no context rules injected, which defeats the
> entire purpose of this skill.

NEVER call `resolve_bundles` with a `config` argument that is not a fully parsed dict.
> WHY: If YAML parsing fails and the caller passes `None` or a string, the resolver
> will raise a bare `AttributeError` or `TypeError` rather than a `BundleResolutionError`.
> The caller then has no `halt_code` to translate and may propagate an unhandled
> exception. Always check that `yaml.safe_load` returned a dict before calling
> `resolve_bundles`; if it did not, treat it as HALT-006 and halt before calling in.

## 9. What this skill does NOT do

- It does not read rule-file contents — only paths. File I/O belongs to the scout.
- It does not parse YAML — the caller passes a pre-parsed `dict`.
- It does not log to `build.jsonl` — it returns a warning tuple; the caller logs.
- It does not emit halts — it raises a typed exception carrying the halt code; the
  caller emits the halt.
- It does not modify the `context-bundles.yml` registry — that file is hand-authored.

## 10. Versioning

The output shape (the `(rules, warning)` tuple, the warning dict schema, the
`BundleResolutionError.halt_code` contract) is part of this skill's version. Any change
to:

- The tuple arity or element types
- The warning dict's keys or value types
- The `HALT-006` halt-code mapping
- The specificity-comparison semantics (literal-segment count)

is a **breaking contract change** for every caller and must bump the skill's `version`
major (e.g. `1.0.0` → `2.0.0`), coordinated with updates to
`plugins/makato-build/agents/knowledge-scout.md` in the same PR.

Adding new bundle types in `context-bundles.yml` (e.g. `kotlin`, `go`) is a minor
non-breaking change — neither the resolver code nor this skill's contract changes; only
the YAML registry grows.
