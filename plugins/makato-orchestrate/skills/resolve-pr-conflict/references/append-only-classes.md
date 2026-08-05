# Append-Only File Classes

Union-merge is safe ONLY for files whose invariants hold:
1. Both sides exclusively add lines (no line is modified or deleted).
2. Order within the file is not load-bearing beyond "newest block first" (which union preserves per-side).
3. A duplicate line does not break the consumer (callers parse independently per release/entry).

If ANY invariant is violated — fall back to ours-wins for the conflicting hunks.

## Canonical Allow-List

| Match rule | Examples | Invariant rationale |
|---|---|---|
| Basename `CHANGELOG.md` or `CHANGELOG` | project root changelog | Prepend-only; each PR adds its own block at top |
| Basename `AUTHORS` or `AUTHORS.md` | contributor lists | Append-only lines; duplicates harmless |
| Basename `CONTRIBUTORS` or `CONTRIBUTORS.md` | contributor lists | Same as AUTHORS |
| Extension `*.jsonl` | `build.jsonl`, `orchestrate.jsonl` | Append-only audit logs; consumers read all lines |

## Extending the Allow-List

To add a new class, confirm ALL three invariants before editing `is_append_only()`.

NEVER add:
- `package-lock.json` / `yarn.lock` — both sides rewrite shared sections (dependency tree rebuild); union produces an unparseable lockfile.
- `*.json` config files — any key present on both sides will appear twice; JSON parsers reject duplicate keys silently or with an error.
- `*.py`, `*.ts`, `*.go` source files — imports and logic blocks are position-sensitive; union duplicates cause syntax errors or double-registration.
- Migration files (`*.sql`, `migrations/*.py`) — sequential ordering is load-bearing; union breaks migration chains.
