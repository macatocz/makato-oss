# Decision D16: Phase-Detection Contract — RESOLVED

**Status**: RESOLVED
**Date**: 2026-08-11
**Issue**: #3 (Phase-0 spike)
**Supersedes**: D16 entry in `specs/makato-harness-independence/decisions.md` (PENDING)

## Decision

**Option B — state-file-only** is the chosen phase-detection contract for omp dispatch.

## Options Evaluated

### Option A — RPC-adapter

The harness (omp) exposes an RPC or streaming endpoint. The po-agent opens a connection to this endpoint and receives terminal events (`NDJSON` lines, SSE stream, or WebSocket messages) signalling when a session completes, errors, or emits a resume handle.

**Rejected because**:
- Requires a stable, versioned omp RPC contract that does not yet exist in the oh-my-pi codebase.
- Adds a network dependency inside the po-agent outer loop (TCP socket, connection management, timeout handling).
- The existing state-file contract already provides all required information; adding an RPC layer is redundant.
- If omp's RPC changes between versions, the po-agent outer loop breaks silently.

### Option B — state-file-only

Phase detection is performed exclusively via `workflow-state.json` and `orchestrate.jsonl`. The po-agent reads `current_phase`, `github_pr_number`, and the tail of `orchestrate.jsonl` (`step:"session" status:"ok|error"`) at every outer-loop boundary. No omp process introspection is required.

**Chosen because**:
- The `workflow-state.sh` + `orchestrate.jsonl` audit trail is already operational in the Claude Code baseline and carries all state required for resume and phase determination.
- The `context-handoff.sh` HALT-007B resumption pattern proves that state-file-based session resumption is already end-to-end tested (T1–T15 smoke tests).
- Porting to omp requires only replacing `claude --resume <handle>` with `omp --yolo -p --resume <session-id>` in `scripts/context-handoff.sh` and `scripts/functions.sh`. The state-file contract is harness-agnostic.
- No new protocol or process monitoring is introduced.

## Terminal Event Shape

The terminal NDJSON event emitted by omp at session end follows this structure (captured from omp design docs; live validation deferred to S1):

```json
{"type": "result", "subtype": "success", "session_id": "<uuid>", "result": "...", "total_cost_usd": 0.0}
```

or on error:

```json
{"type": "result", "subtype": "error_max_turns", "session_id": "<uuid>", "is_error": true}
```

The `session_id` field is the resume handle, used as `omp --yolo -p --resume <session_id>`.

## Implementation Note for `context-handoff.sh`

The `_emit_resume` function in `scripts/context-handoff.sh` currently writes:

```bash
claude --dangerously-skip-permissions -p --resume "$SESSION_ID" "$PROMPT"
```

This must be updated to:

```bash
omp --yolo -p --resume "$SESSION_ID" "$PROMPT"
```

The `SESSION_ID` is extracted from the terminal NDJSON event line captured in the run log. The state-file (`resume_point`, `handoff_reason`) remains the source of truth; the omp session-id is the transport mechanism for resumption.

## Confidence

High. The state-file contract is harness-agnostic by construction. The omp terminal event shape is documented in the oh-my-pi README and confirmed by the design phase analysis. Live smoke-test is scheduled for S1 (issue #4).
