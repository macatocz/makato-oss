---
name: build-fix-security
description: >-
  Per-finding security repair engine dispatched by build-resolve-finding for bandit:*,
  safety:*, and pip-audit:* findings. Uses a CWE-keyed classification table with 4 branches
  (autofix / refactor / suppress / carry-over). Never invoked directly by the user.
version: "1.0.0"
tools: All tools
---

# build-fix-security

## 1. Overview

This skill is the **security-finding repair engine** invoked by `build-resolve-finding`
whenever a bandit, safety, or pip-audit finding is routed here through
`plugins/makato-build/shared/finding-routes.json`.

It receives a single normalized finding, classifies it into one of four branches by
matching the `(tool, rule)` pair against the CWE classification table (Section 3),
applies the corresponding fix in place, and returns a structured outcome to the caller.

The four branches, ordered from least invasive to most invasive:

1. **Autofix** — a safe mechanical substitution exists: replace the insecure function/
   algorithm/flag with its secure alternative in a single edit. The fix is deterministic
   and requires no architectural judgment.
2. **Refactor** — a structural fix is required: parameterize a query, add input
   validation, replace an unsafe API pattern. The fix changes the structure of the code,
   not just a function name.
3. **Suppress** — the finding matches a well-defined false-positive pattern (test
   context, statistical random use, internal-constant subprocess args). Adds
   `# nosec B<id>: <specific reason>` inline. Generic reasons are rejected — the reason
   must identify the construct and why it is safe here. Every suppression logs
   `status: "warn"`.
4. **Carry-over** — the finding is structurally unsafe to auto-fix (deserialization,
   eval/exec with dynamic input, SSRF with user-controlled URL). Records a diagnosis
   entry for the draft PR body and escalates to a human reviewer.

**Knowledge of which branch fits which finding lives here in the classification table
(Section 3) — never in `build-resolve-finding`.** The orchestrator only dispatches;
this skill decides and acts.

**Semgrep is out of scope.** Semgrep security routing is handled by issue #73.
If a `semgrep:*` finding arrives here, return `status: "error"` with
`fix_applied: false` and `fix_description: "semgrep:* is not in scope for build-fix-security; route to semgrep skill (#73)"`.

## 2. Inputs

The caller passes a single finding object (same shape used everywhere else in the
sensor-fixer pipeline — the canonical Finding contract is [`shared/finding-schema.md`](../../shared/finding-schema.md)):

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

`attempt` increments on retry by the caller. `model_override` is set by the caller if a
tier escalation is in effect.

## 3. Classification Table

Match the finding's `(tool, rule)` against the table below. The **first** matching row
wins. Rules within each CWE group are checked top-to-bottom.

If no row matches: return `status: "error"` with `fix_applied: false` and log a
`decision` entry naming the unmatched `(tool, rule)`. **Do not apply Branch 3 (suppress)
for unrecognized codes** — silently suppressing an unknown security finding is worse than
leaving it unresolved. The caller (`build-resolve-finding`) escalates to carry-over.

### CWE-327 / CWE-326 — Weak or Broken Cryptographic Algorithm

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B303` | 1 (Autofix) | CWE-327 | MD5 or SHA-1 used directly — swap to `hashlib.sha256` |
| `bandit:B304` | 1 (Autofix) | CWE-327 | DES or Blowfish cipher — swap to `cryptography.fernet.Fernet` |
| `bandit:B305` | 1 (Autofix) | CWE-327 | ECB cipher mode — swap to CBC or GCM with a randomly-generated IV |
| `bandit:B324` | 1 (Autofix) | CWE-327 | `hashlib.md5` / `hashlib.sha1` for password hashing — swap to `bcrypt`/`argon2-cffi` and add dependency note |

### CWE-330 — Use of Insufficiently Random Values

| Rule | Message / context keyword | Branch | CWE | Reason |
|------|--------------------------|--------|-----|--------|
| `bandit:B311` | context: `token`, `password`, `key`, `secret`, `nonce`, `salt` | 1 (Autofix) | CWE-330 | Security-context random — swap `random.X()` → `secrets.token_hex()` / `secrets.choice()` |
| `bandit:B311` | context: `seed`, `shuffle`, `sample`, `randint` for statistical/simulation use | 3 (Suppress) | CWE-330 | Statistical random — FP; suppress with reason identifying the non-security use |

**Disambiguation rule for B311:** inspect the variable names and function context on the
flagged line. If the surrounding code names (variable, function, argument) contain any of
`token`, `password`, `key`, `secret`, `nonce`, `csrf`, `otp`, `salt` → Branch 1. If the
names indicate statistical simulation, shuffling non-sensitive data, or reproducible
seeding → Branch 3. If ambiguous → Branch 1 (safer default).

### CWE-78 — OS Command Injection

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B602` | `shell=True` and arg includes an f-string, variable, or `.format` | 2 (Refactor) | CWE-78 | Shell injection via string interpolation — restructure to `args=[]` list |
| `bandit:B602` | `shell=True` and arg is a string literal with no variables | 3 (Suppress) | CWE-78 | Constant-arg shell call — FP; suppress with reason citing literal value |
| `bandit:B603` | args include a variable or f-string | 2 (Refactor) | CWE-78 | `subprocess` without shell but variable args — validate or restructure |
| `bandit:B603` | args are all literals / internal constants | 3 (Suppress) | CWE-78 | Constant-arg subprocess — FP; suppress with reason |
| `bandit:B604` | — | 2 (Refactor) | CWE-78 | `os.popen` — replace with `subprocess.run(args=[...], capture_output=True)` |
| `bandit:B605` | — | 2 (Refactor) | CWE-78 | `os.system` — replace with `subprocess.run(args=[...])` |
| `bandit:B606` | — | 2 (Refactor) | CWE-78 | `os.spawn*` family — replace with `subprocess.run` |
| `bandit:B607` | first arg is a constant binary path (e.g. `/usr/bin/git`) | 3 (Suppress) | CWE-78 | Partial path with constant binary — FP; suppress with path cited |
| `bandit:B607` | first arg is a variable | 2 (Refactor) | CWE-78 | Partial path with variable binary — validate against an allowlist |

### CWE-89 — SQL Injection

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B608` | 2 (Refactor) | CWE-89 | Hardcoded SQL string using string formatting — convert to parameterized query |

### CWE-78 / CWE-95 — Code Injection (exec / eval)

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B102` | 4 (Carry-over) | CWE-78 | `exec()` with any dynamic input — structural, always carry-over |
| `bandit:B307` | 4 (Carry-over) | CWE-95 | `eval()` — structural, always carry-over; never autofix |

### CWE-617 — Reachable Assertion / Improper Check

| Rule | Path context | Branch | CWE | Reason |
|------|-------------|--------|-----|--------|
| `bandit:B101` | file path contains `tests/`, `test_`, `_test.py`, or `conftest.py` | 3 (Suppress) | — | Assert in test context — FP; suppress with reason "assert in test context" |
| `bandit:B101` | production code path | 1 (Autofix) | CWE-617 | Replace `assert condition, msg` → `if not condition: raise ValueError(msg)` |

### CWE-798 — Use of Hard-coded Credentials

| Rule | Value pattern | Branch | CWE | Reason |
|------|--------------|--------|-----|--------|
| `bandit:B105` | value is `""`, `"test"`, `"fake"`, `"dummy"`, `"placeholder"`, `"changeme"`, or matches the variable name (e.g. `password = "password"`) | 3 (Suppress) | CWE-798 | Constant placeholder — FP; suppress with reason citing the constant |
| `bandit:B105` | value looks like a real credential (long opaque string, UUID, JWT pattern) | 4 (Carry-over) | CWE-798 | Real-looking credential — carry-over; gitleaks owns literal-secret redaction |
| `bandit:B106` | file path contains `tests/`, `conftest.py`, or `fixtures/` | 3 (Suppress) | CWE-798 | Hardcoded password default in test fixture — FP |
| `bandit:B106` | production code path | 4 (Carry-over) | CWE-798 | Hardcoded password default arg — structural; remove default, require caller to supply |
| `bandit:B107` | value is a constant / empty string | 3 (Suppress) | CWE-798 | Constant password arg — FP |
| `bandit:B107` | value looks like a real credential (long opaque string, UUID, JWT pattern) | 4 (Carry-over) | CWE-798 | Real-looking credential — carry-over; gitleaks owns literal-secret redaction |

### CWE-502 — Deserialization of Untrusted Data

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B301` | — | 4 (Carry-over) | CWE-502 | `pickle.load` — structural; cannot safely auto-fix without knowing data origin |
| `bandit:B302` | — | 4 (Carry-over) | CWE-502 | `marshal.load` — structural |
| `bandit:B403` | — | 4 (Carry-over) | CWE-502 | `import pickle` — diagnose; often paired with B301; carry-over as a unit |
| `bandit:B506` | `yaml.load(f)` or `yaml.load(stream)` with no Loader, or `Loader=yaml.Loader` / `Loader=yaml.FullLoader` in simple single-call pattern | 1 (Autofix) | CWE-502 | Simple yaml.load — swap to `yaml.safe_load()` |
| `bandit:B506` | `yaml.load` inside a class, with custom Loader, or nested | 4 (Carry-over) | CWE-502 | Complex yaml context — carry-over for human review |

### CWE-611 — XML External Entity (XXE)

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B405` | 1 (Autofix) | CWE-611 | `xml.etree.ElementTree` import — add `import defusedxml.ElementTree as ET` and replace parse calls |
| `bandit:B406` | 1 (Autofix) | CWE-611 | `xml.sax` import — swap to `defusedxml.sax` |
| `bandit:B407` | 1 (Autofix) | CWE-611 | `xml.dom.expatbuilder` — swap to `defusedxml` |
| `bandit:B408` | 1 (Autofix) | CWE-611 | `xml.dom.minidom` — swap to `defusedxml.minidom` |
| `bandit:B409` | 1 (Autofix) | CWE-611 | `xml.dom.pulldom` — swap to `defusedxml.pulldom` |
| `bandit:B410` | 1 (Autofix) | CWE-611 | `lxml` parse without `resolve_entities=False` — add `parser = etree.XMLParser(resolve_entities=False)` |

### CWE-295 / CWE-326 — Improper Certificate Validation / Inadequate Encryption Strength

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `bandit:B501` | 2 (Refactor) | CWE-295 | `requests.get(..., verify=False)` — remove `verify=False`; if custom CA needed, use `verify="/path/to/ca.pem"` |
| `bandit:B502` | 1 (Autofix) | CWE-295 | `ssl.PROTOCOL_TLSv1` — swap to `ssl.PROTOCOL_TLS_CLIENT` |
| `bandit:B503` | 1 (Autofix) | CWE-295 | `ssl.PROTOCOL_SSLv2` / `ssl.PROTOCOL_SSLv3` — swap to `ssl.PROTOCOL_TLS_CLIENT` |
| `bandit:B504` | 1 (Autofix) | CWE-295 | `ssl.wrap_socket` or `SSLContext` without `check_hostname = True` — add `ctx.check_hostname = True; ctx.verify_mode = ssl.CERT_REQUIRED` |
| `bandit:B505` | 1 (Autofix) | CWE-326 | RSA key size < 2048 bits — bump to 4096 |

### CWE-605 — Multiple Binds to the Same Port / Wildcard Bind

| Rule | Context | Branch | CWE | Reason |
|------|---------|--------|-----|--------|
| `bandit:B104` | file path contains `tests/`, `conftest.py`, `dev`, `local`, or `Dockerfile.dev` | 3 (Suppress) | CWE-605 | Wildcard bind in dev/test context — FP |
| `bandit:B104` | production code path | 2 (Refactor) | CWE-605 | `0.0.0.0` binding in prod — replace with `127.0.0.1` or a configurable bind address |

### safety / pip-audit — Vulnerable Dependency

| Rule | Branch | CWE | Reason |
|------|--------|-----|--------|
| `safety:*` | 1 (upgrade) or 4 (ignore fallback) | varies | Vulnerable dependency — delegate to upgrade-or-ignore flow (Section 4). Branch 1 when upgrade resolves; branch 4 when ignore entry added to tool config. |
| `pip-audit:*` | 1 (upgrade) or 4 (ignore fallback) | varies | Same as safety |

### No Match

If `(tool, rule)` matches none of the rows above: return `status: "error"` with
`fix_applied: false`. Log a `decision` entry naming the unmatched pair so the
classification table can be extended. **Do not apply Branch 3** for unrecognized codes.

## 4. Branch Playbooks

### Branch 1 — Autofix

**Trigger:** a safe mechanical substitution exists. The fix is deterministic — no
judgment about intent is required.

**Procedure:**

1. Re-read `<path>` from disk before editing (a prior finding in the same run may have
   already patched the file).
2. Apply the single targeted substitution from the patterns below. Edit only the
   flagged line (or its immediate import/dependency, if required by the fix).
3. Re-run bandit on `<path>` to confirm the finding is gone.

**Fix patterns by CWE:**

#### Crypto — B303 (MD5/SHA-1)

```python
# Before
import hashlib
digest = hashlib.md5(data).hexdigest()

# After
import hashlib
digest = hashlib.sha256(data).hexdigest()
```

If the MD5/SHA-1 was used for password hashing (variable names `password_hash`,
`pwd_hash`, etc.) escalate to B324 pattern below instead.

#### Crypto — B324 (weak password hash)

```python
# Before
import hashlib
stored = hashlib.md5(password.encode()).hexdigest()

# After
import bcrypt
stored = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
# Note: add bcrypt to project dependencies
```

If the project uses `argon2-cffi`:

```python
from argon2 import PasswordHasher
ph = PasswordHasher()
stored = ph.hash(password)
```

Add a comment: `# dependency: bcrypt>=4.0 (or argon2-cffi>=21.3)`.

#### Crypto — B304 (DES/Blowfish)

```python
# Before
from Crypto.Cipher import DES
cipher = DES.new(key, DES.MODE_ECB)

# After
from cryptography.fernet import Fernet
key = Fernet.generate_key()
cipher = Fernet(key)
# Note: add cryptography to project dependencies
```

#### Crypto — B305 (ECB mode)

```python
# Before
cipher = AES.new(key, AES.MODE_ECB)

# After
import os
iv = os.urandom(16)
cipher = AES.new(key, AES.MODE_GCM, nonce=iv)
```

#### Random — B311 (security context)

```python
# Before
import random
token = random.randint(0, 2**32)          # or random.choice for tokens/keys

# After
import secrets
token = secrets.token_hex(32)
# For choices: secrets.choice(sequence)
# For integers: secrets.randbelow(n)
```

#### yaml — B506 (simple pattern)

```python
# Before
import yaml
data = yaml.load(f)                   # or yaml.load(stream, Loader=yaml.Loader)

# After
import yaml
data = yaml.safe_load(f)
```

#### assert → raise — B101 (production code)

```python
# Before
assert user_id is not None, "user_id required"

# After
if user_id is None:
    raise ValueError("user_id required")
```

#### SSL — B502 / B503

```python
# Before
ctx = ssl.SSLContext(ssl.PROTOCOL_TLSv1)

# After
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
```

#### SSL — B504 (missing check_hostname)

```python
# Before
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS)
# missing check_hostname / verify_mode

# After
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
```

#### RSA key size — B505

```python
# Before
key = rsa.generate_private_key(public_exponent=65537, key_size=1024, ...)

# After
key = rsa.generate_private_key(public_exponent=65537, key_size=4096, ...)
```

#### XXE — B405–B410

```python
# Before — B405
import xml.etree.ElementTree as ET
tree = ET.parse(source)

# After
import defusedxml.ElementTree as ET
tree = ET.parse(source)
# Note: add defusedxml to project dependencies
```

Apply the same import-swap pattern for B406 (`xml.sax` → `defusedxml.sax`),
B408 (`xml.dom.minidom` → `defusedxml.minidom`), B409 (`xml.dom.pulldom` → `defusedxml.pulldom`).

For B410 (lxml):

```python
# Before
from lxml import etree
tree = etree.parse(source)

# After
from lxml import etree
parser = etree.XMLParser(resolve_entities=False)
tree = etree.parse(source, parser)
```

---

### Branch 2 — Refactor

**Trigger:** a structural fix is required. The code must be reorganized, not just
substituted.

**Procedure:**

1. Re-read the file before editing.
2. Apply the structural fix from the patterns below.
3. Preserve runtime semantics: do not change what the code does to valid inputs.
4. Re-run bandit on `<path>`.

If applying the fix would change API signatures visible to callers outside the file:
log a `decision` entry and escalate to Branch 4 (carry-over) with the diagnosis.
Changing an API contract is not a one-edit fix.

**Fix patterns:**

#### SQL Injection — B608

```python
# Before
query = f"SELECT * FROM users WHERE id = {user_id}"
cursor.execute(query)

# After
query = "SELECT * FROM users WHERE id = %s"
cursor.execute(query, (user_id,))
# For SQLite: use ? placeholder
# query = "SELECT * FROM users WHERE id = ?"
# cursor.execute(query, (user_id,))
```

If using an ORM (SQLAlchemy, Django ORM, Tortoise): prefer the ORM query API over
raw SQL. Log a `decision` entry noting the ORM is available.

#### OS Command Injection — B602 (shell=True with variable)

```python
# Before
import subprocess
subprocess.run(f"git commit -m '{message}'", shell=True)

# After
import subprocess
subprocess.run(["git", "commit", "-m", message], check=True)
```

If the command is complex (piped, shell built-in): log a `decision` entry recommending
carry-over — piped commands cannot be directly translated to `args=[]`.

#### os.popen / os.system — B604 / B605

```python
# Before
result = os.popen("ls -la").read()

# After
result = subprocess.run(["ls", "-la"], capture_output=True, text=True, check=True).stdout
```

#### TLS verify=False — B501

```python
# Before
response = requests.get(url, verify=False)

# After
response = requests.get(url)
# If a custom CA is required:
# response = requests.get(url, verify="/path/to/ca-bundle.crt")
```

If the `verify=False` is justified (e.g. corporate proxy with custom cert), add a comment
citing the reason and the cert path, and log a `decision` entry. Do not suppress with
`# nosec` for B501 — refactor or carry-over only.

#### Wildcard bind — B104 (production)

```python
# Before
server.bind(("0.0.0.0", port))

# After
bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
server.bind((bind_host, port))
```

---

### Branch 3 — Suppress (False Positive)

**Trigger:** the finding matches a deterministic false-positive pattern. The construct is
intentional and safe in this specific context.

**Suppression format (hard rule):**

```python
result = some_call()  # nosec B<id>: <specific reason>
```

The reason MUST identify:
1. What the construct is (e.g. "subprocess call to git")
2. Why it is safe here (e.g. "args fully constructed from internal constants")

**Rejected reasons** (too generic — return `status: "error"` if this is all you can write):
- `# nosec B101: false positive`
- `# nosec B311: not a security concern`
- `# nosec B602: known safe`

**Accepted reason examples:**

```python
assert result is not None  # nosec B101: assert in test context — test fixtures use assert by convention
random.shuffle(population)  # nosec B311: statistical simulation — population is anonymous survey data, not a credential
subprocess.run(["/usr/bin/git", "log"], ...)  # nosec B603: args are hardcoded internal constants, no user input
data = yaml.safe_load(f)  # already safe — if this fires, it is a bandit FP on safe_load alias
server.bind(("0.0.0.0", port))  # nosec B104: development server only — not reachable in production (BIND_HOST env var gates prod)
```

**Procedure:**

1. Re-read the file.
2. Confirm the FP pattern from the table in Section 3 applies (do not suppress if uncertain).
3. Compose a specific reason (reject generic reasons — escalate to carry-over instead).
4. Append `# nosec B<id>: <reason>` at end of the flagged line.
5. Re-run bandit on `<path>`.
6. Log `status: "warn"` with the nosec reason and CWE (see Section 7).

---

### Branch 4 — Carry-Over

**Trigger:** the finding cannot be safely auto-fixed. The code requires architectural
review, a refactor that changes API contracts, or involves deserialization / code injection
patterns where the safe fix depends on the data origin.

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

3. If a draft PR already exists for this branch:

```bash
EXISTING=$(gh pr view --json body --jq '.body')
DIAGNOSIS="$(printf '\n\n## Carry-over: %s:%s at %s:%s\n\n**Finding:** ...\n**CWE:** ...\n**Severity:** ...\n**Why not auto-fixed:** ...\n**Recommended fix:** ...' "<tool>" "<rule>" "<path>" "<line>")"
gh pr edit <num> --body "${EXISTING}${DIAGNOSIS}"
```

Otherwise, append to `<repo_root>/.makato/carry-over.jsonl` for `build-create-pr` to
consume.

4. Leave the failing hook red — do NOT suppress, do NOT use `--no-verify`.
5. Return `status: "error"` with `fix_applied: false` and `fix_description: "carry-over: <tool>:<rule> — structural, human review required"`.

**Carry-over templates by rule:**

| Rule | Recommended fix |
|------|----------------|
| B301 (pickle) | Replace `pickle.load` with a structured format (JSON, msgpack, protobuf) after verifying data origin |
| B302 (marshal) | Same as B301 |
| B307 (eval) | Remove `eval`; if dynamic dispatch is needed, use a registry dict |
| B102 (exec) | Remove `exec`; refactor to a plugin registry or importlib |
| B506 (complex yaml) | Switch to `yaml.safe_load` or validate Loader class; confirm no untrusted YAML input path |
| B105/B106/B107 (real credential) | Remove hardcoded credential; load from env var or secrets manager |

---

### upgrade-or-ignore — safety / pip-audit

This sub-flow extends `build-resolve-finding` Branch 3b with Python-specific context.

**Procedure** (mirrors build-resolve-finding §3b with additions):

1. Parse the finding to extract: package name, installed version, CVE ID, fixed version.
2. Detect package manager:
   - `pyproject.toml` + `uv.lock` → `uv lock --upgrade-package <pkg>`
   - `pyproject.toml` + `poetry.lock` → `poetry update <pkg>`
   - `requirements*.txt` → `pip install --upgrade <pkg>` + update the pinned version
3. Run the upgrade.
4. Re-run `safety check` / `pip-audit` on the updated dependencies.
5. Run the project test suite (fast subset, e.g. `pytest -x -q`).
6. If green: commit with `chore(deps): upgrade <pkg> for <CVE>`. Return `status: "ok"` with `fix_applied: true` and `fix_description: "upgraded <pkg> to <version> — resolves <CVE>"` (branch 1).
7. If no upgrade exists or upgrade breaks tests:
   - For **safety**: append to `<repo_root>/safety-policy.yml` under `ignore-vulnerabilities`:
     ```yaml
     - id: <CVE>
       reason: no-fix-available as of <today>
       expires: <today+30d>
     ```
   - For **pip-audit**: add `--ignore-vuln <CVE>` to the pip-audit invocation in CI, or add to `.pip-audit.toml`:
     ```toml
     [[tool.pip-audit.ignore]]
     id = "<CVE>"
     reason = "no-fix-available as of <today>"
     ```
   - Call `create-issue` with `title: "review CVE <CVE> ignore by <date>"`.
   - Return `status: "error"` with `fix_applied: false` and `fix_description: "CVE <id> ignored until <date> in tool config — no fix available; tracked in issue"` (branch 4 carry-over).

**Python-specific caveat:** if the vulnerable package is in a `dev` or `test` extras
group only (e.g. `[tool.poetry.group.dev.dependencies]`), note this in the
`create-issue` body and log a `decision` entry noting the dev-only scope. Do not open a
rotation issue for dev-only deps unless severity is CRITICAL. Add the ignore entry to the
tool's config file as above (not a `# nosec` comment — `safety` and `pip-audit` do not
read Python source comments).

## 5. Hard Rules

1. **Read disk state before editing.** The sensor-fixer loop may have already patched
   the file in the same run. Always re-read before applying a fix.
2. **One finding, one edit.** Never bundle fixes for adjacent findings. The caller
   re-runs bandit after each fix; multi-finding edits make the loop non-deterministic.
3. **Preserve runtime semantics.** Security fixes must not change what the code does to
   valid inputs. A guard that changes error type from `TypeError` to `ValueError` is
   a semantic change — escalate as Branch 4.
4. **No bare `# nosec`.** Always `# nosec B<id>: <specific reason>`. Generic reasons are
   rejected; escalate to Branch 4 if a specific reason cannot be written.
5. **Branch 3 logs `warn`.** Every suppression appends a `warn` entry to `build.jsonl`.
6. **Never bypass hooks.** Do not use `git commit --no-verify` or `SKIP=...` to hide
   a finding. Carry-over is the correct escalation path.
7. **Branch 4 for unrecognized codes.** If `(tool, rule)` matches no table row, return
   `status: "error"` — not a silent Branch 3 suppress.

## 6. Output Contract

Return a single JSON object to the caller:

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
- `status: "warn"` — fix applied via branch 3 (suppress); re-verify but flag for human
  review.
- `status: "error"` — could not apply any fix safely; finding escalates to carry-over in
  `build-resolve-finding`. Also returned when `(tool, rule)` is unrecognized.
- `branch` — integer 1–4 indicating which branch was used. For `upgrade-or-ignore`
  (safety/pip-audit), use `branch: 1` (upgrade resolved) or `branch: 4` (ignore entry
  added to tool config — no fix available). For the no-match error path (unrecognized
  `(tool, rule)`), omit `branch` or set it to `null` — no branch was entered.
- `fix_applied` — `true` if the file was edited, `false` if the skill bailed out.
- `fix_description` — one-line human-readable description of the edit, including the
  bandit rule ID and CWE.

## 7. Logging

Append JSONL entries to `specs/<story-key>/build.jsonl` via `shared/build-log.sh`.
Required entries:

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

Use bare `shared/build-log.sh` (no `../`) — Claude resolves it from the plugin root.

## 8. When to Use

Dispatched by `build-resolve-finding` Branch 2 (tech-skill route) for any finding
matching `bandit:*`, `safety:*`, or `pip-audit:*` in `shared/finding-routes.json`.
**Not invoked directly by the user.** If a user types `/build-fix-security`, respond with:

> "This skill is the per-finding security repair engine dispatched by
> `build-resolve-finding`. It is not invoked directly. To trigger it, run
> `/build-sensors` against a branch with bandit/safety violations, or pass a finding
> JSON via `build-resolve-finding`."
