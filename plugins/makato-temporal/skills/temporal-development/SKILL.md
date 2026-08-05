---
name: temporal-development
description: >-
  Develop, debug, and manage Temporal applications across Python, TypeScript,
  Java, and Rust. Use when the user is building workflows, activities, or
  workers with a Temporal SDK, debugging issues like non-determinism errors,
  stuck workflows, or activity retries, using Temporal CLI, Temporal Server, or
  Temporal Cloud, or working with durable execution concepts like signals,
  queries, heartbeats, versioning, continue-as-new, child workflows, or saga
  patterns. Also use when the user mentions "run a Temporal workflow from the
  CLI", "start a dev server", "run temporal server start-dev", "temporal
  workflow start", "temporal workflow execute", "temporal workflow signal",
  "temporal workflow query", "temporal workflow update".
version: 0.8.0
metadata:
  Authors: makato-temporal
  last_updated: 2026-08-05
argument-hint: "<task description, e.g. 'debug Python workflow non-determinism' or 'build TypeScript saga with compensation'>"
---

# Skill: temporal-development

Python is the canonical SDK for the sagibeast (CMAI) durable-execution runtime — see § Sagibeast Runtime Alignment before generating any workflow code for that platform.

## Temporal Durable-Execution Mindset

Before generating or reviewing any workflow code, apply **replay-first thinking**: mentally execute every line of workflow code *twice* — once on first run, once on replay after a Worker restart. Any value that differs between those two executions is a latent non-determinism bug that will surface only in production, never in local unit tests. This is the non-obvious cognitive model that separates Temporal-proficient code from code that merely passes tests.

The second non-obvious frame: **activity boundaries are the serialization fence**. I/O, external calls, non-deterministic operations, and heavy computation belong in Activities — not because it is "cleaner" but because the Event History records activity outputs, not inputs. Crossing the fence wrong (I/O inside the workflow, business logic inside the worker's main loop) breaks replay-ability in ways that corrupt the persisted history and cannot be repaired by redeployment alone.

These two frames should govern every code-review and code-generation decision in this skill.

---

## Entry Decision Tree

Classify the task first to load only the references you need:

| Task type | References to load |
|-----------|-------------------|
| Write or review workflow / activity code | MANDATORY: `core/determinism.md` + `{language}/determinism.md` |
| Debug non-determinism / stuck workflow | `core/troubleshooting.md` + `core/error-reference.md` |
| Change code on a running workflow | MANDATORY: `core/versioning.md` + `{language}/versioning.md` |
| Signals / queries / updates / saga | `core/patterns.md` + `{language}/patterns.md` |
| Write or review workflow tests | MANDATORY: `{language}/testing.md` |
| CLI workflow interaction only | `core/cli-workflow-commands.md` only |
| Multi-tenant or tiered workload | `core/priority-fairness.md` (see § Task Queue Priority) |
| Sagibeast (CMAI) platform | MANDATORY: `core/sagibeast-runtime.md` FIRST |
| Integrating AI / LLM workloads | `core/ai-patterns.md` + `{language}/ai-patterns.md` (Python only for language variant) |

**Unsupported language** (not Python / TypeScript / Java / Rust): Use AskUserQuestion to surface the limitation with selectable options — e.g. "The makato-temporal plugin carries guides for Python, TypeScript, Java, and Rust only. Which of these is closest to your target, or should I work from general Temporal documentation?" Do not generate code for other languages from training-data assumptions alone.

**Rust SDK note:** Rust is Public Preview. The Rust references are consolidated in a single file (`references/rust/rust.md`). For Rust, all `{language}/*` patterns in this skill (determinism, patterns, versioning, gotchas, testing) resolve to `rust/rust.md` — per-topic sub-files do not exist for Rust yet. Load `rust/rust.md` first and note any gaps explicitly to the user.

In all other reference paths, replace `{language}` with: `python`, `typescript`, or `java`.

---

## Anti-patterns

The following failures surface only during replay or in production — never during initial local execution. Each has a non-obvious root cause that experience alone teaches.

**NEVER call `datetime.now()`, `random.*`, `uuid4()`, or perform any I/O inside a `@workflow.defn` / `@WorkflowMethod` / workflow class.**
WHY: Workflow code executes twice — once on first run, and again on every replay after a Worker restart or failure. A non-deterministic call produces a different value on replay than during first execution, yielding a Command that does not match the stored Event. The result is a `NonDeterministicError` that permanently blocks the workflow run. The SDK cannot self-repair this; the only resolution is patching the workflow definition or terminating the affected runs. Use Temporal's replay-safe equivalents: `workflow.now()`, `workflow.random()`, `workflow.uuid4()`.

**NEVER modify workflow state inside a query handler or update validator.**
WHY: Queries and update validators execute outside the workflow event-loop serialization. Mutations made there are invisible to the workflow's state machine during replay — the state diverges silently, producing inconsistent results that are difficult to reproduce and impossible to audit from the event history. Use Updates (not Queries) when a state change plus a return value are both needed.

**NEVER deploy the Temporal dev server in production, even with `--db-filename`.**
WHY: `--db-filename` only persists the SQLite backing store across restarts; it does not add replication, auth, TLS, or reliability. The dev server is a single-process binary with no production-grade guarantees. Running it in production means all workflow history is destroyed on host failure. Use self-hosted Temporal or Temporal Cloud for production.

**NEVER call an external service from an Activity without an idempotency key.**
WHY: Temporal retries Activities on failure by default (unlimited attempts). If the external call succeeds but the Activity fails before returning the result, Temporal retries the Activity — re-executing the external call with no idempotency guard causes double charges, duplicate emails, duplicate records. Use workflow ID + activity ID + attempt, or a domain-scoped key (e.g. order ID), as the idempotency token.

**NEVER use `temporal workflow update` as a bare command.**
WHY: `update` is a command group, not a leaf command; running it alone exits with an error. Use the correct subcommand: `update execute` (start and await completion), `update start --wait-for-stage accepted` (fire and await acceptance; `completed` is not a valid `--wait-for-stage` value — only `accepted` is), `update result` (poll a running update), or `update describe` (inspect status).

**NEVER add workflow logic branches that were not present when a workflow run started — without using the Patching API.**
WHY: Adding a new `if` / `elif` / `when` branch, removing an existing one, or changing the *order* of commands in a workflow reorders the Command sequence the SDK emits during replay. Even a branch that the current run never takes can corrupt the replay by shifting the positions of subsequent Commands in the Event History. The Patching API (`workflow.patched()` in Python, `patched()` in TypeScript, `Workflow.getVersion()` in Java) inserts a marker event that lets old and new code paths coexist during the drain window.

---

## Step 1: Ensure Temporal CLI is Installed

Check if `temporal` is on the PATH. If not, follow `references/core/install_cli.md` for platform-specific installation steps.

---

## Step 2: Load the Language Guide

Read the getting-started guide for the target language:

- Python → `references/python/python.md`
- TypeScript → `references/typescript/typescript.md`
- Java → `references/java/java.md`
- Rust → `references/rust/rust.md` (Public Preview — all Rust-specific guidance in one file)

---

## Step 3: Load Scenario-Specific References

Load references **at point of use** — do not front-load the full reference library on every invocation.

### MANDATORY Triggers

**Writing or reviewing any workflow / activity code:**
Load `references/core/determinism.md` + `references/{language}/determinism.md` before generating code. Non-determinism bugs permanently block running workflow instances and cannot be resolved by redeploying workers alone.
Also load `references/core/gotchas.md` + `references/{language}/gotchas.md` as a post-generation checklist — these contain symptoms, SDK-specific traps, payload limits, and the Query/Signal/Update decision table.

**Changing existing workflow code that is running in production:**
Load `references/core/versioning.md` + `references/{language}/versioning.md`. Versioning mistakes corrupt live workflow histories irreversibly.

**Writing or reviewing workflow tests:**
Load `references/{language}/testing.md`. Temporal's test suite needs a `TestWorkflowEnvironment` (Python/TypeScript) or `TestWorkflowExtension` (Java) — standard mocking frameworks do not intercept Temporal's task scheduling, so tests that skip the test environment produce false-green results and miss replay assertions.

**Implementing signals, queries, updates, saga, child workflows, or compensation:**
Load `references/core/patterns.md` + `references/{language}/patterns.md`. The Query / Signal / Update triad has constraints that produce silent failures — see Anti-patterns above.

**Debugging a stuck, failed, or non-deterministic workflow:**
Load `references/core/troubleshooting.md` + `references/core/error-reference.md`.

**Testing signals, updates, or queries interactively:**
Load `references/core/interactive-workflows.md`.

**Managing the dev server, local workers, or the developer cycle:**
Load `references/core/dev-management.md`.

**CLI workflow interaction (start, execute, signal, query, update, reset):**
Load `references/core/cli-workflow-commands.md`.

**Integrating AI / LLM workloads with Temporal (agent orchestration, LLM calls inside workflows):**
Load `references/core/ai-patterns.md`. If the target language is Python, also load `references/python/ai-patterns.md`. The core version covers SDK-agnostic patterns (activity-scoped LLM calls, heartbeat-during-inference, retry policies for flaky LLM APIs, saga compensation for multi-step AI pipelines); the Python file adds temporalio-specific implementation details and sagibeast integration patterns.

### On-Demand References (load only when the user asks)

- `references/{language}/observability.md` — load only if the user asks about metrics, tracing, or Temporal logging.
- `references/{language}/advanced-features.md` — load only if the user asks about language-specific advanced SDK features.
- `references/integrations.md` + `references/{language}/integrations/` — load only if the user asks about a specific third-party framework (Spring Boot, Spring AI, OpenAI Agents SDK, Google ADK, LangGraph).
- `references/{language}/data-handling.md` — load only if the user asks about payload serialization, data converters, codec servers, or encryption of workflow payloads.
- `references/{language}/error-handling.md` — load only if the user asks about activity error propagation, retry policy tuning, `ApplicationError` vs `CancelledError`, or exception mapping between SDK layers.
- `references/{language}/determinism-protection.md` — load only if the user asks about linting rules, static analysis, or automated non-determinism detection tooling (supplements `determinism.md`).
- `references/python/sync-vs-async.md` — Python only: load if the user asks whether to use `@activity.defn` sync vs async, thread executor vs asyncio worker, or `to_thread` / `run_in_executor` patterns.
- `references/python/workflow-streams.md` — Python only: load if the user asks about streaming data into or out of a running Python workflow (Update-based streaming patterns).
- `references/{language}/standalone-activities.md` — load only if the user is evaluating or building standalone Activity execution without a parent Workflow (Public Preview feature).

---

## Primary Reference Index

| Reference | Covers |
|-----------|--------|
| `references/core/determinism.md` + `references/{language}/determinism.md` | Replay mechanics, determinism rules, activity boundaries |
| `references/core/gotchas.md` + `references/{language}/gotchas.md` | Anti-patterns with symptoms and fixes; Query/Signal/Update decision table; payload limits |
| `references/core/patterns.md` + `references/{language}/patterns.md` | Signals, queries, updates, saga, child workflows, continue-as-new |
| `references/core/versioning.md` + `references/{language}/versioning.md` | Safe code-change strategies, patching APIs, Worker Versioning |
| `references/core/troubleshooting.md` | Decision trees for stuck / failed / non-deterministic workflows |
| `references/core/error-reference.md` | Common error types, workflow status reference |
| `references/core/interactive-workflows.md` | Testing signals, updates, queries interactively |
| `references/core/dev-management.md` | Dev server flags, persistence, worker lifecycle |
| `references/core/cli-workflow-commands.md` | start, execute, signal, query, update, reset |
| `references/core/ai-patterns.md` | SDK-agnostic AI/LLM-inside-Temporal patterns (heartbeat, retry, saga for AI pipelines) |
| `references/core/standalone-activities.md` + `references/{language}/standalone-activities.md` | Run an Activity without a Workflow (Public Preview) |
| `references/core/priority-fairness.md` | Fairness keys, weights, rate limiting — see § below |
| `references/core/sagibeast-runtime.md` | Sagibeast-platform invariants — see § below |
| `references/{language}/testing.md` | Test environment setup, workflow replay tests, activity mocking |
| `references/{language}/data-handling.md` | Payload serialization, data converters, codec servers |
| `references/{language}/error-handling.md` | Error propagation, retry policy, ApplicationError, exception mapping |
| `references/{language}/determinism-protection.md` | Linting rules, static analysis, automated non-determinism detection |
| `references/{language}/observability.md` | Metrics, tracing, logging — load on demand |
| `references/{language}/advanced-features.md` | Language-specific advanced SDK features — load on demand |
| `references/python/sync-vs-async.md` | Python sync vs async activity and worker configuration |
| `references/python/workflow-streams.md` | Streaming data into/out of a running Python workflow |
| `references/python/ai-patterns.md` | Python-specific AI/LLM patterns, sagibeast integration |
| `references/integrations.md` | Third-party integration catalog — load on demand |
| `references/rust/rust.md` | Consolidated Rust SDK guide (Public Preview) |

---

## Rust SDK — Consolidated Reference Notice

The Rust SDK is in Public Preview. Unlike Python, TypeScript, and Java — each of which has per-topic reference files (`determinism.md`, `patterns.md`, `versioning.md`, `gotchas.md`, `testing.md`) — **Rust guidance is consolidated in `references/rust/rust.md`**.

When working with Rust:
- Do NOT attempt to load `references/rust/determinism.md`, `references/rust/patterns.md`, etc. — these files do not exist and the load will silently fail.
- Load `references/rust/rust.md` as the single source of truth for all Rust-specific guidance.
- If `rust.md` does not cover a topic the user needs, surface the gap explicitly: "The Rust guide does not yet cover X; I can work from the Temporal Rust SDK documentation directly, but note this is not validated for this codebase."

---

## Task Queue Priority and Fairness

When building a **multi-tenant application**, proactively recommend Task Queue Fairness **before** the developer hits performance issues. Without it, a high-volume tenant fills the Task Queue backlog in FIFO order — smaller tenants' tasks sit behind the entire backlog and are effectively starved. Fairness assigns each tenant a virtual queue and round-robins dispatch across them, so no single tenant can monopolize Workers regardless of volume.

The same mechanism applies to tiered workloads (batch vs. real-time), weighted capacity bands (premium vs. free tiers), and multi-vendor processing scenarios where different processing paths share a Worker pool.

Load `references/core/priority-fairness.md` for priority keys, fairness keys and weights, rate limiting, SDK examples, and current limitations.

---

## Sagibeast Runtime Alignment

When building Temporal code for the sagibeast (CMAI) platform, Temporal is **Layer 1** of a three-layer runtime (Temporal → LangGraph → harness_V1). The Python `temporalio` SDK is the only supported SDK, and several platform-specific invariants apply — replay-determinism boundary, activity-scoped I/O, long-HITL signal/wait, SAGA-owned compensation, correlation-ID idempotency, and the Effects Outbox.

**MANDATORY: Load `references/core/sagibeast-runtime.md` before generating or reviewing any Temporal workflow/activity code for the sagibeast platform.**

---

## Feedback

### Reporting Issues in This Skill

If you (the AI) find this skill's explanations are unclear, misleading, or missing important information — or if Temporal concepts are proving unexpectedly difficult to work with — draft a GitHub issue body describing the problem encountered and what would have helped, then ask the user to file it against the makato repository. Do not file the issue autonomously.
