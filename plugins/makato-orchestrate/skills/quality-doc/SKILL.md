---
name: quality-doc
description: >-
  Generate a per-domain quality scorecard (specs/master/<domain>-quality.md)
  from build.jsonl and workflow-state HALT audit data across all spec folders
  whose plan.md or spec.md frontmatter carries a matching domain: field. Writes
  a Quality Scorecard table (Tests Passing, Sensor Clean, HALTs, Last HALT,
  Structural Failures) and updates that section in place without disturbing
  other sections such as the Evolution Log. Use when: reviewing build health
  after a sprint, auditing a domain before assigning new stories, regenerating a
  scorecard after quality_doc_failed appears in build.jsonl, or running a
  one-off domain health check on demand. Triggers: quality scorecard, generate
  quality doc, build quality report, domain quality, regenerate scorecard.
version: 1.2.0
argument-hint: "--domain <name> [--specs-dir <path>]"
metadata:
  authors: [makato-orchestrate]
  last_updated: "2026-08-05"
---

# quality-doc

Generate a per-domain quality scorecard that aggregates build health metrics
across all issues in a domain into a single `specs/master/<domain>-quality.md`
file. The scorecard is the canonical read-only view of build quality for a
domain; it is updated automatically after each PR merge (via
`documentation-agent` Step 7.6) and can be regenerated on demand at any time.

## Diagnostic Mental Model

The scorecard and `build.jsonl` serve different purposes and must not be
conflated:

- **Scorecard = signal**: tells you *that* something is wrong across a domain
  (e.g. Sensor Clean = `-` on three issues, HALTs ≥ 3 on one issue).
- **`build.jsonl` = diagnosis**: tells you *what* is wrong for a single issue
  (failing test name, specific pre-commit finding, HALT reason string).

Always use the scorecard first to triage, then open the specific issue's
`build.jsonl` for root cause. Regenerating the scorecard does not fix anything
— it only updates the aggregate view.

## Invocation Timing — Decision Tree

```
Was quality_doc_failed logged in build.jsonl?
  YES → Run on demand immediately (Step 7.6 failed silently; see Troubleshooting)
  NO  → Was the domain scorecard last updated before the most recent PR merge?
          YES → Run on demand to refresh stale data
          NO  → documentation-agent already updated it; no action needed

Are you auditing before assigning new stories to a domain?
  YES → Run on demand with --domain <name>; check Structural Failures + HALT counts first
  NO  → documentation-agent post-merge trigger is sufficient

Do you need a full domain sweep (all domains in one pass)?
  YES → See Multi-domain sweep below
  NO  → Single --domain invocation
```

## Invocation Modes

### Operator-invoked (on demand)

Run from `REPO_ROOT`:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
python3 "$REPO_ROOT/plugins/makato-orchestrate/scripts/generate_quality_doc.py" \
  --domain <name>
```

Optional: override the specs directory (defaults to `$REPO_ROOT/specs`):

```bash
python3 "$REPO_ROOT/plugins/makato-orchestrate/scripts/generate_quality_doc.py" \
  --domain <name> --specs-dir /path/to/specs
```

The `--domain` argument is required. Use `general` for issues whose `plan.md`
carries no `domain:` frontmatter field.

### Post-merge trigger (automated)

`documentation-agent` Step 7.6 calls `generate_quality_doc.py --domain
<domain>` automatically after every PR merge. The domain is derived from the
merged issue's `plan.md` frontmatter using the same `detect_domain` logic as
`archive-spec.sh`. This call is **best-effort**: a non-zero exit or a missing
script logs a `quality_doc_failed` warning to `build.jsonl` and does not HALT
the agent.

> MANDATORY: load `plugins/makato-orchestrate/agents/documentation-agent.md`
> § *Step 7.6* when you need to understand when and how `quality_doc_failed` is
> written, or when debugging why the automated post-merge pass did not run.

### Multi-domain sweep

To regenerate scorecards for every domain in one pass:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
# Collect unique domain values from all plan.md frontmatters
for domain in $(grep -rh '^domain:' "$REPO_ROOT/specs"/*/plan.md 2>/dev/null \
    | sed 's/^domain:[[:space:]]*//' | sort -u); do
  echo "=== domain: $domain ==="
  python3 "$REPO_ROOT/plugins/makato-orchestrate/scripts/generate_quality_doc.py" \
    --domain "$domain"
done
# Issues with no domain: frontmatter fall under 'general'
python3 "$REPO_ROOT/plugins/makato-orchestrate/scripts/generate_quality_doc.py" \
  --domain general
```

Note: `detect_domain` in the script reads `domain:` from `plan.md` or `spec.md`
using the same `sed` pattern. The grep above extracts the same values, so
the sweep and the script are aligned.

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
| **Sensor Clean** | Last `step:gate-sensors` entry in `build.jsonl` | `Yes` when `data.findings == 0` or `data.sensor_findings == 0`; `No` when non-zero; `-` when step is **absent** (gate never ran) |
| **HALTs** | Count of entries in `halt_audit[]` in `workflow-state-<N>.json` | Total number of HALT events recorded for this issue |
| **Last HALT** | `halt_audit[-1].code` | The most recent HALT code; `-` if no HALTs |
| **Structural Failures** | Count of `build-verify` entries where `status:error` or `data.all_gates_passed == false` | Number of times the full quality gate pipeline failed; earlier failures are counted even when subsequent runs succeeded |

> MANDATORY: load `references/build-jsonl-fields.md` when writing downstream
> tooling that parses these same log fields, or when a column value looks
> wrong and you need to verify the exact key names and selection logic.

### Interpreting the scorecard

| Signal | Threshold | Recommended action |
|--------|-----------|-------------------|
| Sensor Clean = **`-`** | Any | `gate-sensors` never ran — issue was halted or failed before reaching that step. Inspect Last HALT column. `-` is NOT a passing state. |
| Sensor Clean = **`No`** | Any | Sensors found findings in the build run. Open the issue's `build.jsonl`, find the last `gate-sensors` entry, and inspect `data.findings` for the finding list. |
| **HALTs ≥ 3** | ≥ 3 for one issue | PO-agent likely hit HALT-008 (`outer_iterations >= 3`). The issue probably carries `needs-human-review`; verify and assign an operator to unblock. |
| **Structural Failures ≥ 1** | ≥ 1 | `build-verify` failed at least once. Confirm the final committed run has `status:ok` and `data.all_gates_passed: true`; accumulated counts include intermediate failures. |
| Tests Passing = **`-`** | Any | No `status:ok/green` entry with a numeric `tests_passing` exists. Issue may have been built in goal mode (which does not always emit `tests_passing`) or build.jsonl is incomplete. |

## Idempotency

Re-running the script on an existing `<domain>-quality.md` file updates only
the `## Quality Scorecard` section and the `_Last updated_` footer line in
place. All other content in the file — such as the Evolution Log written by
`archive-spec.sh` — is preserved verbatim. The section-replace logic identifies
the section boundary by searching for `## Quality Scorecard` as the start and
`_Last updated:` as the end sentinel; content outside those markers is never
touched. Running the script twice produces exactly one scorecard section with
fresh data; rows are never duplicated.

> MANDATORY: load `plugins/makato-orchestrate/skills/archive-spec/SKILL.md`
> when coordinating the full content of `<domain>-quality.md` — specifically
> when the Evolution Log section written by `archive-spec.sh` and the
> Scorecard section written by this script must coexist correctly after
> sequential runs.

## Graceful degradation

The script always exits 0. When a `build.jsonl` is absent or unreadable for an
issue, that row shows `-` for all build-derived metrics and a warning is written
to stderr. When `workflow-state-<N>.json` is absent, the HALT columns default to
`0` / `-`. The script never crashes on missing input data. The python3 parser
skips individual corrupted (non-JSON) lines in `build.jsonl` without aborting;
only a completely unreadable file produces all-dash output for that row.

## Anti-patterns

**NEVER interpret Sensor Clean = `-` as "sensor clean"**

`-` means the `gate-sensors` step is absent from `build.jsonl` — the issue was
halted or aborted before that phase ran. `Yes` is the only value that confirms a
clean sensor pass. Misreading `-` as "passed" masks entire categories of findings
for an issue, hiding real pre-commit failures from domain-wide audits.

**NEVER regenerate the scorecard while the PO-agent is actively processing an issue in the same domain**

The script reads all `build.jsonl` entries at point-in-time in a single python3
pass. If the PO-agent is mid-build, it is still appending entries to `build.jsonl`.
The resulting scorecard will show partial metrics — `tests_passing` may reflect a
mid-task checkpoint, not the final gate result; `sensor_clean` may show the state
before the last gate-sensors run. Wait until `workflow-state-<N>.json` shows
`current_phase: "done"` before regenerating.

**NEVER pass a `--domain` value that differs in case or hyphenation from what `plan.md` frontmatter declares**

`detect_domain` matches the `domain:` field verbatim via `sed`. Passing
`--domain orchestrate` when frontmatter declares `domain: makato-orchestrate`
produces an empty scorecard — zero rows — and exits 0. The empty file is written
silently with no error. Verify the exact values in use before running:

```bash
grep -rh '^domain:' "$(git rev-parse --show-toplevel)"/specs/*/plan.md \
  | sed 's/^domain:[[:space:]]*//' | sort -u
```

**NEVER use the scorecard to diagnose individual build failures**

The scorecard aggregates final-state metrics; it does not preserve the failure
message, the specific failing test name, or the pre-commit tool output. For root
cause analysis, open the issue's `build.jsonl` directly and filter for
`status:error` entries. The scorecard signals *that* something is wrong; `build.jsonl`
tells you *what*.

**NEVER assume Structural Failures = 0 means the build always passed cleanly**

The counter increments only for `build-verify` entries. A build that halted
before reaching `build-verify` (e.g. HALT-003 on the implement step) contributes
0 to Structural Failures despite never completing. Combine the Structural Failures
and HALTs columns together to assess overall build health.

## Test hook

`MAKATO_QUALITY_SPECS_DIR` overrides the specs directory for offline tests
(mirrors `MAKATO_REPORT_SPECS_DIR` in `generate-run-report.sh`). The 6 pytest
scenarios in `tests/test_generate_quality_doc.py` cover: empty domain (T1),
full happy-path row (T2), sensor findings (T3), halt_audit entries (T4),
idempotency with preserved Evolution Log (T5), and absent `build.jsonl` (T6).

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| Empty scorecard (no data rows) | `--domain` value does not match any `domain:` frontmatter verbatim | Run `grep -rh '^domain:' specs/*/plan.md \| sed 's/^domain:[[:space:]]*//' \| sort -u` to list exact valid names |
| `quality_doc_failed` in documentation-agent `build.jsonl` | Script exited non-zero during Step 7.6 post-merge pass | Run script manually and capture stderr (`bash ... --domain <name> 2>&1`) to read the failing step; common cause is `SPECS_DIR` not found |
| All rows show `-` for Tests Passing | Build ran in goal mode or build log is incomplete | Confirm `build.jsonl` has at least one `status:ok` or `status:green` entry with numeric `data.tests_passing`; goal-mode builds omit this field by design |
| Sensor Clean shows `-` for a merged issue | `gate-sensors` step never ran; issue halted before that phase | Inspect Last HALT column; HALT-003 or HALT-007 are common causes |
| Scorecard rows not updating after re-run | Git checkout is behind — `build.jsonl` on disk is stale | Run `git -C "$(git rev-parse --show-toplevel)" pull --ff-only` then rerun the script; if a merge conflict prevents fast-forward, run `git fetch origin && git reset --hard origin/<branch>` (confirm no uncommitted local changes first) |

## Do NOT Load This Skill When

- Debugging a specific failing test or build error — open `build.jsonl` directly;
  this skill documents a read-only aggregate, not a repair tool.
- Verifying spec folder structure or archiving specs — use `archive-spec/SKILL.md`.

## See also

- `plugins/makato-orchestrate/scripts/generate_quality_doc.py` — the script this skill documents.
- `plugins/makato-orchestrate/scripts/tests/test_generate_quality_doc.py` — 6 offline pytest scenarios.
- `references/build-jsonl-fields.md` — exact field names, key aliases, and halt_audit structure consumed by the script.
