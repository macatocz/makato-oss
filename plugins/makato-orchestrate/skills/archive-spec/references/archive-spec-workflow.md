# archive-spec GHA Workflow

Copy this file to `.github/workflows/archive-spec.yml` in your consumer repo.

Fires automatically after every PR merges to the default branch. Extracts the closed
issue number from the PR body (`Closes #N` / `Fixes #N` / `Resolves #N`), then runs
the deterministic `archive-spec.sh` script — **no Claude CLI on the runner**.

The archival is purely mechanical (derive slug → move folder → append Evolution Log
row → close issue), so it needs no model. Running it as plain bash keeps GitHub
Actions Claude-free — consistent with the **D5 "no LLM in the runner"** constraint —
and avoids a per-merge cloud-LLM cost plus a new API-key secret (#221).

Prerequisites in the consumer repo:
- `gh` CLI (preinstalled on `ubuntu-latest`)
- `GITHUB_TOKEN` with `contents: write`, `issues: write` scopes (default token suffices)
- `specs/<key>-<slug>/` (or `specs/<slug>/`) folder convention for spec folders
- `plugins/makato-orchestrate/scripts/archive-spec.sh` present in the repo (vendor it
  or adjust the invocation path)

---

## Workflow file

```yaml
# .github/workflows/archive-spec.yml
#
# Post-merge spec lifecycle — archive completed feature specs (deterministic
# bash port, no Claude CLI). Copy of the template at:
#   plugins/makato-orchestrate/skills/archive-spec/references/archive-spec-workflow.md
#
# Mirrors post-merge.yml (documentation-agent) in this plugin.
name: Post-merge spec archive

on:
  pull_request:
    types:
      - closed

permissions:
  contents: write
  issues: write
  pull-requests: read

jobs:
  archive:
    # Only on actual merge to the default branch, not on PR close without merge.
    if: >-
      ${{ github.event.pull_request.merged == true &&
          github.event.pull_request.base.ref == github.event.repository.default_branch }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout merged commit
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Extract closing issue number
        id: issue
        env:
          PR_BODY: ${{ github.event.pull_request.body }}
        run: |
          # Matches: Closes #N, Fixes #N, Resolves #N (case-insensitive, first match)
          issue=$(echo "$PR_BODY" \
            | grep -ioP '(?:closes|fixes|resolves)\s+#\K\d+' \
            | head -1)
          if [ -z "$issue" ]; then
            echo "::notice::No closing issue found in PR body — skipping archive."
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "issue_number=$issue" >> "$GITHUB_OUTPUT"
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Run archive-spec
        if: steps.issue.outputs.skip == 'false'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ISSUE_NUMBER: ${{ steps.issue.outputs.issue_number }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
        run: |
          bash plugins/makato-orchestrate/scripts/archive-spec.sh \
            --issue "${ISSUE_NUMBER}" \
            --pr "${PR_NUMBER}"
```

---

## How issue resolution works

The script receives `--issue N` and does the rest deterministically:

1. Reads `gh issue view N --json body` and derives the spec slug from the `to-issues`
   provenance in the body — the `*Feature slug: \`<slug>\`*` footer, falling back to the
   top-of-body `specs/<slug>/stories.json` line (same logic as `loop.sh`).
2. Resolves the folder by matching `specs/<slug>/` (exact) or `specs/<slug>-*/` (prefix),
   disambiguating epic collisions by the issue number in `created-issues.json` / `plan.md`.
3. Detects the domain from `plan.md` / `spec.md` frontmatter (default `general`).
4. Appends an Evolution Log row to `specs/master/<domain>.md`, moves the folder to
   `specs/archive/<date>-<folder>/`, appends the archive-index row, then closes the issue.

## Wiring notes

| Scenario | Behaviour |
|----------|-----------|
| PR body has no `Closes #N` | `skip=true` — workflow exits cleanly, no archive runs |
| PR closes multiple issues | Only the **first** match is archived; add a second `run` step for multiple |
| No `to-issues` provenance in body | Script logs a warning, closes the issue, moves no folder (exit 0) |
| Spec folder missing / gitignored | Script logs a warning, closes the issue, moves no folder (exit 0) |
| Issue already closed (e.g. via PR `Closes #N`) | Close step is an idempotent skip; folder move still runs |
| `gh issue close` genuinely fails | Script exits 3 so the (non-blocking) job surfaces the failure |

**Note on gitignored specs.** In the makato repo `specs/**` is a gitignored scratch dir,
so on the runner the spec folder is absent after checkout — the move is a local no-op and
the durable effect is the issue closure. In a consumer repo where specs are tracked, the
move + commit + push persists (the script commits with `[skip ci]` and pushes when the
move produced staged changes). Either way the job never fails on an absent folder.

## Relationship to post-merge.yml

This workflow mirrors `workflows/post-merge.yml` (documentation-agent) in structure.
Both fire on the same `pull_request: closed` event. They are intentionally separate jobs
so an archive failure never blocks the documentation pass and vice versa.

If you want a single post-merge job, fold the `Run archive-spec` step into
`post-merge.yml` after the documentation-agent step — the jobs share the same trigger
and permissions.
