# Branch 2 — Refactor: Structural Fix Patterns

Load this reference **only when executing Branch 2** (SQL injection B608,
OS command injection B602/B603/B604/B605/B606/B607, TLS verify=False B501,
wildcard bind B104).
Do NOT load for Branch 1 autofix patterns.

## B608 — SQL injection

```python
# Before
query = f"SELECT * FROM users WHERE id = {user_id}"
cursor.execute(query)

# After (generic DB-API 2.0 — psycopg2, mysql-connector, etc.)
query = "SELECT * FROM users WHERE id = %s"
cursor.execute(query, (user_id,))

# SQLite: use ? placeholder
# query = "SELECT * FROM users WHERE id = ?"
# cursor.execute(query, (user_id,))
```

If an ORM (SQLAlchemy, Django ORM, Tortoise) is already in scope: prefer the ORM query
API over raw SQL. Log a `decision` entry noting the ORM is available.

## B602 — shell=True with variable arg

```python
# Before
import subprocess
subprocess.run(f"git commit -m '{message}'", shell=True)

# After
import subprocess
subprocess.run(["git", "commit", "-m", message], check=True)
```

If the command uses shell built-ins (pipes, redirects, `&&`): log a `decision` entry
recommending carry-over — piped commands cannot be directly translated to `args=[]`
without restructuring the surrounding logic.

## B604 / B605 — os.popen / os.system

```python
# Before
result = os.popen("ls -la").read()

# After
result = subprocess.run(["ls", "-la"], capture_output=True, text=True, check=True).stdout
```

## B501 — TLS verify=False

```python
# Before
response = requests.get(url, verify=False)

# After
response = requests.get(url)
# If a custom CA is required:
# response = requests.get(url, verify="/path/to/ca-bundle.crt")
```

If `verify=False` is justified by a corporate proxy with a custom cert: add a comment
citing the reason and the cert path, and log a `decision` entry. Do NOT add `# nosec`
for B501 — `verify=False` disables TLS peer authentication entirely; the failure mode
is silent data exposure to a MITM, not an application error, so suppression masks a
genuine security hole. Refactor or carry-over only.

## B104 — Wildcard bind (production)

```python
# Before
server.bind(("0.0.0.0", port))

# After
bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
server.bind((bind_host, port))
```
