<!-- markdownlint-disable MD041 -->
<!--
PR Title format: type(scope): description
  Types: feat | fix | refactor | docs | test | chore | ci | build | perf | style | revert
  Scope: plugin name (e.g., makato-core, makato-plan) or area (docs, ci, repo)
  Example: feat(makato-plan): add grill skill
-->

## Description of Changes

**What changed:**

<!-- One bullet per file/area with a concise explanation. -->
-

## Goal Alignment

**Plugin**: `makato-<name>`
**Goal**: `<paste goal statement from plugin.json here>`
**Alignment**: <!-- one sentence connecting this change to the plugin goal -->

## Links

<!-- GitHub Issue: Closes #NNN -->
N/A

## How to Test

<!-- Numbered steps. Name the command, the input, and the expected output. -->
1.
2.
3.

## Breaking Changes

- [ ] Yes — describe what breaks and migration steps
- [x] No

## PR Checklist

- [ ] PR title follows conventional commits: `type(scope): description`
- [ ] Skills are self-contained (no `@`-paths escaping the skill directory)
- [ ] CHANGELOG updated (or relies on release-please from commit message)
- [ ] Version bumped in `plugin.json` if skill behavior changed

**AI-assisted:**

- [ ] Code implementation
- [ ] Commit messages
- [ ] PR description

## Additional Changelog Entries

<!-- Leave empty for single-change PRs. Add extra `type(scope): description` lines
     only when this PR contains additional logical changes the title doesn't cover. -->
