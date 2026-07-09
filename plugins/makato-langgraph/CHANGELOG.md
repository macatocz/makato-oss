# Changelog — makato-langgraph

## [Unreleased]

### Added — first-plugin skill bundle (#144)

F1 of agent-skill-routing. makato-langgraph is the first plugin to ship a
skill-routing bundle, proving the mechanism end-to-end.

- `config/skill-bundles.yml` (new) — routes `**/*graph*.py` files containing
  `from langgraph` or `import langgraph` (D19 OR-substring content hint) to
  `langgraph-fundamentals` + `langgraph-persistence`. Aggregated by
  makato-build's inject-skills resolver alongside every other plugin's bundles.
  Doubles as the authoring reference for the other plugins' bundles landing in
  S3.
- `pre-commit/validate-skill-bundles.sh` (new) — authoring gate that rejects a
  wide glob (zero literal path segments) recommending skills without a
  `contains:` content filter; exits non-zero with an actionable message. Reuses
  makato-build's `inject_skills._glob_specificity` as the single source of truth
  for what "wide" means.

### Changed — sagibeast-alignment audit (2026-06-25)

All five skills audited against sagibeast golden-rule H.1 (PEP 604/585 type hints; no `typing.Dict` / `typing.List` / `typing.Optional`). Code examples were corrected so generated code follows the canon.

- `langgraph-agent-patterns` — **1.0.0 → 1.0.1**
  - replaced `Dict[str, Any]` with `dict[str, Any]` in TypedDict fields and function signatures across the minimal single-node, multi-step planning, and conditional-branching examples
  - removed `from typing import Dict` in three code blocks (PEP 585 builtins instead)
  - added `-> str` return annotation to `route()` in the conditional-branching example
- `langgraph-fundamentals` — **1.0.0 → 1.0.1**
  - replaced deprecated `typing.List` / `typing.Dict` / `typing.Optional` imports with PEP 585 builtins in five code blocks (state-schema-typeddict, state-schema-pydantic, pydantic-arbitrary-types, custom-reducer, map-reduce)
  - removed stray closing ` ``` ` at EOF
  - fixed malformed `</overview>` closing tag (leading backtick)
- `langgraph-human-in-the-loop` — **1.0.0 → 1.0.1**
  - removed terminal `<boundaries>` "What You Should NOT Do" block (makato-skill-creator rule: no NEVER sections at end of file)
  - removed stray unmatched ``` fence on final line
  - fixed three backtick-wrapped XML closing tags
- `langgraph-persistence` — **1.0.0 → 1.0.1**
  - replaced `from typing import List, Optional, Annotated` with `from typing import Annotated`; converted all `List[...]` to `list[...]` and `Optional[int]` to `int | None` throughout the subgraph-composition example
- `langgraph-reflexion` — **1.0.0 → 1.1.0**
  - replaced `Dict` / `List` imports from `typing` with PEP 585 builtins in the State Definition and Unique Lessons Reducer blocks
  - removed stray dangling code fence at EOF

## [0.1.0] — 2026-06-13

### Added
- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- 5 LangGraph reference skills extracted from `makato-build`:
  - `langgraph-fundamentals`
  - `langgraph-agent-patterns`
  - `langgraph-human-in-the-loop`
  - `langgraph-persistence`
  - `langgraph-reflexion`
