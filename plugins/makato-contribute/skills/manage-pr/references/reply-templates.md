# Reply Templates

Canned phrasing for replying to bot threads. Keep replies short — they're for record-keeping, not discussion.

## Fixed

```
Fixed in <sha>. <one-line description of the fix>
```

Example:
```
Fixed in a1b2c3d. Updated schema doc to match SKILL.md (3-5 for foundation/happy-path, 1-3 for edge-cases).
```

## Already Correct (Bot Was Wrong)

```
Not an issue: <brief explanation of why the code is correct as-is>.
```

Example:
```
Not an issue: this template is read-only by design (terminal interaction per SKILL.md). No copy button needed.
```

## Won't Fix (Out of Scope)

```
Out of scope for this PR. <reason or where it should be addressed>.
```

Example:
```
Out of scope for this PR — tracked separately for the broader auth refactor.
```

## Partially Addressed

```
Partial fix in <sha>: <what was fixed>. <what was deliberately left>.
```

## Acknowledged but Deferred

```
Acknowledged. Will address in a follow-up — not blocking this PR.
```

## Tips

- Always reference the commit SHA when applicable so the thread links to the fix.
- Don't argue with the bot. State the fact, move on.
- If multiple comments share one fix, reply to each individually with the same SHA reference — it's clearer than chaining.
