#!/usr/bin/env bash
# promote-lessons.sh — lift scope:generalizable lessons from per-issue stores
# into the committed .makato/memory/procedural.jsonl for long-term retention.
#
# Two per-issue sources are read. The spec folder is matched by three name
# shapes so BOTH lane conventions resolve: `<N>-<slug>` (new-work, number-first,
# e.g. 470-persistent-memory), `<slug>-<N>` (change lane, number-last), and the
# bare `<N>`:
#   a. specs/{<N>-*,*-<N>,<N>}/workflow-state-<ISSUE_NUMBER>.json → .lessons_learned[]
#   b. specs/{<N>-*,*-<N>,<N>}/change-lessons.jsonl (if exists) → line-by-line
#
# Only records with scope=="generalizable" are promoted. Records lacking a
# scope field are silently skipped. Each promoted record is routed by its
# `tier` field: tier=="semantic" → SEMANTIC_MEMORY_FILE, anything else (or an
# absent tier) → MEMORY_FILE (procedural). Dedup is by
# hash(normalized_text + sorted_tags), applied independently per target file:
# an existing record with a matching key has its occurrences bumped; new records
# are appended with occurrences=1.
#
# Usage:
#   promote-lessons.sh <ISSUE_NUMBER> [SPECS_DIR] [MEMORY_FILE] [SEMANTIC_MEMORY_FILE]
#
#   ISSUE_NUMBER         integer (required)
#   SPECS_DIR            path to specs/ root (default: specs)
#   MEMORY_FILE          path to .makato/memory/procedural.jsonl
#                        (default: .makato/memory/procedural.jsonl)
#   SEMANTIC_MEMORY_FILE path to .makato/memory/semantic.jsonl
#                        (default: .makato/memory/semantic.jsonl)
#
# Environment overrides (tests):
#   MAKATO_PROMOTE_REPO_OVERRIDE   Override the repo slug (e.g. "owner/repo").
#                                  When set, used instead of `git remote get-url`.
#
# Exit codes:
#   0   success — including no-op when no generalizable records found
#   non-zero — only on file I/O errors (Python/bash set -e propagation)
set -euo pipefail

ISSUE_NUMBER="${1:?usage: promote-lessons.sh <ISSUE_NUMBER> [SPECS_DIR] [MEMORY_FILE]}"
SPECS_DIR="${2:-specs}"
MEMORY_FILE="${3:-.makato/memory/procedural.jsonl}"
SEMANTIC_MEMORY_FILE="${4:-.makato/memory/semantic.jsonl}"

# ---------------------------------------------------------------------------
# _log <msg…> — stderr diagnostic
# ---------------------------------------------------------------------------
_log() { echo "promote-lessons: $*" >&2; }

# ---------------------------------------------------------------------------
# Resolve repo slug from git remote (or test override).
# ---------------------------------------------------------------------------
_repo_slug() {
  if [[ -n "${MAKATO_PROMOTE_REPO_OVERRIDE:-}" ]]; then
    echo "$MAKATO_PROMOTE_REPO_OVERRIDE"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$url" ]]; then
    echo "unknown/unknown"
    return 0
  fi
  # Normalize https://github.com/owner/repo.git and git@github.com:owner/repo.git
  # to owner/repo.
  echo "$url" \
    | sed 's|.*github\.com[:/]\(.*\)|\1|' \
    | sed 's|\.git$||'
}

# ---------------------------------------------------------------------------
# Ensure the MEMORY_FILE parent directory exists.
# ---------------------------------------------------------------------------
MEMORY_DIR="$(dirname "$MEMORY_FILE")"
mkdir -p "$MEMORY_DIR"

# Touch MEMORY_FILE if it does not exist yet.
[[ -f "$MEMORY_FILE" ]] || : > "$MEMORY_FILE"

# Same for the semantic store (tier==semantic routing target).
SEMANTIC_MEMORY_DIR="$(dirname "$SEMANTIC_MEMORY_FILE")"
mkdir -p "$SEMANTIC_MEMORY_DIR"
[[ -f "$SEMANTIC_MEMORY_FILE" ]] || : > "$SEMANTIC_MEMORY_FILE"

# ---------------------------------------------------------------------------
# Collect all candidate input files for this ISSUE_NUMBER:
#   - workflow-state-<N>.json files under matching spec folders
#   - change-lessons.jsonl files under matching spec folders
# ---------------------------------------------------------------------------
WS_FILES=()
CL_FILES=()

while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  WS="$dir/workflow-state-${ISSUE_NUMBER}.json"
  CL="$dir/change-lessons.jsonl"
  [[ -f "$WS" ]] && WS_FILES+=("$WS")
  [[ -f "$CL" ]] && CL_FILES+=("$CL")
done < <(find "$SPECS_DIR" -maxdepth 1 -mindepth 1 -type d \
           \( -name "*-${ISSUE_NUMBER}" -o -name "${ISSUE_NUMBER}-*" -o -name "${ISSUE_NUMBER}" \) 2>/dev/null \
         | sort || true)

# When no source files exist, exit cleanly (no-op).
if [[ "${#WS_FILES[@]}" -eq 0 && "${#CL_FILES[@]}" -eq 0 ]]; then
  _log "no source files for issue #${ISSUE_NUMBER} under ${SPECS_DIR} — nothing to promote"
  exit 0
fi

REPO_SLUG="$(_repo_slug)"

# ---------------------------------------------------------------------------
# Python: load candidates, dedup against existing MEMORY_FILE, write atomically.
# ---------------------------------------------------------------------------
REPO_SLUG="$REPO_SLUG" \
ISSUE_NUMBER="$ISSUE_NUMBER" \
MEMORY_FILE="$MEMORY_FILE" \
SEMANTIC_MEMORY_FILE="$SEMANTIC_MEMORY_FILE" \
python3 - "${WS_FILES[@]+"${WS_FILES[@]}"}" -- "${CL_FILES[@]+"${CL_FILES[@]}"}" <<'PYEOF'
import datetime
import hashlib
import json
import os
import re
import sys
import tempfile

issue_number = int(os.environ["ISSUE_NUMBER"])
memory_file = os.environ["MEMORY_FILE"]
semantic_memory_file = os.environ["SEMANTIC_MEMORY_FILE"]
repo_slug = os.environ.get("REPO_SLUG", "unknown/unknown")

# Split argv on the '--' separator: before it are WS files; after are CL files.
args = sys.argv[1:]
try:
    sep_idx = args.index("--")
    ws_files = args[:sep_idx]
    cl_files = args[sep_idx + 1:]
except ValueError:
    ws_files = args
    cl_files = []

# ---------------------------------------------------------------------------
# Collect raw candidate records from all input sources.
# ---------------------------------------------------------------------------
candidates = []

# Source A: workflow-state-<N>.json → .lessons_learned[]
# Schema: {ts, cycle, trigger, description, files_affected} — body field is `description`.
# Normalise to `text` so both sources share the same field name downstream.
for path in ws_files:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        print(f"promote-lessons: WARNING skipping {path}: {exc}", file=sys.stderr)
        continue
    for entry in data.get("lessons_learned") or []:
        if not isinstance(entry, dict):
            continue
        # Normalise: copy `description` → `text` so later logic uses one key.
        if "description" in entry and "text" not in entry:
            entry = dict(entry)
            entry["text"] = entry["description"]
        candidates.append(entry)

# Source B: change-lessons.jsonl → one JSON object per line
for path in cl_files:
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    if isinstance(entry, dict):
                        candidates.append(entry)
                except json.JSONDecodeError:
                    print(f"promote-lessons: WARNING malformed line in {path}: {line!r}", file=sys.stderr)
    except Exception as exc:
        print(f"promote-lessons: WARNING skipping {path}: {exc}", file=sys.stderr)
        continue

# ---------------------------------------------------------------------------
# Filter: only scope == "generalizable".
# ---------------------------------------------------------------------------
generalizable = [c for c in candidates if c.get("scope") == "generalizable"]

if not generalizable:
    # Nothing to do — exit cleanly without rewriting the memory file.
    sys.exit(0)

# ---------------------------------------------------------------------------
# Load existing records from a store file, plus a dedup index. Malformed lines
# are preserved verbatim (never corrupt the file). Missing file → empty store.
# ---------------------------------------------------------------------------
def load_store(path):
    records = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    if isinstance(rec, dict):
                        records.append(rec)
                except json.JSONDecodeError:
                    # Preserve malformed lines (do not corrupt the file).
                    records.append({"_raw": line})
    except FileNotFoundError:
        pass
    # Index existing records by their dedup key for O(1) lookup.
    key_to_idx = {}
    for idx, rec in enumerate(records):
        if "key" in rec:
            key_to_idx[rec["key"]] = idx
    return records, key_to_idx


# Two independent target stores, routed by the record's `tier` field.
procedural_records, procedural_idx = load_store(memory_file)
semantic_records, semantic_idx = load_store(semantic_memory_file)

# Map a resolved tier → (records list, dedup index, dirty flag holder).
stores = {
    "procedural": {"records": procedural_records, "idx": procedural_idx,
                   "path": memory_file, "dirty": False},
    "semantic": {"records": semantic_records, "idx": semantic_idx,
                 "path": semantic_memory_file, "dirty": False},
}

# ---------------------------------------------------------------------------
# Helper functions.
# ---------------------------------------------------------------------------
# Normalization: lowercase, collapse whitespace, strip non-alphanumeric
def normalize_text(text: str) -> str:
    t = text.lower()
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"[^a-z0-9 ]", "", t)
    return t.strip()


# Dedup key: hash of normalized text + sorted tags (Q6)
def compute_key(text: str, tags: list) -> str:
    normalized = normalize_text(text)
    sorted_tags = sorted(str(t) for t in tags)
    payload = normalized + json.dumps(sorted_tags, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# repo_sha source: git rev-parse --short HEAD
def get_repo_sha() -> str:
    import subprocess
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else "unknown"
    except Exception:
        return "unknown"


today_str = datetime.date.today().isoformat()
repo_sha = get_repo_sha()

# ---------------------------------------------------------------------------
# Process each generalizable candidate, routing by its `tier` field:
#   tier == "semantic"  → semantic store
#   tier == "procedural" or absent → procedural store (legacy default)
# Dedup + occurrences-bump is applied independently per target store.
# ---------------------------------------------------------------------------
for candidate in generalizable:
    text = candidate.get("text", "")
    tags = candidate.get("tags") or []
    if not isinstance(tags, list):
        tags = []

    # Resolve the target tier. Absent/any-other value defaults to procedural
    # so legacy behaviour is byte-for-byte preserved.
    resolved_tier = "semantic" if candidate.get("tier") == "semantic" else "procedural"
    store = stores[resolved_tier]
    records = store["records"]
    key_to_idx = store["idx"]

    # Extract key field from spec folder path context; fall back to issue number.
    key_field = candidate.get("key", f"{issue_number}")

    dedup_key = compute_key(text, tags)

    if dedup_key in key_to_idx:
        # Bump occurrences on the existing record.
        idx = key_to_idx[dedup_key]
        records[idx]["occurrences"] = records[idx].get("occurrences", 1) + 1
    else:
        # Append a new record.
        new_record = {
            "ts": datetime.datetime.utcnow().isoformat() + "Z",
            "tier": resolved_tier,
            "repo": repo_slug,
            "key": key_field,
            "text": text,
            "tags": tags,
            "scope": "generalizable",
            "occurrences": 1,
            "source_issue": issue_number,
            # repo_sha source: git rev-parse --short HEAD
            "repo_sha": repo_sha,
            "date": today_str,
        }
        key_to_idx[dedup_key] = len(records)
        new_record["key"] = dedup_key
        records.append(new_record)
    store["dirty"] = True


# ---------------------------------------------------------------------------
# Atomic write: write to a sibling tmp file then mv over the target. Only
# stores that received a promoted record this run are rewritten — a store with
# no new records is left untouched on disk.
# ---------------------------------------------------------------------------
def write_store(path, records):
    memory_dir = os.path.dirname(path)
    os.makedirs(memory_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=memory_dir, prefix=".promote-lessons-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for rec in records:
                if "_raw" in rec and len(rec) == 1:
                    fh.write(rec["_raw"] + "\n")
                else:
                    fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


for store in stores.values():
    if store["dirty"]:
        write_store(store["path"], store["records"])
PYEOF
