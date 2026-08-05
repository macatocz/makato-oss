# Context7 Skill Navigation

**Purpose**: Live documentation fetching for external libraries via Context7 MCP server

---

## Structure

```
context7/
├── navigation.md              # This file
├── README.md                  # Quick start and workflow
├── SKILL.md                   # Full skill: workflow, anti-patterns, decision trees
└── library-registry.md        # Supported libraries and pre-optimized query patterns
```

---

## Quick Routes

| Task | Path |
|------|------|
| **Quick start** | `README.md` |
| **Full workflow + anti-patterns** | `SKILL.md` |
| **Supported libraries** | `library-registry.md` (lines 18-181) |
| **Pre-optimized query patterns** | `library-registry.md` (lines 199-261) |
| **Add new library** | `library-registry.md` (lines 264-279) |

---

## By Purpose

**Using Context7**:
- Quick start → `README.md`
- Full procedure + recovery → `SKILL.md`

**Query Optimization**:
- Pre-built query strings → `library-registry.md` (MANDATORY for listed libraries)
- Query construction rules → `SKILL.md` § Workflow Step 3

**Anti-Patterns**:
- All NEVER items with WHY → `SKILL.md` § Anti-Patterns
