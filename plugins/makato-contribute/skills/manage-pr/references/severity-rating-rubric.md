# Severity & Quality Rating Rubric

Two independent ratings per comment.

## Severity (makato if unfixed)

| Tier | Meaning | Examples |
|------|---------|----------|
| **High** | Will mislead consumers, cause runtime errors, break contracts, or violate stated rules | Schema drift between docs and code; missing required field; broken API contract |
| **Medium** | Silent failure modes, degraded UX, edge cases that real users hit | Unhandled Promise rejection; missing `.catch()`; permission denial swallowed |
| **Low** | Cosmetic, stylistic, or affects a path most users never see | Initial-render glyph mismatch; whitespace; non-canonical formatting |
| **N/A** | Comment is invalid or by-design — no severity applies | Bot misread; intentional omission |

## Quality (how useful was the bot here)

| Rating | Meaning |
|--------|---------|
| 🌟 **Awesome** | Caught a real, high-makato issue with accurate reasoning. Apply as-is. |
| ✅ **Helpful** | Caught a real issue, even if reasoning is partly off. Worth fixing. |
| 🤷 **Neutral** | Conditional or low-makato; could go either way. Don't reward, don't punish. |
| ❌ **Misleading** | Wrong claim or wrong reasoning. Reply with correction so the bot's training signal isn't reinforced. |

## How to Use

- A comment can be `Valid + Low + Helpful` (real but cosmetic) or `Invalid + N/A + Misleading` (wrong claim).
- High-severity + Invalid is uncommon but possible — bot raised a real-sounding alarm about something that doesn't exist.
- Default toward fixing High and Medium severity when valid; consider skipping Low unless the change is one-line.

## Worked Example (PR #36)

| Comment | Validity | Severity | Quality | Action |
|---------|----------|----------|---------|--------|
| Schema doc contradicts SKILL.md | ✅ Valid | High | 🌟 Awesome | Fix |
| `.then()` without `.catch()` | ✅ Valid | Medium | ✅ Helpful | Fix |
| Glyph mismatch on initial render | ⚠️ Partial | Low | ✅ Helpful | Fix (one char) |
| "Missing copy button" | ❌ Invalid | N/A | 🤷 Neutral | Reply explaining design |
