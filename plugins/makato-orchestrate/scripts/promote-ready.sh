#!/usr/bin/env bash
# scripts/promote-ready.sh — dependency-aware Ready promotion (#268).
#
# The autonomous `loop` (scripts/loop.sh) dispatches board items strictly
# FIFO and single-threaded; it does not read the cross-issue dependency
# graph (issue #33 Out of Scope: "Priority ordering … FIFO only in v1").
# No makato skill reads the dependency graph to decide which issues are
# *right now unblocked* and may move to Ready. This script closes that gap.
#
# The dependency data already exists and is machine-readable: `to-issues`
# writes it into `specs/<slug>/created-issues.json` (`issues[].blocked_by[]`,
# real issue numbers) and, as a fallback, `stories.json` carries
# `stories[].dependencies.blockedBy` (STORY SEQUENCES — translated to issue
# numbers here via `stories[].sequence → stories[].githubIssue`). Nobody
# reads it back at promotion time. This script does.
#
# Behaviour (issue #268):
#   1. Load the dependency graph from created-issues.json (fallback
#      stories.json) for one slug or every spec folder.
#   2. Read each issue's current board Status via `gh project item-list`.
#   3. Compute unblocked issues = those at Todo/Blocked (or off-board)
#      whose EVERY blocked_by predecessor is Done. Arrange topologically
#      into waves.
#   4. Print a recommendation: which issues to move to Ready for correct
#      sequencing, which stay blocked and by what.
#   5. After interactive approval (or --yes), promote the selected issues
#      to Status=Ready — idempotently, forward-only, warn-not-fail (reuses
#      the GraphQL `gh project item-edit` pattern from loop.sh
#      `_claim_board_card` / `_promote_labelled_ready`).
#   6. --dry-run prints the recommendation only; no board mutation.
#
# Parallel-safety constraints this tool MUST respect (issue #268):
#   - Shared plan.md collision: issues sharing one `specs/<KEY>-<slug>/`
#     folder share a single plan.md in the main checkout (#173 isolated
#     workflow-state-<n>.json but NOT plan.md). This tool NEVER recommends
#     promoting two issues that map to the same spec folder at once — it
#     keeps the lowest issue number per folder per wave and defers the rest.
#   - Board Status is the shared lock (#259): this tool writes the same
#     field loop reads and claims. Every write is idempotent and forward-only
#     — it promotes ONLY from {Todo, Blocked, off-board}, never rolling a
#     card back from Ready / In progress / In review / Done. So it never
#     races issue-to-project sync-lifecycle or the loop claim.
#   - The loop is FIFO single-threaded per worktree — promoting more issues
#     only lengthens the queue (safe); wave-by-wave promotion (promote the
#     next wave after the previous one merges) is the correct operating model.
#
# Config contract: reads `.claude/config.json` → github_project (owner,
# number, host, project_node_id, fields.status.{id,options.{ready,done,…}}).
# No hardcoded IDs. `GH_HOST=<host>` prefix (never `--hostname`) on every
# `gh project` subcommand — `gh project` has no host flag.
#
# Environment / test hooks:
#   MAKATO_PROMOTE_CONFIG        Override .claude/config.json path (tests).
#   MAKATO_PROMOTE_SPECS_DIR     Override the specs/ directory (tests).
#   MAKATO_PROMOTE_GH_OVERRIDE   Tests only: path to a JSON file holding the
#                                canned `gh project item-list --format json`
#                                payload, read instead of invoking `gh`.
#                                Mirrors MAKATO_LOOP_GH_OVERRIDE in loop.sh.
#   MAKATO_PROMOTE_DRYRUN=1       Same as --dry-run (no board mutation).
#   MAKATO_PROMOTE_YES=1          Same as --yes (skip the interactive prompt;
#                                required for the offline live-promote test).
#   MAKATO_PROMOTE_EDIT_TEST_FILE Tests only: append each intended promotion
#                                (`promote #<n> <slug> item=<id>`) to this
#                                file instead of calling `gh project
#                                item-edit`. Keeps the live-promote test
#                                offline.
#   MAKATO_MIN_VCR               Minimum Verified-to-Completed Rate gate.
#                                Unset or empty: no gate, promote as today.
#                                Set (e.g. 0.5): read .vcr.rate from
#                                $REPO_ROOT/.claude/state/loop-status.json.
#                                If absent or vcr missing, treat rate as 0.0.
#                                If rate < MAKATO_MIN_VCR, skip all
#                                promotions and exit 0. Does NOT apply to
#                                --dry-run.
#
# Conventions: matches scripts/loop.sh (POSIX-ish bash, `set -euo pipefail`,
# python3 for the graph/wave computation, jq for JSON extraction).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPECS_DIR="${MAKATO_PROMOTE_SPECS_DIR:-$REPO_ROOT/specs}"
CONFIG_FILE="${MAKATO_PROMOTE_CONFIG:-$REPO_ROOT/.claude/config.json}"

# ---------------------------------------------------------------------------
# _log <msg…> — stderr diagnostic (stdout is reserved for the recommendation
# report so it can be piped/grepped).
# ---------------------------------------------------------------------------
_log() { echo "promote-ready: $*" >&2; }

# ---------------------------------------------------------------------------
# _read_board_json — the raw `gh project item-list --format json` payload,
# or the injected offline fixture. Prints `{"items":[]}` on any failure so
# the caller degrades to an empty board (every issue treated off-board /
# not-Done) rather than crashing.
# ---------------------------------------------------------------------------
_read_board_json() {
  if [[ -n "${MAKATO_PROMOTE_GH_OVERRIDE:-}" ]]; then
    cat "$MAKATO_PROMOTE_GH_OVERRIDE" 2>/dev/null || echo '{"items":[]}'
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    _log "WARN — .claude/config.json not found at $CONFIG_FILE; treating board as empty"
    echo '{"items":[]}'
    return 0
  fi
  local host owner number
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  if [[ -z "$owner" || -z "$number" ]]; then
    _log "WARN — github_project.owner/number missing in $CONFIG_FILE; treating board as empty"
    echo '{"items":[]}'
    return 0
  fi
  # Use _board_via_graphql (~1 pt/page) when project_node_id is cached (#683).
  # Falls back to item-list (~1 pt/item) in degraded mode (pid absent or
  # _board_via_graphql not available — standalone invocation without loop.sh sourced).
  local _pid=""
  _pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
  if [[ -n "$_pid" ]] && declare -f _board_via_graphql >/dev/null 2>&1; then
    _board_via_graphql "$host" "$_pid" 2>/dev/null \
      || { _log "WARN — board poll failed (graphql); treating board as empty"; echo '{"items":[]}'; }
  else
    GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
      --format json --limit 9999 2>/dev/null \
      || { _log "WARN — board poll failed (item-list); treating board as empty"; echo '{"items":[]}'; }
  fi
}

# ---------------------------------------------------------------------------
# _collect_graph_files [SLUG] — print, one per line, the graph source files
# to feed the planner. When SLUG is given, only that folder; otherwise every
# specs/*/ folder. Prefers created-issues.json; falls back to stories.json.
# ---------------------------------------------------------------------------
_collect_graph_files() {
  local slug="${1:-}"
  local dir found=0
  local -a dirs=()
  if [[ -n "$slug" ]]; then
    # Accept an exact folder name or a slug suffix (KEY-slug or bare slug).
    if [[ -d "$SPECS_DIR/$slug" ]]; then
      dirs=("$SPECS_DIR/$slug")
    else
      while IFS= read -r dir; do dirs+=("$dir"); done < <(
        find "$SPECS_DIR" -maxdepth 1 -type d -name "*$slug" 2>/dev/null | sort)
    fi
  else
    while IFS= read -r dir; do dirs+=("$dir"); done < <(
      find "$SPECS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
  fi
  # Iterate only when non-empty: bash 3.2 (macOS /bin/bash) errors on
  # `"${dirs[@]}"` when `dirs` is an empty array under `set -u` ("unbound
  # variable"). Guard with the element-count check (same idiom loop.sh uses).
  if [[ "${#dirs[@]}" -gt 0 ]]; then
    for dir in "${dirs[@]}"; do
      if [[ -f "$dir/created-issues.json" ]]; then
        echo "$dir/created-issues.json"
        found=1
      elif [[ -f "$dir/stories.json" ]]; then
        echo "$dir/stories.json"
        found=1
      fi
    done
  fi
  [[ "$found" -eq 1 ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _compute_plan <board_json> <graph_file…> — the dependency/wave engine.
#
# Bash 3.2 (macOS /bin/bash) has no associative arrays; python3 is already a
# hard dependency (see loop.sh `_now`). The planner reads the board Status
# map plus every graph file and emits a single decision JSON on stdout:
#
#   {
#     "graphs":   [{slug, folder, issue_count}],
#     "waves":    [[{issue, slug, folder, status, title, blocked_by,
#                    pending_blockers}]],     # topological, level 0 first
#     "ready":    [{issue, slug, folder, title, url, item_id}],  # promote now,
#                                                 # after collision guard
#     "deferred_collision": [{issue, slug, folder, collides_with}],
#     "blocked":  [{issue, slug, pending_blockers}],
#     "skipped":  [{issue, slug, status}],      # already Ready/InProgress/…
#     "warnings": ["…"]
#   }
#
# "Ready to promote now" = issue whose board status ∈ {todo, blocked, ""}
# (off-board) AND EVERY blocked_by predecessor is Done. Forward-only: issues
# already at ready/in progress/in review/done are never re-promoted (skipped).
# Collision guard: among ready candidates sharing a folder, keep the lowest
# issue number, defer the rest.
# ---------------------------------------------------------------------------
_compute_plan() {
  local board_json="$1"; shift
  BOARD_JSON="$board_json" python3 - "$@" <<'PY'
import json, os, sys, re

board_raw = os.environ.get("BOARD_JSON", '{"items":[]}')

# --- board status + item id maps -----------------------------------------
status_of = {}   # issue_number -> normalized lowercase status ("" if none)
item_of = {}     # issue_number -> project item id (for item-edit)
try:
    board = json.loads(board_raw)
    for it in board.get("items", []):
        c = it.get("content", {}) or {}
        if c.get("type") != "Issue":
            continue
        n = c.get("number")
        if not isinstance(n, int):
            continue
        status_of[n] = (it.get("status") or "").strip().lower()
        if it.get("id"):
            item_of[n] = it["id"]
except Exception as e:
    print(json.dumps({"graphs": [], "waves": [], "ready": [],
                      "deferred_collision": [], "blocked": [], "skipped": [],
                      "warnings": ["board JSON parse failed: %s" % e]}))
    sys.exit(0)

DONE = "done"
# Statuses that mean "already progressing or finished" — never re-promote.
FORWARD_SKIP = {"ready", "in progress", "in review", "done"}
# Statuses eligible to be promoted TO Ready.
PROMOTABLE = {"todo", "blocked", ""}

warnings = []
graphs = []          # metadata per source file
# node -> {issue, slug, folder, title, url, blocked_by:set}
nodes = {}
folder_of = {}

def load_created(data, path):
    slug = data.get("slug") or os.path.basename(os.path.dirname(path))
    folder = os.path.basename(os.path.dirname(path))
    issues = data.get("issues", []) or []
    count = 0
    for e in issues:
        n = e.get("issue_number")
        if not isinstance(n, int):
            continue
        bb = [b for b in (e.get("blocked_by") or []) if isinstance(b, int)]
        nodes[n] = {"issue": n, "slug": slug, "folder": folder,
                    "title": e.get("title", ""), "url": e.get("url", ""),
                    "blocked_by": set(bb), "unresolved": []}
        folder_of[n] = folder
        count += 1
    # Return the count of entries actually parsed into nodes, NOT len(issues):
    # entries with a non-int issue_number are skipped above and must not inflate
    # the reported graph size.
    return slug, folder, count

def load_stories(data, path):
    # stories.json: dependencies.blockedBy holds STORY SEQUENCES, not issue
    # numbers. Translate via sequence -> githubIssue. Stories without a
    # githubIssue have no real issue yet — recorded as a warning, skipped.
    slug = data.get("slug") or os.path.basename(os.path.dirname(path))
    folder = os.path.basename(os.path.dirname(path))
    stories = data.get("stories", []) or []
    seq_to_issue = {}
    for s in stories:
        seq = s.get("sequence")
        gh = s.get("githubIssue")
        if isinstance(seq, int) and isinstance(gh, int):
            seq_to_issue[seq] = gh
    count = 0
    for s in stories:
        gh = s.get("githubIssue")
        if not isinstance(gh, int):
            warnings.append("stories.json %s: story seq %s has no githubIssue; skipped"
                            % (slug, s.get("sequence")))
            continue
        deps = (s.get("dependencies") or {}).get("blockedBy", []) or []
        bb = set()
        unresolved = []
        for d in deps:
            if isinstance(d, int) and d in seq_to_issue:
                bb.add(seq_to_issue[d])
            else:
                # A blockedBy sequence with no corresponding githubIssue (the
                # upstream story is not yet filed) must NOT be silently dropped:
                # dropping it would leave this issue with an empty blocked_by,
                # so pending_blockers returns [] and the issue is wrongly deem
                # unblocked and promoted. Record it as an UNRESOLVED blocker so
                # pending_blockers keeps the dependent issue blocked (the
                # conservative contract: unknown predecessors still block).
                unresolved.append("seq %s (unfiled)" % d)
                warnings.append("stories.json %s: blockedBy seq %s unresolved (no githubIssue) — issue #%s kept blocked"
                                % (slug, d, gh))
        nodes[gh] = {"issue": gh, "slug": slug, "folder": folder,
                     "title": s.get("summary", ""), "url": "",
                     "blocked_by": bb, "unresolved": unresolved}
        folder_of[gh] = folder
        count += 1
    return slug, folder, count

for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as e:
        warnings.append("could not read %s: %s" % (path, e))
        continue
    if os.path.basename(path) == "created-issues.json" or "issues" in data:
        slug, folder, n = load_created(data, path)
    else:
        slug, folder, n = load_stories(data, path)
    graphs.append({"slug": slug, "folder": folder, "issue_count": n})

def is_done(pred):
    # A predecessor counts as Done only if the board says so. Off-board or
    # unknown predecessors are conservatively NOT done (they still block).
    return status_of.get(pred, "") == DONE

def pending_blockers(node):
    # Display-ready strings. Resolved blockers not yet Done get a "#N" form;
    # unresolved (unfiled upstream) entries keep their descriptive text. Both
    # keep this node blocked (conservative contract).
    pend = ["#%s" % b for b in sorted(node["blocked_by"]) if not is_done(b)]
    pend.extend(node.get("unresolved", []))
    return pend

# --- topological waves (level = longest blocked_by chain within graph) -----
# level[n] is memoized. A node is marked in-progress via `in_stack` (a shared
# set) while its DFS is live; re-entering it is a cycle. On a cycle we assign
# level 0 to the re-entry node AND memoize it immediately so the unwinding
# parent frames read that memoized 0 (via the `if n in level` guard) instead of
# recomputing an inflated level from the cyclic path.
level = {}
def compute_level(n, in_stack):
    if n in level:
        return level[n]
    if n in in_stack:
        warnings.append("dependency cycle detected at #%s; breaking (wave 0)" % n)
        level[n] = 0
        return 0
    in_stack.add(n)
    preds = [b for b in nodes[n]["blocked_by"] if b in nodes]
    lv = 0 if not preds else 1 + max(compute_level(p, in_stack) for p in preds)
    in_stack.discard(n)
    # Only memoize if a cycle re-entry did not already pin this node to 0.
    # Without this guard the parent frame of a cyclic node would overwrite the
    # cycle sentinel with an inflated level derived from the cycle path.
    if n not in level:
        level[n] = lv
    return level[n]

# Share ONE in-progress set across all roots so cycle sentinels memoized during
# one root's DFS are honored by later roots (a fresh set per root re-derived
# inflated levels for cycle members — see #268 verification).
_in_stack = set()
for n in nodes:
    compute_level(n, _in_stack)

# waves is empty when there are no nodes (so the report's "no issues in graph"
# branch, keyed on `.waves | length == 0`, is reachable); otherwise one bucket
# per level 0..max_level.
if not level:
    waves = []
else:
    max_level = max(level.values())
    waves = [[] for _ in range(max_level + 1)]
    for n in sorted(nodes):
        nd = nodes[n]
        waves[level[n]].append({
            "issue": n, "slug": nd["slug"], "folder": nd["folder"],
            "status": status_of.get(n, ""), "title": nd["title"],
            "blocked_by": sorted(nd["blocked_by"]),
            "pending_blockers": pending_blockers(nd),
        })

# --- classify each node ----------------------------------------------------
ready_candidates = []   # promotable now (before collision guard)
blocked = []
skipped = []
for n in sorted(nodes):
    nd = nodes[n]
    st = status_of.get(n, "")
    if st in FORWARD_SKIP:
        skipped.append({"issue": n, "slug": nd["slug"], "status": st})
        continue
    if st not in PROMOTABLE:
        # Unknown board status name — be conservative, skip with a warning.
        warnings.append("issue #%s has unrecognized board status %r; skipping" % (n, st))
        skipped.append({"issue": n, "slug": nd["slug"], "status": st})
        continue
    pend = pending_blockers(nd)
    if pend:
        blocked.append({"issue": n, "slug": nd["slug"], "pending_blockers": pend})
    else:
        ready_candidates.append(nd)

# --- collision guard: max one promotion per spec folder --------------------
ready = []
deferred = []
seen_folder = {}
for nd in sorted(ready_candidates, key=lambda x: x["issue"]):
    f = nd["folder"]
    if f in seen_folder:
        deferred.append({"issue": nd["issue"], "slug": nd["slug"],
                         "folder": f, "collides_with": seen_folder[f]})
        continue
    seen_folder[f] = nd["issue"]
    ready.append({"issue": nd["issue"], "slug": nd["slug"], "folder": f,
                  "title": nd["title"], "url": nd["url"],
                  "item_id": item_of.get(nd["issue"], "")})

print(json.dumps({
    "graphs": graphs, "waves": waves, "ready": ready,
    "deferred_collision": deferred, "blocked": blocked,
    "skipped": skipped, "warnings": warnings,
}))
PY
}

# ---------------------------------------------------------------------------
# _render_report <plan_json> — human-facing recommendation to stdout.
# ---------------------------------------------------------------------------
_render_report() {
  local plan="$1"
  echo "=== Dependency-aware Ready promotion (#268) ==="
  echo
  # Graph sources
  local ng
  ng="$(jq '.graphs | length' <<<"$plan")"
  echo "Dependency graphs loaded: $ng"
  jq -r '.graphs[] | "  • \(.slug) — \(.issue_count) issue(s) [\(.folder)]"' <<<"$plan"
  echo

  # Topological waves
  echo "Topological waves (level 0 = no blockers within graph):"
  local nw
  nw="$(jq '.waves | length' <<<"$plan")"
  if [[ "$nw" -eq 0 ]]; then
    echo "  (no issues in graph)"
  else
    jq -r '
      .waves | to_entries[] |
      "  Wave \(.key):" ,
      ( .value[] |
        "    #\(.issue) [\(if .status == "" then "off-board" else .status end)] \(.title)"
        + (if (.pending_blockers|length) > 0
           then "  ⟶ waiting on " + (.pending_blockers | join(", "))
           else "" end) )
    ' <<<"$plan"
  fi
  echo

  # Recommendation
  echo "→ Recommended to promote to Ready now:"
  if [[ "$(jq '.ready | length' <<<"$plan")" -eq 0 ]]; then
    echo "    (none — nothing is unblocked, or all unblocked issues already progressing)"
  else
    jq -r '.ready[] | "    #\(.issue) — \(.title)  [\(.slug)]"' <<<"$plan"
  fi
  echo

  # Deferred by plan.md collision
  if [[ "$(jq '.deferred_collision | length' <<<"$plan")" -gt 0 ]]; then
    echo "⏸  Deferred (plan.md collision — same specs/ folder, promote after the sibling merges):"
    jq -r '.deferred_collision[] | "    #\(.issue) [\(.slug)] — collides with #\(.collides_with) in the same folder"' <<<"$plan"
    echo
  fi

  # Still blocked
  if [[ "$(jq '.blocked | length' <<<"$plan")" -gt 0 ]]; then
    echo "✗  Still blocked (upstream not Done):"
    jq -r '.blocked[] | "    #\(.issue) — waiting on " + (.pending_blockers | join(", "))' <<<"$plan"
    echo
  fi

  # Skipped (already progressing)
  if [[ "$(jq '.skipped | length' <<<"$plan")" -gt 0 ]]; then
    echo "•  Already progressing (forward-only — not re-promoted):"
    jq -r '.skipped[] | "    #\(.issue) [\(if .status == "" then "?" else .status end)]"' <<<"$plan"
    echo
  fi

  # Warnings
  if [[ "$(jq '.warnings | length' <<<"$plan")" -gt 0 ]]; then
    echo "⚠  Warnings:"
    jq -r '.warnings[] | "    " + .' <<<"$plan"
    echo
  fi
}

# ---------------------------------------------------------------------------
# _promote_one <issue> <slug> <url> <item_id> — set one card to Status=Ready.
# Idempotent + forward-only + warn-not-fail. Resolves the board item id
# (item-add if the issue is not yet on the board), then item-edit to Ready.
# Returns 0 on success OR on a swallowed best-effort failure (never fails the
# whole pass). The test hook MAKATO_PROMOTE_EDIT_TEST_FILE records the intent
# offline instead of calling gh.
# ---------------------------------------------------------------------------
_promote_one() {
  local issue="$1" slug="$2" url="$3" item_id="$4"

  if [[ -n "${MAKATO_PROMOTE_EDIT_TEST_FILE:-}" ]]; then
    echo "promote #$issue $slug item=${item_id:-<add>}" >>"$MAKATO_PROMOTE_EDIT_TEST_FILE"
    _log "promote #$issue → Ready [$slug] (test hook)"
    return 0
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    _log "WARN — cannot promote #$issue: .claude/config.json not found"
    return 0
  fi
  local status_field_id ready_option_id project_node_id host owner number
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  ready_option_id="$(jq -r '.github_project.fields.status.options.ready // empty' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  if [[ -z "$status_field_id" || -z "$ready_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    _log "WARN — cannot promote #$issue: status field / ready option / project id missing in config"
    return 0
  fi

  # Resolve the item id: add to board when absent (mirrors _promote_labelled_ready).
  if [[ -z "$item_id" ]]; then
    # Only `item-add` with a REAL issue URL (created-issues.json carries one).
    # We deliberately do NOT synthesize a URL from owner+issue: `gh project
    # item-add` needs the full https://<host>/<owner>/<repo>/issues/<n>, and
    # the config contract (github_project) has no repo field. A synthesized
    # https://<host>/<owner>/issues/<n> is malformed and would silently fail —
    # worse, it hides the real cause. So: with a URL, add; without one, fall
    # through to the board lookup and, failing that, WARN actionably.
    if [[ -n "$url" ]]; then
      item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
        --url "$url" --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
    fi
    if [[ -z "$item_id" ]]; then
      item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
        --format json --limit 9999 2>/dev/null \
        | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
        | head -1 || true)"
    fi
  fi
  if [[ -z "$item_id" ]]; then
    if [[ -z "$url" ]]; then
      _log "WARN — promote #$issue: off-board and no issue URL (stories.json fallback carries none); add it to the board or use created-issues.json — skipping"
    else
      _log "WARN — promote #$issue: could not resolve board item; skipping"
    fi
    return 0
  fi

  # TOCTOU re-poll (forward-only under concurrency, #259). _read_board_json was
  # snapshotted once at pass start; between then and now the loop's claim (or
  # sync-lifecycle) may have moved this card off Todo/Blocked. Re-read the live
  # Status and promote ONLY if it is still promotable — otherwise we would roll
  # an In progress / In review / Ready / Done card backward to Ready and the
  # loop would re-dispatch it. A compare-and-set closes the window as far as the
  # API allows; an unreadable Status is best-effort (proceed, mirroring
  # loop.sh _claim_board_card's warn-proceed on a read failure).
  local live_status
  live_status="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
    --format json --limit 9999 2>/dev/null \
    | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .status // ""' 2>/dev/null \
    | head -1 || true)"
  # Normalize to lowercase for the comparison (board returns "In progress" etc).
  local live_lc
  live_lc="$(printf '%s' "$live_status" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$live_lc" in
    ""|todo|blocked)
      : ;;  # still promotable (off-board reads as empty) — proceed
    ready)
      _log "promote #$issue: already Status=Ready (idempotent no-op)"; return 0 ;;
    *)
      _log "promote #$issue: board moved to '$live_status' since snapshot — skipping (forward-only)"
      return 0 ;;
  esac

  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
    _log "promote #$issue → Status=Ready [$slug]"
  else
    _log "WARN — promote #$issue failed to set Ready (pass continues)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _reconcile_blocked_by_labels — safety-net pass that removes stale
# blocked-by:N labels where N is already closed. Runs after the wave-
# promotion pass. Best-effort: all gh calls are swallowed with || true.
# Skips when gh auth is unavailable (offline test runs).
# FORWARD-ONLY: only promotes issues whose current Status ∈ {Todo, Blocked,
# off-board} — never demotes an issue that has already advanced.
# ---------------------------------------------------------------------------
_reconcile_blocked_by_labels() {
  local repo_name
  repo_name="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  [[ -z "$repo_name" ]] && { _log "reconcile: gh not available — skipping"; return 0; }

  _log "reconcile: scanning for stale blocked-by:* labels…"

  # Get all open issues with at least one blocked-by:* label
  local issues_json
  issues_json="$(gh issue list \
    --repo "$repo_name" \
    --state open \
    --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | any(startswith("blocked-by:")))]' \
    2>/dev/null || echo '[]')"

  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    # Get all blocked-by:N labels for this issue
    local blockers
    blockers="$(gh issue view "$dep" --repo "$repo_name" \
      --json labels \
      --jq '[.labels[].name | select(startswith("blocked-by:")) | ltrimstr("blocked-by:")] | .[]' \
      2>/dev/null || true)"

    local blocker_num blocker_state
    for blocker_num in $blockers; do
      blocker_state="$(gh issue view "$blocker_num" --repo "$repo_name" \
        --json state --jq '.state' 2>/dev/null || echo '')"
      if [[ "$blocker_state" == "CLOSED" ]]; then
        gh issue edit "$dep" --repo "$repo_name" \
          --remove-label "blocked-by:${blocker_num}" 2>/dev/null || true
        _log "reconcile: removed stale blocked-by:${blocker_num} from #${dep}"
      fi
    done

    # Re-check: fully unblocked?
    local remaining
    remaining="$(gh issue view "$dep" --repo "$repo_name" \
      --json labels \
      --jq '[.labels[].name | select(startswith("blocked-by:"))] | length' \
      2>/dev/null || echo '1')"
    if [[ "$remaining" -eq 0 ]]; then
      # Forward-only promotion — only promote if currently at Todo/Blocked/off-board
      gh issue edit "$dep" --repo "$repo_name" \
        --remove-label "status:blocked" \
        --add-label "status:ready-for-dev" 2>/dev/null || true
      _log "reconcile: promoted #${dep} to status:ready-for-dev (all blockers closed)"
    fi
  done < <(printf '%s' "$issues_json" | jq -r '.[].number' 2>/dev/null || true)

  _log "reconcile: done"
}

# ---------------------------------------------------------------------------
# cmd_run [SLUG] [--dry-run] [--yes] — the main entry point.
# ---------------------------------------------------------------------------
cmd_run() {
  local slug="" dry="${MAKATO_PROMOTE_DRYRUN:-}" yes="${MAKATO_PROMOTE_YES:-}" json=
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --yes|-y)  yes=1 ;;
      --json)    json=1 ;;
      --*)       _log "unknown flag: $1"; return 2 ;;
      *)         slug="$1" ;;
    esac
    shift
  done

  local -a graph_files=()
  local gf
  while IFS= read -r gf; do
    [[ -n "$gf" ]] && graph_files+=("$gf")
  done < <(_collect_graph_files "$slug" || true)
  if [[ "${#graph_files[@]}" -eq 0 ]]; then
    if [[ -n "$slug" ]]; then
      _log "no created-issues.json or stories.json found for slug '$slug' under $SPECS_DIR"
    else
      _log "no created-issues.json or stories.json found under $SPECS_DIR"
    fi
    return 1
  fi

  local board_json plan
  board_json="$(_read_board_json)"
  plan="$(_compute_plan "$board_json" "${graph_files[@]}")"

  # --json: print raw _compute_plan JSON to stdout and exit; no board mutation.
  if [[ -n "$json" ]]; then
    printf '%s\n' "$plan"
    return 0
  fi

  _render_report "$plan"

  local ready_count
  ready_count="$(jq '.ready | length' <<<"$plan")"

  if [[ -n "$dry" ]]; then
    _log "--dry-run: no board mutation. $ready_count issue(s) would be promoted."
    return 0
  fi
  if [[ "$ready_count" -eq 0 ]]; then
    _log "nothing to promote."
    return 0
  fi

  # VCR gate: if MAKATO_MIN_VCR is set, read .vcr.rate from loop-status.json.
  # If rate < MAKATO_MIN_VCR, skip all promotions and exit 0.
  # MAKATO_PROMOTE_LOOP_STATUS_OVERRIDE overrides the path for offline tests.
  if [[ -n "${MAKATO_MIN_VCR:-}" ]]; then
    local _loop_status_file="${MAKATO_PROMOTE_LOOP_STATUS_OVERRIDE:-${REPO_ROOT}/.claude/state/loop-status.json}"
    local _vcr_rate
    _vcr_rate="$(jq -r '.vcr.rate // 0.0' "$_loop_status_file" 2>/dev/null || echo "0.0")"
    # python3 comparison: exits 0 when rate >= floor, exits 1 when rate < floor.
    if ! python3 -c "import sys; sys.exit(0 if float('${_vcr_rate}') >= float('${MAKATO_MIN_VCR}') else 1)" 2>/dev/null; then
      echo "promote-ready: VCR gate: rate=${_vcr_rate} < MAKATO_MIN_VCR=${MAKATO_MIN_VCR} — skipping promotion" >&2
      return 0
    fi
  fi

  # Interactive approval, unless --yes.
  if [[ -z "$yes" ]]; then
    if [[ ! -t 0 ]]; then
      _log "not a TTY and --yes not given — refusing to mutate the board. Re-run with --yes or --dry-run."
      return 0
    fi
    printf 'Promote %s issue(s) to Status=Ready? [y/N] ' "$ready_count" >&2
    local reply
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) _log "aborted by user; no board mutation."; return 0 ;;
    esac
  fi

  # Promote each — forward-only, idempotent, warn-not-fail.
  local n s u iid
  while IFS=$'\t' read -r n s u iid; do
    [[ -n "$n" ]] || continue
    _promote_one "$n" "$s" "$u" "$iid"
  done < <(jq -r '.ready[] | [(.issue|tostring), .slug, .url, .item_id] | @tsv' <<<"$plan")

  # Reconcile stale blocked-by:* labels (safety net for missed GHA events).
  _reconcile_blocked_by_labels

  _log "done — promoted up to $ready_count issue(s)."
  return 0
}

# ---------------------------------------------------------------------------
# cmd_plan [SLUG] — recommendation only (alias for `run --dry-run`).
# ---------------------------------------------------------------------------
cmd_plan() { cmd_run "$@" --dry-run; }

usage() {
  cat >&2 <<'EOF'
Usage: promote-ready.sh <command> [SLUG] [options]

Commands:
  run [SLUG] [--dry-run] [--yes] [--json]
                           Compute unblocked issues and promote them to
                           Ready (interactive approval unless --yes).
                           --json: print raw _compute_plan JSON to stdout
                                   and exit without mutating the board.
  plan [SLUG] [--json]     Recommendation only; never mutates the board
                           (alias for `run --dry-run`). Pass --json to
                           print the raw plan JSON instead of the report.

Options:
  --dry-run   Print the recommendation; make no board change.
  --yes, -y   Skip the interactive approval prompt.
  --json      Print the raw _compute_plan JSON to stdout; implies no board
              mutation. Consumers may extract .ready[].issue, .waves,
              .blocked, .skipped, .deferred_collision; exits 0.

Without SLUG, every specs/*/ folder with a created-issues.json (fallback
stories.json) is loaded. See the header of this file and skills/promote-ready
for the full contract (#268).
EOF
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$cmd" in
    run)  cmd_run "$@" ;;
    plan) cmd_plan "$@" ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] && return 0 || return 2 ;;
    *) _log "unknown command: $cmd"; usage; return 2 ;;
  esac
}

main "$@"
