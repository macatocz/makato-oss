#!/usr/bin/env bash
# sync-living-specs.sh — apply a spec-delta.md file to a living docs/specs/<capability>.md
# post-merge. Reads ADDED / MODIFIED / REMOVED requirement sections from spec-delta.md
# and applies the corresponding operations to the target capability spec file.
#
# Usage:
#   sync-living-specs.sh <spec-delta-path> <docs-specs-dir>
#
#   spec-delta-path   Path to the spec-delta.md file (e.g. specs/<KEY>-<slug>/spec-delta.md)
#   docs-specs-dir    Path to the docs/specs/ directory (will be created if absent)
#
# Behaviour:
#   - ADDED requirements: appended to docs/specs/<capability>.md; file created if absent.
#   - MODIFIED requirements: replace the matching ### <name> section in the target file.
#     A dangling MODIFIED ref (no matching heading) emits a WARN to stderr and is skipped.
#   - REMOVED requirements: replace the ### <name> section with a tombstone comment.
#   - Empty spec-delta.md (no populated requirement sections) is a clean no-op.
#
# Capability is derived from the spec-delta.md file's parent directory basename
# (e.g. specs/foo-bar/spec-delta.md → capability "foo-bar", target docs/specs/foo-bar.md).
#
# Exit codes:
#   0  success (including no-op and dangling MODIFIED WARN)
#   1  usage error or spec-delta.md not found
#
# Dependencies: bash, python3 (stdlib only)
set -euo pipefail

DELTA_PATH="${1:-}"
DOCS_DIR="${2:-}"

if [[ -z "$DELTA_PATH" || -z "$DOCS_DIR" ]]; then
  echo "usage: sync-living-specs.sh <spec-delta-path> <docs-specs-dir>" >&2
  exit 1
fi

if [[ ! -f "$DELTA_PATH" ]]; then
  echo "sync-living-specs: spec-delta file not found: $DELTA_PATH" >&2
  exit 1
fi

# All parsing and applying logic in one Python pass — stdlib only, no jq.
python3 - "$DELTA_PATH" "$DOCS_DIR" <<'PY'
import sys
import os
import re

DELTA_PATH = sys.argv[1]
DOCS_DIR   = sys.argv[2]

# ── Helpers ──────────────────────────────────────────────────────────────────

def parse_delta(text):
    """Parse spec-delta.md into {section: [(name, body_lines), ...]} dicts.

    Returns a dict with keys 'ADDED', 'MODIFIED', 'REMOVED', each mapping to
    a list of (requirement_name, body_lines) tuples.  Only requirements that
    have at least one non-comment, non-blank body line are returned (template
    comment blocks are ignored).
    """
    SECTION_RE = re.compile(
        r'^##\s+(ADDED Requirements|MODIFIED Requirements|REMOVED Requirements)\s*$'
    )
    REQ_RE = re.compile(r'^###\s+(.+?)\s*$')
    H2_RE  = re.compile(r'^##\s+')

    result = {'ADDED': [], 'MODIFIED': [], 'REMOVED': []}
    current_section = None
    current_req = None
    current_body = []

    def flush_req():
        if current_section and current_req is not None:
            # Strip surrounding blank lines; skip template comment-only bodies
            stripped = [l for l in current_body if l.strip() and not l.strip().startswith('<!--')]
            if stripped:
                result[current_section].append((current_req, current_body[:]))

    lines = text.splitlines()
    for line in lines:
        sec_m = SECTION_RE.match(line)
        if sec_m:
            flush_req()
            current_req = None
            current_body = []
            label = sec_m.group(1)
            if label.startswith('ADDED'):
                current_section = 'ADDED'
            elif label.startswith('MODIFIED'):
                current_section = 'MODIFIED'
            elif label.startswith('REMOVED'):
                current_section = 'REMOVED'
            continue

        if H2_RE.match(line) and not SECTION_RE.match(line):
            flush_req()
            current_req = None
            current_body = []
            current_section = None
            continue

        req_m = REQ_RE.match(line)
        if req_m and current_section:
            flush_req()
            current_req = req_m.group(1)
            current_body = []
            continue

        if current_req is not None:
            current_body.append(line)

    flush_req()
    return result


def split_sections(lines):
    """Split a markdown file into a list of (header_line_or_None, body_lines) chunks.

    Each chunk is (heading_line, [body lines]).  The first chunk has heading_line=None
    for any content before the first heading.  Only ### headings are split points here;
    ## headings are preserved as body content within their parent chunk's intro.
    """
    chunks = []
    current_heading = None
    current_body = []
    H3_RE = re.compile(r'^###\s+(.+?)\s*$')

    for line in lines:
        m = H3_RE.match(line)
        if m:
            chunks.append((current_heading, current_body))
            current_heading = line
            current_body = []
        else:
            current_body.append(line)

    chunks.append((current_heading, current_body))
    return chunks


def join_chunks(chunks):
    """Reassemble chunks back into a list of lines."""
    out = []
    for heading, body in chunks:
        if heading is not None:
            out.append(heading)
        out.extend(body)
    return out


def req_name_from_heading(heading_line):
    m = re.match(r'^###\s+(.+?)\s*$', heading_line or '')
    return m.group(1) if m else None


# ── Main ─────────────────────────────────────────────────────────────────────

delta_text = open(DELTA_PATH, encoding='utf-8').read()
delta = parse_delta(delta_text)

# Derive capability from the parent directory of spec-delta.md
parent_dir = os.path.basename(os.path.dirname(os.path.abspath(DELTA_PATH)))
capability = parent_dir  # e.g. "openspec-transfer-features"

os.makedirs(DOCS_DIR, exist_ok=True)
target_path = os.path.join(DOCS_DIR, capability + '.md')

# No-op check: nothing populated in any section
if not any(delta[k] for k in ('ADDED', 'MODIFIED', 'REMOVED')):
    sys.exit(0)

# Load existing target file (or start empty)
if os.path.exists(target_path):
    with open(target_path, encoding='utf-8') as f:
        target_lines = f.read().splitlines()
else:
    target_lines = []

# ── Apply ADDED ───────────────────────────────────────────────────────────────
for req_name, body_lines in delta['ADDED']:
    # Append heading + body after last non-blank line
    while target_lines and not target_lines[-1].strip():
        target_lines.pop()
    if target_lines:
        target_lines.append('')
    target_lines.append(f'### {req_name}')
    target_lines.extend(body_lines)

# ── Apply MODIFIED ────────────────────────────────────────────────────────────
for req_name, body_lines in delta['MODIFIED']:
    chunks = split_sections(target_lines)
    matched = False
    new_chunks = []
    for (heading, body) in chunks:
        existing_name = req_name_from_heading(heading)
        if existing_name and existing_name.lower() == req_name.lower():
            new_chunks.append((heading, body_lines))
            matched = True
        else:
            new_chunks.append((heading, body))
    if matched:
        target_lines = join_chunks(new_chunks)
    else:
        print(
            f'WARN: sync-living-specs: dangling MODIFIED ref "{req_name}" in {capability}.md — '
            'no matching heading found; skipping',
            file=sys.stderr
        )

# ── Apply REMOVED ─────────────────────────────────────────────────────────────
for req_name, _body_lines in delta['REMOVED']:
    chunks = split_sections(target_lines)
    new_chunks = []
    for (heading, body) in chunks:
        existing_name = req_name_from_heading(heading)
        if existing_name and existing_name.lower() == req_name.lower():
            # Replace entire section with tombstone (no heading, just a comment)
            new_chunks.append((None, [f'<!-- REMOVED: {req_name} -->']))
        else:
            new_chunks.append((heading, body))
    target_lines = join_chunks(new_chunks)

# ── Write result ──────────────────────────────────────────────────────────────
# Ensure file ends with a single newline
output = '\n'.join(target_lines)
if output and not output.endswith('\n'):
    output += '\n'

with open(target_path, 'w', encoding='utf-8') as f:
    f.write(output)
PY
