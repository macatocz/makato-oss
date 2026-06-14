---
name: build-address-pr-comments
description: >-
  Classify and resolve all PR comments — human reviewer feedback and
  automated bot findings (CI failures, lint bots, security scanners,
  Hyperspace). Classifies each as MUST-FIX / SHOULD-FIX / CONSIDER /
  OUT-OF-SCOPE, presents classification for approval, implements fixes
  grouped by file, commits and pushes, replies to each resolved comment.
  Structural feedback escalates to refine.
  Interactive. Use after create-pr when review comments arrive.
version: "1.2.1"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/create-pr` when review comments have arrived on the PR. Handles all unresolved comments — human reviewer feedback, CI bot failures, security scanner findings, lint bots, and automated review tools. May run multiple times across review rounds.

## Workflow

### Step 1 — Ask for work item key and PR URL

Ask: *"Which work item and PR are we addressing? (e.g. DCP-1234, or pass it directly: `/daff-build:build-address-pr-comments DCP-1234`)"* — or use the passed argument.

If only a key is given, derive the PR URL:
```
gh pr list --head $(git branch --show-current) --json url -q '.[0].url'
```

Run `git branch --show-current` to confirm we are on the story branch. If on `main` or `master`, stop — fixes must go on the feature branch.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"session","status":"start","data":{"pr_url":"<url>"}}'
```

---

### Step 3 — Fetch all PR comments

Run:
```
gh pr view <url> --comments --json reviews,comments
```

Include all unresolved comments regardless of source — human reviewers, CI bots, security scanners, lint tools, and automated review tools (Hyperspace, Renovate, Dependabot, etc.).

Exclude only comments already marked as resolved in the PR review thread.

Note the author type for each comment (human vs bot) — this informs the classification default in Step 4 but does not exclude anything.

If there are no unresolved comments: tell the user and stop.

---

### Step 4 — Classify each comment

Load `@references/comment-classification-guide.md`. Assign each unresolved comment a tier: **MUST-FIX**, **SHOULD-FIX**, **CONSIDER**, or **OUT-OF-SCOPE**. Use the source heuristics and classification rules from the guide; content of the comment overrides the source heuristic.

For any MUST-FIX: check whether it requires changing the fundamental implementation approach (data model redesign, API contract reversal, algorithm replacement). If yes, flag it as **STRUCTURAL**.

---

### Step 5 — Present classification for approval

Present the full classification table to the user:

```
[MUST-FIX]     src/Invoice.java:42      — "status field must be non-null"
[MUST-FIX]     CI: build failure        — "cannot find symbol OrderStatus"
[SHOULD-FIX]   src/InvoiceService.java  — lint: "method too long (87 lines)"
[CONSIDER]     Hyperspace               — "consider extracting a helper here"
[OUT-OF-SCOPE] human reviewer           — "add audit logging to all endpoints"
```

If any STRUCTURAL comment was found, present it clearly and define the flow:

> "This MUST-FIX requires changing the implementation approach. Recommended handling:
>
> **(A) Pause on structural item, continue non-structural** — address all non-structural MUST-FIX and SHOULD-FIX comments now. After the non-structural pass is complete, open a new `/build-refine` session to re-plan the structural change.
> **(B) Stop entirely** — address the structural change before any other comments.
> **(C) Override** — treat as a regular MUST-FIX and implement inline (only if you are confident the structural concern can be resolved without a new plan)."

Wait for the user to choose. If (A): continue implementing non-structural comments in this session; after the commit-and-push step, prompt the user: "Structural item outstanding — ready to open `/build-refine` for re-planning?" If (B): stop here. If (C): proceed as a regular MUST-FIX.

Wait for the user to confirm or adjust classifications. User can: promote/demote tiers, mark a SHOULD-FIX as skip with a reason, or override the STRUCTURAL call.

---

### Step 6 — Implement fixes

Implement in order: MUST-FIX first, then SHOULD-FIX, then approved CONSIDER items.

Group fixes by file — apply all changes to the same file in one pass to avoid partial edits. After all fixes to a file are applied, verify the file compiles (or passes a quick type-check if possible).

Do not implement OUT-OF-SCOPE items or unapproved CONSIDER items. Do not skip any MUST-FIX or approved SHOULD-FIX.

Log each fix:
```
{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"fix","status":"ok","data":{"tier":"MUST-FIX","file":"src/Invoice.java","comment_id":"<id>"}}
```

---

### Step 7 — Re-run verify gates

Run the project's build and unit test suite to confirm fixes did not break anything:
- **Build** (compile / type-check) — must pass
- **Unit tests** — zero new failures vs. pre-session baseline

On failure: classify.
- **Fixable** → fix and re-run from BUILD
- **Structural** → stop, report, recommend `/refine`

Full integration test suite is optional here — defer to the CI run triggered by the push unless the fixes touched integration-boundary code.

---

### Step 8 — Commit and push fixes

Stage and commit the fixes. Commit message:
```
fix(<scope>): address PR review feedback for <key>
```

If fixes span multiple logical themes (e.g. a CI build fix plus several readability fixes), use multiple commits — one per group.

Show the user the staged diff and ask: *"Ready to push `<N>` fix commits to `origin/<branch>`?"*

Wait for confirmation before pushing. Run `git push` on approval.

---

### Step 9 — Reply to PR comments

For each addressed comment, prefer `mcp__github-tools__add_reply_to_pull_request_comment` when the `github-tools` MCP is configured — it requires only the comment ID and body.

If the `github-tools` MCP is not available, fall back to `gh api`:
```bash
# Reply to a review comment
gh api repos/{owner}/{repo}/pulls/comments/{comment_id}/replies \
  -X POST -f body="<reply text>"

# Post a general review comment batch
gh pr review <pr-number> --comment -b "<reply text>"
```

Reply text by tier:
- **MUST-FIX / SHOULD-FIX / CONSIDER (implemented):** *"Fixed in `<commit-sha>` — `<one sentence on what was done>`."*
- **CONSIDER (deferred):** *"Noted — deferred; `<reason>`."*
- **OUT-OF-SCOPE:** *"This falls outside the scope of `<key>` — `<brief explanation>`. Will track separately."*

Keep replies factual and brief. Quote the original comment only if needed for clarity.

---

### Step 10 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"session","status":"ok","data":{"must_fix":<N>,"should_fix":<N>,"consider":<N>,"out_of_scope":<N>,"commits":<N>}}'
```

Tell the user: *"`<N>` comments addressed, `<N>` commits pushed. PR is ready for re-review."*
