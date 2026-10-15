## makato-typesafeai

Provide reference skills and patterns for building AI-powered applications with TypeSafe's System One model API.

**How:** Shipping curated skills that guide developers through TypeSafe's judgment primitives (Choice, Noul, Score), composition patterns, and integration recipes, always pointing at the live docs as the authoritative source.

**Why:** TypeSafe's probability-weighted typed judgments are a distinct paradigm from generative text — integrations need specific design heuristics not covered by general LLM or AI agent guidance, and no other makato plugin addresses this paradigm.

## What Belongs Here

- Skills explaining TypeSafe's System One programming model and Jev model capabilities
- Skills guiding judgment question design (Choice, Noul, Score primitives) and state structure
- Integration patterns and cookbook walkthroughs for TypeSafe HTTP API and Python/JavaScript SDKs
- Skills for specific application categories (routing, ranking, extraction, verification, interactive experiences) built with TypeSafe
- Reference links to live TypeSafe documentation as the authoritative source

## What Does NOT Belong Here

- General generative LLM patterns (text generation, streaming, chat completions)
- LangGraph, LangChain, or other AI orchestration framework patterns (belongs in `makato-langgraph`)
- FastAPI or framework scaffolding not specific to TypeSafe integration (belongs in `makato-fastapi`)
- LLM observability and tracing (belongs in `makato-observability`)
- Generic AI agent loop patterns not tied to TypeSafe's judgment API

## Skills

| Skill | Trigger | Description |
|-------|---------|-------------|
| `how-to-typesafe-ai` | "build with TypeSafe", "TypeSafe integration", "System One", "Jev model", "judgment API" | Design, integrate, and optimize TypeSafe System One judgment calls in an application |
| `building-with-jev-skill` | "Jev", "Choice Score Noul", "confidence threshold" | Write and improve Jev programs — primitive selection, state design, composition, debugging |

## Installation

```bash
claude --plugin-dir ./plugins/makato-typesafeai
```
