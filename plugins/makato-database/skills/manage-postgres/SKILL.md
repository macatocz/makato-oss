---
name: manage-postgres
description: >-
  Postgres performance, schema, security, and concurrency best practices
  organized across 30+ expert reference files. Use when: writing or reviewing
  SQL queries; designing or auditing schemas; diagnosing slow queries (missing
  indexes, EXPLAIN output); implementing or debugging Row Level Security (RLS);
  configuring connection pooling (PgBouncer, transaction vs session mode);
  preventing deadlocks; building queue-processing patterns; implementing upsert
  logic; designing table partitioning; cursor-based pagination; advisory locking;
  prepared statements with a pooler. Trigger keywords: postgres, postgresql, sql,
  index, slow query, explain analyze, rls, row level security, connection pool,
  pgbouncer, deadlock, schema design, migration, partition, jsonb,
  pg_stat_statements, upsert, pagination, advisory lock, prepared statement,
  covering index, identifier quoting.
version: "1.1.3"
license: MIT
argument-hint: "[symptom or task description]"
metadata:
  author: makato AI team
  last_updated: 2026-08-05
  abstract: >
    Postgres performance optimization guide covering 8 categories from
    critical (query performance, connection management, security/RLS)
    to incremental (advanced features). Each reference file contains
    incorrect/correct SQL pairs, EXPLAIN output, and performance metrics.
---

# Postgres Best Practices

Navigation skill — match the user's symptom to the right reference file(s) before advising.

## Symptom → Reference (load these FIRST)

MANDATORY: resolve the user's symptom here, then load only the matching reference
files. Load the MINIMUM set that covers the symptom — do not load all files
speculatively.

| Symptom or task | Load FIRST |
|---|---|
| Slow SELECT / sequential scan on large table | `query-missing-indexes.md`, `monitor-explain-analyze.md` |
| Slow query with composite or partial filter | `query-composite-indexes.md`, `query-partial-indexes.md` |
| Index-only scan / covering index / heap fetch elimination | `query-covering-indexes.md` |
| Index type selection / GIN vs GiST vs BRIN / expression indexes | `query-index-types.md` |
| RLS policy causing slowdown / wrong row visibility | `security-rls-performance.md` |
| Implementing RLS from scratch / writing first RLS policy | `security-rls-basics.md` |
| "too many clients" / connection-limit errors | `conn-pooling.md`, `conn-limits.md` |
| Idle connections holding locks or exhausting slots | `conn-idle-timeout.md` |
| Prepared statements / query plan caching / PgBouncer prepared statement errors | `conn-prepared-statements.md` |
| Deadlock errors in logs | `lock-deadlock-prevention.md` |
| Queue workers blocking each other on same rows | `lock-skip-locked.md` |
| Long-running transaction holding lock | `lock-short-transactions.md` |
| Custom serialization / distributed locking / pg_advisory_lock | `lock-advisory.md` |
| Schema design / migration / data type choice | `schema-primary-keys.md`, `schema-constraints.md`, `schema-data-types.md` |
| Foreign key performance / missing FK index | `schema-foreign-key-indexes.md` |
| Table partitioning / partition pruning / large time-series tables | `schema-partitioning.md` |
| Identifier quoting / case sensitivity / CamelCase schema warnings | `schema-lowercase-identifiers.md` |
| N+1 queries / excessive round trips | `data-n-plus-one.md` |
| Bulk insert performance | `data-batch-inserts.md` |
| Offset pagination performance / cursor-based pagination | `data-pagination.md` |
| INSERT ON CONFLICT / upsert logic / idempotent writes | `data-upsert.md` |
| Privilege audit / least-privilege setup | `security-privileges.md` |
| EXPLAIN output interpretation | `monitor-explain-analyze.md` |
| Production query statistics / top slow queries | `monitor-pg-stat-statements.md` |
| Table bloat / autovacuum tuning | `monitor-vacuum-analyze.md` |
| Symptom unknown / general performance audit | `monitor-pg-stat-statements.md`, `monitor-explain-analyze.md`, `query-missing-indexes.md` |

Do NOT load `advanced-*` files unless the user explicitly asks about full-text
search (`advanced-full-text-search.md`) or JSONB operators/indexing
(`advanced-jsonb-indexing.md`).

**Multi-symptom triage:** When the user reports more than one symptom, load all
matched references, but sequence advice — resolve the highest-impact issue first
(priority order: connection exhaustion → lock/deadlock → RLS slowdown → missing
index → schema). When no symptom clearly maps to a row above, use
AskUserQuestion with selectable options:
> "Which best describes your situation? (a) Slow query or missing index (b) Connection errors or pooling (c) RLS / security concern (d) Schema design or migration (e) Locking or deadlock (f) Other Postgres question"

Route to the matching rows after the answer.

**Full reference index:** `references/_sections.md` lists all 30+ files with
one-line descriptions and their category (query-, conn-, security-, schema-,
lock-, data-, monitor-, advanced-).

## Anti-Patterns

NEVER write `auth.uid()` bare in an RLS `USING` clause.
WHY: it is evaluated once per candidate row at the catalog level — on a 1M-row
table that is 1M function invocations per query, causing 100x+ slowdowns. Wrap
it: `(select auth.uid())` forces a single evaluation that Postgres caches for
the statement.

NEVER create a `SECURITY DEFINER` function without `SET search_path = ''`.
WHY: without pinning the search path, an attacker who owns a schema earlier in
`search_path` can shadow any table the function touches, hijacking its elevated
privileges. Always pair with `REVOKE EXECUTE ... FROM PUBLIC`.

NEVER open a raw Postgres connection per HTTP request without a pooler.
WHY: each Postgres backend costs 1-3 MB RAM plus a fork. At 500 concurrent
requests without PgBouncer the database exhausts memory and crashes. Use
transaction-mode pooling for stateless apps.

NEVER use session-mode pooling for serverless or short-lived processes.
WHY: session mode holds a backend connection for the client's entire session
lifetime. A serverless function that sits idle between invocations still occupies
a backend slot, defeating the pooler entirely. Use transaction mode instead.

NEVER acquire row locks in different orders across concurrent transactions.
WHY: two transactions locking rows A→B and B→A create a circular wait. Postgres's
deadlock detector resolves it by killing one transaction, but the caller sees a
non-retryable error. Always lock in a deterministic order:
`SELECT ... FOR UPDATE ORDER BY id`.

NEVER use UUIDv4 (`gen_random_uuid()`) as a primary key on tables expected to
grow beyond ~100K rows.
WHY: random UUIDs scatter every insert across the entire B-tree, making each
insert a random-access write. This causes index fragmentation and 2-3x index
size overhead compared to sequential keys. Use `bigint generated always as
identity` for single-database deployments or UUIDv7 (time-ordered) for
distributed systems.

NEVER grant `ALL PRIVILEGES` to an application role.
WHY: a single SQL injection or compromised credential then has DROP TABLE rights
and can cascade-destroy the schema. Grant exactly `SELECT`/`INSERT`/`UPDATE` per
table; withhold `DELETE` and DDL unless the application explicitly requires them.

NEVER run `CREATE INDEX` (non-CONCURRENTLY) on a live table during peak hours.
WHY: a standard index build holds `ShareLock` for its entire duration, blocking
all concurrent writes to the table. Use `CREATE INDEX CONCURRENTLY` — it allows
normal reads and writes throughout the build, at the cost of ~2-3x longer build
time. Note: `CONCURRENTLY` cannot run inside a transaction block.

## External References

- [Postgres Documentation](https://www.postgresql.org/docs/current/)
- [Postgres Wiki — Performance Optimization](https://wiki.postgresql.org/wiki/Performance_Optimization)
