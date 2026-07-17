# Error Analysis Reference

## Primary Guide

**Step 1 — Fetch the authoritative guide:**

```
https://langfuse.com/guides/cookbook/error-analysis-llm-applications.md
```

Read it in full. It defines the 5-step process:
sample selection → open coding → clustering → labelling → deciding what to fix.

**Step 2 — Work through the process with the user**

Do as much as possible directly (look up traces, create annotation queues,
display charts). Pause and ask before acting wherever the user's judgment is
required (what to fix, how to label, which evaluator to set up).

> NEVER tell the user "now do this in Langfuse" when you can do it yourself
> via the SDK or CLI.

## Credentials

Require `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_HOST`
(pointing to your self-hosted instance, e.g. `http://localhost:3000`).
If they are not set, ask the user to configure them. Do not ask them to paste
secret values into chat. Verify connectivity before proceeding.

## Annotation Target: OBSERVATION vs TRACE

> **CRITICAL:** In OpenTelemetry-instrumented apps, trace-level `input`/`output`
> is often null — content lives in a GENERATION observation. Add the GENERATION
> observation (not the trace) to the annotation queue so the reviewed content
> is actually visible.

## Annotation Queues

> **CRITICAL:** Queues cannot be updated or deleted after creation.
> Create score configs first, collect their IDs, then create the queue.
> To add configs later you must create a new queue.

After creating a queue, give the user a direct link:

```
<LANGFUSE_HOST>/project/<projectId>/annotation-queues/<queueId>
```

Instruction to give the user: *"Open-code the first ~50 examples. For each,
write what you observe in `open_coding` (describe behaviour, don't diagnose
root causes), then set `pass_fail_assessment` to Pass or Fail."*

## Common Gotchas

| Mistake | Fix |
|---------|-----|
| Annotating the trace instead of the observation | Target the GENERATION observation when trace I/O is null |
| Creating a queue before score configs exist | Create configs → collect IDs → create queue |
| Checking for existing score configs skipped | Check first; configs can't be deleted |
| Requesting more than 100 traces at once | Page size is capped at 100; paginate |
| Bulk queue item creation without rate limiting | Space out requests to avoid 429 errors |

## After Labelling

When a category warrants action, offer two options:
- **Prompt fix:** create a versioned prompt in Langfuse (tracked, callable via
  the prompt API) or draft the specific text change for the user to review.
- **Evaluator setup:** propose the evaluator type and offer to configure it.
