<!-- markdownlint-disable MD013 -->
# makato-core: Guided Onboarding (`/makato-core:init`)

This document describes the full `init` wizard flow — what it does in each
phase, what files it writes, and how to interpret the validation summary.

Run the wizard with:

```
/makato-core:init
```

---

## Overview

The `init` skill walks you through three sequential phases:

| Phase | Name | Required? | What it does |
|-------|------|-----------|--------------|
| 1 | Mandatory Setup | Always runs | Installs makato-core, authenticates `gh`, writes `.claude/config.json` |
| 2 | Optional Configuration | Skippable | Projects board, context bundles, Langfuse, tech plugins |
| 3 | Validation Summary | Always runs | Validates Phase 1 outputs and prints a summary table |

Type `skip` at the Phase 2 menu to bypass all optional items and jump straight
to the Phase 3 summary.

---

## Phase 1 — Mandatory Setup

Phase 1 runs every time and must complete before the wizard continues.

### 1.1 — Repository root

The wizard locates the git repository root via `git rev-parse --show-toplevel`.
If the current directory is not inside a git repo the wizard aborts immediately.

### 1.2 — makato-core installation check

```bash
claude plugin list
```

The output is scanned for `makato-core`. If not present, the wizard prints the
install command and aborts:

```bash
claude --plugin-dir ./plugins/makato-core
```

Re-run `/makato-core:init` after installation.

### 1.3 — GitHub CLI authentication check

```bash
gh auth status
```

If `gh` is not authenticated the wizard prints `gh auth login` and aborts.
All subsequent `gh` calls require an active session.

### 1.4 — Project name

The wizard extracts the GitHub remote slug from `git remote get-url origin`
(e.g. `macatocz/makato`) and proposes it as the default project name. Accept
the default by pressing Enter, or type a custom name.

### 1.5 — .claude/config.json

The wizard creates `.claude/` if absent, then writes (or merges into)
`.claude/config.json`:

```json
{
  "project": "<your-project-name>"
}
```

**This is the minimum viable config.** The `project` key is used by
`create-issue`, `issue-to-project`, and the loop driver to scope all GitHub
operations to the correct project board.

The file may contain additional keys added by other skills (e.g.
`github_project` from Phase 2 option 1). The init wizard always merges new
keys rather than overwriting the file.

---

## Phase 2 — Optional Configuration

Phase 2 presents a numbered menu:

```
  (1) Projects board   — link a GitHub Projects v2 board to this repo
  (2) Context bundles  — choose which rule bundles apply to changed files
  (3) Langfuse         — configure Langfuse tracing endpoint and credentials
  (4) Tech plugins     — install additional makato toolkits

Type a number, multiple numbers separated by spaces, or `skip`:
```

### Skipping Phase 2

Type `skip` (or just press Enter) to advance to Phase 3 immediately. No
optional files are created. Each optional item will appear as `—` (dash) in
the Phase 3 summary table.

You can re-run `/makato-core:init` later to configure any item you skipped.

### Option (1) — Projects board

Asks for the GitHub Projects v2 board number and validates it with `gh project
view`. On success, adds `"github_project": "<number>"` to `.claude/config.json`.

This value is consumed by `issue-to-project` when placing new issues on the board.

### Option (2) — Context bundles

Explains the role of `config/context-bundles.yml` — the file that maps
file-path glob patterns to rule-bundle paths. No new file is written; the
wizard checks whether the file already exists and reports accordingly.

See `config/context-bundles.yml` in the repo root for the bundle definitions.

### Option (3) — Langfuse

Collects Langfuse credentials interactively (public key, secret key, host URL)
and offers to write them to `.env.langfuse` in the repo root:

```
LANGFUSE_PUBLIC_KEY=<pk>
LANGFUSE_SECRET_KEY=<sk>
LANGFUSE_HOST=http://localhost:3333
```

**Credentials are never written to `.claude/config.json`.**
If you decline, the values are printed to stdout for manual configuration.

The default host is `http://localhost:3333` (local Langfuse Docker instance).
Change it to your hosted instance URL if applicable.

### Option (4) — Tech plugins

Displays the full plugin catalogue from `references/tech-plugins-menu.md`
and asks which plugins to install. For each selection the wizard runs
`claude plugin list` to confirm the plugin is visible after installation.

See [`references/tech-plugins-menu.md`](../references/tech-plugins-menu.md)
for descriptions and install commands for all 10 installable plugins.

---

## Phase 3 — Validation Summary

Phase 3 always runs. It re-validates every mandatory Phase 1 output and prints
a summary table to stdout:

```
┌─────────────────────────────────────────────────────────────┐
│  makato init — configuration summary                        │
├────────────────────────┬──────────┬────────────────────────┤
│  Item                  │ Status   │ Notes                  │
├────────────────────────┼──────────┼────────────────────────┤
│  makato-core installed │  ✓       │ confirmed via plugin list│
│  gh authenticated      │  ✓       │ gh auth status ok      │
│  .claude/config.json   │  ✓       │ project: my-project    │
│  Projects board        │  —       │ skipped                │
│  Context bundles       │  ✓       │ config/context-bundles.yml found │
│  Langfuse              │  —       │ skipped                │
│  Tech plugins          │  ✓       │ 2 installed            │
└────────────────────────┴──────────┴────────────────────────┘
```

- `✓` — configured or validated successfully
- `—` — skipped during Phase 2 (can be configured later)
- `✗` — mandatory item failed (re-run init after fixing)

If any mandatory item shows `✗`, the wizard prints remediation instructions and
tells you to re-run `/makato-core:init`.

The Phase 3 summary is printed to the console only — it is **not written to any
file**.

---

## .claude/config.json — Expected Shape

After a full Phase 1 + Phase 2 run, `.claude/config.json` may contain:

```json
{
  "project": "my-project-name",
  "github_project": "5"
}
```

**Minimum viable config (Phase 1 only):**

```json
{
  "project": "my-project-name"
}
```

Keys added by other skills (e.g. `issue-to-project` caching board/field IDs)
will appear alongside these. The init wizard never removes existing keys.

---

## Re-running the Wizard

`/makato-core:init` is idempotent:

- If `.claude/config.json` already exists, Phase 1.5 merges the `project` key
  without overwriting other keys.
- Phase 2 options can be re-run individually to update a single item.
- Phase 3 always re-validates the current state.

---

## Troubleshooting

| Symptom | Remedy |
|---------|--------|
| `Cannot run init — not inside a git repository` | `cd` into a git repo before running the wizard |
| `makato-core is not yet installed` | Run `claude --plugin-dir ./plugins/makato-core` first |
| `gh auth: not authenticated` | Run `gh auth login` then re-run the wizard |
| Phase 3 shows `✗` for `.claude/config.json` | Check file permissions on `.claude/` directory |
| Tech plugin not visible after install | Restart Claude Code to reload the plugin registry |

---

## See Also

- `references/tech-plugins-menu.md` — full catalogue of installable plugins
- `skills/create-workflow-schema/SKILL.md` — customise the build pipeline after init
- `skills/makato-guide/SKILL.md` — discover all available skills across installed plugins
- `config/context-bundles.yml` — rule bundle definitions for changed-file routing
