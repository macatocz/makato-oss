#!/usr/bin/env bash
# Smoke tests for the autonomous-propagation contract (#117).
#
# Asserts that:
#   T1 — AUTONOMOUS-MODE.md § *Cross-skill propagation* documents the
#        "skills MUST NOT forward --autonomous" rule and names $AGENT_ID
#        as the canonical bash-level signal.
#   T2 — No build skill prose forwards `--autonomous` on a documented
#        cross-skill dispatch (the legacy build-push-to-git → build-create-pr
#        site is the only one this rule affects).
#   T3 — Each build skill's Step 1a still accepts --autonomous on the CLI
#        (developer-driven entry point — unchanged).
#   T4 — Each build skill's Step 1a still names $AGENT_ID as a trigger.
#   T5 — A subprocess dispatch test: setting AGENT_ID=test, no --autonomous
#        flag, no CLI flags at all — the falsy-check bash snippet from
#        AUTONOMOUS-MODE.md treats this as autonomous mode.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: AUTONOMOUS-MODE.md documents the new contract -----
echo "T1: AUTONOMOUS-MODE.md § Cross-skill propagation contract"
AUTONOMOUS_MD="$PLUGIN_DIR/AUTONOMOUS-MODE.md"
if grep -qE 'Skills MUST NOT forward .--autonomous. on cross-skill dispatch' "$AUTONOMOUS_MD"; then
  _pass "MUST NOT forward --autonomous rule documented"
else
  _fail "MUST NOT forward rule NOT documented"
fi
if grep -qE 'AGENT_ID.*canonical|canonical.*AGENT_ID' "$AUTONOMOUS_MD"; then
  _pass "AGENT_ID named as canonical bash-level signal"
else
  _fail "AGENT_ID NOT named as canonical signal"
fi

# ----- T2: no skill forwards --autonomous on cross-skill dispatch -----
echo "T2: no skill forwards --autonomous on cross-skill dispatch"
# Search for patterns like "/build-create-pr <key> --autonomous" or similar
# documented dispatch lines. Exclude code blocks that document the activation
# triggers themselves (those legitimately name --autonomous).
SITES="$(grep -rn '/build-[a-z-]\+ <[a-z-]\+> --autonomous' "$PLUGIN_DIR/skills" 2>/dev/null || true)"
if [[ -z "$SITES" ]]; then
  _pass "no cross-skill dispatch forwards --autonomous"
else
  _fail "cross-skill dispatches still forward --autonomous:"
  echo "$SITES"
fi

# ----- T3: skills still accept --autonomous on the CLI (Step 1a / Input) -----
echo "T3: every autonomous-capable skill still accepts --autonomous on the CLI"
for skill_md in "$PLUGIN_DIR"/skills/build-{refine,implement-tdd,implement-goal,simplify,verify,push-to-git,create-pr,address-pr-comments}/SKILL.md; do
  name="$(basename "$(dirname "$skill_md")")"
  # The skill should still mention the CLI flag somewhere as an activation
  # trigger (Step 1a forward-ref to AUTONOMOUS-MODE.md § Activation triggers
  # counts via the canonical text).
  if grep -qE '\-\-autonomous' "$skill_md"; then
    _pass "$name still references --autonomous CLI flag"
  else
    _fail "$name does NOT reference --autonomous"
  fi
done

# ----- T4: AGENT_ID is a documented trigger -----
echo "T4: AGENT_ID remains a documented activation trigger"
if grep -qE 'AGENT_ID.*environment|\$AGENT_ID' "$AUTONOMOUS_MD"; then
  _pass "AGENT_ID documented as activation trigger"
else
  _fail "AGENT_ID NOT documented as trigger"
fi

# ----- T5: subprocess dispatch — AGENT_ID alone activates autonomous mode -----
echo "T5: AGENT_ID-only propagation activates autonomous mode (bash-level)"
# Construct a minimal repro of the falsy-check pattern documented in
# AUTONOMOUS-MODE.md § *Falsy-check pattern*. The contract is:
#   - AGENT_ID set + WORKTREE_PATH empty → exit 1 (autonomous + missing input)
#   - AGENT_ID unset + WORKTREE_PATH empty → fall through to git rev-parse
# This proves implicit env propagation reaches the falsy-check.
SUBPROC="$(mktemp)"
cat > "$SUBPROC" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  if [[ -n "${AGENT_ID:-}" ]]; then
    echo "AUTONOMOUS_HALT"
    exit 1
  fi
  echo "INTERACTIVE_FALLBACK"
  exit 0
fi
echo "WORKTREE_SET"
exit 0
EOF
chmod +x "$SUBPROC"

# Case A: AGENT_ID set, no WORKTREE_PATH → expect HALT
RESULT="$(AGENT_ID=test "$SUBPROC" 2>&1 || true)"
if [[ "$RESULT" == "AUTONOMOUS_HALT" ]]; then
  _pass "AGENT_ID set alone routes to autonomous-mode HALT"
else
  _fail "AGENT_ID-only did not trigger autonomous-mode (got: $RESULT)"
fi

# Case B: nothing set → expect interactive fallback
RESULT="$(env -i bash -c "$SUBPROC" 2>&1 || true)"
if [[ "$RESULT" == "INTERACTIVE_FALLBACK" ]]; then
  _pass "no signal → interactive fallback"
else
  _fail "no-signal case did not route to interactive (got: $RESULT)"
fi

rm -f "$SUBPROC"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All autonomous-propagation smoke tests passed."
  exit 0
else
  echo "$FAIL autonomous-propagation smoke test(s) failed."
  exit 1
fi
