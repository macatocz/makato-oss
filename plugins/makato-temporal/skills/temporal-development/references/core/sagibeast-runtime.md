# Sagibeast Runtime Alignment (Temporal Layer 1)

Read this before generating or reviewing Temporal workflow/activity code for the **sagibeast (CMAI)** platform. These are platform invariants, not general Temporal advice.

## Where Temporal sits

Sagibeast runs a three-layer Brain-side runtime (ADR-0005, ADR-0010, ADR-0025):

```
Layer 1 — Temporal      durable history, activity retries, cross-workflow signals, long HITL waits
Layer 2 — LangGraph     subgraph topology, node sequencing, short HITL via interrupt() + PG checkpoint
Layer 3 — harness_V1     agent runtime; skills are invoked here (never call Temporal APIs from a skill)
```

- The **only** SDK is the Python `temporalio` SDK (Python 3.14+). No TypeScript/Java/Rust in the Brain.
- A Temporal workflow is the **only** component allowed to call `run_langgraph_subgraph(subgraph_id, tenant_id, claim_id, input_state, correlation_id)`.
- Skill bodies never touch Temporal directly. Invocation chain: Temporal activity → LangGraph subgraph → `harness.run_agent` → `invoke_skill`.

## Non-negotiable invariants

### 1. Replay-determinism boundary (ADR-0029)

Anything inside an `@workflow.defn` body (including `@workflow.run` and `@workflow.signal`) must produce identical output on every replay. **No I/O, no `harness.memory` calls, no `datetime.utcnow()`, no `uuid4()`, no `random`.** Real I/O and LLM inference live behind `@activity.defn`; results are cached in event history.

Lint rule **CMAI-W001** (CI + pre-commit, Phase 8 AST lint) flags any `harness.memory` / `harness_memory` / `from harness import memory` reference inside a `@workflow.run` or `@workflow.signal` body.

### 2. Long-HITL signal/wait (Brain-Body Contract 06.3)

| HITL type | Duration | Mechanism | Owner |
|---|---|---|---|
| Short | seconds–minutes | `interrupt()` + PG checkpoint | LangGraph node |
| Long | minutes–days | Temporal `signal` + `workflow.wait_condition` | Temporal workflow |

Long human approvals (e.g. multi-party liability split) are held by the workflow, not a suspended graph.

### 3. SAGA compensation is Temporal-owned (Contract 06.2)

Compensating actions live **exclusively** in the Temporal SAGA pattern in `ClaimWorkflow` (e.g. `CancelRfqActivity`, `RetractAssessmentActivity`, `MarkQuarantineActivity`). LangGraph subgraphs and harness_V1 nodes must never issue compensation — they only return results or human-request signals.

### 4. Idempotency: correlation ID + Effects Outbox (Contracts 06.2, 06.4)

- A `correlation_id` (canonical form `{workflow_run_id}:{subgraph_id}`) makes `run_langgraph_subgraph` safe for at-least-once retry: an existing LangGraph checkpoint resumes, otherwise a fresh start.
- Any activity with external side effects uses the three-step outbox guard (order is fixed): `outbox.claim_slot(...)` → perform the effect → `outbox.commit_result(...)`. Brain-side clients: `harness/effects_outbox/`.
- Use a `RetryPolicy` with `non_retryable_error_types` such as `SkillContractViolation`, `TenantNotFound`.

### 5. Namespace per module (Contract 06.2)

Multi-tenant deployments assign one Temporal namespace per module for blast-radius isolation and independent retention (e.g. `claim-assessment-prod`, `fraud-detection-prod`).

### 6. Do not conflate the three durable stores (Architecture Overview)

Temporal event history, LangGraph Postgres checkpoint, and the harness Memory Service are intentionally distinct surfaces with distinct keys and retention. GDPR purge/export are exposed as Temporal activities so they inherit durability and replay safety.

## Source specs

Authoritative detail lives in `sagibeast/specs/Architecture/` (chapters 00, 01, 02, 06, 12, 13) and `sagibeast/specs/ADR/` (0005, 0010, 0013, 0025, 0029). Treat the specs as the source of truth if they diverge from this summary.
