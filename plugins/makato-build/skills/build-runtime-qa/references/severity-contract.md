# runtime-qa Severity Contract

> MANDATORY reference for `build-runtime-qa` Step 3 (dispatch) and Step 4 (parse/route).
> Do NOT load this reference for other skills — it is specific to the runtime-qa agent contract.

## Severity rubric (sourced from `agents/runtime-qa.md`)

| Severity | Condition | Build effect |
|----------|-----------|--------------|
| CRITICAL | App crashes, returns 5xx, or the core AC outcome is NOT achievable at all | Blocks `build-push-to-git` (R1 `status: "failure"`, HALT `RUNTIME_QA_BLOCKED`) |
| MAJOR | AC is achievable but with degraded UX — missing UI element, wrong data, error shown | Advisory — logged to `build.jsonl` as `status: "warn"`, build proceeds |
| ADVISORY | Minor cosmetic / UX issue that does not block the AC outcome | Advisory — logged as `status: "warn"`, build proceeds |

Key distinction: CRITICAL means the feature is **not shippable** as-is; MAJOR/ADVISORY means it is shippable but noted for follow-up.

## Why parse failure is advisory, not CRITICAL

The `runtime-qa` agent emits the R1 block as the **last** fenced ` ```json ` block in its output. In rare
multi-model or context-exhaustion conditions the model may truncate that final block or produce trailing prose
after the R1 marker. Because agent output is non-deterministic, a malformed or missing R1 does not constitute
evidence that any runtime AC failed — it is simply a transport failure. Treating parse failure as CRITICAL
would silently block a clean build whenever the model hiccups. The correct response is to log a `step:
"parse-failure"` warn entry to `build.jsonl` and return R1 `success` so the pipeline can proceed.

The only safe CRITICAL block source is an explicit `"status": "failure"` with `errors[]` containing
`"CRITICAL: …"` entries in a *successfully parsed* R1 envelope.

## R1 envelope examples for this skill

### Successful run (2 ACs exercised, 0 CRITICAL)

```json
{
  "schema": "r1",
  "agent": "runtime-qa",
  "status": "success",
  "summary": "2 paths exercised; 0 CRITICAL, 1 MAJOR, 0 advisory findings.",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 14,
  "data": {
    "skipped": false,
    "skip_reason": null,
    "paths_exercised": 2,
    "findings_total": 1,
    "findings_critical": 0,
    "findings_major": 1,
    "findings_advisory": 0,
    "runtime_cmd": "uvicorn app.main:app --port 8000"
  }
}
```

### CRITICAL failure (1 AC not achievable)

```json
{
  "schema": "r1",
  "agent": "runtime-qa",
  "status": "failure",
  "summary": "3 paths exercised; 1 CRITICAL, 0 MAJOR, 1 advisory finding.",
  "files_changed": [],
  "tests_written": [],
  "errors": ["CRITICAL: POST /api/orders returns 500 — core AC-2 outcome not achievable"],
  "tool_calls_used": 22,
  "data": {
    "skipped": false,
    "skip_reason": null,
    "paths_exercised": 3,
    "findings_total": 2,
    "findings_critical": 1,
    "findings_major": 0,
    "findings_advisory": 1,
    "runtime_cmd": "node server.js"
  }
}
```

### Clean skip (no runtime surface)

```json
{
  "schema": "r1",
  "agent": "runtime-qa",
  "status": "success",
  "summary": "No runtime surface detected; skipping.",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 3,
  "data": {
    "skipped": true,
    "skip_reason": "no-runtime-surface",
    "paths_exercised": 0,
    "findings_total": 0,
    "findings_critical": 0,
    "findings_major": 0,
    "findings_advisory": 0,
    "runtime_cmd": null
  }
}
```

## Logging the R1 to build.jsonl

After routing the R1 result in Step 4, append the full envelope as a JSONL line per
`agents/RETURN-CONTRACT.md § Audit-log integration`:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO>","skill":"build-runtime-qa","story":"<key>","step":"r1","status":"<r1.status>","data":<entire-r1-envelope>}'
```
