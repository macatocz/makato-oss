## Scope and hook-stage selection guide

MANDATORY: load at Step 2 when the caller provides no explicit `scope`, or when
choosing which scope is ambiguous. Do NOT load this reference for other purposes.

## When to use each scope

| Scope | Hook stage | File source | Use when |
|-------|-----------|-------------|----------|
| `staged` | `manual` | Cached diff | Quick feedback on files currently staged in the index. |
| `changed-vs-main` | `manual` | Branch diff + tracked worktree diff + untracked files | Default gate for everything the branch or current worktree could contribute. |

## Changed-vs-main composition

The default scope combines these NUL-delimited sources and de-duplicates their
results before invoking pre-commit with a quoted Bash array:

- `git diff --name-only --diff-filter=ACMR -z <base>...HEAD` for committed
  branch changes.
- `git diff --name-only --diff-filter=ACMR -z HEAD` for staged and unstaged
  tracked changes.
- `git ls-files --others --exclude-standard -z` for untracked, non-ignored
  files.

This avoids index mutation and preserves spaces and newlines in filenames.
Deleted files are omitted because file-oriented hooks cannot inspect them.

## Non-convergence: when fixer loops produce new findings

If the sensor loop reaches `MAX_LOOPS` without going clean, the likely causes are:

1. **Autofix side-effects**: `ruff --fix` reformats a file, introducing a new `pyright` type
   error on the modified line. Root cause: the fixer skill is not using `--select` narrowly
   enough, or the auto-applied fix is semantically wrong. Residual findings are returned in
   the payload; do not retry beyond the cap.
2. **Interdependent findings**: fixing finding A exposes finding B in the same function.
   This is a structural code problem, not a sensor problem. Escalate to `build-refine` with
   the residual findings rather than retrying.
3. **Hook side-effects on generated files**: a hook regenerates a file (e.g. `biome --write`
   on a TypeScript file with mixed ESM/CJS exports), producing a drift between the generated
   output and a committed snapshot. Treat as `STRUCTURAL` — carry over in the PR and note the
   regeneration behavior.

In all non-convergence cases: write the `sensors-loop-complete` JSONL entry with `residual`
populated, return `ok: false`, let the orchestrator decide.
