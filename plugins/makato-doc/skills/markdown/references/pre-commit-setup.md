# Pre-commit Hook Integration

Reference for wiring prettier + markdownlint into pre-commit hook frameworks.
Load this file when configuring a pre-commit pipeline for markdown — not for
routine formatting passes.

---

## The Ordering Constraint

Prettier and markdownlint are **not commutative**. Prettier normalises whitespace,
wraps prose, and realigns table columns. Running markdownlint before prettier means
markdownlint validates content that prettier will subsequently reformat — the lint
result is stale the moment the formatter runs. The required order in every hook
framework is:

```text
prettier → markdownlint
```

This is not a preference. It is a hard constraint.

---

## Framework-Specific Configs

### lint-staged (husky)

In `package.json` or `.lintstagedrc`:

```json
{
  "*.md": ["prettier --prose-wrap always --print-width 100 --write", "markdownlint --config .markdownlint.json"]
}
```

**Key behaviour**: lint-staged re-stages modified files automatically between commands.
Prettier runs and modifies the file; lint-staged stages the prettier output; markdownlint
runs on the already-staged (post-prettier) content. This is why the array order matters:
reversing the two commands means markdownlint validates pre-prettier content.

**Pitfall**: using `&&` in a single string (`"prettier ... && markdownlint ..."`) is
equivalent but hides the lint-staged re-staging step — if the prettier command modifies a
file and lint-staged does not re-stage it between the `&&` commands, markdownlint may run
on stale content. Use the array form.

### pre-commit framework

In `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/mirrors-prettier
    rev: v3.1.0
    hooks:
      - id: prettier
        types: [markdown]
        args: [--prose-wrap, always, --print-width, "100"]

  - repo: https://github.com/igorshubovych/markdownlint-cli
    rev: v0.43.0
    hooks:
      - id: markdownlint
        args: [--config, .markdownlint.json]
```

**Critical difference from lint-staged**: the pre-commit framework does NOT re-stage
modified files automatically. If prettier modifies a file, the hook reports
`Files were modified by this hook` and exits non-zero — the commit is blocked and the
user must `git add` the prettier output and commit again. This two-step behaviour is
intentional for the pre-commit framework; it is not an error.

Because markdownlint runs in a separate hook that fires after prettier, it always
validates the prettier-formatted content. The ordering in the YAML (prettier repo listed
before markdownlint repo) enforces this.

**Pitfall**: reversing the repo order causes markdownlint to run on the original content,
then prettier modifies it. The two-step commit lands on prettier output that has never been
linted. The next commit then requires a separate lint pass.

### Plain git hook (`pre-commit` shell script)

```bash
#!/usr/bin/env bash
set -euo pipefail

STAGED_MD=$(git diff --cached --name-only --diff-filter=ACM | grep '\.md$' || true)
[ -z "$STAGED_MD" ] && exit 0

# Step 1: format
echo "$STAGED_MD" | xargs prettier --prose-wrap always --print-width 100 --write
echo "$STAGED_MD" | xargs git add

# Step 2: lint (validates post-prettier content)
echo "$STAGED_MD" | xargs markdownlint --config .markdownlint.json
```

The `git add` between the two commands re-stages the prettier output. Without it,
markdownlint runs on the formatted file on disk but the commit still contains the
pre-prettier content — the CI and local results diverge.

---

## xargs Safety

When the staged file list is empty, xargs with no arguments is a no-op on most Unix
systems — but some configurations will run the command with no arguments, causing
unexpected behaviour. Guard with:

```bash
[ -z "$STAGED_MD" ] && exit 0
```

Or use `xargs -r` (GNU coreutils only — not available on macOS) to skip execution when
stdin is empty.

---

## CI vs Local Divergence

A common failure pattern:

1. Developer runs only markdownlint locally (or uses a hook without prettier).
2. CI runs prettier then markdownlint.
3. Prettier reformats the file, introducing whitespace changes.
4. Markdownlint then flags those changes.
5. The PR fails CI on lines that were clean locally.

The root cause is always the same: local tooling skipped the prettier step that CI runs.
The fix is identical hooks locally and in CI, in the same order.
