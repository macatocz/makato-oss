---
name: manage-stores
description: >-
  Use when user wants to register, list, or remove a cross-repo store entry in
  `.claude/config.json`. Manages the `stores[]` array that `to-issues` uses to
  resolve a `--store <id>` flag to a target repo without repeating the full
  `owner/repo` path on every invocation. Trigger keywords: register store, add
  store, list stores, remove store, manage store, cross-repo store. Do NOT load
  for read-only to-issues runs or for any field other than stores[].
version: "1.1.0"
argument-hint: "register <id> <owner/repo> <description> | list | remove <id>"
allowed-tools: Bash(git *) Bash(bash *) Read
hooks: ["register store", "add store", "list stores", "remove store", "manage store", "cross-repo store"]
metadata:
  Authors: makato contributors
  last_updated: "2026-08-05"
  mcp_server: none
---

# Manage Stores

Manage cross-repo store entries in `.claude/config.json → stores[]`. Each
entry maps a short `id` to an `owner/repo` path and a human-readable
description, allowing `to-issues --store <id>` to publish GitHub issues to a
different repository without repeating the full path on every invocation.

All mutations delegate to `scripts/manage-stores.sh` — this skill describes
when and how to invoke it correctly.

Do NOT load this skill for read-only `to-issues` runs, for `--repo owner/repo`
one-off overrides, or for any other `.claude/config.json` field.

## When to Use

- Before running `to-issues --store <id>` for the first time on a new target repo
- When a stored repo path changes and the existing entry needs updating (`register` is idempotent)
- When a store entry is no longer needed and should be cleaned up
- When an operator needs a quick list of all registered stores in the config

## When NOT to Use

- To publish issues (use `to-issues`)
- To create or edit `.claude/config.json` fields other than `stores[]`
- When `--repo owner/repo` can be passed directly to `to-issues` for a one-off override — no permanent state needed

## Decision: register vs. `--repo` for a one-off

Ask: "Will this target repo be used more than once, across sessions or scripts?"
- Yes → `register` now, use `--store <id>` going forward
- No → pass `--repo owner/repo` to `to-issues` directly; skip this skill

## Sub-Commands

### register

Adds a new store entry or updates an existing one in-place (no duplicates).
Creates `.claude/config.json` with `{"stores": []}` if the file does not exist.
Reads the full file, mutates only `stores[]`, writes the whole file back — all
other top-level fields (`project`, `github_project`, etc.) are preserved.

**Signature:**

```
manage-stores.sh register <id> <owner/repo> <description>
```

| Argument | Format | Example |
|---|---|---|
| `id` | `^[a-z0-9][a-z0-9_-]*$` (lowercase, digits, `-`, `_`) | `platform` |
| `owner/repo` | `owner/name` — no URL, no trailing slash | `macatocz/platform` |
| `description` | Non-empty string | `"Platform monorepo"` |

**Example:**

```bash
bash "$SCRIPT" register platform macatocz/platform "Platform monorepo"
```

### list

Prints all registered store entries, one per line, tab-separated:
`id<TAB>owner/repo<TAB>description`. Exits silently (status 0) when the config
file does not exist yet.

**Signature:**

```
manage-stores.sh list
```

**Output sample:**

```
platform    macatocz/platform    Platform monorepo
infra       macatocz/infra       Infrastructure repo
```

### remove

Removes the store entry with the given `id`. Exits status 1 with an error
message to stderr if the `id` is not found. Does NOT modify the file on exit 1.

**Signature:**

```
manage-stores.sh remove <id>
```

## Process

### Step 1 — Identify the sub-command

Parse the user's intent to one of: `register`, `list`, or `remove`. When the
user asks to "update" a store, map this to `register` — register is idempotent
(same-id = in-place update, no duplicates created).

When intent is ambiguous between registering a new entry and running a one-off
`--repo`, apply the "register vs. `--repo`" decision above before proceeding.

### Step 2 — Resolve the repo root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-plan/scripts/manage-stores.sh"
```

Note: when run outside a git repo, the script falls back to `REPO_ROOT="."` and
resolves the config relative to the current working directory. This is a
test-harness escape valve — in normal use `git rev-parse` must succeed.

### Step 3 — Invoke manage-stores.sh

```bash
# register
bash "$SCRIPT" register "<id>" "<owner/repo>" "<description>"

# list
bash "$SCRIPT" list

# remove
bash "$SCRIPT" remove "<id>"
```

The script reads/writes `$REPO_ROOT/.claude/config.json` by default; override
via `MANAGE_STORES_CONFIG` (used by test harness only — never in production).

### Step 4 — Confirm outcome

- `register`: confirm entry was added or updated; show current `list` output.
- `list`: display the tab-separated table to the user.
- `remove`: confirm deletion; show remaining entries.

## Anti-patterns

**NEVER edit `.claude/config.json` directly with Write or Edit.**
The Python script handles idempotent upsert, missing-file creation, and safe
in-place JSON rewriting with `json.dump`. Direct edits risk malformed JSON that
will cause every subsequent `register`, `list`, and `remove` to exit 1 without
writing — the damage compounds silently until the file is fixed by hand.

**NEVER pass a URL as the `<owner/repo>` argument.**
The argument must be the bare `owner/name` path (e.g. `macatocz/platform`), not
`https://github.com/macatocz/platform`. The script stores the value verbatim; a
URL-valued `repo` field causes `to-issues` to construct a malformed API target.

**NEVER use an id with uppercase letters, spaces, or dots.**
The schema pattern is `^[a-z0-9][a-z0-9_-]*$`. The script does NOT validate the
pattern on write — a non-conforming id is silently stored, then fails at
invocation time when `to-issues --store <id>` processes its argument list.

**NEVER assume `register` deleted an old entry when updating.**
`register` performs an in-place slot update: the same index in `stores[]` is
overwritten. The old entry is gone only for that id. If you need to rename an
id, you must `remove <old-id>` first, then `register <new-id> ...`.

**NEVER run store commands while another process may be writing `config.json`.**
The Python rewrite is not atomic (read-modify-write with no file lock). Concurrent
writes from `issue-to-project --init` or another `manage-stores.sh` call will
produce a race condition — last writer wins, silently dropping the other change.

## Failure Modes and Handling

### git rev-parse fails (not a git repo)
The script falls back to `REPO_ROOT="."`. The config file resolves to
`./.claude/config.json` relative to the current working directory — which is
likely wrong. Symptom: a new `config.json` appears in an unexpected directory.
Fix: run the command from inside the git repository root.

### config.json contains malformed JSON
All three sub-commands detect this, print a diagnostic to stderr, and exit 1
**without modifying the file**. Recovery steps:
1. Validate: `python3 -m json.tool .claude/config.json`
2. Fix by hand, then retry the store command.
3. If stores content is lost entirely, delete and let `register` recreate it.
   Other fields (`project`, `github_project`) must be re-added manually after.

MANDATORY: load `references/config-schema.md` when diagnosing schema or
malformed-JSON failures.

### remove on a non-existent id
Exits 1 with `manage-stores: no store with id '<id>' found`. The file is not
modified. No retry is needed — use `list` to discover the correct id spelling.

### id conflict after rename
If an old entry must be renamed: `remove <old-id>` first, then
`register <new-id> <repo> <description>`. Running only `register <new-id>` does
NOT remove the old entry — both will coexist.

## Implementation Reference

`scripts/manage-stores.sh` in the same plugin directory.
Dependencies: `bash`, `python3` stdlib only (`json` module) — no pip packages.

Config schema for `stores[]`: `schemas/config.schema.json` (added in #565).

MANDATORY — load `references/config-schema.md` when:
- Validating whether a proposed `id` or `repo` value will be accepted
- Diagnosing a malformed-JSON failure
- Auditing `.claude/config.json` for schema compliance
