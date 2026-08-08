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
#   PLAN_TIER_BODY_THRESHOLD — body_full character count strictly above which
#             an issue is treated as "full" (default 1500)
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
#   3. effort:l|xl OR epic:*/phase:* OR body_full>thr → full
#   4. effort:xs|s OR (type:feat|feature AND body_full≤thr)→ light
#   5. otherwise (ambiguous)                          → full (safe default)
#
# Keyword scan runs over `title + body_snippet` (first 200 chars of body).
# The body-length signal always measures body_full, never the snippet.
set -euo pipefail

TITLE="${TITLE:-}"
BODY="${BODY:-}"
LABELS="${LABELS:-}"
THRESHOLD="${PLAN_TIER_BODY_THRESHOLD:-1500}"

has_label() { printf '%s\n' "$LABELS" | grep -qxF "$1"; }
has_label_re() { printf '%s\n' "$LABELS" | grep -qE "$1"; }

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

# --- Rule 3: full ----------------------------------------------------------
body_len="${#BODY}"
if has_label 'effort:l' || has_label 'effort:xl' \
   || has_label_re '^(epic|phase):' \
   || [ "$body_len" -gt "$THRESHOLD" ]; then
  printf 'full classified\n'
  exit 0
fi

# --- Rule 4: light ---------------------------------------------------------
# Reaching here guarantees body_len ≤ THRESHOLD (rule 3 already excluded the
# over-threshold case), so the type:feat/type:feature branch needs no length
# re-check.
#
# type:feat is the canonical work-kind label emitted by to-issues (see
# plugins/makato-plan/skills/to-issues/references/label-taxonomy.md); type:feature
# is a legacy alias retained for issues filed before the enum consolidation.
# Both map to the light lane here.
if has_label 'effort:xs' || has_label 'effort:s' \
    || has_label 'type:feat' || has_label 'type:feature'; then
  printf 'light classified\n'
  exit 0
fi

# --- Rule 5: safe default --------------------------------------------------
printf 'full classified\n'
