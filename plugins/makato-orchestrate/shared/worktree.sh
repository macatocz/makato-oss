#!/usr/bin/env bash
# worktree.sh — git worktree lifecycle for the PO-agent and interactive builds.
#
# Implements the four mechanisms § *Worktree Lifecycle* in po-agent.md
# specifies: create, resume, cleanup-on-success, retain-on-HALT. The PO-agent
# invokes this helper at known outer-loop boundaries; the interactive build
# bootstrap invokes the same helper for developer-started sessions. Sub-agents
# inherit the resolved path via the dispatch context bundle and never run
# `git worktree` commands themselves.
#
# Subcommands (all take <KEY> AND <ISSUE_NUMBER> positional args because
# workflow-state is per-issue since #173):
#   create [--new-branch] <KEY> <ISSUE_NUMBER> <REPO> <BRANCH>
#       Create a worktree at .claude/worktrees/<sanitised-repo>-<issue> on
#       <BRANCH>. Reuses an existing worktree at the target path (resume case)
#       and prints the canonical event marker (worktree_resumed vs
#       worktree_created) on the first line of stdout; the absolute worktree
#       path on the second line. Patches workflow-state-<ISSUE>.json:.worktree_path to
#       the absolute path.
#
#       Default mode assumes <BRANCH> already exists on the remote or locally.
#       `git worktree add <path> <branch>` checks out the existing branch. If the
#       branch does not exist, `--new-branch` creates it atomically from the
#       selected base and pushes it after creation. The main repo working tree is
#       never checked out or mutated by this helper.
#
#   path <KEY> <ISSUE_NUMBER>
#       Print the .worktree_path field from workflow-state-<ISSUE>.json, or
#       empty string if unset. Stable contract for sub-agent dispatch bundles.
#
#   cleanup <KEY> <ISSUE_NUMBER>
#       Run `git worktree remove --force` on the path in workflow-state, then
#       patch .worktree_path back to null. Used on workflow `status:
#       completed`. Refuses to run when .worktree_retained is true (emits
#       worktree_cleanup_refused on stdout, exits 0 — caller decides). On a
#       genuine git-remove failure (locked worktree, NFS lock, perms),
#       emits worktree_remove_failed and LEAVES .worktree_path untouched so
#       the schema invariant `path != null ⟺ worktree on disk` holds.
#
#   retain <KEY> <ISSUE_NUMBER> <HALT_CODE>
#       Mark the worktree as deliberately retained — atomically patch BOTH
#       .worktree_retained=true and .worktree_retain_reason=<HALT_CODE> in a
#       single write so no concurrent reader observes the half-written state.
#       Does NOT run `git worktree remove`. Used on every terminal HALT code
#       so a human (or GAP-016 / #45 rebase logic) can inspect the failed run.
#
# Event log:
#   Every state transition prints one canonical event marker on the FIRST line
#   of stdout. The PO-agent reads this marker and appends the matching JSONL
#   audit entry to orchestrate.jsonl. Markers:
#     worktree_created          — fresh `git worktree add` succeeded
#     worktree_resumed          — existing worktree at target path detected and reused
#     worktree_removed          — `git worktree remove --force` succeeded
#     worktree_remove_failed    — `git worktree remove --force` refused (locked, perms);
#                                 state is NOT cleared, schema invariant preserved
#     worktree_cleanup_refused  — caller invoked cleanup but worktree_retained=true;
#                                 retained worktrees are not removed automatically
#     worktree_retained         — retain subcommand applied on HALT
#     worktree_noop             — cleanup called with no worktree_path set
#
# Environment variables:
#   MAKATO_WORKTREE_ROOT
#       Override the default .claude/worktrees/ directory (tests only).
#       Absolutised via realpath before use so a relative override does not
#       leak into the stored .worktree_path.
#
# Conventions: matches shared/workflow-state.sh — `set -euo pipefail`,
# python3 for ISO-8601 ms timestamps (delegated to workflow-state.sh patch),
# atomic state mutations via the existing helper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBCMD="${1:?subcommand required: create|path|cleanup|retain}"
shift

# --new-branch is a create-only modifier consumed at entry so the positional
# parsing below stays uniform across subcommands. See #170 rationale.
NEW_BRANCH_MODE=0
if [[ "$SUBCMD" == "create" && "${1:-}" == "--new-branch" ]]; then
  NEW_BRANCH_MODE=1
  shift
fi

KEY="${1:?key required}"
shift || true
# ISSUE_NUMBER positional #3 across all subcommands so per-issue workflow-state
# (#173) is routed correctly. `create` already had ISSUE_NUMBER as an internal
# positional; the change here promotes it from create-only to shared.
ISSUE_NUMBER="${1:?issue_number required (per-issue workflow-state, #173)}"
shift || true

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="${MAKATO_WORKFLOW_STATE_HELPER:-$SCRIPT_DIR/workflow-state.sh}"
if [[ ! -x "$WS" ]]; then
  WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
fi
WORKTREE_ROOT_RAW="${MAKATO_WORKTREE_ROOT:-$REPO_ROOT/.claude/worktrees}"

# ---------------------------------------------------------------------------
# Sanitise a repo name (owner/name → owner-name) so the path stays safely
# inside .claude/worktrees/ without nested directories. Matches the convention
# the Claude Code EnterWorktree tool uses for its own scratch worktrees.
# ---------------------------------------------------------------------------
_sanitise_repo() {
  printf '%s' "$1" | tr '/' '-'
}

# ---------------------------------------------------------------------------
# Resolve a filesystem path to its canonical form (symlinks + macOS /var ↔
# /private/var aliasing collapsed). Empty input echoes empty. Used so the
# path comparisons against `git worktree list` always match — git prints
# canonicalised paths on macOS even when the user passes /var/folders/…
# Also used to absolutise a relative MAKATO_WORKTREE_ROOT override at
# script entry so the stored .worktree_path is always absolute (C13 fix).
# ---------------------------------------------------------------------------
_realpath() {
  local raw="$1"
  [[ -z "$raw" ]] && { printf ''; return 0; }
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$raw"
}

# Make WORKTREE_ROOT absolute and canonical at entry so a relative env
# override never leaks through to the state file (C13 fix). If the dir
# does not yet exist, python's realpath still resolves the symbolic form;
# the dir is created inside the create subcommand.
mkdir -p "$WORKTREE_ROOT_RAW"
WORKTREE_ROOT="$(_realpath "$WORKTREE_ROOT_RAW")"

# ---------------------------------------------------------------------------
# JSON-encode an arbitrary shell string into a valid JSON literal that
# workflow-state.sh patch can accept (it uses jq --argjson, which requires
# the value to parse as JSON). Hardening for backslashes, double-quotes,
# newlines, and other shell metachars in WT_PATH / HALT_CODE (C2 fix).
# Returns e.g. `"foo\"bar"` for input `foo"bar`.
# ---------------------------------------------------------------------------
_json_encode() {
  jq -nc --arg v "$1" '$v'
}

# ---------------------------------------------------------------------------
# Read .worktree_path from workflow-state.json. Empty string on null/missing.
# `jq -r '... // ""'` already converts JSON null to empty string, so no
# secondary null-string guard is needed (C14 fix removed that dead code).
# ---------------------------------------------------------------------------
_state_worktree_path() {
  "$WS" read "$KEY" "$ISSUE_NUMBER" | jq -r '.worktree_path // ""'
}

# ---------------------------------------------------------------------------
# Read .worktree_retained (boolean) from workflow-state.json. Defaults to
# false on missing/null. Used by cleanup's retain-guard (C15 fix).
# ---------------------------------------------------------------------------
_state_worktree_retained() {
  "$WS" read "$KEY" "$ISSUE_NUMBER" | jq -r '.worktree_retained // false'
}

# ---------------------------------------------------------------------------
# Detect whether a path is already registered as a git worktree of this repo.
# Returns 0 (yes) or 1 (no). Compares realpath-normalised paths because git
# canonicalises symlinks on macOS (/var → /private/var) and a naive string
# match would miss the existing registration. The match runs in plain bash
# (no pipeline subshell) so `set -e` on a transient python3 _realpath
# failure does not silently turn into a false-negative answer (C3 fix).
# Parses git's porcelain output by stripping the literal `worktree ` prefix
# so paths containing whitespace survive intact (C1 fix).
# ---------------------------------------------------------------------------
_is_registered_worktree() {
  local target_raw="$1"
  [[ -z "$target_raw" ]] && return 1
  local target
  target="$(_realpath "$target_raw")"

  # Capture porcelain output into a single buffer so the path comparisons
  # run in the current shell with `set -e` semantics — a pipeline subshell
  # would mask early-exit on _realpath failure (C3).
  local porcelain
  porcelain="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"

  local line wt resolved
  while IFS= read -r line; do
    # Match `worktree <path>` lines verbatim. `<path>` may contain spaces.
    [[ "$line" == worktree\ * ]] || continue
    wt="${line#worktree }"
    resolved="$(_realpath "$wt")"
    if [[ "$resolved" == "$target" ]]; then
      return 0
    fi
  done <<<"$porcelain"

  return 1
}

case "$SUBCMD" in

  # -------------------------------------------------------------------------
#   create [--new-branch] KEY ISSUE_NUMBER REPO BRANCH
  # -------------------------------------------------------------------------
  create)
    REPO="${1:?repo required (owner/name form)}"
    BRANCH="${2:?branch required}"
    # ISSUE_NUMBER was already required at the top of the script for every
    # subcommand (per-issue workflow-state, #173); no additional positional
    # consumed here. Preserve the local for path composition below.

    SAFE_REPO="$(_sanitise_repo "$REPO")"
    WT_PATH="$WORKTREE_ROOT/${SAFE_REPO}-${ISSUE_NUMBER}"

    if _is_registered_worktree "$WT_PATH"; then
      # Resume case — reuse the existing worktree without `git worktree add`.
      # We do NOT touch its HEAD; the PO-agent's caller is responsible for
      # checking out the right branch if needed. In practice the worktree's
      # branch is already <BRANCH> from the original create call.
      # --new-branch on an already-registered path is a no-op resume, not
      # an error — resume must be idempotent regardless of the caller's
      # branch-existence knowledge.
      EVENT="worktree_resumed"
    elif (( NEW_BRANCH_MODE == 1 )); then
      # New-branch mode (#170 fix). The branch does NOT yet exist —
      # atomically create it as part of `git worktree add -b` off
      # origin/main. This keeps the main-repo working tree ON `main`;
      # no `git checkout -b` is ever executed against the main checkout.
      # After the atomic create, push the new branch with -u from INSIDE
      # the worktree so upstream tracking is established without ever
      # `cd`-ing to the main repo.
      local_stderr="$(mktemp)"

      # Refresh remote refs so `origin/main` is current. Silent on success;
      # a fetch failure is not fatal here because git worktree add will
      # surface it with a clearer diagnostic. `|| true` prevents set -e
      # from aborting the create on transient network issues that the
      # subsequent worktree add can still recover from.
      git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null || true

      # Resolve the default remote base. The bare literal `origin/main` is
      # correct for macatocz/makato but not universal (some target repos
      # use master/develop). Read HEAD off the remote to stay generic.
      REMOTE_HEAD_REF="${MAKATO_WORKTREE_BASE_REF:-$(git -C "$REPO_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo 'refs/remotes/origin/main')}"
      REMOTE_HEAD="${REMOTE_HEAD_REF#refs/remotes/}"  # e.g. origin/main or HEAD

      if ! git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT_PATH" "$REMOTE_HEAD" >/dev/null 2>"$local_stderr"; then
        {
          echo "worktree: failed to create $WT_PATH on new branch $BRANCH (base $REMOTE_HEAD)"
          echo "worktree: git stderr follows ---"
          cat "$local_stderr"
          echo "worktree: --- end git stderr"
          echo "worktree: hint — if the branch already exists locally or on the remote, drop --new-branch"
        } >&2
        rm -f "$local_stderr"
        exit 1
      fi

      # Push the new branch upstream from inside the worktree. If the push
      # fails we still keep the local worktree — a retry with `git push`
      # from inside the worktree is straightforward. Push failure is NOT
      # a state-corrupting condition and does NOT roll back the worktree
      # create.
      if ! git -C "$WT_PATH" push -u origin "$BRANCH" >/dev/null 2>"$local_stderr"; then
        {
          echo "worktree: warning — push -u origin $BRANCH failed after worktree create"
          echo "worktree: git stderr follows ---"
          cat "$local_stderr"
          echo "worktree: --- end git stderr"
          echo "worktree: worktree is on disk; retry the push from inside $WT_PATH"
        } >&2
        # Fall through — state patch below records the local worktree so
        # a caller can resume; the upstream is missing but recoverable.
      fi
      rm -f "$local_stderr"
      EVENT="worktree_created"
    else
      # Existing-branch mode. `<BRANCH>` must already exist locally or on
      # the remote — build-start creates it per po-agent.md § *Input*.
      # `git worktree add <path> <branch>` checks out an existing branch
      # (does NOT pass -b, which would attempt to create a new one and
      # conflict on resume of a half-failed earlier run). Capture git's
      # stderr to a tmp file so the failure path can echo the actual git
      # diagnostic, not a generic hint (C23 fix).
      local_stderr="$(mktemp)"
      if ! git -C "$REPO_ROOT" worktree add "$WT_PATH" "$BRANCH" >/dev/null 2>"$local_stderr"; then
        {
          echo "worktree: failed to create $WT_PATH on branch $BRANCH"
          echo "worktree: git stderr follows ---"
          cat "$local_stderr"
          echo "worktree: --- end git stderr"
          echo "worktree: hint — verify the branch exists ('git rev-parse --verify $BRANCH'); if the branch does not exist yet pass --new-branch (#170)"
        } >&2
        rm -f "$local_stderr"
        exit 1
      fi
      rm -f "$local_stderr"
      EVENT="worktree_created"
    fi

    # Patch workflow-state with the absolute path. The state file must already
    # exist (workflow-state.sh init runs before this helper per po-agent Step 2).
    # JSON-encode the path so embedded quotes/backslashes survive (C2 fix).
    # The workflow-state patch validator (#170 Fix 3) checks that the path
    # is a registered git worktree — which it verifiably is at this point.
    "$WS" patch "$KEY" "$ISSUE_NUMBER" '.worktree_path' "$(_json_encode "$WT_PATH")"

    # Record the owning loop.sh PID in the worktree (#320 — stale-crash reap).
    # The reaper reads this file to confirm the owner is still alive before
    # removing a non-landed worktree.  $PPID is the calling script's PID
    # (loop.sh or po-agent), which is the process that owns this worktree
    # for liveness purposes.  If the worktree is resumed, overwrite with the
    # current owner so a fresh run inherits ownership correctly.
    printf '%s\n' "$PPID" >"$WT_PATH/.loop-owner.pid" 2>/dev/null || true

    # Stdout contract: event on line 1, path on line 2. Callers can read both
    # via head -1 / tail -1 without parsing JSON.
    echo "$EVENT"
    echo "$WT_PATH"
    ;;

  # -------------------------------------------------------------------------
  # path <KEY>
  # -------------------------------------------------------------------------
  path)
    _state_worktree_path
    ;;

  # -------------------------------------------------------------------------
  # cleanup <KEY>
  # -------------------------------------------------------------------------
  cleanup)
    # Retain-guard (C15 fix): refuse to remove a deliberately-retained
    # worktree. The PO-agent's prose contract says cleanup runs only on the
    # success path; this is the code-level enforcement so a misordered or
    # future caller cannot silently destroy a retention artefact.
    # Single state read; extract both fields so we don't fork
    # workflow-state.sh twice for one cleanup call.
    CLEANUP_STATE="$("$WS" read "$KEY" "$ISSUE_NUMBER")"
    RETAINED="$(jq -r '.worktree_retained // false' <<<"$CLEANUP_STATE")"
    WT_PATH="$(jq -r '.worktree_path // ""' <<<"$CLEANUP_STATE")"

    if [[ "$RETAINED" == "true" ]]; then
      echo "worktree_cleanup_refused" >&1
      echo "worktree: refusing to remove retained worktree (worktree_retained=true)" >&2
      echo "worktree: clear .worktree_retained first if removal is genuinely intended" >&2
      exit 0
    fi

    if [[ -z "$WT_PATH" ]]; then
      echo "worktree_noop"
      exit 0
    fi

    # Try to remove. On failure, surface the failure as a distinct event
    # marker and LEAVE state untouched so the invariant
    # `worktree_path != null ⟺ worktree on disk` holds (C4 fix).
    if _is_registered_worktree "$WT_PATH"; then
      # --force is required because the worktree may have uncommitted files
      # the PO-agent never pushes (e.g. coder's pre-RED scratch). build-push-
      # to-git only commits the conventional-commit set; everything else is
      # safe to discard.
      if ! git -C "$REPO_ROOT" worktree remove --force "$WT_PATH" >/dev/null 2>&1; then
        # remove refused. Try `prune` once — it clears stale registrations
        # whose on-disk dir was already deleted. If the worktree is STILL
        # listed after prune, the failure is genuine (locked, perms, NFS).
        git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
        if _is_registered_worktree "$WT_PATH"; then
          echo "worktree_remove_failed"
          echo "worktree: git worktree remove refused for $WT_PATH" >&2
          echo "worktree: worktree_path retained in state — schema invariant preserved" >&2
          exit 1
        fi
      fi
    fi

    # Reached only when the worktree is verifiably gone from git's registry.
    # Patch state to null so the schema invariant holds.
    # The .worktree_path validator (#170 Fix 3) exempts explicit null
    # writes because the invariant permits `worktree_path == null` when
    # no worktree is on disk.
    "$WS" patch "$KEY" "$ISSUE_NUMBER" '.worktree_path' 'null'

    echo "worktree_removed"
    ;;

  # -------------------------------------------------------------------------
  # retain <KEY> <HALT_CODE>
  # -------------------------------------------------------------------------
  retain)
    HALT_CODE="${1:?halt_code required (e.g. HALT-003 or merge_conflict)}"

    # No git operations — the worktree stays on disk exactly as the failed
    # run left it. Patch BOTH retention fields in a single workflow-state
    # write so no concurrent reader observes worktree_retained=true with a
    # null reason (C16 fix). We read current state, merge the two fields,
    # then write back atomically via workflow-state.sh write (which itself
    # uses mktemp + mv).
    JSON_RETAIN_REASON="$(_json_encode "$HALT_CODE")"
    NEW_STATE="$("$WS" read "$KEY" "$ISSUE_NUMBER" \
      | jq --argjson r "$JSON_RETAIN_REASON" '.worktree_retained = true | .worktree_retain_reason = $r')"
    "$WS" write "$KEY" "$ISSUE_NUMBER" "$NEW_STATE"

    echo "worktree_retained"
    ;;

  *)
    echo "worktree: unknown subcommand '$SUBCMD'. Valid: create|path|cleanup|retain" >&2
    exit 1
    ;;
esac
