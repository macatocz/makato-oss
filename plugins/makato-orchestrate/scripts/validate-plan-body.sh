#!/usr/bin/env bash
# validate-plan-body.sh — deterministic promotion guard for the lightweight
# planning lane (#212).
#
# A plan-tier:light issue must NOT be promoted to Status=Ready on the board
# until the light-planner agent has materialized a REAL plan.md — one that
# carries both a non-empty `## Tasks` section and a non-empty
# `## Acceptance criteria` section. A stub (the HALT-006 seed-issue skeleton
# with only placeholder text) must fail this guard so seed-issue keeps the
# board at Todo and the po-agent never fires HALT-006 on dispatch.
#
# This is the machine-checkable half of the light-planner integration: the
# LLM agent writes the plan, this pure function decides whether that plan is
# substantive enough to promote. Keeping it a standalone bash/jq-free script
# makes it auditable in CI and unit-testable without a live agent.
#
# Input:
#   $1 — path to the plan.md file to validate.
#   $2 — (optional) ISSUE_NUMBER to check against the <!-- issue: #NNN -->
#        fingerprint in the plan. When supplied and the plan carries a
#        fingerprint header whose number does not match, the guard fails with
#        `invalid fingerprint-mismatch`. When the plan has no fingerprint
#        header, it is treated as a legacy plan and this check is skipped
#        (legacy-pass). When $2 is absent, fingerprint checking is skipped.
#
# Output (stdout): exactly one line "<verdict> <reason>"
#   verdict ∈ {valid, invalid}
#   reason  ∈ {ok, missing-file, no-tasks-heading, empty-tasks,
#              no-acceptance-heading, empty-acceptance, fingerprint-mismatch}
#
# Exit code: 0 when valid, 1 when invalid. The stdout reason is the
# authoritative signal; the exit code mirrors it for `if` convenience.
#
# A section is "non-empty" when, between its `## <Heading>` line and the next
# `## ` heading (or EOF), at least one line carries real content — a Markdown
# list item (`-`, `*`, `+`, or `N.`) or a non-blank prose line — that is NOT a
# placeholder stub. Placeholder text (the seed-issue `_To be filled in…_`
# line, HTML comments, and the template `<tasks>` / `<ac-coverage-table>`
# tokens) does not count as content. This mirrors build-refine's
# MISSING_ACCEPTANCE guard so the two never disagree about what "empty" means.
set -euo pipefail

PLAN_PATH="${1:-}"
ISSUE_NUMBER="${2:-}"

# emit <verdict> <reason>: print the one-line result, then exit 0 for valid
# or 1 for invalid. Every terminal path funnels through here so stdout and
# exit code can never disagree.
emit() {
  printf '%s %s\n' "$1" "$2"
  [ "$1" = "valid" ] && exit 0 || exit 1
}

if [ -z "$PLAN_PATH" ] || [ ! -f "$PLAN_PATH" ]; then
  emit invalid missing-file
fi

# --- Fingerprint check (optional — only when $2 ISSUE_NUMBER is supplied) ----
# Extract the <!-- issue: #NNN --> fingerprint from the plan file. The header
# must be a standalone HTML comment on its own line (as written by light-planner
# and plan templates). When present, compare against $2. When absent, treat the
# plan as a legacy plan (legacy-pass — fingerprinting predates this feature).
if [ -n "$ISSUE_NUMBER" ]; then
  fingerprint="$(grep -m1 '<!-- issue: #[0-9]\+' "$PLAN_PATH" | \
    grep -oE '[0-9]+' | head -1 || true)"
  if [ -n "$fingerprint" ] && [ "$fingerprint" != "$ISSUE_NUMBER" ]; then
    emit invalid fingerprint-mismatch
  fi
  # fingerprint absent → legacy-pass; fingerprint matches → continue to structural checks
fi

# Extract the body of a `## <Heading>` section: everything after the heading
# line up to (but not including) the next `## ` heading or EOF. Case-insensitive
# on the heading text; tolerant of trailing whitespace after the heading.
section_body() {
  local heading="$1" file="$2"
  awk -v want="$heading" '
    BEGIN { IGNORECASE = 1; inside = 0 }
    /^##[[:space:]]+/ {
      # Normalize: strip leading "## " and trailing whitespace.
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (tolower(h) == tolower(want)) { inside = 1; next }
      else if (inside) { inside = 0 }
    }
    inside { print }
  ' "$file"
}

# A section body counts as non-empty when at least one line is real content:
# a list item or a prose line that is not blank, not an HTML comment, not a
# template token, and not the seed-issue placeholder stub.
has_content() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next                       # blank
      if (line ~ /^<!--/) next                    # HTML comment
      if (line ~ /^<[a-z-]+>$/) next              # template token e.g. <tasks>
      if (line ~ /^_.*_$/) next                   # italic placeholder stub
      if (line ~ /^\|/ && line ~ /-\|/) next      # markdown table separator row
      # Real content: markdown list item or any other non-blank line.
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  '
}

# --- Tasks section ---------------------------------------------------------
tasks_body="$(section_body "Tasks" "$PLAN_PATH")"
if [ -z "$(printf '%s' "$tasks_body" | tr -d '[:space:]')" ]; then
  # Distinguish "heading absent" from "heading present but empty" for a
  # clearer operator message. grep the raw file for the heading.
  if grep -qiE '^##[[:space:]]+Tasks[[:space:]]*$' "$PLAN_PATH"; then
    emit invalid empty-tasks
  fi
  emit invalid no-tasks-heading
fi
if ! printf '%s\n' "$tasks_body" | has_content; then
  emit invalid empty-tasks
fi

# --- Acceptance criteria section -------------------------------------------
ac_body="$(section_body "Acceptance criteria" "$PLAN_PATH")"
if [ -z "$(printf '%s' "$ac_body" | tr -d '[:space:]')" ]; then
  if grep -qiE '^##[[:space:]]+Acceptance criteria[[:space:]]*$' "$PLAN_PATH"; then
    emit invalid empty-acceptance
  fi
  emit invalid no-acceptance-heading
fi
if ! printf '%s\n' "$ac_body" | has_content; then
  emit invalid empty-acceptance
fi

emit valid ok
