#!/usr/bin/env bash
# auto-merge-decide.sh — decision helper for
# .github/workflows/auto-merge-release-please.yml (#181).
#
# Reads a JSON payload with the shape returned by:
#   gh api "repos/{owner}/{repo}/commits/{sha}/check-runs"
# … i.e. `{ "check_runs": [ {name, status, conclusion}, … ] }`.
#
# Filters out the workflow's own job (SELF_JOB_NAME) so the poll loop
# cannot deadlock waiting on itself, then classifies the remaining runs
# into one of four decisions:
#
#   zero-checks-detected  — filtered list is empty. Caller either counts
#                           this against a bounded budget (zero-checks
#                           countdown for makato's path-filtered
#                           validate.yml) or proceeds straight to merge.
#                           Exit 0.
#   merge                 — every run is `status: completed` AND every
#                           conclusion is in {success, skipped, neutral}.
#                           Exit 0.
#   wait                  — no red conclusions, but at least one run is
#                           still pending (`status != completed`).
#                           Caller sleeps and re-polls. Exit 2.
#   abort                 — at least one run finished with conclusion in
#                           {failure, cancelled, timed_out, action_required}.
#                           Exit 1. Each failing run is echoed to stderr as
#                           `  - <name>: <conclusion>` so the caller can
#                           surface the concrete failure name to the operator.
#
# The exit-code shape (0 / 1 / 2) mirrors sagibeast's convention so the
# calling workflow can `case $?` on the return value without parsing prose.
#
# Usage:
#   auto-merge-decide.sh <check-runs-json-file> <self-job-name>
#
# Contract:
#   - Missing file → exit non-zero with `no such file` diagnostic on stderr.
#   - Missing self-job-name → exit non-zero.
#   - Malformed JSON → exit non-zero with jq's parse error on stderr.
#
# Dependencies: `jq` (already required by every workflow in this repo).
set -euo pipefail

JSON_FILE="${1:?usage: auto-merge-decide.sh <check-runs-json-file> <self-job-name>}"
SELF_JOB_NAME="${2:?usage: auto-merge-decide.sh <check-runs-json-file> <self-job-name>}"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "auto-merge-decide: no such file: $JSON_FILE" >&2
  exit 3
fi

# Filter to non-self runs. `select(.name != $self)` drops any check-run
# whose display-name matches SELF_JOB_NAME — this is the self-reference
# guard sagibeast documents as the deadlock avoidance.
non_self="$(jq --arg self "$SELF_JOB_NAME" \
  '[.check_runs[]? | select(.name != $self) | {name, status, conclusion}]' \
  "$JSON_FILE")"

total="$(jq 'length' <<<"$non_self")"

if [[ "$total" == "0" ]]; then
  echo "zero-checks-detected"
  exit 0
fi

# Red conclusions: anything the GitHub UI shows as a hard failure. `neutral`
# and `skipped` are NOT red — GitHub itself treats them as passing (matches
# sagibeast's semantics).
red_list="$(jq -r '[.[] | select(
  .conclusion == "failure"          or
  .conclusion == "cancelled"        or
  .conclusion == "timed_out"        or
  .conclusion == "action_required"
)] | .[] | "  - \(.name): \(.conclusion // "unknown")"' <<<"$non_self")"

if [[ -n "$red_list" ]]; then
  echo "abort"
  echo "$red_list" >&2
  exit 1
fi

# No red — how many are still running?
pending="$(jq '[.[] | select(.status != "completed")] | length' <<<"$non_self")"

if [[ "$pending" != "0" ]]; then
  echo "wait"
  exit 2
fi

# All completed, no red — final sanity: every conclusion must be in the
# green set. If a caller extended the enum in the future (e.g. a novel
# GHA conclusion string), it would fall through here rather than be
# silently classified as merge.
green="$(jq '[.[] | select(.status == "completed" and (
  .conclusion == "success" or
  .conclusion == "skipped" or
  .conclusion == "neutral"
))] | length' <<<"$non_self")"

if [[ "$green" == "$total" ]]; then
  echo "merge"
  exit 0
fi

# Defensive fallback: a completed run with an unknown conclusion string
# should not silently pass. Treat as abort with an explicit stderr note.
echo "abort"
jq -r '.[] | select(.status == "completed" and .conclusion != null and
  .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral" and
  .conclusion != "failure" and .conclusion != "cancelled" and .conclusion != "timed_out" and .conclusion != "action_required"
) | "  - \(.name): unknown-conclusion:\(.conclusion)"' <<<"$non_self" >&2
exit 1
