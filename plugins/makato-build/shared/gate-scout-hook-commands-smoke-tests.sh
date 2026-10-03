#!/usr/bin/env bash
# Contract / smoke test for gate-scout pre-commit hook-commands probe (#450).
#
# gate-scout Step 1d probes .pre-commit-config.yaml for
# type-check (pyright/mypy) and lint (ruff/flake8/pylint) hook IDs and
# exposes new R1 data fields (build_hook_cmd, lint_hook_cmd, pyright_env,
# build_hook_missing, lint_hook_missing) so build-verify Gates 1 and 2 can
# run changed-file-only pre-commit commands instead of raw tool invocations.
#
# T1 — gate-scout.md Step 1d probes .pre-commit-config.yaml
# T2 — gate-scout.md maps pyright → build_hook_cmd
# T3 — gate-scout.md maps ruff → lint_hook_cmd
# T4 — gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd fields
# T5 — command contract contains no all-files scan
# T6 — changed-file sources cover branch, worktree, and untracked changes
# T7 — filename transport is NUL-delimited and quoted
# T8 — gate-scout version is 1.6.0 or higher
# E1 — gate-scout reads canonical MAKATO_E2E config and command
# E2 — prose output publishes e2e_cmd and e2e_config
# E3 — R1 data shape publishes both E2E fields
# E4 — success example matches config/config.yml producer values
# T9 — active settings omit legacy commit/push blockers and retain advisory Stop
#
# Assertions are read-only contract checks.
# No mutation, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
FAIL=0

GATE_SCOUT_MD="$PLUGIN_DIR/agents/gate-scout.md"
CONFIG_YML="$PLUGIN_DIR/../../config/config.yml"
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"

_pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
_fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---- T1: gate-scout.md Step 1d probes .pre-commit-config.yaml ---------------
echo "T1: gate-scout.md Step 1d probes .pre-commit-config.yaml"
if grep -qF 'pre-commit-config.yaml' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md references .pre-commit-config.yaml"
else
  _fail "gate-scout.md does not reference .pre-commit-config.yaml — Step 1d missing"
fi

# ---- T2: gate-scout.md maps pyright → build_hook_cmd -----------------------
echo "T2: gate-scout.md maps pyright → build_hook_cmd"
if grep -qF 'build_hook_cmd' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md documents build_hook_cmd field"
else
  _fail "gate-scout.md missing build_hook_cmd field"
fi

# ---- T3: gate-scout.md maps ruff → lint_hook_cmd ---------------------------
echo "T3: gate-scout.md maps ruff → lint_hook_cmd"
if grep -qF 'lint_hook_cmd' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md documents lint_hook_cmd field"
else
  _fail "gate-scout.md missing lint_hook_cmd field"
fi

# ---- T4: gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd -
echo "T4: gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd"
# Both fields must appear in the data shape description (prose section) and
# the success example JSON block.
if grep -qF '"build_hook_cmd"' "$GATE_SCOUT_MD" && grep -qF '"lint_hook_cmd"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md R1 data shape includes both build_hook_cmd and lint_hook_cmd"
else
  _fail "gate-scout.md R1 data shape missing build_hook_cmd or lint_hook_cmd"
fi

# ---- T5: all-files scans are forbidden -------------------------------------
echo "T5: gate-scout command contract contains no all-files scan"
if grep -qF -- '--all-files' "$GATE_SCOUT_MD"; then
  _fail "gate-scout.md still contains --all-files"
else
  _pass "gate-scout.md contains no --all-files scan"
fi

# ---- T6: changed-file sources are complete ---------------------------------
echo "T6: gate-scout covers branch, worktree, and untracked changes"
BRANCH_DIFF_PATTERN="\"\${BASE_REF}...HEAD\""
if grep -qF "$BRANCH_DIFF_PATTERN" "$GATE_SCOUT_MD" &&
  grep -qF 'git diff --name-only --diff-filter=ACMR -z HEAD' "$GATE_SCOUT_MD" &&
  grep -qF 'git ls-files --others --exclude-standard -z' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md covers all changed-file sources"
else
  _fail "gate-scout.md changed-file source contract is incomplete"
fi

# ---- T7: filename transport is safe ----------------------------------------
echo "T7: gate-scout uses NUL-delimited, quoted filename transport"
if grep -qF 'xargs -0 sh -c' "$GATE_SCOUT_MD" &&
  grep -qF -- '--files "$@"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md safely transports filenames"
else
  _fail "gate-scout.md filename transport is not NUL-delimited and quoted"
fi

# ---- T8: gate-scout version is 1.6.0 or higher ------------------------------
echo "T8: gate-scout version is 1.6.0 or higher"
if grep -qE 'version: "1\.([6-9]|[1-9][0-9]+)\.' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md version is 1.6.0 or higher"
else
  _fail "gate-scout.md version is not 1.6.0 or higher — bump required"
fi

# ---- E1: canonical E2E producer discovery ----------------------------------
echo "E1: gate-scout discovers canonical MAKATO_E2E config and command"
if grep -qF 'Step 1f — Detect canonical full-E2E configuration' "$GATE_SCOUT_MD" &&
  grep -qF 'REPO_ROOT/config/config.yml' "$GATE_SCOUT_MD" &&
  grep -qF 'top-level' "$GATE_SCOUT_MD" &&
  grep -qF 'MAKATO_E2E' "$GATE_SCOUT_MD"; then
  _pass "gate-scout defines canonical E2E producer discovery"
else
  _fail "gate-scout does not discover the canonical MAKATO_E2E producer"
fi

# ---- E2: prose output fields ------------------------------------------------
echo "E2: gate-scout prose output publishes E2E fields"
if grep -qF '**e2e_cmd**:' "$GATE_SCOUT_MD" &&
  grep -qF '**e2e_config**:' "$GATE_SCOUT_MD"; then
  _pass "gate-scout prose output includes e2e_cmd and e2e_config"
else
  _fail "gate-scout prose output omits an E2E field"
fi

# ---- E3: R1 data shape fields -----------------------------------------------
echo "E3: gate-scout R1 data shape publishes E2E fields"
if grep -qF '"e2e_cmd":"...|null"' "$GATE_SCOUT_MD" &&
  grep -qF '"e2e_config":"config/config.yml|null"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout R1 shape includes both E2E fields"
else
  _fail "gate-scout R1 shape omits an E2E field"
fi

# ---- E4: example agrees with canonical producer -----------------------------
echo "E4: gate-scout example matches canonical MAKATO_E2E producer"
E2E_COMMAND="$(awk '
  /^MAKATO_E2E:[[:space:]]*$/ { section=1; next }
  section && /^[^[:space:]#]/ { exit }
  section && /^  command:[[:space:]]*/ {
    value=$0
    sub(/^  command:[[:space:]]*/, "", value)
    gsub(/^"|"$/, "", value)
    print value
    exit
  }
' "$CONFIG_YML")"
if [[ -n "$E2E_COMMAND" ]] &&
  grep -qF "\"e2e_cmd\": \"$E2E_COMMAND\"" "$GATE_SCOUT_MD" &&
  grep -qF '"e2e_config": "config/config.yml"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout example matches config/config.yml command and path"
else
  _fail "gate-scout E2E example diverges from canonical config"
fi

# ---- T9: active settings contain only the advisory hook contract ------------
echo "T9: active settings omit legacy blockers and retain advisory Stop"
if python3 - "$SETTINGS_JSON" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hooks = settings.get("hooks", {})
legacy_matchers = {"Bash(git commit*)", "Bash(git push*)"}
active_matchers = {
    entry.get("matcher")
    for entry in hooks.get("PreToolUse", [])
    if isinstance(entry, dict)
}
if active_matchers & legacy_matchers:
    raise SystemExit("legacy git commit/push PreToolUse blocker is still active")

stop_commands = [
    hook.get("command", "")
    for entry in hooks.get("Stop", [])
    if isinstance(entry, dict)
    for hook in entry.get("hooks", [])
    if isinstance(hook, dict)
]
if not any(
    "build-push-to-git" in command and "Push detected" in command
    for command in stop_commands
):
    raise SystemExit("advisory post-push Stop hook is missing")
PY
then
  _pass "settings omit legacy blockers and retain advisory Stop"
else
  _fail "settings legacy/advisory hook contract is invalid"
fi

echo
if (( FAIL == 0 )); then
  echo "All gate-scout hook-commands smoke tests passed."
  exit 0
else
  echo "$FAIL gate-scout hook-commands smoke test(s) failed."
  exit 1
fi
