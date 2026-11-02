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
from collections.abc import Iterable
from pathlib import Path, PurePosixPath

SCOPE_MODES = ("delta", "full")
FULL_SCOPE_RATIO = 0.6
DEFAULT_MAX_RELATED = 25
MAX_TEXT_BYTES = 2_000_000
GENERIC_STEMS = frozenset({"index", "main", "types", "utils", "config", "constants", "mod", "lib"})
JS_SUFFIXES = frozenset({".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"})
TEST_SUFFIXES = (".test", ".spec", "_test", "_spec")
REVIEW_CONTRACT_VERSION = 3
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
    "shared/review_audit.py",
    "shared/spec_folder.py",
    "shared/review_loop.py",
    "shared/review_runtime.py",
    "shared/skill_execution.py",
    "shared/review_scope.py",
    "scripts/run-skill.py",
    "AUTONOMOUS-MODE.md",
    ".claude-plugin/plugin.json",
    "shared/build-log.sh",
    "shared/default-branch.sh",
    "orchestrate:.claude-plugin/plugin.json",
    "orchestrate:shared/progress-comment.sh",
    "orchestrate:scripts/task_schedule.py",
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
    """Merge-base changes, untracked files and raw changes hidden by Git filters."""
    tracked = _nul_split(_git(worktree, "diff", "--name-only", "--no-renames", "-z", review_base))
    untracked = _nul_split(_git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
    changed = set(tracked) | set(untracked)
    for record in _nul_split(_git(worktree, "ls-tree", "-r", "-z", review_base)):
        metadata, path = record.split("\t", 1)
        base_mode, kind, base_oid = metadata.split()
        if path in changed or kind != "blob":
            continue
        full = Path(worktree) / path
        try:
            before = full.lstat()
            raw = hashlib.new("sha1" if len(base_oid) == 40 else "sha256", usedforsecurity=False)
            if stat.S_ISLNK(before.st_mode):
                content = os.fsencode(os.readlink(full))
                mode = "120000"
                raw.update(f"blob {len(content)}\0".encode())
                raw.update(content)
            elif stat.S_ISREG(before.st_mode):
                mode = "100755" if before.st_mode & 0o111 else "100644"
                raw.update(f"blob {before.st_size}\0".encode())
                with full.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        raw.update(chunk)
            else:
                changed.add(path)
                continue
            after = full.lstat()
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
                raise ScopeError(f"scope file changed while being read: {path!r}")
        except (FileNotFoundError, NotADirectoryError):
            changed.add(path)
            continue
        except OSError as exc:
            raise ScopeError(f"cannot read raw review input {path!r}: {exc}") from exc
        if mode != base_mode or raw.hexdigest() != base_oid:
            changed.add(path)
    return sorted(changed)


def contract_input(
    argument: str,
    contract_root: str | Path,
    orchestrate_root: str | Path | None = None,
) -> tuple[str, str, Path]:
    """Dispatch an exact contract argument to its manifest label and canonical root."""
    if not isinstance(argument, str):
        raise ScopeError("contract path must be a string")
    source = "orchestrate" if argument.startswith("orchestrate:") else "contract"
    relative = argument[len("orchestrate:") :] if source == "orchestrate" else argument
    if not relative or "\\" in relative or ":" in relative or any(part in ("", ".", "..") for part in relative.split("/")):
        raise ScopeError(f"invalid contract path: {argument!r}")
    if source == "contract" and relative.startswith("skills/build-review/shared/"):
        raise ScopeError("contract inputs must use canonical shared paths, not the skill alias")
    root = orchestrate_root if source == "orchestrate" else contract_root
    if not root:
        raise ScopeError(f"{source} root is required for {argument!r}")
    return source, relative, Path(root).resolve()


def _root_identity(root: str | Path) -> dict:
    path = Path(root).resolve()
    try:
        info = path.stat()
        if not stat.S_ISDIR(info.st_mode):
            raise ScopeError(f"contract root is not a directory: {path}")
        return {"path": str(path), "dev": info.st_dev, "ino": info.st_ino}
    except OSError as exc:
        raise ScopeError(f"contract root unavailable: {path}: {exc}") from exc


def root_bindings(contract_root: str | Path, orchestrate_root: str | Path) -> dict:
    """Capture physical directory identity separately from source-content identity."""
    if not contract_root or not orchestrate_root:
        raise ScopeError("explicit build and orchestrate roots are required")
    return {"build": _root_identity(contract_root), "orchestrate": _root_identity(orchestrate_root)}


def _contract_record(source: str, relative: str, root: Path, *, required: bool) -> dict:
    full = root / relative
    try:
        if required:
            current = root
            for component in relative.split("/"):
                current /= component
                if current.is_symlink():
                    raise ScopeError(f"required contract has a symlink component: {relative!r}")
            if not full.resolve().is_relative_to(root):
                raise ScopeError(f"required contract escapes its root: {relative!r}")
        before = full.stat()
        if not stat.S_ISREG(before.st_mode):
            raise ScopeError(f"contract is not a regular file: {relative!r}")
        hasher = hashlib.sha256()
        with full.open("rb") as handle:
            opened = os.fstat(handle.fileno())
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
            finished = os.fstat(handle.fileno())
        after = full.stat()

        def identity(info):
            return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_mode)

        if not identity(before) == identity(opened) == identity(finished) == identity(after):
            raise ScopeError(f"contract changed while being read: {relative!r}")
        if required:
            current = root
            for component in relative.split("/"):
                current /= component
                if current.is_symlink():
                    raise ScopeError(f"required contract has a symlink component: {relative!r}")
        return {"path": f"{source}:{relative}", "kind": "file", "mode": stat.S_IMODE(after.st_mode), "sha256": hasher.hexdigest()}
    except OSError as exc:
        raise ScopeError(f"contract file unavailable: {relative!r}: {exc}") from exc


def contract_inventory(
    contract_root: str | Path,
    contract_paths: list[str] | tuple[str, ...] | None = None,
    *,
    orchestrate_root: str | Path | None = None,
) -> list[dict]:
    """Read ordered content/kind/mode records, rejecting a root switch during reads."""
    paths = REVIEW_CONTRACT_PATHS if contract_paths is None else contract_paths
    contract_root = Path(contract_root).resolve()
    orchestrate_root = Path(orchestrate_root).resolve() if orchestrate_root else None
    inputs = [(argument, *contract_input(argument, contract_root, orchestrate_root)) for argument in dict.fromkeys(paths)]
    roots = {source: root for _, source, _, root in inputs}
    before = {source: _root_identity(root) for source, root in roots.items()}
    records = [_contract_record(source, relative, selected, required=argument in REVIEW_CONTRACT_PATHS) for argument, source, relative, selected in inputs]
    after = {source: _root_identity(root) for source, root in roots.items()}
    if before != after:
        raise ScopeError("contract root changed while reading inventory")
    return records


def resolve_active_roots(
    execution_root: str | Path,
    environment: dict[str, str],
    orchestrate_root: str | Path | None = None,
) -> dict:
    """Resolve the executing installation; implicit siblings require suite Git proof."""
    build = Path(execution_root).resolve()
    own = _root_identity(build)
    exported_build = environment.get("MAKATO_BUILD_ROOT")
    if exported_build and _root_identity(exported_build) != own:
        raise ScopeError("exported build root differs from the executing installation")
    exported_orchestrate = environment.get("MAKATO_ORCHESTRATE_ROOT")
    if orchestrate_root and exported_orchestrate and _root_identity(orchestrate_root) != _root_identity(exported_orchestrate):
        raise ScopeError("explicit and exported orchestrate roots disagree")
    selected = orchestrate_root or exported_orchestrate
    if not selected:
        if build.name != "makato-build" or build.parent.name != "plugins":
            raise ScopeError("installed build requires an explicit orchestrate root")
        suite = build.parent.parent
        git_env = dict(environment)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES"):
            git_env.pop(key, None)
        top = Path(_git(str(suite), "rev-parse", "--show-toplevel", env=git_env).decode().strip()).resolve()
        if top != suite:
            raise ScopeError("implicit roots require the suite Git toplevel")
        _git(
            str(suite),
            "ls-files",
            "--error-unmatch",
            ".claude-plugin/marketplace.json",
            "plugins/makato-build/.claude-plugin/plugin.json",
            "plugins/makato-orchestrate/.claude-plugin/plugin.json",
            env=git_env,
        )
        try:
            marketplace = json.loads((suite / ".claude-plugin/marketplace.json").read_text())
            entries = marketplace["plugins"]
            if marketplace["name"] != "makato-suite" or any(
                [item.get("source") for item in entries if item.get("name") == name] != [f"./plugins/{name}"] for name in ("makato-build", "makato-orchestrate")
            ):
                raise ScopeError("implicit roots require the canonical suite marketplace")
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise ScopeError(f"invalid suite marketplace: {exc}") from exc
        sibling = suite / "plugins/makato-orchestrate"
        if any(path.is_symlink() for path in (suite / "plugins", sibling)) or sibling.resolve() != sibling:
            raise ScopeError("implicit orchestrate root has a symlink component")
        selected = sibling
    orchestrate = Path(selected).resolve()
    before = root_bindings(build, orchestrate)
    shared = orchestrate / "shared"
    exported_shared = environment.get("MAKATO_ORCHESTRATE_SHARED")
    if exported_shared and _root_identity(exported_shared) != _root_identity(shared):
        raise ScopeError("exported orchestrate shared directory disagrees")
    contract_inventory(build, orchestrate_root=orchestrate)
    for path, name in ((build, "makato-build"), (orchestrate, "makato-orchestrate")):
        try:
            if json.loads((path / ".claude-plugin/plugin.json").read_text()).get("name") != name:
                raise ScopeError(f"plugin manifest must name {name}")
        except (OSError, ValueError, AttributeError) as exc:
            raise ScopeError(f"invalid plugin manifest for {name}: {exc}") from exc
    if root_bindings(build, orchestrate) != before:
        raise ScopeError("active roots changed while resolving")
    return {"build": str(build), "orchestrate": str(orchestrate), "shared": str(shared.resolve()), "root_bindings": before}


def fingerprint(
    worktree: str,
    review_base: str,
    *,
    context_paths: list[str] | None = None,
    contract_paths: list[str] | None = None,
    evidence_root: str | None = None,
    contract_root: str | None = None,
    orchestrate_root: str | None = None,
) -> dict[str, object]:
    """Hash branch bytes plus explicit context/spec/contract files."""
    base_oid = _git(worktree, "rev-parse", "--verify", f"{review_base}^{{commit}}").decode().strip()
    changed = changed_files(worktree, review_base)
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
    for record in contract_inventory(contract_root, contracts, orchestrate_root=orchestrate_root):
        manifest_files.append({**record, "changed": False, "context": False, "contract": True})
    manifest = {
        "schema": "review-input-fingerprint-v2",
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


def snapshot(worktree: str, *, raw_paths: Iterable[str] = ()) -> str:
    """Capture the complete live tracked/untracked tree as raw bytes.

    Even Git-clean committed files can differ from their blobs after smudge,
    line-ending or encoding conversion. Every producer uses the same raw tree;
    the private index never changes the caller's real index.
    """
    with tempfile.TemporaryDirectory(prefix="makato-snapshot-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": os.path.join(tmp, "index")}
        _git(worktree, "read-tree", "HEAD", env=env)
        tracked = _nul_split(_git(worktree, "ls-files", "--cached", "-z"))
        tracked += _nul_split(_git(worktree, "ls-tree", "-r", "--name-only", "-z", "HEAD"))
        untracked = _nul_split(_git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
        paths = sorted(set(tracked) | set(untracked) | set(raw_paths))
        removed = []
        entries = []
        null_oid = "0" * len(_git(worktree, "rev-parse", "HEAD").strip())
        for path in paths:
            pure = PurePosixPath(path)
            if not path or pure.is_absolute() or any(part in ("", ".", "..") or part.casefold() == ".git" for part in path.split("/")):
                raise ScopeError(f"snapshot path must be repository-relative: {path!r}")
            encoded = path.encode("utf-8", errors="surrogateescape")
            removed.append(b"0 " + null_oid.encode() + b"\t" + encoded + b"\0")
            full = os.path.join(worktree, path)
            parent = Path(worktree)
            for component in pure.parts[:-1]:
                parent /= component
                if parent.is_symlink():
                    raise ScopeError(f"snapshot path has a symlink ancestor: {path!r}")
            try:
                before = os.lstat(full)
                if stat.S_ISLNK(before.st_mode):
                    content = os.readlink(full).encode("utf-8", errors="surrogateescape")
                    mode, oid = "120000", _git(worktree, "hash-object", "-w", "--no-filters", "--stdin", stdin=content).strip()
                elif stat.S_ISREG(before.st_mode):
                    mode = "100755" if before.st_mode & 0o111 else "100644"
                    oid = _git(worktree, "hash-object", "-w", "--no-filters", "--", path).strip()
                elif stat.S_ISDIR(before.st_mode):
                    if not os.path.exists(os.path.join(full, ".git")):
                        # A displaced historical file is removed; live children
                        # are collected independently from the index/untracked set.
                        continue
                    mode, oid = "160000", _git(full, "rev-parse", "HEAD").strip()
                else:
                    raise ScopeError(f"unsupported snapshot file kind: {path!r}")
                after = os.lstat(full)
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode):
                    raise ScopeError(f"snapshot file changed while being read: {path!r}")
            except (FileNotFoundError, NotADirectoryError):
                if os.path.lexists(full):
                    raise ScopeError(f"snapshot file changed while being read: {path!r}") from None
                continue
            except OSError as exc:
                raise ScopeError(f"cannot snapshot {path!r}: {exc}") from exc
            entries.append(mode.encode() + b" " + oid + b"\t" + encoded + b"\0")
        if paths:
            # Remove first so file/directory replacements cannot leave stale entries.
            _git(worktree, "update-index", "-z", "--index-info", env=env, stdin=b"".join(removed + entries))
        return _git(worktree, "write-tree", env=env).decode().strip()


def snapshot_delta(worktree: str, pre: str, post: str) -> list[dict[str, str]]:
    """Files whose content differs between two snapshots, as {path, status} (A/M/D/T)."""
    raw = _git(worktree, "diff-tree", "-r", "--no-renames", "--name-status", "-z", pre, post)
    tokens = _nul_split(raw)
    return [{"status": tokens[i], "path": tokens[i + 1]} for i in range(0, len(tokens) - 1, 2)]


def materialize(worktree: str, snapshot_tree: str, path: str) -> dict[str, str]:
    """Populate a detached consumer with raw blobs, never checkout transforms."""
    if os.path.lexists(path):
        raise ScopeError(f"materialize target exists: {path}")
    records = []
    for record in _nul_split(_git(worktree, "ls-tree", "-r", "-z", snapshot_tree)):
        metadata, relative = record.split("\t", 1)
        mode, kind, oid = metadata.split()
        if any(part in ("", ".", "..") or part.casefold() == ".git" for part in relative.split("/")) or PurePosixPath(relative).is_absolute():
            raise ScopeError(f"unsafe materialized path: {relative!r}")
        if kind != "blob" or mode not in ("100644", "100755", "120000"):
            raise ScopeError(f"unsupported materialized snapshot entry: {relative!r}")
        records.append((relative, mode, oid))
    commit = _git(worktree, "commit-tree", snapshot_tree, "-p", "HEAD", "-m", "makato review snapshot").decode().strip()
    env = {key: value for key, value in os.environ.items() if key not in ("GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR")}
    _git(worktree, "worktree", "add", "--detach", "--no-checkout", path, commit, env=env)
    try:
        _git(path, "read-tree", snapshot_tree, env=env)
        expected = {}
        for relative, mode, oid in records:
            full = Path(path) / relative
            full.parent.mkdir(parents=True, exist_ok=True)
            content = _git(worktree, "cat-file", "blob", oid)
            if mode == "120000":
                full.symlink_to(os.fsdecode(content))
            else:
                full.write_bytes(content)
                full.chmod(0o755 if mode == "100755" else 0o644)
            expected[relative] = (mode, hashlib.sha256(content).hexdigest())
        actual = {}
        for directory, dirs, files in os.walk(path, followlinks=False):
            for name in dirs[:]:
                if (Path(directory) / name).is_symlink():
                    dirs.remove(name)
                    files.append(name)
            for name in files:
                full = Path(directory) / name
                relative = full.relative_to(path).as_posix()
                if relative == ".git":
                    continue
                before = full.lstat()
                if stat.S_ISLNK(before.st_mode):
                    mode, content = "120000", os.fsencode(os.readlink(full))
                elif stat.S_ISREG(before.st_mode):
                    mode, content = ("100755" if before.st_mode & 0o111 else "100644"), full.read_bytes()
                else:
                    raise ScopeError(f"unsafe materialized file kind: {relative!r}")
                after = full.lstat()
                if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode):
                    raise ScopeError(f"materialized file changed while being verified: {relative!r}")
                actual[relative] = (mode, hashlib.sha256(content).hexdigest())
        if actual != expected:
            raise ScopeError("materialized tree differs from the complete raw snapshot")
    except BaseException:
        release(worktree, path)
        raise
    return {"path": path, "commit": commit}


def release(worktree: str, path: str) -> None:
    """Remove a materialized checkout; an already-removed one is not an error."""
    try:
        _git(worktree, "worktree", "remove", "--force", path)
    except ScopeError:
        if os.path.exists(path):
            raise
        _git(worktree, "worktree", "prune")


def _read_text(worktree: str, path: str, snapshot_tree: str | None = None) -> str | None:
    full = os.path.join(worktree, path)
    if snapshot_tree is not None:
        try:
            size = int(_git(worktree, "cat-file", "-s", f"{snapshot_tree}:{path}"))
            if size > MAX_TEXT_BYTES:
                return None
            return _git(worktree, "show", f"{snapshot_tree}:{path}").decode("utf-8")
        except (ScopeError, UnicodeDecodeError, ValueError):
            return None
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


def related_files(worktree: str, delta_paths: list[str], candidates: list[str], max_related: int = DEFAULT_MAX_RELATED, *, snapshot_tree: str | None = None) -> tuple[list[dict[str, str]], bool]:
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
        text = _read_text(worktree, candidate, snapshot_tree)
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


def checkpoint_scope(worktree: str, manifest: dict, post: str, *, previous: dict | None = None, invariant_paths: Iterable[str] = ()) -> dict:
    """Derive checkpoint authority from source trees/manifests, never reviewer scope claims."""
    base = manifest["base"]
    changed = set(manifest["changed_files"])
    # Raw normalization can also change Git-clean baseline blobs. Those extra
    # paths must match the live source exactly, never arbitrary uncited entries.
    raw_delta = {item["path"] for item in snapshot_delta(worktree, base, post)}
    if not changed.issubset(raw_delta):
        raise ScopeError("checkpoint snapshot does not match the source manifest")
    tree = {}
    for record in _nul_split(_git(worktree, "ls-tree", "-r", "-z", post)):
        metadata, path = record.split("\t", 1)
        tree[path] = metadata.split(" ", 1)[0]
    extra = raw_delta - changed
    if extra & set(changed_files(worktree, base)):
        raise ScopeError("checkpoint snapshot has unreviewed source manifest changes")
    for path in extra:
        full = Path(worktree) / path
        try:
            before = full.lstat()
        except OSError as exc:
            raise ScopeError(f"checkpoint snapshot extra path is unavailable: {path}") from exc
        if stat.S_ISLNK(before.st_mode):
            mode, content = "120000", os.fsencode(os.readlink(full))
        elif stat.S_ISREG(before.st_mode):
            mode, content = ("100755" if before.st_mode & 0o111 else "100644"), full.read_bytes()
        else:
            raise ScopeError(f"checkpoint snapshot has an unsafe extra path: {path}")
        after = full.lstat()
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode)
            or tree.get(path) != mode
            or _git(worktree, "show", f"{post}:{path}") != content
        ):
            raise ScopeError(f"checkpoint snapshot extra raw bytes or mode differ: {path}")
    for entry in manifest["files"]:
        if not entry["changed"]:
            continue
        path = entry["path"].removeprefix("worktree:")
        if entry["kind"] == "deleted":
            if path in tree:
                raise ScopeError(f"checkpoint snapshot retained deleted path: {path}")
            continue
        mode = tree.get(path)
        if mode is None or (mode == "120000") != (entry["kind"] == "symlink") or (mode != "120000" and (mode == "100755") != bool(entry["mode"] & 0o111)):
            raise ScopeError(f"checkpoint snapshot kind or mode differs from manifest: {path}")
        content = _git(worktree, "show", f"{post}:{path}")
        if hashlib.sha256(content).hexdigest() != entry["sha256"]:
            raise ScopeError(f"checkpoint snapshot bytes differ from manifest: {path}")
    pre = None if previous is None else previous["checkpoint_receipt"]["snapshot"]
    delta = {item["path"] for item in snapshot_delta(worktree, pre or base, post)}
    candidates = sorted(tree)
    related, truncated = related_files(worktree, sorted(delta), candidates, snapshot_tree=post)
    scope = delta | {item["path"] for item in related}
    # References in a changed caller also invalidate its unchanged dependencies.
    texts = [_read_text(worktree, path, post if path in tree else pre or base) for path in delta]
    for path in candidates:
        pattern = _reference_pattern(path)
        if any(text is not None and pattern.search(text) for text in texts):
            scope.add(path)
    explicit = [entry for entry in manifest["files"] if entry["context"] or entry["contract"]]
    old_explicit = None if previous is None else [entry for entry in previous["manifest"]["files"] if entry["context"] or entry["contract"]]
    if truncated or any(text is None for text in texts) or (previous is not None and explicit != old_explicit):
        scope.update(changed)
        scope.update(candidates if truncated or any(text is None for text in texts) else ())
    scope.update(entry["path"] for entry in explicit)
    scope.update(invariant_paths)
    return {"pre_snapshot": pre, "scope_files": sorted(scope)}


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
