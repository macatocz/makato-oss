#!/usr/bin/env bash
# Smoke tests for build-address-pr-comments autonomous-mode wiring (GAP-011 / #36).
#
# Read-only structural assertions over the skill, the shared template, and the
# cross-doc references. No `gh` calls, no test PR, no network. Run via:
#
#   bash plugins/makato-build/shared/pr-comments-smoke-tests.sh
#
# Exit code: 0 on PASS, 1 on first FAIL.

set -u
set -o pipefail

# Resolve plugin root regardless of CWD. The skill's `shared/` directory is a
# symlink to the plugin-level `shared/` dir, so $BASH_SOURCE can resolve in
# either location. Walk up looking for `plugins/makato-build/AGENTS.md` — the
# stable anchor for this plugin's root.
THIS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR=""
candidate="$THIS_SCRIPT_DIR"
while [[ "$candidate" != "/" ]]; do
  if [[ -f "$candidate/AGENTS.md" && "$candidate" == */plugins/makato-build ]]; then
    PLUGIN_DIR="$candidate"
    break
  fi
  candidate="$(dirname "$candidate")"
done
if [[ -z "$PLUGIN_DIR" ]]; then
  printf 'FATAL: could not locate plugins/makato-build root from %s\n' "$THIS_SCRIPT_DIR" >&2
  exit 2
fi
SKILL_DIR="$PLUGIN_DIR/skills/build-address-pr-comments"
SKILL_MD="$SKILL_DIR/SKILL.md"
TEMPLATE_MD="$PLUGIN_DIR/templates/pr-comment-replies.md"
AUTONOMOUS_MD="$PLUGIN_DIR/AUTONOMOUS-MODE.md"
ORCHESTRATE_DIR="$(cd "$PLUGIN_DIR/../makato-orchestrate" && pwd)"
HALT_MD="$ORCHESTRATE_DIR/halt-conditions.md"
PO_AGENT_MD="$ORCHESTRATE_DIR/agents/po-agent.md"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

# Each assert: <description> <command…>. Command is a callable that returns 0 on pass.
assert() {
  local desc="$1"; shift
  if "$@"; then
    green "PASS  $desc"
    PASS=$((PASS + 1))
  else
    red "FAIL  $desc"
    FAIL=$((FAIL + 1))
  fi
}

file_exists() { [[ -f "$1" ]]; }
contains()    { grep -q -- "$2" "$1"; }
contains_F()  { grep -qF -- "$2" "$1"; }

# --- A. File existence -----------------------------------------------------

assert "SKILL.md present at $SKILL_MD"            file_exists "$SKILL_MD"
assert "Reply template present at $TEMPLATE_MD"   file_exists "$TEMPLATE_MD"
assert "AUTONOMOUS-MODE.md present"               file_exists "$AUTONOMOUS_MD"
assert "halt-conditions.md present"               file_exists "$HALT_MD"
assert "po-agent.md present"                      file_exists "$PO_AGENT_MD"

# --- B. SKILL.md frontmatter + structure -----------------------------------

assert "SKILL.md version bumped to at least 1.4.0"         contains "$SKILL_MD" '^version: "1\.[4-9]\.'
assert "SKILL.md description mentions --autonomous safety"   contains_F "$SKILL_MD" "Headless-safe under --autonomous"

# --- C. AC2 — SHOULD-FIX scope guard ---------------------------------------

assert "SKILL.md references plan.md task[].Files[] for scope guard" \
  contains_F "$SKILL_MD" 'task[].Files[]'
assert "SKILL.md logs should-fix-scope-guard gate" \
  contains_F "$SKILL_MD" 'should-fix-scope-guard'
assert "SKILL.md surfaces DEFERRED tier in Step 5"  contains_F "$SKILL_MD" "mark the comment DEFERRED"
assert "Template defines [DEFERRED] marker section"  contains_F "$TEMPLATE_MD" "SHOULD-FIX (deferred — autonomous-only)"
assert "Template uses [DEFERRED] bracket marker"     contains_F "$TEMPLATE_MD" "[DEFERRED]"

# --- D. AC3 — STRUCTURAL HALT-003 -----------------------------------------

assert "SKILL.md has Step 5a — STRUCTURAL HALT-003"    contains_F "$SKILL_MD" "Step 5a — STRUCTURAL HALT-003"
assert "SKILL.md sequence: summary reply → label → log → HALT" \
  contains_F "$SKILL_MD" "post-reply → label → log → HALT"
assert "SKILL.md applies needs-human-review on PR + issue"    contains_F "$SKILL_MD" 'gh pr edit "$PR_NUMBER" --add-label needs-human-review'
assert "SKILL.md exits with data.halt_code HALT-003"    contains_F "$SKILL_MD" 'data.halt_code: "HALT-003"'
assert "Template has STRUCTURAL MUST-FIX section"       contains_F "$TEMPLATE_MD" "STRUCTURAL MUST-FIX (autonomous HALT — AC3)"
assert "Template uses [STRUCTURAL] bracket marker"      contains_F "$TEMPLATE_MD" "[STRUCTURAL]"
assert "halt-conditions.md HALT-003 lists build-address-pr-comments" \
  contains_F "$HALT_MD" "STRUCTURAL MUST-FIX comments from autonomous \`build-address-pr-comments\` (\`STRUCTURAL_BLOCKER\`)"
assert "po-agent.md Label application table has a HALT-003 row for pr-comments STRUCTURAL" \
  contains_F "$PO_AGENT_MD" "or \`build-address-pr-comments\` STRUCTURAL"

# --- E. AC4 — OUT-OF-SCOPE carry-over -------------------------------------

assert "SKILL.md opens follow-up via gh issue create"    contains_F "$SKILL_MD" 'gh issue create'
assert "SKILL.md applies makato-carry-over label"        contains_F "$SKILL_MD" 'makato-carry-over'
assert "SKILL.md auto-creates label idempotently"        contains_F "$SKILL_MD" 'gh label create makato-carry-over'
assert "SKILL.md HALT-005 on carry-over failure"         contains_F "$SKILL_MD" 'CARRY_OVER_FAILED:'
assert "Template has OUT-OF-SCOPE autonomous variant with follow-up URL" \
  contains_F "$TEMPLATE_MD" 'Tracked separately at <follow-up-issue>'

# --- F. AC5 — Reply templates externalized --------------------------------

assert "SKILL.md Step 9 references @../../templates/pr-comment-replies.md" \
  contains_F "$SKILL_MD" '@../../templates/pr-comment-replies.md'
assert "SKILL.md prohibits hard-coded reply prose (AC5 callout)" \
  contains_F "$SKILL_MD" "Hard-coded prose in this skill is a contract violation (AC5)"
assert "SKILL.md Step 9 contains tier→template mapping table" \
  contains_F "$SKILL_MD" "Tier → template section mapping"
assert "SKILL.md HALTs on placeholder render failure"   contains_F "$SKILL_MD" 'RENDER_FAILED:'
assert "AUTONOMOUS-MODE.md documents templates/ exception" \
  contains_F "$AUTONOMOUS_MD" "Shared reply templates — \`templates/pr-comment-replies.md\`"
assert "AUTONOMOUS-MODE.md documents Label-application exception" \
  contains_F "$AUTONOMOUS_MD" "Label-application exception — STRUCTURAL HALT-003"

# --- G. Template placeholder vocabulary completeness ----------------------

for ph in "<commit-sha>" "<fix-summary>" "<reason>" "<follow-up-issue>" "<comment-summary>" "<key>" "<harness-issue>" "<proposed-rule>"; do
  assert "Template defines placeholder $ph"  contains_F "$TEMPLATE_MD" "$ph"
done

# --- H. AC1 — autonomous_bypass logging schema ----------------------------

# Every per-gate bypass must emit an autonomous_bypass entry. Spot-check the
# four GAP-011 gates land in SKILL.md alongside the canonical helper call.
# Post-#116: gates are passed as positional args to the log-bypass.sh helper
# (invoked as "$MAKATO_BUILD_ROOT/shared/log-bypass.sh"), not as
# inline JSON `"gate":"<name>"` literals.
assert "SKILL.md logs comment-classification bypass"     contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" comment-classification'
assert "SKILL.md logs should-fix-scope-guard bypass"     contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" should-fix-scope-guard'
assert "SKILL.md logs out-of-scope-carry-over bypass"    contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" out-of-scope-carry-over'
assert "SKILL.md logs structural-must-fix bypass"        contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" structural-must-fix'
assert "SKILL.md logs structural-halt-summary bypass"    contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" structural-halt-summary'
assert "SKILL.md logs sensor-bot-classification bypass"  contains_F "$SKILL_MD" 'log-bypass.sh" build-address-pr-comments "<key>" sensor-bot-classification'
assert "SKILL.md routes autonomous_bypass through log-bypass.sh helper" \
  contains_F "$SKILL_MD" 'shared/log-bypass.sh" build-address-pr-comments'

# --- I. AUTONOMOUS-MODE.md per-gate table currency -------------------------

assert "AUTONOMOUS-MODE.md Step 5 row reflects scope-guard policy" \
  contains_F "$AUTONOMOUS_MD" "SHOULD-FIX is **scope-guarded**"
assert "AUTONOMOUS-MODE.md Step 5a row added for STRUCTURAL flow" \
  contains_F "$AUTONOMOUS_MD" "Step 5a — STRUCTURAL handling"

# --- J. Review-feedback promotion (Step 5b + Step 6a) ---

assert "SKILL.md version bumped to at least 1.6.0" \
  contains "$SKILL_MD" '^version: "1\.[6-9]\.'

assert "SKILL.md documents Step 5b heading" \
  contains_F "$SKILL_MD" 'Step 5b'

assert "SKILL.md documents write-lessons.sh call-site" \
  contains_F "$SKILL_MD" 'write-lessons.sh'

assert "SKILL.md documents Step 6a heading" \
  contains_F "$SKILL_MD" 'Step 6a'

assert "SKILL.md documents RECURRENCE_THRESHOLD constant" \
  contains_F "$SKILL_MD" 'RECURRENCE_THRESHOLD'

assert "SKILL.md documents type:harness issue creation" \
  contains_F "$SKILL_MD" 'type:harness'

assert "SKILL.md documents recurring-pattern-check bypass gate" \
  contains_F "$SKILL_MD" 'recurring-pattern-check'

assert "AUTONOMOUS-MODE.md has recurring-pattern-check row" \
  contains_F "$AUTONOMOUS_MD" 'recurring-pattern-check'

# --- Summary --------------------------------------------------------------

echo
echo "=========================================="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"
echo "=========================================="

[[ $FAIL -eq 0 ]]
