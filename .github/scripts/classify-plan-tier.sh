#!/usr/bin/env bash
# classify-plan-tier.sh — deterministic plan-tier classifier (D5 / D8).
#
# Pure function over an issue's {title, body, labels}. Emits exactly one
# plan-tier decision. No network, no LLM, no secret — the whole point of D5
# is that classification is a bash/jq pure function that is auditable in CI
# and carries zero data-egress risk from the runner (SC-4).
#
# Input (environment):
#   TITLE   — issue title (string)
#   BODY    — issue body / body_full (string, may be empty)
#   LABELS  — newline-separated label names (may be empty)
#   PLAN_TIER_POINTS_THRESHOLD — points:<n> value at or above which a single
#             story is treated as "full" (needs further decomposition).
#             Default 13 (the repo's enforced Fibonacci split point, #554).
#
# Output (stdout): exactly one line "<tier> <source>"
#   tier   ∈ {light, full, change}
#   source ∈ {override, classified}
#
# When a human plan-tier:* label is already present the classifier is a
# no-op: it echoes that tier with source=override and the caller MUST NOT
# stamp or change any label (D8 precedence rule 1 — human override wins).
#
# Precedence (D8):
#   1. human plan-tier:* label present               → keep it (override)
#   2. type:change OR change keyword in title/snippet → change
#   3. effort:xl OR points:>=13 OR epic:*/phase:*     → full (decomposition)
#   4. otherwise                                      → light (safe default)
#
# DECOMPOSITION METRIC (not body length). `full` means exactly one thing:
# "this issue splits into multiple vertically-sliced stories and needs the
# human makato-plan cycle (brainstorm → PRD → architecture → decompose)".
# That is a structural fact carried by explicit sizing/epic labels — NOT a
# property of how long the body text is. The prior body-length signal
# (PLAN_TIER_BODY_THRESHOLD, > 1500 chars → full) was removed: it mistook a
# well-written description for a large feature and forced ~75% of `full`
# issues into a human-blocked lane they did not need. A `full` misclassifi-
# cation is expensive (loop blocks the card at needs-human-review, silently
# and indefinitely); a `light` misclassification self-corrects downstream
# (the light-planner's thin-body AND scope-excess guards re-tier to full).
# So the safe default flipped from `full` to `light`.
#
# Keyword scan (rule 2 only) runs over `title + body_snippet` (first 200
# chars of body). No rule reads the full body length any more.
set -euo pipefail

TITLE="${TITLE:-}"
BODY="${BODY:-}"
LABELS="${LABELS:-}"
POINTS_THRESHOLD="${PLAN_TIER_POINTS_THRESHOLD:-13}"

has_label() { printf '%s\n' "$LABELS" | grep -qxF "$1"; }
has_label_re() { printf '%s\n' "$LABELS" | grep -qE "$1"; }

# Highest points:<n> label value present (0 when none). A degenerate issue
# carrying multiple points:* labels uses the largest — the most conservative
# read for the "needs decomposition" signal. The `|| true` guards keep the
# pipeline from tripping `set -o pipefail` when no points:* label matches.
max_points() {
  local n
  n="$(printf '%s\n' "$LABELS" \
    | grep -oE '^points:[0-9]+$' \
    | grep -oE '[0-9]+$' \
    | sort -rn | head -n1 || true)"
  printf '%s' "${n:-0}"
}

# --- Rule 1: human override wins -------------------------------------------
# The first existing plan-tier:* label is authoritative; deterministic on
# label order. A degenerate issue carrying two plan-tier:* labels keeps the
# first one encountered.
existing="$(printf '%s\n' "$LABELS" | grep -m1 -E '^plan-tier:(light|full|change)$' || true)"
if [ -n "$existing" ]; then
  printf '%s override\n' "${existing#plan-tier:}"
  exit 0
fi

# body_snippet is the first 200 chars of body_full — used ONLY for keyword
# scanning (cheap, bounded). The length signal below reads body_full.
body_snippet="${BODY:0:200}"
scan="$(printf '%s\n%s' "$TITLE" "$body_snippet")"

# Portable word-boundary keyword match (works on GNU + BSD grep — avoids the
# non-portable \b / [[:<:]] escapes). A change keyword must be bordered by a
# non-letter (or string edge) so "prefix"/"debugging" don't false-match.
CHANGE_RE='(^|[^a-zA-Z])(fix|bug|hotfix|regression|revert|patch)([^a-zA-Z]|$)'

# --- Rule 2: change --------------------------------------------------------
if has_label 'type:change' || printf '%s' "$scan" | grep -qiE "$CHANGE_RE"; then
  printf 'change classified\n'
  exit 0
fi

# --- Rule 3: full (decomposition signal) -----------------------------------
# An issue is `full` ONLY when an explicit structural signal says it splits
# into multiple stories / warrants the human plan cycle:
#   • effort:xl                 — > 1 week of work; a single story that large
#                                 is by definition a decomposition candidate.
#   • points:>=THRESHOLD (13)   — the repo enforces a Fibonacci ≤13 SP cap and
#                                 splits anything above it (#554); 13 is the
#                                 "must decompose" boundary.
#   • epic:* / phase:*          — explicit epic/phase marker carried by a
#                                 parent/roadmap issue.
# NOTE: effort:l and points 8..12 are deliberately NOT full — a single ~week
# story still fits one autonomous build session. Body length is not read.
points="$(max_points)"; points="${points:-0}"
if has_label 'effort:xl' \
   || has_label_re '^(epic|phase):' \
   || { [ "$points" -ge "$POINTS_THRESHOLD" ]; }; then
  printf 'full classified\n'
  exit 0
fi

# --- Rule 4: light (safe default) ------------------------------------------
# Everything that is not change and not an explicit decomposition candidate
# defaults to light. This is the flipped default (was `full`): a wrong light
# self-corrects via the light-planner's thin-body + scope-excess guards,
# whereas a wrong full silently blocks the card on needs-human-review.
#
# Formerly this branch gated on effort:xs|s / type:feat|feature; that gate is
# now redundant — those issues all land here anyway — so light is emitted
# unconditionally as the terminal rule.
printf 'light classified\n'
