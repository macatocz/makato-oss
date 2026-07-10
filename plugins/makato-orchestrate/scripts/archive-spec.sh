#!/usr/bin/env bash
# archive-spec.sh — deterministic post-merge spec archival (#221).
#
# Mechanical bash port of the archive-spec ARCHIVE path. Runs in GitHub Actions
# on `pull_request: closed` (merged to default branch) with NO Claude CLI on the
# runner — consistent with the D5 "no LLM in the runner" constraint. The archive
# is purely mechanical (derive slug → move folder → append Evolution Log → close
# issue), so it needs no model.
#
# What it does, given a closing ISSUE_NUMBER:
#   1. Derive the spec slug from the issue body (to-issues footer, then the
#      `specs/<slug>/stories.json` fallback) — same logic as loop.sh.
#   2. Prefix-match `specs/<slug>-*/` to find the spec folder.
#   3. If found: append an Evolution Log row to `specs/master/<domain>.md`,
#      move the folder to `specs/archive/<date>-<folder>/`, append the archive
#      index row, and (when the moves produced tracked changes) commit + push.
#   4. Close the GitHub Issue idempotently — skip if already closed (GitHub
#      usually closes it via the PR's `Closes #N` keyword before this runs).
#
# NOTE on this repo: `specs/**` is gitignored here (scratch dir), so on the
# makato repo runner the folder move is a local no-op and the only durable
# effect is the issue closure. In a consumer repo where specs are tracked, the
# move + commit + push persists. The script handles both — it never fails when
# the folder is absent.
#
# Exit codes:
#   0  success, or a tolerated skip (no slug, no folder, already-closed issue)
#   2  usage error (no issue number)
#   3  a `gh` mutation genuinely failed (issue close returned non-zero)
#
# Test hooks (all optional; keep smoke tests fully offline):
#   MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE  path → file used as the issue body
#   MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE OPEN|CLOSED → skip `gh issue view`
#   MAKATO_ARCHIVE_GH_TEST_FILE         path → record `gh` mutations, skip network
#   MAKATO_ARCHIVE_DATE                 YYYY-MM-DD → deterministic date prefix
#   MAKATO_ARCHIVE_SKIP_PUSH            1 → skip `git commit`/`git push`
#   MAKATO_ARCHIVE_SPECS_ROOT           dir → override the specs/ root (tests)
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# log <level> <message>  — structured stderr line; GHA renders ::notice/::error.
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  case "$level" in
    notice)  echo "::notice::archive-spec: $*" >&2 ;;
    warning) echo "::warning::archive-spec: $*" >&2 ;;
    error)   echo "::error::archive-spec: $*" >&2 ;;
    *)       echo "archive-spec: $*" >&2 ;;
  esac
}

# ---------------------------------------------------------------------------
# today — deterministic date prefix (override via MAKATO_ARCHIVE_DATE in tests).
# ---------------------------------------------------------------------------
today() {
  if [[ -n "${MAKATO_ARCHIVE_DATE:-}" ]]; then
    printf '%s\n' "$MAKATO_ARCHIVE_DATE"
  else
    date +%Y-%m-%d
  fi
}

# ---------------------------------------------------------------------------
# repo_root — the git top-level, or CWD if not in a repo (defensive).
# ---------------------------------------------------------------------------
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# ---------------------------------------------------------------------------
# specs_root — override-aware specs/ directory.
# ---------------------------------------------------------------------------
specs_root() {
  if [[ -n "${MAKATO_ARCHIVE_SPECS_ROOT:-}" ]]; then
    printf '%s\n' "$MAKATO_ARCHIVE_SPECS_ROOT"
  else
    printf '%s/specs\n' "$(repo_root)"
  fi
}

# ---------------------------------------------------------------------------
# fetch_body <issue> [<repo>] — the issue body (override-aware). Empty on error.
# ---------------------------------------------------------------------------
fetch_body() {
  local issue="$1" repo="${2:-}"
  if [[ -n "${MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE:-}" ]]; then
    cat "$MAKATO_ARCHIVE_ISSUE_BODY_OVERRIDE" 2>/dev/null || return 0
    return 0
  fi
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
  gh issue view "$issue" "${repo_flag[@]}" --json body --jq '.body' 2>/dev/null || return 0
}

# ---------------------------------------------------------------------------
# derive_slug <issue> [<repo>] — extract the spec slug from the issue body.
# Mirrors loop.sh:_derive_key_for_issue (footer first, stories.json fallback).
# Prints the sanitised slug on stdout; empty string when no provenance found.
# BSD/macOS `sed` compatible (no -E, no PCRE lookarounds).
# ---------------------------------------------------------------------------
derive_slug() {
  local issue="$1" repo="${2:-}"
  local body slug
  body="$(fetch_body "$issue" "$repo")"
  [[ -n "$body" ]] || { printf '\n'; return 0; }

  # Primary: footer line  *Feature slug: `<slug>` — produced by to-issues …*
  slug="$(printf '%s\n' "$body" \
    | sed -n "s/.*Feature slug: \`\([^\`]*\)\` — produced by to-issues.*/\1/p" \
    | head -1)"

  # Fallback: top-of-body provenance  specs/<slug>/stories.json
  if [[ -z "$slug" ]]; then
    slug="$(printf '%s\n' "$body" \
      | sed -n 's|.*specs/\([^/]*\)/stories\.json.*|\1|p' \
      | head -1)"
  fi

  # Sanitise defensively (matches loop.sh) — no-op for well-formed slugs.
  slug="${slug//[^a-zA-Z0-9._-]/-}"
  printf '%s\n' "$slug"
}

# ---------------------------------------------------------------------------
# resolve_folder <slug> <issue> — resolve the spec folder for a slug. Matches
# both the exact folder `specs/<slug>/` (e.g. `specs/agent-skill-routing/`) and
# the prefixed `specs/<slug>-*/` convention (e.g. `specs/<slug>-f2/`), mirroring
# loop.sh's prefix-match while also handling the exact-name case. Disambiguates
# epic collisions (multiple matches) by the issue number found in
# created-issues.json / plan.md. Prints the folder path or nothing (return 1)
# when no folder matches.
# ---------------------------------------------------------------------------
resolve_folder() {
  local slug="$1" issue="$2"
  local root; root="$(specs_root)"
  [[ -d "$root" ]] || return 1

  local -a candidates=()
  # Exact match first (`specs/<slug>/`), then the prefixed convention.
  while IFS= read -r -d '' dir; do
    candidates+=("$dir")
  done < <(find "$root" -maxdepth 1 -type d \( -name "$slug" -o -name "${slug}-*" \) -print0 2>/dev/null)

  [[ "${#candidates[@]}" -gt 0 ]] || return 1

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  # Multiple matches — pick the folder whose provenance references this issue.
  local candidate
  for candidate in "${candidates[@]}"; do
    if grep -qsE '"issue_number"[[:space:]]*:[[:space:]]*'"$issue"'[^0-9]' \
          "$candidate/created-issues.json" "$candidate/plan.md" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  # No disambiguation hit — fall back to the first sorted match (deterministic).
  printf '%s\n' "${candidates[0]}"
}

# ---------------------------------------------------------------------------
# detect_domain <folder> — read `domain:` from plan.md / spec.md frontmatter.
# Defaults to `general`.
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
# summary_for <folder> — a one-line description for the audit rows. Uses the
# first level-1 heading of prd.md / plan.md, else the folder name.
# ---------------------------------------------------------------------------
summary_for() {
  local folder="$1" line="" f
  for f in prd.md plan.md; do
    if [[ -f "$folder/$f" ]]; then
      line="$(sed -n 's/^#[[:space:]]\+\(.*\)/\1/p' "$folder/$f" | head -1)"
      [[ -n "$line" ]] && break
    fi
  done
  # Collapse any pipe chars so we never break the markdown table.
  line="${line//|/-}"
  printf '%s\n' "${line:-$(basename "$folder")}"
}

# ---------------------------------------------------------------------------
# append_evolution_log <master> <date> <feature> <summary>
# Appends one row under the `## Evolution Log` table separator. Creates the
# master spec from the shipped template layout when it does not yet exist.
# ---------------------------------------------------------------------------
append_evolution_log() {
  local master="$1" date="$2" feature="$3" summary="$4"
  local domain; domain="$(basename "$master" .md)"

  if [[ ! -f "$master" ]]; then
    mkdir -p "$(dirname "$master")"
    cat >"$master" <<EOF
# Master Spec: ${domain}

**Last Updated**: ${date}
**Features Merged**: 0

---

## Current Requirements

<!-- Requirements are appended here by archive-spec after each feature merge -->

---

## Evolution Log

| Date | Feature | Change Type | Summary | Rationale |
|------|---------|-------------|---------|-----------|

---

## Superseded Requirements

| Requirement | Superseded By | Date | Feature | Reason |
|-------------|---------------|------|---------|--------|
EOF
  fi

  local row="| ${date} | ${feature} | Archived | ${summary} | Post-merge archival |"

  # Insert the row immediately after the Evolution Log table separator row.
  # awk keeps this robust regardless of surrounding content.
  local tmp="${master}.tmp.$$"
  awk -v row="$row" '
    BEGIN { in_evo = 0; inserted = 0 }
    /^## Evolution Log[[:space:]]*$/ { in_evo = 1 }
    /^## / && !/^## Evolution Log[[:space:]]*$/ { in_evo = 0 }
    {
      print
      if (in_evo && !inserted && $0 ~ /^\|[[:space:]-]+\|/) {
        print row
        inserted = 1
      }
    }
    END {
      # Fallback: table separator never matched — append row at EOF so the
      # audit entry is never silently dropped.
      if (!inserted) print row
    }
  ' "$master" >"$tmp" && mv "$tmp" "$master"
}

# ---------------------------------------------------------------------------
# append_archive_index <date> <folder-basename> <summary> <issue>
# Appends a row to specs/archive/README.md (created if absent).
# ---------------------------------------------------------------------------
append_archive_index() {
  local date="$1" folder="$2" summary="$3" issue="$4"
  local root; root="$(specs_root)"
  local index="$root/archive/README.md"
  mkdir -p "$root/archive"
  if [[ ! -f "$index" ]]; then
    cat >"$index" <<'EOF'
# Archived Specs

| Date | Folder | Description | Issue |
|------|--------|-------------|-------|
EOF
  fi
  printf '| %s | [%s](%s-%s/) | %s | #%s |\n' \
    "$date" "$folder" "$date" "$folder" "$summary" "$issue" >>"$index"
}

# ---------------------------------------------------------------------------
# move_folder <src> <dest> — `git mv` when the folder is tracked, else plain
# `mv`. Returns 0 on success.
# ---------------------------------------------------------------------------
move_folder() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  # Tracked? (git ls-files prints paths only for tracked files.)
  if git ls-files --error-unmatch "$src" >/dev/null 2>&1 \
     || [[ -n "$(git ls-files "$src" 2>/dev/null)" ]]; then
    git mv "$src" "$dest" 2>/dev/null && return 0
  fi
  mv "$src" "$dest"
}

# ---------------------------------------------------------------------------
# commit_and_push <message> — commit staged changes and push, but only when
# there is something staged. No-op when MAKATO_ARCHIVE_SKIP_PUSH=1 or nothing
# is tracked (the makato repo case — specs/ is gitignored).
# ---------------------------------------------------------------------------
commit_and_push() {
  local message="$1"
  [[ "${MAKATO_ARCHIVE_SKIP_PUSH:-}" == "1" ]] && { log info "push skipped (MAKATO_ARCHIVE_SKIP_PUSH=1)"; return 0; }

  git add -A specs 2>/dev/null || true
  if git diff --cached --quiet 2>/dev/null; then
    log notice "no tracked spec changes to commit (specs/ likely gitignored) — skipping commit/push"
    return 0
  fi
  git -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -m "$message" >/dev/null 2>&1 || { log warning "commit failed — leaving working tree as-is"; return 0; }
  if git push >/dev/null 2>&1; then
    log notice "pushed archive commit: $message"
  else
    log warning "push failed — archive commit is local only"
  fi
}

# ---------------------------------------------------------------------------
# issue_state <issue> [<repo>] — prints OPEN or CLOSED (override-aware).
# ---------------------------------------------------------------------------
issue_state() {
  local issue="$1" repo="${2:-}"
  if [[ -n "${MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "$MAKATO_ARCHIVE_ISSUE_STATE_OVERRIDE"
    return 0
  fi
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
  gh issue view "$issue" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
    | tr '[:lower:]' '[:upper:]' || printf 'UNKNOWN\n'
}

# ---------------------------------------------------------------------------
# close_issue <issue> <comment> [<repo>] — idempotent close. Returns 3 on a
# genuine `gh` failure so the workflow surfaces it.
# ---------------------------------------------------------------------------
close_issue() {
  local issue="$1" comment="$2" repo="${3:-}"

  local state; state="$(issue_state "$issue" "$repo")"
  if [[ "$state" == "CLOSED" ]]; then
    log notice "issue #${issue} already closed — skipping (idempotent)"
    return 0
  fi

  if [[ -n "${MAKATO_ARCHIVE_GH_TEST_FILE:-}" ]]; then
    echo "close #${issue} reason=completed comment=${comment} repo=${repo:-<ambient>}" \
      >>"$MAKATO_ARCHIVE_GH_TEST_FILE"
    return 0
  fi

  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
  if gh issue close "$issue" "${repo_flag[@]}" --comment "$comment" --reason completed >/dev/null 2>&1; then
    log notice "closed issue #${issue}"
    return 0
  fi
  log error "failed to close issue #${issue}"
  return 3
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local issue="" pr="" repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="$2"; shift 2 ;;
      --pr)    pr="$2"; shift 2 ;;
      --repo)  repo="$2"; shift 2 ;;
      -h|--help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)
        [[ -z "$issue" ]] && { issue="$1"; shift; continue; }
        log warning "ignoring unexpected argument: $1"; shift ;;
    esac
  done

  if [[ -z "$issue" ]]; then
    log error "no issue number provided (usage: archive-spec.sh --issue N [--pr N] [--repo owner/name])"
    return 2
  fi

  log notice "post-merge archive for issue #${issue}${pr:+ (merged via PR #${pr})}"

  local date; date="$(today)"
  local slug; slug="$(derive_slug "$issue" "$repo")"

  local comment
  if [[ -z "$slug" ]]; then
    log warning "no to-issues provenance in issue #${issue} body — closing issue without archiving a spec folder"
    comment="Archived by post-merge workflow (no spec folder found to move)."
    close_issue "$issue" "$comment" "$repo"
    return $?
  fi

  log notice "issue #${issue} → slug '${slug}'"

  local folder
  if ! folder="$(resolve_folder "$slug" "$issue")"; then
    log warning "no specs/${slug}-*/ folder found — closing issue without moving a folder"
    comment="Archived by post-merge workflow. No local spec folder matched \`specs/${slug}-*/\` (specs may be gitignored on this runner)."
    close_issue "$issue" "$comment" "$repo"
    return $?
  fi

  local folder_base; folder_base="$(basename "$folder")"
  local domain; domain="$(detect_domain "$folder")"
  local summary; summary="$(summary_for "$folder")"
  local root; root="$(specs_root)"
  local master="$root/master/${domain}.md"
  local dest="$root/archive/${date}-${folder_base}"

  log notice "archiving '${folder_base}' → archive/${date}-${folder_base} (domain: ${domain})"

  append_evolution_log "$master" "$date" "$folder_base" "$summary"

  if [[ -e "$dest" ]]; then
    log warning "destination ${dest} already exists — leaving spec folder in place (folder may have been archived already)"
  else
    move_folder "$folder" "$dest"
    append_archive_index "$date" "$folder_base" "$summary" "$issue"
  fi

  commit_and_push "chore(specs): archive ${folder_base} post-merge (#${issue}) [skip ci]"

  comment="Archived: specs moved to \`specs/archive/${date}-${folder_base}/\`. Evolution logged in \`specs/master/${domain}.md\`."
  close_issue "$issue" "$comment" "$repo"
}

main "$@"
