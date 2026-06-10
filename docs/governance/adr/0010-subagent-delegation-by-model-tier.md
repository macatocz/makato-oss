# ADR-0010: Subagent Delegation by Model Tier

## Status

Accepted

## Date

2026-05-12

## Context

Skills that run on expensive models (Opus) for creative facilitation also need to perform mechanical tasks: scanning directories, filling templates, writing formatted documents. Running all of this on Opus wastes tokens on work that doesn't benefit from the model's strengths.

Claude Code's Agent tool allows spawning subagents with different model specifications. Plugins can declare agent definitions with explicit model assignments.

## Decision

Skills delegate mechanical subtasks to cheaper model tiers via dedicated subagents:

| Task type | Model tier | Examples |
|-----------|-----------|----------|
| User-facing facilitation, creative dialogue, nuanced judgment | Opus | Brainstorming ideation, grilling, convergence |
| Structured document writing, template filling, HTML generation | Sonnet | Writing brainstorm.md, generating review HTML |
| Read-only scanning, file discovery, index navigation | Haiku | Scanning context/ directories, checking for files |

Agent definitions live at `plugins/<plugin>/agents/` and declare their model explicitly in frontmatter.

The dispatching skill:
- Passes structured content (not raw conversation) to the subagent
- Uses natural language dispatch prompts (no pseudo-code syntax)
- Provides absolute paths for any file references
- Receives the subagent's output and integrates it into the user-facing flow

## Consequences

- Token cost for facilitation-heavy skills drops 30-40% (writing/scanning offloaded)
- Subagents are reusable across skills within the same plugin
- The main session's context window stays lean (subagent results are summaries, not raw file contents)
- Subagents must be self-sufficient — they cannot ask the user questions or access conversation history
- Model tier assignments should match task complexity, not default to the cheapest option (Sonnet for HTML generation after Haiku proved unreliable with complex markup)
