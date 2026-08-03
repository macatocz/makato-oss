---
name: init
description: >-
  Guided 3-phase onboarding wizard for a new makato repository — installs
  makato-core, authenticates GitHub CLI, writes .claude/config.json, optionally
  sets up context bundles / Langfuse / tech plugins, and prints a validation
  summary table. Use when setting up makato in a repo for the first time, or
  when prompted by HALT-006 with no existing config.
version: "1.0.0"
argument-hint: ""
---

# init

Interactive 3-phase onboarding wizard. Runs sequentially: Phase 1 is mandatory,
Phase 2 is optional (typing `skip` skips all optional steps), Phase 3 validates
and prints a summary.

## When to Use

- Setting up makato in a repository for the first time
- The repository has no `.claude/config.json`
- HALT-006 fires because no spec folder or config is found
- A developer joins a project and wants to configure their local makato environment

## When NOT to Use

- `.claude/config.json` already exists and only specific values need updating —
  edit the file directly instead
- Only a single plugin is needed without the full wizard — install manually with
  `claude --plugin-dir ./plugins/<name>`

## Output

- `.claude/config.json` with at least a `project` key (Phase 1)
- Zero or more optional config artefacts depending on Phase 2 choices
- A Phase 3 summary table printed to the console (never written to disk)

---

## Workflow

### Phase 1 — Mandatory Setup

Phase 1 always runs and must complete before Phase 2 begins.

#### Step 1.1 — Resolve repository root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```

If this fails: abort with:
> "Cannot run init — not inside a git repository."

#### Step 1.2 — Check makato-core installation

Run:

```bash
claude plugin list 2>/dev/null
```

Scan the output for `makato-core`. If present, print:

> "[init] makato-core: already installed ✓"

If absent, instruct the user:

> "[init] makato-core is not yet installed. Install it with:
>
> ```bash
> claude --plugin-dir ./plugins/makato-core
> ```
>
> Then re-run `/makato-core:init`."
>
> Abort — Phase 1 cannot continue without makato-core.

#### Step 1.3 — Check GitHub CLI authentication

Run:

```bash
GH_HOST=github.com gh auth status 2>&1
```

If the output contains `Logged in` or `You are logged into`: print:

> "[init] gh auth: authenticated ✓"

Otherwise print:

> "[init] gh auth: not authenticated — run `gh auth login` then re-run `/makato-core:init`."
>
> Abort — Phase 1 cannot continue without an authenticated CLI.

#### Step 1.4 — Gather project identity

Determine the GitHub remote:

```bash
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
```

Example result: `macatocz/makato`.

Ask the user:

> "What is this project called? (default: `<REPO_SLUG>`)"

Accept Enter to use the default. Store the result as `PROJECT_NAME`.

#### Step 1.5 — Write .claude/config.json

Create `.claude/` if absent:

```bash
mkdir -p "$REPO_ROOT/.claude"
```

Write `.claude/config.json`:

```json
{
  "project": "<PROJECT_NAME>"
}
```

If the file already exists, merge the new `project` key into the existing JSON
without overwriting other keys.

Print:

> "[init] .claude/config.json written ✓  (project: <PROJECT_NAME>)"

---

### Phase 2 — Optional Configuration

Present the following menu:

```
Phase 2: Optional setup — type a number to configure, or type `skip` to finish.

  (1) Projects board   — link a GitHub Projects v2 board to this repo
  (2) Context bundles  — choose which rule bundles apply to changed files
  (3) Langfuse         — configure Langfuse tracing endpoint and credentials
  (4) Tech plugins     — install additional makato toolkits

Type a number, multiple numbers separated by spaces, or `skip`:
```

Wait for input. Accepted values: `1`, `2`, `3`, `4`, any combination, or `skip`.
Typing `skip` immediately advances to Phase 3 without creating any optional files.

Track which items were configured vs. skipped in a results map used in Phase 3:

```
PHASE2_RESULTS = {
  "Projects board":  "skipped" | "configured",
  "Context bundles": "skipped" | "configured",
  "Langfuse":        "skipped" | "configured",
  "Tech plugins":    "skipped" | "configured",
}
```

#### Option (1) — Projects board

Ask:

> "Enter the GitHub Projects v2 board number for this repo (e.g. `5`):"

Validate with:

```bash
GH_HOST=github.com gh project view "<number>" --owner "<REPO_OWNER>" 2>&1
```

Where `REPO_OWNER` is the org/user extracted from `REPO_SLUG` (everything before `/`).

If valid: add `"github_project": "<number>"` to `.claude/config.json` and mark
"Projects board" as `configured`.

If the command fails: print a warning and mark as `skipped`.

#### Option (2) — Context bundles

Print:

> "Context bundles tell makato-build which rule files apply when specific paths
> change. The bundles are defined in `config/context-bundles.yml`.
>
> Inspect `config/context-bundles.yml` to review the available bundles, then
> ensure your changed-file patterns are covered. No file is created here — the
> config file is already active once it exists."

Check whether `$REPO_ROOT/config/context-bundles.yml` exists:

- If yes: print `[init] context-bundles.yml found ✓` and mark as `configured`.
- If no: print `[init] config/context-bundles.yml not found — create it when you
  add your first context bundle.` Mark as `skipped`.

#### Option (3) — Langfuse

Ask:

> "Enter your Langfuse public key (or press Enter to skip):"

If Enter: mark as `skipped` and continue.

If a key is provided, also ask:

> "Enter your Langfuse secret key:"
> "Enter your Langfuse host URL (default: http://localhost:3333):"

Accept Enter for the default host. Then ask:

> "Write these to `.env.langfuse` in the repo root? (y/n)"

If y: write `.env.langfuse`:

```
LANGFUSE_PUBLIC_KEY=<key>
LANGFUSE_SECRET_KEY=<secret>
LANGFUSE_HOST=<host>
```

Print `[init] .env.langfuse written ✓` and mark as `configured`.

If n: print the env vars to stdout for manual configuration and mark as `skipped`.

**Never write Langfuse credentials into `.claude/config.json`.**

#### Option (4) — Tech plugins

Load @references/tech-plugins-menu.md and display the numbered list of
installable plugins.

Ask:

> "Which plugins do you want to install?
> Enter numbers separated by spaces (e.g. `1 3 5`), or press Enter to skip:"

If Enter: mark as `skipped` and continue.

For each selected plugin:

1. Print the `claude plugin install` command for that plugin.
2. Run:
   ```bash
   claude plugin list 2>/dev/null
   ```
   Check whether the plugin now appears in the list.
3. If present: print `[init] <plugin-name>: installed ✓`
4. If absent: print `[init] <plugin-name>: not yet visible — you may need to
   restart Claude Code.`

Mark "Tech plugins" as `configured` if at least one was successfully confirmed.

---

### Phase 3 — Validation Summary

Phase 3 always runs, even when `skip` was typed in Phase 2.

#### Step 3.1 — Validate Phase 1 outputs

Re-check each mandatory Phase 1 output:

| Check | Command / path |
|---|---|
| makato-core installed | `claude plugin list` contains `makato-core` |
| gh authenticated | `gh auth status` succeeds |
| `.claude/config.json` exists | file present at `$REPO_ROOT/.claude/config.json` |
| `project` key present | `project` key is non-empty in the JSON |

#### Step 3.2 — Print summary table

Print to stdout:

```
┌─────────────────────────────────────────────────────────────┐
│  makato init — configuration summary                        │
├────────────────────────┬──────────┬────────────────────────┤
│  Item                  │ Status   │ Notes                  │
├────────────────────────┼──────────┼────────────────────────┤
│  makato-core installed │  ✓       │ confirmed via plugin list│
│  gh authenticated      │  ✓       │ gh auth status ok      │
│  .claude/config.json   │  ✓       │ project: <PROJECT_NAME>│
│  Projects board        │  ✓ / —  │ board #N / skipped     │
│  Context bundles       │  ✓ / —  │ found / not found      │
│  Langfuse              │  ✓ / —  │ .env.langfuse / skipped│
│  Tech plugins          │  ✓ / —  │ N installed / skipped  │
└────────────────────────┴──────────┴────────────────────────┘
```

Use `✓` for configured/confirmed, `—` for skipped or absent.

If any mandatory item shows a failure (`✗`), append:

> "One or more mandatory items failed. Re-run `/makato-core:init` after fixing
> the issues listed above."

#### Step 3.3 — Print next steps

Print:

```
Next steps:
  • Run /build-start to begin a build session
  • Run /makato-guide to explore available skills
  • Install tech plugins now or later with: claude --plugin-dir ./plugins/makato-<name>
  • See docs/onboarding.md for full documentation of this wizard
```
