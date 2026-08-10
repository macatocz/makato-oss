# Implementation Plan: Cross-platform portability remediation + state/transcript path re-homing (#6)

<!-- to-issues:auto — enriched by build-refine at dispatch time -->

## Story
**Issue:** #6
**Summary:** Cross-platform portability remediation + state/transcript path re-homing

## Implementation Mode
**Mode:** goal
**Rationale:** _To be enriched by build-refine at dispatch time._

## Tasks

- Detect-and-branch the osascript HALT notifier (loop-halt-watch.sh:43)
- keep the portable flock/mutex
- readlink -f python fallback
- stat -c/-f branch
- _guarded_sleep
- and BSD-safe sed (already cross-platform). Add a new MAKATO_TRANSCRIPT_PATH env override + an oh-my-pi transcript-path adapter for the one hardcoded path (loop.sh:4711) so the Langfuse hook can consume it. Re-home HALT/state/specs/config via the existing env overrides
- interim default is a local state dir (the persistent-volume target is provisioned in sequence 6). The transcript adapter depends on how omp stores transcripts (confirmed by the sequence-1 spike).

## Acceptance criteria

- no command fails due to a macOS-only tool and the detect-and-branch notifier no-ops gracefully on Linux
- all state reads and writes land under the configured root; no path defaults to $HOME/.claude or $REPO_ROOT
- the Langfuse hook reads the transcript from the configured path and emits a trace, accessing no hardcoded $HOME/.claude/projects path
- the dispatch cycle should complete without any command failing due to a macOS-only tool
  - no macOS-specific desktop notification should be attempted
- all state reads and writes should land under the configured custom root
  - no state file should be written to the default home directory or the repository root
- a trace should appear in Langfuse sourced from the configured transcript path
  - no read should occur from the default home directory projects folder

## Scope Flags

_To be enriched by build-refine at dispatch time._
