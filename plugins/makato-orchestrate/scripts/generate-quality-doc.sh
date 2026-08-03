#!/usr/bin/env bash
# scripts/generate-quality-doc.sh — per-domain quality scorecard from build.jsonl
# + halt_audit (#598).
#
# Reads all per-issue build.jsonl files whose plan.md / spec.md frontmatter
# carries `domain: <name>` (or is absent when `--domain general`) and writes a
# Quality Scorecard table to `specs/master/<domain>-quality.md`.
#
# Usage:
#   bash plugins/makato-orchestrate/scripts/generate-quality-doc.sh \
#     --domain <name> [--specs-dir <path>]
#
# Arguments:
#   --domain <name>      Required. The domain to aggregate (e.g. "orchestrate",
#                        "build", "general").
#   --specs-dir <path>   Optional. Override the specs/ root. Defaults to
#                        $REPO_ROOT/specs (or $MAKATO_QUALITY_SPECS_DIR for tests).
#
# Output:
#   Writes/overwrites `<specs-dir>/master/<domain>-quality.md`.  If the master
#   file already exists, only the `## Quality Scorecard` section and the
#   `_Last updated_` footer line are replaced; all other content (e.g. Evolution
#   Log written by archive-spec.sh) is preserved.
#
# Per-issue metrics (all read-only, via jq):
#   tests_passing       — last numeric data.tests_passing from a status:ok/green entry
#   sensor_clean        — Yes/No/- from the last gate-sensors entry
#   halts               — count of halt_audit[] entries
#   last_halt           — halt_audit[-1].code
#   structural_failures — count of build-verify entries where status==error or
#                         data.all_gates_passed==false
#
# Never fatal: always exits 0; unreadable files produce `-` for their cells
# and a warning to stderr.
#
# Test hook: MAKATO_QUALITY_SPECS_DIR overrides the specs directory.
#
# Pattern-mirrors generate-run-report.sh: same _now helper, same atomic write,
# same detect_domain logic as archive-spec.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPECS_DIR="${MAKATO_QUALITY_SPECS_DIR:-${SPECS_DIR:-$REPO_ROOT/specs}}"

_log() { echo "quality-doc: $*" >&2; }

# ---------------------------------------------------------------------------
# _now — ISO-8601 UTC timestamp. Same helper as generate-run-report.sh.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# --- Argument parsing -------------------------------------------------------
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --domain requires a value"; exit 64; }
      DOMAIN="$1"; shift ;;
    --specs-dir)
      shift
      [[ $# -gt 0 ]] || { _log "ERROR — --specs-dir requires a value"; exit 64; }
      SPECS_DIR="$1"; shift ;;
    --*)
      _log "ERROR — unknown flag: $1"; exit 64 ;;
    *)
      _log "ERROR — unexpected positional arg: $1"; exit 64 ;;
  esac
done

[[ -n "$DOMAIN" ]] || { _log "ERROR — --domain is required"; exit 64; }

# ---------------------------------------------------------------------------
# detect_domain <folder> — read `domain:` from plan.md / spec.md frontmatter.
# Mirrors archive-spec.sh:detect_domain exactly.
# ---------------------------------------------------------------------------
detect_domain() {
  local folder="$1" domain=""
  local f
  for f in plan.md spec.md; do
    if [[ -f "$folder/$f" ]]; then
      domain="$(sed -n 's/^domain:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$folder/$f" | head -1)"
      [[ -n "$domain" ]] && break
    fi
  done
  printf '%s\n' "${domain:-general}"
}

# ---------------------------------------------------------------------------
# _issue_number_from_folder <basename> — last numeric segment.
# e.g. "598-makato-orchestrate-feat-quality-doc" → "598"
# ---------------------------------------------------------------------------
_issue_number_from_folder() {
  local base="$1"
  printf '%s\n' "$base" | grep -oE '^[0-9]+' | head -1 || true
}

# ---------------------------------------------------------------------------
# _slug_title <basename> — human-readable slug: strip leading digits + dash.
# e.g. "598-makato-orchestrate-feat-quality-doc" →
#      "makato-orchestrate-feat-quality-doc"
# ---------------------------------------------------------------------------
_slug_title() {
  printf '%s\n' "$1" | sed 's/^[0-9]*-//'
}

# ---------------------------------------------------------------------------
# _aggregate_build_jsonl <path> — parse build.jsonl and emit four tab-separated
# values: tests_passing<TAB>sensor_clean<TAB>structural_failures
# Returns "-<TAB>-<TAB>-" if the file is unreadable or absent.
# ---------------------------------------------------------------------------
_aggregate_build_jsonl() {
  local bfile="$1"
  if [[ ! -f "$bfile" ]]; then
    printf '%s\t%s\t%s\n' "-" "-" "-"
    return
  fi

  # Use python3 to avoid jq streaming issues with concatenated JSON objects.
  python3 - "$bfile" <<'PYEOF' 2>/dev/null || printf '%s\t%s\t%s\n' "-" "-" "-"
import sys, json

path = sys.argv[1]
entries = []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass

# tests_passing: last numeric data.tests_passing from a status ok/green entry
tests_passing = "-"
for e in reversed(entries):
    if e.get("status") in ("ok", "green"):
        d = e.get("data") or {}
        tp = d.get("tests_passing")
        if tp is not None and isinstance(tp, (int, float)):
            tests_passing = str(int(tp))
            break

# sensor_clean: last gate-sensors entry
sensor_clean = "-"
for e in reversed(entries):
    if e.get("step") == "gate-sensors":
        d = e.get("data") or {}
        findings = d.get("findings")
        if findings is None:
            findings = d.get("sensor_findings")
        if findings is not None:
            try:
                sensor_clean = "Yes" if int(findings) == 0 else "No"
            except (ValueError, TypeError):
                sensor_clean = "-"
        break

# structural_failures: build-verify entries where status==error or
# data.all_gates_passed==false
structural_failures = 0
for e in entries:
    if e.get("skill") == "build-verify" or e.get("step") == "build-verify":
        d = e.get("data") or {}
        if e.get("status") == "error" or d.get("all_gates_passed") is False:
            structural_failures += 1

print(f"{tests_passing}\t{sensor_clean}\t{structural_failures}")
PYEOF
}

# ---------------------------------------------------------------------------
# _aggregate_halt <folder> <issue> — read workflow-state-<issue>.json and
# emit: halt_count<TAB>last_halt_code
# Returns "0<TAB>-" if the file is absent or unreadable.
# ---------------------------------------------------------------------------
_aggregate_halt() {
  local folder="$1" issue="$2"
  local state_file
  state_file="$(find "$folder" -maxdepth 1 -name "workflow-state-${issue}.json" 2>/dev/null | head -1 || true)"
  if [[ -z "$state_file" || ! -f "$state_file" ]]; then
    printf '%s\t%s\n' "0" "-"
    return
  fi

  jq -r '
    (.halt_audit // []) as $ha |
    ($ha | length | tostring) as $cnt |
    (if ($ha | length) > 0 then $ha[-1].code // "-" else "-" end) as $last |
    [$cnt, $last] | join("\t")
  ' "$state_file" 2>/dev/null || printf '%s\t%s\n' "0" "-"
}

# ---------------------------------------------------------------------------
# Main: enumerate issue folders, filter by domain, build table rows.
# ---------------------------------------------------------------------------
if [[ ! -d "$SPECS_DIR" ]]; then
  _log "ERROR — SPECS_DIR not found: $SPECS_DIR"
  exit 1
fi

declare -a rows=()

while IFS= read -r -d '' folder; do
  [[ -d "$folder" ]] || continue
  base="$(basename "$folder")"
  # Skip master/, archive/, and any bare file entries.
  [[ "$base" == "master" || "$base" == "archive" ]] && continue
  # Only process folders that look like issue folders (leading digits).
  [[ "$base" =~ ^[0-9] ]] || continue

  folder_domain="$(detect_domain "$folder")"
  [[ "$folder_domain" == "$DOMAIN" ]] || continue

  issue="$(_issue_number_from_folder "$base")"
  [[ -n "$issue" ]] || continue
  slug_title="$(_slug_title "$base")"

  # build.jsonl metrics
  build_file="$folder/build.jsonl"
  IFS=$'\t' read -r tests_passing sensor_clean structural_failures \
    < <(_aggregate_build_jsonl "$build_file")

  # halt metrics
  IFS=$'\t' read -r halts last_halt < <(_aggregate_halt "$folder" "$issue")

  rows+=("| #${issue} | ${slug_title} | ${tests_passing} | ${sensor_clean} | ${halts} | ${last_halt} | ${structural_failures} |")
done < <(find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

# Build the scorecard block.
TIMESTAMP="$(_now)"
scorecard_header="## Quality Scorecard"
scorecard_table="| Issue | Story | Tests Passing | Sensor Clean | HALTs | Last HALT | Structural Failures |
|-------|-------|---------------|--------------|-------|-----------|---------------------|"
for row in "${rows[@]}"; do
  scorecard_table+=$'\n'"$row"
done
footer="_Last updated: ${TIMESTAMP}. Source: build.jsonl + workflow-state._"

NEW_SCORECARD="${scorecard_header}

${scorecard_table}

${footer}"

# ---------------------------------------------------------------------------
# Write to specs/master/<domain>-quality.md (atomic).
# If the file exists, replace only the ## Quality Scorecard section +
# _Last updated_ footer; preserve all other content.
# ---------------------------------------------------------------------------
mkdir -p "$SPECS_DIR/master"
output_file="$SPECS_DIR/master/${DOMAIN}-quality.md"

if [[ -f "$output_file" ]]; then
  # Replace the section from `## Quality Scorecard` up to and including the
  # `_Last updated:` footer line (or the next `##` heading / EOF).
  # Strategy: python3 section-replace for correctness.
  NEW_SCORECARD_ESC="$NEW_SCORECARD"
  python3 - "$output_file" "$NEW_SCORECARD_ESC" <<'PYEOF' 2>/dev/null
import sys

path = sys.argv[1]
new_section = sys.argv[2]

with open(path, "r", encoding="utf-8") as fh:
    content = fh.read()

SECTION_START = "## Quality Scorecard"
FOOTER_PREFIX = "_Last updated:"

# Find the start of the existing section.
start = content.find(SECTION_START)
if start == -1:
    # Section not present — append to the file.
    combined = content.rstrip("\n") + "\n\n" + new_section + "\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(combined)
    sys.exit(0)

# Find the footer line end (the line after the footer).
footer_start = content.find(FOOTER_PREFIX, start)
if footer_start == -1:
    end = len(content)
else:
    footer_end = content.find("\n", footer_start)
    end = footer_end + 1 if footer_end != -1 else len(content)

# Preserve content before and after the section.
before = content[:start]
after_raw = content[end:]
# Trim leading blank lines from after so we don't accumulate whitespace.
after = after_raw.lstrip("\n")

combined = before + new_section + ("\n\n" + after if after else "\n")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(combined)
PYEOF
  _log "updated scorecard in ${output_file} (domain: ${DOMAIN}, issues: ${#rows[@]})"
else
  # New file — write directly (atomic).
  tmp="$(mktemp "${output_file}.XXXXXX")"
  printf '%s\n' "$NEW_SCORECARD" >"$tmp"
  mv -f "$tmp" "$output_file"
  _log "created ${output_file} (domain: ${DOMAIN}, issues: ${#rows[@]})"
fi
