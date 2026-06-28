# build-fix-security — Test Fixtures

Manual verification recipe for the `build-fix-security` skill.
Mirrors the pattern from `build-fix-types/test-fixtures/README.md`.

## Prerequisites

```bash
pip install bandit
```

## Run bandit against the fixtures

From the repository root:

```bash
bandit -r plugins/makato-build/skills/build-fix-security/test-fixtures/bandit-sample.py \
       --format json 2>/dev/null | jq '.results[] | {rule: .test_id, line: .line_number, severity: .issue_severity, text: .issue_text}'
```

## Expected findings (one per branch)

| Function | Rule | Branch | CWE | Expected severity |
|----------|------|--------|-----|-------------------|
| `crypto_weak_hash` | B303 | 1 (Autofix) | CWE-327 | MEDIUM |
| `yaml_unsafe_load` | B506 | 1 (Autofix) | CWE-502 | MEDIUM |
| `ssl_legacy_protocol` | B502 | 1 (Autofix) | CWE-295 | MEDIUM |
| `shell_injection` | B602 | 2 (Refactor) | CWE-78 | HIGH |
| `test_assert_fp` | B101 | 3 (Suppress) | — | LOW (suppressed in real runs) |
| `deserialize_untrusted` | B301 | 4 (Carry-over) | CWE-502 | MEDIUM |
| `eval_dynamic` | B307 | 4 (Carry-over) | CWE-95 | MEDIUM |

## Verify route map

Check that each rule routes to `build-fix-security` (not `build-simplify`):

```bash
ROUTES=plugins/makato-build/shared/finding-routes.json

# B303 should route to build-fix-security (routes are nested under .routes)
jq '.routes."bandit:B303" // .routes."bandit:*"' "$ROUTES"

# Catch-all bandit:* should route to build-fix-security
jq '.routes."bandit:*"' "$ROUTES"

# safety:* and pip-audit:* should route to build-fix-security
jq '.routes."safety:*", .routes."pip-audit:*"' "$ROUTES"
```

Expected output (all three):

```json
{
  "action": "skill",
  "skill": "makato-build:build-fix-security",
  "note": "..."
}
```

## Spot-check a specific route

```bash
RULE="bandit:B602"
jq --arg r "$RULE" '.routes[$r] // .routes["bandit:*"]' plugins/makato-build/shared/finding-routes.json
```
