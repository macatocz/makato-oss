# Implementation Plan: Fork bootstrap + Phase-0 spike: headless omp dispatch on an open model (#3)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #3
**Summary:** Fork bootstrap + Phase-0 spike: headless omp dispatch on an open model

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Create the makato-oss fork (repo + GitHub project) as the entry-point enabler. Stand up a minimal single-open-endpoint `models` section in config/config.yml (no separate models.yml). Run omp --yolo -p headless against 3 representative skills (prompt-only / MCP-calling / sub-agent-dispatch). Capture the omp --mode rpc terminal-event shape AND the resume-handle equivalent
- then commit a decision doc that flips Decision 3 (D16) from PENDING to a fixed contract (Option A RPC-adapter vs Option B state-file-only). Measure how many of the ~25 agent files need harness-specific change beyond a modelRole substitution. Explicitly verify Playwright MCP resolves from a sub-agent (filterBrowser gate
- Q8). State an explicit pass/fail gate: if oh-my-pi fails the headless/sub-agent/MCP contract
- the Hermes fallback (D2) is triggered before S2–S4 commit.

## Acceptance criteria

- all three skills complete with no approval-prompt stall, each LLM call routes to the open endpoint, and MCP tools resolve from sub-agents
  - Playwright MCP resolves from a sub-agent, or the filterBrowser caveat is confirmed and the filterBrowser:false workaround is documented
- the terminal NDJSON event line is captured to a committed artefact and a resume-handle equivalent (session id or path) is confirmed usable for --resume
  - the committed decision doc states whether Option A (RPC-adapter) or Option B (state-file-only) phase detection was chosen, flipping D16 from PENDING to RESOLVED
- no CC-specific path fails to resolve, and any skill requiring CC-specific semantics is listed in a committed migration-scope doc that counts the agent files needing harness-specific change
- all three skills should complete without pausing for an approval prompt, and each language-model call should route to the open endpoint
  - the browser automation tool either resolves from a sub-agent without modification, or the limitation and a confirmed workaround are documented in a committed artefact
- the document should capture the end-of-run event shape, a confirmed method for resuming interrupted runs, and a stated choice between the two candidate detection approaches — moving the contract from an open question to a resolved decision
- any skill that relies on harness-specific behaviour should be identified in a committed migration-scope document that counts the agent files needing change
  - no skill should fail to load in a way the operator cannot diagnose from the run logs

## Scope Flags

_To be enriched by build-refine at dispatch time._
