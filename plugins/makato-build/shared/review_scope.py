"""Scope a repair-loop re-review to the repair delta instead of the whole branch diff.

build-review and build-verify repair CRITICAL/MAJOR findings in the *uncommitted*
working tree, so ``git diff`` cannot tell the coder's repair apart from the
implementation that was already there. This helper makes that boundary exact with
git plumbing only (a throw-away index; the real index and working tree are never
touched):

    snapshot     print a tree id of the current working-tree state
    delta        compare a pre-repair snapshot with now: the files the repair touched
                 plus the changed files that import them or test them
    decide       the scope state machine: which review (full / delta / final-full /
                 done) comes next
    materialize  check a snapshot out into a detached linked worktree, so a
                 background reviewer reads a frozen tree while the repair edits
                 the live one
    release      remove a materialized checkout again

Delta review is a cost control, not a coverage waiver: it cannot see a defect that
is unrelated to the repair, so the machine always demands one full-scope pass after
the first repair before a clean result may be accepted (``final-full``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import PurePosixPath

SCOPE_MODES = ("delta", "full")
FULL_SCOPE_RATIO = 0.6
DEFAULT_MAX_RELATED = 25
MAX_TEXT_BYTES = 2_000_000
GENERIC_STEMS = frozenset({"index", "main", "types", "utils", "config", "constants", "mod", "lib"})
JS_SUFFIXES = frozenset({".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"})
TEST_SUFFIXES = (".test", ".spec", "_test", "_spec")
REVIEW_CONTRACT_VERSION = 2
REVIEW_CONTRACT_PATHS = (
    "agents/RETURN-CONTRACT.md",
    "agents/coder.md",
    "agents/diff-reviewer.md",
    "config/default-workflow-schema.yml",
    "config/verification-ownership.md",
    "skills/build-review/SKILL.md",
    "skills/build-review/references/mechanical-fixes.md",
    "skills/build-review/references/review-criteria.md",
    "skills/build-review/references/review-loop.md",
    "shared/review_eval.py",
    "shared/review_loop.py",
    "shared/review_runtime.py",
    "shared/skill_execution.py",
    "shared/review_scope.py",
    "scripts/run-skill.py",
    "AUTONOMOUS-MODE.md",
)


class ScopeError(RuntimeError):
    """A git or input problem that makes the scope unreliable."""


def _git(worktree: str, *args: str, env: dict[str, str] | None = None, stdin: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["git", "--literal-pathspecs", "-C", worktree, *args],
        input=stdin,
        capture_output=True,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        raise ScopeError(f"git {' '.join(args[:2])} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def _nul_split(data: bytes) -> list[str]:
    return [item.decode("utf-8", errors="surrogateescape") for item in data.split(b"\0") if item]


def changed_files(worktree: str, review_base: str) -> list[str]:
    """CHANGED_FILES as build-review defines it: merge-base diff plus untracked files."""
    tracked = _nul_split(_git(worktree, "diff", "--name-only", "--no-renames", "-z", review_base))
    untracked = _nul_split(_git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
    return sorted(set(tracked) | set(untracked))


def fingerprint(
    worktree: str,
    review_base: str,
    *,
    context_paths: list[str] | None = None,
    contract_paths: list[str] | None = None,
    evidence_root: str | None = None,
    contract_root: str | None = None,
) -> dict[str, object]:
    """Hash branch bytes plus explicit context/spec/contract files."""
    base_oid = _git(worktree, "rev-parse", "--verify", f"{review_base}^{{commit}}").decode().strip()
    tracked = _nul_split(_git(worktree, "diff", "--name-only", "--no-renames", "-z", review_base))
    untracked = _nul_split(_git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
    changed = sorted(set(tracked) | set(untracked))
    context = sorted(set(context_paths or []))
    contracts = sorted(set(contract_paths or []))
    evidence_root = evidence_root or worktree
    contract_root = contract_root or evidence_root
    manifest_files: list[dict[str, object]] = []

    def add_file(root: str, relative: str, source: str, *, is_changed: bool, is_context: bool, is_contract: bool) -> None:
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts:
            raise ScopeError(f"fingerprint path must be repository-relative: {relative!r}")
        full = os.path.join(root, *pure.parts)
        if os.path.islink(full) and not (is_context or is_contract):
            digest = hashlib.sha256(os.readlink(full).encode("utf-8", errors="surrogateescape")).hexdigest()
            mode = stat.S_IMODE(os.lstat(full).st_mode)
            kind = "symlink"
        elif os.path.isfile(full):
            before = os.stat(full)
            hasher = hashlib.sha256()
            with open(full, "rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    hasher.update(chunk)
            after = os.stat(full)
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
                raise ScopeError(f"fingerprint file changed while being read: {relative!r}")
            digest = hasher.hexdigest()
            mode = stat.S_IMODE(after.st_mode)
            kind = "file"
        elif is_context or is_contract:
            raise ScopeError(f"fingerprint context or contract file is missing: {relative!r}")
        else:
            digest, mode, kind = hashlib.sha256(b"").hexdigest(), None, "deleted"
        manifest_files.append(
            {
                "path": f"{source}:{relative}",
                "kind": kind,
                "mode": mode,
                "sha256": digest,
                "changed": is_changed,
                "context": is_context,
                "contract": is_contract,
            }
        )

    for relative in changed:
        add_file(worktree, relative, "worktree", is_changed=True, is_context=False, is_contract=False)
    for relative in context:
        add_file(evidence_root, relative, "context", is_changed=False, is_context=True, is_contract=False)
    for relative in contracts:
        add_file(contract_root, relative, "contract", is_changed=False, is_context=False, is_contract=True)
    manifest = {
        "schema": "review-input-fingerprint-v1",
        "review_contract_version": REVIEW_CONTRACT_VERSION,
        "base": base_oid,
        "changed_files": changed,
        "context_paths": context,
        "contract_paths": contracts,
        "files": manifest_files,
    }
    encoded = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    return {
        "sha256": digest,
        "review_base": base_oid,
        "files": [entry["path"] for entry in manifest_files],
        "manifest_sha256": digest,
        "manifest": manifest,
    }


def snapshot(worktree: str) -> str:
    """Return a tree id holding the working-tree content of every changed or untracked file.

    The tree is HEAD overlaid with whatever differs on disk, built in a temporary
    index, so it is the complete working state and stays comparable even if HEAD
    moves between two snapshots. Objects are written to the object database only.
    """
    with tempfile.TemporaryDirectory(prefix="makato-snapshot-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": os.path.join(tmp, "index")}
        _git(worktree, "read-tree", "HEAD", env=env)
        dirty = _nul_split(_git(worktree, "diff", "--name-only", "-z", "HEAD"))
        untracked = _nul_split(_git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
        paths = sorted(set(dirty) | set(untracked))
        if paths:
            payload = b"\0".join(path.encode("utf-8", errors="surrogateescape") for path in paths) + b"\0"
            _git(worktree, "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul", env=env, stdin=payload)
        return _git(worktree, "write-tree", env=env).decode().strip()


def snapshot_delta(worktree: str, pre: str, post: str) -> list[dict[str, str]]:
    """Files whose content differs between two snapshots, as {path, status} (A/M/D/T)."""
    raw = _git(worktree, "diff-tree", "-r", "--no-renames", "--name-status", "-z", pre, post)
    tokens = _nul_split(raw)
    return [{"status": tokens[i], "path": tokens[i + 1]} for i in range(0, len(tokens) - 1, 2)]


def materialize(worktree: str, snapshot_tree: str, path: str) -> dict[str, str]:
    """Check ``snapshot_tree`` out at ``path`` as a detached linked worktree; the live worktree is untouched."""
    if os.path.exists(path):
        raise ScopeError(f"materialize target exists: {path}")
    commit = _git(worktree, "commit-tree", snapshot_tree, "-p", "HEAD", "-m", "makato review snapshot").decode().strip()
    _git(worktree, "worktree", "add", "--detach", path, commit)
    return {"path": path, "commit": commit}


def release(worktree: str, path: str) -> None:
    """Remove a materialized checkout; an already-removed one is not an error."""
    try:
        _git(worktree, "worktree", "remove", "--force", path)
    except ScopeError:
        if os.path.exists(path):
            raise
        _git(worktree, "worktree", "prune")


def _read_text(worktree: str, path: str) -> str | None:
    full = os.path.join(worktree, path)
    try:
        if os.path.getsize(full) > MAX_TEXT_BYTES:
            return None
        with open(full, "rb") as handle:
            return handle.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):  # fmt: skip
        return None


def _test_target(stem: str) -> str | None:
    for suffix in TEST_SUFFIXES:
        if stem.endswith(suffix):
            return stem[: -len(suffix)]
    if stem.startswith("test_"):
        return stem[len("test_") :]
    return None


def _reference_pattern(path: str) -> re.Pattern[str]:
    """A pattern that matches another file *referring to* ``path`` (import, mock, link or mention)."""
    pure = PurePosixPath(path)
    suffix = pure.suffix.lower()
    stem = pure.stem
    if suffix == ".py":
        module = pure.parent.name if stem == "__init__" else stem
        target = rf"{re.escape(pure.parent.name)}\.{re.escape(module)}" if module in GENERIC_STEMS and pure.parent.name else re.escape(module)
        return re.compile(rf"^[ \t]*(?:from|import)[ \t]+[^\n#]*\b{target}\b", re.MULTILINE)
    if suffix in JS_SUFFIXES:
        name = pure.parent.name if stem == "index" and pure.parent.name else stem
        return re.compile(rf"""['"][^'"\n]*\b{re.escape(name)}(?:\.[A-Za-z]+)?['"]""")
    return re.compile(rf"(?<![\w.-]){re.escape(pure.name)}(?![\w-])")


def related_files(worktree: str, delta_paths: list[str], candidates: list[str], max_related: int = DEFAULT_MAX_RELATED) -> tuple[list[dict[str, str]], bool]:
    """Changed files outside the delta that test or reference a delta file, test pairs first."""
    in_delta = set(delta_paths)
    patterns = {path: _reference_pattern(path) for path in delta_paths}
    pairs: list[dict[str, str]] = []
    references: list[dict[str, str]] = []
    for candidate in sorted(set(candidates) - in_delta):
        target_stem = _test_target(PurePosixPath(candidate).stem)
        paired = next((path for path in delta_paths if target_stem is not None and PurePosixPath(path).stem == target_stem), None)
        if paired is not None:
            pairs.append({"path": candidate, "reason": f"test of {paired}"})
            continue
        text = _read_text(worktree, candidate)
        if text is None:
            continue
        hit = next((path for path, pattern in patterns.items() if pattern.search(text)), None)
        if hit is not None:
            references.append({"path": candidate, "reason": f"references {hit}"})
    ordered = pairs + references
    return ordered[:max_related], len(ordered) > max_related


def build_delta(worktree: str, review_base: str, pre: str, max_related: int = DEFAULT_MAX_RELATED) -> dict[str, object]:
    post = snapshot(worktree)
    files = snapshot_delta(worktree, pre, post)
    changed = changed_files(worktree, review_base)
    delta_paths = [item["path"] for item in files]
    related, truncated = related_files(worktree, [item["path"] for item in files if item["status"] != "D"], changed, max_related)
    scope_files = sorted(set(changed)) if truncated else sorted(set(delta_paths) | {item["path"] for item in related})
    total = len(changed)
    return {
        "pre_snapshot": pre,
        "post_snapshot": post,
        "files": files,
        "related": related,
        "related_truncated": truncated,
        "scope_files": scope_files,
        "changed_files_total": total,
        "scope_ratio": round(len(scope_files) / total, 3) if total else 1.0,
        "empty": not files,
    }


def resolve_mode(raw: str | None) -> tuple[str, str | None]:
    """MAKATO_REVIEW_SCOPE → (mode, warning); an invalid value falls back to delta."""
    if raw is None or raw.strip() == "":
        return "delta", None
    value = raw.strip().lower()
    if value in SCOPE_MODES:
        return value, None
    return "delta", f"invalid MAKATO_REVIEW_SCOPE {raw!r}; using delta"


def decide(event: str, mode: str, last_scope: str, full_since_repair: bool, repair_rounds: int, scope_ratio: float | None) -> dict[str, object]:
    """Next review scope. ``full_since_repair``: a full-scope pass already ran after the first repair."""

    def result(scope: str, reason: str) -> dict[str, object]:
        reviews_repaired_tree = scope in ("full", "final-full") and repair_rounds > 0
        return {"next": scope, "reason": reason, "full_since_repair": full_since_repair or reviews_repaired_tree}

    if event == "start":
        return result("full", "first pass reviews the whole change")
    if event == "background-full":
        if mode == "full":
            return {"next": "none", "reason": "legacy full mode", "full_since_repair": full_since_repair}
        if repair_rounds < 2:
            raise ScopeError("background-full needs repair_rounds >= 2")
        return {"next": "none", "reason": "a background full pass covered the tree after an earlier repair", "full_since_repair": True}
    if mode == "full":
        return result("done", "legacy full mode: clean pass") if event == "clean" else result("full", "legacy full mode: every pass is full")
    if event == "mechanical":
        return result("delta", "mechanical changes only")
    if event == "repaired":
        if scope_ratio is not None and scope_ratio >= FULL_SCOPE_RATIO:
            return result("full", f"delta plus neighbours cover {scope_ratio:.0%} of the change; a full pass costs the same")
        return result("delta", "review the repair delta and its neighbours")
    if event == "clean":
        if last_scope in ("full", "final-full"):
            return result("done", "a full-scope pass is clean")
        if last_scope == "delta":
            if full_since_repair or repair_rounds == 0:
                return result("done", "the whole tree has had a full-scope review since its last repair")
            return result("final-full", "repairs were only delta-reviewed; one full pass must certify the whole tree")
    raise ScopeError(f"cannot decide for event={event!r} last_scope={last_scope!r}")


def _bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes")


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    snap = sub.add_parser("snapshot", help="print a tree id of the working-tree state")
    snap.add_argument("--worktree", required=True)

    mat = sub.add_parser("materialize", help="check a snapshot out into a detached linked worktree")
    mat.add_argument("--worktree", required=True)
    mat.add_argument("--snapshot", required=True, help="snapshot tree id")
    mat.add_argument("--path", required=True, help="new checkout path; must not exist")

    rel = sub.add_parser("release", help="remove a materialized checkout")
    rel.add_argument("--worktree", required=True)
    rel.add_argument("--path", required=True)

    delta = sub.add_parser("delta", help="repair delta between a pre-repair snapshot and now")
    delta.add_argument("--worktree", required=True)
    delta.add_argument("--review-base", required=True)
    delta.add_argument("--snapshot", required=True, help="pre-repair snapshot id")
    delta.add_argument("--max-related", type=int, default=DEFAULT_MAX_RELATED)

    nxt = sub.add_parser("decide", help="next review scope")
    nxt.add_argument("--event", required=True, choices=("start", "repaired", "mechanical", "clean", "background-full"))
    nxt.add_argument("--mode", default=None, help="delta|full; defaults to $MAKATO_REVIEW_SCOPE")
    nxt.add_argument("--last-scope", default="none", choices=("none", "full", "delta", "final-full"))
    nxt.add_argument("--full-since-repair", default="false")
    nxt.add_argument("--repair-rounds", type=int, default=0)
    nxt.add_argument("--scope-ratio", type=float, default=None)

    args = parser.parse_args(argv)
    try:
        if args.command == "snapshot":
            print(json.dumps({"snapshot": snapshot(args.worktree)}))
        elif args.command == "delta":
            print(json.dumps(build_delta(args.worktree, args.review_base, args.snapshot, args.max_related)))
        elif args.command == "materialize":
            print(json.dumps(materialize(args.worktree, args.snapshot, args.path)))
        elif args.command == "release":
            release(args.worktree, args.path)
            print(json.dumps({"released": True}))
        else:
            mode, warning = resolve_mode(args.mode if args.mode is not None else os.environ.get("MAKATO_REVIEW_SCOPE"))
            outcome = decide(args.event, mode, args.last_scope, _bool(args.full_since_repair), args.repair_rounds, args.scope_ratio)
            outcome["mode"] = mode
            if warning:
                outcome["warning"] = warning
            print(json.dumps(outcome))
    except ScopeError as exc:
        print(f"review-scope: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
