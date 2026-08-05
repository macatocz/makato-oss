---
name: build-fix-security
description: >-
  Per-finding security repair engine for bandit:*, safety:*, and pip-audit:* findings.
  Uses a CWE-keyed classification table with 4 branches (autofix / refactor / suppress /
  carry-over) to resolve each finding deterministically. Dispatched by build-resolve-finding;
  never invoked directly by the user. Keywords: bandit, safety, pip-audit, CVE, CWE,
  nosec, security finding, sensor-fixer repair.
version: "1.0.0"
allowed-tools: [Read, Edit, Write, Bash]
metadata:
  authors: [makato-build]
  last_updated: "2025-08-05"
  argument-hint: "finding JSON object passed by build-resolve-finding"
---

# build-fix-security

## 1. Overview

Security-finding repair engine invoked by `build-resolve-finding` whenever a bandit,
safety, or pip-audit finding is routed here through
`plugins/makato-build/shared/finding-routes.json`.

Receives one normalized finding, classifies it via the CWE table (Section 3), applies
the fix, and returns a structured outcome. **Classification lives here — the orchestrator
only dispatches.**

The four branches, ordered least-invasive → most-invasive:

1. **Autofix** — safe mechanical substitution; deterministic, no architectural judgment.
2. **Refactor** — structural fix required; code reorganized, not just substituted.
3. **Suppress** — deterministic false-positive pattern; adds `# nosec B<id>: <reason>`.
4. **Carry-over** — cannot safely auto-fix; records diagnosis for PR body / carry-over.jsonl.

**Semgrep is out of scope.** If a `semgrep:*` finding arrives, return
`status: "error"`, `fix_applied: false`,
`fix_description: "semgrep:* not in scope; route to semgrep skill (#73)"`.

## 2. Inputs

The caller passes a single finding object — the same shape used everywhere else in the
sensor-fixer pipeline. The canonical Finding contract is
[`../../shared/finding-schema.md`](../../shared/finding-schema.md):

```json
{
  "tool": "bandit | safety | pip-audit",
  "rule": "<rule id, e.g. B303, B602, CVE-2024-12345>",
  "path": "<repo-relative file path>",
  "line": 123,
  "message": "<verbatim sensor message>",
  "severity": "low | medium | high | critical",
  "autofix_available": false,
  "repo_root": "/abs/path/to/repo",
  "attempt": 1,
  "model_override": null
}
```

`attempt` increments on retry by the caller. `model_override` is **reserved/inert (#287)**:
no runtime consumes it yet (repair skills run under the Skill tool, which has no `model`
parameter). Documented for a future Agent-tool-based dispatch.

## 3. Classification Table

Match `(tool, rule)` top-to-bottom; first row wins.

**No match:** return `status: "error"`, `fix_applied: false`. Log a `decision` entry
naming the unmatched pair so the table can be extended.
**Never apply Branch 3 for unrecognized codes** — see Anti-patterns §A3.

### CWE-327 / CWE-326 — Weak or Broken Cryptographic Algorithm

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B303` | 1 | CWE-327 | MD5 or SHA-1 used directly — swap to `hashlib.sha256` |
| `bandit:B304` | 1 | CWE-327 | DES or Blowfish cipher — swap to `cryptography.fernet.Fernet` |
| `bandit:B305` | 1 | CWE-327 | ECB cipher mode — swap to GCM with `os.urandom(16)` nonce (NOT CBC) |
| `bandit:B324` | 1 | CWE-327 | `hashlib.md5/sha1` for password hashing — swap to `bcrypt`/`argon2-cffi` + add dep |

### CWE-330 — Use of Insufficiently Random Values

| Rule | Message / context keyword | Branch | CWE | Reason |
|------|--------------------------|--------|-----|--------|
| `bandit:B311` | context: `token`, `password`, `key`, `secret`, `nonce`, `salt` | 1 | CWE-330 | Security-context random — swap to `secrets` module |
| `bandit:B311` | context: `seed`, `shuffle`, `sample`, `randint` for statistical use | 3 | CWE-330 | Statistical random — FP; suppress with reason |

**Disambiguation rule for B311:** inspect variable names and function context on the
flagged line. Any of `token`, `password`, `key`, `secret`, `nonce`, `csrf`, `otp`,
`salt` → Branch 1. Statistical simulation, shuffling non-sensitive data, reproducible
seeding → Branch 3. Ambiguous → Branch 1 (safer default).

### CWE-78 — OS Command Injection

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B602` | `shell=True` + f-string / variable / `.format` in arg | 2 | CWE-78 | Shell injection — restructure to `args=[]` list |
| `bandit:B602` | `shell=True` + string literal, no variables | 3 | CWE-78 | Constant-arg shell — FP; suppress with literal value cited |
| `bandit:B603` | args include variable or f-string | 2 | CWE-78 | Variable subprocess args — validate or restructure |
| `bandit:B603` | args all literals / internal constants | 3 | CWE-78 | Constant-arg subprocess — FP; suppress |
| `bandit:B604` | — | 2 | CWE-78 | `os.popen` — replace with `subprocess.run(args=[...], capture_output=True)` |
| `bandit:B605` | — | 2 | CWE-78 | `os.system` — replace with `subprocess.run(args=[...])` |
| `bandit:B606` | — | 2 | CWE-78 | `os.spawn*` family — replace with `subprocess.run` |
| `bandit:B607` | first arg is constant binary path (e.g. `/usr/bin/git`) | 3 | CWE-78 | Constant binary path — FP; suppress with path cited |
| `bandit:B607` | first arg is variable | 2 | CWE-78 | Variable binary path — validate against allowlist |

### CWE-89 — SQL Injection

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B608` | 2 | CWE-89 | String-formatted SQL — convert to parameterized query |

### CWE-78 / CWE-95 — Code Injection (exec / eval)

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B102` | 4 | CWE-78 | `exec()` with any dynamic input — structural, always carry-over |
| `bandit:B307` | 4 | CWE-95 | `eval()` — structural, always carry-over; never autofix |

### CWE-617 — Reachable Assertion

| Rule | Path context | Branch | CWE | Reason |
|------|-------------|--------|-----|--------|
| `bandit:B101` | path contains `tests/`, `test_`, `_test.py`, or `conftest.py` | 3 | — | Assert in test context — FP |
| `bandit:B101` | production code path | 1 | CWE-617 | Replace `assert cond, msg` → `if not cond: raise ValueError(msg)` |

### CWE-798 — Use of Hard-coded Credentials

| Rule | Value pattern | Branch | CWE | Reason |
|------|--------------|--------|-----|--------|
| `bandit:B105` | value is `""`, `"test"`, `"fake"`, `"dummy"`, `"placeholder"`, `"changeme"`, or matches the variable name | 3 | CWE-798 | Constant placeholder — FP; suppress with constant cited |
| `bandit:B105` | value looks like real credential (long opaque string, UUID, JWT pattern) | 4 | CWE-798 | Real-looking credential — gitleaks owns redaction; carry-over |
| `bandit:B106` | path contains `tests/`, `conftest.py`, or `fixtures/` | 3 | CWE-798 | Test fixture hardcoded default — FP |
| `bandit:B106` | production code path | 4 | CWE-798 | Hardcoded default arg — remove default, require caller to supply |
| `bandit:B107` | value is constant / empty string | 3 | CWE-798 | Constant password arg — FP |
| `bandit:B107` | value looks like real credential | 4 | CWE-798 | Real-looking credential — carry-over |

### CWE-502 — Deserialization of Untrusted Data

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B301` | — | 4 | CWE-502 | `pickle.load` — structural; data origin unknown |
| `bandit:B302` | — | 4 | CWE-502 | `marshal.load` — structural |
| `bandit:B403` | — | 4 | CWE-502 | `import pickle` — diagnose; often paired with B301; carry-over as a unit |
| `bandit:B506` | `yaml.load(f)` / no Loader / `Loader=yaml.Loader` in simple single-call pattern | 1 | CWE-502 | Simple yaml.load — swap to `yaml.safe_load()` |
| `bandit:B506` | `yaml.load` inside a class, custom Loader subclass, or nested | 4 | CWE-502 | Complex yaml context — carry-over for human review |

### CWE-611 — XML External Entity (XXE)

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B405` | 1 | CWE-611 | `xml.etree.ElementTree` — swap to `defusedxml.ElementTree` |
| `bandit:B406` | 1 | CWE-611 | `xml.sax` — swap to `defusedxml.sax` |
| `bandit:B407` | 1 | CWE-611 | `xml.dom.expatbuilder` — swap to `defusedxml` |
| `bandit:B408` | 1 | CWE-611 | `xml.dom.minidom` — swap to `defusedxml.minidom` |
| `bandit:B409` | 1 | CWE-611 | `xml.dom.pulldom` — swap to `defusedxml.pulldom` |
| `bandit:B410` | 1 | CWE-611 | `lxml` parse without `resolve_entities=False` — add `XMLParser(resolve_entities=False)` |

### CWE-295 / CWE-326 — Improper Certificate Validation / Encryption Strength

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B501` | 2 | CWE-295 | `requests.get(..., verify=False)` — remove `verify=False`; custom CA → `verify="/path/to/ca.pem"` |
| `bandit:B502` | 1 | CWE-295 | `ssl.PROTOCOL_TLSv1` — swap to `ssl.PROTOCOL_TLS_CLIENT` |
| `bandit:B503` | 1 | CWE-295 | `ssl.PROTOCOL_SSLv2/3` — swap to `ssl.PROTOCOL_TLS_CLIENT` |
| `bandit:B504` | 1 | CWE-295 | `SSLContext` without `check_hostname=True` — add `check_hostname`+`CERT_REQUIRED` |
| `bandit:B505` | 1 | CWE-326 | RSA key size < 2048 — bump to 4096 |

### CWE-605 — Wildcard Bind

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B104` | path contains `tests/`, `conftest.py`, `dev`, `local`, or `Dockerfile.dev` | 3 | CWE-605 | Dev/test wildcard bind — FP |
| `bandit:B104` | production code path | 2 | CWE-605 | `0.0.0.0` in prod — replace with `127.0.0.1` or `BIND_HOST` env var |

### safety / pip-audit — Vulnerable Dependency

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `safety:*` | 1 (upgrade) or 4 (ignore fallback) | varies | Delegate to upgrade-or-ignore flow (Section 4) |
| `pip-audit:*` | 1 (upgrade) or 4 (ignore fallback) | varies | Same as safety |

## 3a. repair_hint mapping table

Set `finding.repair_hint` before dispatching or returning. Exact match takes precedence
over glob. Leave `repair_hint` absent when no mapping exists — do not set `null` or `""`.
The `repair_hint` string follows the WHAT/WHY/FIX sub-structure defined in
[`../../shared/finding-schema.md`](../../shared/finding-schema.md).

| Rule | repair_hint |
|------|-------------|
| `bandit:B105` | `"WHAT: Hard-coded password string.\nWHY: Committing credentials in source risks exposure in version control and logs.\nFIX: Replace with os.environ[\"PASSWORD\"] or a secrets-manager lookup."` |
| `bandit:B107` | `"WHAT: Hard-coded password as function argument.\nWHY: A constant password is visible in source and call stack.\nFIX: Accept via env var or secrets manager; never pass as a literal."` |
| `bandit:B303` | `"WHAT: MD5 or SHA-1 for hashing.\nWHY: Both are cryptographically broken.\nFIX: Replace with hashlib.sha256 for general hashing, or bcrypt/argon2 for password storage."` |
| `bandit:B324` | `"WHAT: Weak hash (MD5/SHA-1) for password storage.\nWHY: Fast algorithms are easily brute-forced.\nFIX: Use bcrypt.hashpw(pwd.encode(), bcrypt.gensalt())."` |
| `bandit:*` | `"WHAT: Bandit security finding.\nWHY: Known vulnerability class (see message and CWE).\nFIX: Consult the classification table in build-fix-security/SKILL.md."` |
| `safety:*` | `"WHAT: Vulnerable dependency version.\nWHY: Known CVE may be exploitable.\nFIX: Upgrade to the fixed version, or add a timed ignore entry if unavailable."` |
| `pip-audit:*` | `"WHAT: pip-audit found a vulnerable package.\nWHY: Publicly disclosed security flaw.\nFIX: pip install --upgrade <package>; add a timed ignore entry if no upgrade available."` |

## 4. Branch Playbooks

**Always set `finding.repair_hint`** (Section 3a) before dispatching or returning.

### Branch 1 — Autofix

**Trigger:** safe mechanical substitution exists; no architectural judgment required.

**MANDATORY: Load fix patterns before editing.**
- For CWE-327/CWE-326/CWE-330 rules (B303, B304, B305, B311, B324, B502–B505):
  load `references/branch1-crypto-patterns.md` NOW.
- For all other Branch 1 rules (B101, B506, B405–B410):
  load `references/branch1-standard-patterns.md` NOW.
- Do NOT load both unless the finding covers rules from both groups.

**Procedure:**

1. Re-read `<path>` from disk (a prior finding in the same run may have already patched it).
2. Apply the single targeted substitution from the loaded reference. Edit only the flagged
   line (or its immediate import/dependency, if required by the fix).
3. Re-run `bandit <path>` to confirm the finding is gone.

---

### Branch 2 — Refactor

**Trigger:** structural fix required — code reorganized, not just substituted.

**MANDATORY: Load `references/branch2-refactor-patterns.md` NOW** before editing.
Do NOT load for Branch 1 or Branch 3 work.

**Procedure:**

1. Re-read the file before editing.
2. Apply the structural fix from the loaded reference.
3. Preserve runtime semantics: do not change what the code does to valid inputs.
   A guard that changes error type from `TypeError` to `ValueError` is a semantic change —
   escalate to Branch 4.
4. Re-run `bandit <path>`.

**API contract boundary:** if the fix would change signatures visible to callers outside the
file, log a `decision` entry and escalate to Branch 4. Changing an API contract is not a
one-edit fix.

---

### Branch 3 — Suppress (False Positive)

**Trigger:** finding matches a deterministic FP pattern from the Section 3 table.

**Do NOT Load** any branch1 or branch2 reference files — no code edit is made here.

**Suppression format (hard rule):**

```python
result = some_call()  # nosec B<id>: <specific reason>
```

The reason MUST identify (1) what the construct is and (2) why it is safe in this context.

**Rejected reasons** (return `status: "error"` if this is all you can write):
- `# nosec B101: false positive`
- `# nosec B311: not a security concern`
- `# nosec B602: known safe`

**Accepted reason examples:**
```python
assert result is not None  # nosec B101: assert in test context — test fixtures use assert by convention
random.shuffle(population)  # nosec B311: statistical simulation — population is anonymous survey data, not a credential
subprocess.run(["/usr/bin/git", "log"], ...)  # nosec B603: args are hardcoded internal constants, no user input
server.bind(("0.0.0.0", port))  # nosec B104: development server only — not reachable in production (BIND_HOST env var gates prod)
```

**Procedure:**

1. Re-read the file.
2. Confirm the FP pattern from Section 3 applies — if uncertain, escalate to Branch 4.
3. Compose a specific reason; if you cannot write one, escalate to Branch 4 (never suppress
   with a generic reason).
4. Append `# nosec B<id>: <reason>` at end of the flagged line.
5. Re-run `bandit <path>`.
6. Log `status: "warn"` with the nosec reason and CWE (see Section 7).

---

### Branch 4 — Carry-Over

**Trigger:** cannot safely auto-fix — requires architectural review, API contract changes,
or involves deserialization / code injection where the safe fix depends on data origin.

**Do NOT Load** any branch1 or branch2 reference files — no code edit is made here.

**Procedure:**

1. Do **not** edit the file.
2. Compose a diagnosis entry for the draft PR body:

```
## Carry-over: <tool>:<rule> at <path>:<line>

**Finding:** <verbatim bandit message>
**CWE:** <CWE-NNN — description>
**Severity:** <severity>
**Why not auto-fixed:** <one sentence: structural reason>
**Recommended fix:** <one sentence: what a human reviewer should do>
```

3. If a draft PR exists for this branch, append to its body:

```bash
EXISTING=$(gh pr view --json body --jq '.body')
DIAGNOSIS="$(printf '\n\n## Carry-over: %s:%s at %s:%s\n\n**Finding:** ...' "<tool>" "<rule>" "<path>" "<line>")"
gh pr edit <num> --body "${EXISTING}${DIAGNOSIS}"
```

Otherwise, append to `<repo_root>/.makato/carry-over.jsonl` for `build-create-pr`.

4. Leave the failing hook red — do NOT suppress, do NOT use `--no-verify`.
5. Return `status: "error"`, `fix_applied: false`,
   `fix_description: "carry-over: <tool>:<rule> — structural, human review required"`.

**Carry-over recommended fix by rule:**

| Rule | Recommended fix |
|------|----------------|
| B301 (pickle) | Replace `pickle.load` with JSON/msgpack/protobuf after verifying data origin |
| B302 (marshal) | Same as B301 |
| B307 (eval) | Remove `eval`; use a registry dict for dynamic dispatch |
| B102 (exec) | Remove `exec`; refactor to plugin registry or importlib |
| B506 (complex yaml) | Validate Loader class; confirm no untrusted YAML input path |
| B105/B106/B107 (real credential) | Remove hardcoded credential; load from env var or secrets manager |

---

### upgrade-or-ignore — safety / pip-audit

**MANDATORY: Do NOT Load** branch1 or branch2 reference files — this sub-flow runs
its own package-manager commands, not Python source edits.

This sub-flow handles the `upgrade-or-ignore` decision for vulnerable dependency findings
(the `build-resolve-finding` "Branch 3b" path that safety/pip-audit findings follow).

**Procedure:**

1. Parse the finding: package name, installed version, CVE ID, fixed version.
2. Detect package manager:
   - `pyproject.toml` + `uv.lock` → `uv lock --upgrade-package <pkg>`
   - `pyproject.toml` + `poetry.lock` → `poetry update <pkg>`
   - `requirements*.txt` → `pip install --upgrade <pkg>` + update the pinned version
3. Run the upgrade.
4. Re-run `safety check` / `pip-audit` on updated dependencies.
5. Run the project test suite (`pytest -x -q`).
6. **Green:** commit `chore(deps): upgrade <pkg> for <CVE>`. Return `status: "ok"`,
   `fix_applied: true`, `fix_description: "upgraded <pkg> to <version> — resolves <CVE>"` (branch 1).
7. **No upgrade or tests break:**
   - **safety:** append to `<repo_root>/safety-policy.yml`:
     ```yaml
     - id: <CVE>
       reason: no-fix-available as of <today>
       expires: <today+30d>
     ```
   - **pip-audit:** add to `.pip-audit.toml`:
     ```toml
     [[tool.pip-audit.ignore]]
     id = "<CVE>"
     reason = "no-fix-available as of <today>"
     ```
   - Call `create-issue` with `title: "review CVE <CVE> ignore by <date>"`.
   - Return `status: "error"`, `fix_applied: false`,
     `fix_description: "CVE <id> ignored until <date> — no fix available; tracked in issue"` (branch 4).

**Python-specific caveat:** if the vulnerable package is in a `dev` or `test` extras
group only (e.g. `[tool.poetry.group.dev.dependencies]`), note this in the `create-issue`
body and log a `decision` entry. Do not open a rotation issue for dev-only deps unless
severity is CRITICAL. Add the ignore entry to the tool config file (not a `# nosec` comment —
`safety` and `pip-audit` do not read Python source comments).

## 5. Anti-patterns

| ID | NEVER | WHY — the non-obvious failure mode |
|----|-------|--------------------------------------|
| A1 | Never suppress with a generic nosec reason | A generic reason (`# nosec B602: known safe`) documents nothing useful and cannot be audited later. Future reviewers cannot distinguish a deliberate FP from a lazy suppression. The suppression will survive forever, masking any future real instance of the same pattern. |
| A2 | Never apply Branch 3 (suppress) for unrecognized codes | Silently suppressing an unknown security rule is epistemically worse than leaving it unresolved: the skill has no classification for the rule, so it cannot know whether this is a true positive. The caller (`build-resolve-finding`) escalates to carry-over, which is the correct path. |
| A3 | Never add `# nosec` for B501 (verify=False) | `verify=False` disables TLS peer authentication entirely. The failure mode is silent data exposure to a man-in-the-middle, not an application error, so a code annotation does not address the risk — it just hides the bandit finding. Refactor or carry-over only. |
| A4 | Never bypass pre-commit hooks (`--no-verify`, `SKIP=...`) | Hook bypass creates a hidden tech-debt trail: the finding leaves no carry-over entry in `.makato/carry-over.jsonl`, no diagnosis in the PR body, and no audit log entry. The loop re-runs bandit at the next iteration and finds the same unfixed finding — the only net effect is a corrupted audit trail. Carry-over is the correct escalation path. |
| A5 | Never bundle fixes for adjacent findings in one edit | The sensor-fixer loop re-runs bandit after each fix. Multi-finding edits make the loop non-deterministic: a second fix may undo a first, or a new finding may be introduced. One finding → one edit → one bandit re-run. |
| A6 | Never swap ECB mode to CBC without authentication | CBC without a MAC is vulnerable to padding oracle attacks. B305 requires authenticated encryption (GCM). A CBC swap silences the bandit finding while leaving the code insecure — the correct fix is in `references/branch1-crypto-patterns.md`. |
| A7 | Never use sha256 as a B324 fix for password storage | sha256 is still a fast algorithm — brute-forceable in milliseconds with GPU hardware. B324 requires a password-hashing algorithm (bcrypt, argon2) with a work factor. Swapping md5 → sha256 on a password field silences bandit but provides no real-world protection improvement. |

## 6. Hard Rules

1. **Read disk state before editing.** The sensor-fixer loop may have already patched
   the file in the same run.
2. **One finding, one edit.** Never bundle fixes for adjacent findings (A5 above).
3. **Preserve runtime semantics.** Security fixes must not change what the code does to
   valid inputs.
4. **No bare `# nosec`.** Always `# nosec B<id>: <specific reason>` (A1 above).
5. **Branch 3 logs `warn`.** Every suppression appends a `warn` entry to `build.jsonl`.
6. **Never bypass hooks** (`--no-verify`, `SKIP=...`). Carry-over is the correct escalation
   path; hook bypass corrupts the audit trail without resolving the finding (A4 above).
7. **Branch 4 for unrecognized codes.** If `(tool, rule)` matches no table row, return
   `status: "error"` — never a silent Branch 3 (A2 above).

## 7. Output Contract

```json
{
  "status": "ok | warn | error",
  "branch": 1,
  "file": "src/example.py",
  "line": 42,
  "fix_applied": true,
  "fix_description": "Replaced hashlib.md5 with hashlib.sha256 (B303, CWE-327)"
}
```

Field semantics:
- `status: "ok"` — fix applied via branches 1–2; expected to pass re-verification.
- `status: "warn"` — fix applied via branch 3 (suppress); re-verify but flag for human review.
- `status: "error"` — could not apply any fix safely; escalates to carry-over in caller.
  Also returned for unrecognized `(tool, rule)`.
- `branch` — integer 1–4. For `upgrade-or-ignore`: `1` (upgrade resolved) or `4` (ignore
  entry added). For no-match error path: omit or `null`.
- `fix_applied` — `true` if the file was edited.
- `fix_description` — one-line description including rule ID and CWE.

## 8. Logging

Append JSONL entries to `specs/<story-key>/build.jsonl` via `shared/build-log.sh`
(bare path — no `../`).

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"session","status":"start","data":{"tool":"bandit","rule":"B303","path":"src/crypto.py","line":12}}
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"classify","status":"ok","data":{"branch":1,"cwe":"CWE-327","reason":"B303 → Autofix: MD5 → sha256"}}
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"apply","status":"ok","data":{"file":"src/crypto.py","line":12,"fix_description":"Replaced hashlib.md5 with hashlib.sha256"}}
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"session","status":"ok","data":{"branch":1,"fix_applied":true}}
```

Branch 3 (suppress) MUST also log:
```jsonl
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"suppress","status":"warn","data":{"file":"tests/test_auth.py","line":55,"rule":"B101","cwe":"—","nosec_reason":"assert in test context — test fixtures use assert by convention"}}
```

Branch 4 (carry-over) MUST log:
```jsonl
{"ts":"<ISO8601>","skill":"build-fix-security","story":"<key>","step":"carry-over","status":"warn","data":{"file":"src/loader.py","line":20,"rule":"B301","cwe":"CWE-502","reason":"pickle.load — structural, data origin unknown"}}
```

## 9. When to Use

Dispatched by `build-resolve-finding` Branch 2 (tech-skill route) for findings matching
`bandit:*`, `safety:*`, or `pip-audit:*` in `shared/finding-routes.json`.
**Not invoked directly by the user.** If a user types `/build-fix-security`, respond:

> "This skill is the per-finding security repair engine dispatched by
> `build-resolve-finding`. It is not invoked directly. To trigger it, run
> `/build-sensors` against a branch with bandit/safety violations, or pass a finding
> JSON via `build-resolve-finding`."
