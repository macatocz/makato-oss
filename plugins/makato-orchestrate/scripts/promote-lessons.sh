#!/usr/bin/env bash
# Promote generalizable workflow-state/change-lessons records into durable memory.
# Usage: promote-lessons.sh <ISSUE_NUMBER|SPEC_KEY> [SPECS_DIR] [MEMORY_FILE] [SEMANTIC_MEMORY_FILE]
# Defaults use the main git checkout; semantic memory is a sibling of MEMORY_FILE.
# Numeric lookup supports N, N-slug, slug-N and workflow-state-N.json in any spec.
# Exact spec keys take precedence over prefix/suffix matches.
#
# Raw records retain ts/tier/scope/text/tags/repo and recall metadata (bundle/label).
# `key` remains the normalized-text + sorted-tags hash in durable stores; the
# original story key is retained as source_key and in source_events[].key.
# Explicit issue_number identifies raw records in shared specs. Legacy records
# use an unambiguous story key or sole workflow-state identity. In a shared spec
# (multiple workflow-state files) a legacy record with none of these has UNKNOWN
# attribution: spec-key promotion keeps it (no issue_number/source_issue invented;
# path/key provenance retained); numeric promotion skips it with a stderr warning.
# source_events identifies captures by event_id when supplied, otherwise by
# source-relative path, raw-record fingerprint and identical-record ordinal.
# Replays do not increase occurrences; distinct captures do. Existing occurrence
# counts without provenance are retained, not reconstructed from guessed history.
#
# tier=semantic routes to semantic; all other/absent tiers retain procedural routing.
# Only scope=generalizable is promoted. Source files are never modified.
# Both stores are validated before writing and locked via <store>.lock across the
# complete read/merge/atomic-replace operation. Malformed input exits nonzero.
# MAKATO_TARGET_REPO_ROOT selects the target checkout (as in write-lessons.sh and
# workflow-state.sh); otherwise defaults resolve through git-common-dir.
# MAKATO_PROMOTE_REPO_OVERRIDE overrides the repository fallback for offline tests.
set -euo pipefail

KEY="${1:?usage: promote-lessons.sh <ISSUE_NUMBER|SPEC_KEY> [SPECS_DIR] [MEMORY_FILE] [SEMANTIC_MEMORY_FILE]}"
if [[ -n "${MAKATO_TARGET_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$MAKATO_TARGET_REPO_ROOT" 2>/dev/null && pwd -P)" || {
    echo "promote-lessons: target repository root is not a directory: $MAKATO_TARGET_REPO_ROOT" >&2
    exit 1
  }
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "promote-lessons: target repository root is not a git checkout: $REPO_ROOT" >&2
    exit 1
  }
else
  COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$COMMON_DIR" ]]; then
    REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
  else
    REPO_ROOT="$PWD"
  fi
fi
SPECS_DIR="${2:-$REPO_ROOT/specs}"
MEMORY_FILE="${3:-$REPO_ROOT/.makato/memory/procedural.jsonl}"
SEMANTIC_MEMORY_FILE="${4:-$(dirname "$MEMORY_FILE")/semantic.jsonl}"

python3 - "$KEY" "$SPECS_DIR" "$MEMORY_FILE" "$SEMANTIC_MEMORY_FILE" "$REPO_ROOT" <<'PYEOF'
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def git_value(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=5)
    return result.stdout.strip() if result.returncode == 0 else ""


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def dedup_key(text, tags):
    normalized = re.sub(r"[^a-z0-9 ]", "", re.sub(r"\s+", " ", text.lower())).strip()
    return digest(normalized + json.dumps(sorted(str(tag) for tag in tags), separators=(",", ":")))


def issue_from_key(key):
    parts = str(key or "").split("-")
    numbers = {int(part) for part in (parts[0], parts[-1]) if part.isdecimal()}
    return next(iter(numbers)) if len(numbers) == 1 else None


def parse_issue(value, path):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)) or int(value) < 1:
        raise ValueError(f"{path}: issue_number must be a positive integer")
    return int(value)


def read_jsonl(path):
    if not path.exists():
        return []
    records = []
    with path.open(encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_SH)
        lines = handle.read().splitlines()
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError as exc:
            raise ValueError(f"{path}:{number}: malformed JSON: {exc}") from exc
        if not isinstance(record, dict):
            raise ValueError(f"{path}:{number}: expected a JSON object")
        records.append(record)
    return records


def source_candidates(specs, key, repo_slug):
    if not specs.exists():
        return []
    issue = int(key) if key.isdecimal() else None
    folders = sorted(folder for folder in specs.iterdir() if folder.is_dir())
    if issue is None and (specs / key).is_dir():
        folders = [specs / key]
    else:
        folders = [folder for folder in folders if folder.name == key or folder.name.startswith(key + "-") or folder.name.endswith("-" + key)
                   or (issue is not None and (folder / f"workflow-state-{issue}.json").is_file())]
        if issue is None and len(folders) > 1:
            raise ValueError(f"spec key {key!r} matches multiple folders; use an exact spec key")
    candidates = []
    skipped = {}
    for folder in folders:
        state_paths = {int(match.group(1)): path for path in sorted(folder.glob("workflow-state-*.json"))
                       if (match := re.fullmatch(r"workflow-state-([0-9]+)\.json", path.name))}
        sources = []
        for state_issue, path in state_paths.items():
            if issue is not None and state_issue != issue:
                continue
            try:
                state = json.loads(path.read_text(encoding="utf-8"))
            except ValueError as exc:
                raise ValueError(f"{path}: malformed JSON: {exc}") from exc
            if not isinstance(state, dict) or not isinstance(state.get("lessons_learned", []), list):
                raise ValueError(f"{path}: expected an object with a lessons_learned array")
            if "issue_number" in state and parse_issue(state["issue_number"], path) != state_issue:
                raise ValueError(f"{path}: issue_number conflicts with workflow-state filename")
            sources.append((path, state.get("lessons_learned", []), state_issue, state.get("repo") or repo_slug))
        raw_path = folder / "change-lessons.jsonl"
        sources.append((raw_path, read_jsonl(raw_path), None, repo_slug))
        for path, entries, state_issue, source_repo in sources:
            repeated = {}
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ValueError(f"{path}: lesson must be a JSON object")
                fingerprint = digest(json.dumps(entry, sort_keys=True, separators=(",", ":")))
                repeated[fingerprint] = repeated.get(fingerprint, 0) + 1
                if entry.get("scope") != "generalizable":
                    continue
                entry_issue = state_issue
                if "issue_number" in entry:
                    entry_issue = parse_issue(entry["issue_number"], path)
                    if state_issue is not None and entry_issue != state_issue:
                        raise ValueError(f"{path}: lesson issue_number conflicts with workflow-state identity")
                unattributed = False
                if entry_issue is None:
                    if entry.get("key") != folder.name or len(state_paths) <= 1:
                        entry_issue = issue_from_key(entry.get("key"))
                    if entry_issue is None and len(state_paths) == 1:
                        entry_issue = next(iter(state_paths))
                    if entry_issue is None and len(state_paths) > 1:
                        unattributed = True
                    if entry_issue is None and not unattributed:
                        entry_issue = issue_from_key(folder.name) if issue is None else issue
                if unattributed and issue is not None:
                    skipped[path] = skipped.get(path, 0) + 1
                    continue
                if issue is not None and entry_issue != issue:
                    continue
                candidate = dict(entry)
                candidate["text"] = entry.get("text", entry.get("description", ""))
                if not isinstance(candidate["text"], str) or not candidate["text"].strip():
                    raise ValueError(f"{path}: generalizable lesson requires nonempty text or description")
                candidate["tags"] = entry.get("tags") or []
                if not isinstance(candidate["tags"], list):
                    raise ValueError(f"{path}: tags must be an array")
                candidate["repo"] = entry.get("repo") or source_repo
                candidate["source_key"] = entry.get("key") or folder.name
                candidate["tier"] = "semantic" if entry.get("tier") == "semantic" else "procedural"
                event = {"path": str(path.relative_to(specs)), "key": candidate["source_key"], "repo": candidate["repo"]}
                if entry_issue is not None:
                    event["issue_number"] = entry_issue
                for field in ("ts", "bundle", "label"):
                    if field in entry:
                        event[field] = entry[field]
                if "event_id" in entry:
                    if not isinstance(entry["event_id"], str) or not entry["event_id"]:
                        raise ValueError(f"{path}: event_id must be a nonempty string")
                    event["event_id"] = entry["event_id"]
                    identity = [candidate["repo"], "event_id", entry["event_id"]]
                else:
                    identity = [candidate["repo"], event["path"], fingerprint, repeated[fingerprint]]
                event["id"] = digest(json.dumps(identity, separators=(",", ":")))
                candidates.append((candidate, event))
    for path, count in skipped.items():
        print(f"promote-lessons: warning: skipped {count} legacy generalizable lesson(s) in {path.relative_to(specs)} "
              f"without issue_number in a shared spec; ambiguous for issue {issue} (promote by spec key to keep them unattributed)", file=sys.stderr)
    return candidates


def write_store(path, records):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".promote-lessons-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record, separators=(",", ":")) + "\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def promote(candidates, paths, repo_sha):
    with contextlib.ExitStack() as locks:
        # Lock stable sibling inodes, not the stores replaced by atomic rename.
        # A consistent order also covers callers using different store directories.
        for path in sorted(set(paths.values())):
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = locks.enter_context(Path(str(path) + ".lock").open("a", encoding="utf-8"))
            fcntl.flock(lock, fcntl.LOCK_EX)
        stores = {tier: read_jsonl(path) for tier, path in paths.items()}
        indexes = {tier: {record["key"]: record for record in records if isinstance(record.get("key"), str)} for tier, records in stores.items()}
        seen = {}
        for tier, records in stores.items():
            seen[tier] = set()
            for record in records:
                events = record.get("source_events", [])
                if not isinstance(events, list) or any(not isinstance(event, dict) or not isinstance(event.get("id"), str) for event in events):
                    raise ValueError(f"{paths[tier]}: malformed source_events provenance")
                seen[tier].update(event["id"] for event in events)
        dirty = set()
        now = datetime.datetime.now(datetime.timezone.utc)
        for candidate, event in candidates:
            tier = candidate["tier"]
            if event["id"] in seen[tier]:
                continue
            key = dedup_key(candidate["text"], candidate["tags"])
            record = indexes[tier].get(key)
            if record is None:
                record = dict(candidate)
                record.pop("event_id", None)
                record.pop("issue_number", None)
                record.update(key=key, occurrences=0, source_events=[], repo_sha=repo_sha, date=now.date().isoformat())
                record.setdefault("ts", now.isoformat().replace("+00:00", "Z"))
                if "issue_number" in event:
                    record["source_issue"] = event["issue_number"]
                stores[tier].append(record)
                indexes[tier][key] = record
            occurrences = record.get("occurrences", 1)
            if not isinstance(occurrences, int) or isinstance(occurrences, bool) or occurrences < 0:
                raise ValueError(f"{paths[tier]}: invalid occurrences for {key}")
            record["occurrences"] = occurrences + 1
            record.setdefault("source_events", []).append(event)
            # Existing annotations are authoritative; populate missing recall metadata.
            for field, value in candidate.items():
                if field not in {"key", "event_id", "issue_number"}:
                    record.setdefault(field, value)
            seen[tier].add(event["id"])
            dirty.add(tier)
        for tier, path in paths.items():
            if tier in dirty or not path.exists():
                write_store(path, stores[tier])


def main():
    key, specs_arg, procedural_arg, semantic_arg, root_arg = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", key):
        raise ValueError("expected an issue number or a single spec key, not a path")
    root = Path(root_arg)
    paths = {"procedural": Path(procedural_arg).resolve(), "semantic": Path(semantic_arg).resolve()}
    if paths["procedural"] == paths["semantic"]:
        raise ValueError("procedural and semantic stores must be different files")
    remote = git_value(root, "remote", "get-url", "origin")
    repo_slug = os.environ.get("MAKATO_PROMOTE_REPO_OVERRIDE") or re.sub(r"^.*github\.com[:/]", "", remote).removesuffix(".git") or "unknown/unknown"
    candidates = source_candidates(Path(specs_arg).resolve(), key, repo_slug)
    if not candidates:
        print(f"promote-lessons: no generalizable source events for {key}", file=sys.stderr)
        return
    promote(candidates, paths, git_value(root, "rev-parse", "--short", "HEAD") or "unknown")


try:
    main()
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    print(f"promote-lessons: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
