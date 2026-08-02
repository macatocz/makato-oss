---
name: manage-stores
description: >-
  Use when user wants to register, list, or remove a cross-repo store entry in
  `.claude/config.json`. Manages the `stores[]` array that `to-issues` uses to
  resolve a `--store <id>` flag to a target repo without repeating the full
  `owner/repo` path. Delegates to `scripts/manage-stores.sh`.
version: "1.0.0"
argument-hint: "register <id> <owner/repo> <description> | list | remove <id>"
allowed-tools: Bash(git *) Bash(bash *) Read Write
hooks: ["register store", "add store", "list stores", "remove store", "manage store", "cross-repo store"]
metadata:
  Authors: makato contributors
  last_updated: "2026-08-02"
  mcp_server: none
---

# Manage Stores

Manage cross-repo store entries in `.claude/config.json → stores[]`. Each
entry maps a short `id` to an `owner/repo` path and a human-readable
description, allowing `to-issues --store <id>` to publish GitHub issues to a
different repository without repeating the full path on every invocation.

All mutations are delegated to `scripts/manage-stores.sh` — this skill
describes when and how to invoke it.

## When to Use

- Before running `to-issues --store <id>` for the first time on a new target repo
- When a stored repo path changes and the existing entry needs updating
- When a store entry is no longer needed and should be cleaned up
- When an operator needs a quick list of all registered stores in the config

## When NOT to Use

- To publish issues (use `to-issues`)
- To create or edit `.claude/config.json` fields other than `stores[]`
- When `--repo owner/repo` can be passed directly to `to-issues` for a one-off override

## Sub-Commands

### register

Adds a new store entry or updates an existing one in-place (no duplicates).
Creates `.claude/config.json` with an empty `stores: []` if the file does not
exist.

**Signature:**

```
manage-stores.sh register <id> <owner/repo> <description>
```

| Argument | Description |
|---|---|
| `id` | Short identifier used with `--store` in `to-issues` |
| `owner/repo` | Full GitHub repository path (e.g. `macatocz/platform`) |
| `description` | Human-readable label for the entry |

**Example:**

```bash
bash plugins/makato-plan/scripts/manage-stores.sh \
  register platform macatocz/platform "Platform monorepo"
```

### list

Prints all registered store entries, one per line, tab-separated:
`id<TAB>owner/repo<TAB>description`.

**Signature:**

```
manage-stores.sh list
```

**Example:**

```bash
bash plugins/makato-plan/scripts/manage-stores.sh list
```

**Output sample:**

```
platform    macatocz/platform    Platform monorepo
infra       macatocz/infra       Infrastructure repo
```

### remove

Removes the store entry with the given `id`. Exits with status 1 and an
informative error message if the `id` is not found.

**Signature:**

```
manage-stores.sh remove <id>
```

| Argument | Description |
|---|---|
| `id` | Identifier of the entry to delete |

**Example:**

```bash
bash plugins/makato-plan/scripts/manage-stores.sh remove infra
```

## Process

### Step 1 — Identify the sub-command

Parse the user's intent to one of: `register`, `list`, or `remove`.

### Step 2 — Resolve the repo root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-plan/scripts/manage-stores.sh"
```

### Step 3 — Invoke manage-stores.sh

Run the appropriate sub-command with the resolved arguments. The script
reads and writes `$REPO_ROOT/.claude/config.json` by default; the path can
be overridden via `MANAGE_STORES_CONFIG` (used by tests).

```bash
# register
bash "$SCRIPT" register "<id>" "<owner/repo>" "<description>"

# list
bash "$SCRIPT" list

# remove
bash "$SCRIPT" remove "<id>"
```

### Step 4 — Confirm outcome

- `register`: confirm the entry was added or updated; show the current `list` output.
- `list`: display the tab-separated table to the user.
- `remove`: confirm deletion; show the remaining entries.

## Implementation Reference

The implementation lives in `scripts/manage-stores.sh` (same plugin directory).
The script uses only `bash` and Python 3 stdlib (`json` module) — no external
dependencies.

Config schema for `stores[]` is defined in
`schemas/config.schema.json` (added in #565).
