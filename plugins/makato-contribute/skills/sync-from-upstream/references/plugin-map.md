# Plugin Map

Maps upstream impact-market plugin directories to their makato counterparts.

| Upstream (impact-market) | Makato |
|--------------------------|--------|
| `daff-build` | `makato-build` |
| `daff-shape` | `makato-plan` |
| `daff-cr` | `makato-change` |
| `daff-core` | `makato-core` |
| `daff-contribute` | `makato-contribute` |

## Skill Renames

Some skills use a different directory name in makato:

| Upstream path | Makato path |
|---------------|-------------|
| `daff-contribute/skills/daff-skill-creator` | `makato-contribute/skills/makato-skill-creator` |
| `daff-contribute/skills/daff-plugin-creator` | `makato-contribute/skills/makato-plugin-creator` |
| `daff-core/skills/daff-guide` | `makato-core/skills/makato-guide` |

## Agent/Shared Structure (same names, different parent)

Agents and shared files keep the same file names — only the parent plugin directory changes:

| Upstream | Makato |
|----------|--------|
| `daff-cr/agents/code-reviewer.md` | `makato-change/agents/code-reviewer.md` |
| `daff-shape/agents/acceptance-writer.md` | `makato-plan/agents/acceptance-writer.md` |
| `daff-build/shared/baseline-guide.md` | `makato-build/shared/baseline-guide.md` |

## makato-Only Plugins / Skills (no upstream equivalent — never touch)

- `makato-build/skills/langgraph-fundamentals`
- `makato-build/skills/langgraph-agent-patterns`
- `makato-build/skills/langgraph-human-in-the-loop`
- `makato-build/skills/langgraph-persistence`
- `makato-build/skills/langgraph-reflexion`
- `makato-core/skills/dotx-schema-extractor`
- `makato-core/skills/manage-microsoft-excel`
- `makato-core/skills/manage-pdf`
