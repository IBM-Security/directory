# idspgmaint.sh — PostgreSQL Maintenance Script

**Version:** 1.0.7 | **Last Updated:** 2025-10-06  
**Author:** J. Alejandro Carrillo  
**License:** Copyright contributors to the IBM Security Verify Directory project.

---

## Getting the Script into the Container

To use `idspgmaint.sh` inside an ISVD container, copy it to the container-mounted persistent volume by following these steps.

### 1. Create the scripts directory

**Docker**
```bash
docker exec -u 1000 <isvd-container-name> mkdir /var/isvd/data/scripts
```

**Kubernetes**
```bash
kubectl exec <isvd-pod-name> -- mkdir /var/isvd/data/scripts
```

### 2. Adjust the directory permissions

**Docker**
```bash
docker exec -u 1000 <isvd-container-name> chmod 750 /var/isvd/data/scripts/
```

**Kubernetes**
```bash
kubectl exec <isvd-pod-name> -- chmod 750 /var/isvd/data/scripts/
```

### 3. Copy the script into the container

**Docker**
```bash
docker cp idspgmaint.sh <isvd-target-container-name>:/var/isvd/data/scripts/idspgmaint.sh
```

**Kubernetes**
```bash
kubectl cp idspgmaint.sh <isvd-target-pod-name>:/var/isvd/data/scripts/idspgmaint.sh
```

---

## Overview

`idspgmaint.sh` is a controlled, predictable PostgreSQL maintenance script (PG 14–17) for **IBM Security Verify Directory (ISVD)**. It performs `VACUUM`, `VACUUM FULL`, `ANALYZE`, and `REINDEX` operations with:

- **Bloat-aware selection** — runs heavy operations only when tables or indexes exceed a configurable bloat threshold.
- **Dry-run planner** — previews all actions without making any changes.
- **Table excludes** — skips tables by name or glob pattern.
- **Live progress monitoring** — polls `pg_stat_progress_vacuum` / `pg_stat_progress_create_index`.
- **Autovacuum conflict management** — cancels, waits for, skips, or ignores competing autovacuum workers.
- **Exclusive VACUUM FULL mode** — safely revokes connections, runs all FULL tasks in a single session, then restores access.
- **Robust logging** — configurable log directory with automatic fallback.

> This script is designed for **planned maintenance windows** or for filling gaps when autovacuum's reactive, threshold-based approach leaves tables bloated. It is **not** a replacement for autovacuum.

---

## Requirements

| Requirement | Notes |
|---|---|
| `psql` in `PATH` | Must be reachable at runtime |
| PostgreSQL 14+ | Progress views (`pg_stat_progress_vacuum`, `pg_stat_progress_create_index`) |
| DB user privileges | `VACUUM`, `ANALYZE`, `REINDEX` on target objects; `ALTER DATABASE` when using `--full` |
| `pgstattuple` extension | Optional but recommended for accurate bloat estimation (`CREATE EXTENSION pgstattuple;`) |

---

## Quick Start

```bash
# Preview what the script will do — no changes made
./idspgmaint.sh --dry-run

# Routine online VACUUM + ANALYZE on all user tables in the default database
./idspgmaint.sh --analyze

# VACUUM FULL only on tables whose bloat exceeds 30%
./idspgmaint.sh --full-only-on-bloat=30 --analyze

# REINDEX indexes that exceed 25% bloat, concurrently
./idspgmaint.sh --reindex-only-on-bloat=25 --reindex-concurrently

# Scope to a specific schema and table, with live progress
./idspgmaint.sh -n public -t users --analyze --watch
```

---

## Usage

```
./idspgmaint.sh [connection options] [selection options] [mode options] [other options]
```

### Connection Options

| Option | Default | Description |
|---|---|---|
| `-d <database>` | `idsldap` | Target database name |
| `-U <user>` | `$PGUSER` or `idsldap` | PostgreSQL user |
| `-h <host>` | `$PGHOST` or `/run/postgresql` | Host or Unix socket directory |
| `-p <port>` | `$PGPORT` or `5432` | Port |

### Selection Options

| Option | Description |
|---|---|
| `-n <schema>[,...]` | Restrict to one or more schemas (repeatable) |
| `-t <table>[,...]` | Restrict to specific tables (schema-qualified or plain; repeatable) |
| `--exclude <pattern>[,...]` | Exclude tables by name or glob (`*`, `?`). Accepts `schema.table` or unqualified. Repeatable. Quote patterns to prevent shell expansion: `--exclude 'public.temp_*'` |

If neither `-n` nor `-t` is provided, **all user tables** are targeted (excludes `pg_catalog`, `information_schema`, `pg_toast%`).

### Vacuum / Analyze Modes

| Option | Description |
|---|---|
| _(none)_ | Online `VACUUM` on all targeted tables |
| `--full` | Force `VACUUM FULL` on all targeted tables (exclusive mode) |
| `--full-only-on-bloat[=N]` | `VACUUM FULL` only when table bloat ≥ N% (default: 20). Uses `pgstattuple_approx` if available, else falls back to `pg_stat_all_tables` dead-tuple ratio |
| `--analyze` | Run `ANALYZE` after `VACUUM` / `VACUUM FULL` |
| `--analyze-only` | Only run `ANALYZE` (skip all VACUUM) |

### REINDEX Modes

| Option | Description |
|---|---|
| `--reindex` | `REINDEX` after vacuum/analyze. Per-table only when `-t` is specified; otherwise schema or database scope |
| `--reindex-concurrently` | Use `REINDEX CONCURRENTLY` (lower locking, longer runtime) |
| `--reindex-only-on-bloat[=N]` | Auto-enables reindexing; runs `REINDEX` per-table only when BTREE index bloat ≥ N% (default: 20). Uses `pgstatindex()` if `pgstattuple` is available; else a catalog-based fallback |

### Progress Monitoring

| Option | Description |
|---|---|
| `--watch` | Show live progress for `VACUUM` and `REINDEX` |
| `--watch-quiet` | Concise one-line progress per poll (implies `--watch`) |
| `--watch-interval <sec>` | Poll interval in seconds (default: 15) |

### Logging

| Option | Description |
|---|---|
| `-l <dir>`, `--log-dir <dir>` | Log directory (default: `/var/isvd/data/logs/pgmaint_logger/`) |
| `--require-log-dir` | Exit non-zero if neither the provided nor the default log directory is usable (no stdout-only fallback) |

**Fallback policy:**
1. If `--log-dir` is unusable → warn and try the default directory.
2. If the default is also unusable → warn and log to stdout only.
3. If `--require-log-dir` is set and both fail → exit with code `5`.

Log files are named `pgmaint_<database>_<YYYYMMDD_HHMMSS>.log`.

### Autovacuum Conflict Management

| Option | Description |
|---|---|
| `--autovacuum-conflict {wait\|cancel\|skip\|ignore}` | How to handle an active autovacuum worker on a target table (default: `cancel`) |
| `--autovacuum-timeout <sec>` | Seconds before escalating from cancel → terminate (default: 600) |
| `--autovacuum-show-settings` | Display autovacuum GUCs and per-table `reloptions` during pre-check |

**Conflict policies:**

| Policy | Behaviour |
|---|---|
| `cancel` | Sends `pg_cancel_backend()`; escalates to `pg_terminate_backend()` after timeout |
| `wait` | Polls until the worker finishes or the timeout is reached, then proceeds |
| `skip` | Skips the table entirely if autovacuum is active |
| `ignore` | Disables all conflict detection; no pre-check runs |

The pre-check **temporarily disables autovacuum** per target table (`autovacuum_enabled=false`) and restores the setting on exit, whether the script succeeds or is interrupted.

### Planning

| Option | Description |
|---|---|
| `--dry-run` | Print a full plan of actions and exit 0 (no changes). Still connects read-only to enumerate tables and estimate bloat |

### Other

| Option | Description |
|---|---|
| `-V`, `--version` | Print script version and last updated date, then exit |
| `-H`, `--help` | Show usage help |

---

## How It Works

### Execution Steps

```
1. Verify psql is in PATH and parse CLI options
2. Initialize logging (with fallback)
3. Test database connectivity
4. Build the target table list from -n / -t (or all user tables)
5. Apply --exclude filters
6. Detect whether pgstattuple extension is installed
7. Execution planning:
   a. Bloat estimation per table (if --full-only-on-bloat)
   b. Index bloat estimation per table (if --reindex-only-on-bloat)
   → Assigns each table to: TO_VAC, TO_FULL, and/or TO_REIN
8. Autovacuum conflicts pre-check (disable per-table autovacuum)
9. If --dry-run: print plan and exit
10. Execute maintenance:
    A. Online VACUUM path (TO_VAC)
    B. VACUUM FULL exclusive path (TO_FULL)
    C. ANALYZE-ONLY path (if --analyze-only)
11. Print summary (OK / FAIL counts per operation)
12. Restore autovacuum settings (always runs on exit via trap)
13. Exit 0 (success) or 1 (any operation failed)
```

### VACUUM FULL Exclusive Mode

When `VACUUM FULL` is required the script enters exclusive mode:

1. **Prologue** — Revokes `CONNECT` on the database, sets `CONNECTION LIMIT 1`, and terminates all other sessions.
2. **Body** — Runs all `VACUUM FULL` (and optionally `ANALYZE` / `REINDEX`) statements in a single `psql` session.
3. **Epilogue** — Restores `CONNECTION LIMIT -1` and re-grants `CONNECT TO PUBLIC`.

If the epilogue fails (e.g. due to a crash), the script logs the manual recovery commands to run.

> ⚠️ After `VACUUM FULL` it is recommended to **restart the container**.

### Bloat Estimation

**Table bloat** (for `--full-only-on-bloat`):
- Preferred: `pgstattuple_approx()` — fast, accurate dead-tuple percentage.
- Fallback: `n_dead_tup / reltuples` ratio from `pg_stat_all_tables`.

**Index bloat** (for `--reindex-only-on-bloat`):
- Preferred: `pgstatindex()` — computes leaf-page density vs. fill factor.
- Fallback: catalog-based estimator using `pg_index`, `pg_class`, `pg_stats`, and `pg_attribute` — no extensions required.

The fallback path applies a **damping factor** to avoid reindexing tiny or nearly-empty indexes. Tune via environment variables (see [Advanced Tuning](#advanced-tuning)).

---

## Common Examples

```bash
# 1. Dry-run: see the full plan without touching anything
./idspgmaint.sh --dry-run

# 2. Online VACUUM + ANALYZE on all tables in the 'public' schema
./idspgmaint.sh -n public --analyze

# 3. VACUUM FULL on specific tables, with live progress
./idspgmaint.sh -n public -t orders,order_items --full --analyze --watch

# 4. Bloat-aware VACUUM FULL (skip tables below 25% bloat) + ANALYZE + REINDEX
./idspgmaint.sh --full-only-on-bloat=25 --analyze --reindex

# 5. ANALYZE-ONLY on all tables, exclude audit schema
./idspgmaint.sh --analyze-only --exclude 'audit.*'

# 6. REINDEX CONCURRENTLY where index bloat >= 30%
./idspgmaint.sh --reindex-only-on-bloat=30 --reindex-concurrently

# 7. Full maintenance with custom log directory, require logging
./idspgmaint.sh --full-only-on-bloat --analyze --reindex \
  --log-dir /var/log/mymaint --require-log-dir

# 8. Quiet progress, custom poll interval, skip tables with active autovacuum
./idspgmaint.sh --analyze --watch-quiet --watch-interval 30 \
  --autovacuum-conflict skip

# 9. Connect with explicit credentials
./idspgmaint.sh -d mydb -U myuser -h localhost -p 5433 --analyze

# 10. Check version
./idspgmaint.sh --version
```

---

## Advanced Tuning

These environment variables fine-tune the catalog-based index bloat fallback estimator. They must be exported before running the script.

| Variable | Default | Description |
|---|---|---|
| `REINDEX_MIN_INDEX_PAGES` | `8` | Skip tables whose largest BTREE index has fewer than this many pages (~64 KB). A fractional damping factor is applied as the page count approaches this threshold. |
| `REINDEX_MIN_SAVED_PAGES` | `3` | Require at least this many estimated pages saved (~24 KB). A fractional factor is applied as estimated savings approach this threshold. |
| `REINDEX_TINY_INDEX_PAGES_MAX` | `2` | Indexes with ≤ this many total pages are treated as 0% bloat (root + 1 leaf). |
| `REINDEX_DAMP_MODE` | `product` | How the two size factors are combined. Options from most to least aggressive: `power`, `product`, `min`, `division`, `max`, `none`. `none` applies no damping. |
| `REINDEX_DAMP_GAMMA` | `2.0` | Exponent for `power` mode (must be ≥ 1.0 and < 10). Higher values are more aggressive at suppressing bloat on small indexes. |

```bash
export REINDEX_MIN_INDEX_PAGES=16
export REINDEX_DAMP_MODE=min
./idspgmaint.sh --reindex-only-on-bloat=20
```

---

## Pre-Maintenance Checklist

Before running during a maintenance window:

```sql
-- 1. Check autovacuum lag
SELECT relname, n_dead_tup, last_autovacuum
FROM pg_stat_all_tables WHERE n_dead_tup > 100000;

-- 2. Check when ANALYZE last ran
SELECT schemaname, relname, n_live_tup, n_dead_tup, last_analyze
FROM pg_stat_all_tables ORDER BY last_analyze DESC LIMIT 50;

-- 3. Check for currently running maintenance
SELECT * FROM pg_stat_progress_vacuum;
SELECT * FROM pg_stat_progress_create_index;

-- 4. (Optional) Install pgstattuple for accurate bloat estimation
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- 5. Check free disk space (VACUUM FULL rewrites tables — needs 2× table size free)
```

Also:
- Disable heavy batch jobs (ETL, bulk inserts) to reduce lock contention.
- Take a fresh backup or snapshot before starting.

---

## Post-Maintenance Validation

```sql
-- Check stats were updated
SELECT relname, last_vacuum, last_analyze FROM pg_stat_all_tables;

-- Identify unused indexes
SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;

-- Check for invalid indexes (e.g. after interrupted REINDEX)
SELECT n.nspname AS schema, c.relname AS index_name, t.relname AS table_name
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid;
```

---

## Rollback / Recovery

The script automatically restores autovacuum and connection settings on exit via a `trap`. If the script is interrupted or crashes mid-run, follow these steps:

**Restore autovacuum on a table:**
```sql
ALTER TABLE schema.table RESET (autovacuum_enabled);
```

**Restore database connections after failed VACUUM FULL:**
```sql
ALTER DATABASE mydb WITH CONNECTION LIMIT -1;
GRANT CONNECT ON DATABASE mydb TO PUBLIC;
```

**Rebuild invalid indexes:**
```sql
-- Find invalid indexes
SELECT n.nspname AS schema, c.relname AS index_name, t.relname AS table_name
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid;

-- Rebuild
REINDEX INDEX index_name;
```

**Check table sizes after interrupted VACUUM FULL:**
```sql
SELECT n.nspname AS schema, c.relname AS table,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 15;
```

**Last resort — restore from backup:**
1. Stop the application.
2. Restore from your latest physical backup or `pg_basebackup` snapshot.
3. Apply WAL files if using PITR (Point-In-Time Recovery).

---

## Safety Tips

- **Always test in staging first.**
- **Always run `--dry-run` before the real execution** to confirm the plan.
- Use `--require-log-dir` when logs are mandatory for compliance.
- If downtime is unacceptable, avoid `--full` and use online `VACUUM` + `ANALYZE` only.
- Quote glob patterns passed to `--exclude` to prevent shell expansion: `--exclude 'public.temp_*'`.
- Monitor `pg_stat_activity` during the run for blocking sessions.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All operations succeeded (or `--dry-run` / `--version` / `--help`) |
| `1` | One or more `VACUUM`, `ANALYZE`, or `REINDEX` operations failed |
| `5` | Log directory unusable and `--require-log-dir` is set |
| `64` | Invalid CLI usage |
| `130` | Script received `SIGINT` or `SIGTERM` |

---

## Change History

| Version | Date | Summary |
|---|---|---|
| 1.0.1 | 2025-09-19 | Initial release: VACUUM / VACUUM FULL (+ ANALYZE), REINDEX with progress |
| 1.0.2 | 2025-09-20 | `--full-only-on-bloat[=N]`: bloat-aware VACUUM FULL with `pgstattuple_approx` |
| 1.0.3 | 2025-09-22 | `--dry-run`: full plan preview with bloat estimates, no changes |
| 1.0.4 | 2025-09-24 | Robust logging controls, `-l` alias, `--require-log-dir`, fallback chain |
| 1.0.5 | 2025-09-26 | `--exclude` filter with glob support (`*`, `?`), schema-qualified or plain names |
| 1.0.6 | 2025-09-29 | Autovacuum conflict management (wait/cancel/skip/ignore), per-table disable/restore, total execution time, VACUUM FULL restart warning |
| 1.0.7 | 2025-10-06 | `-d` / `-U` / `-h` / `-p` now optional with smart defaults; `--reindex-only-on-bloat[=N]` with `pgstatindex()` accurate path and catalog-based fallback with damping |

---

## References

- [pgstattuple extension](https://www.postgresql.org/docs/pgstattuple.html)
- [PostgreSQL VACUUM](https://www.postgresql.org/docs/14/sql-vacuum.html)
- [PostgreSQL ANALYZE](https://www.postgresql.org/docs/14/sql-analyze.html)
- [Progress Reporting (PG14+)](https://www.postgresql.org/docs/14/progress-reporting.html)
- [IBM Directory Server idspgmaint](https://www.ibm.com/docs/en/verify-directory/11.0.0?topic=utilities-idspgmaint)
- [IBM Directory Server planning database maintenance guide](https://www.ibm.com/docs/en/verify-directory/11.0.0?topic=planning-postgresql-database-maintenance-guide)
