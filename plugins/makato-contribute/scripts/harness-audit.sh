#!/usr/bin/env bash
# harness-audit.sh — classify AGENTS.md sections and agent frontmatter
#
# Pure classification helper — no file mutation, stdout-only.
# Analogous to plugins/makato-orchestrate/scripts/lesson-prune.sh.
#
# Usage:
#   harness-audit.sh [REPO_ROOT]
#
#   REPO_ROOT   path to repository root (default: git rev-parse --show-toplevel)
#
# Output (stdout): one JSON object per finding:
#
#   AGENTS.md finding:
#     {"type":"agents-md","plugin":"<name>","section":"<heading>",
#      "lines":<N>,"refs":<N>,"action":"KEEP|BLOAT|REDUNDANT|MOVE-TO-SKILL",
#      "reason":"..."}
#
#   permissionMode finding:
#     {"type":"permission","plugin":"<name>","agent":"<name>",
#      "permissionMode":"<val>","disallowedTools":"<val>",
#      "action":"OK|MISSING_PM|READ_WRITE_MISMATCH","reason":"..."}
#
# Exit codes:
#   0   always (classification only — never errors on missing data)
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT (mirrors lesson-prune.sh logic).
# ---------------------------------------------------------------------------
if [[ -n "${1:-}" && "$1" != "--non-interactive" ]]; then
  REPO_ROOT="$1"
else
  GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$GIT_COMMON_DIR" ]]; then
    REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
  else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi

# ---------------------------------------------------------------------------
# _log <msg…> — stderr diagnostic
# ---------------------------------------------------------------------------
_log() { echo "harness-audit: $*" >&2; }

# ---------------------------------------------------------------------------
# Check for --non-interactive flag (anywhere in argv).
# ---------------------------------------------------------------------------
NON_INTERACTIVE=0
for _arg in "$@"; do
  [[ "$_arg" == "--non-interactive" ]] && NON_INTERACTIVE=1
done
# Export so python3 can see it (not actually used in classifier, but good practice).
export NON_INTERACTIVE

PLUGINS_DIR="$REPO_ROOT/plugins"

if [[ ! -d "$PLUGINS_DIR" ]]; then
  # Empty/missing plugins dir — exit 0 with no output.
  exit 0
fi

# ---------------------------------------------------------------------------
# Collect AGENTS.md and agent .md paths.
# ---------------------------------------------------------------------------
AGENTS_MD_LIST_FILE="$(mktemp)"
AGENT_FILES_LIST_FILE="$(mktemp)"
cleanup() {
  rm -f "$AGENTS_MD_LIST_FILE" "$AGENT_FILES_LIST_FILE"
}
trap cleanup EXIT

# Find all plugins/*/AGENTS.md (one level deep only).
find "$PLUGINS_DIR" -maxdepth 2 -name "AGENTS.md" 2>/dev/null | sort > "$AGENTS_MD_LIST_FILE" || true

# Find all plugins/*/agents/*.md (two levels deep).
find "$PLUGINS_DIR" -maxdepth 3 -path "*/agents/*.md" 2>/dev/null | sort > "$AGENT_FILES_LIST_FILE" || true

# ---------------------------------------------------------------------------
# Python: classify AGENTS.md sections and agent frontmatter; emit JSON per finding.
# ---------------------------------------------------------------------------
PLUGINS_DIR="$PLUGINS_DIR" \
AGENTS_MD_LIST_FILE="$AGENTS_MD_LIST_FILE" \
AGENT_FILES_LIST_FILE="$AGENT_FILES_LIST_FILE" \
python3 - <<'PYEOF'
import json
import os
import re
import sys

plugins_dir = os.environ.get("PLUGINS_DIR", "")
agents_md_list_file = os.environ.get("AGENTS_MD_LIST_FILE", "")
agent_files_list_file = os.environ.get("AGENT_FILES_LIST_FILE", "")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BLOAT_THRESHOLD = 150  # total lines in an AGENTS.md before bloat scanning kicks in

CANONICAL_SECTIONS = {
    "goal",
    "what belongs here",
    "what does not belong here",
    "decision test",
    "hard constraints",
    "file structure",
    "versioning",
    "pr checklist",
    "skill authoring",
}

WRITE_CAPABLE_AGENTS = {
    "coder",
    "change-implementer",
    "documentation-agent",
    "po-agent",
    "light-planner",
    "acceptance-writer",
    "dev-reviewer",
    "doc-writer",
    "po-reviewer",
    "prototype-builder",
    "qa-reviewer",
}


# ---------------------------------------------------------------------------
# Helper: extract plugin name from file path under plugins/<name>/...
# ---------------------------------------------------------------------------
def plugin_name_from_path(filepath: str) -> str:
    """Return the plugin directory name from an absolute path."""
    # Normalize path and split on plugins/
    norm = filepath.replace("\\", "/")
    marker = "/plugins/"
    idx = norm.rfind(marker)
    if idx == -1:
        return os.path.basename(os.path.dirname(filepath))
    remainder = norm[idx + len(marker):]
    # First path segment is the plugin name
    return remainder.split("/")[0]


# ---------------------------------------------------------------------------
# Helper: count #NNN or specs/ cross-references in a text block.
# ---------------------------------------------------------------------------
_REF_RE = re.compile(r"#\d+|specs/")


def count_refs(text: str) -> int:
    return len(_REF_RE.findall(text))


# ---------------------------------------------------------------------------
# Helper: normalize section heading for canonical check.
# ---------------------------------------------------------------------------
def normalize_heading(heading: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", heading.lower().strip()).strip()


# ---------------------------------------------------------------------------
# Parse AGENTS.md files — extract sections with line counts and ref counts.
# ---------------------------------------------------------------------------
def parse_agents_md(filepath: str):
    """
    Parse an AGENTS.md file and return a list of
    {'heading': str, 'lines': int, 'refs': int} dicts.
    Preamble (content before first ## heading) is treated as a synthetic
    section with heading '(preamble)'.
    """
    try:
        with open(filepath, encoding="utf-8") as fh:
            content = fh.read()
    except Exception as exc:
        print(f"harness-audit: WARNING skipping {filepath}: {exc}", file=sys.stderr)
        return [], 0

    lines = content.splitlines()
    total_lines = len(lines)

    sections = []
    current_heading = "(preamble)"
    current_lines = []

    for line in lines:
        if line.startswith("## "):
            if current_lines or current_heading != "(preamble)":
                sections.append({
                    "heading": current_heading,
                    "lines": len(current_lines),
                    "refs": count_refs("\n".join(current_lines)),
                })
            current_heading = line.lstrip("#").strip()
            current_lines = []
        else:
            current_lines.append(line)

    # Flush last section
    if current_lines or current_heading != "(preamble)":
        sections.append({
            "heading": current_heading,
            "lines": len(current_lines),
            "refs": count_refs("\n".join(current_lines)),
        })

    return sections, total_lines


# ---------------------------------------------------------------------------
# Classify a single AGENTS.md section.
# ---------------------------------------------------------------------------
def classify_agents_section(heading: str, lines: int, refs: int, total_lines: int) -> tuple:
    """Return (action, reason)."""
    norm_heading = normalize_heading(heading)

    # Preamble: frontmatter / YAML fence or blank preamble — keep
    if heading == "(preamble)":
        return "KEEP", "preamble / frontmatter area"

    # Canonical structural sections are always KEEP.
    if norm_heading in CANONICAL_SECTIONS:
        return "KEEP", f"canonical structural section"

    # File is under the threshold — KEEP regardless.
    if total_lines <= BLOAT_THRESHOLD:
        return "KEEP", f"file is within {BLOAT_THRESHOLD}-line threshold"

    # File is over threshold — check for cross-refs.
    if refs > 0:
        return "KEEP", f"has {refs} spec/issue cross-reference(s)"

    # Over threshold and no cross-refs — BLOAT.
    # Check for MOVE-TO-SKILL heuristic: section mentions "contract", "propagation",
    # "runtime", "dispatch" — typical skill-content signals.
    skill_keywords = re.compile(
        r"\b(contract|propagation|dispatch table|runtime contract|dispatch chain)\b",
        re.IGNORECASE,
    )
    if skill_keywords.search(heading):
        return (
            "MOVE-TO-SKILL",
            "section describes a runtime contract or dispatch chain — "
            "belongs in a skill's SKILL.md",
        )

    return (
        "BLOAT",
        f"section has no #NNN or specs/ cross-reference and "
        f"file exceeds {BLOAT_THRESHOLD}-line threshold",
    )


# ---------------------------------------------------------------------------
# Parse YAML frontmatter from an agent .md file.
# Returns a dict of frontmatter key → value strings.
# ---------------------------------------------------------------------------
def parse_frontmatter(filepath: str) -> dict:
    """Extract YAML frontmatter between leading --- delimiters."""
    result = {}
    try:
        with open(filepath, encoding="utf-8") as fh:
            lines = fh.readlines()
    except Exception as exc:
        print(f"harness-audit: WARNING skipping {filepath}: {exc}", file=sys.stderr)
        return result

    if not lines or lines[0].strip() != "---":
        return result

    in_front = False
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        in_front = True
        # Parse simple key: value lines (not multi-line YAML blocks).
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)", line)
        if m:
            key = m.group(1).strip()
            val = m.group(2).strip().strip('"').strip("'")
            result[key] = val

    return result


# ---------------------------------------------------------------------------
# Classify a single agent's permissionMode configuration.
# ---------------------------------------------------------------------------
def classify_permission(agent_name: str, fm: dict) -> tuple:
    """Return (action, reason)."""
    pm = fm.get("permissionMode", "")
    dt = fm.get("disallowedTools", "")

    if not pm:
        return (
            "MISSING_PM",
            "agent frontmatter has no permissionMode field",
        )

    if pm == "bypassPermissions":
        if dt:
            # Has disallowedTools → read-only pattern → OK
            return "OK", "bypassPermissions + disallowedTools (read-only pattern)"
        else:
            # No disallowedTools — check whitelist
            if agent_name in WRITE_CAPABLE_AGENTS:
                return (
                    "OK",
                    f"bypassPermissions without disallowedTools — '{agent_name}' "
                    f"is a known write-capable agent",
                )
            else:
                return (
                    "READ_WRITE_MISMATCH",
                    f"bypassPermissions but no disallowedTools and '{agent_name}' "
                    f"is not in the known write-capable whitelist — potential "
                    f"accidental write access",
                )

    # Any other permissionMode value — treat as OK (e.g. default)
    return "OK", f"permissionMode is '{pm}'"


# ---------------------------------------------------------------------------
# Main: load lists and emit findings.
# ---------------------------------------------------------------------------

# --- Read AGENTS.md list ---
agents_md_paths = []
if agents_md_list_file and os.path.exists(agents_md_list_file):
    try:
        with open(agents_md_list_file, encoding="utf-8") as f:
            agents_md_paths = [line.strip() for line in f if line.strip()]
    except Exception:
        pass

# --- Read agent files list ---
agent_file_paths = []
if agent_files_list_file and os.path.exists(agent_files_list_file):
    try:
        with open(agent_files_list_file, encoding="utf-8") as f:
            agent_file_paths = [line.strip() for line in f if line.strip()]
    except Exception:
        pass

# --- Process AGENTS.md files ---
for agents_md_path in agents_md_paths:
    plugin = plugin_name_from_path(agents_md_path)
    sections, total_lines = parse_agents_md(agents_md_path)

    for sec in sections:
        action, reason = classify_agents_section(
            sec["heading"], sec["lines"], sec["refs"], total_lines
        )
        finding = {
            "type": "agents-md",
            "plugin": plugin,
            "section": sec["heading"],
            "lines": sec["lines"],
            "refs": sec["refs"],
            "action": action,
            "reason": reason,
        }
        print(json.dumps(finding, separators=(",", ":")))

# --- Process agent .md files ---
for agent_path in agent_file_paths:
    # Skip RETURN-CONTRACT.md and similar non-agent files
    basename = os.path.basename(agent_path)
    if basename.upper() == basename or not basename.endswith(".md"):
        continue

    plugin = plugin_name_from_path(agent_path)
    agent_name = basename[:-3]  # strip .md

    fm = parse_frontmatter(agent_path)

    # Skip files without any frontmatter (not an agent definition).
    if not fm:
        continue

    action, reason = classify_permission(agent_name, fm)
    finding = {
        "type": "permission",
        "plugin": plugin,
        "agent": agent_name,
        "permissionMode": fm.get("permissionMode", ""),
        "disallowedTools": fm.get("disallowedTools", ""),
        "action": action,
        "reason": reason,
    }
    print(json.dumps(finding, separators=(",", ":")))

PYEOF
