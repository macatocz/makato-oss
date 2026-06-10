# Comment Validation Rubric

## Why Validate

Review bots produce confident-sounding claims that are sometimes wrong (misread codepoints, hallucinated APIs, claims about removed code). Trust nothing without checking the actual file.

## Per-Comment Checklist

For each bot comment:

1. **Locate the file at the cited line.** Use the `Read` tool with `offset`/`limit` around the line. If the file doesn't exist on the PR branch, the comment is stale — invalid.

2. **Find the exact symbol/quote the bot references.** Grep for any function name, string literal, regex, or codepoint quoted in the bot's body.
   - If the bot quotes a codepoint (e.g., "U+25C4"), verify the actual codepoint in the source — bots often misidentify these.
   - If the bot quotes a string, grep for that exact string.

3. **Compare claim vs reality.** Examples:
   - Bot says "no `.catch()` on Promise" → check whether `.catch` is actually missing.
   - Bot says "drift between schema and SKILL.md" → read both, compare.
   - Bot says "missing button" → grep for the button class/text.

4. **Check for intentional design.** Sometimes the bot is correct that something is missing, but the absence is intentional (e.g., a read-only template doesn't need copy buttons). Read the SKILL.md or surrounding docs to determine intent.

## Decision

| Outcome | Validity |
|---------|----------|
| Bot's factual claim matches the code | ✅ Valid |
| Claim is partly right (real issue, wrong reasoning) | ⚠️ Partially valid |
| Claim contradicts the code | ❌ Invalid |
| Real but intentional (by design) | ❌ Invalid (note design intent in reply) |

## Common Bot Misfires

- Misidentifying Unicode codepoints from HTML entities (e.g., `&#9684;` quoted as `U+25C4`).
- Flagging "missing error handling" for code paths that can't fail.
- Suggesting Promise rejection paths for fire-and-forget operations.
- Claiming a feature is "missing" when it was deliberately removed.

When you spot one of these patterns, the comment is likely invalid or partially valid — but verify before dismissing.
