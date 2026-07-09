# archive-spec GHA Workflow

Copy this file to `.github/workflows/archive-spec.yml` in your consumer repo.

Fires automatically after every PR merges to the default branch. Extracts the closed
issue number from the PR body (`Closes #N` / `Fixes #N` / `Resolves #N`), then runs
the `archive-spec` skill headless via the Claude CLI.

Prerequisites in the consumer repo:
- Claude CLI available on the runner (wire via your org's standard Claude setup action)
- `gh` CLI (preinstalled on `ubuntu-latest`)
- `GITHUB_TOKEN` with `contents: write`, `issues: write` scopes (default token suffices)
- `specs/<key>-<slug>/` folder convention for spec folders

---

## Workflow file

```yaml
# .github/workflows/archive-spec.yml
#
# Post-merge spec lifecycle — archive completed feature specs.
# Copy of the template at:
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

      - name: Setup Claude CLI
        # Replace with your org's standard Claude CLI setup action.
        # See https://docs.anthropic.com/claude-code for current guidance.
        run: |
          echo "::notice::Replace this step with your Claude CLI setup action."

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
          claude --dangerously-skip-permissions \
            --print "Post-merge: run /makato-orchestrate:archive-spec for issue #${ISSUE_NUMBER} (merged via PR #${PR_NUMBER})" \
            --allowedTools "Bash,Read,Write,Edit"
```

---

## How issue resolution works

The skill receives `issue #N` in the prompt and does the rest:

1. Reads `gh issue view N` to get the spec folder key from the issue title or labels
2. Prefix-matches `specs/<key>-*/` to find the folder
3. Detects the domain from `plan.md` frontmatter
4. Runs the archive or obsolete path depending on whether the PR merged code

## Wiring notes

| Scenario | Behaviour |
|----------|-----------|
| PR body has no `Closes #N` | `skip=true` — workflow exits cleanly, no archive runs |
| PR closes multiple issues | Only the **first** match is archived; add a second `run` step for multiple |
| Spec folder missing | Skill logs a warning and exits 0 — issue is closed but no spec to archive |
| Claude CLI not installed | Workflow fails the `Run archive-spec` step; PR merge is unaffected (job is not blocking) |

## Relationship to post-merge.yml

This workflow mirrors `workflows/post-merge.yml` (documentation-agent) in structure.
Both fire on the same `pull_request: closed` event. They are intentionally separate jobs
so an archive failure never blocks the documentation pass and vice versa.

If you want a single post-merge job, fold the `Run archive-spec` step into
`post-merge.yml` after the documentation-agent step — the jobs share the same trigger
and permissions.
