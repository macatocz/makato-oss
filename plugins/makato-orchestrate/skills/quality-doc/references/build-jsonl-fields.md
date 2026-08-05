# build.jsonl Field Reference for quality-doc

This is the machine-readable contract between `generate-quality-doc.sh` and the
`build.jsonl` log written by `makato-build` build steps. Load this reference when
writing downstream tools that parse the same log or when the Column Semantics table
in SKILL.md needs to be verified against the actual log format.

## Entry shape

Each line is a valid JSON object:

```json
{
  "step":    "<string>",
  "status":  "ok" | "error" | "green" | "yellow" | "red",
  "ts":      "<ISO8601 UTC>",
  "data":    { ... }
}
```

`step` and `status` are always present. `data` keys vary by step.

## Fields consumed by generate-quality-doc.sh

### Tests Passing

Read from the last entry where `status` is `"ok"` or `"green"` AND `data.tests_passing`
is a non-negative integer.

```json
{ "step": "build-verify", "status": "ok", "data": { "tests_passing": 42 } }
```

`data.tests_passing` is emitted only by TDD-mode builds (`build-implement-tdd`). Goal-mode
builds (`build-implement-goal`) do not emit this field. When absent, the column shows `-`.

### Sensor Clean

Read from the last entry where `step` is `"gate-sensors"`.

```json
{ "step": "gate-sensors", "status": "ok", "data": { "sensor_findings": 0 } }
{ "step": "gate-sensors", "status": "error", "data": { "findings": 3 } }
```

Two key names are accepted: `data.sensor_findings` (preferred, newer logs) and `data.findings`
(legacy alias). The script treats either key equal to `0` as "Yes". Non-zero → "No".
Step absent entirely → "-" (NEVER treat "-" as passing).

### Structural Failures

Count of entries where `step` is `"build-verify"` AND (`status` is `"error"` OR
`data.all_gates_passed` is `false`).

```json
{ "step": "build-verify", "status": "error", "data": { "all_gates_passed": false } }
```

Earlier failures are counted even when subsequent runs succeeded (cumulative counter).

## halt_audit[] structure in workflow-state-<N>.json

HALTs and Last HALT columns are sourced from the `halt_audit` array, not from `build.jsonl`.

```json
{
  "current_phase": "done",
  "halt_audit": [
    { "code": "HALT-003", "ts": "2026-07-15T12:00:00Z", "reason": "..." },
    { "code": "HALT-008", "ts": "2026-07-16T08:30:00Z", "reason": "outer_iterations >= 3" }
  ]
}
```

- `HALTs` column = `halt_audit | length`
- `Last HALT` column = `halt_audit[-1].code`, or "-" when array is empty or file absent
