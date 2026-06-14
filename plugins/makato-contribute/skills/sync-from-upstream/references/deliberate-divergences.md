# Deliberate Divergences

Content that was intentionally changed in makato relative to impact-market. Do NOT overwrite these when syncing from upstream.

## Skills with Deliberate Content Differences

### makato-skill-creator / Step 14: skill-plan.html placement

- **impact-market**: skill-plan.html stays in `/tmp`, is NOT copied into the skill directory. Per ADR-0014 in impact-market, no `skill-plan.html` may live inside a skill.
- **makato**: skill-plan.html IS copied into `references/skill-plan.html` inside the skill directory.
- **Action**: When syncing this step, preserve the makato behavior (copy into references).

### create-prd: argument-hint and spec folder naming

- **impact-market**: `argument-hint: "[ITDB-KEY]"`, spec folders named `specs/{ITDB-KEY}-{slug}/`
- **makato**: `argument-hint: "[slug]"`, spec folders named `specs/{slug}/`
- **Action**: Keep makato's slug-based approach; do not restore ITDB key convention.

### makato-plan/publish: no Jira or Confluence

- **impact-market**: publish skill creates Jira epic + stories + Confluence spec page
- **makato**: publish skill only creates GitHub Issues — no Jira MCP calls, no Confluence
- **Action**: When syncing publish skill, replace all Jira/Confluence steps with GitHub Issue creation via `gh issue create`.

### makato-core/skills/excalidraw: lives in core, not plan

- **impact-market**: `daff-shape/skills/excalidraw`
- **makato**: `makato-core/skills/excalidraw` AND `makato-plan/skills/excalidraw` (both exist)
- **Action**: Update `daff-shape` excalidraw content → both locations in makato.

## makato-Only Skills (no upstream equivalent)

These exist only in makato and must never be touched during sync:

| Plugin | Skill | Reason |
|--------|-------|--------|
| `makato-build` | `langgraph-fundamentals` | makato-specific LangGraph patterns |
| `makato-build` | `langgraph-agent-patterns` | makato-specific LangGraph patterns |
| `makato-build` | `langgraph-human-in-the-loop` | makato-specific LangGraph patterns |
| `makato-build` | `langgraph-persistence` | makato-specific LangGraph patterns |
| `makato-build` | `langgraph-reflexion` | makato-specific LangGraph patterns |
| `makato-core` | `dotx-schema-extractor` | makato-specific Word template tooling |
| `makato-core` | `manage-microsoft-excel` | makato-specific Excel tooling |
| `makato-core` | `manage-pdf` | makato-specific PDF tooling |

## Known Remaining Issues (tracked, not blocking)

Files in makato where substitutions were missed or done incorrectly. These should be fixed as part of any sync run that touches the file — not necessarily today:

| File | Issue | Fix |
|------|-------|-----|
| `makato-build/skills/build-start/SKILL.md` | `daff-build`, `daff-shape`, `DCP-1234` examples | Replace per naming-map.md |
| `makato-plan/skills/create-prd/SKILL.md` | "the makato if wrong" (garbled — should be "the impact if wrong") | Restore "impact" as plain noun |
| `makato-core/skills/create-issue/references/label-conventions.md` | Heading says "DCP/makato" | Change to `sagibeast/makato` |
| `makato-contribute/skills/makato-plugin-creator/SKILL.md` | Author default still `"DCP AI Team"` | Change to `"makato Team"` |
| `makato-plan/.claude-plugin/plugin.json` | `author.name: "DCP makato Team"` | Change to `"makato Team"` |
| `makato-change/.claude-plugin/plugin.json` | `name: "daff-cr"` | Change to `"makato-change"` |
| `makato-plan/.claude-plugin/plugin.json` | description references Jira | Rewrite to use GitHub Issues |
| `makato-plan/shared/terminology.md` | ITDB, Confluence, DCP section references | Update per naming-map.md |
| `makato-plan/README.md` | Extensive ITDB, Jira, Confluence, DCP references | Full update per naming-map.md |
