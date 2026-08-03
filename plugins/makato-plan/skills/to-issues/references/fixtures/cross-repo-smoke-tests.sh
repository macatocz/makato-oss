#!/usr/bin/env bash
# Smoke tests for the to-issues --repo / --store flag resolution (issue #565).
#
# to-issues is a prose skill — its logic lives in SKILL.md and is executed by
# an agent, not a script. This file is the *executable spec* for the
# deterministic flag-parsing core of the cross-repo feature: it re-implements
# the TARGET_REPO resolution algorithm exactly as the prose describes it, runs
# it against a minimal fixture .claude/config.json containing one store entry,
# and asserts all five acceptance criteria from issue #565:
#
#   1. --repo owner/repo  → TARGET_REPO == "owner/repo"; all gh issue create
#      calls would include --repo owner/repo.
#   2. --store <id>  where id IS in stores[]  → TARGET_REPO == that store's
#      repo field.
#   3. --store <id>  where id is ABSENT from stores[]  → skill halts with an
#      error listing known store IDs.
#   4. Neither --repo nor --store passed  → TARGET_REPO defaults to the current
#      repo (unchanged behaviour — derived from git remote).
#   5. Both --repo and --store passed  → mutually-exclusive error.
#
# Pure bash + python3 stdlib. No gh, no network, no agent.
#
# If the prose in SKILL.md changes the algorithm, update this reference
# implementation in lockstep — a drift here means the spec and its guard
# disagree.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FIXTURE_CONFIG="$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/fixtures/cross-repo-config.json"

pass=0
fail=0

# check <test-name> <expected> <actual>
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s → %s\n' "$name" "$actual"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual"
  fi
}

echo "== to-issues --repo/--store flag resolution (#565) =="

# ---------------------------------------------------------------------------
# Reference implementation of the deterministic TARGET_REPO resolution logic,
# per SKILL.md Step 0 (extended section).  Emits `key=value` lines the bash
# harness asserts on.  If SKILL.md changes the algorithm, update this in
# lockstep.
#
# resolve_target_repo(repo_flag, store_flag, config_path, git_remote)
#   returns either:
#     TARGET_REPO=<value>
#   or:
#     ERROR=<message>
# ---------------------------------------------------------------------------
RESULT="$(python3 - "$FIXTURE_CONFIG" <<'PY'
import json
import sys

config_path = sys.argv[1]

def load_stores(config_path):
    try:
        cfg = json.load(open(config_path))
        return cfg.get("stores", [])
    except FileNotFoundError:
        return []
    except json.JSONDecodeError as e:
        print(f"ERROR=malformed config.json: {e}")
        sys.exit(2)

def resolve_target_repo(repo_flag, store_flag, config_path, git_remote):
    """
    Resolution logic as documented in SKILL.md Step 0 (--repo/--store extension).

    --repo and --store are mutually exclusive.
    --repo <owner/repo>  overrides the git-remote default directly.
    --store <id>         looks up id in .claude/config.json stores[]; resolves
                         to the store entry's `repo` field; halts with error if
                         the id is absent, listing known store IDs.
    Neither flag         falls back to the git-remote-derived TARGET_REPO.
    """
    # AC-5: mutual exclusion
    if repo_flag and store_flag:
        return "ERROR=--repo and --store are mutually exclusive"

    # AC-1: explicit --repo wins
    if repo_flag:
        return f"TARGET_REPO={repo_flag}"

    # AC-2 / AC-3: --store lookup
    if store_flag:
        stores = load_stores(config_path)
        for entry in stores:
            if entry.get("id") == store_flag:
                repo = entry.get("repo", "")
                if not repo:
                    return f"ERROR=store '{store_flag}' has no repo field"
                return f"TARGET_REPO={repo}"
        # AC-3: unknown id — list known IDs
        known = [e.get("id", "<unnamed>") for e in stores]
        known_str = ", ".join(known) if known else "(none)"
        return f"ERROR=unknown store id '{store_flag}'; known store IDs: {known_str}"

    # AC-4: default — use git remote (simulated here as fixture value)
    return f"TARGET_REPO={git_remote}"

GIT_REMOTE = "macatocz/makato"   # simulated git remote for this test run

# Scenario 1 (AC-1): --repo passed
print(resolve_target_repo("owner/repo", "", config_path, GIT_REMOTE))

# Scenario 2 (AC-2): --store with known id
print(resolve_target_repo("", "acme", config_path, GIT_REMOTE))

# Scenario 3 (AC-3): --store with unknown id
print(resolve_target_repo("", "unknown-store", config_path, GIT_REMOTE))

# Scenario 4 (AC-4): neither flag passed
print(resolve_target_repo("", "", config_path, GIT_REMOTE))

# Scenario 5 (AC-5): both flags passed
print(resolve_target_repo("owner/repo", "acme", config_path, GIT_REMOTE))
PY
)"

get_line() {
  # Return the Nth output line (1-based) from $RESULT
  echo "$RESULT" | sed -n "${1}p"
}

# Extract value after first '='
val() { echo "$1" | cut -d= -f2-; }

LINE1="$(get_line 1)"
LINE2="$(get_line 2)"
LINE3="$(get_line 3)"
LINE4="$(get_line 4)"
LINE5="$(get_line 5)"

# AC-1: --repo owner/repo → TARGET_REPO=owner/repo
check "AC-1: --repo flag sets TARGET_REPO directly" \
  "TARGET_REPO=owner/repo" "$LINE1"

# AC-2: --store acme (present in fixture) → TARGET_REPO=acme-corp/platform
check "AC-2: --store with known id resolves to store's repo field" \
  "TARGET_REPO=acme-corp/platform" "$LINE2"

# AC-3: --store unknown-store → ERROR containing known IDs
# We check that the line starts with ERROR= and mentions the known id
LINE3_PREFIX="${LINE3%%=*}"
LINE3_REST="${LINE3#*=}"
check "AC-3: --store with unknown id produces ERROR= line" \
  "ERROR" "$LINE3_PREFIX"

# Also assert the error message lists the known store id
if echo "$LINE3_REST" | grep -q "acme"; then
  check "AC-3: error message lists known store IDs" "listed" "listed"
else
  check "AC-3: error message lists known store IDs" "listed" "not-listed"
fi

# AC-4: neither flag → TARGET_REPO defaults to git remote
check "AC-4: no flags → TARGET_REPO defaults to current repo" \
  "TARGET_REPO=macatocz/makato" "$LINE4"

# AC-5: both flags → ERROR
LINE5_PREFIX="${LINE5%%=*}"
check "AC-5: both --repo and --store together produce an error" \
  "ERROR" "$LINE5_PREFIX"

echo ""
echo "== --repo flag propagation to gh issue create calls =="

# Verify the flag-parsing logic also confirms that when TARGET_REPO is set via
# --repo, the value is exactly what would be passed to `gh issue create --repo`.
# This is a structural assertion: the TARGET_REPO value IS the --repo argument.
# No actual gh call is made.
REPO_FROM_FLAG="$(python3 - "$FIXTURE_CONFIG" <<'PY'
import json, sys

def resolve(repo_flag, store_flag, config_path, git_remote):
    if repo_flag and store_flag:
        return None
    if repo_flag:
        return repo_flag
    if store_flag:
        stores = json.load(open(config_path)).get("stores", [])
        for e in stores:
            if e.get("id") == store_flag:
                return e.get("repo", "")
        return None
    return git_remote

target = resolve("myorg/myrepo", "", sys.argv[1], "macatocz/makato")
# Simulate: gh issue create --repo "$TARGET_REPO"
# The assertion is that TARGET_REPO equals myorg/myrepo
print(f"gh_repo_arg={target}")
PY
)"

check "gh issue create --repo arg equals TARGET_REPO from --repo flag" \
  "gh_repo_arg=myorg/myrepo" "$REPO_FROM_FLAG"

echo ""
echo "== store lookup — absent stores[] key in config =="

# When config.json has no stores[] key at all, --store should still produce
# the unknown-id error (not a KeyError crash), and list "(none)" as known IDs.
NO_STORES_RESULT="$(python3 - <<'PY'
import json, sys

config_no_stores = {"project": "test"}  # no stores[] key

def load_stores_from_dict(cfg):
    return cfg.get("stores", [])

def resolve(repo_flag, store_flag, cfg, git_remote):
    if repo_flag and store_flag:
        return "ERROR=mutually exclusive"
    if repo_flag:
        return f"TARGET_REPO={repo_flag}"
    if store_flag:
        stores = load_stores_from_dict(cfg)
        for entry in stores:
            if entry.get("id") == store_flag:
                return f"TARGET_REPO={entry.get('repo', '')}"
        known = [e.get("id", "<unnamed>") for e in stores]
        known_str = ", ".join(known) if known else "(none)"
        return f"ERROR=unknown store id '{store_flag}'; known store IDs: {known_str}"
    return f"TARGET_REPO={git_remote}"

result = resolve("", "missing", config_no_stores, "macatocz/makato")
print(result)
PY
)"

NO_STORES_PREFIX="${NO_STORES_RESULT%%=*}"
NO_STORES_REST="${NO_STORES_RESULT#*=}"
check "missing stores[] key: --store still errors cleanly" \
  "ERROR" "$NO_STORES_PREFIX"

if echo "$NO_STORES_REST" | grep -q "(none)"; then
  check "missing stores[] key: error lists '(none)' as known IDs" "listed" "listed"
else
  check "missing stores[] key: error lists '(none)' as known IDs" "listed" "not-listed"
fi

echo ""
echo "to-issues cross-repo flag-resolution smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
