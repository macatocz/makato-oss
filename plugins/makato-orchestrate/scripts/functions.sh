#!/usr/bin/env bash
# functions.sh — helper + subcommand functions for loop.sh. Sourced by loop.sh after config parsing.
# Not standalone: relies on config vars and runtime paths loop.sh defines.

# --- Offline board mirror (#9) — sibling module providing mirror_* helpers. ---
# shellcheck source=board-mirror.sh
source "${MAKATO_LOOP_BOARD_MIRROR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-mirror.sh}"

# ISO-8601 timestamp with milliseconds (UTC). Matches workflow-state.sh.
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# _guarded_sleep <seconds> — wall-clock-guaranteed sleep against early wake (#171).
# macOS suspend/resume can cause `sleep N` to return early; this wrapper loops until
# $(date +%s) has advanced by the requested total, capping each raw step at SLEEP_MAX_STEP_SECS.
_guarded_sleep() {
  local target="${1:?_guarded_sleep: target seconds required}"
  local deadline
  deadline=$(( $(date +%s) + target ))
  # Cap each raw-sleep step at SLEEP_MAX_STEP_SECS so a wake event never
  # loses more than one step's worth of wall-clock time (raw sleep of
  # 300 s that returns instantly is still guarded, but polls are
  # bounded — safer than trusting a single long sleep).
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  while :; do
    local now_epoch remaining step
    now_epoch=$(date +%s)
    remaining=$(( deadline - now_epoch ))
    if [[ $remaining -le 0 ]]; then
      return 0
    fi
    step=$remaining
    if [[ $step -gt $SLEEP_MAX_STEP_SECS ]]; then
      step=$SLEEP_MAX_STEP_SECS
    fi
    # shellcheck disable=SC2086
    $sleep_cmd $step 2>/dev/null || true
  done
}

# _read_project_config — read .claude/config.json → github_project; outputs
# {owner, number, host, status_field_name}. Exits 65 if missing or malformed.
_read_project_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: .claude/config.json not found at $CONFIG_FILE — run \`issue-to-project --init\` first" >&2
    return 65
  fi
  local owner number host
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  if [[ -z "$owner" || -z "$number" ]]; then
    echo "loop: github_project.owner / github_project.number missing in $CONFIG_FILE — run \`issue-to-project --init\`" >&2
    return 65
  fi
  jq -n --arg owner "$owner" --arg number "$number" --arg host "$host" \
    '{owner: $owner, number: ($number|tonumber), host: $host}'
}

# _gh_project_item_list <host> <number> <owner> (#289) — bounded-retry wrapper around the board
# poll gh call. Returns raw JSON on success, nothing + non-zero on exhaustion (never fakes empty queue).
#
# ---------------------------------------------------------------------------
# BOARD_QUERY — the GraphQL document _board_via_graphql pages through.
#
# Raw GraphQL instead of `gh project item-list --limit 9999` (#516): hand-written
# items(first:100) costs ~1 point/page vs ~1 point/item — ~100x cheaper on large boards.
# Requests only the fields downstream consumers read (id, Status, content number/title/url/state/
# repository/labels for Issues and PullRequests). DraftIssues are dropped by the remap.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # jq/GraphQL program: $-tokens are query variables, not shell expansions
BOARD_QUERY='query($pid:ID!,$cursor:String){
  rateLimit { cost remaining }
  node(id:$pid){ ... on ProjectV2 {
    items(first:100, after:$cursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id
        fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name optionId } }
        content{ __typename
          ... on Issue{ number title url state repository{nameWithOwner} labels(first:20){nodes{name}} }
          ... on PullRequest{ number title url state repository{nameWithOwner} labels(first:20){nodes{name}} } } } } } } }'

# _board_via_graphql <host> <project_node_id> — page the board via raw GraphQL and emit
# {"items":[...]} in the same shape `gh project item-list --format json` produces.
# Returns non-zero (prints nothing) on any page failure so the retry wrapper treats it
# like a failed gh call — never as an empty queue (#289 contract).
_board_via_graphql() {
  local host="$1" pid="$2"
  local cursor="" acc='[]' resp page has_next
  while :; do
    if [[ -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
      # Offline test hook: eval'd in place of `gh api graphql`; receives cursor via
      # MAKATO_LOOP_GRAPHQL_CURSOR so pagination logic can be exercised without network.
      resp="$(MAKATO_LOOP_GRAPHQL_CURSOR="$cursor" eval "$MAKATO_LOOP_GRAPHQL_TEST_CMD" 2>/dev/null)" || return 1
    elif [[ -n "$cursor" ]]; then
      resp="$(GH_HOST="$host" gh api graphql -F pid="$pid" -F cursor="$cursor" \
        -f query="$BOARD_QUERY" 2>/dev/null)" || return 1
    else
      resp="$(GH_HOST="$host" gh api graphql -F pid="$pid" \
        -f query="$BOARD_QUERY" 2>/dev/null)" || return 1
    fi
    # A truncated / HTML-error / partial response is NOT an empty page — bail
    # so the retry wrapper re-attempts rather than consuming garbage as data.
    _gh_json_valid "$resp" || return 1
    # #492-style label cap guard: labels(first:20) truncates issues with >20
    # labels. Log once per page if any node hit the cap; the loop only reads a
    # handful of status:* labels so truncation is benign, but silence is not.
    if jq -e '[.data.node.items.nodes[]?.content.labels.nodes // [] | length] | any(. >= 20)' \
        >/dev/null 2>&1 <<<"$resp"; then
      echo "loop: WARN — board poll: an item has >=20 labels; labels(first:20) may be truncated" >&2
    fi
    page="$(jq -c '[.data.node.items.nodes[]?
      | select(.content.__typename == "Issue" or .content.__typename == "PullRequest")
      | {
          id: .id,
          status: (.fieldValueByName.name // null),
          status_option_id: (.fieldValueByName.optionId // null),
          labels: [ (.content.labels.nodes // [])[].name ],
          content: {
            type: .content.__typename,
            number: .content.number,
            title: .content.title,
            url: .content.url,
            state: .content.state,
            repository: (.content.repository.nameWithOwner // null)
          }
        }]' <<<"$resp" 2>/dev/null)" || return 1
    acc="$(jq -c --argjson p "$page" '. + $p' <<<"$acc" 2>/dev/null)" || return 1
    has_next="$(jq -r '.data.node.items.pageInfo.hasNextPage' <<<"$resp" 2>/dev/null)"
    [[ "$has_next" == "true" ]] || break
    cursor="$(jq -r '.data.node.items.pageInfo.endCursor' <<<"$resp" 2>/dev/null)"
    [[ -n "$cursor" && "$cursor" != "null" ]] || break
  done
  jq -nc --argjson items "$acc" '{items: $items}'
}

# _project_item_id_for_issue <host> <owner> <repo> <issue> <project_node_id> (#516).
# Resolves the ProjectV2 item id for a single issue in one cheap GraphQL call (~1 point)
# instead of item-list --limit 9999 (~1 point/item). Prints id to stdout; returns non-zero
# when not found or on failure (caller falls back to item-add / item-list).
# shellcheck disable=SC2016  # jq/GraphQL program: $-tokens are query variables, not shell expansions
_ITEM_ID_QUERY='query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$num){
      projectItems(first:20){ nodes{ id project{ id } } }
    }
  }
}'

_project_item_id_for_issue() {
  local host="$1" owner="$2" repo="$3" issue="$4" pid="$5"
  [[ -n "$owner" && -n "$repo" && -n "$issue" && -n "$pid" ]] || return 1

  # Strip an "owner/name" repo into just the name for the GraphQL `name:` arg.
  local repo_name="${repo##*/}"

  local resp
  if [[ -n "${MAKATO_LOOP_ITEM_ID_TEST_CMD:-}" ]]; then
    resp="$(eval "$MAKATO_LOOP_ITEM_ID_TEST_CMD" 2>/dev/null)" || return 1
  else
    resp="$(GH_HOST="$host" gh api graphql \
      -F owner="$owner" -F repo="$repo_name" -F num="$issue" \
      -f query="$_ITEM_ID_QUERY" 2>/dev/null)" || return 1
  fi
  _gh_json_valid "$resp" || return 1

  local item_id
  item_id="$(jq -r --arg pid "$pid" \
    '.data.repository.issue.projectItems.nodes[]?
      | select(.project.id == $pid) | .id' <<<"$resp" 2>/dev/null | head -1)" || return 1
  [[ -n "$item_id" && "$item_id" != "null" ]] || return 1
  printf '%s\n' "$item_id"
}

# _check_graphql_rate_budget <host> (#556) — proactive GraphQL rate-limit guard.
# When RATE_GUARD=1 (default), compares resources.graphql.remaining against
# GRAPHQL_MIN_REMAINING; returns 0 (proceed), sleeps-then-returns-2 (skip tick),
# or returns 0 on guard failure (degrades gracefully). RATE_GUARD=0 is a no-op.
_check_graphql_rate_budget() {
  local host="${1:-}"
  [[ "${RATE_GUARD:-1}" == "1" ]] || return 0

  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local rate_json remaining reset_epoch rc

  rc=0
  if [[ -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
    rate_json="$(eval "$MAKATO_LOOP_GRAPHQL_TEST_CMD" 2>/dev/null)" || rc=$?
  else
    rate_json="$(GH_HOST="${host}" gh api rate_limit 2>/dev/null)" || rc=$?
  fi

  if [[ $rc -ne 0 || -z "$rate_json" ]]; then
    echo "loop: WARN — _check_graphql_rate_budget: gh api rate_limit failed (rc=$rc); skipping guard (#556)" >&2
    return 0
  fi

  remaining="$(jq -r '.resources.graphql.remaining // empty' <<<"$rate_json" 2>/dev/null || true)"
  reset_epoch="$(jq -r '.resources.graphql.reset // empty' <<<"$rate_json" 2>/dev/null || true)"

  if [[ -z "$remaining" || ! "$remaining" =~ ^[0-9]+$ ]]; then
    echo "loop: WARN — _check_graphql_rate_budget: could not parse remaining from rate_limit response; skipping guard (#556)" >&2
    return 0
  fi

  if (( remaining >= GRAPHQL_MIN_REMAINING )); then
    return 0
  fi

  # Budget below floor — sleep until reset, then return 2 (caller skips tick).
  echo "loop: INFO — poll_skipped_rate_budget remaining=$remaining < $GRAPHQL_MIN_REMAINING; sleeping until reset (#556)" >&2
  if [[ -n "$reset_epoch" && "$reset_epoch" =~ ^[0-9]+$ ]]; then
    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    local wait_secs=$(( reset_epoch - now_epoch ))
    (( wait_secs > 0 )) && $sleep_cmd "$wait_secs" 2>/dev/null || true
  fi
  return 2
}

_gh_project_item_list() {
  local host="$1" number="$2" owner="$3"
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local attempt=1 out rc

  # Proactive GraphQL rate-limit guard (#556). Check before the first attempt —
  # if the budget is already below the floor, sleeping now is cheaper than
  # burning remaining tokens and triggering a hard 429 mid-poll.
  # Exit code 2 from the guard means "skip this tick"; propagate as 76
  # (distinct from 75 = transient-poll-failure) so cmd_poll and cmd_run can
  # stamp poll_skipped_rate_budget:true rather than poll_healthy:false.
  #
  # Guard is bypassed when MAKATO_LOOP_POLL_TEST_CMD is set: that hook
  # completely replaces the real `gh` poll (including GraphQL), so a
  # rate-limit check against the real API is irrelevant and would interfere
  # with offline smoke tests whose live budget may be zero (#556).
  if [[ "${RATE_GUARD:-1}" == "1" && -z "${MAKATO_LOOP_POLL_TEST_CMD:-}" ]]; then
    local _rg_rc=0
    _check_graphql_rate_budget "$host" || _rg_rc=$?
    if [[ $_rg_rc -eq 2 ]]; then
      return 76
    fi
  fi

  while (( attempt <= POLL_RETRIES )); do
    # Guard the command-substitution assignment with `|| rc=$?`: under
    # `set -e` a bare `out="$(failing-cmd)"` would abort the function on the
    # first non-zero exit, defeating the retry loop entirely. The `||` keeps
    # the failure local so we can inspect rc and back off.
    rc=0
    if [[ -n "${MAKATO_LOOP_POLL_TEST_CMD:-}" ]]; then
      out="$(MAKATO_LOOP_POLL_ATTEMPT="$attempt" eval "$MAKATO_LOOP_POLL_TEST_CMD" 2>/dev/null)" || rc=$?
    elif [[ "${MAKATO_LOOP_BOARD_MODE:-graphql}" == "item-list" ]]; then
      # Emergency rollback path — the pre-#516 `gh project item-list` call.
      # ~100x more expensive per poll; kept behind an env flag so an operator
      # can fall back instantly if the GraphQL path regresses.
      out="$(GH_HOST="$host" gh project item-list "$number" \
        --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || rc=$?
    else
      # Default path (#516): raw GraphQL, ~1 point/page vs ~1 point/item.
      # Resolve the project node id from config; without it we cannot issue the
      # node(id:) query, so fall back to the item-list call for this attempt.
      local pid=""
      [[ -f "$CONFIG_FILE" ]] && pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
      if [[ -n "$pid" ]]; then
        out="$(_board_via_graphql "$host" "$pid")" || rc=$?
      else
        echo "loop: WARN — github_project.project_node_id missing in config; using costlier item-list path (#516)" >&2
        out="$(GH_HOST="$host" gh project item-list "$number" \
          --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || rc=$?
      fi
    fi
    if [[ $rc -eq 0 ]]; then
      printf '%s' "$out"
      return 0
    fi
    if (( attempt < POLL_RETRIES )); then
      local wait=$(( POLL_BACKOFF_BASE_SECS * (1 << (attempt - 1)) ))
      echo "loop: WARN — board poll attempt $attempt/$POLL_RETRIES failed (gh exit $rc); retrying in ${wait}s (#289)" >&2
      $sleep_cmd "$wait" 2>/dev/null || true
    else
      echo "loop: ERROR — board poll failed after $POLL_RETRIES attempts (gh exit $rc); NOT treating as empty queue (#289)" >&2
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# _gh_json_valid <json-string> (#447) — returns 0 when input parses as JSON, 1 otherwise.
# Distinguishes parseable JSON from garbage (truncated body, HTML error page) so callers
# never consume a malformed gh response as valid data.
# Note: `jq -e .` on a JSON `null`/`false` returns non-zero by design; that is
# acceptable here because every wrapped critical call returns an object.
_gh_json_valid() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$json"
}

# _gh_with_fallback <context> <primary gh args...> -- <rest gh args...> (#447).
# Bounded-retry wrapper with a `gh api` / REST fallback for critical read paths
# (KEY derivation, dispatch-gate label fetch, issue-type routing). Prints raw JSON
# on success; prints nothing and returns non-zero on exhaustion — never masks failure
# as an empty result. Everything before `--` is the primary invocation; everything
# after is the REST fallback (optional; omit to retry primary only).
_gh_with_fallback() {
  local context="$1"; shift
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local test_cmd="${MAKATO_LOOP_FALLBACK_TEST_CMD:-}"

  # Split argv on the literal `--` into primary and REST arg vectors.
  local -a primary_args=() rest_args=()
  local seen_sep=0
  local a
  for a in "$@"; do
    if [[ "$seen_sep" -eq 0 && "$a" == "--" ]]; then
      seen_sep=1
      continue
    fi
    if [[ "$seen_sep" -eq 0 ]]; then
      primary_args+=("$a")
    else
      rest_args+=("$a")
    fi
  done
  # No REST tail supplied → fall back to re-trying the primary args.
  if [[ "${#rest_args[@]}" -eq 0 ]]; then
    rest_args=("${primary_args[@]}")
  fi

  local out rc

  # --- Primary attempt: `gh <primary_args>`. -----------------------------
  rc=0
  if [[ -n "$test_cmd" ]]; then
    out="$(MAKATO_LOOP_FALLBACK_ATTEMPT=0 eval "$test_cmd" 2>/dev/null)" || rc=$?
  else
    out="$(gh "${primary_args[@]}" 2>/dev/null)" || rc=$?
  fi
  if [[ $rc -eq 0 ]] && _gh_json_valid "$out"; then
    printf '%s' "$out"
    return 0
  fi

  # Primary failed (non-zero exit) OR returned unparseable JSON. Both are
  # equally "do not trust this payload" — fall back to REST.
  local reason
  if [[ $rc -ne 0 ]]; then
    reason="gh exit $rc"
  else
    reason="unparseable JSON"
  fi
  echo "loop: WARN — ${context} primary gh failed (${reason}); using REST fallback (#447)" >&2

  local attempt=1
  while (( attempt <= FALLBACK_RETRIES )); do
    rc=0
    if [[ -n "$test_cmd" ]]; then
      out="$(MAKATO_LOOP_FALLBACK_ATTEMPT="$attempt" eval "$test_cmd" 2>/dev/null)" || rc=$?
    else
      out="$(gh "${rest_args[@]}" 2>/dev/null)" || rc=$?
    fi
    if [[ $rc -eq 0 ]] && _gh_json_valid "$out"; then
      printf '%s' "$out"
      return 0
    fi
    if (( attempt < FALLBACK_RETRIES )); then
      local wait=$(( FALLBACK_BACKOFF_BASE_SECS * (1 << (attempt - 1)) ))
      echo "loop: WARN — ${context} REST fallback attempt ${attempt}/${FALLBACK_RETRIES} failed; retrying in ${wait}s (#447)" >&2
      $sleep_cmd "$wait" 2>/dev/null || true
    else
      echo "loop: ERROR — ${context} failed after primary + ${FALLBACK_RETRIES} REST fallback attempts; NOT masking as empty result (#447)" >&2
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# _read_status — read the loop-status file, or echo `{}` if missing.
_read_status() {
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    echo '{}'
  fi
}

# _write_status <json> — atomic write to STATUS_FILE with updated_at stamp.
# Uses same-directory mktemp so mv is a same-filesystem rename(2) — no torn reads.
_write_status() {
  local payload="$1"
  local now
  now="$(_now)"
  local stamped
  stamped="$(jq --arg ts "$now" '. + {updated_at: $ts}' <<<"$payload")"
  local tmp
  tmp="$(mktemp "${STATUS_FILE}.XXXXXX")"
  printf '%s\n' "$stamped" >"$tmp"
  mv "$tmp" "$STATUS_FILE"
}

# _patch_status <path> <value-json> — patch a single jq path in the status file.
# Initialises the file with an empty object if missing.
_patch_status() {
  local path="$1"
  local value="$2"
  local current
  current="$(_read_status)"
  local merged
  merged="$(jq "$path = $value" <<<"$current")"
  _write_status "$merged"
}

# _increment_poll_skip_count / _reset_poll_skip_count — track consecutive
# rate-budget skip ticks for the circuit-breaker (#683).
_increment_poll_skip_count() {
  local cur
  cur="$(_read_status | jq -r '.poll_skip_count // 0')"
  _patch_status '.poll_skip_count' "$((cur + 1))"
}
_reset_poll_skip_count() {
  _patch_status '.poll_skip_count' '0'
}

# _increment_gate_skips — increment gate_skips_total in status file.
# Called by every dispatch-gate skip path (exclusion-label veto, merged-PR, in-flight).
_increment_gate_skips() {
  local cur
  cur="$(_read_status | jq -r '.gate_skips_total // 0')"
  _patch_status '.gate_skips_total' "$((cur + 1))"
}

# _increment_orphan_dispatches — increment orphan_dispatches in status file.
# Called once per orphan dispatch that proceeds (after tiers 1+2 pass). Session-scoped.
_increment_orphan_dispatches() {
  local cur
  cur="$(_read_status | jq -r '.orphan_dispatches // 0')"
  _patch_status '.orphan_dispatches' "$((cur + 1))"
}

# _is_orphan_issue <issue_number> — returns 0 (orphan) when no created-issues.json
# in specs/ references this issue number, 1 (not orphan) when a match is found.
# Missing, zero-byte, or malformed files count as orphan (D11).
_is_orphan_issue() {
  local issue="$1"
  local spec_root="${SPECS_DIR:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}/specs}"
  [[ -d "$spec_root" ]] || return 0  # no specs dir → orphan

  local f
  while IFS= read -r -d '' f; do
    # Skip zero-byte files (D11)
    [[ -s "$f" ]] || continue
    # Attempt jq parse; skip malformed files (D11)
    local matched
    matched="$(jq -r --argjson n "$issue" \
      '[.issues[]? | select(.issue_number == $n)] | length' \
      "$f" 2>/dev/null || echo "0")"
    if [[ "$matched" -gt 0 ]]; then
      return 1  # found — not an orphan
    fi
  done < <(find "$spec_root" -maxdepth 2 -name "created-issues.json" -print0 2>/dev/null)

  return 0  # no referencing file found → orphan
}

# _label_board_conflict <labels_json> <board_status> — tier 3/4 gate (#356).
# Returns 0 (conflict) when any status:* label contradicts the observed board Status;
# returns 1 (no conflict) when no status:* labels are present (board is authoritative).
# AC-5: status:ready-for-dev exemption removed — any status:* label at Ready = conflict.
_label_board_conflict() {
  local labels_json="$1"
  local board_status="$2"
  local dispatch_status="${MAKATO_LOOP_DISPATCH_STATUS:-Ready}"

  # Extract status:* labels from the candidates JSON.
  local status_labels
  status_labels="$(jq -r '[.labels[].name | select(startswith("status:"))] | .[]' \
    <<<"$labels_json" 2>/dev/null || true)"

  # No status:* labels at all — board is authoritative; no conflict.
  [[ -z "$status_labels" ]] && return 1

  # Any status:* label present when the board says dispatch_status → conflict.
  # The former "status:ready-for-dev is aligned" exemption is removed (AC-5).
  if [[ "$board_status" == "$dispatch_status" ]]; then
    return 0  # conflict — any status:* label contradicts the board-only authority
  fi

  # Board is NOT at dispatch_status. Any status:* label present is a conflict.
  return 0
}

# _post_halt_comment <HALT_CODE> <ISSUE_NUMBER> <REPO> [--reason <text>] [--what-to-fix <text>]
# Best-effort wrapper: delegates to shared/post-halt-comment.sh; swallows non-zero exit.
# Derives repo via _derive_reap_repo when empty (#744 fix). Resolves helper relative to
# this script first, falls back to REPO_ROOT plugin mirror.
_post_halt_comment() {
  local halt_code="${1:-}"
  local issue="${2:-}"
  local repo="${3:-}"
  shift 3 2>/dev/null || true

  # Derive repo when the caller passed an empty arg. Every call site passes
  # "${MAKATO_LOOP_DISPATCH_REPO:-}", which is empty in a bare loop process
  # (only GH_HOST is exported). The helper HARD-fails on an empty REPO (exit 1)
  # while the paired `gh issue edit --add-label` derives its repo from the cwd
  # git remote — so the label landed but the comment silently no-op'd every
  # time. Reuse _derive_reap_repo (env override → git remote) to close that
  # asymmetry once for all ~15 call sites (#744 fixed only the script path).
  if [[ -z "$repo" ]]; then
    repo="$(_derive_reap_repo 2>/dev/null || true)"
  fi

  # Resolve the helper next to this script first (plugin cache / marketplace —
  # where it always ships), falling back to the consumer repo-mirror. The prior
  # $REPO_ROOT-only path silently no-op'd in consumer repos (e.g. sagibeast),
  # which vendor the other shared/ scripts as symlinks but not this one, so the
  # needs-human-review comment was never posted (#744).
  local phc_script
  phc_script="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/shared/post-halt-comment.sh"
  if [[ ! -x "$phc_script" ]]; then
    phc_script="$REPO_ROOT/plugins/makato-orchestrate/shared/post-halt-comment.sh"
  fi
  [[ -x "$phc_script" ]] || return 0

  bash "$phc_script" "$halt_code" "$issue" "$repo" "$@" 2>/dev/null || \
    echo "loop: WARN — post-halt-comment failed for #${issue} (${halt_code}); proceeding (best-effort)" >&2
}

# _reconcile_situation <spec_folder> <issue> <phase> <age_secs> — build a compact
# one-line Situation string for HALT-015 comments. Surfaces phase, staleness, last
# orchestrate.jsonl event, last dispatch log line, and audit trail pointer.
# All args optional; best-effort (any read failure yields a shorter string).
_reconcile_situation() {
  local spec_folder="${1:-}" issue="${2:-}" phase="${3:-}" age="${4:-}"
  local -a parts=()

  [[ -n "$phase" && "$phase" != "null" ]] && parts+=("phase \`${phase}\`")

  if [[ -n "$age" ]]; then
    # Humanise seconds → "~2h 15m" so the operator reads staleness at a glance.
    local _h=$(( age / 3600 )) _m=$(( (age % 3600) / 60 ))
    if (( _h > 0 )); then
      parts+=("stale ~${_h}h ${_m}m (${age}s)")
    else
      parts+=("stale ~${_m}m (${age}s)")
    fi
  fi

  # Last orchestrate.jsonl event (step/status) — the last thing the loop logged.
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    local _last_evt
    _last_evt="$(tail -n 1 "$spec_folder/orchestrate.jsonl" 2>/dev/null \
      | jq -r '"\(.step // "?")/\(.status // "?")"' 2>/dev/null || true)"
    [[ -n "$_last_evt" && "$_last_evt" != "?/?" ]] && parts+=("last event \`${_last_evt}\`")
  fi

  # Last meaningful line of the dispatch log (where the session died). Cap at
  # 200 chars so a giant stack trace cannot blow up the comment body.
  local _disp_log="$STATE_DIR/dispatch-${issue}.log"
  if [[ -n "$issue" && -f "$_disp_log" ]]; then
    local _last_log
    _last_log="$(grep -v '^[[:space:]]*$' "$_disp_log" 2>/dev/null | tail -n 1 | cut -c1-200 || true)"
    [[ -n "$_last_log" ]] && parts+=("dispatch died at: \`${_last_log}\`")
  fi

  # Pointer to the spec folder's audit trail.
  [[ -n "$spec_folder" ]] && parts+=("audit trail in \`specs/$(basename "$spec_folder")/\`")

  # Join with "; " (manual join — IFS-based join collapses the space). The
  # `${parts[@]+…}` guard keeps this safe under `set -u` on bash 3.2 (macOS),
  # where an empty-array expansion is otherwise an "unbound variable" error.
  local _out="" _p
  for _p in ${parts[@]+"${parts[@]}"}; do
    if [[ -z "$_out" ]]; then _out="$_p"; else _out="$_out; $_p"; fi
  done
  echo "$_out"
}

# _label_conflict_stamp <ISSUE_NUMBER> — best-effort idempotent stamp of needs-human-review
# on a label-board conflict skip (D11, #356). Swallows non-zero gh exit as WARN.
_label_conflict_stamp() {
  local issue="$1"
  local -a repo_flag=()
  [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    return 0
  fi

  # Ensure the label exists (idempotent create, best-effort).
  if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
    gh label create "needs-human-review" "${repo_flag[@]}" \
      --color "E4E669" --description "Requires human review" >/dev/null 2>&1 || true
  fi

  if gh issue edit "$issue" "${repo_flag[@]}" --add-label "needs-human-review" >/dev/null 2>&1; then
    echo "loop: label-conflict — applied 'needs-human-review' to #$issue" >&2
  else
    echo "loop: WARN — label-conflict — could not stamp needs-human-review on #$issue; proceeding (best-effort, D11)" >&2
  fi
  _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
}

# cmd_check_halt — exit 0 if HALT_FILE absent, exit 1 if present.
cmd_check_halt() {
  if [[ -e "$HALT_FILE" ]]; then
    echo "loop: HALT file present at $HALT_FILE — exiting cleanly" >&2
    return 1
  fi
  return 0
}

# cmd_poll [STATUS_NAME] — emit board items at the requested Status as a JSON array.
# STATUS_NAME may be comma-separated (e.g. "Ready,Todo"); ordering follows list position.
# Closed issues, PRs, and DraftIssue items are filtered out.
# Returns 75 on transient poll failure, 76 on rate-budget skip.
cmd_poll() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local raw
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_GH_OVERRIDE")"
  else
    local cfg
    cfg="$(_read_project_config)" || return 65
    local owner number host
    owner="$(jq -r '.owner' <<<"$cfg")"
    number="$(jq -r '.number' <<<"$cfg")"
    host="$(jq -r '.host' <<<"$cfg")"
    # `gh project item-list` has no host flag — the `gh` CLI resolves the
    # host via `GH_HOST` (auth context) and `--owner`. A bare
    # `gh --hostname …` at this subcommand position fails with
    # `unknown flag: --hostname` and previously left the queue silently
    # empty (issue #156). Route host through the env var instead.
    # `--limit 9999` mirrors plugins/makato-plan/.../board-audit.md — same
    # ceiling, same WARN-on-truncation contract.
    #
    # #289: the poll now goes through _gh_project_item_list, which retries on
    # rate-limit / transient failure and returns non-zero on exhaustion. We
    # return 75 (EX_TEMPFAIL) for any transient failure so cmd_run can stamp
    # poll_healthy:false — a failed poll must NOT read as an empty queue.
    # #556: exit 76 from _gh_project_item_list means the rate-limit guard
    # triggered; propagate as 76 so cmd_run can distinguish "rate-budget skip"
    # from "transient poll error" and stamp poll_skipped_rate_budget:true.
    local _item_list_rc=0
    raw="$(_gh_project_item_list "$host" "$number" "$owner")" || _item_list_rc=$?
    if [[ $_item_list_rc -eq 76 ]]; then
      return 76
    elif [[ $_item_list_rc -ne 0 ]]; then
      # #9: a failed poll no longer halts the queue when a local mirror exists —
      # serve the last-known board so dispatch continues across a GitHub partition.
      local _mirror_board
      if _mirror_board="$(mirror_read)"; then
        echo "loop: WARN — board poll failed; serving from offline mirror (#9)" >&2
        raw="$_mirror_board"
      else
        return 75
      fi
    else
      # Online: refresh the mirror with the fresh board and flush any queued
      # local writes back to GitHub (per-tick bidirectional sync, #9).
      mirror_refresh "$raw"
      mirror_flush "$host"
    fi
  fi
  # Build a list of accepted status names from the comma-separated input.
  # For a single value ("Ready") this is a one-element list and the behaviour
  # is identical to before. For "Ready,Todo" the filter includes both, with
  # list-position ordering preserved by sorting on the index of the status.
  local -a status_list=()
  IFS=',' read -r -a status_list <<<"$status_name"

  # jq: collect all matching items preserving list-position order.
  # Build the accepted-statuses JSON array for the filter.
  local statuses_json
  statuses_json="$(printf '%s\n' "${status_list[@]}" | jq -R . | jq -sc .)"

  jq --argjson statuses "$statuses_json" \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status as $s | $statuses | index($s) != null)
      | {
          issue: .content.number,
          repository: .content.repository,
          title: .content.title,
          url: .content.url,
          status: .status,
          labels: (.labels // []),
          _sort_key: (.status as $s | $statuses | index($s))
        }]
    | sort_by(._sort_key)
    | map(del(._sort_key))' <<<"$raw"
}

# in_flight_issues — emit issue numbers (one per line) whose workflow-state.json
# exists and is NOT in current_phase:"done". These must NOT be re-dispatched.
in_flight_issues() {
  [[ -d "$SPECS_DIR" ]] || return 0
  # One jq invocation per file but only one (not two): extract both fields
  # in a single pass and filter in jq rather than running two greps' worth
  # of forks per file. Per-file error handling preserved — malformed JSON
  # in one workflow-state.json must not crash the whole poll.
  # Glob widened to workflow-state-*.json (#173) so per-issue files under a
  # shared spec folder are all picked up. Legacy workflow-state.json files
  # are read by the -o clause below until their next write triggers migration.
  find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      jq -r 'select(.current_phase != "done") | (.issue_number // empty)' \
        "$f" 2>/dev/null || true
    done | sort -u
}

# _compute_vcr — compute Verified-to-Completed Rate for loop-status.json .vcr field.
# "Verified" = current_phase=="done" in a workflow-state file (dispatch throughput metric,
# not AC pass rate). Output: {"activated":<n>,"verified":<n>,"rate":<f>}.
_compute_vcr() {
  if [[ ! -d "$SPECS_DIR" ]]; then
    echo '{"activated":0,"verified":0,"rate":0.0}'
    return 0
  fi
  local activated=0 verified=0
  while IFS= read -r -d '' f; do
    activated=$(( activated + 1 ))
    local phase
    phase="$(jq -r '.current_phase // empty' "$f" 2>/dev/null || true)"
    if [[ "$phase" == "done" ]]; then
      verified=$(( verified + 1 ))
    fi
  done < <(find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)
  local rate
  if [[ "$activated" -eq 0 ]]; then
    rate="0.0"
  else
    rate="$(python3 -c "print('%.2f' % ($verified / $activated))")"
  fi
  echo "{\"activated\":${activated},\"verified\":${verified},\"rate\":${rate}}"
}

# _dependency_order — emit wave-ordered issue numbers for next-issue selection (#548).
# Calls `promote-ready.sh plan --json`, extracts .waves[] ordered by wave index.
# Read-only (plan --json never writes the board). Returns nothing (FIFO fallback) on any failure.
_dependency_order() {
  local pr_bin="${MAKATO_PROMOTE_PATH:-}"
  if [[ -z "$pr_bin" ]]; then
    # Locate promote-ready.sh relative to this script so it works regardless
    # of PATH (the scripts/ directory may not be on PATH in CI).
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    pr_bin="$script_dir/promote-ready.sh"
  fi

  if [[ ! -x "$pr_bin" ]]; then
    # promote-ready.sh absent or non-executable — degrade to FIFO silently.
    return 0
  fi

  local plan_json
  # Suppress stderr (warnings about missing graph files are expected in repos
  # with no specs directory); exit non-zero is treated as empty list.
  # Thread MAKATO_PROMOTE_SPECS_DIR = SPECS_DIR so promote-ready.sh reads the
  # same graph files as the loop (critical for test isolation where SPECS_DIR
  # is overridden via env). MAKATO_PROMOTE_SPECS_DIR already set → honour it;
  # unset → inherit the loop's SPECS_DIR.
  plan_json="$(MAKATO_PROMOTE_SPECS_DIR="${MAKATO_PROMOTE_SPECS_DIR:-$SPECS_DIR}" \
    "$pr_bin" plan --json 2>/dev/null)" || return 0

  # Validate JSON before jq; an empty string or non-JSON output exits 0 (FIFO).
  if ! jq empty <<<"$plan_json" 2>/dev/null; then
    return 0
  fi

  # Extract issues ordered by wave index (wave 0 = index 0, wave 1 = index 1,
  # …). .waves is an array of arrays; the outer array index IS the wave number.
  # FIFO order within each wave is preserved (jq preserves insertion order).
  # Issues in .ready[] are always wave-0 candidates already eligible for
  # promotion — they form the same set as .waves[0] when the graph is fresh.
  # However, issues already at Status=Ready on the board appear in .waves but
  # NOT in .ready[] (the forward-only filter skips them). We want all issues
  # the graph considers unblocked/wave-ordered regardless of current board
  # status, so we walk .waves directly.
  jq -r '
    .waves
    | to_entries
    | sort_by(.key)
    | .[].value[]
    | .issue
  ' <<<"$plan_json" 2>/dev/null || true
}

# _check_pending_handoffs — HALT-007B liveness watchdog sweep (#284).
# For each workflow-state with handoff_reason=="context_ceiling" and a spawned_pid,
# calls context-handoff.sh check-pid to detect dead resume subprocesses and fire
# the HALT-007 fallback. Best-effort — any error is swallowed.
_check_pending_handoffs() {
  [[ -d "$SPECS_DIR" ]] || return 0
  local handoff_script="$REPO_ROOT/plugins/makato-orchestrate/scripts/context-handoff.sh"
  [[ -x "$handoff_script" ]] || return 0
  find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      local handoff_reason spawned_pid issue key
      handoff_reason="$(jq -r '.handoff_reason // "null"' "$f" 2>/dev/null || echo null)"
      spawned_pid="$(jq -r '.spawned_pid // "null"' "$f" 2>/dev/null || echo null)"
      [[ "$handoff_reason" == "context_ceiling" && "$spawned_pid" != "null" ]] || continue
      issue="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
      [[ -n "$issue" ]] || continue
      # KEY is the spec-folder basename (workflow-state.sh resolves it to this
      # exact dir); e.g. specs/284-halt-007b-silent-fork/workflow-state-284.json.
      key="$(basename "$(dirname "$f")")"
      echo "loop: check-pid #$issue (HALT-007B handoff pending, spawned_pid=$spawned_pid)" >&2
      "$handoff_script" check-pid "$key" "$issue" 2>&1 | sed 's/^/loop:   /' >&2 || true
    done
}

# _reconcile_orphaned_in_progress — pre-poll pass (#368): move "In progress" cards
# with no live workflow-state to Blocked + needs-human-review. Guards:
# RECONCILE_ON_POLL==0 skips; RECONCILE_DRYRUN==1 logs only. Best-effort.

# _reconcile_issue_closed <issue> <repo> (#616) — terminal-state guard shared by both
# reconcile passes. Returns 0 (closed → caller must skip) when the issue is CLOSED;
# returns 1 (open or unknown) otherwise. Prevents reconcilers from re-blocking
# already-merged issues whose workflow-state never reached current_phase:"done".
_reconcile_issue_closed() {
  local issue="$1" repo="${2:-}"
  [[ -n "$issue" ]] || return 1

  local state=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE:-}" ]]; then
    state="$(jq -r --arg n "$issue" '.[$n] // empty' \
      "$MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE" 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' || true)"
  else
    [[ -n "$repo" ]] || repo="$(_derive_reap_repo 2>/dev/null || true)"
    local -a repo_flag=()
    [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
    state="$(gh issue view "$issue" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' || true)"
  fi

  [[ "$state" == "CLOSED" ]] && return 0
  return 1
}

# _reconcile_has_human_review_label <issue> <repo> — dedup guard for the stale reconciler (#786).
# Returns 0 (label present → caller must skip) when needs-human-review is already set;
# returns 1 (absent or unknown) otherwise. Prevents 6-8× duplicate comments on already-
# reconciled orphans (the stale reconciler never deletes state files, so gates re-fire every tick).
_reconcile_has_human_review_label() {
  local issue="$1" repo="${2:-}"
  [[ -n "$issue" ]] || return 1

  local labels=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE:-}" ]]; then
    labels="$(jq -r --arg n "$issue" '(.[$n] // []) | .[]' \
      "$MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE" 2>/dev/null || true)"
  else
    [[ -n "$repo" ]] || repo="$(_derive_reap_repo 2>/dev/null || true)"
    local -a repo_flag=()
    [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
    labels="$(gh issue view "$issue" "${repo_flag[@]}" --json labels \
      --jq '.labels[].name' 2>/dev/null || true)"
  fi

  grep -qx "needs-human-review" <<<"$labels" && return 0
  return 1
}

_reconcile_orphaned_in_progress() {
  [[ "$RECONCILE_ON_POLL" != "0" ]] || return 0
  [[ -n "${MAKATO_LOOP_TEST_HOOK:-}" ]] || {
    local cfg
    cfg="$(_read_project_config 2>/dev/null)" || {
      echo "loop: reconcile-orphaned — no project config, skipping" >&2
      return 0
    }
  }

  # Fetch "In progress" items from the board (or test fixture).
  local raw
  if [[ -n "${MAKATO_LOOP_RECONCILE_GH_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_RECONCILE_GH_OVERRIDE")" || {
      echo "loop: WARN — reconcile-orphaned: could not read fixture ${MAKATO_LOOP_RECONCILE_GH_OVERRIDE}" >&2
      return 0
    }
  else
    local cfg owner number host
    cfg="$(_read_project_config 2>/dev/null)" || return 0
    owner="$(jq -r '.owner' <<<"$cfg")"
    number="$(jq -r '.number' <<<"$cfg")"
    host="$(jq -r '.host' <<<"$cfg")"
    # #516: use cheap raw-GraphQL poll instead of item-list; avoids sleeping rate-limit guard (wrong for best-effort reconcile).
    local _recon_rc=0 pid=""
    [[ -f "$CONFIG_FILE" ]] && pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$pid" ]]; then
      raw="$(_board_via_graphql "$host" "$pid")" || _recon_rc=$?
    else
      # No node id cached — fall back to costlier item-list (never through sleeping guard).
      raw="$(GH_HOST="$host" gh project item-list "$number" \
        --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || _recon_rc=$?
    fi
    if [[ "$_recon_rc" -ne 0 ]]; then
      echo "loop: WARN — reconcile-orphaned: board poll failed (rc=$_recon_rc), skipping" >&2
      return 0
    fi
  fi

  # Filter to Issue items at "In progress".
  local candidates
  candidates="$(jq -r \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status == "In progress")
      | .content.number] | .[]' \
    <<<"$raw" 2>/dev/null)" || {
    echo "loop: WARN — reconcile-orphaned: jq parse failed" >&2
    return 0
  }

  [[ -n "$candidates" ]] || return 0

  # Build the current in-flight set once.
  # MAKATO_LOOP_RECONCILE_SPECS_DIR overrides SPECS_DIR for tests.
  local reconcile_specs_dir="${MAKATO_LOOP_RECONCILE_SPECS_DIR:-$SPECS_DIR}"
  local in_flight
  in_flight="$(SPECS_DIR="$reconcile_specs_dir" in_flight_issues 2>/dev/null || true)"

  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    # Skip if a live (non-done) workflow-state exists for this issue.
    if echo "$in_flight" | grep -qx "$n"; then
      echo "loop: reconcile-orphaned — #$n has live workflow-state, skipping" >&2
      continue
    fi

    # Terminal-state guard (#616 follow-up): a CLOSED issue is finished work,
    # never a dead orphan. Skip so a Done+closed card is not re-Blocked forever.
    if _reconcile_issue_closed "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}"; then
      echo "loop: reconcile-orphaned — #$n is CLOSED, skipping (terminal state, not an orphan)" >&2
      continue
    fi

    if [[ "${RECONCILE_DRYRUN:-0}" == "1" ]]; then
      echo "loop: reconcile-orphaned — would reconcile #$n → Blocked + needs-human-review (dry-run)" >&2
      continue
    fi

    echo "loop: reconcile-orphaned — #$n orphaned (In progress but no live workflow-state) → Blocked + needs-human-review" >&2

    # board_edit_ok=1 only when edit lands; label stamp gated on it to prevent
    # infinite oscillation if item-edit silently fails.
    local board_edit_ok=0
    {
      if [[ -n "${MAKATO_LOOP_RECONCILE_TEST_FILE:-}" ]]; then
        echo "reconcile #${n}" >>"$MAKATO_LOOP_RECONCILE_TEST_FILE"
        board_edit_ok=1
      else
        local cfg item_id blocked_id proj_owner proj_number proj_host field_id proj_node_id
        cfg="$(_read_project_config 2>/dev/null)" || { echo "loop: WARN — reconcile-orphaned #$n: no config for board edit" >&2; true; }
        proj_owner="$(jq -r '.owner' <<<"$cfg")"
        proj_number="$(jq -r '.number' <<<"$cfg")"
        proj_host="$(jq -r '.host' <<<"$cfg")"
        # #492: read field/option ids from $CONFIG_FILE with full `.github_project.` prefix.
        field_id="$(jq -r '.github_project.fields.status.id // .github_project.status_field_id // empty' "$CONFIG_FILE")"
        blocked_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE")"
        proj_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        if [[ -z "$field_id" || -z "$blocked_id" || -z "$proj_node_id" ]]; then
          echo "loop: WARN — reconcile-orphaned #$n: missing field_id, blocked option id, or project_node_id in config" >&2
        else
          # Resolve item-id from already-fetched $raw (avoids second board scan per candidate).
          # `// empty` collapses null .id to no output rather than literal "null".
          item_id="$(jq -r --argjson n "$n" \
            '.items[] | select(.content.type == "Issue" and .content.number == $n) | (.id // empty)' \
            <<<"$raw" 2>/dev/null | head -1)" || true
          if [[ -n "$item_id" ]]; then
            if GH_HOST="$proj_host" gh project item-edit \
              --id "$item_id" \
              --project-id "$proj_node_id" \
              --field-id "$field_id" \
              --single-select-option-id "$blocked_id" \
              >/dev/null 2>&1; then
              board_edit_ok=1
            else
              echo "loop: WARN — reconcile-orphaned #$n: gh project item-edit failed" >&2
            fi
          else
            echo "loop: WARN — reconcile-orphaned #$n: could not resolve board item-id" >&2
          fi
        fi
      fi
    } || true

    # Apply needs-human-review label only when board edit succeeded to prevent infinite oscillation.
    [[ "$board_edit_ok" -eq 1 ]] || { echo "loop: WARN — reconcile-orphaned #$n: skipping label stamp (board edit did not succeed)" >&2; continue; }
    # HALT-015 (orphaned card, dead session) — Situation built before the escalate
    # entry so the last dispatch event is captured, not this reconciler line (#786).
    local _ro_situation
    _ro_situation="$(_reconcile_situation "" "$n" "" "" 2>/dev/null || true)"
    {
      local repo_flag=()
      if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
        repo_flag=(--repo "$MAKATO_LOOP_DISPATCH_REPO")
      fi
      if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE:-}" ]]; then
        echo "label #${n} needs-human-review" >>"$MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE"
        _post_halt_comment "HALT-015" "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_ro_situation" || true
      else
        if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
          gh label create "needs-human-review" "${repo_flag[@]}" \
            --color "e4e669" --description "Needs human attention before autonomous dispatch" \
            >/dev/null 2>&1 || true
        fi
        if ! gh issue edit "$n" "${repo_flag[@]}" \
            --add-label "needs-human-review" >/dev/null 2>&1; then
          echo "loop: WARN — reconcile-orphaned #$n: could not apply needs-human-review label" >&2
        else
          echo "loop: reconcile-orphaned — applied 'needs-human-review' label to #$n" >&2
        fi
        _post_halt_comment "HALT-015" "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_ro_situation" || true
      fi
    } || true
  done <<<"$candidates"

  return 0
}

# ---------------------------------------------------------------------------
# cmd_reconcile_orphaned — standalone subcommand: run one reconciliation pass.
# ---------------------------------------------------------------------------
cmd_reconcile_orphaned() {
  _reconcile_orphaned_in_progress
}

# ---------------------------------------------------------------------------
# _reconcile_orphaned_stale — per-tick pass (#616): recovers non-done
# workflow-state files whose owner pid is dead and updated_at is stale.
# ---------------------------------------------------------------------------
_reconcile_orphaned_stale() {
  [[ "$ORPHAN_DETECT_DISABLE" != "1" ]] || return 0

  local scan_specs_dir="${MAKATO_LOOP_RECONCILE_SPECS_DIR:-$SPECS_DIR}"
  [[ -d "$scan_specs_dir" ]] || return 0

  local now_epoch
  now_epoch="$(_reap_epoch_of_iso "$(_now)" 2>/dev/null || echo "")"

  local f
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue

    # Read phase, issue number, worktree_path, updated_at in one pass.
    local phase issue_n wt updated_at
    phase="$(jq -r '.current_phase // "null"' "$f" 2>/dev/null || echo "null")"
    [[ "$phase" != "done" && "$phase" != "null" ]] || continue
    issue_n="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    [[ -n "$issue_n" ]] || continue
    local _rs_repo=""
    _rs_repo="$(jq -r '.repo // empty' "$f" 2>/dev/null || true)"
    wt="$(jq -r '.worktree_path // ""' "$f" 2>/dev/null || true)"
    updated_at="$(jq -r '.updated_at // ""' "$f" 2>/dev/null || true)"

    # Liveness gate — live owner always skipped; absent worktree_path treated as dead.
    if [[ -n "$wt" && "$wt" != "null" ]] && _reap_owner_pid_alive "$wt"; then
      echo "loop: reconcile-stale — #$issue_n owner pid alive, skipping" >&2
      continue
    fi

    # Terminal-state guard (#616 follow-up): closed issue is finished, not a dead orphan.
    if _reconcile_issue_closed "$issue_n" "$_rs_repo"; then
      echo "loop: reconcile-stale — #$issue_n is CLOSED, skipping (terminal state, not an orphan)" >&2
      continue
    fi

    # Dedup guard (#786): state file never deleted, so skip if already needs-human-review.
    if _reconcile_has_human_review_label "$issue_n" "$_rs_repo"; then
      echo "loop: reconcile-stale — #$issue_n already needs-human-review, skipping (already reconciled)" >&2
      continue
    fi

    # Staleness gate — updated_at older than ORPHAN_STALE_SECS.
    local age=""
    if [[ -n "$updated_at" && -n "$now_epoch" ]]; then
      local upd_epoch
      upd_epoch="$(_reap_epoch_of_iso "$updated_at" 2>/dev/null || echo "")"
      if [[ -n "$upd_epoch" ]]; then
        age=$(( now_epoch - upd_epoch ))
        (( age < 0 )) && age=0
      fi
    fi
    if [[ -z "$age" ]]; then
      # Unparseable timestamp — be conservative, do not fire.
      echo "loop: reconcile-stale — #$issue_n unparseable updated_at, skipping" >&2
      continue
    fi
    if (( age < ORPHAN_STALE_SECS )); then
      echo "loop: reconcile-stale — #$issue_n fresh (${age}s < ${ORPHAN_STALE_SECS}s), skipping" >&2
      continue
    fi

    if [[ "${RECONCILE_DRYRUN:-0}" == "1" ]]; then
      echo "loop: reconcile-stale — would reconcile #$issue_n (phase=$phase) → Blocked + needs-human-review (dead owner, age ${age}s, dry-run)" >&2
      continue
    fi

    # reap-and-resume: if phase=pr with a live PR, route to _stall_resume instead
    # of escalating — the po-agent was killed after PR creation but before CI poll.
    if [[ "${MAKATO_LOOP_PR_RESUME_DISABLE:-0}" != "1" && "$phase" == "pr" ]]; then
      local pr_num=""
      pr_num="$(jq -r '.github_pr_number // empty' "$f" 2>/dev/null || true)"
      if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
        # Dispatch guard (#171): returns 0 when same issue dispatched within window → defer.
        if _within_dispatch_guard "$issue_n" 2>/dev/null; then
          echo "loop: reconcile-stale — #$issue_n dispatch guard active, deferring reap-resume to next cycle" >&2
          continue
        fi
        # Lookup PR state via test hook or gh API.
        local pr_state=""
        if [[ -n "${MAKATO_LOOP_PR_STATE_OVERRIDE:-}" && -f "$MAKATO_LOOP_PR_STATE_OVERRIDE" ]]; then
          pr_state="$(jq -r --arg n "$pr_num" '.[$n] // empty' "$MAKATO_LOOP_PR_STATE_OVERRIDE" 2>/dev/null || true)"
        elif [[ -n "$_rs_repo" ]]; then
          pr_state="$(GH_HOST="${GH_HOST:-github.com}" gh pr view "$pr_num" \
            --repo "$_rs_repo" --json state --jq '.state' 2>/dev/null || true)"
        fi
        local spec_dir
        spec_dir="$(dirname "$f")"
        local key_for_resume
        key_for_resume="$(basename "$spec_dir")"
        local now_ts_r
        now_ts_r="$(_now)"
        local orch_log_r="$spec_dir/orchestrate.jsonl"
        if [[ "$pr_state" == "OPEN" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} OPEN, dead owner → reap-and-resume" >&2
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-and-resume\",\"status\":\"attempt\",\"data\":{\"pr_num\":$pr_num,\"phase\":\"$phase\",\"age_secs\":$age}}" \
            >>"$orch_log_r" 2>/dev/null || true
          _stall_resume "$issue_n" "$key_for_resume" "$spec_dir" "" || true
          continue
        elif [[ "$pr_state" == "MERGED" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} MERGED out-of-band → patching done" >&2
          jq '.current_phase = "done"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f" || true
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-done-ooband\",\"status\":\"ok\",\"data\":{\"pr_num\":$pr_num,\"phase_was\":\"$phase\"}}" \
            >>"$orch_log_r" 2>/dev/null || true
          continue
        elif [[ "$pr_state" == "CLOSED" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} CLOSED (not merged) → falling through to escalation" >&2
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-closed-fallthrough\",\"status\":\"warn\",\"data\":{\"pr_num\":$pr_num,\"phase\":\"$phase\"}}" \
            >>"$orch_log_r" 2>/dev/null || true
          # fall through to existing escalation
        elif [[ -z "$pr_state" ]]; then
          echo "loop: WARN — reconcile-stale #$issue_n: could not determine PR #${pr_num} state → falling through to escalation" >&2
          # fall through to existing escalation
        fi
      fi
    fi

    echo "loop: reconcile-stale — #$issue_n orphaned (phase=$phase, owner dead, age ${age}s) → Blocked + needs-human-review" >&2

    # Build Situation BEFORE emitting escalate entry (#786): captures last dispatch event, not this line.
    # HALT-015 (dead session), not HALT-014 (stall ceiling).
    local _rs_situation
    _rs_situation="$(_reconcile_situation "$(dirname "$f")" "$issue_n" "$phase" "$age" 2>/dev/null || true)"

    # Emit orchestrate.jsonl escalate entry (best-effort).
    {
      local orch_log
      orch_log="$(dirname "$f")/orchestrate.jsonl"
      local now_ts
      now_ts="$(_now)"
      echo "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reconcile-orphaned-stale\",\"status\":\"escalate\",\"data\":{\"phase\":\"$phase\",\"age_secs\":$age,\"orphan_stale_secs\":$ORPHAN_STALE_SECS}}" \
        >>"$orch_log" 2>/dev/null || true
    } || true

    # Move board card to Blocked; gate label stamp on success to prevent oscillation.
    local board_edit_ok=0
    {
      if [[ -n "${MAKATO_LOOP_RECONCILE_TEST_FILE:-}" ]]; then
        echo "reconcile #${issue_n}" >>"$MAKATO_LOOP_RECONCILE_TEST_FILE"
        board_edit_ok=1
      else
        local cfg proj_owner proj_number proj_host field_id blocked_id item_id proj_node_id
        cfg="$(_read_project_config 2>/dev/null)" || { echo "loop: WARN — reconcile-stale #$issue_n: no config for board edit" >&2; true; }
        proj_owner="$(jq -r '.owner' <<<"$cfg")"
        proj_number="$(jq -r '.number' <<<"$cfg")"
        proj_host="$(jq -r '.host' <<<"$cfg")"
        field_id="$(jq -r '.github_project.fields.status.id // .github_project.status_field_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        blocked_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE" 2>/dev/null)"
        proj_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        if [[ -z "$field_id" || -z "$blocked_id" || -z "$proj_node_id" ]]; then
          echo "loop: WARN — reconcile-stale #$issue_n: missing field_id, blocked option id, or project_node_id in config" >&2
        else
          # Rate-budget pre-check (#683): skip if budget low; sleep acceptable here (infrequent).
          if [[ "${RATE_GUARD:-1}" == "1" ]]; then
            local _rs_rg_rc=0
            _check_graphql_rate_budget "$proj_host" || _rs_rg_rc=$?
            if [[ $_rs_rg_rc -eq 2 ]]; then
              echo "loop: WARN — reconcile-stale #$issue_n: rate budget low; skipping board item-id lookup this tick (#683)" >&2
              continue
            fi
          fi
          local _rs_item_cmd_out=""
          item_id=""
          if [[ -n "${MAKATO_LOOP_STALE_REAP_TEST_CMD:-}" ]]; then
            _rs_item_cmd_out="$(eval "$MAKATO_LOOP_STALE_REAP_TEST_CMD" 2>/dev/null)" || true
          elif [[ -n "$_rs_repo" ]]; then
            # Cheap single-issue lookup (~1 GraphQL point) instead of item-list --limit 9999.
            item_id="$(_project_item_id_for_issue "$proj_host" "$proj_owner" "$_rs_repo" "$issue_n" "$proj_node_id" || true)"
          fi
          if [[ -z "$item_id" ]]; then
            if [[ -z "$_rs_item_cmd_out" && -z "${MAKATO_LOOP_STALE_REAP_TEST_CMD:-}" ]]; then
              _rs_item_cmd_out="$(GH_HOST="$proj_host" gh project item-list "$proj_number" \
                --owner "$proj_owner" --format json --limit 9999 2>/dev/null)" || true
            fi
            item_id="$(jq -r --argjson n "$issue_n" \
              '.items[] | select(.content.type == "Issue" and .content.number == $n) | .id' \
              <<<"$_rs_item_cmd_out" 2>/dev/null | head -1)" || true
          fi
          if [[ -n "$item_id" ]]; then
            if GH_HOST="$proj_host" gh project item-edit \
              --id "$item_id" \
              --project-id "$proj_node_id" \
              --field-id "$field_id" \
              --single-select-option-id "$blocked_id" \
              >/dev/null 2>&1; then
              board_edit_ok=1
            else
              echo "loop: WARN — reconcile-stale #$issue_n: gh project item-edit failed" >&2
            fi
          else
            echo "loop: WARN — reconcile-stale #$issue_n: could not resolve board item-id" >&2
          fi
        fi
      fi
    } || true

    # Apply needs-human-review label only when board edit succeeded.
    # (_rs_situation computed before escalate entry — captures last dispatch event, not this line.)
    [[ "$board_edit_ok" -eq 1 ]] || { echo "loop: WARN — reconcile-stale #$issue_n: skipping label stamp (board edit did not succeed)" >&2; continue; }
    {
      local repo_flag=()
      if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
        repo_flag=(--repo "$MAKATO_LOOP_DISPATCH_REPO")
      fi
      if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE:-}" ]]; then
        echo "label #${issue_n} needs-human-review" >>"$MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE"
        _post_halt_comment "HALT-015" "$issue_n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_rs_situation" || true
      else
        if ! gh issue edit "$issue_n" "${repo_flag[@]}" \
            --add-label "needs-human-review" >/dev/null 2>&1; then
          echo "loop: WARN — reconcile-stale #$issue_n: could not apply needs-human-review label" >&2
        else
          echo "loop: reconcile-stale — applied 'needs-human-review' label to #$issue_n" >&2
        fi
        _post_halt_comment "HALT-015" "$issue_n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_rs_situation" || true
      fi
    } || true
  done < <(find "$scan_specs_dir" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  return 0
}

# ---------------------------------------------------------------------------
# cmd_reconcile_stale — standalone subcommand: run one stale-orphan pass.
# ---------------------------------------------------------------------------
cmd_reconcile_stale() {
  _reconcile_orphaned_stale
}

# ---------------------------------------------------------------------------
# next [STATUS_NAME] — first untracked open issue at the requested Status.
# ---------------------------------------------------------------------------
cmd_next() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local queue
  queue="$(cmd_poll "$status_name")"
  local in_flight
  in_flight="$(in_flight_issues)"
  jq -r --argjson in_flight \
    "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
    '.[] | .issue as $n
      | select(($in_flight | index($n|tostring) | not)) | $n' \
    <<<"$queue" | head -1
}

# ---------------------------------------------------------------------------
# status — pretty-print the status file.
# ---------------------------------------------------------------------------
cmd_status() {
  local s
  s="$(_read_status)"
  # Pretty-print with vcr sorted after other top-level fields.
  jq 'if .vcr then
    . | to_entries
    | sort_by(
        if .key == "vcr" then 1
        elif .key == "updated_at" then 2
        else 0 end)
    | from_entries
  else . end' <<<"$s"
}

# ---------------------------------------------------------------------------
# _wd_owns_active <issue> — watchdog ownership CAS (#312). Returns 0 iff the
# live status file still names <issue> as the active workflow, preventing an
# orphaned watchdog from writing stale active_workflow.* state (T30 smoke flake).
# ---------------------------------------------------------------------------
_wd_owns_active() {
  local issue="$1"
  local cur
  cur="$(_read_status | jq -r '.active_workflow.issue // empty' 2>/dev/null || echo "")"
  [[ "$cur" == "$issue" ]]
}

# ---------------------------------------------------------------------------
# _watchdog_poll — background helper spawned by cmd_dispatch. Polls log mtime
# every STALL_POLL_SECS; stamps stalled after STALL_WARN_SECS; SIGTERM/SIGKILL
# after STALL_KILL_SECS. Terminates when its parent exits or the tracked PID dies.
# Args: <log-file> <child-pid> <issue-number>
# ---------------------------------------------------------------------------
_watchdog_poll() {
  local log_file="$1"
  local child_pid="$2"
  local issue="$3"

  local warn_stamped=0
  local killed=0

  # Ownership guard (#312): skip if this issue is no longer active. See _wd_owns_active.

  # `stat -c` on Linux, `stat -f` on macOS. Detect once.
  local stat_cmd
  if stat -c '%Y' "$log_file" >/dev/null 2>&1; then
    stat_cmd='stat -c %Y'
  else
    stat_cmd='stat -f %m'
  fi

  while :; do
    # If the tracked PID is gone, parent has reaped it — exit quietly.
    if ! kill -0 "$child_pid" 2>/dev/null; then
      return 0
    fi

    # If the log has been removed (parent cleanup) bail out defensively.
    if [[ ! -e "$log_file" ]]; then
      return 0
    fi

    local mtime now_epoch idle
    mtime="$($stat_cmd "$log_file" 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    idle=$((now_epoch - mtime))

    if [[ $killed -eq 0 && $idle -ge $STALL_KILL_SECS ]]; then
      # Orphan guard: if we no longer own the active slot, kill the child but skip active_workflow writes.
      local own_kill=1
      _wd_owns_active "$issue" || own_kill=0
      # Snapshot kill audit BEFORE signalling; last_watchdog_kill survives the active_workflow=null clear.
      # Classify stall cause (#444): halt_code from workflow-state; stall_restart_count from loop-status.
      local stall_cause
      local _wf_halt_code=""
      local _wf_file
      _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
        -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
      if [[ -f "$_wf_file" ]]; then
        _wf_halt_code="$(jq -r '(.halt_audit // []) | last | .code // empty' "$_wf_file" 2>/dev/null || true)"
      fi
      local _restart_count=0
      _restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      if [[ -n "$_wf_halt_code" ]]; then
        stall_cause="halt_emitted"
      elif [[ "$_restart_count" -ge "$MAX_STALL_RESTARTS" ]]; then
        stall_cause="no_progress"
      else
        stall_cause="transient"
      fi
      local kill_stamp
      kill_stamp="$(_now)"
      local audit
      audit="$(jq -n --argjson issue "$issue" \
        --arg stamped_at "$kill_stamp" \
        --argjson idle "$idle" \
        --argjson kill_secs "$STALL_KILL_SECS" \
        --arg stall_cause "$stall_cause" \
        '{issue: $issue, killed_at: $stamped_at, idle_seconds: $idle, stall_kill_seconds: $kill_secs, stall_cause: $stall_cause}')"
      if [[ $own_kill -eq 1 ]]; then
        _patch_status '.last_watchdog_kill' "$audit"
        _patch_status '.active_workflow.killed_by_watchdog' 'true'
      fi
      echo "loop: watchdog SIGTERM'ing PO-agent pid=$child_pid (issue #$issue, idle=${idle}s ≥ ${STALL_KILL_SECS}s)" >&2
      kill -TERM "$child_pid" 2>/dev/null || true
      # Grace period, then hard-kill if the child hasn't exited.
      local waited=0
      while [[ $waited -lt $STALL_TERM_GRACE_SECS ]] && kill -0 "$child_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$child_pid" 2>/dev/null; then
        echo "loop: watchdog SIGKILL'ing PO-agent pid=$child_pid (still alive after ${STALL_TERM_GRACE_SECS}s)" >&2
        kill -KILL "$child_pid" 2>/dev/null || true
      fi
      killed=1
      return 0
    fi

    if [[ $warn_stamped -eq 0 && $idle -ge $STALL_WARN_SECS ]]; then
      # Same orphan guard as the kill path: never stamp stalled on a status we no longer own.
      if _wd_owns_active "$issue"; then
        local warn_stamp
        warn_stamp="$(_now)"
        _patch_status '.active_workflow.stalled' 'true'
        _patch_status '.active_workflow.stalled_since' "\"$warn_stamp\""
        echo "loop: watchdog WARN — PO-agent idle for ${idle}s ≥ ${STALL_WARN_SECS}s (issue #$issue)" >&2
        warn_stamped=1
      fi
    fi

    sleep "$STALL_POLL_SECS"
  done
}

# ---------------------------------------------------------------------------
# _stall_restart <issue> <spec-folder> <log-file> (#444)
# Routes by last_watchdog_kill.stall_cause: halt_emitted → skip;
# transient → bounded exponential-backoff restart; no_progress → HALT-014 escalate.
# Guard: MAKATO_LOOP_STALL_DISABLE=1 → return 0 immediately.
# ---------------------------------------------------------------------------
_stall_restart() {
  local issue="$1"
  local spec_folder="${2:-}"
  local log_file="${3:-}"

  # Opt-out guard — must mirror the watchdog opt-out.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    return 0
  fi

  # Resolve orchestrate.jsonl path (best-effort: spec_folder hint first,
  # then scan; emit is non-fatal when not found).
  local orch_log=""
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  elif [[ -n "$spec_folder" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  else
    orch_log="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1)"
  fi

  local stall_cause
  stall_cause="$(_read_status | jq -r '.last_watchdog_kill.stall_cause // "transient"' 2>/dev/null || echo "transient")"

  local now_ts
  now_ts="$(_now)"

  _orch_append() {
    local entry="$1"
    if [[ -n "$orch_log" ]]; then
      echo "$entry" >> "$orch_log" 2>/dev/null || true
    fi
  }

  case "$stall_cause" in
    halt_emitted)
      # po-agent already HALTed — do not restart; let the HALT path own it.
      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-classify\",\"status\":\"skip\",\"data\":{\"stall_cause\":\"halt_emitted\",\"reason\":\"po-agent emitted a HALT code before stalling\"}}"
      return 0
      ;;
    no_progress)
      # Stall_restart_count exhausted — escalate to HALT-014.
      local restart_count
      restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-restart\",\"status\":\"escalate\",\"data\":{\"stall_cause\":\"no_progress\",\"halt_code\":\"HALT-014\",\"stall_restart_count\":$restart_count}}"
      # Append HALT-014 to workflow-state (best-effort).
      local _wf_sh
      _wf_sh="$(dirname "$(dirname "$0")")/shared/workflow-state.sh"
      if [[ -x "$_wf_sh" ]]; then
        # Derive KEY from spec_folder basename if available.
        local _key=""
        if [[ -n "$spec_folder" ]]; then
          _key="$(basename "$spec_folder")"
        fi
        if [[ -n "$_key" ]]; then
          "$_wf_sh" append-halt "$_key" "$issue" HALT-014 '{"origin":"stall"}' 2>/dev/null || true
        fi
      fi
      # Apply needs-human-review label (best-effort, non-fatal).
      local _repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
      if [[ -n "$_repo" ]]; then
        gh issue edit "$issue" --add-label needs-human-review --repo "$_repo" 2>/dev/null || true
      fi
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
      return 1
      ;;
    *)
      # transient (or absent/unknown) — bounded restart.
      local restart_count
      restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      # Exponential backoff: base * 2^count, capped at STALL_KILL_SECS.
      local backoff=$(( STALL_BACKOFF_BASE_SECS * (1 << restart_count) ))
      if [[ $backoff -gt $STALL_KILL_SECS ]]; then
        backoff=$STALL_KILL_SECS
      fi

      # Read resume_point from workflow-state file (best-effort).
      local resume_pt="null"
      local _wf_file
      _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
        -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
      if [[ -f "$_wf_file" ]]; then
        resume_pt="$(jq -r '.resume_point // "null"' "$_wf_file" 2>/dev/null || echo "null")"
      fi

      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-restart\",\"status\":\"attempt\",\"data\":{\"stall_cause\":\"transient\",\"backoff_secs\":$backoff,\"resume_point\":\"$resume_pt\",\"stall_restart_count\":$restart_count}}"

      # Increment stall_restart_count before sleep so a kill during backoff still records the attempt.
      local new_count=$(( restart_count + 1 ))
      _patch_status '.stall_restart_count' "$new_count"

      # Backoff sleep (honour STALL_POLL_SECS as the minimum tick unit).
      sleep "$backoff" 2>/dev/null || true
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _parse_dispatch_result <log-file> (#531)
# Classifies omp stream-json dispatch outcome per D16 contract: complete / errored / incomplete.
# omp emits {"type":"result","is_error":false|true,...} — same shape as claude stream-json.
# Guard: MAKATO_LOOP_STALL_DISABLE=1 → returns "complete". Missing file → "incomplete".
# ---------------------------------------------------------------------------
_parse_dispatch_result() {
  local log_file="${1:-}"

  # Opt-out guard.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    echo "complete"
    return 0
  fi

  # Missing or empty log file → safe default.
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    echo "incomplete"
    return 0
  fi

  # Scan for terminal {"type":"result",...} line; last one wins.
  local result_line=""
  while IFS= read -r line; do
    local t
    t="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null || true)"
    if [[ "$t" == "result" ]]; then
      result_line="$line"
    fi
  done <"$log_file"

  if [[ -z "$result_line" ]]; then
    echo "incomplete"
    return 0
  fi

  local is_error
  is_error="$(printf '%s' "$result_line" | jq -r '.is_error // false' 2>/dev/null || echo "false")"
  if [[ "$is_error" == "true" ]]; then
    echo "errored"
  else
    echo "complete"
  fi
}

# ---------------------------------------------------------------------------
# _stall_resume <issue> <key> <spec-folder> <log-file> (#531)
# Resumes a crashed dispatch via `omp --yolo -p --resume`. Shares stall_restart_count
# with _stall_restart; budget exhaustion → HALT-014. Guard: MAKATO_LOOP_STALL_DISABLE=1 → skip.
# ---------------------------------------------------------------------------
_stall_resume() {
  local issue="$1"
  local key="${2:-}"
  local spec_folder="${3:-}"
  local log_file="${4:-}"

  # Opt-out guard.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    # Resolve orch_log for the skip emit.
    local orch_log=""
    if [[ -n "$spec_folder" ]]; then
      orch_log="$spec_folder/orchestrate.jsonl"
    fi
    local now_ts
    now_ts="$(_now)"
    if [[ -n "$orch_log" ]]; then
      echo "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"skip\",\"data\":{\"reason\":\"MAKATO_LOOP_STALL_DISABLE=1\"}}" \
        >> "$orch_log" 2>/dev/null || true
    fi
    return 0
  fi

  # Resolve orchestrate.jsonl path (same pattern as _stall_restart).
  local orch_log=""
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  elif [[ -n "$spec_folder" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  else
    orch_log="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1)"
  fi

  _orch_append() {
    local entry="$1"
    if [[ -n "$orch_log" ]]; then
      echo "$entry" >> "$orch_log" 2>/dev/null || true
    fi
  }

  local now_ts
  now_ts="$(_now)"

  # Read shared restart counter.
  local restart_count
  restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"

  # Budget check — mirrors _stall_restart's no_progress branch.
  if [[ "$restart_count" -ge "$MAX_STALL_RESTARTS" ]]; then
    _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"escalate\",\"data\":{\"halt_code\":\"HALT-014\",\"stall_restart_count\":$restart_count,\"max_stall_restarts\":$MAX_STALL_RESTARTS}}"
    # Append HALT-014 to workflow-state (best-effort).
    local _wf_sh
    _wf_sh="$(dirname "$(dirname "$0")")/shared/workflow-state.sh"
    if [[ -x "$_wf_sh" ]]; then
      local _key_for_halt="${key:-}"
      if [[ -z "$_key_for_halt" && -n "$spec_folder" ]]; then
        _key_for_halt="$(basename "$spec_folder")"
      fi
      if [[ -n "$_key_for_halt" ]]; then
        "$_wf_sh" append-halt "$_key_for_halt" "$issue" HALT-014 '{"origin":"stall-resume"}' 2>/dev/null || true
      fi
    fi
    # Apply needs-human-review label (best-effort, non-fatal).
    local _repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
      echo "label #${issue} needs-human-review" >> "$MAKATO_LOOP_LABEL_TEST_FILE" 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    elif [[ -n "$_repo" ]]; then
      gh issue edit "$issue" --add-label needs-human-review --repo "$_repo" 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    fi
    return 1
  fi

  # Compute exponential backoff (same formula as _stall_restart).
  local backoff=$(( STALL_BACKOFF_BASE_SECS * (1 << restart_count) ))
  if [[ $backoff -gt $STALL_KILL_SECS ]]; then
    backoff=$STALL_KILL_SECS
  fi

  # Resolve the worktree directory from workflow-state (best-effort).
  local worktree_dir=""
  local _wf_file
  _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
    -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
  if [[ -f "$_wf_file" ]]; then
    worktree_dir="$(jq -r '.worktree_path // ""' "$_wf_file" 2>/dev/null || true)"
  fi
  # Fall back to REPO_ROOT when worktree_path is absent or null.
  if [[ -z "$worktree_dir" || "$worktree_dir" == "null" ]]; then
    worktree_dir="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  fi

  # #616: read persisted session UUID — `claude --resume` requires UUID not KEY.
  # Missing → skip resume, let orphan-liveness detection recover on next tick
  # (skip BEFORE counter increment to avoid wasting a restart budget slot).
  local _resume_sid=""
  if [[ -f "$_wf_file" ]]; then
    _resume_sid="$(jq -r '.last_session_id // ""' "$_wf_file" 2>/dev/null || true)"
  fi
  if [[ -z "$_resume_sid" || "$_resume_sid" == "null" ]]; then
    _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"skip\",\"data\":{\"reason\":\"no_session_id\"}}"
    return 0
  fi

  # Increment shared restart counter before sleep (mirrors _stall_restart convention).
  local new_count=$(( restart_count + 1 ))
  _patch_status '.stall_restart_count' "$new_count"

  _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"attempt\",\"data\":{\"key\":\"${key:-}\",\"backoff_secs\":$backoff,\"worktree_dir\":\"$worktree_dir\",\"stall_restart_count\":$restart_count}}"

  # Backoff sleep.
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  $sleep_cmd "$backoff" 2>/dev/null || true

  # Resume the session from the worktree directory.
  local resume_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to resume driving GitHub issue #${issue} to a merged PR. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
  (
    cd "$worktree_dir" 2>/dev/null || true
    MAKATO_HEADLESS=1 "$CLAUDE_BIN" --yolo \
      --resume "$_resume_sid" \
      -p "$resume_prompt" >>"$log_file" 2>&1 || true
  )
  return 0
}

# ---------------------------------------------------------------------------
# _seconds_since <iso8601-timestamp> — seconds elapsed since timestamp, or
# 999999 on empty/unparseable (makes "younger than GAP" false on missing data).
# ---------------------------------------------------------------------------
_seconds_since() {
  local ts="${1:-}"
  if [[ -z "$ts" || "$ts" == "null" ]]; then
    echo 999999
    return 0
  fi
  # python3 reused for calendar-safe ISO parsing (already a hard dependency).
  python3 -c "
import sys, datetime
try:
    ts = sys.argv[1].replace('Z', '+00:00')
    then = datetime.datetime.fromisoformat(ts)
    if then.tzinfo is None:
        then = then.replace(tzinfo=datetime.timezone.utc)
    delta = datetime.datetime.now(datetime.timezone.utc) - then
    print(int(delta.total_seconds()))
except Exception:
    print(999999)
" "$ts" 2>/dev/null || echo 999999
}

# ---------------------------------------------------------------------------
# _within_dispatch_guard <issue-number> (#171) — idempotent-dispatch guard.
# Returns 0 (refuse) when: A) same issue still in-flight with fresh started_at,
# or B) same issue just-dispatched with fresh last_dispatch_at. Both fail-open.
# ---------------------------------------------------------------------------
_within_dispatch_guard() {
  local issue="$1"
  local status
  status="$(_read_status)"
  # Predicate A — same-issue still in flight, fresh started_at.
  local active_issue active_started_at
  active_issue="$(jq -r '.active_workflow.issue // empty' <<<"$status")"
  active_started_at="$(jq -r '.active_workflow.started_at // empty' <<<"$status")"
  if [[ "$active_issue" == "$issue" ]]; then
    local age_a
    age_a="$(_seconds_since "$active_started_at")"
    if [[ "$age_a" -lt "$MIN_DISPATCH_GAP_SECS" ]]; then
      return 0
    fi
  fi
  # Predicate B — same-issue just-dispatched, fresh last_dispatch_at.
  local last_issue last_ts
  last_issue="$(jq -r '.last_dispatch_issue // empty' <<<"$status")"
  last_ts="$(jq -r '.last_dispatch_at // empty' <<<"$status")"
  if [[ "$last_issue" == "$issue" ]]; then
    local age_b
    age_b="$(_seconds_since "$last_ts")"
    if [[ "$age_b" -lt "$LAST_DISPATCH_GAP_SECS" ]]; then
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _derive_key_for_issue <ISSUE_NUMBER> [<REPO>] (#232)
# Derives spec KEY from issue body: footer slug → stories.json fallback →
# <N>-<normalized-title> (#232). On failure prints nothing, returns 1.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _slug_truncate_wb <normalized-slug> — truncate slug to 40 chars with
# word-boundary backoff (#721, FM-KEY-CUT): mirrors seed-issue SKILL.md Step 4
# so KEY derivation never mismatches a mid-word cut. sed -E (macOS + GNU safe).
# ---------------------------------------------------------------------------
_slug_truncate_wb() {
  local s="$1"
  s="$(printf '%s' "$s" | cut -c1-40 | sed -E 's/-+$//')"
  if [[ "${#s}" -eq 40 && "$s" == *-* ]]; then
    # Mid-word cut: strip trailing partial word and any exposed hyphen.
    s="$(printf '%s' "$s" | sed -E 's/-[^-]*$//')"
  fi
  printf '%s' "$s"
}

_derive_key_for_issue() {
  local issue="$1"
  local repo="${2:-${MAKATO_LOOP_DISPATCH_REPO:-}}"

  # Declare the repo flag once — reused by body fetch and title fetch (#232).
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # REST path for #447 fallback; {owner}/{repo} expands from ambient repo when no explicit repo.
  local rest_issue_path
  if [[ -n "$repo" ]]; then
    rest_issue_path="repos/${repo}/issues/${issue}"
  else
    rest_issue_path="repos/{owner}/{repo}/issues/${issue}"
  fi

  local body
  if [[ -n "${MAKATO_LOOP_ISSUE_BODY_OVERRIDE:-}" ]]; then
    body="$(cat "$MAKATO_LOOP_ISSUE_BODY_OVERRIDE" 2>/dev/null)" || return 1
  else
    # #447: wrap body fetch with REST fallback; both shapes expose `.body`. On exhaustion returns 1.
    local body_json
    if ! body_json="$(_gh_with_fallback "KEY-derivation body #${issue}" \
        issue view "$issue" "${repo_flag[@]}" --json body \
        -- api "$rest_issue_path")"; then
      return 1
    fi
    body="$(jq -r '.body // ""' <<<"$body_json" 2>/dev/null)" || return 1
  fi
  [[ -n "$body" ]] || return 1

  # Primary: footer line  *Feature slug: `<slug>` — produced by to-issues …*
  # BSD/macOS `sed` compatible (no -E, no PCRE lookarounds).
  local slug
  slug="$(printf '%s\n' "$body" \
    | sed -n "s/.*Feature slug: \`\([^\`]*\)\` — produced by to-issues.*/\1/p" \
    | head -1)"

  # Fallback: top-of-body provenance  specs/<slug>/stories.json
  # Real slug (starts alnum, alnum/hyphen only) prevents matching the doc-example
  # placeholder `specs/<slug>/stories.json` (angle brackets → never matches) — fixes #721/FM-FALSE-MATCH.
  if [[ -z "$slug" ]]; then
    slug="$(printf '%s\n' "$body" \
      | sed -nE 's|.*specs/([a-z0-9][a-z0-9-]*)/stories\.json.*|\1|p' \
      | head -1)"
  fi

  # Third fallback (#232): no to-issues provenance — derive <issue>-<normalized-title>,
  # matching seed-issue SLUG convention (SKILL.md Step 4). Reached only when both
  # provenance patterns missed. Test hook: MAKATO_LOOP_ISSUE_TITLE_OVERRIDE.
  if [[ -z "$slug" ]]; then
    local title
    if [[ -n "${MAKATO_LOOP_ISSUE_TITLE_OVERRIDE:-}" ]]; then
      title="$MAKATO_LOOP_ISSUE_TITLE_OVERRIDE"
    else
      # #447: REST fallback for title fetch; failure keeps fail-open (title empty → return 1 below).
      local title_json
      if title_json="$(_gh_with_fallback "KEY-derivation title #${issue}" \
          issue view "$issue" "${repo_flag[@]}" --json title \
          -- api "$rest_issue_path")"; then
        title="$(jq -r '.title // ""' <<<"$title_json" 2>/dev/null || true)"
      fi
    fi
    if [[ -n "$title" ]]; then
      # seed-issue normalization: lowercase, non-alnum→'-', collapse, strip, truncate@40.
      local norm
      norm="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
      norm="$(_slug_truncate_wb "$norm")"
      [[ -n "$norm" ]] && slug="${issue}-${norm}"
    fi
  fi

  [[ -n "$slug" ]] || return 1

  # Disambiguation: when slug matches multiple specs/ folders (epic collision),
  # pick the one whose created-issues.json or plan.md references this issue number (#).
  local spec_root="${REPO_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)}/specs"
  if [[ -d "$spec_root" ]]; then
    local -a candidates=()
    while IFS= read -r -d '' dir; do
      candidates+=("$dir")
    done < <(find "$spec_root" -maxdepth 1 -type d -name "${slug}-*" -print0 2>/dev/null)
    if [[ "${#candidates[@]}" -gt 1 ]]; then
      local disambig=""
      for candidate in "${candidates[@]}"; do
        if grep -qsE '"issue_number"[[:space:]]*:[[:space:]]*'"$issue"'[^0-9]' \
              "$candidate/created-issues.json" "$candidate/plan.md" 2>/dev/null; then
          disambig="$(basename "$candidate")"
          break
        fi
      done
      [[ -n "$disambig" ]] && slug="$disambig"
    fi
  fi

  # Sanitise: replace chars outside [A-Za-z0-9._-] with dash so BRANCH is a valid ref.
  # No-op for to-issues slugs in practice; guards hand-edited bodies.
  slug="${slug//[^a-zA-Z0-9._-]/-}"

  printf '%s\n' "$slug"
}

# ---------------------------------------------------------------------------
# _spec_folder_for_key <KEY> — binary existence check for specs/<KEY>*/ folder.
# Returns 0 and prints the matching basename; returns 1 when no folder matches.
# Uses SPECS_DIR env override as offline test seam (same as loop.sh broadly).
# Distinct from _derive_key_for_issue's multi-candidate disambiguation block.
# ---------------------------------------------------------------------------
_spec_folder_for_key() {
  local key="$1"
  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  local match
  match="$(find "$spec_root" -maxdepth 1 -type d -name "${key}*" -print0 2>/dev/null \
    | tr '\0' '\n' | head -1)"
  if [[ -n "$match" ]]; then
    printf '%s\n' "$(basename "$match")"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _assign_issue <ISSUE_NUMBER> — assign issue to dispatch actor via `gh issue edit --add-assignee` (#33).
# Best-effort: non-zero `gh` exit is logged and swallowed. Repo from MAKATO_LOOP_DISPATCH_REPO.
# ---------------------------------------------------------------------------
_assign_issue() {
  local issue="$1"
  [[ "$ASSIGN_ON_DISPATCH" == "1" ]] || return 0

  # Test hook: record assign instead of hitting the network (loop-smoke-tests.sh).
  if [[ -n "${MAKATO_LOOP_ASSIGN_TEST_FILE:-}" ]]; then
    echo "assign #${issue} assignee=${ASSIGNEE} repo=${MAKATO_LOOP_DISPATCH_REPO:-<ambient>}" \
      >>"${MAKATO_LOOP_ASSIGN_TEST_FILE}"
    return 0
  fi

  local -a repo_flag=()
  [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")

  if gh issue edit "$issue" "${repo_flag[@]}" --add-assignee "$ASSIGNEE" >/dev/null 2>&1; then
    echo "loop: assigned #$issue to $ASSIGNEE (board → In progress via project-board-sync.yml)" >&2
  else
    echo "loop: WARN — failed to assign #$issue to $ASSIGNEE (dispatch continues; board Status unchanged)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _claim_board_card <ISSUE_NUMBER> — synchronous CAS board claim (#259).
# Re-polls board Status; if still at dispatch Status, sets it to "In progress".
# Exit 0 = claimed (or disabled/best-effort fallback): PROCEED.
# Exit 1 = card no longer at dispatch Status (another session claimed it): SKIP.
# Best-effort: read failure returns 0 (degrades to pre-#259 assign path).
# Write failure also returns 0 (Ready already observed; webhook is backstop).
# Test hooks: MAKATO_LOOP_CLAIM_TEST_FILE, MAKATO_LOOP_CLAIM_STATUS_OVERRIDE.
# ---------------------------------------------------------------------------
_claim_board_card() {
  local issue="$1"
  # Per-item expected status: critical for multi-status dispatch so a Todo CAS
  # is not compared against "Ready". Falls back to MAKATO_LOOP_ITEM_STATUS then DEFAULT_STATUS.
  local dispatch_status="${2:-${MAKATO_LOOP_ITEM_STATUS:-${MAKATO_LOOP_DISPATCH_STATUS:-$DEFAULT_STATUS}}}"

  # Disabled → fall through to the async assign→webhook path.
  [[ "$CLAIM_ON_DISPATCH" == "1" ]] || return 0

  # Test hook: decide from injected fixture Status, never touch the network.
  if [[ -n "${MAKATO_LOOP_CLAIM_TEST_FILE:-}" ]]; then
    local cur="${MAKATO_LOOP_CLAIM_STATUS_OVERRIDE-__UNSET__}"
    if [[ "$cur" == "__UNSET__" || -z "$cur" ]]; then
      echo "claim #${issue} status=<unknown> → warn-proceed" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
      echo "loop: WARN — claim #$issue could not read board Status; proceeding (assign→webhook backstop)" >&2
      return 0
    fi
    if [[ "$cur" == "$dispatch_status" ]]; then
      echo "claim #${issue} status=${cur} → claimed" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
      echo "loop: claimed #$issue (board $dispatch_status → In progress)" >&2
      # Export observed status for tier 3/4 label-board conflict gate (#356).
      LOOP_LAST_CLAIMED_STATUS="$cur"
      return 0
    fi
    echo "claim #${issue} status=${cur} → skip" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
    echo "loop: skip #$issue — board Status is '$cur', not '$dispatch_status' (claimed by another session)" >&2
    return 1
  fi

  # Resolve project coordinates + the In progress option id. Missing config →
  # cannot claim; WARN and proceed (best-effort read-fallback).
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — claim #$issue skipped: .claude/config.json not found; proceeding (assign→webhook backstop)" >&2
    return 0
  fi
  local status_field_id in_progress_option_id project_node_id host owner number
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  in_progress_option_id="$(jq -r '.github_project.fields.status.options.in_progress // empty' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  if [[ -z "$status_field_id" || -z "$in_progress_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — claim #$issue skipped: status field / in_progress option / project missing in config; proceeding" >&2
    return 0
  fi

  # Re-poll: fetch board item (current Status + item id). Closes TOCTOU window.
  # MAKATO_LOOP_GH_OVERRIDE: offline fixture keeps DRY_DISPATCH smoke path (T9) offline.
  local board item_line cur_status item_id _claim_offline=""
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" ]]; then
    board="$(cat "$MAKATO_LOOP_GH_OVERRIDE" 2>/dev/null || echo '{"items":[]}')"
  else
    # #289: CAS re-poll uses retrying wrapper. Failed read → SKIP (not warn-proceed):
    # proceeding on an unreadable board re-opens the pre-#259 double-dispatch race.
    if ! board="$(_gh_project_item_list "$host" "$number" "$owner")"; then
      # #9: offline fallback — CAS against the last-known mirror and queue the
      # transition for push on reconnect. Single operator, so no reachable
      # competing session can race the claim while GitHub is unreachable.
      if _mirror_enabled && board="$(mirror_read)"; then
        echo "loop: claim #$issue — board re-poll failed; using offline mirror (#9)" >&2
        _claim_offline=1
      else
        echo "loop: skip #$issue — board re-poll failed (rate-limit/transient); NOT claiming to avoid double-dispatch (#289)" >&2
        return 1
      fi
    fi
  fi
  item_line="$(jq -c --argjson i "$issue" \
    'first(.items[] | select(.content.type == "Issue" and .content.number == $i))' \
    <<<"$board" 2>/dev/null || echo "")"
  if [[ -z "$item_line" || "$item_line" == "null" ]]; then
    echo "loop: WARN — claim #$issue could not locate board item on re-poll; proceeding (assign→webhook backstop)" >&2
    return 0
  fi
  cur_status="$(jq -r '.status // empty' <<<"$item_line")"
  item_id="$(jq -r '.id // empty' <<<"$item_line")"

  # CAS: only claim when the card is still at the dispatch Status.
  if [[ "$cur_status" != "$dispatch_status" ]]; then
    echo "loop: skip #$issue — board Status is '${cur_status:-<none>}', not '$dispatch_status' (claimed by another session)" >&2
    return 1
  fi
  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — claim #$issue: board item id unresolved; proceeding (assign→webhook backstop)" >&2
    return 0
  fi

  # Export CAS-observed Status for the tier 3/4 label-board conflict gate (#356).
  LOOP_LAST_CLAIMED_STATUS="$cur_status"

  # #9: offline claim — GitHub is unreachable; record the transition locally and
  # queue it for push on reconnect rather than a network write that would hang.
  if [[ "${_claim_offline:-}" == "1" ]]; then
    mirror_apply_local "$issue" "In progress"
    echo "loop: claimed #$issue offline — queued 'In progress' for sync (#9)" >&2
    return 0
  fi

  # Forward-only write: Ready → In progress. Failed write still proceeds —
  # Ready already observed; async webhook is the backstop.
  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$in_progress_option_id" >/dev/null 2>&1; then
    echo "loop: claimed #$issue (board $dispatch_status → In progress)" >&2
  else
    # #9: keep the mirror truthful and retry the push on the next tick.
    mirror_apply_local "$issue" "In progress"
    echo "loop: WARN — claim #$issue: item-edit failed after observing $dispatch_status; proceeding (assign→webhook backstop)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _reset_board_card_to_ready <ISSUE_NUMBER> — api_error board recovery (#687).
# Called by cmd_dispatch when child exits rc!=0 with no workflow-state written.
# Moves board card In progress → Ready so the loop retries next tick.
# Best-effort: any failure logs WARN and returns 0.
# Test hook: MAKATO_LOOP_RESET_BOARD_TEST_FILE.
# ---------------------------------------------------------------------------
_reset_board_card_to_ready() {
  local issue="$1"

  # Test hook — offline smoke tests write to this file instead of calling gh.
  if [[ -n "${MAKATO_LOOP_RESET_BOARD_TEST_FILE:-}" ]]; then
    echo "reset #${issue} → Ready" >>"$MAKATO_LOOP_RESET_BOARD_TEST_FILE"
    echo "loop: api-error-reset — #$issue board reset → Ready (test hook)" >&2
    return 0
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — api-error-reset #$issue: no config; board card stays In progress" >&2
    return 0
  fi

  local status_field_id ready_option_id project_node_id host owner number
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  ready_option_id="$(jq -r '.github_project.fields.status.options.ready // (.github_project.options.ready // empty)' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

  if [[ -z "$status_field_id" || -z "$ready_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — api-error-reset #$issue: missing config fields; board card stays In progress" >&2
    return 0
  fi

  # Re-fetch item_id from board. Use _board_via_graphql (~1 point) with item-list fallback.
  local board=""
  local _pid
  _pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
  if [[ -n "$_pid" ]]; then
    board="$(_board_via_graphql "$host" "$_pid" 2>/dev/null)" || board=""
  fi
  if [[ -z "$board" ]]; then
    board="$(GH_HOST="$host" gh project item-list "$number" \
      --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || board=""
  fi
  if [[ -z "$board" ]]; then
    echo "loop: WARN — api-error-reset #$issue: board poll failed; card stays In progress" >&2
    return 0
  fi

  local item_line item_id cur_status
  item_line="$(jq -c --argjson i "$issue" \
    'first(.items[] | select(.content.type == "Issue" and .content.number == $i))' \
    <<<"$board" 2>/dev/null || echo "")"
  item_id="$(jq -r '.id // empty' <<<"$item_line" 2>/dev/null)"
  cur_status="$(jq -r '.status // empty' <<<"$item_line" 2>/dev/null)"

  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — api-error-reset #$issue: item_id not found; card stays In progress" >&2
    return 0
  fi

  # Status guard: only reset when card is still "In progress".
  # Avoids oscillation if reconciler raced ahead.
  if [[ "$cur_status" != "In progress" ]]; then
    echo "loop: api-error-reset #$issue: card is '${cur_status:-<unknown>}', not In progress — skip" >&2
    return 0
  fi

  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
    echo "loop: api-error-reset — #$issue board reset In progress → Ready (api_error, no workflow-state)" >&2
    # Best-effort JSONL audit to orchestrate.jsonl when found.
    local _spec_dir_reset
    _spec_dir_reset="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1 | xargs -I{} dirname {} 2>/dev/null || true)"
    if [[ -n "$_spec_dir_reset" ]]; then
      local _now_ts
      _now_ts="$(_now)"
      echo "{\"ts\":\"$_now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"api-error-board-reset\",\"status\":\"reset\",\"data\":{\"from\":\"In progress\",\"to\":\"Ready\",\"reason\":\"api_error_no_workflow_state\"}}" \
        >>"$_spec_dir_reset/orchestrate.jsonl" 2>/dev/null || true
    fi
  else
    echo "loop: WARN — api-error-reset #$issue: item-edit failed; card stays In progress (reconciler will recover)" >&2
  fi
  return 0
}

# _PROMOTE_EXCLUSION_LABELS is defined in ../config/config.yml (auto-seed veto set, #286).

# ---------------------------------------------------------------------------
# cmd_auto_seed — standalone entry point for the pre-poll auto-seed pass (#373, epic #367 S5).
# ---------------------------------------------------------------------------
cmd_auto_seed() {
  _auto_seed_unprepared
}

# ---------------------------------------------------------------------------
# _auto_seed_demote_to_todo — move board card Ready → Todo (#783).
# Called by T3.5 guard for a Ready-but-folderless issue so the loop advances
# instead of stalling; next auto-seed pass re-seeds and re-promotes.
# Best-effort. Test hook: MAKATO_LOOP_DEMOTE_TEST_FILE.
# ---------------------------------------------------------------------------
_auto_seed_demote_to_todo() {
  local issue="${1:?issue number required}"

  # Test hook — offline smoke tests write to this file instead of calling gh.
  if [[ -n "${MAKATO_LOOP_DEMOTE_TEST_FILE:-}" ]]; then
    echo "demote #${issue} → Todo" >>"$MAKATO_LOOP_DEMOTE_TEST_FILE"
    echo "loop: auto-seed-demote — #$issue → Todo (test hook)" >&2
    return 0
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: no config; card stays Ready" >&2
    return 0
  fi

  local status_field_id todo_option_id project_node_id host owner number repo
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  todo_option_id="$(jq -r '.github_project.fields.status.options.todo // (.github_project.options.todo // empty)' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  repo="${MAKATO_LOOP_DISPATCH_REPO:-}"

  if [[ -z "$status_field_id" || -z "$todo_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: missing config fields (need github_project.fields.status.options.todo); card stays Ready" >&2
    return 0
  fi

  # Resolve the board item id (3-step: idempotent item-add → cheap single-issue
  # GraphQL lookup → whole-board item-list fallback), matching _auto_seed_block_full.
  local item_id=""
  if [[ -n "$repo" ]]; then
    item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
      --url "https://github.com/${repo}/issues/$issue" \
      --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$item_id" ]]; then
    item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
  fi
  if [[ -z "$item_id" ]]; then
    item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
      --format json --limit 9999 2>/dev/null \
      | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
      | head -1 || true)"
  fi

  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: could not resolve board item id; card stays Ready" >&2
    return 0
  fi

  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$todo_option_id" >/dev/null 2>&1; then
    echo "loop: auto-seed-demote — #$issue board demoted Ready → Todo (folderless; will re-seed)" >&2
  else
    echo "loop: WARN — auto-seed-demote #$issue: board item-edit to Todo failed; card stays Ready" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_candidates — discover open issues needing seeding and classify plan-tier (#369, epic #367 S1).
# Returns a JSON array of {number, plan_tier} objects.
# Test hook: MAKATO_LOOP_AUTOSEED_OVERRIDE.
# ---------------------------------------------------------------------------
_auto_seed_candidates() {
  local raw candidates
  if [[ -n "${MAKATO_LOOP_AUTOSEED_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_AUTOSEED_OVERRIDE" 2>/dev/null || echo '[]')"
  else
    local -a repo_flag=()
    [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")
    raw="$(gh issue list "${repo_flag[@]}" \
      --state open --json number,labels,author --limit 200 2>/dev/null || echo '[]')"
  fi
  [[ -n "$raw" ]] || raw='[]'

  # Start with all open issues; board-Ready exclusion applied per-candidate in T3.5.
  local candidates="$raw"
  [[ -n "$candidates" ]] || candidates='[]'

  # Iterate per candidate, apply T2 exclusion labels, T3 bot veto, T4 plan-tier
  local result='[]'
  local n labels author_login excluded lbl plan_tier
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    labels="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | [.labels[].name] | join(" ")' \
      <<<"$candidates" 2>/dev/null || echo "")"
    author_login="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | .author.login // ""' \
      <<<"$candidates" 2>/dev/null || echo "")"

    # T2: Exclusion guard — reuse _PROMOTE_EXCLUSION_LABELS verbatim.
    excluded=""
    for lbl in $_PROMOTE_EXCLUSION_LABELS; do
      if [[ " $labels " == *" $lbl "* ]]; then excluded="$lbl"; break; fi
    done
    if [[ -n "$excluded" ]]; then
      echo "loop: auto-seed — skip #$n (exclusion label: $excluded)" >&2
      continue
    fi

    # T3: dependencies label veto.
    if [[ " $labels " == *" dependencies "* ]]; then
      echo "loop: auto-seed — skip #$n (dependencies label)" >&2
      continue
    fi

    # T3: bot-author veto — login ends in "[bot]" (renovate[bot], dependabot[bot], etc.).
    # Bot-filed issues are never human-shaped work and must not enter the queue.
    if [[ "$author_login" == *"[bot]" ]]; then
      echo "loop: auto-seed — skip #$n (bot author: $author_login)" >&2
      continue
    fi

    # T3.5: already-planned veto (#499/#510). `_is_orphan_issue` returns 1 when a
    # created-issues.json already references this number (already planned via to-issues);
    # re-seeding would create a duplicate spec folder with a hollow plan.md (#571 fix).
    if ! _is_orphan_issue "$n"; then
      # #783: a non-orphan that is also folderless starves the dispatch queue
      # (cmd_dispatch spec-folder gate bounces it back to auto-seed every tick).
      # Detect and demote Ready → Todo so it exits the dispatchable queue;
      # the next auto-seed pass treats it as a genuine unprepared candidate.
      local n_key=""
      n_key="$(_derive_key_for_issue "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
      if [[ -n "$n_key" ]] && ! _spec_folder_for_key "$n_key" >/dev/null 2>&1; then
        echo "loop: auto-seed — #$n Ready-but-folderless (KEY='$n_key'); demoting to Todo for re-seed (#783)" >&2
        _auto_seed_demote_to_todo "$n" || true
      else
        echo "loop: auto-seed — skip #$n (already planned by to-issues — in created-issues.json)" >&2
      fi
      continue
    fi

    # T4: Classify plan-tier from labels.
    plan_tier="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | [.labels[].name] | .[] | select(startswith("plan-tier:"))' \
      <<<"$candidates" 2>/dev/null | head -1 | sed 's/plan-tier://' || echo "")"
    [[ -n "$plan_tier" ]] || plan_tier=""

    result="$(jq --argjson n "$n" --arg t "$plan_tier" \
      '. + [{"number": $n, "plan_tier": $t}]' \
      <<<"$result" 2>/dev/null || echo "$result")"
  done < <(jq -r '.[].number' <<<"$candidates" 2>/dev/null)

  printf '%s\n' "$result"
  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_dispatch_light — light-tier arm of auto-seed routing (#370, epic #367 S2).
# Dispatches seed-issue headlessly for plan_tier=="light"; skips otherwise.
# Exit 0 = dispatched or skipped; 1 = dispatch attempted but failed.
# Test hook: MAKATO_LOOP_SEED_TEST_CMD.
# ---------------------------------------------------------------------------
_auto_seed_dispatch_light() {
  local issue="${1:?issue number required}"
  local plan_tier="${2:-}"

  # Non-light candidates: skip, defer to S4 (#372).
  if [[ "$plan_tier" != "light" ]]; then
    echo "loop: auto-seed — skip #$issue (plan-tier '$plan_tier' not light — deferred to S4)" >&2
    return 0
  fi

  echo "loop: auto-seed — dispatching seed-issue for #$issue (plan-tier:light)" >&2

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local dispatch_prompt
  dispatch_prompt="Use the Skill tool to invoke the makato-orchestrate:seed-issue skill with args '${issue} --type new-work'. Required env: ISSUE_NUMBER=${issue} REPO=${repo} REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. Return R1 envelope verbatim."

  local rc=0
  if [[ -n "${MAKATO_LOOP_SEED_TEST_CMD:-}" ]]; then
    # Test-hook path: run the stub instead of the real claude -p.
    # </dev/null: caller iterates via `while ... done < <(jq ...)` — without
    # explicit stdin redirect the child process drains the TSV pipe, causing
    # subsequent loop iterations to receive EOF and silently drop candidates.
    MAKATO_HEADLESS=1 \
    ISSUE_NUMBER="$issue" \
    REPO="$repo" \
    REPO_ROOT="$REPO_ROOT" \
      ${MAKATO_LOOP_SEED_TEST_CMD} -p "$dispatch_prompt" </dev/null >/dev/null 2>&1 || rc=$?
  else
    # Production path: mirror the belt-and-braces invocation cmd_dispatch uses.
    # </dev/null: same TSV-pipe guard as the test-hook path above.
    MAKATO_HEADLESS=1 \
    ISSUE_NUMBER="$issue" \
    REPO="$repo" \
    REPO_ROOT="$REPO_ROOT" \
      "$CLAUDE_BIN" --yolo \
      -p "$dispatch_prompt" </dev/null >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "loop: WARN — auto-seed seed dispatch for #$issue failed (rc=$rc); tick continues" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_reconcile_thin_body — terminal-state reconciliation after light-tier
# seed-issue dispatch (S3, epic #367, #371). Detects thin-body refusal
# (light-planner wrote no plan, re-tiered to full, stripped status:ready-for-dev)
# and applies needs-human-review so the loop does not dispatch the issue.
# Exit 0 = not thin-body; 2 = thin-body detected (caller must not dispatch).
# ---------------------------------------------------------------------------
_auto_seed_reconcile_thin_body() {
  local issue="${1:?issue number required}"
  local seed_key="${2:-}"

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Signal 1: orchestrate.jsonl (primary) ---
  # Grep for the light-plan line: data.thin_body == true or guard == "invalid".
  local thin_body_detected=""
  if [[ -n "$seed_key" ]]; then
    local jsonl_root="${MAKATO_LOOP_RECONCILE_JSONL_DIR:-$SPECS_DIR}"
    local jsonl_path="${jsonl_root}/${seed_key}/orchestrate.jsonl"
    if [[ -f "$jsonl_path" && -s "$jsonl_path" ]]; then
      while IFS= read -r line; do
        local _tb _guard
        _tb="$(printf '%s' "$line" | jq -r '.data.thin_body // empty' 2>/dev/null || true)"
        _guard="$(printf '%s' "$line" | jq -r '.data.guard // empty' 2>/dev/null || true)"
        if [[ "$_tb" == "true" || "$_guard" == "invalid" ]]; then
          thin_body_detected="jsonl"
          break
        fi
      done <"$jsonl_path"
    fi
    # Missing or empty jsonl: fall through — no error.
  fi

  # --- No thin-body verdict: return 0, dispatch proceeds ---
  if [[ -z "$thin_body_detected" ]]; then
    return 0
  fi

  # --- Thin-body verdict: apply needs-human-review, leave at Todo ---
  echo "loop: auto-seed — #${issue} thin-body, left at Todo + needs-human-review (not dispatched) [signal=${thin_body_detected}]" >&2

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    # Test hook: record label action to file instead of calling gh.
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  else
    # Production path: create label if absent, then add idempotently.
    if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
      gh label create "needs-human-review" "${repo_flag[@]}" \
        --color "d93f0b" --description "Requires human review before autonomous dispatch" \
        >/dev/null 2>&1 || true
    fi
    if gh issue edit "$issue" "${repo_flag[@]}" \
        --add-label "needs-human-review" >/dev/null 2>&1; then
      echo "loop: auto-seed-reconcile — applied 'needs-human-review' label to #$issue" >&2
    else
      echo "loop: WARN — auto-seed-reconcile #$issue: could not apply needs-human-review label" >&2
    fi
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  fi

  # Exit code 2 = thin-body; caller must not dispatch.
  return 2
}

# ---------------------------------------------------------------------------
# _auto_seed_block_full — full/untiered arm of auto-seed routing (#372, epic #367 S4).
# For plan_tier full/change/empty: creates specs/<slug>/ stub, sets board Blocked,
# applies needs-human-review label, and posts a sentinel-guarded launch-command comment.
# light → no-op (S2 owns); change → no-op (makato-change owns).
# ---------------------------------------------------------------------------
_auto_seed_promote_ready_from_gate() {
  local issue="${1:?issue number required}"

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Step A: park-label guard (#721, FM-LABEL-PARK) ---
  # Issues carrying any MAKATO_LOOP_PARK_LABELS label are NOT promoted to Ready.
  # Checked before any board mutation; offline source: MAKATO_LOOP_RECONCILE_LABEL_FILE.
  local park_labels="${MAKATO_LOOP_PARK_LABELS:-priority:hold}"
  local issue_labels=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_FILE:-}" && -f "${MAKATO_LOOP_RECONCILE_LABEL_FILE}" ]]; then
    issue_labels="$(tr '\n' ',' <"$MAKATO_LOOP_RECONCILE_LABEL_FILE" 2>/dev/null || echo "")"
  else
    issue_labels="$(gh issue view "$issue" "${repo_flag[@]}" --json labels \
      --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")"
  fi
  local _pl_ifs_save="$IFS"; IFS=","
  local pl
  for pl in $park_labels; do
    IFS="$_pl_ifs_save"
    # trim surrounding whitespace
    pl="${pl#"${pl%%[![:space:]]*}"}"; pl="${pl%"${pl##*[![:space:]]}"}"
    [[ -n "$pl" ]] || { IFS=","; continue; }
    if printf '%s' "$issue_labels" | tr ',' '\n' | grep -qxF "$pl"; then
      echo "loop: auto-seed-block — skip promote #$issue (label '$pl' matches MAKATO_LOOP_PARK_LABELS; operator-parked)" >&2
      return 0
    fi
    IFS=","
  done
  IFS="$_pl_ifs_save"

  # --- Step B: Move board card to Ready ---
  if [[ -n "${MAKATO_LOOP_PROMOTE_TEST_FILE:-}" ]]; then
    echo "promote #${issue} → Ready" >>"$MAKATO_LOOP_PROMOTE_TEST_FILE"
  else
    if [[ -f "$CONFIG_FILE" ]]; then
      local status_field_id ready_option_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
      ready_option_id="$(jq -r '.github_project.fields.status.options.ready // (.github_project.options.ready // empty)' "$CONFIG_FILE")"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

      if [[ -n "$status_field_id" && -n "$ready_option_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        local item_id=""
        item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
          --url "https://github.com/${repo}/issues/$issue" \
          --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        if [[ -z "$item_id" ]]; then
          # Cheap single-issue lookup (~1 GraphQL point) before expensive item-list fallback.
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          if GH_HOST="$host" gh project item-edit --id "$item_id" \
              --project-id "$project_node_id" \
              --field-id "$status_field_id" \
              --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
            echo "loop: auto-seed-block — set #$issue → Ready on board (materialize-refine)" >&2
          else
            echo "loop: WARN — auto-seed-block #$issue: board item-edit to Ready failed" >&2
          fi
        else
          echo "loop: WARN — auto-seed-block #$issue: could not resolve board item id for Ready move" >&2
        fi
      else
        echo "loop: WARN — auto-seed-block #$issue: missing config fields for board Ready move" >&2
      fi
    else
      echo "loop: WARN — auto-seed-block #$issue: .claude/config.json not found; skipping Ready move" >&2
    fi
  fi
}
_auto_seed_block_full() {
  local issue="${1:?issue number required}"
  local plan_tier="${2:-}"

  # Light-tier candidates: no-op (S2 owns them).
  if [[ "$plan_tier" == "light" ]]; then
    echo "loop: auto-seed-block — skip #$issue (plan-tier:light — S2 owns it)" >&2
    return 0
  fi

  # Change-tier candidates: no-op (makato-change:orchestrate owns them).
  if [[ "$plan_tier" == "change" ]]; then
    echo "loop: auto-seed-block — skip #$issue (plan-tier:change — change-orchestrate owns it)" >&2
    return 0
  fi

  echo "loop: auto-seed-block — processing #$issue (plan-tier '${plan_tier:-untiered}')" >&2

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Step 1: Derive slug and prepare spec-folder stub ---
  # Delegate to _derive_key_for_issue so to-issues footer KEY (primary) and
  # specs/<slug>/stories.json provenance (secondary) take precedence over the
  # title-slug fallback, preventing false-positive Blocked on shared feature folders.
  local slug=""
  slug="$(_derive_key_for_issue "$issue" "${repo:-}" 2>/dev/null || true)"

  # Title-slug fallback: _derive_key_for_issue returns empty when body is empty/unfetchable.
  # Derives <issue>-<title-slug> matching seed-issue Step 4 normalization.
  if [[ -z "$slug" ]]; then
    local title=""
    if [[ -n "${MAKATO_LOOP_ISSUE_TITLE_OVERRIDE:-}" ]]; then
      title="$MAKATO_LOOP_ISSUE_TITLE_OVERRIDE"
    else
      title="$(gh issue view "$issue" "${repo_flag[@]}" --json title \
        --jq '.title' 2>/dev/null)" || true
    fi
    if [[ -n "$title" ]]; then
      local norm
      norm="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
      norm="$(_slug_truncate_wb "$norm")"
      [[ -n "$norm" ]] && slug="${issue}-${norm}"
    fi
  fi

  if [[ -z "$slug" ]]; then
    slug="${issue}"
    echo "loop: WARN — auto-seed-block #$issue could not derive slug; using bare issue number" >&2
  fi

  local spec_root="${MAKATO_LOOP_AUTOSEED_SPEC_ROOT:-$SPECS_DIR}"
  local spec_dir="$spec_root/$slug"

  # Stub creation skipped when _derive_key_for_issue returned a footer KEY
  # resolving to an existing shared spec folder.
  if [[ -d "$spec_dir" ]]; then
    echo "loop: auto-seed-block — specs/$slug/ already exists — skipping folder creation" >&2
  else
    mkdir -p "$spec_dir" 2>/dev/null || {
      echo "loop: WARN — auto-seed-block #$issue: could not create spec dir $spec_dir" >&2
    }
    if [[ -d "$spec_dir" ]]; then
      local now_iso
      now_iso="$(_now)"

      # plan.md stub (mirrors seed-issue Step 8 format exactly).
      printf '# Plan: %s\n\n> Auto-seeded by seed-issue v1.2.0 on %s. Replace this stub with a\n> full plan before the PO-agent starts.\n\n## Issue\n\n[#%s](https://github.com/%s/issues/%s)\n\n## Acceptance criteria\n\n_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if\nthis file contains only the stub text above._\n' \
        "#${issue}" "$now_iso" "$issue" "${repo:-unknown/repo}" "$issue" \
        >"$spec_dir/plan.md" 2>/dev/null || true

      # seed-manifest.json (schema_version 2, same as seed-issue).
      jq -n \
        --arg seeded_at "$now_iso" \
        --argjson issue_num "$issue" \
        --arg issue_title "" \
        --arg slug "$slug" \
        --arg repo "${repo:-}" \
        '{
          schema_version: "2",
          seeded_at: $seeded_at,
          seeded_by: "seed-issue",
          skill_version: "1.2.0",
          issue_number: $issue_num,
          issue_title: $issue_title,
          slug: $slug,
          repo: $repo,
          type: "new-work"
        }' >"$spec_dir/seed-manifest.json" 2>/dev/null || true

      echo "loop: auto-seed-block — created specs/$slug/ with plan.md stub and seed-manifest.json (schema_version 2)" >&2
    fi
  fi

  # --- Gate: consult should-materialize-spec.sh before blocking (#533) ---
  # When the issue has a committed stories.json the PO-agent's Step 1a gate
  # can materialize the plan autonomously — promote to Ready instead of blocking.
  local materialize_sh
  materialize_sh="$(dirname "$0")/should-materialize-spec.sh"

  local labels_raw=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_FILE:-}" ]]; then
    labels_raw="$(cat "${MAKATO_LOOP_RECONCILE_LABEL_FILE}" 2>/dev/null || true)"
  else
    labels_raw="$(gh issue view "$issue" "${repo_flag[@]}" \
      --json labels --jq '[.labels[].name] | .[]' 2>/dev/null || true)"
  fi
  local -a labels_arr=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && labels_arr+=("$lbl"); done <<<"$labels_raw"

  local gate_out="" gate_verdict="halt"
  if [[ -f "$materialize_sh" ]]; then
    # For to-issues shared folders the real plan is plan-<N>.md, not plan.md.
    # Prefer the issue-specific plan file when it exists so the gate sees a
    # valid plan and emits 'proceed plan-valid' rather than 'halt'.
    local plan_file="$spec_dir/plan.md"
    if [[ ! -f "$plan_file" && -f "$spec_dir/plan-${issue}.md" ]]; then
      plan_file="$spec_dir/plan-${issue}.md"
    fi
    gate_out="$(bash "$materialize_sh" "$plan_file" "${labels_arr[@]}" 2>/dev/null || true)"
    gate_verdict="${gate_out%% *}"
  else
    echo "loop: WARN — auto-seed-block #$issue: should-materialize-spec.sh not found; defaulting to block" >&2
  fi

  if [[ "$gate_verdict" == "materialize-refine" ]]; then
    echo "loop: auto-seed-block — #$issue materialize-refine verdict; promoting to Ready (skipping block)" >&2
    _auto_seed_promote_ready_from_gate "$issue"
    return 0
  fi

  # A 'proceed' verdict means a valid committed plan exists (plan.md or plan-<N>.md
  # in a to-issues shared folder) — #571 fix: must NOT be false-positive Blocked.
  if [[ "$gate_verdict" == "proceed" ]]; then
    echo "loop: auto-seed-block — #$issue gate verdict 'proceed' (valid committed plan); promoting to Ready (skipping block)" >&2
    _auto_seed_promote_ready_from_gate "$issue"
    return 0
  fi

  # --- Step 2: Move board card to Blocked + apply needs-human-review label ---

  # Test hook for the block (item-edit) step.
  if [[ -n "${MAKATO_LOOP_BLOCK_TEST_FILE:-}" ]]; then
    echo "block #${issue} plan_tier=${plan_tier:-untiered} → Blocked" \
      >>"$MAKATO_LOOP_BLOCK_TEST_FILE"
  else
    # Production path: resolve project config + item id, set Blocked.
    if [[ -f "$CONFIG_FILE" ]]; then
      local status_field_id blocked_option_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
      blocked_option_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE")"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

      if [[ -n "$status_field_id" && -n "$blocked_option_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        # Find or add the board item (mirrors seed-issue's item-add path).
        local item_id=""
        item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
          --url "https://github.com/${repo}/issues/$issue" \
          --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        if [[ -z "$item_id" ]]; then
          # Cheap single-issue lookup (~1 GraphQL point) before expensive item-list fallback.
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          if GH_HOST="$host" gh project item-edit --id "$item_id" \
              --project-id "$project_node_id" \
              --field-id "$status_field_id" \
              --single-select-option-id "$blocked_option_id" >/dev/null 2>&1; then
            echo "loop: auto-seed-block — set #$issue → Blocked on board" >&2
          else
            echo "loop: WARN — auto-seed-block #$issue: board item-edit to Blocked failed" >&2
          fi
        else
          echo "loop: WARN — auto-seed-block #$issue: could not resolve board item id" >&2
        fi
      else
        echo "loop: WARN — auto-seed-block #$issue: missing config fields for board Blocked move" >&2
      fi
    else
      echo "loop: WARN — auto-seed-block #$issue: .claude/config.json not found; skipping board move" >&2
    fi
  fi

  # Apply needs-human-review label (idempotent, create if absent).
  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  else
    if gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
      : # label exists
    else
      gh label create "needs-human-review" "${repo_flag[@]}" \
        --color "d93f0b" --description "Requires human review before autonomous dispatch" \
        >/dev/null 2>&1 || true
    fi
    if gh issue edit "$issue" "${repo_flag[@]}" \
        --add-label "needs-human-review" >/dev/null 2>&1; then
      echo "loop: auto-seed-block — applied 'needs-human-review' label to #$issue" >&2
    else
      echo "loop: WARN — auto-seed-block #$issue: could not apply needs-human-review label" >&2
    fi
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  fi

  # --- Step 3: Post sentinel-guarded launch-command comment ---
  local SENTINEL="<!-- makato:auto-seed-block:full -->"

  # Check for existing sentinel in issue comments.
  local existing_comments=""
  if [[ -n "${MAKATO_LOOP_COMMENTS_OVERRIDE:-}" ]]; then
    existing_comments="$(cat "$MAKATO_LOOP_COMMENTS_OVERRIDE" 2>/dev/null || echo '[]')"
  else
    existing_comments="$(gh issue view "$issue" "${repo_flag[@]}" \
      --json comments --jq '.comments' 2>/dev/null || echo '[]')"
  fi

  local sentinel_found=""
  sentinel_found="$(printf '%s' "$existing_comments" \
    | jq -r '.[].body' 2>/dev/null \
    | grep -F "$SENTINEL" | head -1 || true)"

  if [[ -n "$sentinel_found" ]]; then
    echo "loop: auto-seed-block — sentinel already present on #$issue; skipping comment" >&2
  else
    # Build the launch command: seed-issue skill with new-work type.
    local launch_cmd
    if [[ -n "$repo" ]]; then
      launch_cmd="/seed-issue ${issue} --type new-work  (or: claude code and invoke makato-orchestrate:seed-issue skill with args '${issue} --type new-work', repo=${repo})"
    else
      launch_cmd="/seed-issue ${issue} --type new-work  (or: claude code and invoke makato-orchestrate:seed-issue skill with args '${issue} --type new-work')"
    fi

    local comment_body
    comment_body="${SENTINEL}
This issue carries \`plan-tier:full\` (or no plan-tier label) and does not have a committed \`stories.json\` — the full makato-plan pipeline is needed before autonomous dispatch.

**To make this issue dispatchable without manual board action**, relabel it \`plan-tier:light\`: the auto-seed pass then dispatches \`seed-issue\` headlessly, the light-planner generates \`plan-<N>.md\`, and \`seed-issue\` moves the board card to **Status=Ready** on its own. Otherwise, run \`seed-issue\` yourself to generate a full \`plan.md\`:

\`\`\`
${launch_cmd}
\`\`\`

Once a valid \`plan.md\` exists, \`seed-issue\` moves the board card to **Status=Ready** — the sole dispatch signal — and the loop picks it up automatically. (The former \`status:ready-for-dev\` label bridge was removed in #688.)

_This comment was posted automatically by the makato auto-seed pass (#372)._"

    if [[ -n "${MAKATO_LOOP_COMMENT_TEST_FILE:-}" ]]; then
      echo "comment #${issue} sentinel=${SENTINEL}" >>"$MAKATO_LOOP_COMMENT_TEST_FILE"
      printf '%s\n' "$comment_body" >>"$MAKATO_LOOP_COMMENT_TEST_FILE"
    else
      if gh issue comment "$issue" "${repo_flag[@]}" \
          --body "$comment_body" >/dev/null 2>&1; then
        echo "loop: auto-seed-block — posted launch-command comment on #$issue" >&2
      else
        echo "loop: WARN — auto-seed-block #$issue: could not post launch-command comment" >&2
      fi
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_unprepared — composing pass: routes each open issue to S2 (light)
# or S4 (full/change/untiered) (#373, epic #367 S5). Always returns 0.
# ---------------------------------------------------------------------------
_auto_seed_unprepared() {
  echo "loop: auto-seed — starting pre-poll unprepared pass (#373, epic #367 S5)" >&2

  local candidates
  # Candidates function writes JSON to stdout, messages to stderr.
  candidates="$(_auto_seed_candidates)" 2>/dev/null || candidates='[]'
  [[ -n "$candidates" ]] || candidates='[]'

  local count
  count="$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)"
  echo "loop: auto-seed — $count candidate(s) to process" >&2

  local n plan_tier
  while IFS=$'\t' read -r n plan_tier; do
    [[ -n "$n" ]] || continue

    if [[ "$plan_tier" == "light" ]]; then
      # S2: dispatch seed-issue headlessly.
      local dispatch_rc=0
      _auto_seed_dispatch_light "$n" "$plan_tier" || dispatch_rc=$?
      if [[ "$dispatch_rc" -eq 0 ]]; then
        # S3: reconcile thin-body outcome; _auto_seed_reconcile_thin_body handles absent jsonl.
        local seed_key=""
        seed_key="$(_derive_key_for_issue "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
        _auto_seed_reconcile_thin_body "$n" "$seed_key" || true
      else
        echo "loop: WARN — auto-seed #$n light dispatch failed (rc=$dispatch_rc); tick continues" >&2
      fi
    else
      # S4: block full/untiered issues. (change-tier is a no-op in _auto_seed_block_full)
      _auto_seed_block_full "$n" "$plan_tier" || true
    fi
  done < <(jq -r '.[] | [.number, .plan_tier] | @tsv' <<<"$candidates" 2>/dev/null || true)

  echo "loop: auto-seed — pre-poll unprepared pass complete" >&2
  return 0
}

# _reap_epoch_of_iso <iso> — convert ISO-8601 ms timestamp to Unix epoch integer; empty on failure.
_reap_epoch_of_iso() {
  local iso="$1"
  [[ -n "$iso" && "$iso" != "null" ]] || return 0
  python3 -c "import sys,datetime
try:
    s=sys.argv[1].replace('Z','+00:00')
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    pass" "$iso" 2>/dev/null || true
}

# _derive_reap_repo — resolve owner/repo for `gh pr list` (REAP_REPO > DISPATCH_REPO > git remote).
_derive_reap_repo() {
  if [[ -n "${MAKATO_LOOP_REAP_REPO:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_REAP_REPO"; return 0
  fi
  if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_DISPATCH_REPO"; return 0
  fi
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||' || true
}

# _reap_pr_merged <repo> <branch> — echo merged PR number or empty. MAKATO_LOOP_REAP_GH_OVERRIDE for offline tests.
_reap_pr_merged() {
  local repo="$1" branch="$2"
  if [[ -n "${MAKATO_LOOP_REAP_GH_OVERRIDE:-}" ]]; then
    jq -r --arg b "$branch" '.[$b] // empty' \
      "$MAKATO_LOOP_REAP_GH_OVERRIDE" 2>/dev/null || true
    return 0
  fi
  [[ -n "$repo" ]] || return 0
  gh pr list --repo "$repo" --head "$branch" --state merged \
    --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# _reap_base_ref — resolve default-branch ref for ancestry check (REAP_BASE_REF > origin/HEAD > origin/main).
_reap_base_ref() {
  if [[ -n "${MAKATO_LOOP_REAP_BASE_REF:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_REAP_BASE_REF"; return 0
  fi
  local ref
  ref="$(git -C "$REPO_ROOT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/@@')"
  [[ -n "$ref" ]] && { printf '%s\n' "$ref"; return 0; }
  printf 'origin/main\n'
}

# _reap_branch_landed <head> <branch> <repo> <base-ref> — echo landing reason when work is on base (merged PR or ancestor); empty otherwise.
# HEAD==base-tip is NOT landed: a fresh worktree sitting on base has no work yet — only a merged PR counts there.
_reap_branch_landed() {
  local head="$1" branch="$2" repo="$3" base_ref="$4"
  local pr
  pr="$(_reap_pr_merged "$repo" "$branch")"
  if [[ -n "$pr" ]]; then printf 'merged PR #%s\n' "$pr"; return 0; fi
  local base_tip
  base_tip="$(git -C "$REPO_ROOT" rev-parse -q --verify "$base_ref" 2>/dev/null || true)"
  if [[ -n "$base_tip" && -n "$head" && "$head" != "$base_tip" ]]; then
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$head" "$base_ref" 2>/dev/null; then
      printf 'ancestor of %s\n' "$base_ref"; return 0
    fi
  fi
  return 0
}

# _reap_is_retained <realpath> — return 0 when any workflow-state has .worktree_retained==true for this path.
_reap_is_retained() {
  local target="$1"
  [[ -d "$SPECS_DIR" ]] || return 1
  local match
  match="$(find "$SPECS_DIR" -maxdepth 2 \
      \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
      -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      local wp retained rp
      retained="$(jq -r '.worktree_retained // false' "$f" 2>/dev/null || echo false)"
      [[ "$retained" == "true" ]] || continue
      wp="$(jq -r '.worktree_path // empty' "$f" 2>/dev/null || true)"
      [[ -n "$wp" ]] || continue
      rp="$(_realpath "$wp")"
      if [[ "$rp" == "$target" ]]; then echo "match"; break; fi
    done)"
  [[ -n "$match" ]]
}

# _realpath <path> — canonicalise path (resolves macOS /var→/private/var); matches worktree.sh helper.
_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s\n' "$1"
}

# _reap_wt_age_secs <dir> — return worktree directory age in seconds; 0 on stat failure (safe: treats broken dir as young).
_reap_wt_age_secs() {
  local dir="$1"
  # Use python3 for portable mtime — avoids macOS BSD vs GNU `stat` flag incompatibility; 0 on error = safe (no false-positive reap).
  python3 -c '
import os, sys, time
try:
    mtime = os.path.getmtime(sys.argv[1])
    print(int(time.time() - mtime))
except Exception:
    print(0)
' "$dir" 2>/dev/null || echo 0
}

# _reap_owner_pid_alive <dir> — return 0 when the owning loop.sh PID (from .loop-owner.pid) is alive.
_reap_owner_pid_alive() {
  local dir="$1"
  local pid_file="$dir/.loop-owner.pid"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || echo "")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# _reap_has_unpushed <dir> <branch> — return 0 when branch has commits not pushed to remote tracking; 1 when no upstream or on error.
_reap_has_unpushed() {
  local dir="$1" branch="$2"
  # Verify remote tracking ref exists; absent = no unpushed.
  local upstream
  upstream="$(git -C "$dir" rev-parse --abbrev-ref "@{u}" 2>/dev/null || echo "")"
  [[ -n "$upstream" ]] || return 1
  # Any commit reachable from HEAD but not from remote tracking ref.
  local count
  count="$(git -C "$dir" rev-list --count HEAD "^$upstream" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]]
}

# _reap_merged_worktrees — sweep .claude/worktrees/ and remove landed/stale worktrees (#265). Guards: main-checkout, path, nested-wt, locked, detached, dirty, retained, landed (merged PR or ancestor) or stale-crash (#320). Throttled by REAP_INTERVAL_SECS.
_reap_merged_worktrees() {
  [[ "$REAP_ON_POLL" == "1" ]] || return 0

  # Throttle — skip when a pass ran within the interval window.
  if [[ "${REAP_INTERVAL_SECS:-3600}" -gt 0 ]]; then
    local last_reap last_epoch now_epoch
    last_reap="$(_read_status | jq -r '.last_reap // empty' 2>/dev/null || true)"
    last_epoch="$(_reap_epoch_of_iso "$last_reap")"
    if [[ -n "$last_epoch" ]]; then
      now_epoch="$(date +%s)"
      if (( now_epoch - last_epoch < REAP_INTERVAL_SECS )); then
        return 0
      fi
    fi
  fi

  local dryrun="${MAKATO_LOOP_REAP_DRYRUN:-}"
  local repo self_path wt_base porcelain base_ref
  repo="$(_derive_reap_repo)"
  base_ref="$(_reap_base_ref)"
  self_path="$(_realpath "$REPO_ROOT")"
  wt_base="$(_realpath "$REPO_ROOT/.claude/worktrees")"

  if [[ -n "${MAKATO_LOOP_REAP_WT_OVERRIDE:-}" ]]; then
    porcelain="$(cat "$MAKATO_LOOP_REAP_WT_OVERRIDE" 2>/dev/null || true)"
  else
    porcelain="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"
  fi
  [[ -n "$porcelain" ]] || { _reap_stamp 0 ""; return 0; }

  # First pass: collect all worktree realpaths for guard 3 nested-wt detection.
  local all_paths=()
  local line p
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p="${line#worktree }"; all_paths+=("$(_realpath "$p")") ;;
    esac
  done <<<"$porcelain"

  # Second pass: parse stanzas and apply the guard stack.
  local reaped_json="[]"
  local reaped_count=0
  local cur_path="" cur_branch="" cur_locked="" cur_detached="" cur_head=""

  _reap_process_stanza() {
    [[ -n "$cur_path" ]] || return 0
    local rp="$cur_path" branch="$cur_branch"

    # Guard 1: main checkout.
    if [[ "$rp" == "$self_path" ]]; then
      echo "loop: reap skip $rp (main checkout)" >&2; return 0
    fi
    # Guard 2: under .claude/worktrees/.
    if [[ "$rp" != "$wt_base/"* ]]; then
      echo "loop: reap skip $rp (outside .claude/worktrees)" >&2; return 0
    fi
    # Guard 3: nested-worktree relationship — skip if candidate is parent of another wt (a) or nested inside one (b).
    local other
    for other in "${all_paths[@]}"; do
      [[ "$other" == "$rp" ]] && continue
      if [[ "$other" == "$rp/"* ]]; then
        echo "loop: reap skip $rp (parent of nested worktree)" >&2; return 0
      fi
      if [[ "$other" != "$self_path" && "$rp" == "$other/"* ]]; then
        echo "loop: reap skip $rp (nested inside worktree $other)" >&2; return 0
      fi
    done
    # Guard 4: locked.
    if [[ -n "$cur_locked" ]]; then
      echo "loop: reap skip $rp (locked)" >&2; return 0
    fi
    # Guard 5: detached HEAD.
    if [[ -n "$cur_detached" || -z "$branch" ]]; then
      echo "loop: reap skip $rp (detached HEAD / no branch)" >&2; return 0
    fi
    # Guard 6: dirty working tree — TRACKED changes only (`??` untracked scratch does not pin).
    if git -C "$rp" status --porcelain 2>/dev/null | grep -qv '^??'; then
      echo "loop: reap skip $rp (dirty working tree — tracked changes)" >&2; return 0
    fi
    # Guard 7: retained via workflow-state.
    if _reap_is_retained "$rp"; then
      echo "loop: reap skip $rp (worktree_retained=true)" >&2; return 0
    fi
    # Guard 8: branch must have LANDED (merged PR or ancestor of base); Guard 9 can authorise without landing.
    local landed=""
    landed="$(_reap_branch_landed "$cur_head" "$branch" "$repo" "$base_ref")"
    if [[ -z "$landed" ]]; then
      # Guard 9 (#320): stale-crash reap — branch NOT landed, owner pid dead, age >= REAP_STALE_AGE_SECS.
      # Safety: (a) live pid skips, (b) unpushed blocks unless REAP_STALE_FORCE=1, (c) age gate prevents mis-reap of fresh wt.

      # (a) live owner — skip
      if _reap_owner_pid_alive "$rp"; then
        echo "loop: reap skip $rp (branch $branch not landed; owner pid alive)" >&2; return 0
      fi
      # (c) age gate
      local age
      age="$(_reap_wt_age_secs "$rp")"
      if [[ "${REAP_STALE_AGE_SECS:-86400}" -gt 0 ]] && \
         (( age < REAP_STALE_AGE_SECS )); then
        echo "loop: reap skip $rp (branch $branch not landed; worktree too young ${age}s < ${REAP_STALE_AGE_SECS}s)" >&2; return 0
      fi
      # (b) unpushed commits gate
      if _reap_has_unpushed "$rp" "$branch"; then
        if [[ "${REAP_STALE_FORCE:-0}" != "1" ]]; then
          echo "loop: reap skip $rp (branch $branch not landed; unpushed commits — set MAKATO_LOOP_REAP_STALE_FORCE=1 to override)" >&2; return 0
        fi
        echo "loop: reap WARN $rp (branch $branch not landed; unpushed commits present; REAP_STALE_FORCE=1)" >&2
      fi

      # Passed all stale-crash guards — authorise reap.
      landed="stale-crashed worktree (owner pid dead, age ${age}s)"
    fi

    if [[ -n "$dryrun" ]]; then
      echo "loop: reap would remove $rp ($landed, branch $branch)" >&2
      return 0
    fi
    echo "loop: reap removing $rp ($landed, branch $branch)" >&2
    if git -C "$REPO_ROOT" worktree remove --force "$rp" >/dev/null 2>&1; then
      reaped_json="$(jq -c --arg p "$rp" --arg b "$branch" --arg r "$landed" \
        '. + [{path:$p, branch:$b, landed:$r}]' <<<"$reaped_json")"
      reaped_count=$((reaped_count + 1))
    else
      echo "loop: WARN — reap remove failed for $rp (tick continues)" >&2
    fi
  }

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        _reap_process_stanza
        cur_path="$(_realpath "${line#worktree }")"
        cur_branch=""; cur_locked=""; cur_detached=""; cur_head=""
        ;;
      "HEAD "*)              cur_head="${line#HEAD }" ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "detached")            cur_detached=1 ;;
      "locked"*)             cur_locked=1 ;;
    esac
  done <<<"$porcelain"
  _reap_process_stanza   # flush the final stanza (no trailing blank guaranteed)

  # Prune stale registrations left by removals (best-effort).
  if [[ -z "$dryrun" && "$reaped_count" -gt 0 ]]; then
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi

  # Orphaned specs/ folder pruning — same pass window, same throttle; failure never aborts the worktree-reap audit.
  _reap_orphan_specs || true

  _reap_stamp "$reaped_count" "$reaped_json"
  return 0
}

# _reap_stamp <count> <reaped-json> — write reap-pass audit into loop-status.json.
_reap_stamp() {
  local count="$1" reaped_json="${2:-}"
  _patch_status '.last_reap' "\"$(_now)\""
  _patch_status '.last_reap_count' "${count:-0}"
  if [[ "${count:-0}" -gt 0 && -n "$reaped_json" ]]; then
    _patch_status '.reaped' "$reaped_json"
  fi
}

# _reap_orphan_specs — prune local specs/<slug>/ for completed/closed issues (#265); shares REAP_ON_POLL + throttle.
# Per folder: skip if tracked files, derive issue#, check phase=done or gh CLOSED, shared-epic guard, promote lessons then rm. Always returns 0.
_reap_orphan_specs() {
  [[ "$REAP_SPECS" == "1" ]] || return 0

  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  [[ -d "$spec_root" ]] || return 0

  local dryrun="${MAKATO_LOOP_REAP_DRYRUN:-}"
  local pruned_count=0
  local pruned_json="[]"

  local slug_dir
  while IFS= read -r -d '' slug_dir; do
    [[ -d "$slug_dir" ]] || continue

    # Guard 1: must be fully untracked (see NEVER note above).
    if [[ -n "$(git -C "$REPO_ROOT" ls-files "$slug_dir" 2>/dev/null)" ]]; then
      echo "loop: reap-specs skip $slug_dir (has tracked files — managed by archive-spec.sh)" >&2
      continue
    fi

    # Derive the issue number: seed-manifest first, workflow-state filename fallback.
    local issue_num=""
    if [[ -f "$slug_dir/seed-manifest.json" ]]; then
      issue_num="$(jq -r '.issue_number // empty' "$slug_dir/seed-manifest.json" 2>/dev/null || true)"
    fi
    if [[ -z "$issue_num" ]]; then
      local wf_file
      wf_file="$(find "$slug_dir" -maxdepth 1 -name 'workflow-state-*.json' 2>/dev/null | head -1)"
      if [[ -n "$wf_file" ]]; then
        issue_num="$(basename "$wf_file" | sed -E 's/^workflow-state-([0-9]+)\.json$/\1/')"
      fi
    fi
    if [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]]; then
      # No <N>- prefix + no manifest/workflow-state = design-doc/scratch folder (info); issue-derived but unresolvable = anomaly (WARN).
      local slug_basename
      slug_basename="$(basename "$slug_dir")"
      if [[ ! "$slug_basename" =~ ^[0-9] ]] \
          && [[ ! -f "$slug_dir/seed-manifest.json" ]] \
          && [[ -z "$(find "$slug_dir" -maxdepth 1 -name 'workflow-state-*.json' 2>/dev/null | head -1)" ]]; then
        echo "loop: reap-specs skip $slug_dir (no issue prefix, treating as design-doc folder)" >&2
      else
        echo "loop: reap-specs WARN $slug_dir — cannot derive issue number, skipping" >&2
      fi
      continue
    fi

    # Done signal — fast local path: workflow-state phase=done.
    local reason=""
    local wf_phase_file="$slug_dir/workflow-state-${issue_num}.json"
    if [[ -f "$wf_phase_file" ]]; then
      local phase
      phase="$(jq -r '.current_phase // empty' "$wf_phase_file" 2>/dev/null || true)"
      [[ "$phase" == "done" ]] && reason="workflow-state phase=done"
    fi

    # Fallback: gh issue state (offline override in tests).
    if [[ -z "$reason" ]]; then
      local gh_state=""
      if [[ -n "${MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE:-}" ]]; then
        gh_state="$(jq -r --arg n "$issue_num" '.[$n] // empty' \
          "$MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
      else
        local repo; repo="$(_derive_reap_repo)"
        local -a repo_flag=()
        [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
        gh_state="$(gh issue view "$issue_num" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
          | tr '[:upper:]' '[:lower:]' || true)"
      fi
      if [[ "$gh_state" == "closed" ]]; then
        reason="issue #${issue_num} CLOSED"
      elif [[ "$gh_state" == "open" ]]; then
        echo "loop: reap-specs skip $slug_dir (issue #${issue_num} is OPEN)" >&2
        continue
      else
        echo "loop: reap-specs WARN $slug_dir (issue #${issue_num} gh state unknown: '${gh_state}') — skipping" >&2
        continue
      fi
    fi

    # Guard 6 (shared-epic): keep folder while ANY sibling issue is open — one stories.json is the shared AC/plan store.
    local epic_manifest=""
    for cand in "$slug_dir/created-issues.json" "$slug_dir/stories.json"; do
      [[ -f "$cand" ]] && { epic_manifest="$cand"; break; }
    done
    if [[ -n "$epic_manifest" ]]; then
      # Collect every issue number in the manifest (both created-issues.json and stories.json shapes), excluding current.
      local -a siblings=()
      while IFS= read -r sib; do
        [[ -n "$sib" && "$sib" != "$issue_num" ]] && siblings+=("$sib")
      done < <(jq -r '
        [ (.issues[]?.issue_number // empty),
          (.stories[]?.issue_number // empty),
          (.stories[]?.githubIssue // empty) ]
        | .[] | numbers' "$epic_manifest" 2>/dev/null | sort -u)

      if [[ "${#siblings[@]}" -gt 0 ]]; then
        local open_sibling=""
        for sib in "${siblings[@]}"; do
          local sib_state=""
          if [[ -n "${MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE:-}" ]]; then
            sib_state="$(jq -r --arg n "$sib" '.[$n] // empty' \
              "$MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
          else
            local sib_repo; sib_repo="$(_derive_reap_repo)"
            local -a sib_repo_flag=()
            [[ -n "$sib_repo" ]] && sib_repo_flag=(--repo "$sib_repo")
            sib_state="$(gh issue view "$sib" "${sib_repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
              | tr '[:upper:]' '[:lower:]' || true)"
          fi
          # Anything not definitively "closed" (open, or unreadable) pins the folder.
          if [[ "$sib_state" != "closed" ]]; then
            open_sibling="$sib"
            break
          fi
        done
        if [[ -n "$open_sibling" ]]; then
          echo "loop: reap-specs skip $slug_dir (shared-epic folder — sibling issue #${open_sibling} still open; keeping shared plans)" >&2
          continue
        fi
      fi
    fi

    # Prune (or log intent under dryrun).
    if [[ -n "$dryrun" ]]; then
      echo "loop: reap-specs would remove $slug_dir (issue #${issue_num}, ${reason})" >&2
    else
      # Promote lessons before deleting — gitignored sources only visible here; non-zero exit = KEEP to avoid lesson loss.
      local promote_sh; promote_sh="$(dirname "$0")/promote-lessons.sh"
      if [[ -f "$promote_sh" ]]; then
        if ! bash "$promote_sh" "$issue_num" "$spec_root" \
               "${REPO_ROOT}/.makato/memory/procedural.jsonl" >/dev/null 2>&1; then
          echo "loop: reap-specs SKIP $slug_dir (issue #${issue_num}) — promote-lessons failed, keeping folder to avoid lesson loss" >&2
          continue
        fi
      fi
      echo "loop: reap-specs removing $slug_dir (issue #${issue_num}, ${reason})" >&2
      if rm -rf "$slug_dir" 2>/dev/null; then
        pruned_json="$(jq -c --arg d "$slug_dir" --arg n "$issue_num" --arg r "$reason" \
          '. + [{dir:$d, issue:$n, reason:$r}]' <<<"$pruned_json")"
        pruned_count=$((pruned_count + 1))
      else
        echo "loop: WARN — reap-specs remove failed for $slug_dir (tick continues)" >&2
      fi
    fi
  done < <(find "$spec_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  # Audit — write count every live pass; the array only when something moved.
  if [[ -z "$dryrun" ]]; then
    _patch_status '.last_reap_specs_count' "${pruned_count}"
    if [[ "$pruned_count" -gt 0 ]]; then
      _patch_status '.reap_specs_pruned' "$pruned_json"
    fi
  fi

  return 0
}

# remove-worktrees — standalone entry point for merged-worktree reaper (#265); also called by cmd_run each poll.
cmd_remove_worktrees() {
  _reap_merged_worktrees
}

# _pre_dispatch_plan_guard <KEY> — validate plan.md; if invalid, attempt build-refine --autonomous recovery, then re-validate.
# Emits "<verdict>:<refine_attempted>:<refine_outcome>" on stdout. Never blocks dispatch.
_pre_dispatch_plan_guard() {
  local key="$1"
  local validate_sh
  validate_sh="$(dirname "$0")/validate-plan-body.sh"

  # Locate plan.md via the same glob _spec_folder_for_key uses.
  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  local plan_path
  plan_path="$(find "$spec_root" -maxdepth 2 -name "plan.md" \
    -path "*/${key}*" 2>/dev/null | head -1)"

  if [[ -z "$plan_path" ]]; then
    echo "skipped:false:n/a"
    return 0
  fi

  if [[ ! -x "$validate_sh" && ! -f "$validate_sh" ]]; then
    echo "error:false:n/a"
    return 0
  fi

  local guard_out guard_verdict
  guard_out="$(bash "$validate_sh" "$plan_path" 2>/dev/null || true)"
  guard_verdict="${guard_out%% *}"

  if [[ "$guard_verdict" == "valid" ]]; then
    echo "valid:false:n/a"
    return 0
  fi

  # Plan is invalid — attempt build-refine --autonomous as recovery.
  # exit 127 = claude binary not launchable (PATH issue), not a refine logic failure — branched below.
  echo "loop: pre-dispatch plan guard: plan.md invalid for KEY=${key} — running build-refine --autonomous" >&2

  local refine_prompt="Use the Skill tool to invoke the makato-build:build-refine skill with args '${key} --autonomous'. REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. Return R1 envelope verbatim."
  local refine_exit=0
  MAKATO_HEADLESS=1 REPO_ROOT="$REPO_ROOT" \
    "$CLAUDE_BIN" --yolo -p "$refine_prompt" \
    >/dev/null 2>&1 || refine_exit=$?

  if [[ $refine_exit -eq 127 ]]; then
    # exit 127 = skill not launchable — expected infra skip, not a refine failure.
    echo "loop: pre-dispatch plan guard: build-refine skill not launchable (exit 127) for KEY=${key} — skipping refine, dispatching anyway" >&2
    echo "invalid:true:error"
    return 0
  fi
  if [[ $refine_exit -ne 0 ]]; then
    echo "loop: pre-dispatch plan guard: build-refine exited ${refine_exit} for KEY=${key} — dispatching anyway" >&2
    echo "invalid:true:error"
    return 0
  fi

  # Re-validate after refine — this is the single authoritative post-refine check.
  local guard_out2 guard_verdict2
  guard_out2="$(bash "$validate_sh" "$plan_path" 2>/dev/null || true)"
  guard_verdict2="${guard_out2%% *}"

  if [[ "$guard_verdict2" == "valid" ]]; then
    echo "loop: pre-dispatch plan guard: build-refine produced a valid plan for KEY=${key}" >&2
    echo "valid:true:valid"
  else
    echo "loop: pre-dispatch plan guard: build-refine did not produce a valid plan for KEY=${key} — dispatching anyway" >&2
    echo "invalid:true:invalid"
  fi
}

# _emit_langfuse_trace <log_file> <issue> — pipe stop-hook payload to langfuse_hook.py after dispatch; skipped when TRACE_TO_LANGFUSE!=true or session_id absent.
# _extract_session_id <log_file> — extract omp session UUID from stream-json result line per D16 contract; sole source of truth for session-id extraction (#616).
_extract_session_id() {
  local log_file="${1:-}"
  [[ -f "$log_file" ]] || return 0
  grep '"type":"result"' "$log_file" 2>/dev/null \
    | tail -1 \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("session_id",""))' 2>/dev/null || true
}

_emit_langfuse_trace() {
  local log_file="${1:-}" issue="${2:-}"
  [[ "${TRACE_TO_LANGFUSE:-false}" == "true" ]] || return 0
  [[ -f "$log_file" ]] || return 0

  # Resolve hook — prefer working-tree copy, fall back to marketplace cache.
  local hook_py=""
  local _candidates=(
    "$REPO_ROOT/plugins/makato-observability/hooks/langfuse_hook.py"
    "$HOME/.claude/plugins/marketplaces/makato-suite/plugins/makato-observability/hooks/langfuse_hook.py"
  )
  local _c
  for _c in "${_candidates[@]}"; do
    if [[ -f "$_c" ]]; then hook_py="$_c"; break; fi
  done
  [[ -n "$hook_py" ]] || return 0

  # Extract session_id from the terminal {"type":"result",...} line.
  local session_id
  session_id="$(_extract_session_id "$log_file")"
  [[ -n "$session_id" ]] || return 0

  # Derive transcript path: honour MAKATO_TRANSCRIPT_PATH when set (caller or config
  # supplies the full path including session suffix); fall back to the legacy
  # ~/.claude/projects/<hash>/<session_id>.jsonl derivation for backward compatibility.
  local project_hash
  project_hash="$(echo -n "$REPO_ROOT" | sed 's|/|-|g' | sed 's|^-||')"
  local transcript
  if [[ -n "${MAKATO_TRANSCRIPT_PATH:-}" ]]; then
    transcript="$MAKATO_TRANSCRIPT_PATH"
  else
    transcript="$HOME/.claude/projects/${project_hash}/${session_id}.jsonl"
  fi
  [[ -f "$transcript" ]] || return 0

  # Read issue_trace_id from workflow-state when available.
  local issue_trace_id=""
  if [[ -n "${issue:-}" ]]; then
    local wf_file
    wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
    if [[ -n "$wf_file" ]]; then
      issue_trace_id="$(jq -r '.issue_trace_id // empty' "$wf_file" 2>/dev/null || true)"
    fi
  fi

  # Build payload via jq to avoid inline string interpolation with untrusted values.
  local payload_json
  payload_json="$(jq -n \
    --arg sid "$session_id" \
    --arg tp "$transcript" \
    --arg tid "${issue_trace_id:-}" \
    'if $tid != "" then {sessionId:$sid,transcriptPath:$tp,issue_trace_id:$tid}
     else {sessionId:$sid,transcriptPath:$tp} end')"
  python3 "$hook_py" <<< "$payload_json" 2>/dev/null || true
}

# dispatch <ISSUE_NUMBER> [--repo owner/repo] [--dry-run] — drive one issue to a merged PR; --repo required outside cmd_run.
cmd_dispatch() {
  local issue="${1:?issue number required}"
  shift
  local dry_run=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)    MAKATO_LOOP_DISPATCH_REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
      --dry-run) dry_run="--dry-run"; shift ;;
      *) echo "loop: dispatch: unknown flag: $1" >&2; return 64 ;;
    esac
  done

  # Require explicit repo — ambient git remote is the makato repo, not the target.
  if [[ -z "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
    echo "loop: dispatch: REPO is required — set MAKATO_LOOP_DISPATCH_REPO or pass --repo owner/repo" >&2
    return 1
  fi

  # #171 idempotent-dispatch guard — silent no-op when same issue dispatched within guard window (sleep-wake burst / state-write race).
  if _within_dispatch_guard "$issue"; then
    echo "loop: dispatch #$issue skipped by guard (recent same-issue dispatch within window)" >&2
    return 0
  fi

  # Refuse to dispatch when a workflow is already active in this loop session.
  local active
  active="$(_read_status | jq -r '.active_workflow.issue // empty')"
  if [[ -n "$active" && "$active" != "$issue" ]]; then
    echo "loop: refuse to dispatch #$issue — active_workflow=#$active (single-threaded)" >&2
    return 2
  fi

  local now
  now="$(_now)"
  local active_obj
  active_obj="$(jq -n --argjson issue "$issue" --arg ts "$now" \
    '{issue: $issue, started_at: $ts, stalled: false, stalled_since: null, killed_by_watchdog: false}')"
  _patch_status '.active_workflow' "$active_obj"
  # Stamp .last_dispatch_at / .last_dispatch_issue — guard predicate B needs this to detect same-issue re-dispatch after active_workflow clears.
  _patch_status '.last_dispatch_at' "\"$now\""
  _patch_status '.last_dispatch_issue' "$issue"

  # Derive KEY (to-issues provenance slug) and BRANCH (feat/<issue>-<key>) for po-agent dispatch.
  # On failure: key="" → po-agent fails input validation (better than silent missing inputs).
  local key="" branch=""
  if key="$(_derive_key_for_issue "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}")"; then
    # Avoid doubled issue-number prefix: key=470-foo → feat/470-foo (not feat/470-470-foo).
    if [[ "$key" == "${issue}-"* ]]; then
      branch="feat/${key}"
    else
      branch="feat/${issue}-${key}"
    fi
  else
    key=""
    echo "loop: WARN — could not derive KEY for issue #${issue} (no to-issues provenance in body); po-agent will fail input validation" >&2
  fi

  # Routing: type:change → makato-change:orchestrate --autonomous; else → po-agent.
  # Resolved before the spec-folder gate: change-orchestrate owns its folder lifecycle (Step 0.5).
  # Test hook: MAKATO_LOOP_ISSUE_TYPE_OVERRIDE. Test seam: MAKATO_LOOP_ROUTING_LABELS_OVERRIDE.
  local issue_type=""
  if [[ -n "${MAKATO_LOOP_ISSUE_TYPE_OVERRIDE:-}" ]]; then
    issue_type="$MAKATO_LOOP_ISSUE_TYPE_OVERRIDE"
  else
    # #447: REST fallback for routing label fetch — shape-agnostic; fail-open (empty issue_type → po-agent path).
    local _rt_repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    local -a _rt_repo_flag=()
    [[ -n "$_rt_repo" ]] && _rt_repo_flag=(--repo "$_rt_repo")
    local _rt_rest_path
    if [[ -n "$_rt_repo" ]]; then
      _rt_rest_path="repos/${_rt_repo}/issues/${issue}"
    else
      _rt_rest_path="repos/{owner}/{repo}/issues/${issue}"
    fi
    local labels_json=""
    if [[ -n "${MAKATO_LOOP_ROUTING_LABELS_OVERRIDE:-}" ]]; then
      labels_json="$(cat "${MAKATO_LOOP_ROUTING_LABELS_OVERRIDE}" 2>/dev/null || true)"
    elif labels_json="$(_gh_with_fallback "issue-type routing #${issue}" \
        issue view "$issue" "${_rt_repo_flag[@]}" --json labels \
        -- api "$_rt_rest_path")"; then
      : # labels_json set by _gh_with_fallback
    fi
    if [[ -n "$labels_json" ]]; then
      # #760: plan-tier:change takes priority over type:* — avoids po-agent dispatch of change issues that also carry type:fix/feat (#539 regression).
      if jq -e '[.labels[].name] | contains(["plan-tier:change"])' \
          <<<"$labels_json" >/dev/null 2>&1; then
        issue_type="type:change"
      else
        issue_type="$(jq -r \
          '[.labels[].name | select(startswith("type:"))] | first // ""' \
          <<<"$labels_json" 2>/dev/null || true)"
      fi
    fi
  fi

  # Pre-dispatch spec-folder gate (#445) — KEY must resolve to a specs/ folder; else route to auto-seed (no dispatch slot consumed).
  # Skipped for type:change (change-orchestrate creates its own folder) and derivation failures. Test seam: SPECS_DIR.
  if [[ -n "$key" && "$issue_type" != "type:change" \
        && "$dry_run" != "--dry-run" \
        && "${MAKATO_LOOP_DRY_DISPATCH:-0}" != "1" ]] \
      && ! _spec_folder_for_key "$key" >/dev/null 2>&1; then
    echo "loop: WARN — pre-dispatch: KEY '${key}' matches no specs/ folder for #${issue}; routing to auto-seed, slot not consumed" >&2
    _auto_seed_unprepared "$issue" 2>/dev/null || true
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Pre-dispatch plan guard — validate plan.md, attempt build-refine recovery; never blocks dispatch. Skipped for type:change and dry-run.
  local _pdpg_tuple="skipped:false:n/a"
  if [[ "$issue_type" != "type:change" \
        && "$dry_run" != "--dry-run" \
        && "${MAKATO_LOOP_DRY_DISPATCH:-0}" != "1" \
        && -n "$key" ]]; then
    # Guard returns tuple — parse in one shot to avoid redundant validate-plan-body.sh invocation.
    _pdpg_tuple="$(_pre_dispatch_plan_guard "$key")"
  fi
  local _pdpg_verdict="${_pdpg_tuple%%:*}"
  local _pdpg_rest="${_pdpg_tuple#*:}"
  local _pdpg_refine_attempted="${_pdpg_rest%%:*}"
  local _pdpg_refine_outcome="${_pdpg_rest#*:}"
  _patch_status '.pre_dispatch_plan_guard' \
    "$(jq -n \
      --arg verdict "$_pdpg_verdict" \
      --argjson refine_attempted "$([[ "$_pdpg_refine_attempted" == "true" ]] && echo true || echo false)" \
      --arg refine_outcome "$_pdpg_refine_outcome" \
      '{verdict: $verdict, refine_attempted: $refine_attempted, refine_outcome: $refine_outcome}')"

  if [[ "$dry_run" == "--dry-run" ]]; then
    if [[ "$issue_type" == "type:change" ]]; then
      echo "loop: --dry-run — would exec: $CLAUDE_BIN --yolo -p \"<dispatch makato-change:orchestrate --autonomous for issue #${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} REPO_ROOT=${REPO_ROOT}>\"" >&2
    else
      echo "loop: --dry-run — would exec: $CLAUDE_BIN --yolo -p \"<dispatch makato-orchestrate:po-agent for issue #${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} BRANCH=${branch} REPO_ROOT=${REPO_ROOT}>\"" >&2
    fi
    echo "loop: --dry-run — would claim #${issue} (board Ready → In progress, CAS)" >&2
    echo "loop: --dry-run — would assign #${issue} to ${ASSIGNEE} (board → In progress)" >&2
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Dispatch gate (#318/#355) — refuse to dispatch merged or in-flight issues; skipped when GATE_DISABLE=1. Best-effort, never writes board Status (D5).
  local gate_is_orphan=0
  if [[ "$GATE_DISABLE" != "1" ]]; then
    # Task 1 — Consolidated label+title fetch (D10 enabler); offline: MAKATO_LOOP_GATE_LABELS_OVERRIDE; fail-open on read error.
    local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    local gate_labels_json=""
    if [[ -n "${MAKATO_LOOP_GATE_LABELS_OVERRIDE:-}" ]]; then
      if ! gate_labels_json="$(cat "${MAKATO_LOOP_GATE_LABELS_OVERRIDE}" 2>/dev/null)"; then
        echo "loop: WARN — gate: could not read MAKATO_LOOP_GATE_LABELS_OVERRIDE ('${MAKATO_LOOP_GATE_LABELS_OVERRIDE}'); proceeding" >&2
        gate_labels_json=""
      fi
    else
      # #447: REST fallback for gate label+title fetch; shape-agnostic; fail-open on wrapper failure.
      local gate_rest_path
      if [[ -n "$repo" ]]; then
        gate_rest_path="repos/${repo}/issues/${issue}"
      else
        gate_rest_path="repos/{owner}/{repo}/issues/${issue}"
      fi
      local -a gate_repo_flag=()
      [[ -n "$repo" ]] && gate_repo_flag=(--repo "$repo")
      if ! gate_labels_json="$(_gh_with_fallback "gate labels #${issue}" \
          issue view "$issue" "${gate_repo_flag[@]}" --json labels,title \
          -- api "$gate_rest_path")"; then
        echo "loop: WARN — gate: could not fetch labels for #${issue}; proceeding" >&2
        gate_labels_json=""
      fi
    fi

    # Orphan detection (D6, #357): no created-issues.json in any specs/ folder referencing this issue.
    if _is_orphan_issue "$issue"; then
      gate_is_orphan=1
    fi

    # Task 3 — Exclusion-label veto (D4): applies to orphan and non-orphan alike.
    local gate_veto_label=""
    if [[ -n "$gate_labels_json" ]]; then
      # shellcheck disable=SC2086  # intentional word-split: space-separated labels → one per line for jq -R (mirrors line ~3515)
      gate_veto_label="$(jq -r \
        --argjson excl "$(printf '%s\n' $_PROMOTE_EXCLUSION_LABELS | jq -R . | jq -s .)" \
        '[.labels[].name] as $lbls | $excl[] | select(. as $e | $lbls | any(. == $e)) | .' \
        <<<"$gate_labels_json" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$gate_veto_label" ]]; then
      echo "loop: gate — #${issue} carries exclusion label '${gate_veto_label}'; skip dispatch" >&2
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Task 4 — Tier 1: merged-PR check (both orphan+non-orphan; skip when branch empty to avoid false-positive gh pr list).
    local gate_merged_pr=""
    if [[ -n "$branch" ]]; then
      gate_merged_pr="$(_reap_pr_merged "$repo" "$branch" 2>/dev/null || true)"
    fi
    if [[ -n "$gate_merged_pr" ]]; then
      echo "loop: gate — #${issue} branch '${branch}' already merged (PR #${gate_merged_pr}); skip dispatch + stamp needs-human-review" >&2
      gh issue edit "$issue" --repo "$repo" --add-label needs-human-review 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "$repo" \
        --reason "Branch '${branch}' was already merged (PR #${gate_merged_pr}) but the issue is still open — dispatch was skipped to avoid duplicate work." \
        --what-to-fix "Verify PR #${gate_merged_pr} delivered this issue; if so close the issue and move the board card to Done. Otherwise open a fresh branch. Then remove needs-human-review." || true
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Task 4 — Tier 2: in-flight workflow-state check (both orphan+non-orphan; best-effort).
    local gate_inflight=""
    gate_inflight="$(in_flight_issues 2>/dev/null | grep -x "$issue" || true)"
    if [[ -n "$gate_inflight" ]]; then
      echo "loop: gate — #${issue} has a non-done workflow-state (in-flight); skip dispatch" >&2
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Degraded gate path (D6, #357): orphan proceeds after tiers 1+2; skip tiers 3/4 (no created-issues.json context).
    if [[ "$gate_is_orphan" -eq 1 ]]; then
      local gate_issue_url="https://github.com/${repo}/issues/${issue}"
      echo "loop: gate — orphan: ${gate_issue_url} — D6 tiers 1-2 enforced, board/label drift not checked" >&2
      _increment_orphan_dispatches
    fi
  fi
  # End dispatch gate.

  # Synchronous board CAS (#259) — cross-worktree lock; lost CAS = clean skip, not an error.
  if ! _claim_board_card "$issue"; then
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Tier 3/4 — label-vs-board conflict gate (#356); skipped for orphans (D6) and empty gate_labels_json.
  if [[ "$GATE_DISABLE" != "1" && -n "$gate_labels_json" && "$gate_is_orphan" -eq 0 ]]; then
    local claimed_status="${MAKATO_LOOP_ITEM_STATUS:-${MAKATO_LOOP_DISPATCH_STATUS:-Ready}}"
    # Use the CAS-observed status exported by _claim_board_card when available.
    [[ -n "${LOOP_LAST_CLAIMED_STATUS:-}" ]] && claimed_status="$LOOP_LAST_CLAIMED_STATUS"
    if _label_board_conflict "$gate_labels_json" "$claimed_status"; then
      echo "loop: gate — #${issue} label-board conflict (labels vs board '${claimed_status}'); skip dispatch + stamp needs-human-review" >&2
      _label_conflict_stamp "$issue"
      _increment_gate_skips
      echo "loop: gate-skip #${issue} reason=label-board-conflict gate_skips_total=$(_read_status | jq -r '.gate_skips_total // 0')" >&2
      _patch_status '.active_workflow' 'null'
      return 0
    fi
  fi

  # Assign issue → fires issues.assigned → board sync Ready→In progress (#33). Belt-and-braces after CAS claim (#259).
  _assign_issue "$issue"

  # Test hook — exercise state-machine without forking a subprocess (DRY_DISPATCH=1).
  if [[ "${MAKATO_LOOP_DRY_DISPATCH:-0}" == "1" ]]; then
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Test hook — spawn hung subprocess for watchdog tests (T12–T14); value is command to exec.
  local child_cmd=""
  if [[ -n "${MAKATO_LOOP_STALL_TEST_CMD:-}" ]]; then
    child_cmd="${MAKATO_LOOP_STALL_TEST_CMD}"
  fi

  local rc=0
  # Prepare log + watchdog unless MAKATO_LOOP_STALL_DISABLE=1 (#164).
  local log_file="" watchdog_pid=""
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" != "1" ]]; then
    log_file="$STATE_DIR/dispatch-${issue}.log"
    : >"$log_file"
  fi
  # Single-threaded: blocks until PO-agent exits. Delegates to po-agent via Task tool (#160/#163):
  # MAKATO_HEADLESS=1 guards against interactive-mode fallback (MISSING_INPUT instead of deadlock).

  # Export MAKATO_ORCHESTRATE_SHARED so child sessions can locate shared scripts without relying on CWD.
  MAKATO_ORCHESTRATE_SHARED="$(git rev-parse --show-toplevel)/plugins/makato-orchestrate/shared"
  if [[ -d "$MAKATO_ORCHESTRATE_SHARED" ]]; then
    export MAKATO_ORCHESTRATE_SHARED
  else
    echo "[loop WARN] MAKATO_ORCHESTRATE_SHARED path not found: $MAKATO_ORCHESTRATE_SHARED" >&2
  fi

  local dispatch_prompt
  if [[ "$issue_type" == "type:change" ]]; then
    # Route to makato-change:orchestrate --autonomous; change pipeline owns its own spec-folder lifecycle.
    dispatch_prompt="Use the Skill tool to invoke the makato-change:orchestrate skill with args '${key} --autonomous'. Required env: ISSUE_NUMBER=${issue} ISSUE_KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. The skill owns the analyze→design→execute→resolve-review loop and writes change-state-${issue}.json + a workflow-state-${issue}.json loop-compat stub. Return R1 envelope verbatim."
  else
    dispatch_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to drive GitHub issue #${issue} to a merged PR. Pass the po-agent's required inputs verbatim: ISSUE_NUMBER=${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} BRANCH=${branch} REPO_ROOT=${REPO_ROOT}. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
  fi

  if [[ -n "$log_file" ]]; then
    # Redirect stdout+stderr to log so watchdog gets mtime updates on any output.
    if [[ -n "$child_cmd" ]]; then
      # Test path: spawn the stall stand-in directly.
      # shellcheck disable=SC2086
      $child_cmd >"$log_file" 2>&1 &
      local child_pid=$!
    else
      # Production path: omp --yolo keeps log mtime alive for watchdog (#146).
      MAKATO_HEADLESS=1 "$CLAUDE_BIN" --yolo \
        -p "$dispatch_prompt" >"$log_file" 2>&1 &
      local child_pid=$!
    fi
    # Spawn watchdog against the child's PID.
    _watchdog_poll "$log_file" "$child_pid" "$issue" &
    watchdog_pid=$!
    # Signal-safe reap (#312): TERM/INT trap kills watchdog+child in-scope before exit, preventing orphaned _patch_status writer.
    trap 'kill -TERM "$watchdog_pid" "$child_pid" 2>/dev/null || true; wait "$watchdog_pid" "$child_pid" 2>/dev/null || true; exit 143' TERM INT
    # Block on child. `wait` returns the child's exit status if we name it.
    wait "$child_pid" || rc=$?
    # #616: persist session UUID to workflow-state as last_session_id for --resume recovery; best-effort.
    if [[ -n "$log_file" && -n "${key:-}" ]]; then
      local _sid
      _sid="$(_extract_session_id "$log_file")"
      if [[ -n "$_sid" ]]; then
        local _ws_capture
        _ws_capture="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/shared/workflow-state.sh"
        if [[ -x "$_ws_capture" ]]; then
          "$_ws_capture" patch "$key" "$issue" '.last_session_id' "\"$_sid\"" >/dev/null 2>&1 || true
        fi
      fi
    fi
    # Reap watchdog — no-op if already exited.
    if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
      kill -TERM "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
    fi
    # Drop signal trap after normal completion.
    trap - TERM INT
    # Stall-restart wiring (#444): watchdog kill → _stall_restart; transient returns 0, no_progress returns 1.
    if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" != "1" ]]; then
      local _killed_issue
      _killed_issue="$(_read_status | jq -r '.last_watchdog_kill.issue // empty' 2>/dev/null || true)"
      local _killed_flag
      _killed_flag="$(_read_status | jq -r '.active_workflow.killed_by_watchdog // false' 2>/dev/null || echo false)"
      # active_workflow.killed_by_watchdog cleared before we read; use last_watchdog_kill snapshot.
      local _wkill_flag
      _wkill_flag="$(_read_status | jq -r '
        if .last_watchdog_kill.issue == '"$issue"' then
          "true"
        else
          "false"
        end' 2>/dev/null || echo false)"
      if [[ "$_wkill_flag" == "true" ]]; then
        # Derive spec folder from SPECS_DIR + issue's workflow-state file.
        local _spec_dir=""
        local _wf
        _wf="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
          -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
        if [[ -n "$_wf" ]]; then
          _spec_dir="$(dirname "$_wf")"
        fi
        _stall_restart "$issue" "$_spec_dir" "$log_file" || rc=$?
      else
        # Stall-resume (#531): incomplete/errored exit without a HALT code → attempt --resume re-entry.
        local _dispatch_verdict
        _dispatch_verdict="$(_parse_dispatch_result "$log_file")"
        if [[ "$_dispatch_verdict" == "incomplete" || "$_dispatch_verdict" == "errored" ]]; then
          # Skip resume when HALT code already emitted — HALT classification path owns the issue.
          local _spec_dir_r=""
          local _wf_r
          _wf_r="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
            -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
          if [[ -n "$_wf_r" ]]; then
            _spec_dir_r="$(dirname "$_wf_r")"
          fi
          local _halt_emitted="false"
          if [[ -f "${_spec_dir_r}/orchestrate.jsonl" ]]; then
            if grep -q '"step":"halt"' "${_spec_dir_r}/orchestrate.jsonl" 2>/dev/null; then
              _halt_emitted="true"
            fi
          fi
          if [[ "$_halt_emitted" != "true" ]]; then
            _stall_resume "$issue" "$key" "$_spec_dir_r" "$log_file" || rc=$?
            # #687: api_error recovery — no workflow-state = session never started → reset board to Ready.
            if [[ "$rc" -ne 0 ]]; then
              local _wf_absent="true"
              local _wf_check
              _wf_check="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
                -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
              [[ -n "$_wf_check" ]] && _wf_absent="false"
              if [[ "$_wf_absent" == "true" ]]; then
                echo "loop: api-error: #$issue exited rc=$rc with no workflow-state — resetting board to Ready" >&2
                _reset_board_card_to_ready "$issue" || true
              fi
            fi
          fi
        fi
      fi
    fi
  else
    # Opt-out path (MAKATO_LOOP_STALL_DISABLE=1) — no log/watchdog; text format OK (operator watches terminal directly).
    if [[ -n "$child_cmd" ]]; then
      # shellcheck disable=SC2086
      $child_cmd || rc=$?
    else
      MAKATO_HEADLESS=1 "$CLAUDE_BIN" --yolo \
        -p "$dispatch_prompt" || rc=$?
    fi
  fi
  _emit_langfuse_trace "$log_file" "$issue"
  _patch_status '.active_workflow' 'null'
  return $rc
}

# _acquire_run_mutex — layer-1 guard against concurrent loop.sh instances (#172); writes PID to $PIDFILE + EXIT trap.
# Refuses when pidfile holds a live PID (unless --force); stale pidfile reclaimed silently. Not atomic (flock unavailable on macOS).
_acquire_run_mutex() {
  local force="$1"
  if [[ -f "$PIDFILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$PIDFILE" 2>/dev/null || echo "")"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      if [[ -z "$force" ]]; then
        echo "loop: another instance is running (PID $existing_pid, pidfile $PIDFILE)" >&2
        echo "loop: pass --force to reclaim, or stop the incumbent (kill -TERM $existing_pid)" >&2
        return 3
      fi
      echo "loop: --force reclaiming PID $existing_pid (SIGTERM, ${FORCE_GRACE_SECS}s grace, then SIGKILL)" >&2
      kill -TERM "$existing_pid" 2>/dev/null || true
      local waited=0
      while [[ $waited -lt $FORCE_GRACE_SECS ]] && kill -0 "$existing_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$existing_pid" 2>/dev/null; then
        echo "loop: --force SIGKILL'ing PID $existing_pid (still alive after ${FORCE_GRACE_SECS}s)" >&2
        kill -KILL "$existing_pid" 2>/dev/null || true
      fi
    else
      # Stale pidfile — reclaim silently. Common after crash or kill -9.
      if [[ -n "$existing_pid" ]]; then
        echo "loop: stale pidfile (PID $existing_pid gone); reclaiming $PIDFILE" >&2
      fi
    fi
  fi
  echo "$$" >"$PIDFILE"
  # Preserve any existing EXIT trap (tests may compose) by chaining.
  trap 'rm -f "$PIDFILE"' EXIT
  return 0
}

# _stamp_startup_audit — records process identity into loop-status.json for operator disambiguation (#172).
# Args: <status-name> <interval> <dry-run-flag>
_stamp_startup_audit() {
  local status_name="$1"
  local interval="$2"
  local dry_run="$3"
  local now script_path ppid
  now="$(_now)"
  # Canonicalise $0; macOS readlink lacks -f so use python3 fallback.
  script_path="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0" 2>/dev/null || echo "$0")"
  ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ' || echo "")"
  local audit
  audit="$(jq -n \
    --arg started_at "$now" \
    --arg script_path "$script_path" \
    --argjson pid "$$" \
    --arg ppid "$ppid" \
    --arg pidfile "$PIDFILE" \
    --arg status_name "$status_name" \
    --argjson interval "$interval" \
    --arg dry_run "$dry_run" \
    '{
       started_at: $started_at,
       script_path: $script_path,
       pid: $pid,
       ppid: (if $ppid == "" then null else ($ppid|tonumber) end),
       pidfile: $pidfile,
       status_name: $status_name,
       interval_seconds: $interval,
       dry_run: ($dry_run != "")
     }')"
  _patch_status '.startup_audit' "$audit"
}

# _reshape_pass — pre-poll reshape pass (#350, epic #319). Dispatches decompose+to-issues for
# "Needs Planning" board items; fires HALT-013 at ceiling; feature-flagged via MAKATO_LOOP_RESHAPE_ENABLED.
_reshape_pass() {
  # Guard 1: feature flag.
  if [[ "${MAKATO_LOOP_RESHAPE_ENABLED:-0}" != "1" ]]; then
    return 0
  fi

  echo "loop: reshape-pass — starting (#350)" >&2

  # Guard 2: kill-switch.
  if ! cmd_check_halt; then
    echo "loop: reshape-pass — HALT file present, skipping pass" >&2
    return 0
  fi

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  local max_cycles="${MAKATO_MAX_RESHAPE_CYCLES:-2}"

  # Guard 3: discover Needs Planning candidates (override hook or board poll; fallback: label).
  local candidates='[]'

  if [[ -n "${MAKATO_LOOP_RESHAPE_OVERRIDE:-}" ]]; then
    candidates="$(cat "${MAKATO_LOOP_RESHAPE_OVERRIDE}" 2>/dev/null || echo '[]')"
  else
    # Primary: board Status = Needs Planning using config-resolved option id.
    local needs_planning_option_id=""
    if [[ -f "$CONFIG_FILE" ]]; then
      needs_planning_option_id="$(jq -r '
        (.github_project.fields.status.options.needs_planning // empty),
        (.github_project.options.needs_planning // empty)
        | select(. != null and . != "null" and . != "")
        | .' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"
    fi

    if [[ -n "$needs_planning_option_id" ]]; then
      local board_items
      board_items="$(_gh_project_item_list 2>/dev/null || echo '{"items":[]}')"
      candidates="$(jq -r --arg opt_id "$needs_planning_option_id" \
        '[.items[] | select(.content.type == "Issue") |
          select(.status_option_id == $opt_id or .status == "Needs Planning") |
          {number: .content.number, key: ""}]' \
        <<<"$board_items" 2>/dev/null || echo '[]')"
    fi

    # Fallback: label-based discovery when board yields nothing.
    if [[ "$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)" -eq 0 ]]; then
      local label_issues
      label_issues="$(gh issue list "${repo_flag[@]}" \
        --label "needs-reshape" --state open \
        --json number --limit 200 2>/dev/null || echo '[]')"
      candidates="$(jq '[.[] | {number: .number, key: ""}]' <<<"$label_issues" 2>/dev/null || echo '[]')"
    fi
  fi

  local count
  count="$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)"
  echo "loop: reshape-pass — $count candidate(s) to process" >&2

  local n key
  while IFS=$'\t' read -r n key; do
    [[ -n "$n" ]] || continue
    echo "loop: reshape-pass — processing issue #$n" >&2

    # Derive spec KEY if not provided by the fixture.
    if [[ -z "$key" || "$key" == "null" ]]; then
      key="$(_derive_key_for_issue "$n" "$repo" 2>/dev/null || true)"
    fi
    if [[ -z "$key" ]]; then
      echo "loop: WARN — reshape-pass #$n: cannot derive KEY; skipping" >&2
      continue
    fi

    # Read reshape_cycles from workflow-state directly (SPECS_DIR override for tests).
    local state_file=""
    local spec_folder
    spec_folder="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1)"
    [[ -z "$spec_folder" ]] && [[ -d "$SPECS_DIR/$key" ]] && spec_folder="$SPECS_DIR/$key"
    [[ -z "$spec_folder" ]] && spec_folder="$SPECS_DIR/$key"
    state_file="$spec_folder/workflow-state-${n}.json"
    local wf_json reshape_cycles
    wf_json="$([[ -f "$state_file" ]] && cat "$state_file" 2>/dev/null || echo '{}')"
    reshape_cycles="$(jq -r '.reshape_cycles // 0' <<<"$wf_json" 2>/dev/null || echo 0)"

    # Ceiling check — HALT-013: reshape oscillation guard (#351, epic #319).
    # Fires when reshape_cycles >= max_cycles: apply needs-human-review, append halt_audit, log JSONL.
    if [[ "$reshape_cycles" -ge "$max_cycles" ]]; then
      echo "loop: reshape-pass — #$n HALT-013: reshape ceiling reached (reshape_cycles=${reshape_cycles} >= max=${max_cycles}); applying needs-human-review" >&2

      # Step 1: apply needs-human-review label.
      _apply_needs_human_review_reshape "$n" "${repo_flag[@]}"

      # Step 2: append halt_audit directly to state file (SPECS_DIR path, for test compat).
      local halt_data halt_ts
      halt_ts="$(_now)"
      halt_data="$(jq -cn \
        --argjson cycles "$reshape_cycles" \
        --argjson max "$max_cycles" \
        '{reshape_cycles: $cycles, max_reshape_cycles: $max, retryable: false, origin: "human"}')"
      if [[ -f "$state_file" ]]; then
        local patched_halt
        patched_halt="$(jq \
          --arg code "HALT-013" \
          --arg ts "$halt_ts" \
          --argjson data "$halt_data" \
          '.halt_audit += [{"code": $code, "ts": $ts, "data": $data}] | .updated_at = $ts' \
          "$state_file" 2>/dev/null || true)"
        [[ -n "$patched_halt" ]] && printf '%s\n' "$patched_halt" >"$state_file" 2>/dev/null || true
      fi

      # Step 3: write step:"halt" orchestrate.jsonl line.
      local spec_folder_halt=""
      spec_folder_halt="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1 || true)"
      [[ -z "$spec_folder_halt" && -d "$SPECS_DIR/$key" ]] && spec_folder_halt="$SPECS_DIR/$key"
      [[ -z "$spec_folder_halt" ]] && spec_folder_halt="$SPECS_DIR/$key"
      mkdir -p "$spec_folder_halt" 2>/dev/null || true
      printf '%s\n' "$(jq -cn \
        --arg ts "$halt_ts" \
        --argjson issue "$n" \
        --argjson data "$halt_data" \
        '{"ts": $ts, "skill": "loop", "issue": $issue, "step": "halt", "status": "error", "data": ($data + {"halt_code": "HALT-013"})}')" \
        >> "$spec_folder_halt/orchestrate.jsonl" 2>/dev/null || true


      _log_reshape_result "$key" "$n" "error" "$reshape_cycles" "cycle-ceiling"
      continue
    fi

    # Dispatch: decompose Refine + to-issues.
    local dispatch_rc=0
    local reshape_request_path="$SPECS_DIR/$key/reshape-request.json"

    if [[ -n "${MAKATO_LOOP_RESHAPE_TEST_CMD:-}" ]]; then
      # Test hook: subshell prevents `exit N` from escaping to caller.
      ( eval "${MAKATO_LOOP_RESHAPE_TEST_CMD}" ) >/dev/null 2>&1 || dispatch_rc=$?
    else
      # Production path: dispatch Claude headlessly — Step 1: decompose in Refine mode.
      local decompose_prompt
      decompose_prompt="Use the Skill tool to invoke makato-plan:decompose for issue #${n} in Refine mode. ISSUE_NUMBER=${n} KEY=${key} REPO=${repo} REPO_ROOT=${REPO_ROOT} RESHAPE_REQUEST=${reshape_request_path}. --autonomous. Return R1 envelope verbatim."
      REPO_ROOT="$REPO_ROOT" \
      MAKATO_HEADLESS=1 \
        "$CLAUDE_BIN" --yolo -p "$decompose_prompt" \
        >/dev/null 2>&1 || dispatch_rc=$?

      # Step 2: to-issues (only when decompose succeeded).
      if [[ "$dispatch_rc" -eq 0 ]]; then
        local to_issues_prompt
        to_issues_prompt="Use the Skill tool to invoke makato-plan:to-issues for issue #${n}. ISSUE_NUMBER=${n} KEY=${key} REPO=${repo} REPO_ROOT=${REPO_ROOT}. --autonomous. Return R1 envelope verbatim."
        REPO_ROOT="$REPO_ROOT" \
        MAKATO_HEADLESS=1 \
          "$CLAUDE_BIN" --yolo -p "$to_issues_prompt" \
          >/dev/null 2>&1 || dispatch_rc=$?
      fi
    fi

    if [[ "$dispatch_rc" -ne 0 ]]; then
      echo "loop: reshape-pass — #$n dispatch failed (rc=${dispatch_rc}); applying needs-human-review" >&2
      _apply_needs_human_review_reshape "$n" "${repo_flag[@]}"
      _log_reshape_result "$key" "$n" "error" "$reshape_cycles" "dispatch-failed"
      continue
    fi

    # Success: increment reshape_cycles, remove needs-reshape label, set Status=Ready.
    local new_cycles=$(( reshape_cycles + 1 ))
    # Patch reshape_cycles directly in state file (SPECS_DIR path, for test compat).
    if [[ -f "$state_file" ]]; then
      local patched_json
      patched_json="$(jq --argjson c "$new_cycles" '.reshape_cycles = $c' "$state_file" 2>/dev/null || true)"
      if [[ -n "$patched_json" ]]; then
        printf '%s\n' "$patched_json" >"$state_file" 2>/dev/null || true
      fi
    fi

    # Remove needs-reshape label.
    if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
      echo "remove-label #${n} needs-reshape" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    else
      gh issue edit "$n" "${repo_flag[@]}" --remove-label "needs-reshape" >/dev/null 2>&1 || true
    fi

    # Set board Status=Ready.
    local ready_option_id=""
    if [[ -f "$CONFIG_FILE" ]]; then
      ready_option_id="$(jq -r '.github_project.fields.status.options.ready // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$ready_option_id" ]]; then
      local status_field_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE" 2>/dev/null || true)"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      if [[ -n "$status_field_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        # Find the board item id.
        local item_id=""
        # Cheap single-issue lookup (~1 GraphQL point) when repo known; fallback to full item-list.
        if [[ -n "$repo" ]]; then
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$n" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$n" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          GH_HOST="$host" gh project item-edit \
            --id "$item_id" \
            --project-id "$project_node_id" \
            --field-id "$status_field_id" \
            --single-select-option-id "$ready_option_id" >/dev/null 2>&1 || true
        fi
      fi
    fi

    _log_reshape_result "$key" "$n" "ok" "$new_cycles" ""
    echo "loop: reshape-pass — #$n reshaped successfully (reshape_cycles=$new_cycles), Status=Ready" >&2

  done < <(jq -r '.[] | [.number, (.key // "")] | @tsv' <<<"$candidates" 2>/dev/null || true)

  echo "loop: reshape-pass — complete" >&2
  return 0
}

# _apply_needs_human_review_reshape — applies needs-human-review on reshape failure (#446).
# Gates on halt_audit[].origin: "human"→apply, "auto"/"transient"→skip; empty→"human" (compat).
_apply_needs_human_review_reshape() {
  local issue="$1"
  shift
  local -a repo_flag=("$@")

  # Gate: effective origin — test hook > state-file > "human" default.
  local gate_origin="human"  # safe default: apply label when origin unknown

  if [[ -n "${MAKATO_LOOP_NHR_ORIGIN_OVERRIDE+x}" ]]; then
    # Test hook: use the explicitly provided origin (empty string is valid = legacy/absent).
    gate_origin="${MAKATO_LOOP_NHR_ORIGIN_OVERRIDE}"
  else
    # Production path: read origin from the latest halt_audit[] entry in workflow-state.
    local gate_key=""
    gate_key="$(_derive_key_for_issue "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
    if [[ -n "$gate_key" ]]; then
      local gate_spec_folder=""
      gate_spec_folder="$(find "${SPECS_DIR:-specs}" -maxdepth 1 -type d -name "${gate_key}-*" 2>/dev/null | head -1 || true)"
      [[ -z "$gate_spec_folder" && -d "${SPECS_DIR:-specs}/$gate_key" ]] && gate_spec_folder="${SPECS_DIR:-specs}/$gate_key"
      if [[ -n "$gate_spec_folder" ]]; then
        local gate_state_file="$gate_spec_folder/workflow-state-${issue}.json"
        if [[ -f "$gate_state_file" ]]; then
          local latest_origin
          latest_origin="$(jq -r '.halt_audit[-1].data.origin // ""' "$gate_state_file" 2>/dev/null || echo "")"
          # Treat null/empty as "human" (backward compat for legacy entries without the field).
          [[ -z "$latest_origin" || "$latest_origin" == "null" ]] && latest_origin="human"
          gate_origin="$latest_origin"
        fi
      fi
    fi
  fi

  # Treat empty origin (no field in legacy entry) as "human" for backward compat.
  [[ -z "$gate_origin" ]] && gate_origin="human"

  # Only apply needs-human-review for human-origin HALTs.
  if [[ "$gate_origin" != "human" ]]; then
    echo "loop: reshape-pass — #${issue} skipping needs-human-review (origin=${gate_origin}; non-human HALTs do not require operator action)" >&2
    return 0
  fi

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-013" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    return 0
  fi

  if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
    gh label create "needs-human-review" "${repo_flag[@]}" \
      --color "E4E669" --description "Requires human review" >/dev/null 2>&1 || true
  fi
  gh issue edit "$issue" "${repo_flag[@]}" --add-label "needs-human-review" >/dev/null 2>&1 || true
  _post_halt_comment "HALT-013" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
}

# _log_reshape_result <KEY> <ISSUE_NUMBER> <status:ok|error> <reshape_cycles> <error_reason>
# Emits one JSONL entry to specs/<key>/orchestrate.jsonl.
_log_reshape_result() {
  local key="$1"
  local issue="$2"
  local status="$3"
  local cycles="$4"
  local reason="${5:-}"

  local ts
  ts="$(_now)"
  local data
  data="$(jq -cn \
    --arg key "$key" \
    --argjson issue "$issue" \
    --argjson cycles "$cycles" \
    --arg reason "$reason" \
    '{key: $key, issue: $issue, reshape_cycles_after: $cycles, error_reason: (if $reason == "" then null else $reason end)}')"

  local entry
  entry="$(jq -cn \
    --arg ts "$ts" \
    --argjson issue "$issue" \
    --arg status "$status" \
    --argjson data "$data" \
    '{"ts": $ts, "skill": "loop", "issue": $issue, "step": "reshape", "status": $status, "data": $data}')"

  # Write directly via SPECS_DIR, not build-log.sh: in a worktree, build-log.sh resolves
  # via git --git-common-dir (main checkout) and would mismatch loop's SPECS_DIR.
  local spec_folder=""
  spec_folder="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1 || true)"
  [[ -z "$spec_folder" && -d "$SPECS_DIR/$key" ]] && spec_folder="$SPECS_DIR/$key"
  [[ -z "$spec_folder" ]] && spec_folder="$SPECS_DIR/$key"
  mkdir -p "$spec_folder" 2>/dev/null || true
  printf '%s\n' "$entry" >> "$spec_folder/orchestrate.jsonl" 2>/dev/null || true
}

# _emit_run_report <issue…> — aggregates terminal issue states into a run report (#448).
# Best-effort: generation failure logs WARN and never changes cmd_run exit status.
_emit_run_report() {
  local -a issues=("$@")
  [[ "${#issues[@]}" -gt 0 ]] || return 0
  local report_script="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-run-report.sh"
  if [[ ! -x "$report_script" ]]; then
    echo "loop: WARN — run-report script not found/executable at $report_script; skipping report (#448)" >&2
    return 0
  fi
  local report_path
  # Forward SPECS_DIR/STATE_DIR so test-overridden loop and report share the same paths.
  if report_path="$(MAKATO_REPORT_SPECS_DIR="$SPECS_DIR" MAKATO_LOOP_STATE_DIR="$STATE_DIR" \
      "$report_script" --issues "${issues[*]}" 2>/dev/null)"; then
    echo "loop: run report written → $report_path (#448)" >&2
    _patch_status '.last_run_report' "\"$report_path\""
  else
    echo "loop: WARN — run-report generation failed for issues '${issues[*]}'; continuing (#448)" >&2
  fi
}

# _check_tool_deps — pre-flight check for jq, gh, git, python3 + gh auth (#587).
# Skips live auth check in offline/test mode (MAKATO_LOOP_GH_OVERRIDE et al set).
_check_tool_deps() {
  local tool
  for tool in jq gh git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "loop: pre-flight error — required tool '$tool' not found on PATH; install it and retry" >&2
      return 1
    fi
  done
  # Skip live auth check when any test-mode env var is active (offline/CI harness).
  if [[ -z "${MAKATO_LOOP_GH_OVERRIDE:-}" \
     && -z "${MAKATO_LOOP_POLL_TEST_CMD:-}" \
     && -z "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
    local _host
    _host="$(jq -r '.github_project.host // "github.com"' "${CONFIG_FILE}" 2>/dev/null || echo "github.com")"
    if ! GH_HOST="$_host" gh auth status --hostname "$_host" >/dev/null 2>&1; then
      echo "loop: pre-flight error — gh auth status failed for $_host; run 'gh auth login --hostname $_host' and retry" >&2
      return 1
    fi
  fi
  return 0
}

# _check_session_safety — pre-flight guard against running under a bg Claude session (#743).
# Walks 4 ppid levels; aborts if bg-spare/bg-pty-host/transient ancestry found (SIGTERM risk).
_check_session_safety() {
  # Opt-out: headless CI with external SIGTERM protection.
  [[ "${MAKATO_LOOP_ALLOW_BG_SESSION:-0}" == "1" ]] && return 0

  # Offline smoke-test mode: skip guard (mirrors _check_tool_deps auth skip).
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" \
     || -n "${MAKATO_LOOP_POLL_TEST_CMD:-}" \
     || -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]] \
     && [[ -z "${MAKATO_LOOP_SESSION_SAFETY_TEST_PPID:-}" ]]; then
    return 0
  fi

  local pid
  pid="${MAKATO_LOOP_SESSION_SAFETY_TEST_PPID:-$PPID}"

  local level args
  for level in 1 2 3 4; do
    [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]] || break

    # Resolve ancestor args; test seam overrides ps on level 1 only.
    if [[ -n "${MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE:-}" && "$level" == "1" ]]; then
      args="$(cat "${MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE}" 2>/dev/null || echo "")"
    else
      args="$(ps -o args= -p "$pid" 2>/dev/null || echo "")"
    fi

    # Graceful degrade: `ps` unavailable / empty output → skip the check.
    if [[ -z "$args" ]]; then
      [[ "$level" == "1" ]] && echo "loop: WARN — session-safety: could not read process ancestry (ps unavailable); skipping guard" >&2
      break
    fi

    if [[ "$args" == *"bg-spare"* \
       || "$args" == *"bg-pty-host"* \
       || "$args" == *"claude daemon run --origin transient"* ]]; then
      cat >&2 <<EOF
loop: error — launched under a background/headless Claude session (process: '${args}').
The loop will be SIGTERM'd when this session is reaped.
Fix: run from an interactive terminal or use nohup+disown:
  nohup plugins/makato-orchestrate/scripts/loop.sh run > ~/.claude/state/loop.log 2>&1 &
  disown
To suppress this guard: export MAKATO_LOOP_ALLOW_BG_SESSION=1
EOF
      return 1
    fi

    # Walk one level up (test seam only mocks level 1; real ppid from level 2).
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")"
  done

  return 0
}
