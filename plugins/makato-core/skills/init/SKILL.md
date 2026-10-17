---
name: init
description: >-
  Guided 3-phase onboarding wizard for a new makato repository — installs
  makato-core, authenticates GitHub CLI with the GH_HOST=github.com prefix,
  writes .claude/config.json with project and github_project keys, optionally
  sets up context bundles / Langfuse credentials / tech plugins, and prints a
  validation summary table. Use when: setting up makato for the first time,
  HALT-006 fires with no config, developer joins project, onboarding makato,
  init wizard, first-time setup, configure makato, no .claude/config.json.
version: "1.1.1"
argument-hint: ""
allowed-tools: Bash Read
metadata:
  Authors: makato-core
  last_updated: "2026-08-05"
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

## Expert Context — makato-Specific Knowledge

These items are non-obvious without experience in the makato stack:

**`.claude/config.json` schema** — only two keys are consumed by the autonomous
loop: `"project"` (plain string, used as GitHub repo name prefix) and
`"github_project"` (board number as a string, e.g. `"5"`). All other keys are
ignored by the loop but may be read by individual skills.

**`GH_HOST=github.com` prefix** — the makato loop always exports this prefix
before `gh` calls because enterprise GitHub deployments default to a non-github.com
host. Without it, `gh project item-list` silently queries the wrong host. This
init skill follows the same convention to prevent environment drift between the
wizard setup and later loop execution.

**Plugin visibility lag** — `claude plugin list` reflects plugins loaded at
session start, not dynamically installed ones. A freshly-installed plugin will
not appear in the output until Claude Code restarts. This is expected behavior
and is not an installation failure.

**JSON merge on re-run** — when `.claude/config.json` already exists, new keys
must be merged (not overwritten). The safest merge is:
1. `python3 -c "import json,sys; d=json.load(open('...config.json')); d.update({...new keys...}); json.dump(d,sys.stdout,indent=2)"`, then write output.
Use Python rather than `jq` for the merge because `jq` is not guaranteed present.

**REPO_SLUG extraction edge cases** — the `sed` pattern
`s|.*github\.com[:/]||; s|\.git$||` handles both HTTPS
(`https://github.com/org/repo.git`) and SSH (`git@github.com:org/repo.git`)
remotes. It fails silently when there is no `origin` remote or the remote is not
GitHub — detect this via empty `REPO_SLUG` and fall back to asking the user.

**`github_project` validation** — `gh project view <N> --owner <ORG>` exits
non-zero when the board number is wrong or the token lacks `read:project` scope.
A scope failure returns the string `could not resolve` in stderr; a wrong number
returns `project not found`. Distinguish these to give a useful error message.

---

## Anti-Patterns

**NEVER write Langfuse credentials to `.claude/config.json`.**
WHY: `.claude/config.json` is routinely committed to git (it carries non-secret
project metadata). Committing `LANGFUSE_SECRET_KEY` exposes it in every future
clone of the repo. Always direct credentials to `.env.langfuse` (which must be
`.gitignore`d) or print them to stdout for manual configuration.

**NEVER run `jq` to merge `.claude/config.json`.**
WHY: `jq` is not part of the makato toolchain requirement; it is absent on clean
CI images and some developer machines. A missing `jq` causes a silent merge
failure that leaves the config file unchanged, which later triggers HALT-006.
Always use `python3` for JSON merge (Python 3 is required by the repo).

**NEVER omit the `GH_HOST=github.com` prefix from `gh` commands.**
WHY: On SAP and other enterprise machines, `GH_HOST` may be set to an internal
host in the shell environment. Without the explicit prefix, `gh auth status`
succeeds against the enterprise host while the makato loop later fails against
`github.com` — a mismatch that is very hard to diagnose.

**NEVER advance to Phase 2 if Phase 1 fails.**
WHY: Optional steps (Projects board validation, plugin install verification) call
`gh project view` and `claude plugin list`, both of which depend on Phase 1
artifacts (authenticated CLI, known `REPO_OWNER`). A partial Phase 1 produces
misleading Phase 2 success messages that mask the underlying failure.

**NEVER overwrite `.claude/config.json` if it already exists; always merge.**
WHY: Re-running init on an existing project is a valid workflow (e.g., adding a
`github_project` key after the board was created). Overwriting silently drops
other keys written by other skills (e.g., `"lesson_labels"`, `"slug_prefix"`).
Parse and merge; never replace.

**NEVER create `.claude/config.json` outside `$REPO_ROOT`.**
WHY: If `git rev-parse --show-toplevel` is not used and the agent uses `pwd`
instead, a nested working directory resolves the wrong root. The config file
ends up in a subdirectory where the loop cannot find it, causing HALT-006 on
every subsequent dispatch.

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

If output contains `could not resolve`:
> "[init] gh auth: wrong host — run `GH_HOST=github.com gh auth login` then re-run `/makato-core:init`."
> Abort.

Otherwise (any other failure):
> "[init] gh auth: not authenticated — run `GH_HOST=github.com gh auth login` then re-run `/makato-core:init`."
> Abort — Phase 1 cannot continue without an authenticated CLI.

#### Step 1.4 — Gather project identity

Determine the GitHub remote:

```bash
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
```

Example result: `macatocz/makato`.

If `REPO_SLUG` is empty (no `origin` remote or non-GitHub host): do not use a
default — ask the user to provide the `org/repo` slug directly.

Use **AskUserQuestion** with:
- question: `"What is this project called?"`
- options: [`"<REPO_SLUG> (detected)"`, `"Enter custom name"`]

If the user selects the detected value or enters a custom name, store as
`PROJECT_NAME`. If the user selects custom, prompt for freeform input.

Extract `REPO_OWNER` as everything before the first `/` in `PROJECT_NAME`.

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

If the file already exists, merge using Python (never overwrite):

```bash
python3 - <<'EOF'
import json, sys
path = "$REPO_ROOT/.claude/config.json"
try:
    with open(path) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    d = {}
d["project"] = "$PROJECT_NAME"
with open(path, "w") as f:
    json.dump(d, f, indent=2)
print("merged")
EOF
```

If the Python command exits non-zero: abort with
> "[init] Failed to write .claude/config.json — check file permissions."

Print:

> "[init] .claude/config.json written ✓  (project: <PROJECT_NAME>)"

---

### Step 1.6 — Install the project learning contract

Preserve existing instructions and add a concise project-memory section to
`AGENTS.md` (or its existing authority if `CLAUDE.md` is a symlink). This is
required for ordinary sessions, not just autonomous PO-agent runs:

- At session start, read the main git checkout’s `.makato/memory/procedural.jsonl`
  and `semantic.jsonl`, or use the installed orchestrate `recall-lessons` helper.
  Missing stores mean no prior memory, not a reason to fabricate entries.
- Before completion or handoff, review verified discoveries and capture reusable
  procedures (`procedural`) and technical facts (`semantic`) through the installed
  build `shared/write-lessons.sh`, from the consumer checkout. Create a task spec
  folder if this is an ad-hoc task; pass `--issue N` for shared feature specs.
- A successful generalizable capture must appear in the main checkout’s
  `.makato/memory/` and be recallable immediately; no merge is required. Retain
  source records and report nonzero persistence errors.
- No useful new learning is legitimate: record a reason in the task audit or
  handoff. Never invent lessons, copy secrets, or silently treat host-specific
  OMP/Claude memory as the project store.

Resolve helper roots from the installed plugin locations, never assume the
consumer repo has a `plugins/` directory. Keep the policy harness-independent;
re-running init must update the existing section rather than duplicate it.

### Phase 2 — Optional Configuration

Present the following menu using **AskUserQuestion**:
- question: `"Phase 2: Optional setup — which items do you want to configure?"`
- options: [`"(1) Projects board"`, `"(2) Context bundles"`, `"(3) Langfuse"`, `"(4) Tech plugins"`, `"skip (finish Phase 2)"`]
- allow multiple selections

Wait for input. Typing `skip` immediately advances to Phase 3 without creating any optional files.
If an unrecognised input is entered, re-display the menu with:
> "[init] Unrecognised input — please choose from the list."

Track which items were configured vs. skipped in a results map used in Phase 3:

```
PHASE2_RESULTS = {
  "Projects board":  "skipped" | "configured" | "failed",
  "Context bundles": "skipped" | "configured",
  "Langfuse":        "skipped" | "configured",
  "Tech plugins":    "skipped" | "configured",
}
```

#### Option (1) — Projects board

Use **AskUserQuestion** with:
- question: `"Enter the GitHub Projects v2 board number for this repo (e.g. 5):"`
- options: [`"Enter a number"`, `"skip"`]

If skip: mark as `skipped` and continue.

Validate with:

```bash
GH_HOST=github.com gh project view "<number>" --owner "<REPO_OWNER>" 2>&1
```

Where `REPO_OWNER` is the org/user extracted from `PROJECT_NAME` (everything before `/`).

- If valid: add `"github_project": "<number>"` to `.claude/config.json` (via Python
  merge) and mark "Projects board" as `configured`.
- If stderr contains `could not resolve`: print warning about missing `read:project`
  OAuth scope and mark as `failed`.
- If stderr contains `project not found`: print warning about wrong board number and
  mark as `failed`.

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

Use **AskUserQuestion** with:
- question: `"Langfuse credentials — how do you want to configure them?"`
- options: [`"Write to .env.langfuse in repo root"`, `"Print to stdout only (no file)"`, `"skip"`]

If skip: mark as `skipped` and continue.

Prompt for: Langfuse public key, Langfuse secret key, Langfuse host URL
(default: `http://localhost:3333`). Collect these as freeform input.

If write-to-file: write `.env.langfuse`:

```
LANGFUSE_PUBLIC_KEY=<key>
LANGFUSE_SECRET_KEY=<secret>
LANGFUSE_HOST=<host>
```

Then verify `.env.langfuse` appears in the repo's `.gitignore`. If it does not:
> "[init] WARNING: .env.langfuse is not in .gitignore — add it before committing."

Print `[init] .env.langfuse written ✓` and mark as `configured`.

If print-only: print the three env var lines to stdout and mark as `skipped`.

#### Option (4) — Tech plugins

> MANDATORY: Load @references/tech-plugins-menu.md now and display the numbered
> list of installable plugins to the user.
>
> Do NOT load references/tech-plugins-menu.md outside Option (4).

Use **AskUserQuestion** with:
- question: `"Which plugins do you want to install? Enter numbers separated by spaces, or skip."`
- options: (display the plugin names from the loaded reference as selectable items, plus `"skip"`)

If skip: mark as `skipped` and continue.

For each selected plugin:

1. Print the `claude plugin install` command for that plugin.
2. Run:
   ```bash
   claude plugin list 2>/dev/null
   ```
   Check whether the plugin now appears in the list.
3. If present: print `[init] <plugin-name>: installed ✓`
4. If absent: print `[init] <plugin-name>: not yet visible — restart Claude Code
   to complete activation. This is expected after a fresh install.`

Mark "Tech plugins" as `configured` if at least one was successfully confirmed.

---

### Phase 3 — Validation Summary

Phase 3 always runs, even when `skip` was typed in Phase 2.

#### Step 3.1 — Validate Phase 1 outputs

Re-check each mandatory Phase 1 output:

| Check | Command / path |
|---|---|
| makato-core installed | `claude plugin list` contains `makato-core` |
| gh authenticated | `GH_HOST=github.com gh auth status` succeeds |
| `.claude/config.json` exists | file present at `$REPO_ROOT/.claude/config.json` |
| `project` key present | `project` key is non-empty in the JSON |

For any check that fails, mark with `✗` in the summary and include a one-line
remediation hint.

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
│  Projects board        │  ✓/✗/—  │ board #N / failed / skipped│
│  Context bundles       │  ✓ / —  │ found / not found      │
│  Langfuse              │  ✓ / —  │ .env.langfuse / skipped│
│  Tech plugins          │  ✓ / —  │ N installed / skipped  │
└────────────────────────┴──────────┴────────────────────────┘
```

Use `✓` for configured/confirmed, `—` for skipped or absent, `✗` for explicit
failure.

If any mandatory item shows `✗`, append:

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
