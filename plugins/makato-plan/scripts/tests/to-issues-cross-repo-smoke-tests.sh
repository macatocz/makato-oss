#!/usr/bin/env bash
# Smoke tests for the to-issues --repo/--store cross-repo feature (issue #565).
#
# to-issues is a prose skill — its logic lives in SKILL.md and is executed by
# an agent, not a script. This file is the *executable spec* for the
# deterministic flag-parsing core of the cross-repo feature: it re-implements
# the TARGET_REPO resolution algorithm exactly as the prose describes it, runs
# it against a minimal fixture .claude/config.json containing one store entry,
# and asserts five scenarios (T1-T5):
#
#   T1: no flags -> TARGET_REPO defaults to current repo (unchanged behaviour)
#   T2: --repo owner/repo -> TARGET_REPO=owner/repo (dry-run URL uses owner/repo)
#   T3: --store <known-id> -> TARGET_REPO resolves to the store's repo field
#   T4: --store nonexistent -> exits 1 with "unknown store" in error message
#   T5: --repo + --store passed together -> exits 1 with mutual-exclusion error
#
# Part 2 validates that created-issues.schema.json declares target_repo as an
# optional top-level string field (AC-5 gate: schema updated to allow emitting
# the resolved repo alongside the issues array).
#
# Pure bash + python3 stdlib. No gh, no network, no agent.
#
# Uses the cross-repo-config.json fixture created in Task 1:
#   plugins/makato-plan/skills/to-issues/references/fixtures/cross-repo-config.json
#
# If the prose in SKILL.md changes the algorithm, update this reference
# implementation in lockstep — a drift here means the spec and its guard disagree.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FIXTURE_CONFIG="$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/fixtures/cross-repo-config.json"
SCHEMA="$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/created-issues.schema.json"

pass=0
fail=0

# check <test-name> <expected> <actual>
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual"
  fi
}

echo "== to-issues --repo/--store flag resolution (T1-T5) (#565) =="

# ---------------------------------------------------------------------------
# Reference implementation of the deterministic TARGET_REPO resolution logic,
# per SKILL.md Step 0 (cross-repo extension).  Emits `key=value` lines the bash
# harness asserts on.  If SKILL.md changes the algorithm, update this in lockstep.
#
# Scenarios emitted in order: T1, T2, T3, T4, T5
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
    TARGET_REPO resolution per SKILL.md Step 0 (--repo/--store extension).

    --repo and --store are mutually exclusive.
    --repo <owner/repo>  overrides the git-remote default directly.
    --store <id>         looks up id in .claude/config.json stores[]; resolves
                         to the store entry's `repo` field; halts with error if
                         the id is absent, listing known store IDs.
    Neither flag         falls back to the git-remote-derived TARGET_REPO.
    """
    # T5: mutual exclusion
    if repo_flag and store_flag:
        return "ERROR=--repo and --store are mutually exclusive"

    # T2: explicit --repo wins
    if repo_flag:
        return f"TARGET_REPO={repo_flag}"

    # T3 / T4: --store lookup
    if store_flag:
        stores = load_stores(config_path)
        for entry in stores:
            if entry.get("id") == store_flag:
                repo = entry.get("repo", "")
                if not repo:
                    return f"ERROR=store '{store_flag}' has no repo field"
                return f"TARGET_REPO={repo}"
        # T4: unknown id — list known IDs
        known = [e.get("id", "<unnamed>") for e in stores]
        known_str = ", ".join(known) if known else "(none)"
        return f"ERROR=unknown store id '{store_flag}'; known store IDs: {known_str}"

    # T1: default — use git remote (simulated fixture value)
    return f"TARGET_REPO={git_remote}"

GIT_REMOTE = "macatocz/makato"   # simulated git remote for this test run

# T1: no flags
print(resolve_target_repo("", "", config_path, GIT_REMOTE))

# T2: --repo passed directly
print(resolve_target_repo("owner/repo", "", config_path, GIT_REMOTE))

# T3: --store with known id
print(resolve_target_repo("", "acme", config_path, GIT_REMOTE))

# T4: --store with unknown id
print(resolve_target_repo("", "nonexistent", config_path, GIT_REMOTE))

# T5: both flags passed
print(resolve_target_repo("owner/repo", "acme", config_path, GIT_REMOTE))
PY
)"

get_line() { echo "$RESULT" | sed -n "${1}p"; }

L1="$(get_line 1)"
L2="$(get_line 2)"
L3="$(get_line 3)"
L4="$(get_line 4)"
L5="$(get_line 5)"

# T1: no flags -> current-repo TARGET_REPO (unchanged behaviour)
check "T1: no flags -> TARGET_REPO defaults to current repo" \
  "TARGET_REPO=macatocz/makato" "$L1"

# T2: --repo owner/repo -> TARGET_REPO=owner/repo
# dry-run: gh issue create --repo TARGET_REPO; the URL would contain owner/repo
check "T2: --repo flag sets TARGET_REPO directly" \
  "TARGET_REPO=owner/repo" "$L2"
REPO_IN_URL="$(echo "$L2" | cut -d= -f2-)"
check "T2: dry-run issue URL repo segment matches --repo value" \
  "owner/repo" "$REPO_IN_URL"

# T3: --store acme (present in fixture) -> TARGET_REPO=acme-corp/platform
check "T3: --store with known id resolves to store's repo field" \
  "TARGET_REPO=acme-corp/platform" "$L3"

# T4: --store nonexistent -> ERROR containing "unknown store"
L4_KEY="${L4%%=*}"
L4_VAL="${L4#*=}"
check "T4: --store nonexistent exits with error key" "ERROR" "$L4_KEY"
if echo "$L4_VAL" | grep -q "unknown store"; then
  check "T4: error message contains 'unknown store'" "yes" "yes"
else
  check "T4: error message contains 'unknown store'" "yes" "no"
fi

# T5: --repo + --store together -> mutual-exclusion error
L5_KEY="${L5%%=*}"
check "T5: --repo and --store together produce mutual-exclusion error" "ERROR" "$L5_KEY"

echo ""
echo "== created-issues.schema.json: target_repo field (AC-5) =="

# AC-5 gate: the schema must declare target_repo as an optional top-level
# string field so emitted created-issues.json files can carry the resolved repo
# without violating additionalProperties:false.
SCHEMA_RESULT="$(python3 - "$SCHEMA" <<'PY'
import json
import sys

schema = json.load(open(sys.argv[1]))
root_props = schema.get("properties", {})
has_tr = "target_repo" in root_props

if has_tr:
    tr = root_props["target_repo"]
    tr_type = tr.get("type", "missing")
    # optional = NOT in required[]
    tr_optional = "target_repo" not in schema.get("required", [])
    print(f"target_repo_present=yes")
    print(f"target_repo_type={tr_type}")
    print(f"target_repo_optional={'yes' if tr_optional else 'no'}")
else:
    print("target_repo_present=no")
    print("target_repo_type=missing")
    print("target_repo_optional=unknown")
PY
)"

sget() { echo "$SCHEMA_RESULT" | grep "^${1}=" | cut -d= -f2-; }

check "AC-5: created-issues.schema.json has top-level target_repo field" \
  "yes" "$(sget target_repo_present)"
check "AC-5: target_repo field type is string" \
  "string" "$(sget target_repo_type)"
check "AC-5: target_repo field is optional (not in required[])" \
  "yes" "$(sget target_repo_optional)"

echo ""
echo "to-issues cross-repo smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
