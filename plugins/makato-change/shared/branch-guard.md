# Branch Guard

## Purpose

Prevent code-explorer and other discovery agents from scanning incomplete feature-branch
state during the design phase. A feature branch may contain partial commits, uncommitted
stubs, or changes not yet merged — scanning it as if it were the baseline produces analysis
artefacts that diverge from what the codebase actually does on the default branch.

## Check Procedure

Run the following command to determine the current branch:

```bash
git -C <REPO_ROOT> branch --show-current
```

Compare the result against the repository's default branch (`main` or `master`). If the
default branch is not obvious from the local config, it can be discovered with:

```bash
git -C <REPO_ROOT> remote show origin | grep 'HEAD branch' | awk '{print $NF}'
```

Store the current branch in working memory as `CURRENT_BRANCH` for reuse by later steps.

## Outcome

- **Default branch** (`main` / `master`): proceed — no log entry needed.
- **Non-default branch**: emit the following WARN and continue (advisory, not a hard block,
  because the operator may intentionally be designing against a WIP branch):

  ```
  branch-guard: WARN — current branch is '<CURRENT_BRANCH>', not the default branch.
  Code-explorer will scan WIP state. Analysis artefacts may diverge from the merged baseline.
  Proceeding.
  ```

  Log a `warn` entry to `build.jsonl` with `data.branch: <CURRENT_BRANCH>`.

A hard block is reserved for the cross-ticket case detected at execute time (see
`plugins/makato-change/skills/execute/SKILL.md` Step 1.7).
