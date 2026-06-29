"""Bundle resolver for the makato-build inject-context skill.

Given a list of changed file paths and a parsed context-bundles.yml config,
return a deterministic, deduplicated, ordered list of rule paths for the
knowledge-scout agent to pre-read.

Resolution contract (mirrors plugins/makato-build/config/context-bundles.yml):

  1. For each changed file, every bundle whose globs match is selected.
  2. Bundles are applied in order of decreasing specificity, where
     specificity is the count of literal path segments in the matching glob
     (segments that contain no `*` or `?`). When a bundle matches multiple
     files via globs of different specificity, its rank for the whole
     changeset is the MAX score it achieved on any file — this is a
     per-bundle ranking, not a per-file ranking. Ties broken by
     config-declaration order.
  3. The bundle named `default` is always appended last, regardless of its
     specificity score.
  4. Rule paths are deduplicated, preserving the FIRST occurrence — so a rule
     listed in both `python` and `default` is emitted in python's slot only.
  5. If `changed_files` is empty, only the `default` bundle's rules are
     returned, with no warning (an empty work-set is a valid no-scope case,
     not a warning).
  6. If a changed file matches NO non-default bundle (and the default-bundle's
     globs don't match it either), the resolver still falls back to the
     `default` bundle and returns a structured warning tuple. With the
     canonical production config (`default.globs == ["**/*"]`) every file
     matches default's own globs, so the warning is latent/defensive.
  7. If the config has no bundle named `default`, or any bundle entry is
     missing its `name` field, or two bundles share the same `name`, raise
     BundleResolutionError with halt_code="HALT-006". The caller is
     responsible for translating that into a halt entry in build.jsonl /
     workflow-state.json.

Stdlib only — mirrors plugins/makato-build/shared/parse-sarif.py.

Return shape:

    (rules: list[str], warning: dict | None)

`warning` is None on the happy path. When emitted, it has:

    {"code": "no-match-fallback", "unmatched_files": [<paths>]}

Callers (knowledge-scout) translate this into a build.jsonl entry shaped per
plugins/makato-build/AGENTS.md § Skill Authoring.
"""

from __future__ import annotations

import fnmatch
from typing import Iterable


def _match_glob(path: str, pattern: str) -> bool:
    """Match a POSIX-style path against a glob with `**` semantics.

    Python 3.12's stdlib `fnmatch` does NOT special-case `**` — it treats both
    `*` and `**` as "any characters" and lets them swallow `/`, which breaks the
    common-sense "**/*.py matches foo.py" expectation. `pathlib.PurePath.full_match`
    fixes this in 3.13+, but we target 3.12+, so we implement the semantics
    directly:

      `**`  matches zero or more whole path segments
      `*`   matches zero or more characters within a single segment (no `/`)
      `?`   matches exactly one character within a single segment (no `/`)
      any literal segment must match the corresponding path segment via fnmatch

    Examples (all True):
      `**/*.py`              vs `foo.py`
      `**/*.py`              vs `src/sub/foo.py`
      `**/*`                 vs `README.md`
      `**/migrations/**`     vs `migrations/001.sql`
      `**/migrations/**`     vs `db/migrations/sub/foo.sql`
    """
    return _match_segments(path.split("/"), pattern.split("/"))


def _match_segments(path_parts: list[str], pat_parts: list[str]) -> bool:
    """Recursive segment-wise globstar match (`**` swallows whole segments)."""
    if not pat_parts:
        return not path_parts
    head = pat_parts[0]
    rest = pat_parts[1:]
    if head == "**":
        # ** matches zero or more whole segments — try every consumption.
        if not rest:
            return True
        for i in range(len(path_parts) + 1):
            if _match_segments(path_parts[i:], rest):
                return True
        return False
    if not path_parts:
        return False
    # Within a single segment fnmatch is correct: `*` does not cross `/`.
    if fnmatch.fnmatchcase(path_parts[0], head):
        return _match_segments(path_parts[1:], rest)
    return False


class BundleResolutionError(Exception):
    """Raised when the resolver cannot satisfy a hard contract requirement.

    Currently the only such case is a config that omits the `default` bundle,
    which maps to HALT-006 in plugins/makato-orchestrate/halt-conditions.md.
    """

    def __init__(self, message: str, halt_code: str) -> None:
        super().__init__(message)
        self.halt_code = halt_code


def _glob_specificity(glob: str) -> int:
    """Return the literal-segment count of a glob.

    A segment is one component split on `/`. A segment is `literal` when it
    contains no `*` or `?`. The greater the count, the more specific the glob
    — `src/main.py` (2 literal) > `**/*.py` (0 literal) > `**/*` (0 literal).

    Examples:
      `**/*`             -> 0 literal segments
      `**/*.py`          -> 0 literal segments
      `**/migrations/**` -> 1 literal segment (`migrations`)
      `src/main.py`      -> 2 literal segments (`src`, `main.py`)
    """
    segments = glob.split("/")
    return sum(
        1 for seg in segments
        if seg and "*" not in seg and "?" not in seg
    )


def _bundle_matches_file(bundle: dict, file_path: str) -> tuple[bool, int]:
    """Return (matched, best_specificity_score) for a single bundle vs file.

    A bundle matches a file when any of its globs matches. The bundle's
    specificity for this match is the max literal-segment count across all
    matching globs.
    """
    best = -1
    for glob in bundle.get("globs", []):
        if _match_glob(file_path, glob):
            score = _glob_specificity(glob)
            if score > best:
                best = score
    if best < 0:
        return (False, 0)
    return (True, best)


def resolve_bundles(
    changed_files: Iterable[str],
    config: dict,
) -> tuple[list[str], dict | None]:
    """Resolve changed files to an ordered, deduplicated list of rule paths.

    See module docstring for the full contract.
    """
    bundles = config.get("bundles", []) or []

    # Validate bundle schema up-front so callers always see a typed error
    # rather than a bare KeyError from later dict accesses. Duplicate `name`
    # values are also rejected: the existing `by_name` dict comprehension
    # would silently alias them and emit the second bundle's rules in both
    # slots, while losing the first bundle's rules entirely.
    seen_names: set[str] = set()
    for i, bundle in enumerate(bundles):
        if "name" not in bundle:
            raise BundleResolutionError(
                f"context-bundles config: bundle entry at index {i} is missing "
                "the required `name` field. Every bundle must declare `name`, "
                "`globs`, and `rules`.",
                halt_code="HALT-006",
            )
        name = bundle["name"]
        if name in seen_names:
            raise BundleResolutionError(
                f"context-bundles config: bundle name `{name}` is declared "
                f"more than once (index {i}). Bundle names must be unique — "
                "duplicates would silently alias and discard earlier "
                "definitions.",
                halt_code="HALT-006",
            )
        seen_names.add(name)

    by_name = {b["name"]: b for b in bundles}

    if "default" not in by_name:
        raise BundleResolutionError(
            "context-bundles config is missing the required `default` bundle; "
            "every config must define a `default` so the resolver always has a "
            "fallback. Add a bundle named `default` and retry.",
            halt_code="HALT-006",
        )

    default_bundle = by_name["default"]

    # Step 1: collect (bundle_index, specificity, name) tuples for each
    # non-default bundle that matches AT LEAST ONE changed file. Track which
    # files were matched by anything other than the default bundle so we can
    # surface no-match warnings.
    files = list(changed_files)
    matched_bundles: list[tuple[int, int, str]] = []
    matched_files: set[str] = set()

    for idx, bundle in enumerate(bundles):
        if bundle["name"] == "default":
            continue
        best_for_this_bundle = -1
        for file_path in files:
            ok, score = _bundle_matches_file(bundle, file_path)
            if ok:
                matched_files.add(file_path)
                if score > best_for_this_bundle:
                    best_for_this_bundle = score
        if best_for_this_bundle >= 0:
            matched_bundles.append((idx, best_for_this_bundle, bundle["name"]))

    # Step 2: sort by specificity (descending), then by declaration order
    # (ascending) — Python's sort is stable, so a single sorted() call works.
    matched_bundles.sort(key=lambda tup: (-tup[1], tup[0]))

    # Step 3: build the ordered rule list, dedup preserving first occurrence.
    seen: set[str] = set()
    rules: list[str] = []

    for _, _, name in matched_bundles:
        for rule in by_name[name].get("rules", []):
            if rule not in seen:
                seen.add(rule)
                rules.append(rule)

    # Step 4: always append default's rules last.
    for rule in default_bundle.get("rules", []):
        if rule not in seen:
            seen.add(rule)
            rules.append(rule)

    # Step 5: warning surface.
    #
    # Empty input is NOT a warning — it just means "no work to scope, fall
    # through to default." If any file was changed but didn't match any
    # non-default bundle AND the default bundle's globs don't match it either,
    # we still return the default rules but flag the unmatched files for the
    # caller's audit trail.
    warning: dict | None = None
    if files:
        # A file is "covered" if any non-default bundle matched it OR the
        # default bundle's own globs match it.
        unmatched = []
        for file_path in files:
            if file_path in matched_files:
                continue
            default_match, _ = _bundle_matches_file(default_bundle, file_path)
            if not default_match:
                unmatched.append(file_path)
        if unmatched:
            warning = {
                "code": "no-match-fallback",
                "unmatched_files": unmatched,
            }

    return rules, warning


__all__ = ["BundleResolutionError", "resolve_bundles"]
