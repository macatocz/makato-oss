---
name: analyze-log
description: >-
  Render a human-readable audit report from build.jsonl — audit trail, per-phase
  time totals, token breakdown, model distribution, deduplicated critical findings.
  Use when debugging an autonomous run or reviewing build session performance.
version: "1.0.1"
argument-hint: "[story-key | path/to/build.jsonl] [--since <date>] [--save] [--output <path>] [--jira]"
allowed-tools: Bash Read Write Grep Glob
metadata:
  last_updated: "2026-09-25"
---

# Analyze Log

Render a human-readable audit report from a `build.jsonl` file. Produces an audit trail
table, per-phase time breakdown, token usage from telemetry entries, model distribution,
and deduplicated critical findings.

## When to Use

- Debugging why an autonomous run failed or took too long
- Reviewing build session performance and token costs
- Auditing which skills ran, in what order, with what outcomes
- Posting a run summary to Jira for stakeholder visibility

## When NOT to Use

- Actively running a build (the log is still being written)
- Want to modify or replay the build (this is read-only analysis)

---

## Flags

| Flag | Description |
|------|-------------|
| `--since <date>` | Filter entries after this ISO 8601 date (default: all entries) |
| `--save` | Write the report to `specs/<key>/build-report.md` |
| `--output <path>` | Write the report to a custom path |
| `--jira` | Post the report as a Jira comment (requires explicit user confirmation) |

---

## Reference Loading

Load @references/log-schema.md — MANDATORY. Documents all JSONL entry types consumed.

---

## Workflow

### Step 1: Locate the Log File

Accept input in order of precedence:

1. **Direct path**: if arg ends in `.jsonl`, use it directly.
2. **Story key**: resolve `specs/<key>-*/build.jsonl` (same prefix-match as `build-log.sh`).
3. **No arg**: auto-detect most recently modified `specs/*/build.jsonl`:
   ```bash
   ls -t specs/*/build.jsonl | head -1
   ```

If the file does not exist, report:

> "No build.jsonl found at {path}. Run a build first or provide the correct story key."

Exit gracefully — do not crash.

### Step 2: Parse Entries

Read all JSONL entries. For each line:

1. Parse as JSON (skip malformed lines with a warning count).
2. Apply `--since` filter if provided.
3. Group entries by session (match by `skill` name + timestamp order, NOT by `session_id`
   which rotates on reconnect).

### Step 3: Build Audit Trail Table

For each session, produce a row:

| Skill | Step | Status | Duration | Model | Retries |
|-------|------|--------|----------|-------|---------|

- **Duration**: calculated from `ts` differences between session `start` and session `ok`/`error`.
- **Retries**: count sessions with the same `skill` + `story` that have a `status: error`
  followed by a later `status: ok` (the `↩` retry marker).
- **Model**: from the `model` field (auto-injected by `build-log.sh` per S4).

### Step 4: Per-Phase Time Totals

Aggregate durations by phase:

| Phase | Total Duration | Sessions | Avg Duration |
|-------|---------------|----------|--------------|
| refine | | | |
| implement | | | |
| simplify | | | |
| review | | | |
| verify | | | |
| push | | | |
| pr | | | |
| change | | | |

Map skills to phases using the skill-to-phase mapping in `references/log-schema.md`.

### Step 5: Token Breakdown (from telemetry entries)

If `telemetry` entries exist in the log:

| Model | Input Tokens | Output Tokens | Total | Estimated Cost |
|-------|-------------|---------------|-------|---------------|

Group by `model` field. Sum `input_tokens` and `output_tokens` from telemetry entries.

If no telemetry entries exist, note: "No telemetry data — token breakdown unavailable."

### Step 6: Model Distribution

Count entries per model:

| Model | Entry Count | % of Total |
|-------|------------|-----------|

### Step 7: Critical Findings (Deduplicated)

Collect all entries where `step` contains `critical-finding` or `data` contains severity
`CRITICAL`. Deduplicate by `description` or `data.finding` content (keep first occurrence).

| # | Finding | Skill | Resolved? |
|---|---------|-------|-----------|

A finding is "resolved" if a later session for the same skill has `status: ok` after the
finding was recorded.

### Step 8: Render Report

Combine Steps 3-7 into a formatted markdown report. Display in chat.

If `--save` or `--output` was specified, write to file:

```bash
REPORT_PATH="specs/<key>/build-report.md"  # or custom --output path
```

If `--jira` was specified:

```text
AskUserQuestion:
  question: "Post this report as a comment on {STORY_KEY}?"
  options:
    - "Yes — post to Jira"
    - "No — skip Jira posting"
```

Only post after explicit confirmation.

### Step 9: Summary

```text
Build Log Analysis Complete:
  - Sessions: {N}
  - Total Duration: {HH:MM:SS}
  - Models Used: {list}
  - Critical Findings: {N} ({N} resolved)
  - Retries: {N}
  - Malformed Lines Skipped: {N}
```
