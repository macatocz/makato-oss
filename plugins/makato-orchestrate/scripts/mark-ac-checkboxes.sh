#!/usr/bin/env bash
# mark-ac-checkboxes.sh — deterministic AC-checkbox matcher for the post-merge
# documentation-agent (Step 4a). Given a machine-readable per-AC verdict set and
# a GitHub issue body, produce the new issue body with verified ACs flipped
# `- [ ]` → `- [x]`, applying the granular-first / all-or-nothing-fallback policy.
#
# This is the executable reference implementation of documentation-agent.md
# § "Step 4a — Mark verified AC checkboxes". The agent shells out to it so the
# fuzzy-matching logic is deterministic and unit-testable rather than re-derived
# by the model each run.
#
# Usage:
#   mark-ac-checkboxes.sh <verdicts-json-file> <issue-body-file>
#
#   verdicts-json-file  path to a JSON array of
#                       {ac_id, ac_text, verified, evidence?, reason?}
#   issue-body-file     path to the raw issue body (markdown)
#
# Behaviour:
#   - Granular: for each verdict with verified==true whose normalized ac_text
#     matches a `- [ ]` checkbox line (exact or substring on the normalized
#     label), flip that line to `- [x]`. verified==false or unmatched → untouched.
#     Never flips `[x]` → `[ ]`.
#   - All-or-nothing fallback: when ZERO verdicts matched any checkbox line,
#     fall back to a coarse gate — iff every verdict is verified==true, check
#     ALL `- [ ]` lines; if any verdict is verified==false, check none.
#   - Empty verdict array → no change, mode "skipped".
#
# Output:
#   - The new issue body is written to stdout.
#   - A one-line JSON summary is written to stderr:
#       {"mode":"granular|fallback-all|fallback-none|skipped","boxes_checked":N,
#        "verdicts_total":N,"verified":N}
#
# Exit codes:
#   0  success (body on stdout, summary on stderr) — including a no-op change
#   1  usage / unreadable input / malformed verdict JSON
set -euo pipefail

VERDICTS_FILE="${1:?usage: mark-ac-checkboxes.sh <verdicts-json-file> <issue-body-file>}"
BODY_FILE="${2:?usage: mark-ac-checkboxes.sh <verdicts-json-file> <issue-body-file>}"

[[ -f "$VERDICTS_FILE" ]] || { echo "mark-ac-checkboxes: verdicts file not found: $VERDICTS_FILE" >&2; exit 1; }
[[ -f "$BODY_FILE" ]] || { echo "mark-ac-checkboxes: issue-body file not found: $BODY_FILE" >&2; exit 1; }

# All matching logic lives in one Python pass so normalization is consistent
# between the granular matcher and the fallback gate. stdlib only.
python3 - "$VERDICTS_FILE" "$BODY_FILE" <<'PY'
import json, re, sys

verdicts_path, body_path = sys.argv[1], sys.argv[2]

try:
    with open(verdicts_path, encoding="utf-8") as fh:
        verdicts = json.load(fh)
except (json.JSONDecodeError, ValueError) as exc:
    print(f"mark-ac-checkboxes: malformed verdict JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(verdicts, list):
    print("mark-ac-checkboxes: verdict JSON must be an array", file=sys.stderr)
    sys.exit(1)

with open(body_path, encoding="utf-8") as fh:
    body = fh.read()

lines = body.split("\n")

# An unchecked-checkbox line: capture the leading indent and the label text.
BOX_RE = re.compile(r'^(\s*[-*]\s+)\[ \](\s+)(.*)$')

def normalize(text: str) -> str:
    """Lowercase, strip a leading AC-N / Scenario N: label, collapse whitespace,
    drop trailing punctuation — so plan-AC wording pairs with issue-body wording."""
    t = text.strip().lower()
    t = re.sub(r'^(ac[-\s]?\d+|scenario\s+\d+)\s*[:.\-]?\s*', '', t)
    t = re.sub(r'\s+', ' ', t)
    t = t.strip(' .:;,-')
    return t

# Index unchecked checkbox lines with their normalized labels.
box_lines = []  # (line_index, normalized_label)
for i, line in enumerate(lines):
    m = BOX_RE.match(line)
    if m:
        box_lines.append((i, normalize(m.group(3))))

total = len(verdicts)
verified_verdicts = [v for v in verdicts if v.get("verified") is True]
verified_count = len(verified_verdicts)

def check_line(i: int) -> None:
    m = BOX_RE.match(lines[i])
    # Preserve indent + spacing; only swap the marker.
    lines[i] = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"

matched_indices = set()

# ---- Granular pass -------------------------------------------------------
for v in verified_verdicts:
    ac_norm = normalize(str(v.get("ac_text", "")))
    if not ac_norm:
        continue
    for i, label in box_lines:
        if i in matched_indices:
            continue
        if ac_norm == label or ac_norm in label or label in ac_norm:
            matched_indices.add(i)
            check_line(i)
            break  # one AC → at most one box

if total == 0:
    mode = "skipped"
elif matched_indices:
    mode = "granular"
else:
    # ---- All-or-nothing fallback -----------------------------------------
    # No line paired. Coarse gate keyed on whether every verdict is verified.
    all_verified = total > 0 and verified_count == total
    if all_verified:
        for i, _ in box_lines:
            check_line(i)
            matched_indices.add(i)
        mode = "fallback-all"
    else:
        mode = "fallback-none"

new_body = "\n".join(lines)
sys.stdout.write(new_body)

summary = {
    "mode": mode,
    "boxes_checked": len(matched_indices),
    "verdicts_total": total,
    "verified": verified_count,
}
print(json.dumps(summary), file=sys.stderr)
PY
