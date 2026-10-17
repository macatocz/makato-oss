---
name: build-create-pr
description: >-
  Generate a pull request from the pushed feature branch. Drafts
  the PR description from spec artifacts — acceptance criteria map
  to How to Test, design decisions surface in the description, Jira
  story is linked. Presents draft for user approval before opening.
  Autonomous runs reuse an open PR and wait for build-fix-ci before handoff.
version: "1.12.3"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools:
  - Bash
  - Read
---

## References

| Reference | MANDATORY trigger | Do NOT Load |
|-----------|-------------------|-------------|
| `@references/pr-description-guide.md` | Load at Step 3 before drafting the PR description body | Do NOT load before Step 3 — the guide is section-filling detail, not entry context |
| `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` | Read at Step 1a when `--autonomous` flag is present, to read activation contract and bypass-log schema | Do NOT read in interactive-only sessions — the reference is autonomous-contract detail that adds noise when running interactively |

---

## When to Use

Use after `/push-to-git` (branch is on remote) and before `/address-pr-comments`. The code is committed and pushed. This step generates a PR description from spec artifacts and opens the pull request for human review.

## Input

When dispatched by the PO-agent (`--autonomous` mode):

- `<work-item-key>` — positional argument (optional; see Step 1a fallback).
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). `gh pr create` and any `git` invocation MUST run from `WORKTREE_PATH` so the PR resolves the correct branch — running from the main checkout would open a PR against the wrong (or no) branch.
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root, resolved from
  the runner plugin-root variables when not supplied.
- `MAKATO_PLAN_ROOT` — optional absolute makato-plan root for validating
  `created-issues.json`; if absent, artifact validation is advisory and must
  not probe the consumer repository.
- `REPO` — GitHub `OWNER/REPO`; resolve from the worktree's origin with
  `gh repo view "$(git remote get-url origin)" --json nameWithOwner --jq .nameWithOwner` when absent.
- `SPEC_FOLDER` / `JSONL_PATH` — resolved main-checkout spec folder and
  build log; forward both to downstream skills.
- `EXISTING_PR_NUMBER` — optional known open PR. It must belong to the current
  worktree branch; never replace a missing/closed/mismatched PR with a new one.
- `CI_REPAIR_ACTIVE` — repair-ownership guard. When true, do not run this skill:
  return R1 failure with `PR_CREATE_FAILED` and direct the caller to the
  existing-PR push-only path in `build-push-to-git`. Never nest a CI repair gate.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables, then apply
the workspace-isolation entry guard from
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` before Step 1's `git status -sb`. In
autonomous mode an empty `WORKTREE_PATH` is a HALT with
`errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in
interactive mode the guard falls back to `git rev-parse --show-toplevel`. After
resolution, `cd "$WORKTREE_PATH"` — every `git`/`gh pr create` command below
runs from this CWD.

**Spec-artefact reads use `REPO_ROOT`, not `WORKTREE_PATH`; `MAKATO_TARGET_REPO_ROOT`
selects the root when set, otherwise the common-dir fallback selects the main checkout.**

```bash
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)}"
```

Every spec-artefact path resolved in Step 1 below (`stories.json`,
`seed-manifest.json`, `prd.md`, `design.md`, `plan.md`, `created-issues.json`)
is under the `SPEC_FOLDER` returned by
`python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"`.
`.github/PULL_REQUEST_TEMPLATE.md` lives in the tracked `.github/` directory
and resolves correctly under either root. See `AUTONOMOUS-MODE.md` § *Two
roots, one contract*.

### Downstream skill dispatch

For headless/autonomous OMP runs, keep the existing downstream-skill dispatch
through `python3 "${MAKATO_SKILL_RUNNER:-$MAKATO_BUILD_ROOT/scripts/run-skill.py}"`
with `--repo-root "$REPO_ROOT" --cwd "$WORKTREE_PATH"`, a complete
`--context-file`, and the inherited harness/role configuration. Wait for the
final R1; a nonzero launcher exit, missing/malformed envelope, `failure`, or
`partial` is not success. Forward the work-item-key, activation context, both
workspace roots, `MAKATO_BUILD_ROOT`, optional sibling roots, `REPO`,
`SPEC_FOLDER`, and `JSONL_PATH` explicitly. Do not forward the `--autonomous`
CLI flag on cross-skill handoffs. If this invocation was activated only by that
flag and `AGENT_ID` is absent, include `AUTONOMOUS_MODE:true` and a `task_id`
in the child context (use the work-item key when no dispatch id exists), so
standalone autonomous execution remains headless.

In a human-driven OMP interactive run, do not launch a follow-on workflow skill
through `run-skill.py` or a same-session Skill call. Complete this skill's own
PR approval/create work, then provide any later workflow step as an explicit
clean-context instruction. Claude mode keeps its native skill invocation.

## Workflow

### Step 1 — Ask for work item key and load context

Use **AskUserQuestion** with selectable options:

> "Which work item are we creating a PR for?"
> Options: [ "DCP-1234 (paste your key)", "GitHub #N (paste issue number)", "No issue link — proceed without" ]

Or use the passed argument directly. A work item key is optional; if none is provided, the PR is created without an issue link.

Verify the branch is pushed: run `git status -sb` and check that the upstream tracking branch exists and no local commits are ahead of it. If commits are ahead of remote, stop and tell the user:

> "Branch has unpushed commits. Run `/push-to-git` first."

### Step 1a — Mode detection

The skill runs in `--interactive` mode by default; autonomous mode opts in per dispatch. When `--autonomous` is present, read
`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` (MANDATORY — see References table) to
read the activation contract (§ *Activation triggers*) and the per-gate default
table.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
1. If an argument was passed: use it.
2. Otherwise, inspect the most-recent `$REPO_ROOT/specs/*/build.jsonl`
   session entry (last entry where `step:"session"` and `status:"start"`) and
   extract the top-level `story` field as the key. Do NOT use `data.issue` or
   `data.story` (those fields do not exist in the build.jsonl schema) and do
   NOT rely on `data.branch` for key recovery — that field is only written by
   push-to-git and may be absent at this point.
3. If neither step yields a key: HALT with `MISSING_INPUT: build-create-pr in --autonomous mode requires a work-item-key argument or a populated build.jsonl session entry`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-create-pr "<key>" work-item-key "<use-arg|read-build-jsonl>" "<agent_id|cli_flag|task_id_bundle>"` when bypassed.

Resolve `SPEC_FOLDER` with:

```bash
SPEC_FOLDER="$(
  python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"
)"
JSONL_PATH="${JSONL_PATH:-$SPEC_FOLDER/build.jsonl}"
```

If `stories.json` exists, select exactly one entry using the work-item key or
issue number; never read/print the module-wide JSON array into context. The
schema's canonical identifier is the selected record's `.key`:

```bash
ISSUE_NUMBER=""
if [[ -n "$KEY" && "$KEY" =~ ^([[:alpha:]][[:alnum:]]*[-#])?#?([0-9]+)$ ]]; then
  ISSUE_NUMBER="${BASH_REMATCH[2]}"
fi
STORY_JSON=""
STORY_KEY="$KEY"
if [[ -f "$SPEC_FOLDER/stories.json" ]]; then
  STORY_MATCHES="$(jq -c --arg key "$KEY" --arg issue "$ISSUE_NUMBER" '
    if $key == "" and length == 1 then . else
      [ .[] | select(
          .key == $key
          or ($issue != "" and ((.key | tostring | endswith("-" + $issue))
                                or (.key | tostring | endswith("#" + $issue))))
          or ($issue != "" and (((.issue_number // .number // "") | tostring) == $issue))
        )
      ]
    end' "$SPEC_FOLDER/stories.json")"
  MATCH_COUNT="$(jq 'length' <<<"$STORY_MATCHES")"
fi
```

If there is no work-item key and `stories.json` contains multiple entries, ask
for the exact key, then repeat the selection. A single-story file remains usable
without an issue link. If jq fails, or the selected key/issue number matches
zero or multiple entries, log a terminal `session` error with
`halt_code:"MISSING_INPUT"`, return R1 `status:"failure"`, and do not draft a
PR or guess another story. With exactly one match, set:

```bash
STORY_JSON="$(jq -c '.[0]' <<<"$STORY_MATCHES")"
STORY_KEY="$(jq -r '.key' <<<"$STORY_JSON")"
```

When `stories.json` is absent, `STORY_KEY="$KEY"`; this keeps the existing
plan-only fallback. Do not change the `created-issues.json` Case 4 issue-link
behavior.

Read only the selected story's inputs from `SPEC_FOLDER` (NOT under
`$WORKTREE_PATH` — see the entry guard above):
- `stories.json` — use `STORY_JSON` only (selected by key/issue number above).
- `seed-manifest.json` — query only `.spec_tier`; when it is `plan-only` and
  there is no `stories.json`, `plan.md` `## Acceptance criteria` remains the
  How-to-Test source (see Step 3).
- `plan.md` — read only the current story's plan/task slice; if the plan is for
  one story, the whole plan is that slice.
- `prd.md` and `design.md` — read only the H2 sections that the selected story
  or its plan explicitly references, including their nested content. If neither
  references a section in one of these files, do not read that file. Never read
  either module-wide document in full.
- `$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md` — the project's required PR template.
- `created-issues.json` — handoff artifact emitted by `/makato-plan:to-issues` (optional).

When `created-issues.json` exists and `MAKATO_PLAN_ROOT` is available, validate
it against `$MAKATO_PLAN_ROOT/skills/to-issues/references/created-issues.schema.json`.
When the optional plan root is unavailable, parse the artifact for issue-link
injection, log an advisory `artifact-schema-unavailable` warning, and continue
without schema validation. Never probe `$REPO_ROOT/plugins/makato-plan` as a
fallback.

```bash
ARTIFACT_PATH="$SPEC_FOLDER/created-issues.json"
SCHEMA_PATH=""
if [[ -n "${MAKATO_PLAN_ROOT:-}" ]]; then
  SCHEMA_PATH="$MAKATO_PLAN_ROOT/skills/to-issues/references/created-issues.schema.json"
fi

if [[ -f "$ARTIFACT_PATH" ]]; then
  python3 - "$ARTIFACT_PATH" "$SCHEMA_PATH" <<'PY'
import json
import sys
from pathlib import Path

artifact_path = Path(sys.argv[1])
schema_path = Path(sys.argv[2]) if sys.argv[2] else None

def warn(error):
    print(
        "[build-create-pr] WARNING: %s — continuing without Closes injection"
        % error
    )
    raise SystemExit(0)

try:
    with artifact_path.open(encoding="utf-8") as artifact_file:
        artifact = json.load(artifact_file)
except (OSError, json.JSONDecodeError) as error:
    warn("created-issues.json is unreadable (%s)" % error)

if schema_path is None:
    warn("artifact-schema-unavailable")

try:
    import jsonschema
except ImportError:
    warn("jsonschema is unavailable")

try:
    with schema_path.open(encoding="utf-8") as schema_file:
        schema = json.load(schema_file)
    jsonschema.validate(artifact, schema)
except (
    OSError,
    json.JSONDecodeError,
    jsonschema.exceptions.SchemaError,
    jsonschema.exceptions.ValidationError,
) as error:
    warn("created-issues.json failed schema validation (%s)" % error)

print("[build-create-pr] artifact valid: %d issues" % len(artifact["issues"]))
PY
fi
```

If validation fails (invalid JSON or schema mismatch), log a single warning:
`[build-create-pr] WARNING: specs/<slug>/created-issues.json is malformed (<error>) — continuing without Closes injection`
…and proceed with the current v1.2.0 behavior. Never block PR creation on artifact problems (D21).

Resolve the integration target with `DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"` (returns e.g. `origin/main`); run `git fetch origin --quiet` first so the comparison reflects the latest integration tip. Then run `git log "$DEFAULT_REF..HEAD" --oneline` to see the commits included in this PR. Never compare against the bare local `main` — a stale local `main` reports commits from already-merged PRs (#98).

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","commits":<N>}}'
```

### Step 2a — Reuse the current branch's open PR (autonomous only)

Before drafting or opening anything, resolve `GH_HOST` as in Step 5 and
`REPO` from the supplied context or worktree origin. Set
`JSONL_PATH="$SPEC_FOLDER/build.jsonl"` when it was not supplied. Query:

```bash
BRANCH="$(git -C "$WORKTREE_PATH" branch --show-current)"
gh pr list --repo "$REPO" --state open --head "$BRANCH" \
  --json number,url,headRefName,headRefOid,headRepository
```

Require a nonempty branch and successful, valid API output. Filter to the exact
head branch and head repository matching the worktree's origin, not a fork's
same-named branch. If `EXISTING_PR_NUMBER` is supplied, validate that exact PR
with `gh pr view` and require it to be open and match this branch/repository.
A failed lookup, mismatch, or multiple matching PRs closes the session with
`PR_CREATE_FAILED` (authentication errors use `GH_AUTH_FAILED`); do not
interpret a lookup error as "no PR".

Exactly one matching open PR → capture `PR_NUMBER`, URL, and full head SHA,
log `step:"pr-reused",status:"ok"` with those fields, and skip Steps 3–6.
Continue at Step 7, including the shared CI gate. Do not overwrite the existing
PR title/body or create a second PR. Zero matches and no supplied existing PR
→ continue to Step 3. Interactive mode keeps its current approval/create flow.

---

### Step 3 — Draft the PR description

Load `@references/pr-description-guide.md` (MANDATORY — see References table). Use `.github/PULL_REQUEST_TEMPLATE.md` (already read in Step 1) as the body structure — populate each of its sections from spec artifacts. This ensures the produced PR matches the template enforced by the project rather than a free-form body.

**PR title**: `feat: <story title>` — use `STORY_JSON.title` from the selected
story, or the current story's `plan.md` slice when no story record exists; if no
spec exists, derive from commit messages. Append ` (DCP-1234)` or ` (#42)` when a work item key is available. The full title must fit on one line in GitHub's PR list view: keep it under 72 characters total. Truncate or rephrase the story title if needed; never truncate the issue reference.

**Title format rule**: the title MUST match `^(feat|fix|docs|refactor|test|chore|ci|build|perf|style|revert)(\([a-z0-9-]+\))?: .+$` — the same regex enforced by the CI `pr-title` check. Scope is optional; when present it must be a single `[a-z0-9-]` identifier (no commas, no slashes). For cross-plugin or repo-wide changes, omit the scope entirely (`fix: description`, not `fix(a,b,c): description`). Validate the title against this regex **before** calling `gh pr create` and fail with a clear error if it does not match — do not let CI catch it first.

Fill each template section as follows:

**Description of Changes > What changed**: one bullet per completed task in
the current story's `plan.md` slice — task title + one sentence on what changed.
Do not include tasks from another story. If no `plan.md` exists, derive from the
current story's commit messages.

**Goal Alignment**: plugin name, goal statement (read `AGENTS.md` in the target repo), one sentence connecting this story to the goal.

**Links**: see Step 6 for issue tracker handling. When `created-issues.json` is present and valid, the Links section receives an auto-injected `Closes #N` line per artifact entry (in artifact order), deduped against any user-supplied `GH#N` reference — see Step 6 Case 4.

**How to Test**: one numbered step per acceptance criterion, in this precedence order:
1. **`stories.json` present** → one step per `acceptance_criteria` item in
   `STORY_JSON` (the selected entry only). Keep the complete AC list and its
   order; do not mix criteria from sibling stories.
2. **No `stories.json`, but `spec_tier:plan-only`** (D11 enabler) → read `seed-manifest.json`
   `.spec_tier`; when it is `"plan-only"`, source the steps from `plan.md`
   `## Acceptance criteria` — one numbered step per non-empty acceptance item. This is the
   authoritative test source for the lightweight planning lane; do NOT fall through to the
   commit-message derivation below when a populated `## Acceptance criteria` section exists.
3. **Neither of the above** → write steps derived from the commit messages and changed code
   (existing fallback, unchanged).

Make each step concrete (name the command, the input, the expected output).

**Build log and gate evidence**: load only rows for this story, while retaining
all of those rows (including existing gate/session results) for the current PR
quality checks:

```bash
STORY_LOG_ROWS="$(jq -c --arg key "$STORY_KEY" \
  'select(.story == $key)' "$JSONL_PATH")"
```

Do not replace this with a whole-file read or narrow the rows to AC entries only.

**AC Verification block (machine-readable, #347-followup)**: append a fenced block to the PR body carrying the per-AC verdicts produced by `build-review` (diff-reviewer v1.1.0+). This block is the **sole durable transport** of the verdict to the post-merge `documentation-agent` — `workflow-state.json` is gitignored and `build.jsonl` is not staged into the PR, so the PR body is the only artifact that survives to the GHA runner. Source it from the **last** `step:"ac-verification"` entry among `STORY_LOG_ROWS` (not another story's rows):

````markdown
## AC Verification
<!-- makato:ac-verdicts — machine-readable; do not hand-edit. Consumed by documentation-agent post-merge. -->
```json
[
  {"ac_id":"AC-1","ac_text":"<verbatim AC text>","verified":true,"evidence":"src/foo.py:42 + tests/test_foo.py:10"},
  {"ac_id":"AC-2","ac_text":"<verbatim AC text>","verified":false,"reason":"<shortfall>"}
]
```
````

Rules:
- Emit the block **only** when a `step:"ac-verification"` entry exists in
  `STORY_LOG_ROWS`. When none exists (interactive build, or diff-reviewer
  predates v1.1.0), **omit the entire section** — do NOT emit an empty block.
  Its absence signals the documentation-agent to skip checkbox marking (no
  false `[x]`).
- Copy `ac_verdicts[]` verbatim from the last such entry — do NOT re-derive verdicts here. This skill is a transport, not a judge.
- The HTML comment marker `makato:ac-verdicts` is the anchor the documentation-agent greps for; keep it exact.

**Breaking Changes**: check the diff for changes to public APIs, database schemas, or shared contracts. Check `Yes` if any are found and describe the migration path.

**AI-assisted**: pre-check "Code implementation", "Commit messages", "PR description".

**PR Checklist**: pre-check all items that are verifiably true (conventional commit title ✓, CHANGELOG updated ✓, self-contained skills ✓, version bumped if behavior changed).

**Additional Changelog Entries**: leave empty unless the PR contains a distinct
logical change not covered by its title; when present, add one conventional
changelog title per additional change. Do not infer extra entries from sibling
stories or module-wide artifacts.

---

### Step 4 — Present draft for user review

In **interactive mode**, present the complete draft PR (title + full description body) to the user.

Use **AskUserQuestion** with selectable options:

> "Does this PR description look correct?"
> Options: [ "Approved — open the PR", "Edit title", "Edit description", "Re-generate from spec" ]

Apply any edits the user requests. Re-present if edits alter the title or more than one section. Do not open the PR until the user selects "Approved".

In **autonomous mode**, skip the prompt: proceed directly to Step 5 with the draft as-rendered. Log `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-create-pr "<key>" pr-draft-approval open-pr-as-drafted "<agent_id|cli_flag|task_id_bundle>"`. The PR body is populated from the selected story/plan slice, only referenced
`prd.md`/`design.md` sections, the project template, and the current story's
`build.jsonl` rows — no human authoring is required. The `created-issues.json`
auto-`Closes` injection in Step 6 Case 4 remains the canonical issue-link source.

---

### Step 5 — Create the pull request

**GH_HOST detection**: before calling `gh pr create`, resolve the remote URL:
```
git remote get-url origin
```
Extract the hostname from the URL (e.g. `github.tools.sap` from `https://github.tools.sap/org/repo.git`). If the hostname differs from `github.com`, prefix all subsequent `gh` commands with `GH_HOST=<hostname>`. Emit an informational note: "Using `GH_HOST=<hostname>` — remote is not github.com."

Resolve `REPO` for interactive creation too when absent, using
`gh repo view "$(git remote get-url origin)" --json nameWithOwner --jq .nameWithOwner`
after host detection. Lookup failure follows Step 5c's failure path; never
create with an empty or guessed repository identity.

#### Step 5a — Mandatory pre-call audit event

**Before** invoking `gh pr create`, append a `pr_created status:"start"` line so a subsequent silent process death is attributable to this step:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"start","data":{"branch":"<name>","gh_host":"<hostname>","title_len":<N>}}'
```

This event is required in **every** mode (interactive AND autonomous). Skipping it violates the SKILL.md audit contract — see § *Audit invariant* below.

#### Step 5b — Invoke `gh pr create`

In autonomous mode, repeat Step 2a's exact-branch lookup immediately before
creation. A newly discovered matching PR is reused and proceeds to Step 7;
lookup failure still blocks. Only a successful zero-match lookup permits
`gh pr create`.

Run:
```
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

Base branch: `main`. If the project uses a different default base (e.g. `develop`), check `gh repo view --json defaultBranchRef` or ask the user before creating. Capture both the exit code and stderr:

```bash
GH_STDERR="$(mktemp)"
gh pr create --title "$TITLE" --body "$BODY" 2>"$GH_STDERR"
GH_RC=$?
```

#### Step 5c — Handle result (mandatory branches)

**On success (`GH_RC == 0`):** capture the PR URL from stdout, then append:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"ok","data":{"pr_url":"<url>","pr_number":<N>}}'
```

**Board Status — In Review (best-effort):** interactive mode performs this
update after successful creation. Autonomous mode defers this entire board
update until Step 7 confirms green CI (including reused PRs); a blocked or
partial CI result must not advance the card. Read `in_review` from
`.claude/config.json` `github_project`; skip silently if absent. Otherwise:

```bash
GH_HOST="$HOST" gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_NODE_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$IN_REVIEW_OPTION_ID"
```

On success: log `build-create-pr: marked #$ISSUE_NUMBER as In Review on project board`.
On a missing-scope failure (any `gh project` stderr containing `missing required scopes`,
`has not been granted the required scopes`, or `requires the 'project' scope`): log
`build-create-pr: WARN — gh token lacks the project scope; run 'gh auth refresh --hostname $HOST --scopes project,read:project' and approve the one-time code at https://$HOST/login/device — board not updated; continuing`
and use that remediation as the `reason`. Keep `--hostname`: without it, a
non-interactive `gh auth refresh` exits with
`--hostname required when not running interactively`, so never relay gh's own
hostless hint. The device code expires after 15 minutes.
On any other failure: log `build-create-pr: WARN — could not set In Review on board; continuing` (best-effort — never blocks PR creation or subsequent steps).

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"board-in-review","status":"<ok|warn>","data":{"issue":<ISSUE_NUMBER>,"reason":"<omit-on-ok|error-description-on-warn>"}}'
```

Capture the PR number and full `headRefOid` with
`gh pr view <URL> --repo "$REPO" --json number,url,headRefOid`; preserve these
as `PR_NUMBER`, `PR_URL`, and `HEAD_SHA`. Proceed to Step 6.

**On failure (`GH_RC != 0`):** the skill MUST NOT exit silently. Classify and log:

1. Determine `halt_code`:
   - `GH_AUTH_FAILED` — stderr contains `authentication`, `not logged in`, `token`, or `401`.
   - `PR_CREATE_FAILED` — every other non-zero exit (template missing, branch-protection reject, API outage, title too long, unpushed commits detected post-hoc, etc.).
2. Append the finding line **verbatim** (do not paraphrase the `gh` error):

   ```bash
   "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"error","data":{"halt_code":"<code>","exit_code":<GH_RC>,"stderr":"<first 500 chars, JSON-escaped>"}}'
   ```

3. Append the **terminal session-error** event (see § *Audit invariant* — this is the "either ok or error, never neither" guarantee):

   ```bash
   "$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"error","data":{"halt_code":"<code>","branch":"<name>"}}'
   ```

4. Emit the R1 failure envelope (see § *Return Format*) as the final `json`-fenced block and return. Do NOT retry `gh pr create` silently, and do NOT fall through to Step 6.

---

### Step 6 — Link PR to issue tracker (optional)

This step depends on what tracking context is available. Do not block or ask the user if no reference was provided.

**Case 1 — Jira key provided (e.g. DCP-1234):**
Use the Jira MCP `create_remote_link` tool after the PR is created:
- `key`: the work item key
- `url`: the PR URL from Step 5
- `title`: `Pull Request: <PR title>`

If the Jira MCP is not configured, skip and note it in the log.

**Case 2 — GitHub issue reference provided (e.g. GH#42):**
Add `Closes #42` (or `Fixes #42`) to the PR body's Links section *before* calling `gh pr create` in Step 5. GitHub auto-closes the issue on merge. No separate API call needed.

**Case 3 — No issue reference provided:**
Skip linking entirely. Do not ask the user to supply one. Log `"issue_linked": false` and proceed.

**Case 4 — `created-issues.json` present and schema-valid:**

For each entry in `issues[]`, add `Closes #<issue_number>` to the PR body's Links section in artifact order, before calling `gh pr create` in Step 5.

**Dedupe rule (D20):** if Case 2 already added a `Closes #N` for the same issue number (because the user passed `GH#N`), do not duplicate — the artifact entry wins by being canonical; the user-supplied reference is dropped from the Links section to avoid two lines pointing at the same issue.

**No artifact, malformed artifact, or schema-invalid artifact (D21):** skip injection entirely. Log a warning (as in Step 1) and create the PR with the current Step 6 Case 1–3 behavior. Never block PR creation on artifact problems.

---

### Step 7 — Await the shared CI gate, then close the session

**Autonomous mode, whether standalone or called by the PO-agent:** dispatch
`makato-build:build-fix-ci` for the created/reused PR and wait. Pass
`PR_NUMBER`, `REPO` (`OWNER/REPO`), `WORKTREE_PATH`, `REPO_ROOT`,
`MAKATO_BUILD_ROOT`, optional sibling roots, `SPEC_FOLDER`, `JSONL_PATH`,
and the work-item-key through the downstream dispatch boundary above. The
shared skill owns inspection, repairs, pushes, and waiting; do not poll checks,
re-run jobs, dispatch a second repair loop, or return "ready for review" here.

Propagate its R1 status, errors, and `data.github_pr_number`, `head_sha`,
`ci_status`, `repair_cycles`, `unresolved_checks`, and `halt_code` into
this skill's R1 alongside the PR metadata. Preserve any handoff/resume data
on an actual context handoff too. Success requires a valid R1
`status:"success"`, matching PR number, `ci_status:"green"`, a nonnegative
integer `repair_cycles`, `unresolved_checks:[]`, `halt_code:null`, and
`head_sha` matching both the current PR `headRefOid` and worktree
`git rev-parse HEAD`. If HEAD changed after the result, dispatch the same
shared gate for the new HEAD before handing off. Never trust an older SHA's
green result. A failed/malformed dispatch, non-green result, `partial`, or
`failure` closes this session with `status:"error"` and returns non-success;
preserve the known PR number/URL and all returned CI diagnostics on that path.
A missing/malformed result uses `halt_code:"CI_BLOCKED"`, never green.
Do not create another PR on re-entry. After green, perform the deferred
best-effort In Review board update from Step 5c.

**Interactive mode:** do not invoke the CI gate or change the existing
review handoff.

Emit exactly one terminal session event after this decision. On success:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"ok","data":{"pr_url":"<url>","github_pr_number":<N>,"head_sha":"<full-sha>","ci_status":<CI_STATUS_JSON>,"repair_cycles":<N-or-null>,"unresolved_checks":[],"halt_code":null,"issue_linked":true|false,"issue_type":"jira"|"github"|"none","closes_injected":<N>,"artifact_status":"valid"|"missing"|"malformed"}}'
```

Use actual JSON `"green"` for `CI_STATUS_JSON` on autonomous success;
interactive success uses JSON `null` for both CI status and repair cycles.

For a reused PR, retain existing link metadata when known; do not claim links
were newly injected. On a CI-blocked/failed result, log the same known PR/CI
fields in the terminal `status:"error"` event with the returned halt code.
Project child results into audit events explicitly; never serialize the child's
entire data object. Public audit may contain PR number/URL, SHA, CI status,
repair count, halt code and sanitized unresolved check names/run/job/attempt IDs.
Checkpoint locations, absolute private paths, log_path, raw log summaries and
unsanitized child errors stay private. Retaining diagnostics in private R1
handoff context is not permission to publish them in build.jsonl or comments.
Autonomous success: report the PR URL and confirmed green SHA. Interactive
success: report the PR URL and current SHA without claiming a CI gate ran, then
finish with: *"PR open: `<URL>`. After review comments arrive, continue in a
clean context: `/handoff` (or `/new`), then
`/skill:build-address-pr-comments <KEY>`. The PR and comments are in GitHub;
reuse this feature worktree, or include `WORKTREE_PATH=<absolute path>` if the
new session is not already in it."*

---

## Anti-patterns

These are production-derived failure modes — most were silent bugs before explicit guards were added.

**NEVER use `data.issue` or `data.story` from `build.jsonl` for key recovery.**
WHY: those fields do not exist in the build.jsonl schema. `build-log.sh` writes the key at the top-level `story` field; the `data` sub-object is free-form payload per skill. Reading a non-existent field silently produces `null` and creates a PR with no issue link and an incorrect session key that later breaks the audit trail search.

**NEVER compare the commit range against bare local `main`.**
WHY: a stale local `main` includes commits from already-merged PRs that happened between your last `git fetch` and now. Those commits appear in `git log main..HEAD` as if they are part of this PR, inflating the "What changed" section with unrelated history. Always resolve via `"$MAKATO_BUILD_ROOT/shared/default-branch.sh"` after a
`git fetch origin --quiet` so the tip is `origin/main` (or the true remote default).

**NEVER rely on `data.branch` in `build.jsonl` for key recovery.**
WHY: `data.branch` is written only by `build-push-to-git` and is absent if that skill has not run yet (e.g., the agent is re-dispatched after a partial session). Treating an absent field as the key silently falls through to an empty string, producing a MISSING_INPUT halt that looks like a missing argument bug, not a schema misread.

**NEVER truncate the issue reference at the end of the PR title.**
WHY: the CI `pr-title` check validates the full title against the conventional commit regex, and the GitHub PR list renders the issue reference as a clickable identifier. Truncating `(DCP-1234)` to `(DCP-...` breaks both the regex match (non-alphanumeric suffix) and the cross-link. Truncate or rephrase the story title instead.

**NEVER emit an empty `## AC Verification` block when no `step:"ac-verification"` entry exists in `build.jsonl`.**
WHY: an empty block is indistinguishable from a block where all verdicts evaluated to zero. The `documentation-agent` uses block *absence* as the signal to skip checkbox marking entirely — an empty block triggers the checkbox writer and marks every AC as unverified (`- [ ]` stays), which is correct only if a reviewer actually ran. An omitted block means "no reviewer ran" and is the safe fallback.

**NEVER retry `gh pr create` silently after a non-zero exit.**
WHY: `gh pr create` errors split into recoverable (auth token expired, network blip) and hard-stop (branch-protection reject, PR already exists, title too long). A silent retry on a hard-stop reason creates duplicate PR drafts or hammers a rate-limited API endpoint. Log the `halt_code`, emit the R1 failure envelope, and let the PO-agent route the recovery.

**NEVER run `git log` or `gh pr create` from `REPO_ROOT` in autonomous mode when `WORKTREE_PATH` is set.**
WHY: in the autonomous loop each story runs in a dedicated `git worktree add` at `WORKTREE_PATH`. That worktree has its own `HEAD` pointing to the feature branch. Running `gh pr create` from the main checkout instead opens a PR against whatever branch the main checkout is on, not the story branch — this silently creates a PR against `main` from `main` (or the previous story's branch), which GitHub may accept but is irreversible without force-closing.

---

## Autonomous Execution

Autonomous mode is activated per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` §
*Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key and draft-approval gates are bypassed per the rules above.
- **Read workflow-state from `build.jsonl`** when the work-item-key argument is missing — Step 1a documents the lookup order.
- **PR body is fully autogenerated** from the selected story/plan slice,
  referenced `prd.md`/`design.md` sections, `.github/PULL_REQUEST_TEMPLATE.md`,
  and this story's workflow-state rows. No human authoring.
- **Auto-inject `Closes #<n>`** lines from `created-issues.json` per Step 6 Case 4 — this is the canonical issue-link source in autonomous mode.
- **Render the AC Verification block** from the last `build.jsonl` `step:"ac-verification"` entry (Step 3) so the post-merge `documentation-agent` can flip verified AC checkboxes. Omit the block entirely when no such entry exists.
- **Log every bypass** to `build.jsonl` via
  `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"` with the `autonomous_bypass`
  event schema documented in `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`.
- **Await `build-fix-ci`** for both created and reused PRs; propagate its
  SHA-bound CI result, including failures, instead of declaring PR creation
  alone a successful autonomous handoff.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

**On success:**

```json
{
  "data": {
    "pr_url": "<url>",
    "github_pr_number": <N>,
    "head_sha": "<full-current-head-sha>",
    "ci_status": "green" | null,
    "repair_cycles": <N>,
    "unresolved_checks": [],
    "halt_code": null,
    "issue_linked": <true|false>,
    "issue_type": "jira" | "github" | "none",
    "closes_injected": <N>,
    "artifact_status": "valid" | "missing" | "malformed",
    "gh_host": "<hostname>"
  }
}
```

`agent` is `"build-create-pr"`. Autonomous success means the current PR
HEAD is green, not merely that a PR exists. Interactive mode uses
`ci_status:null` and `repair_cycles:0` because no CI gate ran.

**On CI-gate non-success:** keep the known `github_pr_number`, `pr_url`, and
all returned CI fields in `data`; propagate the shared skill's errors and
halt code. Missing/malformed R1 is a failure, never a fallback success.

**On failure (lookup or `gh pr create` non-zero exit — Step 5c error branch):**

```json
{
  "status": "failure",
  "agent": "build-create-pr",
  "summary": "gh pr create failed: <first line of stderr>",
  "errors": ["<halt_code>: <gh stderr, first 500 chars>"],
  "data": {
    "halt_code": "GH_AUTH_FAILED" | "PR_CREATE_FAILED",
    "exit_code": <GH_RC>,
    "branch": "<name>",
    "gh_host": "<hostname>"
  }
}
```

The PO-agent reads `data.halt_code` and routes per `plugins/makato-build/halt-codes.md` (`GH_AUTH_FAILED` → operator-escalation; `PR_CREATE_FAILED` → operator-escalation).

### Audit invariant

`build-create-pr` MUST emit **exactly one** terminal `step:"session"` line
per invocation: `status:"ok"` after a successful Step 7, or
`status:"error"` on input/lookup/create/CI-gate non-success. An existing PR
must still be included in the terminal event and R1 when its CI gate fails.
Never close with success before a downstream skill returns. A silent exit or
an unclosed session remains a contract violation.

### HALT Codes

Local failure codes (`MISSING_INPUT`, `UNPUSHED_COMMITS`, `GH_AUTH_FAILED`,
`PR_CREATE_FAILED`) and propagated shared CI halt codes use the recovery
routes in `plugins/makato-build/halt-codes.md`. Missing required workspace
inputs also use `MISSING_INPUT`; Step 1a defines work-item-key fallback.
