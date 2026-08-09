---
name: langfuse-ops
description: >-
  OPS companion to langfuse-instrument: interact with Langfuse data and
  documentation. Use for query langfuse traces, read traces, langfuse cli
  access, langfuse docs lookup, error analysis of LLM pipelines, judge
  calibration, experiment gate for CI/CD, sdk upgrade guidance, analyze
  traces, debug llm pipeline. NOT for wiring instrumentation (use
  langfuse-instrument) and NOT for enrichment-field setup (use
  langfuse-enrich).
version: "1.0.1"
metadata:
  authors: ["makato-observability"]
  last_updated: "2026-08-05"
allowed-tools:
  - "WebFetch(domain:langfuse.com)"
  - "Bash(curl *langfuse.com/*)"
  - "Bash(curl -s -u *)"
  - "Bash(npx langfuse-cli api __schema *)"
  - "Bash(npx langfuse-cli api * --help *)"
  - "Bash(npx langfuse-cli api * list *)"
  - "Bash(npx langfuse-cli api * get *)"
  - "Bash(bunx langfuse-cli api __schema *)"
  - "Bash(bunx langfuse-cli api * --help *)"
  - "Bash(bunx langfuse-cli api * list *)"
  - "Bash(bunx langfuse-cli api * get *)"
  - "Bash(gh secret *)"
  - "Bash(gh auth *)"
  - "Bash(gh api *)"
  - "Read"
  - "AskUserQuestion"
---

# langfuse-ops

## When to Use

Use when you need to **read** Langfuse data, **look up** Langfuse documentation, **analyze** errors in a traced pipeline, **calibrate** judge scores, **gate** CI/CD experiment decisions, **upgrade** the Langfuse SDK, or **debug** a production LLM pipeline via trace queries.

**Do NOT use when:**

- The goal is to wire OTel instrumentation into a LangGraph agent — use `langfuse-instrument`.
- The goal is to configure enrichment fields (session tagging, project metadata) — use `langfuse-enrich`.
- The goal is infrastructure provisioning (Docker Compose bring-up, Helm chart install). This skill reads and queries; it does not provision.

## Core Principles

1. **Documentation-first.** Never implement Langfuse code from training-data memory — fetch current docs at point of need using the workflow in `@references/docs-lookup.md`. API shapes and defaults change across SDK versions.
2. **CLI for data access.** Prefer `npx langfuse-cli` (or `bunx langfuse-cli`) for listing, getting, and introspecting Langfuse objects over hand-rolled REST calls. Use raw `curl` only when the CLI does not cover the operation.
3. **Self-hosted / local only.** `LANGFUSE_HOST` is the primary env var. Example: `http://localhost:3000`. Never default to or suggest a specific remote host as a fallback.
4. **Latest SDK version.** Before advising on any SDK call, verify the current version via the Langfuse changelog or the package registry. Do not rely on training-data version numbers.

## Workflow

### Step 0 — Credentials

Emit a session-start audit entry before any other action:

```jsonl
{"ts":"<ISO8601>","skill":"langfuse-ops","step":"session","status":"start","data":{"triggered_by":"<request-signal>"}}
```

Load `@references/credentials.md`.

Verify that the following three env vars are set in the operator's shell before running any CLI or API command:

- `LANGFUSE_HOST` — base URL of the Langfuse instance (required, primary).
- `LANGFUSE_PUBLIC_KEY` — project public key (required).
- `LANGFUSE_SECRET_KEY` — project secret key (required).

NEVER ask the operator to paste key values into the chat. Run the connectivity check from `credentials.md` to confirm they are wired correctly. If any var is absent, halt and point the operator at `credentials.md` § *Where credentials come from*.

### Step 1 — Detect use case autonomously

Read the triggering request and route without asking if the signal is clear. Apply the **first** matching row and load exactly **one** reference — do NOT load multiple references speculatively or pre-emptively:

| Signal words in the request | Reference to load |
|---|---|
| error, traceback, exception, 500, failed span, latency spike | `@references/error-analysis.md` |
| upgrade, sdk, version, bump, migrate, breaking change | `@references/sdk-upgrade.md` |
| ci, pipeline, github actions, pre-commit, gate, threshold | `@references/ci-cd.md` |
| docs, how does, what is, explain, reference, example | `@references/docs-lookup.md` |
| score, judge, calibrate, quality, eval, rating | `@references/judge-calibration.md` |
| cli, query, traces, list, get, read, dataset, session | `@references/cli.md` |
| feedback, wrong guidance, skill bug, incorrect step | `@references/skill-feedback.md` |

**Do NOT load** any reference that does not match the current task. Do NOT load `credentials.md` again here — it was already loaded in Step 0.

If no row matches clearly, or two rows match with equal weight, use `AskUserQuestion` as the declared fallback only:

> **"Which task do you need help with?"**
>
> 1. Error analysis — diagnose failed or slow traces
> 2. SDK upgrade — safely upgrade the Langfuse SDK
> 3. CI/CD — use trace scores as experiment gates
> 4. Docs lookup — fetch and interpret Langfuse documentation
> 5. Judge calibration — review or tune scorer quality
> 6. CLI / data access — query traces, sessions, datasets
> 7. Skill feedback — report incorrect guidance in this skill

### Step 2 — Execute routed reference workflow

Follow the numbered steps in the loaded reference file. If the reference requires credentials not yet verified, return to Step 0 before proceeding.

After the routed-reference workflow completes, emit one JSONL audit entry for the operation executed:

```jsonl
{"ts":"<ISO8601>","skill":"langfuse-ops","step":"route","status":"ok","data":{"reference":"<loaded-reference-filename>"}}
```

Then emit a session-end entry:

```jsonl
{"ts":"<ISO8601>","skill":"langfuse-ops","step":"session","status":"ok","data":{"reference":"<loaded-reference-filename>","completed":true}}
```
