# Scope and hook-stage selection guide

MANDATORY: load at Step 2 when the caller provides no explicit `scope`, or when choosing which scope is ambiguous.
Do NOT load this reference for other purposes.

## When to use each scope

| Scope | Hook stage | File source | Use when |
|-------|-----------|-------------|----------|
| `staged` | `pre-commit` | `git diff --cached --name-only` | Running gate-0 immediately before a commit. Only checks what the committer is about to land — fastest path. |
| `all` | `manual` | `git ls-files` + intent-to-add | Validating an entire branch mid-session when no staged set exists, or when `sensor-fixer` finishes and you want a global clean confirmation. Scans all tracked files + any untracked files registered with `git add -N`. |
| `changed-vs-main` | `pre-push` | `git diff origin/<default> --name-only` | Final pre-push gate: everything the PR will add to the default branch. Catches cross-file regressions introduced by the full feature diff but not visible in a single commit's staged set. |
| `branch` | `manual` | `git diff --name-only --diff-filter=d "$(git merge-base HEAD "$DEFAULT_REF")"` ∪ untracked registered with `git add -N` | Gate 0 when CI pre-commit sensors use changed-file scope; checks the branch diff plus uncommitted work. |

## Non-obvious failure mode: CI/local mismatch on new files

`git ls-files` returns **tracked + intent-to-add only**. A new file that has never been
added to the index does not appear in `--all-files` scope. This means:

- Session creates `app/tools/new_helper.py`, never runs `git add`
- Local `all` scope: hook does not touch `new_helper.py` → passes
- CI: file is tracked after commit → hook flags it → pipeline red

Fix: register untracked files before running `all` scope:

```bash
UNTRACKED="$(git ls-files --others --exclude-standard)"
[ -n "$UNTRACKED" ] && git add -N -- ${UNTRACKED}
```

`git add -N` marks files intent-to-add without staging content. Reversible with `git restore --staged <file>`.

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
