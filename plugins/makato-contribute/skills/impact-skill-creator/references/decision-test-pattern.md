# Decision Test Pattern

## Purpose

Every makato plugin has a single goal statement (stored in `plugin.json` under `description`). The decision test determines whether a new skill belongs in that plugin.

## The Test

Ask: **"Does this skill demonstrably serve the goal: '<goal-statement>'?"**

### Outcomes

| Answer | Action |
|--------|--------|
| **Clearly yes** | The skill belongs in this plugin. Proceed. |
| **Maybe / tangentially** | Discuss with the contributor. Likely belongs elsewhere. |
| **No** | Does not belong. Suggest an alternative plugin or a new one. |

## How to Apply

1. Read the target plugin's `plugin.json` and extract the `description` field
2. Read the plugin's `AGENTS.md` "What Belongs Here" and "What Does NOT Belong Here" sections
3. Compare the proposed skill's purpose against both
4. Make the decision explicit — state the reasoning aloud

## Examples

### makato-core
- **Goal**: "Provide the shared foundation that makes the suite work as a coherent system"
- ✅ Belongs: suite-level guide, diagnostics, contract schema
- ❌ Doesn't belong: spec-writing skill (serves one workflow, not the suite)

### makato-contribute
- **Goal**: "Help contributors participate in makato-suite development while keeping all content within the framework's guardrails"
- ✅ Belongs: plugin scaffolding, skill creation, validation helpers, convention enforcement
- ❌ Doesn't belong: end-user workflow skills, domain-specific tools

## The Goal IS the Boundary

- Not categories or skill counts
- Not role labels ("this is a dev tool")
- Not "it might be useful someday"
- The single question: does it serve the stated goal?
