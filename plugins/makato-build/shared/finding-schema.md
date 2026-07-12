# Finding schema — the sensor-loop contract

> **Single source of truth** for the normalised `Finding` object that flows through the
> makato-build sensor loop. Every stage below links here rather than re-describing the
> shape inline. Guarded by `shared/finding-schema-smoke-test.sh` (wired into
> `.github/workflows/validate.yml`).

## The loop

```
build-sensors ──▶ sensor-fixer (agent) ──▶ build-resolve-finding ──▶ build-fix-types
   (gate-0)        (outer loop)              (per-finding router)  └─▶ build-fix-security
```

`shared/parse-sarif.py` (`class Finding`) is the **sole emitter**. `build-sensors` pipes
every tool's diagnostics through it; the parsed `Finding` objects are handed to the
`sensor-fixer` agent, which routes each one through `build-resolve-finding`, which in turn
dispatches the per-tech repair skills. The shape is fixed at the emitter and read
unchanged by every downstream stage.

## Canonical shape

```json
{
  "tool": "ruff | pyright | bandit | gitleaks | semgrep | <other>",
  "rule": "<rule id, e.g. F401, reportArgumentType, B303; semgrep is category-prefixed>",
  "path": "<repo-relative file path>",
  "line": 123,
  "column": 4,
  "message": "<human-readable diagnostic; secrets redacted for gitleaks>",
  "severity": "error | warning | note",
  "autofix_available": true,
  "raw": { }
}
```

| Field | Type | Notes |
|-------|------|-------|
| `tool` | str | Emitting tool. |
| `rule` | str | Rule id. Semgrep rules are category-prefixed (`security.*` / `style.*`) so `finding-routes.json` can distinguish them. |
| `path` | str | Repo-relative file path. |
| `line` | int | 1-based line; `0` when unknown. |
| `column` | int | 1-based column; `0` when unknown. |
| `message` | str | Diagnostic text. gitleaks messages are redacted — never the secret value. |
| `severity` | str | Normalised to one of `error` / `warning` / `note` in `Finding.__post_init__`. |
| `autofix_available` | bool | `True` when the issuing tool can fix it — SARIF `fixes[]` present, or the rule matches `AUTOFIXABLE_RULES`. |
| `raw` | dict | Original tool payload, pass-through. Optional for consumers; carried for debugging. |

The route key used by `sensor-fixer` / `build-resolve-finding` / `finding-routes.json` is
`"<tool>:<rule>"` — the concatenation of `tool` and `rule`.

## Forbidden field names

These are the **stale** names #230 removed. They must never reappear in a loop artefact;
the contract test greps for them:

| Forbidden | Canonical replacement |
|-----------|-----------------------|
| `rule_id` | `rule` |
| `fixable` | `autofix_available` |
| `file` (Finding-level key) | `path` |

## Derived, not received: `fingerprint`

`sensor-fixer` computes a per-finding `fingerprint` for deduplication. It is a
**sensor-fixer-local derived key**, not a field emitted by `parse-sarif.py`. Do not
document it as a `Finding` input field — a finding does not arrive with a `fingerprint`.

## Out of scope for #230: severity vocabulary

`parse-sarif.py` emits `severity` from the set `{error, warning, note}`. The three fixer
skills (`build-resolve-finding`, `build-fix-types`, `build-fix-security`) show
`severity: low | medium | high | critical` in their *input* examples — they map/interpret
severity themselves. This value-vocabulary divergence is a **separate concern**; #230
unified field *names* only. Flagged here so a future issue can address the vocabulary
without re-discovering it.
