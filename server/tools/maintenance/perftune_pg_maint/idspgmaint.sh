#!/bin/bash

##############################################################################
# Copyright contributors to the IBM Security Verify Directory project.
##############################################################################

# perftune_pg_maint.sh
# Authors: Alejandro Carrillo
# Last Updated: 2025 10 06
# Version: 1.0.7
# Desription:
#   PostgreSQL 14 to 17 maintenance: VACUUM / VACUUM FULL (+ ANALYZE), REINDEX with progress,
#   bloat-aware selection, dry-run planner, table excludes, and robust logging controls.
#   The script is designed for planned, controlled maintenance, not to replace autovacuum,
#   but to fill the gaps when you need predictability and precision.
# Key behavior references:
#
#   VACUUM vs VACUUM FULL semantics:       https://www.postgresql.org/docs/14/sql-vacuum.html
#   ANALYZE semantics:                     https://www.postgresql.org/docs/14/sql-analyze.html
#   Progress views (VACUUM/REINDEX/etc.):  https://www.postgresql.org/docs/14/progress-reporting.html
#
# Notes:
#   - Requires privileges to VACUUM/ANALYZE/REINDEX the target objects
#       * (plus permission to alter DB connect/limit when doing FULL).
#       * Designed with PostgreSQL 14 in mind (progress views for REINDEX).
#   - VACUUM  — reclaims dead tuples and updates visibility maps. 
#       * It can run with concurrent reads/writes;
#       * however it doesn't usually return disk space to the OS.
#       * USE VACUUM for routine maintenance; it’s online and lighter.
#   - VACUUM FULL — rewrites the table to compact it and returns space to the OS, 
#       * but it’s slower and needs ACCESS EXCLUSIVE locks while it runs.
#       * USE VACUUM FULL during a maintenance window when you need 
#       * to reclaim OS disk space or after unusual bloat spikes.
#   - For VACUUM FULL, the script enters an "exclusive DB mode":
#       * keep 1 persistent connection
#       * block new connections and terminate others
#       * run all FULL tasks in that same session
#       * restore connection setting afterward
#   - Bloat heuristic — runs VACUUM FULL only for tables whose bloat exceeds the threshold 
#       * (defaults to 20% if you pass --full-only-on-bloat[=N] without a value).
#       * Prefers pgstattuple_approx if the pgstattuple 
#       * extension is available (for fast estimate of dead tuples), 
#       * else falls back to a dead-tuple ratio using pg_stat_all_tables.
#   - ANALYZE — updates optimizer statistics. It can be run after VACUUM 
#       * or issue ANALYZE separately when data changed substantially.
#   - REINDEX - correct index size growth, fix bloated/corrupted indexes,
#       * progress is tracked via pg_stat_progress_create_index (PG14+).
#   - PostgreSQL runs Autovacuum automatically; this script is for manual, 
#       * controlled maintenance on hot tables or during planned windows. 
#       * Be mindful of autovacuum thresholds and parameters (e.g., autovacuum_vacuum_threshold, autovacuum_vacuum_scale_factor).
#
# Why manual online VACUUM can still be necessary even though PostgreSQL has Autovacuum:
#   Autovacuum is reactive and threshold-based: It kicks in when dead tuples exceed certain thresholds 
#       (autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor). If your workload generates a lot of churn
#       in short bursts, autovacuum might lag behind, leaving tables bloated for longer than you’d like.
#   Autovacuum trigger formula (simplified): vacuum when n_dead_tup > vacuum_threshold + scale_factor × reltuples
#       lowering the scale factor on big tables triggers earlier.
#   Autovacuum_vacuum uses more background I/O:
#       Here’s why:
#           Performs heap cleanup: scans table pages, removes dead tuples, and updates visibility maps.
#           Writes changes back to disk (especially if many dead tuples exist).
#           Can also trigger index cleanup. Analyze is mostly read-only and lightweight compared to vacuum.
#           Therefore, it involves significant read + write I/O.
#       Practical implication:
#           If you’re tuning autovacuum for I/O-sensitive environments, focus on autovacuum_vacuum_cost_limit
#           and autovacuum_vacuum_cost_delay because vacuum is the heavier operation. 
#           Analyze rarely causes noticeable I/O pressure.  
#   Critical tables under heavy load: For high-traffic tables, you may want to force a cleanup during a controlled window 
#       to avoid performance degradation (e.g., index bloat, slow queries).
#   Autovacuum can be disabled or throttled: Some environments tune autovacuum aggressively low to reduce background I/O, 
#       which means dead tuples accumulate faster.
#   Statistics freshness: If you need up-to-date optimizer stats before a big reporting job or after a bulk load, running VACUUM
#       (or ANALYZE) manually ensures the planner has accurate data.
#   Avoiding VACUUM FULL: Running regular online VACUUM proactively reduces the need for disruptive VACUUM FULL later.
#
# How Autovacuum Can Conflict with This Script:
#   Lock Contention: VACUUM FULL in the script requires an ACCESS EXCLUSIVE lock on the table.
#       This can interrupt autovacuum mid-run, and cause autovacuum to restart later, wasting resources. 
#       If autovacuum is running on the same table, the script will block or fail because autovacuum holds a weaker lock but prevents escalation.
#       Conversely, autovacuum workers will be canceled if the script grabs the lock first.
#       The script, when running VACUUM FULL, terminates other sessions (including autovacuum workers) to enforce exclusivity.
#   Performance Interference: Both autovacuum and the script consume I/O and CPU.
#       If they run concurrently on large tables, you can see I/O saturation, longer runtimes, and possible query latency spikes.
#   Analyze Conflicts: If the script runs ANALYZE while autovacuum is also analyzing, one will wait or abort, wasting cycles.
#   Reindex Conflicts: REINDEX (especially without CONCURRENTLY) needs strong locks.
#       Autovacuum on the same table can block or be canceled, causing retries and log noise.
#
# This script counts with an autovacuum conflict management.
#   It handles autovacuum conflicts by default, unless ran with --autovacuum-conflict ignore.
#   The default policy is to try to gracefully cancel confilcting autovacuum,
#   and scalates to terminate after --autovacuum-timeout <sec>, 600 by default.
#
# Decision Tree for VACUUM Usage
#   Here’s a simplified decision tree:
#                ┌───────────────┐
#                │  Table bloat? │
#                └───────┬───────┘
#                        │
#            ┌───────────┴───────────┐
#            │                       │
#        No significant         Significant
#        bloat (<20%)           bloat (≥20%)
#            │                       │
#    ┌───────┴───────┐        ┌──────┴───────┐
#    │               │        │              │
#  Routine       Stats       Need to     Can afford
#  cleanup?     outdated?    reclaim     downtime?
#    │               │        │              │
#    │               │        │              │
# VACUUM        ANALYZE   Yes → VACUUM   No → VACUUM
# (online)      (only)    FULL (exclusive)   (online)
#
# Key points:
#   VACUUM: Use for routine cleanup; safe online.
#   ANALYZE: Use when data distribution changes significantly.
#   VACUUM FULL: Use only when reclaiming OS disk space or after heavy bloat; requires downtime.
#
# Pre-Checks Before the Maintenance Window:
#   Check autovacuum lag:
#       SQLSELECT relname, n_dead_tup, last_autovacuum
#           FROM pg_stat_all_tables WHERE n_dead_tup > 100000;
#   Check when analyze was last ran:
#       SQLSELECT schemaname, relname, n_live_tup, n_dead_tup, last_analyze
#           FROM pg_stat_all_tables
#           ORDER BY last_analyze DESC LIMIT 50;
#   Enable pgstattuple extension (optional, for accurate bloat estimation).
#       Check If pgstattuple is installed:
#           SQLSELECT * FROM pgstattuple_approx('schema.table');
#       Install pgstattuple in it is not already installed:
#           CREATE EXTENSION IF NOT EXISTS pgstattuple;
#   Check if any maintenance is currently happening 
#   Disk space: Ensure enough free space for VACUUM FULL (it rewrites tables).
#   Backups: Take a fresh backup or snapshot before starting.
#
# During the Maintenance Window:
#   Disable heavy jobs (ETL, batch inserts) to reduce lock contention.
#   Monitor logs in /var/log/pgmaint_logger and pg_stat_activity for blocking sessions.
#   Monitor live progress (PG14+)
#       VACUUM:
#           SQLSELECT * FROM pg_stat_progress_vacuum;
#       Index build:
#           SQLSELECT * FROM pg_stat_progress_create_index;
#   If VACUUM FULL is triggered, expect exclusive mode (script will revoke connections and restore them after).
#
# Post-Maintenance
#   Check stats:
#       SQLSELECT relname, last_vacuum, last_analyze FROM pg_stat_all_tables;
#   Validate indexes:
#       SQLSELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;
#   Re-enable jobs and monitor performance.
#
# Rollback Plan
# These rollback steps are provided so you can recover quickly if something fails, or goes wrong during or after the run:
#   Restore Autovacuum Settings:
#       The script automatically resets any temporary changes on exit, but if it fails or is interrupted 
#       re-enable autovacuum for any tables that were disabled (run this for each table if needed):
#           ALTER TABLE schema.table RESET (autovacuum_enabled);
#   Restore Connection Settings:
#       The script automatically resets connections when VACUUM FULL is ran. However, 
#       if the script fails during exclusive mode, connections might still be blocked:
#           ALTER DATABASE mydb WITH CONNECTION LIMIT -1;
#           GRANT CONNECT ON DATABASE mydb TO PUBLIC;
#   Rebuild Indexes if Interrupted:
#       If REINDEX was partially executed, some indexes may be invalid:
#       Check for invalid indexes:
#           SELECT schemaname, relname, indexrelname FROM pg_stat_all_indexes WHERE NOT indisvalid;
#           List invalid index in a more readable format:
#               SELECT n.nspname AS schema, c.relname AS index_name, t.relname AS table_name
#               FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_class t ON t.oid = i.indrelid 
#               JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT i.indisvalid;
#       Rebuild invalid indexes:
#           REINDEX INDEX index_name;
#   Re-run ANALYZE:
#       If ANALYZE didn’t complete:
#           ANALYZE VERBOSE;
#   Disk Space Recovery Check:
#       If VACUUM FULL was interrupted, some tables may still be bloated:
#       Check table sizes:
#           SELECT schemaname, relname, pg_size_pretty(pg_total_relation_size(relid))FROM pg_stat_user_tablesORDER BY 
#               pg_total_relation_size(relid) DESC;
#           Identify Large/Bloated Relations in a more readable format:
#               SELECT n.nspname AS schema, c.relname AS table,
#                   pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
#               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
#               WHERE c.relkind = 'r' ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 15;
#       Re-run VACUUM FULL on the largest offenders if needed:
#           VACUUM FULL schema.table;
#   Validate Database Health. Run consistency checks:
#       Look for invalid objects:
#           SELECT * FROM pg_catalog.pg_class WHERE relkind IN ('i','r') AND relname LIKE '%invalid%';
#       Check for deadlocks or blocked sessions:
#           SELECT * FROM pg_locks WHERE granted = false;
#           Inspect Locks/Blocking in a more readable format:
#               SELECT a.pid, a.usename, a.query, l.locktype, l.mode, l.granted FROM pg_locks l
#               JOIN pg_stat_activity a ON a.pid = l.pid WHERE l.granted = false;
#   Restore from backup if corruption or major failure occurs (Last Resort):
#       Stop the application.
#       Restore from your latest physical backup or pg_basebackup snapshot.
#       Apply WAL files if using PITR (Point-In-Time Recovery).
#
# Safety Tips
#   Always test in staging first.
#   Always run --dry-run first to confirm the plan.
#   Use --require-log-dir if logs are mandatory for compliance.
#   If downtime is unacceptable, avoid VACUUM FULL and stick to online VACUUM + ANALYZE.

################################################################################
# Script Change History
#
#   DATE      Ver.  Author        Abstract
# ----------  ----  ------------- ---------------------------------------------
# 09/19/2025  1.0.1 J. Alejandro  PostgreSQL 14 maintenance: VACUUM / VACUUM FULL (+ ANALYZE), REINDEX with progress.
#                                 - Mandatory: -d <database>, -U <user>
#                                 - Optional: -n <schema>[,schema...]  -t <table>[,table...]  (if omitted => all user schemas/tables)
# 09/20/2025  1.0.2 J. Alejandro  --full-only-on-bloat[=N] runs VACUUM FULL only for tables whose bloat exceeds the threshold 
#                                 (defaults to 20% if used without a value). Prefers pgstattuple_approx if the pgstattuple 
#                                 extension is available (for fast estimate of dead tuples), 
#                                 else falls back to a dead-tuple ratio using pg_stat_all_tables.
# 09/22/2025  1.0.3 J. Alejandro  --dry-run: Prints a plan of actions and exits with 0 (unless discovery fails).
#                                 Dry run still:
#                                 * Connects to the DB to enumerate schemas/tables.
#                                 * Computes --full-only-on-bloat decisions using pgstattuple_approx if available (fast estimate), 
#                                   otherwise a dead tuple ratio fallback from pg_stat_all_tables.
#                                 Dry run does not:
#                                 * Perform VACUUM/VACUUM FULL/ANALYZE/REINDEX.
#                                 * Block connections or terminate other sessions.
#                                 * Start progress watchers.
# 09/24/2025  1.0.4 J. Alejandro  Updated logging behavior for a more robust logging controls.
#                                 -l <dir> is now a short alias for --log-dir <dir>.
#                                 The default log dir is /var/isvd/data/logs/pgmaint_logger/.
#                                 If --log-dir is provided and can’t be created or isn’t writable 
#                                   → the script warns and falls back to the default.
#                                 If the default also can’t be created or isn’t writable 
#                                   → the script warns and falls back to stdout only logging.
#                                 --require-log-dir:  when present, the script fails hard (exits non zero) 
#                                 instead of falling back to stdout only logging 
#                                 if the chosen provided and default directory aren’t usable.
# 09/26/2025  1.0.5 J. Alejandro  Added the --exclude filter flag for tables:
#                                 What it does: 
#                                 * Skips tables from the target set after -n/-t selection but 
#                                   before bloat checks / VACUUM / ANALYZE / REINDEX planning.
#                                 How to specify:
#                                 * Comma separated list and/or multiple --exclude flags.
#                                 * Schema qualified (e.g., audit.events) or unqualified 
#                                   (e.g., sessions to exclude in all selected schemas).
#                                 * Supports shell globs * and ? (e.g., public.temp_*, audit.*).
#                                 Tip: 
#                                 * Quote patterns to prevent your shell from expanding them: --exclude 'public.temp_*'.
#                                 Parsing:
#                                 * You can pass --exclude multiple times or comma separate values. 
#                                   Each token is normalized to lower case for comparison.
#                                 Matching:
#                                 * If a token contains a dot (schema.table), it matches against the fully qualified name.
#                                 * If not, it matches against the table name only (across the selected schemas).
#                                 * Globs (*, ?) are supported through Bash’s [[ ... == pattern ]], 
#                                   so use quotes to prevent your shell from expanding them.
#                                 Order of operations:
#                                 * Build initial TARGETS from -n and/or -t (or all user tables).
#                                 * Apply --exclude filters.
#                                 * Proceed to bloat estimation and plan (VACUUM/VACUUM FULL vs --full-only-on-bloat), and ANALYZE/REINDEX.
#                                 * In --dry-run, you’ll now see “Excluded by --exclude: …” lines and the “After --exclude … remain” summary.
# 09/29/2025  1.0.6 J. Alejandro  Autovacuum conflict management:
#                                 * Default policy = cancel (escalates to terminate after timeout).
#                                 * --autovacuum-conflict {wait|cancel|skip|ignore}
#                                 * --autovacuum-timeout <sec>
#                                 * --autovacuum-show-settings (optional diagnostics in pre-check).
#                                 * Autovacuum Conflicts Pre-check per-target table disables autovacuum temporarily (restored on exit).
#                                 * If policy=ignore → no pre-check and no per-table detection
#                                 * A single per-table function handles (detect and resolve) autovacuumand conflicts,
#                                 * and it is called within online VACUUM, VACUUM FULL, and ANALYZE-ONLY paths.
#                                 Added -V a short alias for the --version flag: Prints the script version and last updated date, then exit.
#                                 Added the total_exec_time() function to calculate the total execution time.
#                                 * The total execution time will now be printed every time at the end of execution.
#                                 Added message to warn user to restart the container after VACUUM FULL.
#                                 * The warning message will now be printed at the end of execution everytime VACUUM FULL was executed.
#
# What’s new:
# This version: 1.0.7
#   Changed script requirement:
#       Made -d and -U to be no longer mandatory.
#       -d will now default to 'idsldap' if no option provided.
#       -U will default to the value of env variable PGUSER, or 'idsldap' if not set.
#       -h will default to the value of env variable PGHOST, or '/run/postgresql' if not set.
#       -p will default to the value of env variable PGPORT, or '5432' if not set.
#   Added the --reindex-only-on-bloat[=<pct>] flag: 
#       It auto-enables reindexing and builds per-table
#       Does the REINDEX plan and store it in (TO_REIN) during planning.
#       Uses pgstatindex() if pgstattuple is installed; 
#       otherwise a catalog-based fallback estimator.
#       - If --reindex-only-on-bloat: 
#       * REINDEX is executed only for tables in TO_REIN 
#       * TO_REIN computed by threshold for all targets.
#       - Else if --reindex/--reindex-concurrently: 
#       * TO_REIN populated only when -t used.
#       - get_index_bloat_pct() replaces any runtime gating; it's called only in
#       Execution Planning (after --exclude, before autovac pre-check).
#   All previously delivered features (dry-run, excludes, bloat-aware FULL, ANALYZE-only,
#   REINDEX w/ progress, exclusive VACUUM FULL mode, in this version -d and -U are no longer mandatory, 
#   optional -n/-t) remain intact.
#
# Options to add later:
#   To add a --plan-json flag to emit the dry run plan in JSON for CI/CD pipelines.
#   Parallelism (careful with locks): run multiple non FULL vacuums in background with a concurrency limit.
#
# Usage:
#   - Connection: -d <database>, -U <user>, -h <host>, -p <port>
#                (will use 'idsldap', $PGUSER, $PGHOST, $PGPORT respectively if they are not supplied)
#   - Selection:  -n <schema>[,schema...]  -t <table>[,table...]
#                (if neither -n nor -t is supplied => all user schemas/tables)
#   - Logging policy:
#       * Default log dir: /var/isvd/data/logs/pgmaint_logger/
#       * -l <dir> | --log-dir <dir> overrides the default
#       * If provided dir unusable -> WARN, fall back to default
#       * If default dir unusable  -> WARN, fall back to stdout-only
#       * --require-log-dir -> fail hard ONLY if both provided and default are unusable
#   - Autovacuum conflict policy:
#       * --autovacuum-conflict {wait|cancel|skip|ignore}
#       * Default policy = cancel (escalates to terminate after timeout)
#       * --autovacuum-timeout <sec> overrides the default 600
#       * --autovacuum-show-settings (optional diagnostics in pre-check)
#   - VACUUM FULL safety: block new connections (REVOKE CONNECTIONS),
#     terminate other sessions, run FULL, then restore connections.
#   - Modes:
#       --full                      : Force VACUUM FULL on selected tables
#       --full-only-on-bloat[=N]    : VACUUM FULL only if bloat >= N% (default 20 when flag passed w/o value)
#       --analyze                   : ANALYZE after vacuum/full
#       --analyze-only              : only ANALYZE (no VACUUM)
#       --reindex                   : REINDEX after maintenance (or with --analyze-only)
#       --reindex-concurrently      : use REINDEX CONCURRENTLY
#       --reindex-only-on-bloat[=N] : REINDEX only when BTREE index-bloat >= N% (default 20).
#       --watch / --watch-quiet     : live progress for VACUUM/REINDEX
#       --exclude                   : skip tables by name or glob pattern (schema.table or unqualified)
#       --dry-run                   : plan only (no changes)

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Defaults & Globals ----------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_LOG_DIR="/var/isvd/data/logs/pgmaint_logger"
LOG_DIR="$DEFAULT_LOG_DIR"
LOGDIR_SPECIFIED=false
REQUIRE_LOG_DIR=false
LOG_FILE=""
WATCH=false
WATCH_QUIET=false
WATCH_INTERVAL=15

FULL=false                              # force VACUUM FULL
FULL_ON_BLOAT=false
BLOAT_THRESHOLD_PCT=20

ANALYZE=false
ANALYZE_ONLY=false

REINDEX=false
REINDEX_CONCURRENTLY=false
REINDEX_ON_BLOAT=false                                          # Reindex-on-bloat (auto-enables REINDEX)
REINDEX_BLOAT_PCT=20
REINDEX_MIN_INDEX_PAGES=${REINDEX_MIN_INDEX_PAGES:-8}           # skip tables whose largest index < 8 pages (64kB)
REINDEX_MIN_SAVED_PAGES=${REINDEX_MIN_SAVED_PAGES:-3}           # require at least 3 pages (24kB) of potential savings
REINDEX_TINY_INDEX_PAGES_MAX=${REINDEX_TINY_INDEX_PAGES_MAX:-2} # Treat indexes with total pages <= <int> as "tiny". Default: 2 (root + 1 leaf).
                                                                # Tiny indexes are treated as 0.00% bloat (and 0 saved pages).
REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE:-product}                 # from more to less aggresive damping ordedered 
                                                                # mode: power|product|min|division|max|none
                                                                # none will not adjust raw bloat_pct obtained without 'pgstattuple'
REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA:-2.0}                   # exponent for 'power' mode (>=1.0). 1.0 aggressiveness ≈ 'min'
                                                                # 2.0 aggressiveness ≈ 'product'. Grater than 2.0 aggressiveness > 'product'

DRY_RUN=false

# Script Identity
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.7"                  # Bump when you change behavior; semantic versioning recommended.
LAST_UPDATED="2025-10-06"               # Keep in sync with the header's Last Updated date.


# Autovacuum conflict management
AUTOVAC_POLICY="cancel"                 # wait|cancel|skip|ignore (default = cancel)
AUTOVAC_TIMEOUT=600                     # seconds
AUTOVAC_SHOW_SETTINGS=false             # show autovacuum settings/reloptions only when requested
declare -a AV_DISABLED_TABLES=()        # fq names we disabled temporarily
declare -a SKIPPED_BY_AUTOVAC=()        # fq names skipped due to policy=skip

# psql connection
PGHOST_OPT=${PGHOST:-"/run/postgresql"} # Directory for the Linux internal Domain Socket file used for Postgress
PGPORT_OPT=${PGPORT:-5432}
PGUSER_OPT=${PGUSER:-idsldap}           # if different can be supplied via -U
DBNAME="idsldap"                        # if different can be supplied via -d 

# selection
SCHEMAS=()
TABLES=()
EXCLUDES=()                             # patterns to exclude

# planning
TO_FULL=()                              # tables to FULL VACUUM
TO_VAC=()                               # tables to VACUUM
TO_REIN=()                              # tables to REINDEX (schema<NL>table)

# psql defaults
PSQL_BASE_OPTS=(-v ON_ERROR_STOP=1 -X -q)

# ---------- Helpers Functions ----------
usage() {
  cat <<EOF
Usage:
  $(basename "$0") -d <database> -U <user> [options]

Connection:
  -d <database>                     Target database name (or connection string, default to 'idsldap' if omitted)
  -U <user>                         PostgreSQL user (default to the value of env variable PGUSER, or 'idsldap' if not set)
  -h <host>                         Host (default to the value of env variable PGHOST, or '/run/postgresql' if not set)
  -p <port>                         Port (default to the value of env variable PGPORT, or '5432' if not set)

Selection:
  -n <schema>[,schema...]           Process only these schema(s) (repeatable)
  -t <table>[,table...]             Process only these table(s) (schema-qualified or unqualified; if unqualified, used with -n)
  --exclude <table>[,table...]      Exclude table(s) by name or pattern (*, ?). Accepts schema-qualified (schema.table) or unqualified.
                                    Can be repeated.

Vacuum/Analyze:
  --full                            Force VACUUM FULL for all targeted tables
  --full-only-on-bloat[=<pct>]      VACUUM FULL only if bloat >= <pct> (default 20 if omitted)
  --analyze                         Run ANALYZE after vacuum
  --analyze-only                    Only ANALYZE (skip VACUUM)

REINDEX:
  --reindex                         Run REINDEX after vacuum/analyze (or with --analyze-only)
  --reindex-concurrently            Use REINDEX CONCURRENTLY (lower locking, longer runtime)
  --reindex-only-on-bloat[=<pct>]   Auto-enables reindexing; per-table REINDEX only when BTREE index
                                    bloat >= <pct> (default: 20). Uses pgstatindex() if pgstattuple is
                                    available; else a catalog-based fallback estimator (no extensions).

Progress:
  --watch                           Show live progress for VACUUM and REINDEX
  --watch-quiet                     Concise progress (implies --watch)
  --watch-interval <sec>            Poll interval (default: 15)

Logging:
  -l <dir>, --log-dir <dir>
                                    Log directory (default: ${DEFAULT_LOG_DIR})
  --require-log-dir                 Fail hard ONLY if both the provided --log-dir (if any) and
                                    the default dir are unusable (no fallback to stdout-only)  

Autovacuum:
 --autovacuum-conflict {wait|cancel|skip|ignore}
                                    How to handle active autovacuum on target tables (default: cancel)
 --autovacuum-timeout <sec>         Max time to wait for workers to stop; with policy=cancel, escalates
                                    to pg_terminate_backend() after timeout (default: 600)
 --autovacuum-show-settings         Show autovacuum GUCs and per-table reloptions during pre-check only

Planning:
  --dry-run                         Preview actions ONLY (no changes). Still connects read-only to enumerate/estimate.

Other:
  -V, --version                     Print script version and last updated date, then exit
  -H, --help                        Show this help

Notes:
  - Schema/table discovery uses information_schema.tables but excludes system schemas by default; you can scope via -n/-t when needed.
  - If neither -n nor -t is provided, all user schemas/tables are processed (excluding pg_catalog, information_schema, pg_toast%).
  - VACUUM is online; VACUUM FULL rewrites tables and requires ACCESS EXCLUSIVE lock; the script ensures exclusivity safely.
  - If --autovacuum-conflict=ignore is set, no autovacuum conflict pre-check runs and no per-table detection is performed.
  - Autovacuum Conflict Pre-check: temporarily disables autovacuum per-target TABLES to avoid new workers (restored at end).
  - REINDEX execution is per-table only:
     * If --reindex-only-on-bloat is used -> always plan per-table REINDEX by threshold.
     * Else if --reindex/--reindex-concurrently is used -> plan REINDEX only when -t is provided.
EOF
}
log()   { echo "[$(date +'%F %T')] $*" | tee -a "${LOG_FILE:-/dev/null}"; }
die()   { log "ERROR: $*" >&2; exit 1; }
normalize() { echo "$1" | sed 's/^ *//; s/ *$//'; }
need_psql() { command -v psql >/dev/null 2>&1 || die "psql not found in PATH"; }
psql_args() {
  local -a args=("${PSQL_BASE_OPTS[@]}")
  [[ -n "$PGHOST_OPT" ]] && args+=(-h "$PGHOST_OPT")
  [[ -n "$PGPORT_OPT" ]] && args+=(-p "$PGPORT_OPT")
  [[ -n "$PGUSER_OPT" ]] && args+=(-U "$PGUSER_OPT")
  printf '%s\n' "${args[@]}"
}
# Function that populates an array passed by name
#psql_args() {
#  local -n args="$1" # Use nameref to directly reference the array
#  args=("${PSQL_BASE_OPTS[@]}")
#  [[ -n "$PGHOST_OPT" ]] && args+=(-h "$PGHOST_OPT")
#  [[ -n "$PGPORT_OPT" ]] && args+=(-p "$PGPORT_OPT")
#  [[ -n "$PGUSER_OPT" ]] && args+=(-U "$PGUSER_OPT")
#}
psql_q() { psql $(psql_args) -d "$DBNAME" -Atqc "$1"; }
psql_c() { psql $(psql_args) -d "$DBNAME" -qc   "$1"; }
# Function that uses the array correctly and returns exit code
#psql_c() {
#  local cmd="$1"
#  local -a psql_command_args
#  psql_args psql_command_args # Call the function and pass array name
#
#  # Run the psql command with correct array expansion
#  psql "${psql_command_args[@]}" -d "$DBNAME" -qc "$cmd" || true
#  return $?
#}
# helper to calculate the total execution time
total_exec_time() {
  total_exe_time=$((ftime - itime))
  if [ $total_exe_time -ge 86400 ] ; then
    ((days=$total_exe_time / 86400))
    human_exe_time=$days-$(date -d "@$total_exe_time" -u +%T)
  else
    human_exe_time=`date -d "@$total_exe_time" -u +%T`
  fi
}
# helper to print last messages before exit
final_messages() {
  # Get the total execution time
  finish_time=$(date +'%F %T')
  ftime=`date -d "$finish_time" +%s`
  total_exec_time  
  
  # Print total time
  echo "Total execution time: $total_exe_time seconds : $human_exe_time" 
  if [[ ${#TO_FULL[@]} -gt 0 ]]; then
    echo "After VACUUM FULL using the pg maintenance script it is recommended to restart the container."
  fi
  echo -e "Log saved to: ${LOG_FILE}\n"
}
# Helper: membership check
is_in_to_rein() {
  local s t st sch="$1" tab="$2"  
  for st in "${TO_REIN[@]}"; do
    s="${st%%|*}"; t="${st#*|}"
    [[ "$s" == "$sch" && "$t" == "$tab" ]] && return 0
  done
  return 1
}
# Escape single quotes in SQL string literals (safe for '...' usage)
sql_quote_lit() {
  # prints the input with single quotes doubled per SQL standard
  printf "%s" "$1" | sed "s/'/''/g"
}
# helper to count active pids
count_active_pids() {
  local pids_sql="$1"
  psql_q "$pids_sql" | wc -l | tr -d ' '
}
cancel_pids() {
  local pids_sql="$1"
  psql_c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid IN ($pids_sql);"
}
terminate_pids() {
  local pids_sql="$1"
  psql_c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid IN ($pids_sql);"
}
# Placeholder cleanup; exclusive mode restores connections within its block
# redefined later to include autovacuum restoration.
cleanup() { :; }
trap cleanup EXIT
trap 'rc=$?; printf "[%(%F %T)T] ERROR: Aborted (rc=%s) at line %s\n" -1 "$rc" "$LINENO" | tee -a "${LOG_FILE:-/dev/null}"; exit "$rc"' ERR
trap 'printf "[%(%F %T)T] Received signal, exiting...\n" -1 | tee -a "${LOG_FILE:-/dev/null}"; exit 130' INT TERM

# ---------- Parse CLI ----------
# Step 1: Verify 'psql' can be run and process user's options.
# 
need_psql
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) [[ $# -ge 2 ]] || { usage; exit 64; }; DBNAME="$2"; shift 2 ;;
    -U) [[ $# -ge 2 ]] || { usage; exit 64; }; PGUSER_OPT="$2"; shift 2 ;;
    -h) [[ $# -ge 2 ]] || { usage; exit 64; }; PGHOST_OPT="$2"; shift 2 ;;
    -p) [[ $# -ge 2 ]] || { usage; exit 64; }; PGPORT_OPT="$2"; shift 2 ;;
    -n) [[ $# -ge 2 ]] || { usage; exit 64; }; IFS=',' read -r -a arr <<<"$2"; SCHEMAS+=("${arr[@]}"); shift 2 ;;
    -t) [[ $# -ge 2 ]] || { usage; exit 64; }; IFS=',' read -r -a arr <<<"$2"; TABLES+=("${arr[@]}"); shift 2 ;;
    --full) FULL=true; shift ;;
    --full-only-on-bloat|--full-only-on-bloat=*)
      FULL_ON_BLOAT=true
      if [[ "$1" == *=* ]]; then BLOAT_THRESHOLD_PCT="${1#*=}"; else
        if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then BLOAT_THRESHOLD_PCT="$2"; shift; fi
      fi
      shift ;;
    --analyze) ANALYZE=true; shift ;;
    --analyze-only) ANALYZE_ONLY=true; shift ;;
    --reindex) REINDEX=true; shift ;;
    --reindex-concurrently) REINDEX=true; REINDEX_CONCURRENTLY=true; shift ;;
    --reindex-only-on-bloat|--reindex-only-on-bloat=*) REINDEX=true; REINDEX_ON_BLOAT=true; 
      if [[ "$1" == *=* ]]; then REINDEX_BLOAT_PCT="${1#*=}"; else
        if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then REINDEX_BLOAT_PCT="$2"; shift; fi
      fi
      shift ;;
    --watch) WATCH=true; shift ;;
    --watch-quiet) WATCH=true; WATCH_QUIET=true; shift ;;
    --watch-interval) [[ $# -ge 2 ]] || { usage; exit 64; }; WATCH_INTERVAL="$2"; [[ "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] || die "--watch-interval must be integer"; shift 2 ;;
    -l) [[ $# -ge 2 ]] || { usage; exit 64; }; LOG_DIR="$2"; LOGDIR_SPECIFIED=true; shift 2 ;;
    --log-dir) [[ $# -ge 2 ]] || { usage; exit 64; }; LOG_DIR="$2"; LOGDIR_SPECIFIED=true; shift 2 ;;
    --log-dir=*) LOG_DIR="${1#*=}"; LOGDIR_SPECIFIED=true; shift ;;
    --require-log-dir) REQUIRE_LOG_DIR=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --exclude) [[ $# -ge 2 ]] || { usage; exit 64; }; IFS=',' read -r -a arr <<<"$2"; EXCLUDES+=("${arr[@]}"); shift 2 ;;
    --exclude=*) val="${1#*=}"; IFS=',' read -r -a arr <<<"$val"; EXCLUDES+=("${arr[@]}"); shift ;;
    --autovacuum-conflict) [[ $# -ge 2 ]] || { usage; exit 64; }
      case "$2" in wait|cancel|skip|ignore) AUTOVAC_POLICY="$2"; shift 2 ;;
      *) die "--autovacuum-conflict must be one of: wait, cancel, skip, ignore";;
      esac ;;
    --autovacuum-timeout) [[ $# -ge 2 ]] || { usage; exit 64; }
      AUTOVAC_TIMEOUT="$2"; [[ "$AUTOVAC_TIMEOUT" =~ ^[0-9]+$ ]] || die "--autovacuum-timeout must be integer"; shift 2 ;;
    --autovacuum-show-settings) AUTOVAC_SHOW_SETTINGS=true; shift ;;
    -V|--version) echo "${SCRIPT_NAME} Version: ${SCRIPT_VERSION} (Last Updated: ${LAST_UPDATED})"; exit 0 ;;
    -H|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage; exit 64 ;;
    *)  usage; exit 64 ;;
  esac
done

[[ -n "$DBNAME"     ]] || { usage; die "missing -d <database>"; }
[[ -n "$PGUSER_OPT" ]] || { usage; die "missing -U <user>"; }

# ---------- Initialize logging with fallback policy ----------
init_logging() {
  local requested_dir="$LOG_DIR"
  local default_dir="$DEFAULT_LOG_DIR"
  local try_dir=""

  ensure_dir_writable() {
    local d="$1"
    mkdir -p "$d" 2>/dev/null || return 1
    [[ -w "$d" ]] || return 1
    return 0
  }

  # Helper: finalize to a directory (create a file) or return failure
  finalize_dir() {
    local d="$1"
    LOG_FILE="${d}/pgmaint_${DBNAME}_${TIMESTAMP}.log"
    : > "$LOG_FILE" 2>/dev/null || return 1
    LOG_DIR="$d"
    return 0
  }

  # Case A: user provided a log dir
  if [[ "$LOGDIR_SPECIFIED" == "true" ]]; then
    try_dir="$requested_dir"
    if ensure_dir_writable "$try_dir" && finalize_dir "$try_dir"; then
      return 0
    fi
    # Provided dir unusable -> warn and attempt default (even with --require-log-dir)
    echo "WARN: Provided --log-dir '$requested_dir' unusable; trying default '$default_dir'." >&2
    try_dir="$default_dir"
    if ensure_dir_writable "$try_dir" && finalize_dir "$try_dir"; then
      return 0
    fi
    # Both provided and default unusable
    if [[ "$REQUIRE_LOG_DIR" == "true" ]]; then
      echo "ERROR: Neither provided --log-dir ('$requested_dir') nor default ('$default_dir') is usable and --require-log-dir is set." >&2
      exit 5
    fi
    echo "WARN: Default log dir '$default_dir' unusable; logging to stdout only." >&2
    LOG_FILE="/dev/null"; LOG_DIR="$default_dir"
    return 0
  fi

  # Case B: no dir provided -> try default
  try_dir="$default_dir"
  if ensure_dir_writable "$try_dir" && finalize_dir "$try_dir"; then
    return 0
  fi
  # Default unusable
  if [[ "$REQUIRE_LOG_DIR" == "true" ]]; then
    echo "ERROR: Default log dir '$default_dir' is unusable and --require-log-dir is set." >&2
    exit 5
  fi
  echo "WARN: Default log dir '$default_dir' unusable; logging to stdout only." >&2
  LOG_FILE="/dev/null"; LOG_DIR="$default_dir"
  return 0
}

#
# Step 2: Initialize logging considering user's options.
#
init_logging

init_time=$(date +'%F %T')
itime=`date -d "$init_time" +%s`

log "Script: ${SCRIPT_NAME} v${SCRIPT_VERSION}"
log "Starting maintenance for DB='${DBNAME}' user='${PGUSER_OPT}' host='${PGHOST_OPT}' port='${PGPORT_OPT}'"
log "Options: FULL=${FULL} FULL_ON_BLOAT=${FULL_ON_BLOAT}[=${BLOAT_THRESHOLD_PCT}%] ANALYZE=${ANALYZE} ANALYZE_ONLY=${ANALYZE_ONLY} REINDEX=${REINDEX} RC=${REINDEX_CONCURRENTLY} REINDEX_ON_BLOAT=${REINDEX_ON_BLOAT}[=${REINDEX_BLOAT_PCT}%] DRY_RUN=${DRY_RUN}"
log "Watch=${WATCH} Quiet=${WATCH_QUIET} Interval=${WATCH_INTERVAL}s REQUIRE_LOG_DIR=${REQUIRE_LOG_DIR} Log=${LOG_FILE}"
log "Autovacuum: policy=${AUTOVAC_POLICY} timeout=${AUTOVAC_TIMEOUT}s show_settings=${AUTOVAC_SHOW_SETTINGS}"


# ---------- Connectivity check ----------
# Step 3: Try to connect to the database.
#
log "Connecting..."
psql_q "SELECT current_database()" >/dev/null || die "Unable to connect to database '${DBNAME}'"

# ---------- Build target table list ----------
# Step 4: Build target table list from the user's options.
#
declare -A SCHEMA_SET=()
if [[ ${#SCHEMAS[@]} -gt 0 ]]; then
  for s in "${SCHEMAS[@]}"; do
    s="$(normalize "$s" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$s" ]] && SCHEMA_SET["$s"]=1
  done
else
  while IFS= read -r s; do SCHEMA_SET["$s"]=1; done < <(
    psql_q "SELECT nspname FROM pg_namespace
            WHERE nspname NOT IN ('pg_catalog','information_schema')
              AND nspname NOT LIKE 'pg_toast%';"
  )
fi

TARGETS=()   # schema|table entries
if [[ ${#TABLES[@]} -gt 0 ]]; then
  for t in "${TABLES[@]}"; do
    t="$(normalize "$t")"
    if [[ "$t" == *.* ]]; then
      sch="${t%%.*}"; tab="${t#*.}"
      TARGETS+=("$(echo "$sch" | tr '[:upper:]' '[:lower:]')|$(echo "$tab" | tr '[:upper:]' '[:lower:]')")
    else
      [[ ${#SCHEMA_SET[@]} -gt 0 ]] || die "Unqualified table '${t}' used without -n schema list."
      tab="$(echo "$t" | tr '[:upper:]' '[:lower:]')"
      for sch in "${!SCHEMA_SET[@]}"; do TARGETS+=("${sch}|${tab}"); done
    fi
  done
else
  for sch in "${!SCHEMA_SET[@]}"; do
    while IFS= read -r tab; do TARGETS+=("${sch}|${tab}"); done < <(
      psql_q "SELECT table_name FROM information_schema.tables
              WHERE table_schema='${sch}' AND table_type='BASE TABLE'
              ORDER BY table_name;"
    )
  done
fi

[[ ${#TARGETS[@]} -gt 0 ]] || die "No tables found for selection."
log "Planned tables (pre-exclude): ${#TARGETS[@]}"

# ---------- Apply --exclude filters ----------
excluded() {
  local sch="$1" tab="$2" pat lcpat want
  for pat in "${EXCLUDES[@]}"; do
    lcpat="$(echo "$pat" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')"
    if [[ "$lcpat" == *.* ]]; then
      want="${sch}.${tab}"
      if [[ "$want" == $lcpat ]]; then return 0; fi
    else
      if [[ "$tab" == $lcpat ]]; then return 0; fi
    fi
  done
  return 1
}

#
# Step 5: Apply --exclude filters provide by user.
#
if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
  FILTERED=(); excl_count=0
  for st in "${TARGETS[@]}"; do
    sch="${st%%|*}"; tab="${st#*|}"
    if excluded "$sch" "$tab"; then
      ((excl_count+=1))
      log "Excluded by --exclude: ${sch}.${tab}"
      continue
    fi
    FILTERED+=("$st")
  done
  TARGETS=("${FILTERED[@]}")
  [[ ${#TARGETS[@]} -gt 0 ]] || die "No tables remain after applying --exclude."
  log "After --exclude: ${#TARGETS[@]} table(s) remain (excluded ${excl_count})."
fi

# ---------- Progress watchers ----------
watch_vacuum() {
  local schema="$1" table="$2"
  while true; do
    local ts="[$(date +'%F %T')]"
    if [[ "$WATCH_QUIET" == "true" ]]; then
      echo "${ts} --- VACUUM progress for ${schema}.${table} ---" 2>&1 >> "$LOG_FILE"
      psql_q "SELECT '${ts} VACUUM ${schema}.${table}: phase='||phase ||'; scanned='||heap_blks_scanned||'/'||heap_blks_total||'; vacuumed='||heap_blks_vacuumed
            FROM pg_stat_progress_vacuum
            WHERE relid = (quote_ident('${schema}')||'.'||quote_ident('${table}'))::regclass" | tee -a "$LOG_FILE" 
    else
      echo "${ts} --- VACUUM progress for ${schema}.${table} ---" | tee -a "$LOG_FILE"
      psql_c "SELECT * FROM pg_stat_progress_vacuum
            WHERE relid = (quote_ident('${schema}')||'.'||quote_ident('${table}'))::regclass" | tee -a "$LOG_FILE"
    fi
    sleep "$WATCH_INTERVAL"
  done
}

watch_reindex() {
  local schema="$1" table="$2"
  while true; do
    local ts="[$(date +'%F %T')]"
    if [[ "$WATCH_QUIET" == "true" ]]; then
      echo "${ts} --- REINDEX progress for ${schema}.${table} ---" 2>&1 >> "$LOG_FILE"
      psql_q "SELECT '${ts} PROGRESS of '||command||' on '||relid::regclass||
                   ': phase='||phase||'; blocks='||blocks_done||'/'||blocks_total||
                   CASE WHEN tuples_total>0 THEN '; tuples='||tuples_done||'/'||tuples_total ELSE '' END
            FROM pg_stat_progress_create_index
            WHERE relid = (quote_ident('${schema}')||'.'||quote_ident('${table}'))::regclass" | tee -a "$LOG_FILE"
    else
      echo "${ts} --- REINDEX progress for ${schema}.${table} ---" | tee -a "$LOG_FILE"
      psql_c "SELECT * FROM pg_stat_progress_create_index
            WHERE relid = (quote_ident('${schema}')||'.'||quote_ident('${table}'))::regclass" | tee -a "$LOG_FILE"
    fi
    sleep "$WATCH_INTERVAL"
  done
}

watch_dat_reindex() {
  local filter="$1"
  while true; do
    local ts="[$(date +'%F %T')]"
    if [[ "$WATCH_QUIET" == "true" ]]; then
      psql_q "SELECT '${ts} PROGRESS of '||command||' on '||relid::regclass||
                   ': phase='||phase||'; blocks='||blocks_done||'/'||blocks_total||
                   CASE WHEN tuples_total>0 THEN '; tuples='||tuples_done||'/'||tuples_total ELSE '' END
            FROM pg_stat_progress_create_index
            WHERE ${filter}" | tee -a "$LOG_FILE"
    else
      echo "${ts} --- REINDEX progress ---" | tee -a "$LOG_FILE"
      psql_c "SELECT * FROM pg_stat_progress_create_index WHERE ${filter};"
    fi
    sleep "$WATCH_INTERVAL"
  done
 }
 
#
# Step 6: Check the presence of pgstattuple extension in the database.
#
have_pgstattuple=$(psql_q "SELECT 1 FROM pg_extension WHERE extname='pgstattuple' LIMIT 1;" || true)

# ---------- Index bloat estimation (accurate + fallback) ----------
# Adjust raw index bloat pct by REINDEX_MIN_INDEX_PAGES and REINDEX_MIN_SAVED_PAGES.
# Input:  $1 = schema, $1 = table
#         $3 = raw pct string like "50.00" (no trailing %)
#         $4 = max pages   : largest b-tree index page count on the table
#         $5 = saved pages : estimated max pages saved on the table
# Output: writes adjusted pct (two decimals) to stdout, e.g., "12.50"
index_bloat_pct_adjusted_for_size() {
  local sch="$1" tab="$2" raw_pct="$3" max_pages="$4" max_saved="$5"
  local factor factor_size factor_saved tiny_guard adj_pct
  
  # Set default value = 1.0 (no damping) to factors from gates 
  factor_size=1.0       #fraction toward REINDEX_MIN_INDEX_PAGES (0..1)
  factor_saved=1.0      #fraction toward REINDEX_MIN_SAVED_PAGES (0..1)     

  # If gates are > 0, compute fractional progress toward meeting them.
  # Example: max_pages=4, REINDEX_MIN_INDEX_PAGES=8 -> factor_size=0.5
  [[ "$REINDEX_MIN_INDEX_PAGES" =~ ^[0-9]+$ ]] || die "REINDEX_MIN_INDEX_PAGES must be integer"
  if [[ "${REINDEX_MIN_INDEX_PAGES}" -gt 0 ]]; then
    factor_size="$(awk -v m="${max_pages:-0}" -v req="${REINDEX_MIN_INDEX_PAGES}" \
      'BEGIN{ if(req<=0){print 1}else{f=m/req; if(f<0)f=0; if(f>1)f=1; printf("%.6f", f)} }')"
  fi
  # Compute saved factor (progress toward min saved pages gate)
  [[ "$REINDEX_MIN_SAVED_PAGES" =~ ^[0-9]+$ ]] || die "REINDEX_MIN_SAVED_PAGES must be integer"
  if [[ "${REINDEX_MIN_SAVED_PAGES}" -gt 0 ]]; then
    factor_saved="$(awk -v s="${max_saved:-0}" -v req="${REINDEX_MIN_SAVED_PAGES}" \
      'BEGIN{ if(req<=0){print 1}else{f=s/req; if(f<0)f=0; if(f>1)f=1; printf("%.6f", f)} }')"
  fi

  # Tiny-index guard: if the largest index is <= 2 pages, we consider reindex unhelpful.
  if [[ "${max_pages:-0}" -le 2 ]]; then
    tiny_guard=0
  else
    tiny_guard=1
  fi

  # Final damping factor we apply to raw pct,
  # obtained from ${factor_size}, ${factor_saved} & indicated mode in ${REINDEX_DAMP_MODE}; 
  # apply tiny guard.
  [[ "$REINDEX_DAMP_GAMMA" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA} must be a positive number"
  if awk "BEGIN{exit !($REINDEX_DAMP_GAMMA < 1)}" || awk "BEGIN{exit !($REINDEX_DAMP_GAMMA >= 10)}"; then
    die "REINDEX_DAMP_GAMMA must be a positive number equal to or greater than 1 and less than 10"
  fi
  factor="$(awk -v a="$factor_size" -v b="$factor_saved" -v tg="$tiny_guard" -v mode="$REINDEX_DAMP_MODE" -v g="${REINDEX_DAMP_GAMMA}" \
    'BEGIN{
      if(mode=="min")f=(a<b?a:b); else if(mode=="product")f=a*b; else if(mode=="max")f=(a>b?a:b)
      else if(mode=="division"){min=(a<b?a:b); max=(a>b?a:b); f=min/max}
      else if(mode=="power"){min=(a<b?a:b); f=(exp(g*log(min)))} else if(mode=="none")f=1.0
      else f=a*b; if(tg==0)f=0; if(f<0)f=0; if(f>1)f=1; printf("%.6f", f)}')"

  # Apply factor to the raw pct; format to 0.00.
  adj_pct="$(awk -v p="$(printf '%0.6f' "${raw_pct}")" -v f="$factor" \
      'BEGIN{printf("%.2f", p*f)}')"
  echo "${adj_pct}"
}
# Catalog-based fallback (no extensions required)
# Includes tiny-index guard and minimal-page clamp for realism
# Returns one line with: "<max_pct>|<max_index_pages>|<max_saved_pages>"
get_index_bloat_pct_fallback() {
  local sql stats sch="$1" tab="$2"
  local tiny=$REINDEX_TINY_INDEX_PAGES_MAX
  
  # Escape single quotes for SQL string literal safety
  #local schq="${sch//\'/\'\'}"
  #local tabq="${tab//\'/\'\'}"

  # Build SQL with embedded literals and quote_ident() to form identifiers safely
  sql="
WITH params AS (
  SELECT current_setting('block_size')::int AS bs, 24 AS page_header, 8 AS btree_special, 8 AS itup_hdr, 4 AS itemid
),
tbl AS (
  SELECT (quote_ident('${sch}')||'.'||quote_ident('${tab}'))::regclass AS tbl_oid, '${sch}'::text AS schema, '${tab}'::text AS table
),
base AS (
  SELECT t.tbl_oid, c_tab.reltuples::numeric AS table_reltuples
  FROM tbl t
  JOIN pg_class c_tab ON c_tab.oid = t.tbl_oid
),
idx AS (
  SELECT c.oid AS idx_oid, c.relname AS index_name, c.relpages::numeric AS pages, c.reloptions,
         i.indrelid AS tbl_oid, i.indkey, am.amname, n.nspname
  FROM pg_index i
  JOIN pg_class c     ON c.oid = i.indexrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_am am       ON am.oid = c.relam
  JOIN tbl t          ON t.tbl_oid = i.indrelid
  WHERE am.amname = 'btree'
),
keycols AS (
  SELECT i.idx_oid, unnest(i.indkey) AS attnum FROM idx i
),
keys_named AS (
  SELECT k.idx_oid, k.attnum, CASE WHEN k.attnum > 0 THEN a.attname ELSE NULL END AS attname
  FROM keycols k
  LEFT JOIN pg_attribute a
    ON a.attrelid = (SELECT tbl_oid FROM idx x WHERE x.idx_oid = k.idx_oid LIMIT 1)
   AND a.attnum = k.attnum
),
col_widths AS (
  SELECT kn.idx_oid,
         COALESCE((
           SELECT s.avg_width::numeric
             FROM idx x
             JOIN base b ON b.tbl_oid = x.tbl_oid JOIN pg_stats s ON s.schemaname = x.nspname
                             AND s.tablename  = (SELECT relname FROM pg_class t WHERE t.oid = x.tbl_oid)
                             AND s.attname    = kn.attname
            WHERE x.idx_oid = kn.idx_oid LIMIT 1
         ), 16::numeric) AS avg_width
  FROM keys_named kn
),
itup AS (
  SELECT i.idx_oid,
         GREATEST((SELECT itup_hdr FROM params) + COALESCE(SUM(cw.avg_width),0)::numeric, 24::numeric) AS itup_size
  FROM idx i LEFT JOIN col_widths cw ON cw.idx_oid = i.idx_oid
  GROUP BY i.idx_oid
),
calc AS (
  SELECT i.index_name, i.pages, b.table_reltuples AS tuples,
         COALESCE((
           SELECT (regexp_matches(unnest(i.reloptions), '^fillfactor=(\d+)$'))[1]::int
           FROM unnest(COALESCE(i.reloptions, '{}'::text[]))
           WHERE unnest LIKE 'fillfactor=%' LIMIT 1
         ), 90) AS fillfactor,
         it.itup_size,
         (SELECT bs - page_header - btree_special FROM params) AS usable,
         (SELECT itemid FROM params) AS lp
  FROM idx i JOIN itup it ON it.idx_oid = i.idx_oid
             JOIN base b  ON b.tbl_oid  = i.tbl_oid
),
expected AS (
  SELECT index_name, pages, tuples, fillfactor, itup_size, usable, lp,
         GREATEST(1::numeric, FLOOR((usable * (fillfactor/100.0)) / (itup_size + lp))) AS cap_tpp
  FROM calc
),
expected_pages AS (
  SELECT index_name, pages,
         CASE WHEN tuples <= 0 THEN 0::numeric ELSE CEIL(tuples / cap_tpp) END AS exp_pages_raw
  FROM expected
),
detail_bloat AS (
  SELECT index_name, pages::int,
         GREATEST(exp_pages_raw, 2)::int AS exp_pages,         -- minimum structure (root + 1 leaf)
         CASE WHEN pages <= ${tiny} THEN 0::numeric(10,2)      -- tiny-index guard: treat as not bloated
              ELSE GREATEST(0, (1 - GREATEST(exp_pages_raw,2) / NULLIF(pages,0)) * 100.0)::numeric(10,2)
          END AS bloat_pct,
         CASE WHEN pages <= ${tiny} THEN 0 
              ELSE GREATEST(pages - GREATEST(exp_pages_raw,2), 0)::int
          END AS saved_pages
  FROM expected_pages
)
SELECT bloat_pct::text || '|' || pages::text || '|' || saved_pages::text
FROM detail_bloat
ORDER BY bloat_pct DESC, pages DESC
LIMIT 1;
"

  stats="$(psql_q "$sql" | tr -d '\r')"
  echo "${stats}"
}
# Accurate when pgstattuple is installed; falls back 
get_index_bloat_pct() {
  local sql pct sch="$1" tab="$2"
  local tiny=${tiny_index_leaf_pages:-1}
  local span=${small_tree_smooth_span:-2}

  # Escape for SQL string literal
  #local schq tabq
  #schq="$(sql_quote_lit "$sch")"
  #tabq="$(sql_quote_lit "$tab")"
    
  sql="
WITH idx AS (
  SELECT c.oid AS index_oid, c.reloptions
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indexrelid
  JOIN pg_am   am ON am.oid = c.relam
  WHERE am.amname = 'btree'
    AND i.indrelid = (quote_ident('${sch}')||'.'||quote_ident('${tab}'))::regclass
),
s AS (
  SELECT
    st.leaf_pages,
    CASE
      WHEN st.avg_leaf_density > 1 THEN st.avg_leaf_density / 100.0
      ELSE st.avg_leaf_density
    END AS dens01,
    COALESCE((
      SELECT (regexp_matches(unnest(idx.reloptions), '^fillfactor=(\d+)'))[1]::int
      FROM unnest(COALESCE(idx.reloptions, '{}'::text[]))
      WHERE unnest LIKE 'fillfactor=%' LIMIT 1
    ), 90) AS fillfactor
  FROM idx
  CROSS JOIN LATERAL pgstatindex(index_oid::regclass) AS st
),
calc AS (
  SELECT
    leaf_pages,
    GREATEST(0.0, ((1.0 - dens01) * 100.0) - (100.0 - fillfactor)) AS raw_excess,
    ${tiny}::int    AS tiny_max,
    ${span}::int    AS smooth_span
  FROM s
),
weighted_bloat AS (
  SELECT
    CASE
      WHEN leaf_pages <= tiny_max THEN 0.0
      WHEN smooth_span <= 0       THEN raw_excess
      ELSE raw_excess * LEAST(1.0, (leaf_pages - tiny_max)::numeric / smooth_span::numeric)
    END AS bloat_pct
  FROM calc
)
SELECT to_char(COALESCE(MAX(bloat_pct), 0), 'FM999999990.00')
FROM weighted_bloat;
"

  pct="$(psql_q "$sql" | tr -d '[:space:]')"
  echo "${pct:-0}"
}

# ---------- Table bloat estimation helpers (for FULL-on-bloat) ----------
bloat_pct_sql_pgstattuple() {
  local sch="$1" tab="$2"
  cat <<SQL
SELECT to_char(
  COALESCE((pgstattuple_approx(quote_ident('${sch}')||'.'||quote_ident('${tab}'))).dead_tuple_percent, 0), 'FM999999990.00');
SQL
}
bloat_pct_sql_fallback() {
  local sch="$1" tab="$2"
  cat <<SQL
WITH s AS (
  SELECT COALESCE(NULLIF(c.reltuples,0),1)::numeric AS reltuples,
         COALESCE(t.n_dead_tup,0)::numeric AS n_dead
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_stat_all_tables t ON t.relid = c.oid
  WHERE n.nspname='${sch}' AND c.relname='${tab}' AND c.relkind='r'
)
SELECT CASE WHEN reltuples=0 THEN 0 ELSE round(100*n_dead/reltuples,2) END FROM s;
SQL
}
get_bloat_pct() {
  local q pct sch="$1" tab="$2"
  if [[ "$have_pgstattuple" == "1" ]]; then
    q="$(bloat_pct_sql_pgstattuple "$sch" "$tab")"
  else 
    q="$(bloat_pct_sql_fallback "$sch" "$tab")"
  fi
  pct="$(psql_q "$q" | head -n1 | tr -d ' ')"
  echo "${pct:-0}"
}

# ---------- VACUUM FULL exclusive mode ----------
run_full_block_and_exec() {
  local sql_body="$1"

  log "Entering exclusive mode for VACUUM FULL tasks..."

  # --- PROLOGUE: Block re-connections and terminate others (keep this session) ---
  if ! psql $(psql_args) -d "$DBNAME" -v ON_ERROR_STOP=1 <<'SQL_PROLOGUE'
SET application_name='idspgmaint(full)';
DO $$
DECLARE mypid int := pg_backend_pid();
BEGIN
  -- Block most new connections while we work --
  EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('ALTER DATABASE %I WITH CONNECTION LIMIT 1', current_database());

  -- Terminate all other sessions --
  PERFORM pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = current_database()
    AND pid <> mypid;
END $$;
SQL_PROLOGUE
  then
    log "ERROR: Failed to enter exclusive mode (prologue)."
    return 1
  fi

  # ---------- BODY: run each statement separately (no txn block) ----------
  # IMPORTANT: Feeding the body via stdin lets psql process each statement
  # in autocommit mode. That avoids "VACUUM cannot run inside a transaction block".
  psql $(psql_args) -d "$DBNAME" -v ON_ERROR_STOP=1 <<SQL_BODY
-- BEGIN FULL TASKS --
$sql_body
-- END FULL TASKS --
SQL_BODY
  local body_rc=$?
  if [[ $body_rc -ne 0 ]]; then
    log "ERROR: One or more FULL tasks failed (rc=$body_rc); attempting to restore access..."
  fi

  # ---------- EPILOGUE: restore connectivity ----------
  if ! psql $(psql_args) -d "$DBNAME" -v ON_ERROR_STOP=1 <<'SQL_EPILOGUE'
DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I WITH CONNECTION LIMIT -1', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO PUBLIC', current_database());
END $$;
SQL_EPILOGUE
  then
    log "WARN: Failed to restore CONNECT/CONNECTION LIMIT; run manually:"
    log "  GRANT CONNECT ON DATABASE \"$DBNAME\" TO PUBLIC;"
    log "  ALTER DATABASE \"$DBNAME\" WITH CONNECTION LIMIT -1;"
  else
    log "Access restored; connections re-enabled."
  fi

  if [[ $body_rc -ne 0 ]]; then
    return $body_rc
  fi 

  log "Exclusive mode complete; connections re-enabled."
}

# -------------------- Autovacuum helpers --------------------
# Optional show cluster/session autovacuum settings when requested
show_autovacuum_settings() {
  log "Autovacuum GUCs (effective in this session):"
  psql_c "SELECT name, setting, unit
            FROM pg_settings
           WHERE name IN (
             'autovacuum','autovacuum_naptime',
             'autovacuum_vacuum_threshold','autovacuum_vacuum_scale_factor',
             'autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay',
             'autovacuum_max_workers'
           )
           ORDER BY name;" || true
}


# Optional show per-table reloptions affecting autovacuum
show_target_reloptions() {
  log "Per-table reloptions on targets (if any):"
  for st in "${TARGETS[@]}"; do
    local sch="${st%%|*}" tab="${st#*|}"
    psql_c "SELECT n.nspname AS schema, c.relname AS table,
                COALESCE(array_to_string(c.reloptions, ', '), 'autovacuum_enabled=NULL') AS reloptions
             FROM pg_class c
             JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE c.relkind = 'r' -- Filter for tables only
                AND n.nspname='${sch}' AND c.relname='${tab}';" || true
  done
}

# Disable autovacuum per table (restored by av_restore_on_exit)
av_disable_table_autovac() {
  local sch="$1" tab="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN plan: would ALTER TABLE ${sch}.\"${tab}\" SET (autovacuum_enabled=false);"
  else
    log "Temporarily disabling autovacuum on ${sch}.${tab}"
    if psql_c "ALTER TABLE ${sch}.\"${tab}\" SET (autovacuum_enabled=false);"; then
      AV_DISABLED_TABLES+=("${sch}.${tab}")
    else
      log "WARN: could not disable autovacuum on ${sch}.${tab}"
    fi
  fi
}

# Restore any changes made in autovacuum conflicts pre-check
av_restore_on_exit() {
  local fq sch tab ts="[$(date +'%F %T')]"
  echo "${ts} ========== AUTOVACUUM CONFLICTS POST-CHECK ==========" 2>&1 >> "$LOG_FILE"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    for st in "${TARGETS[@]}"; do
      sch="${st%%|*}"; tab="${st#*|}"; ts="[$(date +'%F %T')]"
      echo "${ts} DRY-RUN plan: would ALTER TABLE ${sch}.\"${tab}\" RESET (autovacuum_enabled);" 2>&1 >> "$LOG_FILE"
    done
  else
    for fq in "${AV_DISABLED_TABLES[@]}"; do
      sch="${fq%%.*}"; tab="${fq#*.}"; ts="[$(date +'%F %T')]"
      echo "${ts} Restoring autovacuum on ${sch}.${tab}" 2>&1 >> "$LOG_FILE"
      psql_c "ALTER TABLE ${sch}.\"${tab}\" RESET (autovacuum_enabled);" || \
    log "WARN: failed to restore autovacuum on ${sch}.${tab}"
    done
    AV_DISABLED_TABLES=()
  fi

  ts="[$(date +'%F %T')]"
  echo "${ts} ============ AV CONFLICTS POST-CHECK DONE ============" 2>&1 >> "$LOG_FILE"
}

# Autovacuum Conflicts Pre-check: 
#   1- optionally show settings 
#   2- temporarily disable autovacuum
av_precheck() {
  # Skip entirely if policy=ignore
  [[ "$AUTOVAC_POLICY" == "ignore" ]] && { log "Autovacuum pre-check skipped due to policy=ignore."; return 0; }

  log "========== AUTOVACUUM CONFLICTS PRE-CHECK =========="
  
  # Show autovacuum settings if requested
  if [[ "$AUTOVAC_SHOW_SETTINGS" == "true" ]]; then
    show_autovacuum_settings
    show_target_reloptions
  fi

  # Temporary disable autovacuum per table
  for st in "${TARGETS[@]}"; do
    local sch="${st%%|*}" tab="${st#*|}"
    av_disable_table_autovac "$sch" "$tab"
  done

  if [[ "$AUTOVAC_SHOW_SETTINGS" == "true" && "$DRY_RUN" != "true" ]]; then
    echo ""
    show_target_reloptions
  fi
  
  log "============ AV CONFLICTS PRE-CHECK DONE ============"
}

# Detect & resolve autovacuum conflicts for a single table.
# Returns:
#   0  -> proceed with this table
#   10 -> skip this table (policy=skip and autovacuum active)
av_detect_and_resolve_for_table() {
  local sch="$1" tab="$2"
  # If policy is ignore, the caller shouldn't have invoked us; but be forgiving.
  [[ "$AUTOVAC_POLICY" == "ignore" ]] && return 0

  local get_pids_sql="
    SELECT pr.pid::int
      FROM pg_stat_progress_vacuum pr
      JOIN pg_stat_activity sa   ON pr.pid = sa.pid
      JOIN pg_class c     ON c.oid = pr.relid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE sa.query LIKE 'autovacuum: %'
       AND n.nspname='${sch}' AND c.relname='${tab}';
  "

  # Fast check
  local active
  active="$(count_active_pids "$get_pids_sql")"
  if [[ "$active" -eq 0 ]]; then return 0; fi
  case "$AUTOVAC_POLICY" in
    wait)
      local start now elapsed
      start="$(date +%s)"
      while : ; do
        active="$(count_active_pids)"
        [[ "$active" -eq 0 ]] && return 0
        now="$(date +%s)"; elapsed=$((now - start))
        log "Waiting for autovacuum on ${sch}.${tab} (active=${active}, elapsed=${elapsed}s, timeout=${AUTOVAC_TIMEOUT}s)..."
        if (( elapsed >= AUTOVAC_TIMEOUT )); then
          log "WARN: Timeout reached; proceeding with ${sch}.${tab} while autovacuum may still be active."
          return 0
        fi
        sleep 2
      done
      ;;

    cancel)
      log "Requesting pg_cancel_backend() for autovacuum on ${sch}.${tab}"
      cancel_pids "$get_pids_sql" || true
      # wait up to timeout, then escalate
      local start now elapsed
      start="$(date +%s)"
      while : ; do
        active="$(count_active_pids)"
        [[ "$active" -eq 0 ]] && return 0
        now="$(date +%s)"; elapsed=$((now - start))
        if (( elapsed >= AUTOVAC_TIMEOUT )); then
          log "Escalating to pg_terminate_backend() for autovacuum on ${sch}.${tab}"
          terminate_pids "$get_pids_sql" || true
          # give a brief grace period
          sleep 2
          return 0
        fi
        sleep 2
      done
      ;;

    skip)
      # If active -> skip this table
      if [[ "$active" -gt 0 ]]; then
        log "Skipping ${sch}.${tab} due to active autovacuum (policy=skip)."
        SKIPPED_BY_AUTOVAC+=("${sch}.${tab}")
        return 10
      fi
      return 0
      ;;

    ignore) return 0 ;;

    *) log "WARN: Unknown autovacuum policy '${AUTOVAC_POLICY}' (proceeding)."; return 0 ;;
  esac
}

# Redefine cleanup to restore autovacuum toggles reliably
cleanup() { av_restore_on_exit; }
trap cleanup EXIT

# ---------- Execution planning ----------
# Step 7: Execution planning from the user's options.
#         Executes the bloat extimation helper, if selected,
#         and decides what form of maintenance will be executed
#         for each table.
#
# ----- FULLVAC planning -----
if [[ "$ANALYZE_ONLY" == "true" ]]; then
  log "ANALYZE-ONLY mode: will skip VACUUM/VACUUM FULL."
else
  if [[ "$FULL" == "true" ]]; then
    for st in "${TARGETS[@]}"; do
      sch="${st%%|*}"; tab="${st#*|}"
      TO_FULL+=("${sch}|${tab}")
    done
  else  
    if [[ "$FULL_ON_BLOAT" == "true" ]]; then
      if [[ "$have_pgstattuple" != "1" ]]; then
        log "WARN: 'pgstattuple' is not installed in '${DBNAME}'. Falling back to catalog-based estimators"
        log "To install 'pgstattuple' and improve accuracy run: \"CREATE EXTENSION pgstattuple;\" (requires superuser)"
      fi
      log "================= FULLVAC PLANNING ================="
      for st in "${TARGETS[@]}"; do
        sch="${st%%|*}"; tab="${st#*|}"
        pct="$(get_bloat_pct "$sch" "$tab")"
        pct_num=$(echo "$pct" | sed 's/[^0-9.]//g')
        if awk "BEGIN{exit !($pct_num >= $BLOAT_THRESHOLD_PCT)}"; then
          TO_FULL+=("${sch}|${tab}")
          log "FULLVAC plan: ${sch}.${tab} (table bloat estimate ≈ ${pct_num}%>= ${BLOAT_THRESHOLD_PCT}%)   -> FULLVAC"
        else
          TO_VAC+=("${sch}|${tab}")
          log "FULLVAC plan: ${sch}.${tab} (table bloat estimate ≈ ${pct_num}% < ${BLOAT_THRESHOLD_PCT}%)   -> NO_FULL"
        fi
      done
      log "================= FULLVAC PLAN DONE ================="
    else
      for st in "${TARGETS[@]}"; do
        sch="${st%%|*}"; tab="${st#*|}"
        TO_VAC+=("${sch}|${tab}")
      done
    fi
  fi
fi
# ----- REINDEX planning -----
if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
  # Warn the user pgstattuple is not present in the database
  if [[ "$FULL_ON_BLOAT" != "true" && "$have_pgstattuple" != "1" ]]; then
    log "WARN: 'pgstattuple' is not installed in '${DBNAME}'. Falling back to catalog-based estimators."
    log "To install 'pgstattuple' and improve accuracy run: \"CREATE EXTENSION pgstattuple SCHEMA public;\" (requires superuser)."
  fi
  
  log "================= REINDEX PLANNING ================="
  
  # Print Adjust Bloat information depending on values and path
  if [[ "$have_pgstattuple" == "1" ]]; then
    # for pgstatindex path: max number of leaf pages a tiny index can have.
    # so treat indexes with ≤ this many leaf pages as tiny → (0.00% bloat).
    [[ "$REINDEX_TINY_INDEX_PAGES_MAX" =~ ^[0-9]+$ ]] || die "REINDEX_TINY_INDEX_PAGES_MAX={REINDEX_TINY_INDEX_PAGES_MAX} must be integer"
    tiny_index_leaf_pages=$((REINDEX_TINY_INDEX_PAGES_MAX - 2)); [[ $tiny_index_leaf_pages -le 0 ]] && tiny_index_leaf_pages=1
    # for pgstatindex path: number of leaf pages beyond the tiny threshold to ramp from 0 to full bloat.
    # 0 disables smoothing (sharp cutoff).
    if [[ "$REINDEX_DAMP_MODE" == "product" || "$REINDEX_DAMP_MODE" == "min" ]]; then
      small_tree_smooth_span=3
    elif [[ "$REINDEX_DAMP_MODE" == "division" || "$REINDEX_DAMP_MODE" == "max" ]]; then
      small_tree_smooth_span=2
    elif [[ "$REINDEX_DAMP_MODE" == "none" ]]; then
      small_tree_smooth_span=1
    elif [[ "$REINDEX_DAMP_MODE" == "power" ]]; then
      # simple float validation greater than 1 (e.g., 2, 2.0, 1.25)
      [[ "$REINDEX_DAMP_GAMMA" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA} must be a positive number"
      if awk "BEGIN{exit !($REINDEX_DAMP_GAMMA < 1)}" || awk "BEGIN{exit !($REINDEX_DAMP_GAMMA >= 10)}"; then
        die "REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA} must be a positive number equal to or greater than 1 and less than 10"
      fi
      if awk "BEGIN{exit !($REINDEX_DAMP_GAMMA >= 1)}" && awk "BEGIN{exit !($REINDEX_DAMP_GAMMA <= 3)}"; then
        small_tree_smooth_span=3
      else
        small_tree_smooth_span=$REINDEX_DAMP_GAMMA
      fi
    else
      log "WARN: REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE} should be set to one of [power|product|min|division|max|none]"
      log "Setting it to conservative bloat damping 'max'"
      REINDEX_DAMP_MODE=max
      small_tree_smooth_span=2
    fi
    if [[ "$REINDEX_DAMP_MODE" != "power" ]]; then
      log "Adjust bloat: tiny_indexes_max_leaf_pages=${tiny_index_leaf_pages}, small_indexes_gradual_smooth_span=${small_tree_smooth_span}"
      log "       (gate: REINDEX_TINY_INDEX_PAGES_MAX=${REINDEX_TINY_INDEX_PAGES_MAX}, REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE})"
    else
      log "Adjust bloat: tiny_indexes_max_leaf_pages=${tiny_index_leaf_pages}, small_indexes_gradual_smooth_span=${small_tree_smooth_span}"
      log "       (gate: REINDEX_TINY_INDEX_PAGES_MAX=${REINDEX_TINY_INDEX_PAGES_MAX}, REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE}, REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA})"
    fi
  else
    if [[ "$REINDEX_DAMP_MODE" != "power" ]]; then
      log "Adjust bloat: (gates: REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE}, REINDEX_TINY_INDEX_PAGES_MAX=${REINDEX_TINY_INDEX_PAGES_MAX}, REINDEX_MIN_INDEX_PAGES=${REINDEX_MIN_INDEX_PAGES},  REINDEX_MIN_SAVED_PAGES=${REINDEX_MIN_SAVED_PAGES})"
    else
      log "Adjust bloat: (gates: REINDEX_DAMP_MODE=${REINDEX_DAMP_MODE}, REINDEX_DAMP_GAMMA=${REINDEX_DAMP_GAMMA}, REINDEX_TINY_INDEX_PAGES_MAX=${REINDEX_TINY_INDEX_PAGES_MAX}, REINDEX_MIN_INDEX_PAGES=${REINDEX_MIN_INDEX_PAGES}, REINDEX_MIN_SAVED_PAGES=${REINDEX_MIN_SAVED_PAGES})"
    fi
  fi
  
  # Calculate index bloat for each table
  for st in "${TARGETS[@]}"; do
    sch="${st%%|*}"; tab="${st#*|}"
    
    if [[ "$have_pgstattuple" == "1" ]]; then
      # Accurate path via pgstatindex()
      index_pct="$(get_index_bloat_pct "$sch" "$tab")"
      index_pct_num=$(echo "$index_pct" | sed 's/[^0-9.]//g')
      if awk "BEGIN{exit !($index_pct_num >= $REINDEX_BLOAT_PCT)}"; then
        TO_REIN+=("${sch}|${tab}")
        log "REINDEX plan: ${sch}.${tab} (index bloat estimate ≈ ${index_pct_num}%>= ${REINDEX_BLOAT_PCT}%)   -> REINDEX"
      else
        log "REINDEX plan: ${sch}.${tab} (index bloat estimate ≈ ${index_pct_num}% < ${REINDEX_BLOAT_PCT}%)   -> NO_REIN"
      fi
    else
      # Catalog-based fallback
      stats="$(get_index_bloat_pct_fallback "$sch" "$tab")"  
      IFS='|' read -r index_pct max_pages max_saved <<< "$stats"
      index_pct_num=$(echo "$index_pct" | sed 's/[^0-9.]//g')

      if [[ "$REINDEX_DAMP_MODE" != "power" ]]; then
        log "Adjust bloat: sch=${sch}|tab=${tab}, raw_bloat=${index_pct_num}%, max_pages=${max_pages}, saved_pages=${max_saved}"
      else
        log "Adjust bloat: sch=${sch}|tab=${tab}, raw_bloat=${index_pct_num}%, max_pages=${max_pages}, saved_pages=${max_saved}"
      fi

      adj_pct="$(index_bloat_pct_adjusted_for_size "$sch" "$tab" "$index_pct_num" "$max_pages" "$max_saved")"
      adj_pct_num=$(echo "$adj_pct" | sed 's/[^0-9.]//g')
      if awk "BEGIN{exit !($adj_pct_num >= $REINDEX_BLOAT_PCT)}"; then
        TO_REIN+=("${sch}|${tab}")
        log "REINDEX plan: ${sch}.${tab} (index bloat estimate ≈ ${adj_pct_num}%>= ${REINDEX_BLOAT_PCT}%)   -> REINDEX"
      else
        log "REINDEX plan: ${sch}.${tab} (index bloat estimate ≈ ${adj_pct_num}% < ${REINDEX_BLOAT_PCT}%)   -> NO_REIN"
      fi
    fi
  done
  log "================= REINDEX PLAN DONE ================="
fi

# ---------- Autovacuum conflicts pre-check ----------
# Step 8: Autovacuum conflicts pre-check. 
#         It disables autovacuum per-table; skipped if policy=ignore
#
av_precheck

# ---------- DRY-RUN PLAN ----------
# Step 9: Executes the dry-run plan if selected.
#
if [[ "$DRY_RUN" == "true" ]]; then
  log "======= DRY-RUN PLAN (no changes will be made) ======="
  if [[ "$ANALYZE_ONLY" == "true" ]]; then
    log "Plan: ANALYZE ONLY"
    for st in "${TARGETS[@]}"; do
      sch="${st%%|*}"; tab="${st#*|}"
      echo " - ANALYZE ${sch}.${tab}" | tee -a "$LOG_FILE"
      if [[ "$REINDEX" == "true" ]]; then
        if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
          if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
            if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
              echo "   -> REINDEX TABLE CONCURRENTLY ${sch}.${tab}" | tee -a "$LOG_FILE"
            else
              echo "   -> REINDEX TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
            fi
          fi
        else
          if [[ ${#TABLES[@]} -gt 0 ]]; then
            if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
              echo "   -> REINDEX TABLE CONCURRENTLY ${sch}.${tab}" | tee -a "$LOG_FILE"
            else
              echo "   -> REINDEX TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
            fi
          fi
        fi
      fi
    done
    if [[ "$REINDEX" == "true" && "$REINDEX_ON_BLOAT" != "true" && ${#TABLES[@]} -le 0 ]]; then
      echo "----------------------"
      #log "Plan: REINDEX"
      if [[ ${#SCHEMAS[@]} -gt 0 ]]; then
        for sch in "${SCHEMAS[@]}"; do
          if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
            echo " - REINDEX SCHEMA CONCURRENTLY ${sch}" | tee -a "$LOG_FILE"
          else
            echo " - REINDEX SCHEMA ${sch}" | tee -a "$LOG_FILE"
          fi
        done
      else
        if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
          echo " - REINDEX DATABASE CONCURRENTLY ${DBNAME}" | tee -a "$LOG_FILE"
        else
          echo " - REINDEX DATABASE ${DBNAME}" | tee -a "$LOG_FILE"
        fi
      fi
    fi
  else
    if [[ ${#TO_VAC[@]} -gt 0 ]]; then
      log "Plan: Online VACUUM on ${#TO_VAC[@]} table(s)"
      for st in "${TO_VAC[@]}"; do
        sch="${st%%|*}"; tab="${st#*|}"
        echo " - VACUUM ${sch}.${tab}" | tee -a "$LOG_FILE"
        [[ "$ANALYZE" == "true" ]] && echo "   -> ANALYZE ${sch}.${tab}" | tee -a "$LOG_FILE"
        if [[ "$REINDEX" == "true" ]]; then
          if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
            if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
              if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
                echo "   -> REINDEX TABLE CONCURRENTLY ${sch}.${tab}" | tee -a "$LOG_FILE"
              else
                echo "   -> REINDEX TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
              fi
            fi
          else
            if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
              echo "   -> REINDEX TABLE CONCURRENTLY ${sch}.${tab}" | tee -a "$LOG_FILE"
            else
              echo "   -> REINDEX TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
            fi
          fi
        fi
      done
    fi
    if [[ ${#TO_FULL[@]} -gt 0 ]]; then
      log "Plan: VACUUM FULL (exclusive mode) on ${#TO_FULL[@]} table(s)"
      echo "   (Would: REVOKE CONNECTIONS; terminate other sessions to '${DBNAME}'; run tasks; restore CONNECTIONS)" | tee -a "$LOG_FILE"
      for st in "${TO_FULL[@]}"; do
        sch="${st%%|*}"; tab="${st#*|}"
        echo " - VACUUM FULL ${sch}.${tab}" | tee -a "$LOG_FILE"
        [[ "$ANALYZE" == "true" ]] && echo "   -> ANALYZE ${sch}.${tab}" | tee -a "$LOG_FILE"
        if [[ "$REINDEX" == "true" ]]; then
          if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
            if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
              echo "   -> REINDEX (VERBOSE) TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
            fi
          else
            echo "   -> REINDEX (VERBOSE) TABLE ${sch}.${tab}" | tee -a "$LOG_FILE"
          fi
        fi  
      done
    fi
  fi
  log "=============== DRY-RUN PLAN COMPLETED ================"
  final_messages
  exit 0
fi

# ---------- EXECUTION ----------
# Step 10: Main maintenance execution as indicated by the user's options
#         and the execution planner.
# 
VAC_OK=0; VAC_FAIL=0; AN_OK=0; AN_FAIL=0
REIDX_OK=0; REIDX_FAIL=0
FAILED_VAC=(); FAILED_AN=(); FAILED_RI=()

# (A) Online VACUUM path
if [[ "${#TO_VAC[@]}" -gt 0 && "$ANALYZE_ONLY" != "true" ]]; then
  log "Running online VACUUM on ${#TO_VAC[@]} table(s)..."
  for st in "${TO_VAC[@]}"; do
    echo -e "\n============================================="

    sch="${st%%|*}"; tab="${st#*|}"

    # Autovacuum per-table conflict handling (skip allowed)
    if [[ "$AUTOVAC_POLICY" != "ignore" ]]; then
      av_detect_and_resolve_for_table "$sch" "$tab"; avrc=$?
      if [[ "$avrc" -eq 10 ]]; then
        log "AUTOVAC POLICY skipped: ${sch}.${tab}"
        continue
      fi
    fi
    
    if [[ "$WATCH" == "true" ]]; then watch_vacuum "$sch" "$tab" & WVPID=$!; fi

    if psql_c "VACUUM (VERBOSE) ${sch}.\"${tab}\""; then
      ((VAC_OK+=1)); log "VACUUM OK: ${sch}.${tab}"
    else
      ((VAC_FAIL+=1)); FAILED_VAC+=("${sch}.${tab}"); log "VACUUM FAIL: ${sch}.${tab}"
    fi
    echo "----------------------"
    if [[ "$WATCH" == "true" ]]; then kill "$WVPID" >/dev/null 2>&1 || true; wait "$WVPID" 2>/dev/null || true; fi

    if [[ "$ANALYZE" == "true" ]]; then
      if psql_c "ANALYZE VERBOSE ${sch}.\"${tab}\""; then ((AN_OK+=1)); log "ANALYZE OK: ${sch}.${tab}"
      else ((AN_FAIL+=1)); FAILED_AN+=("${sch}.${tab}"); log "ANALYZE FAIL: ${sch}.${tab}"; fi
      echo "----------------------"
    fi

    if [[ "$REINDEX" == "true" ]]; then
      if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
        if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
          if [[ "$WATCH" == "true" ]]; then watch_reindex "$sch" "$tab" & WRPID=$!; fi
          REI_CMD="REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\""
          [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) TABLE CONCURRENTLY ${sch}.\"${tab}\""
          log "Running $REI_CMD"
          if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: ${sch}.${tab}"
          else ((REIDX_FAIL+=1)); FAILED_RI+=("${sch}.${tab}"); log "REINDEX FAIL: ${sch}.${tab}"; fi
          if [[ "$WATCH" == "true" ]]; then kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; fi
        fi
      else
        if [[ "$WATCH" == "true" ]]; then watch_reindex "$sch" "$tab" & WRPID=$!; fi
        REI_CMD="REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\""
        [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) TABLE CONCURRENTLY ${sch}.\"${tab}\""
        log "Running $REI_CMD"
        if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: ${sch}.${tab}"
        else ((REIDX_FAIL+=1)); FAILED_RI+=("${sch}.${tab}"); log "REINDEX FAIL: ${sch}.${tab}"; fi
        if [[ "$WATCH" == "true" ]]; then kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; fi
      fi
    fi
  done
fi

# (B) VACUUM FULL path (exclusive session)
if [[ "${#TO_FULL[@]}" -gt 0 && "$ANALYZE_ONLY" != "true" ]]; then
  log "Preparing VACUUM FULL for ${#TO_FULL[@]} table(s)... (exclusive mode)"
  SQL_BODY=""
  FULL_INCLUDED=0; REINDEX_INCLUDED=0
  FULL_INCLUDED_LIST=()
  for st in "${TO_FULL[@]}"; do
    sch="${st%%|*}"; tab="${st#*|}"
    
    # Autovacuum per-table conflict handling (skip allowed)
    if [[ "$AUTOVAC_POLICY" != "ignore" ]]; then
      av_detect_and_resolve_for_table "$sch" "$tab"; avrc=$?
      if [[ "$avrc" -eq 10 ]]; then
        log "AUTOVAC POLICY skipped (FULL): ${sch}.${tab}"
        continue
      fi
    fi
    
    SQL_BODY+=$'\n'"SELECT format('VACUUM FULL on %I.%I', '${sch}', '${tab}') AS notice;"
    SQL_BODY+=$'\n'"VACUUM (FULL, VERBOSE) ${sch}.\"${tab}\";"
    if [[ "$ANALYZE" == "true" ]]; then
      SQL_BODY+=$'\n'"ANALYZE VERBOSE ${sch}.\"${tab}\";"
    fi
    if [[ "$REINDEX" == "true" ]]; then
      if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
        if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
          SQL_BODY+=$'\n'"REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\";"
          ((REINDEX_INCLUDED+=1))
        fi
      else
        SQL_BODY+=$'\n'"REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\";"
      fi
    fi
    ((FULL_INCLUDED+=1))
    FULL_INCLUDED_LIST+=("${sch}.${tab}")
  done

  if [[ $FULL_INCLUDED -eq 0 ]]; then
    log "No tables remaining for VACUUM FULL after autovacuum policy filtering."
  else
    if run_full_block_and_exec "$SQL_BODY"; then
      VAC_OK=$((VAC_OK + FULL_INCLUDED))
      [[ "$ANALYZE" == "true" ]] && AN_OK=$((AN_OK + FULL_INCLUDED))
      if [[ "$REINDEX" == "true" ]]; then 
        if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
          [[ ${#TO_REIN[@]} -gt 0 ]] && REIDX_OK=$((REIDX_OK + REINDEX_INCLUDED))
        else  
          REIDX_OK=$((REIDX_OK + FULL_INCLUDED))
        fi
      fi
    else
      for fq in "${FULL_INCLUDED_LIST[@]}"; do FAILED_VAC+=("$fq"); done
      VAC_FAIL=$((VAC_FAIL + FULL_INCLUDED))
    fi
  fi
fi

# (C) ANALYZE-ONLY mode
if [[ "$ANALYZE_ONLY" == "true" ]]; then
  log "Running ANALYZE-ONLY on ${#TARGETS[@]} table(s)..."
  for st in "${TARGETS[@]}"; do
    echo -e "\n============================================="

    sch="${st%%|*}"; tab="${st#*|}"
    
    # Autovacuum per-table conflict handling (skip allowed)
    if [[ "$AUTOVAC_POLICY" != "ignore" ]]; then
      av_detect_and_resolve_for_table "$sch" "$tab"; avrc=$?
      if [[ "$avrc" -eq 10 ]]; then
        log "AUTOVAC POLICY skipped (ANALYZE-ONLY): ${sch}.${tab}"
        continue
      fi
    fi

    if psql_c "ANALYZE VERBOSE ${sch}.\"${tab}\""; then ((AN_OK+=1)); log "ANALYZE OK: ${sch}.${tab}"
    else ((AN_FAIL+=1)); FAILED_AN+=("${sch}.${tab}"); log "ANALYZE FAIL: ${sch}.${tab}"; fi
    echo "----------------------"
    if [[ "$REINDEX" == "true" ]]; then
      if [[ "$REINDEX_ON_BLOAT" == "true" ]]; then
        if [[ ${#TO_REIN[@]} -gt 0 ]] && is_in_to_rein "$sch" "$tab"; then
          if [[ "$WATCH" == "true" ]]; then watch_reindex "$sch" "$tab" & WRPID=$!; fi
          REI_CMD="REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\""
          [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) TABLE CONCURRENTLY ${sch}.\"${tab}\""
          log "Running $REI_CMD"
          if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: ${sch}.${tab}"
          else ((REIDX_FAIL+=1)); FAILED_RI+=("${sch}.${tab}"); log "REINDEX FAIL: ${sch}.${tab}"; fi
          if [[ "$WATCH" == "true" ]]; then kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; fi
        fi
      else
        if [[ ${#TABLES[@]} -gt 0 ]]; then
          if [[ "$WATCH" == "true" ]]; then watch_reindex "$sch" "$tab" & WRPID=$!; fi
          REI_CMD="REINDEX (VERBOSE) TABLE ${sch}.\"${tab}\""
          [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) TABLE CONCURRENTLY ${sch}.\"${tab}\""
          log "Running $REI_CMD"
          if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: ${sch}.${tab}"
          else ((REIDX_FAIL+=1)); FAILED_RI+=("${sch}.${tab}"); log "REINDEX FAIL: ${sch}.${tab}"; fi
          if [[ "$WATCH" == "true" ]]; then kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; fi
        fi
      fi
    fi
  done

  if [[ "$REINDEX" == "true" && "$REINDEX_ON_BLOAT" != "true" && ${#TABLES[@]} -le 0 ]]; then
    echo -e "\n============================================="
    if [[ ${#SCHEMAS[@]} -gt 0 ]]; then
      for sch in "${SCHEMAS[@]}"; do
        [[ "$WATCH" == "true" ]] && watch_dat_reindex "relid::regclass::text LIKE '${sch}.%'" & WRPID=$!
        REI_CMD="REINDEX (VERBOSE) SCHEMA ${sch}"
        [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) SCHEMA CONCURRENTLY ${sch}"
        log "Running $REI_CMD"
        if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: schema ${sch}"
        else ((REIDX_FAIL+=1)); FAILED_RI+=("schema ${sch}"); log "REINDEX FAIL: schema ${sch}"; fi
        [[ "$WATCH" == "true" ]] && { kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; }
      done
    else
      [[ "$WATCH" == "true" ]] && watch_dat_reindex "datname = current_database()" & WRPID=$!
      REI_CMD="REINDEX (VERBOSE) DATABASE ${DBNAME}"
      [[ "$REINDEX_CONCURRENTLY" == "true" ]] && REI_CMD="REINDEX (VERBOSE) DATABASE CONCURRENTLY ${DBNAME}"
      log "Running $REI_CMD"
      if psql_c "$REI_CMD"; then ((REIDX_OK+=1)); log "REINDEX OK: database ${DBNAME}"
      else ((REIDX_FAIL+=1)); FAILED_RI+=("database ${DBNAME}"); log "REINDEX FAIL: database ${DBNAME}"; fi
      [[ "$WATCH" == "true" ]] && { kill "$WRPID" >/dev/null 2>&1 || true; wait "$WRPID" 2>/dev/null || true; }
    fi
  fi
fi

# ---------- Summary ----------
# Step 11: Report the maintenance summary.
#
log "-------------------------------------------------------"
log "VACUUM   -> OK: ${VAC_OK}; FAIL: ${VAC_FAIL}"
[[ ${#FAILED_VAC[@]} -gt 0 ]] && { log "Failed VACUUM tables:"; for f in "${FAILED_VAC[@]}"; do log "  - $f"; done; }
log "ANALYZE  -> OK: ${AN_OK}; FAIL: ${AN_FAIL}"
[[ ${#FAILED_AN[@]} -gt 0 ]] && { log "Failed ANALYZE tables:"; for f in "${FAILED_AN[@]}"; do log "  - $f"; done; }
if [[ "$REINDEX" == "true" ]]; then
  log "REINDEX  -> OK: ${REIDX_OK}; FAIL: ${REIDX_FAIL}"
  [[ ${#FAILED_RI[@]} -gt 0 ]] && { log "Failed REINDEX targets:"; for f in "${FAILED_RI[@]}"; do log "  - $f"; done; }
fi
[[ ${#SKIPPED_BY_AUTOVAC[@]} -gt 0 ]] && {
  log "Skipped due to autovacuum policy:"
  for f in "${SKIPPED_BY_AUTOVAC[@]}"; do log " - $f"; done
}
# Print final messages like total time, etc.
final_messages

#
# Step 12: Exit with zero, or non-zero if there was any issues during maintenance.
#
if [[ $VAC_FAIL -gt 0 || $AN_FAIL -gt 0 || $REIDX_FAIL -gt 0 ]]; then exit 1; fi

exit 0
