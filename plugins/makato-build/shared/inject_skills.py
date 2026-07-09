"""Skill-bundle resolver for the makato-build inject-skills skill (F1 / #144).

Given a list of changed file paths and a parsed skill-bundles.yml config, return
a deterministic, deduplicated, ordered list of recommended skill identifiers to
prepend into an agent's system prompt before dispatch.

This is the skill-routing sibling of ``inject_context.py``. It shares the same
glob-specificity ordering (D9) but adds three concerns unique to skill routing:

  * D19 — content-hint predicate. A bundle MAY declare a ``contains`` list of
    substrings. The bundle matches a changed file only when its glob matches
    AND at least one ``contains`` substring is found in that file's text
    (OR-semantics). A bundle with no ``contains`` list is glob-only, exactly
    like a context bundle.
  * D10 — target-repo subset filter. The resolved skill identifiers are
    filtered to those actually installed in the target repo. A rule may name a
    skill that a given repo has not installed; those names are dropped from the
    result and surfaced in ``warnings`` (see D18).
  * D18 — graceful missing-skill skip. A referenced-but-uninstalled skill never
    raises; resolution continues and emits a ``missing-skills`` warning so the
    caller can log it. The pre-commit validator (authoring-time) is the strict
    gate; the resolver (runtime) is deliberately lenient.

Resolution contract (mirrors plugins/makato-*/config/skill-bundles.yml):

  1. For each changed file, every bundle whose glob matches AND whose
     content-hint predicate is satisfied is selected.
  2. Bundles are applied in order of decreasing specificity, where specificity
     is the count of literal path segments in the matching glob (segments with
     no ``*`` or ``?``). A bundle's rank for the whole changeset is the MAX
     score it achieved on any file. Ties break by config-declaration order,
     then by aggregation order across plugin config files (sorted by path).
  3. The bundle named ``default`` is always appended last, regardless of its
     specificity score.
  4. Skill identifiers are deduplicated preserving the FIRST occurrence.
  5. If ``changed_files`` is empty, only the ``default`` bundle's skills are
     returned, with no no-match warning (an empty work-set is a valid no-scope
     case).
  6. If a changed file matches NO non-default bundle (and default's own globs
     don't match it either), the resolver still falls back to ``default`` and
     records the file in a ``no-match-fallback`` warning.
  7. If the merged config has no bundle named ``default``, or any bundle entry
     is missing its ``name`` field, or two bundles share the same ``name``,
     raise BundleResolutionError with halt_code="HALT-006".
  8. After ordering, the skill list is filtered to the target repo's installed
     skills (D10). Dropped names are collected into a ``missing-skills`` warning
     (D18) — never an exception.

Stdlib only for the pure resolver; PyYAML + filesystem walking live in the
orchestration helpers (``aggregate_bundles``, ``discover_installed_skills``,
``resolve_skills_for_repo``) so the core is unit-testable in isolation.

Return shape of ``resolve_skills``:

    (skills: list[str], warnings: list[dict])

Each warning is a dict with a ``code`` key. Emitted codes:

    {"code": "no-match-fallback", "unmatched_files": [<paths>]}
    {"code": "missing-skills", "skills": [<names>]}

Callers (knowledge-scout) translate these into build.jsonl entries shaped per
plugins/makato-build/AGENTS.md § Skill Authoring.
"""

from __future__ import annotations

import fnmatch
from pathlib import Path
from typing import Iterable


# ---------------------------------------------------------------------------
# Glob matching — identical semantics to inject_context._match_glob.
# ---------------------------------------------------------------------------


def _match_glob(path: str, pattern: str) -> bool:
    """Match a POSIX-style path against a glob with ``**`` semantics.

    Python's stdlib ``fnmatch`` does not special-case ``**`` — it lets ``*``
    swallow ``/``, which breaks the common-sense "``**/*.py`` matches foo.py"
    expectation. We implement the segment-wise semantics directly:

      ``**``  matches zero or more whole path segments
      ``*``   matches zero or more characters within a single segment (no ``/``)
      ``?``   matches exactly one character within a single segment (no ``/``)

    Examples (all True):
      ``**/*graph*.py``   vs ``foo_graph.py``
      ``**/*graph*.py``   vs ``src/sub/agent_graph.py``
      ``**/*``            vs ``README.md``
    """
    return _match_segments(path.split("/"), pattern.split("/"))


def _match_segments(path_parts: list[str], pat_parts: list[str]) -> bool:
    """Recursive segment-wise globstar match (``**`` swallows whole segments)."""
    if not pat_parts:
        return not path_parts
    head = pat_parts[0]
    rest = pat_parts[1:]
    if head == "**":
        if not rest:
            return True
        for i in range(len(path_parts) + 1):
            if _match_segments(path_parts[i:], rest):
                return True
        return False
    if not path_parts:
        return False
    if fnmatch.fnmatchcase(path_parts[0], head):
        return _match_segments(path_parts[1:], rest)
    return False


class BundleResolutionError(Exception):
    """Raised when the resolver cannot satisfy a hard contract requirement.

    Currently: a merged config that omits the ``default`` bundle, a bundle
    missing its ``name`` field, or a duplicate bundle name. All map to HALT-006
    in plugins/makato-orchestrate/halt-conditions.md.
    """

    def __init__(self, message: str, halt_code: str) -> None:
        super().__init__(message)
        self.halt_code = halt_code


def _glob_specificity(glob: str) -> int:
    """Return the literal-segment count of a glob.

    A segment is one component split on ``/``. A segment is *literal* when it
    contains no ``*`` or ``?``. Greater count == more specific.

      ``**/*``            -> 0 literal segments
      ``**/*graph*.py``   -> 0 literal segments
      ``**/langgraph/**`` -> 1 literal segment (``langgraph``)
      ``src/graph.py``    -> 2 literal segments (``src``, ``graph.py``)
    """
    segments = glob.split("/")
    return sum(1 for seg in segments if seg and "*" not in seg and "?" not in seg)


def _content_hint_ok(bundle: dict, file_text: str | None) -> bool:
    """Return True when the bundle's ``contains`` predicate is satisfied (D19).

    A bundle with no ``contains`` list (or an empty one) is glob-only and always
    passes. Otherwise at least one substring must appear in ``file_text``
    (OR-semantics). When ``file_text`` is None (file unreadable / not provided),
    a content-restricted bundle cannot be confirmed and therefore does NOT
    match — the safe default is to withhold a suggestion rather than assert one.
    """
    contains = bundle.get("contains") or []
    if not contains:
        return True
    if file_text is None:
        return False
    return any(substr in file_text for substr in contains)


def _bundle_matches_file(
    bundle: dict, file_path: str, file_text: str | None
) -> tuple[bool, int]:
    """Return (matched, best_specificity_score) for a single bundle vs file.

    A bundle matches when any of its globs matches AND its content-hint
    predicate is satisfied. The specificity for the match is the max
    literal-segment count across all matching globs.
    """
    if not _content_hint_ok(bundle, file_text):
        return (False, 0)
    best = -1
    for glob in bundle.get("globs", []):
        if _match_glob(file_path, glob):
            score = _glob_specificity(glob)
            if score > best:
                best = score
    if best < 0:
        return (False, 0)
    return (True, best)


def _validate_bundles(bundles: list[dict]) -> dict:
    """Validate bundle schema and return a name->bundle map.

    Raises BundleResolutionError (HALT-006) on a missing ``name``, a duplicate
    ``name``, or an absent ``default`` bundle — the same hard-contract failures
    that inject_context enforces.
    """
    seen_names: set[str] = set()
    for i, bundle in enumerate(bundles):
        if "name" not in bundle:
            raise BundleResolutionError(
                f"skill-bundles config: bundle entry at index {i} is missing "
                "the required `name` field. Every bundle must declare `name`, "
                "`globs`, and `skills`.",
                halt_code="HALT-006",
            )
        name = bundle["name"]
        if name in seen_names:
            raise BundleResolutionError(
                f"skill-bundles config: bundle name `{name}` is declared more "
                f"than once (index {i}). Bundle names must be unique across the "
                "merged registry — duplicates would silently alias and discard "
                "earlier definitions.",
                halt_code="HALT-006",
            )
        seen_names.add(name)

    by_name = {b["name"]: b for b in bundles}
    if "default" not in by_name:
        raise BundleResolutionError(
            "skill-bundles config is missing the required `default` bundle; "
            "every merged registry must define a `default` so the resolver "
            "always has a fallback. Add a bundle named `default` and retry.",
            halt_code="HALT-006",
        )
    return by_name


def resolve_skills(
    changed_files: Iterable[str],
    config: dict,
    *,
    file_texts: dict[str, str] | None = None,
    installed_skills: Iterable[str] | None = None,
) -> tuple[list[str], list[dict]]:
    """Resolve changed files to an ordered, deduplicated list of skill names.

    Pure function — does no filesystem I/O. Content-hint evaluation reads from
    the ``file_texts`` map (path -> text); a path absent from the map is treated
    as unreadable (its content-restricted bundles will not match).

    Args:
        changed_files: paths the target agent will read or write.
        config: merged skill-bundles config — ``{"bundles": [...]}``.
        file_texts: optional path -> file-content map for D19 content hints.
            When omitted, only glob-only bundles (no ``contains``) can match.
        installed_skills: optional iterable of skill identifiers available in
            the target repo (D10). When None, no subset filtering is applied —
            every resolved skill is returned. When provided, resolved skills not
            in the set are dropped and reported via a ``missing-skills`` warning.

    Returns:
        (skills, warnings) — see module docstring for warning shapes.
    """
    bundles = config.get("bundles", []) or []
    by_name = _validate_bundles(bundles)
    default_bundle = by_name["default"]
    texts = file_texts or {}
    files = list(changed_files)

    # Step 1: collect (declaration_index, specificity, name) for each non-default
    # bundle matching at least one changed file. Track which files were matched
    # by anything non-default so we can surface no-match warnings.
    matched_bundles: list[tuple[int, int, str]] = []
    matched_files: set[str] = set()

    for idx, bundle in enumerate(bundles):
        if bundle["name"] == "default":
            continue
        best_for_this_bundle = -1
        for file_path in files:
            ok, score = _bundle_matches_file(bundle, file_path, texts.get(file_path))
            if ok:
                matched_files.add(file_path)
                if score > best_for_this_bundle:
                    best_for_this_bundle = score
        if best_for_this_bundle >= 0:
            matched_bundles.append((idx, best_for_this_bundle, bundle["name"]))

    # Step 2: sort by specificity (desc), then declaration order (asc). Python's
    # sort is stable so a single sorted() call honours the tie-break.
    matched_bundles.sort(key=lambda tup: (-tup[1], tup[0]))

    # Step 3: build ordered skill list, dedup preserving first occurrence.
    seen: set[str] = set()
    skills: list[str] = []
    for _, _, name in matched_bundles:
        for skill in by_name[name].get("skills", []):
            if skill not in seen:
                seen.add(skill)
                skills.append(skill)

    # Step 4: always append default's skills last.
    for skill in default_bundle.get("skills", []):
        if skill not in seen:
            seen.add(skill)
            skills.append(skill)

    warnings: list[dict] = []

    # Step 5: no-match-fallback warning. Empty input is not a warning.
    if files:
        unmatched = []
        for file_path in files:
            if file_path in matched_files:
                continue
            default_match, _ = _bundle_matches_file(
                default_bundle, file_path, texts.get(file_path)
            )
            if not default_match:
                unmatched.append(file_path)
        if unmatched:
            warnings.append(
                {"code": "no-match-fallback", "unmatched_files": unmatched}
            )

    # Step 6: D10 target-repo subset filter + D18 graceful missing-skill skip.
    if installed_skills is not None:
        available = set(installed_skills)
        kept: list[str] = []
        missing: list[str] = []
        for skill in skills:
            (kept if skill in available else missing).append(skill)
        skills = kept
        if missing:
            warnings.append({"code": "missing-skills", "skills": missing})

    return skills, warnings


# ---------------------------------------------------------------------------
# Orchestration helpers — filesystem + PyYAML (not exercised by pure unit tests)
# ---------------------------------------------------------------------------


def aggregate_bundles(makato_root: Path | str) -> dict:
    """Merge every ``plugins/*/config/skill-bundles.yml`` into one config.

    Cross-plugin aggregation (F1 baseline for S3): each plugin owns its own
    ``skill-bundles.yml`` and contributes its non-``default`` bundles to a single
    merged registry. Exactly one ``default`` bundle is retained — the first one
    encountered in path-sorted order — so the merged config always satisfies the
    HALT-006 default-present contract without duplicate-name collisions.

    Config files are visited in sorted path order for determinism; that order
    is also the cross-plugin tie-break for equally-specific bundles.

    Raises BundleResolutionError (HALT-006) if no plugin ships a ``default``
    bundle. A single plugin's own duplicate bundle names surface later in
    ``resolve_skills`` validation; cross-plugin duplicate names likewise raise
    there, which is the intended strictness.
    """
    import yaml  # type: ignore[import-untyped]

    root = Path(makato_root)
    merged: list[dict] = []
    seen_default = False

    config_paths = sorted(root.glob("plugins/*/config/skill-bundles.yml"))
    for cfg_path in config_paths:
        try:
            raw = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError):
            continue
        for bundle in raw.get("bundles", []) or []:
            if bundle.get("name") == "default":
                # Keep only the first default; drop the rest so the merged
                # registry has a single unambiguous fallback.
                if seen_default:
                    continue
                seen_default = True
            merged.append(bundle)

    if not seen_default:
        raise BundleResolutionError(
            "no plugin ships a `default` skill bundle; the merged registry must "
            "define exactly one `default` bundle as the resolver fallback. Add a "
            "`default` bundle (empty `skills: []` is fine) to a plugin's "
            "config/skill-bundles.yml.",
            halt_code="HALT-006",
        )

    return {"version": "1.0", "bundles": merged}


def discover_installed_skills(makato_root: Path | str) -> set[str]:
    """Return the set of skill identifiers installed under ``plugins/*/skills/``.

    A skill's identifier is its directory name — the same token used in a
    bundle's ``skills`` list (e.g. ``langgraph-fundamentals``). Used to build the
    D10 subset filter for ``resolve_skills``.
    """
    root = Path(makato_root)
    return {
        skill_md.parent.name
        for skill_md in root.glob("plugins/*/skills/*/SKILL.md")
    }


def resolve_skills_for_repo(
    changed_files: Iterable[str],
    makato_root: Path | str,
    *,
    apply_subset_filter: bool = True,
) -> tuple[list[str], list[dict]]:
    """End-to-end resolution against a makato checkout.

    Aggregates every plugin's ``skill-bundles.yml`` (cross-plugin), reads the
    text of each changed file that exists for D19 content hints, discovers the
    installed skill set for the D10 subset filter, and delegates to the pure
    ``resolve_skills``. This is the entry point knowledge-scout's Step 0 calls.
    """
    root = Path(makato_root)
    config = aggregate_bundles(root)

    files = list(changed_files)
    file_texts: dict[str, str] = {}
    for file_path in files:
        candidate = root / file_path
        try:
            if candidate.is_file():
                file_texts[file_path] = candidate.read_text(
                    encoding="utf-8", errors="replace"
                )
        except OSError:
            continue

    installed = discover_installed_skills(root) if apply_subset_filter else None
    return resolve_skills(
        files, config, file_texts=file_texts, installed_skills=installed
    )


__all__ = [
    "BundleResolutionError",
    "resolve_skills",
    "aggregate_bundles",
    "discover_installed_skills",
    "resolve_skills_for_repo",
]
