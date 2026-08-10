# Implementation Plan: Co-located dev stack + on-instance vLLM + unified Langfuse (one container, two projects) (#10)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #10
**Summary:** Co-located dev stack + on-instance vLLM + unified Langfuse (one container, two projects)

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Provision the co-located instance
- stand up the open-LLM engine (vLLM AWQ
- serving config
- health-check) and wire its endpoint into the `models` section of config/config.yml. Deploy one Langfuse container with two projects and OTLP config
- provision and inject each project's OTLP ingest key into the omp dispatch env. Verify the three services coexist within the separate VRAM (A6000 48GB) and RAM (>=32GB sagibeast) budgets. No end-to-end Playwright run here (that is sequence 9).

## Acceptance criteria

- VRAM stays within the vLLM budget, sagibeast RAM stays within 32 GB, and no OOM kill occurs
- makato traces appear under the makato project and sagibeast traces under the sagibeast project in the same instance, with no port/tunnel collision
- VRAM should stay within the 48 GB vLLM budget and sagibeast RAM should stay within 32 GB
  - no OOM kill should occur during or after the dispatch cycle
- the task should complete and the on-instance vLLM engine should be the active provider, not a remote cloud endpoint
- makato traces should appear only under the makato project and sagibeast traces only under the sagibeast project
  - no errors should occur from conflicting ports or tunnels between the two trace streams

## Scope Flags

_To be enriched by build-refine at dispatch time._
