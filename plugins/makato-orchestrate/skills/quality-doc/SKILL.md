---
name: quality-doc
description: 'Generate a per-domain quality scorecard from build.jsonl and halt_audit data across all issues in a domain. Writes specs/master/<domain>-quality.md with a Quality Scorecard table showing tests passing, sensor-clean status, HALT count, last HALT code, and structural failures per issue. Use when: reviewing domain quality after a sprint, auditing build health, or regenerating the scorecard on demand. Triggers: "quality scorecard", "generate quality doc", "build quality report", "domain quality".'
version: 1.0.0
---

# quality-doc

Generate a per-domain quality scorecard that aggregates build health metrics
across all issues in a domain into a single `specs/master/<domain>-quality.md`
file. The scorecard is the canonical read-only view of build quality for a
domain; it is updated automatically after each PR merge (via
`documentation-agent` Step 7.6) and can be regenerated on demand at any time.

## Invocation Modes

### Operator-invoked (on demand)

Run from `REPO_ROOT`:

```bash
bash plugins/makato-orchestrate/scripts/generate-quality-doc.sh \
  --domain <name>
```

Optional: override the specs directory (defaults to `$REPO_ROOT/specs`):

```bash
bash plugins/makato-orchestrate/scripts/generate-quality-doc.sh \
  --domain <name> --specs-dir /path/to/specs
```

The `--domain` argument is required. Use `general` for issues whose `plan.md`
carries no `domain:` frontmatter field.

### Post-merge trigger (automated)

`documentation-agent` Step 7.6 calls `generate-quality-doc.sh --domain
<domain>` automatically after every PR merge. The domain is derived from the
merged issue's `plan.md` frontmatter using the same `detect_domain` logic as
`archive-spec.sh`. This call is **best-effort**: a non-zero exit or a missing
script logs a `quality_doc_failed` warning to `build.jsonl` and does not HALT
the agent.

## Output

Writes (or updates in place) `specs/master/<domain>-quality.md`:

```
## Quality Scorecard

| Issue | Story | Tests Passing | Sensor Clean | HALTs | Last HALT | Structural Failures |
|-------|-------|---------------|--------------|-------|-----------|---------------------|
| #598  | makato-orchestrate-feat-quality-doc | 42 | Yes | 0 | - | 0 |

_Last updated: <ISO8601 UTC>. Source: build.jsonl + workflow-state._
```

### Column semantics

| Column | Source | Meaning |
|--------|--------|---------|
| **Issue** | Folder name (leading digits) | GitHub Issue number with `#` prefix |
| **Story** | Folder basename minus leading digits | Slug title |
| **Tests Passing** | Last `data.tests_passing` (numeric) from a `status:ok/green` entry in `build.jsonl` | Count of passing tests at the time of the last successful build step; `-` if absent |
| **Sensor Clean** | Last `step:gate-sensors` entry in `build.jsonl` | `Yes` when `data.findings == 0` or `data.sensor_findings == 0`; `No` when non-zero; `-` when step is absent |
| **HALTs** | Count of entries in `halt_audit[]` in `workflow-state-<N>.json` | Total number of HALT events recorded for this issue |
| **Last HALT** | `halt_audit[-1].code` | The most recent HALT code; `-` if no HALTs |
| **Structural Failures** | Count of `build-verify` entries where `status:error` or `data.all_gates_passed == false` | Number of times the full quality gate pipeline failed |

## Idempotency

Re-running the script on an existing `<domain>-quality.md` file updates only
the `## Quality Scorecard` section and the `_Last updated_` footer line in
place. All other content in the file — such as the Evolution Log written by
`archive-spec.sh` — is preserved verbatim. Running the script twice produces
exactly one scorecard section with fresh data; rows are never duplicated.

## Graceful degradation

The script always exits 0. When a `build.jsonl` is absent or unreadable for an
issue, that row shows `-` for all build-derived metrics and a warning is written
to stderr. When `workflow-state-<N>.json` is absent, the HALT columns default to
`0` / `-`. The script never crashes on missing input data.

## Test hook

`MAKATO_QUALITY_SPECS_DIR` overrides the specs directory for offline tests
(mirrors `MAKATO_REPORT_SPECS_DIR` in `generate-run-report.sh`).

## See also

- `plugins/makato-orchestrate/scripts/generate-quality-doc.sh` — the script this skill documents.
- `plugins/makato-orchestrate/scripts/generate-quality-doc-smoke-tests.sh` — 6 offline smoke-test scenarios.
- `plugins/makato-orchestrate/agents/documentation-agent.md` § *Step 7.6* — the post-merge trigger.
- `plugins/makato-orchestrate/scripts/archive-spec.sh` § `detect_domain` — the domain-detection logic reused by this script.
- `plugins/makato-orchestrate/skills/archive-spec/SKILL.md` — the archive skill that writes the Evolution Log section this script preserves.
