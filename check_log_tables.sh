#!/usr/bin/env bash
set -Eeuo pipefail

# check_log_tables.sh
# Analyzes log tables, indexer cron jobs, and log cleaner configuration
# for Adobe Commerce (Magento 2.x) environments.
#
# Usage:
#   magento-cloud ssh -p PROJECT -e ENV -- 'bash -s -- -v' < check_log_tables.sh
#   ./run-remote.sh -p PROJECT -e ENV -s check_log_tables.sh

MAGENTO_ROOT=""
VERBOSE=0
HOURS=72
SHOW_SQL=1

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Analyzes log tables, indexer cron jobs, and log cleaner configuration.

Options:
  --root PATH              Magento root directory (default: current directory)
  --hours N                Hours of cron history to check (default: 72)
  --no-sql                 Hide SQL queries from output
  -v, --verbose            Show verbose output
  -h, --help               Show this help

What it checks:
  1. Log table sizes (sorted by size descending)
  2. Changelog (_cl) table sizes for indexers
  3. indexer_update_all_views cron job status and history
  4. Indexer and mview status
  5. Log cleaner configuration

Examples:
  # Direct SSH
  magento-cloud ssh -p PROJECT -e staging -- 'bash -s -- -v' < check_log_tables.sh

  # Via run-remote.sh
  ./run-remote.sh -p PROJECT -e staging -s check_log_tables.sh -- -v
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      MAGENTO_ROOT="${2:-}"
      shift 2
      ;;
    --hours)
      HOURS="${2:-72}"
      shift 2
      ;;
    --no-sql)
      SHOW_SQL=0
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Set Magento root
if [[ -n "$MAGENTO_ROOT" ]]; then
  cd "$MAGENTO_ROOT" || { echo "ERROR: Cannot cd to $MAGENTO_ROOT" >&2; exit 1; }
elif [[ -f "app/etc/env.php" ]]; then
  MAGENTO_ROOT="$(pwd)"
elif [[ -f "/app/app/etc/env.php" ]]; then
  cd /app
  MAGENTO_ROOT="/app"
else
  echo "ERROR: Cannot find Magento root. Use --root or run from Magento directory." >&2
  exit 1
fi

# Extract database credentials
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASS=""

if [[ -n "${MAGENTO_CLOUD_RELATIONSHIPS:-}" ]]; then
  eval "$(echo "$MAGENTO_CLOUD_RELATIONSHIPS" | base64 -d | php -r '
    $r = json_decode(file_get_contents("php://stdin"), true);
    $db = $r["database"][0] ?? $r["mysql"][0] ?? null;
    if ($db) {
      echo "DB_HOST=\"" . ($db["host"] ?? "localhost") . "\"\n";
      echo "DB_PORT=\"" . ($db["port"] ?? "3306") . "\"\n";
      echo "DB_NAME=\"" . ($db["path"] ?? $db["name"] ?? "") . "\"\n";
      echo "DB_USER=\"" . ($db["username"] ?? "") . "\"\n";
      echo "DB_PASS=\"" . ($db["password"] ?? "") . "\"\n";
    }
  ')"
elif [[ -f "app/etc/env.php" ]]; then
  eval "$(php -r '
    $env = include "app/etc/env.php";
    $db = $env["db"]["connection"]["default"] ?? [];
    echo "DB_HOST=\"" . ($db["host"] ?? "localhost") . "\"\n";
    echo "DB_PORT=\"" . ($db["port"] ?? "3306") . "\"\n";
    echo "DB_NAME=\"" . ($db["dbname"] ?? "") . "\"\n";
    echo "DB_USER=\"" . ($db["username"] ?? "") . "\"\n";
    echo "DB_PASS=\"" . ($db["password"] ?? "") . "\"\n";
  ')"
fi

MYSQL_OPTS="-h $DB_HOST -P $DB_PORT -u $DB_USER"
if [[ -n "$DB_PASS" ]]; then
  MYSQL_OPTS="$MYSQL_OPTS -p$DB_PASS"
fi

# Helper for mysql queries
run_query() {
  mysql $MYSQL_OPTS -N -e "$1" "$DB_NAME" 2>/dev/null
}

run_query_table() {
  mysql $MYSQL_OPTS -t -e "$1" "$DB_NAME" 2>/dev/null
}

# Helper to show SQL query
show_sql() {
  if [[ "$SHOW_SQL" -eq 1 ]]; then
    echo "📋 SQL Query:"
    echo "-----------------------------------------------------------"
    echo "$1" | sed 's/^/   /'
    echo "-----------------------------------------------------------"
    echo ""
  fi
}

echo "============================================================"
echo "📊 LOG TABLES & INDEXER ANALYSIS"
echo "============================================================"
echo ""
echo "Magento Root: $MAGENTO_ROOT"
echo "Database: $DB_NAME @ $DB_HOST"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Analysis window: Last $HOURS hours"
echo ""

# ============================================================
# SECTION 1: Log Table Sizes
# ============================================================
echo "============================================================"
echo "1️⃣  LOG TABLE SIZES"
echo "============================================================"
echo ""
echo "Common Magento log tables sorted by size (descending):"
echo ""

LOG_TABLES=(
  "report_event"
  "report_viewed_product_index"
  "report_viewed_product_aggregated_daily"
  "report_viewed_product_aggregated_monthly"
  "report_viewed_product_aggregated_yearly"
  "report_compared_product_index"
  "customer_log"
  "customer_visitor"
  "search_query"
  "cron_schedule"
  "magento_logging_event"
  "magento_logging_event_changes"
  "catalog_compare_item"
  "persistent_session"
  "session"
  "cache"
  "cache_tag"
  "report_event_types"
  "adminnotification_inbox"
  "admin_user_session"
)

# Build SQL for log tables
LOG_TABLE_LIST=$(printf "'%s'," "${LOG_TABLES[@]}" | sed 's/,$//')

SQL_LOG_TABLES="
SELECT
  table_name AS 'Table',
  CONCAT(LPAD(FORMAT(ROUND((data_length + index_length) / 1024 / 1024, 2), 2), 10, ' '), ' MB') AS 'Size',
  LPAD(FORMAT(table_rows, 0), 15, ' ') AS 'Rows (approx)',
  CASE
    WHEN table_rows > 1000000 THEN '🔴 LARGE - Consider cleaning'
    WHEN table_rows > 100000 THEN '🟡 MEDIUM'
    ELSE '🟢 OK'
  END AS 'Status'
FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
  AND table_name IN ($LOG_TABLE_LIST)
ORDER BY (data_length + index_length) DESC"

show_sql "$SQL_LOG_TABLES"
run_query_table "$SQL_LOG_TABLES"

echo ""

# ============================================================
# SECTION 2: Changelog (_cl) Table Sizes
# ============================================================
echo "============================================================"
echo "2️⃣  INDEXER CHANGELOG TABLES (_cl)"
echo "============================================================"
echo ""
echo "Changelog tables track changes for indexers. Large tables may indicate"
echo "indexer_update_all_views is not running or falling behind."
echo ""

SQL_CHANGELOG="
SELECT
  table_name AS 'Changelog Table',
  CONCAT(LPAD(FORMAT(ROUND((data_length + index_length) / 1024 / 1024, 2), 2), 10, ' '), ' MB') AS 'Size',
  LPAD(FORMAT(table_rows, 0), 15, ' ') AS 'Rows (approx)',
  CASE
    WHEN table_rows > 100000 THEN '🔴 HIGH - Indexer may be behind'
    WHEN table_rows > 10000 THEN '🟡 ELEVATED'
    ELSE '🟢 OK'
  END AS 'Status'
FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
  AND table_name LIKE '%_cl'
ORDER BY (data_length + index_length) DESC
LIMIT 30"

show_sql "$SQL_CHANGELOG"
run_query_table "$SQL_CHANGELOG"

echo ""

# Total changelog size
SQL_CL_TOTAL="
SELECT CONCAT(ROUND(SUM(data_length + index_length) / 1024 / 1024, 2), ' MB')
FROM information_schema.tables
WHERE table_schema = '$DB_NAME' AND table_name LIKE '%_cl'"

CL_TOTAL=$(run_query "$SQL_CL_TOTAL")
echo "📦 Total changelog tables size: $CL_TOTAL"
echo ""

# ============================================================
# SECTION 3: indexer_update_all_views Cron Job
# ============================================================
echo "============================================================"
echo "3️⃣  INDEXER CRON JOB STATUS"
echo "============================================================"
echo ""

# Check cron configuration
echo "3.1 Cron Job Configuration:"
echo "-----------------------------------------------------------"

if [[ -x "bin/magento" ]]; then
  echo ""
  echo "Indexer-related cron jobs from crontab.xml:"
  php bin/magento cron:install --dry-run 2>/dev/null | grep -i "indexer" || echo "  (Could not retrieve cron configuration)"
fi

echo ""
echo "Checking cron_schedule table for indexer jobs..."
echo ""

# Recent indexer_update_all_views executions
echo "3.2 Recent indexer_update_all_views Executions (last $HOURS hours):"
echo "-----------------------------------------------------------"

CUTOFF=$(date -d "-$HOURS hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-${HOURS}H '+%Y-%m-%d %H:%M:%S')

SQL_RECENT_INDEXER="
SELECT
  job_code AS 'Job',
  status AS 'Status',
  COUNT(*) AS 'Count',
  MIN(scheduled_at) AS 'First',
  MAX(scheduled_at) AS 'Last'
FROM cron_schedule
WHERE job_code LIKE '%indexer%'
  AND scheduled_at >= '$CUTOFF'
GROUP BY job_code, status
ORDER BY job_code, status"

show_sql "$SQL_RECENT_INDEXER"
run_query_table "$SQL_RECENT_INDEXER"

echo ""
echo "3.3 Failed/Missed Indexer Cron Jobs (last $HOURS hours):"
echo "-----------------------------------------------------------"

SQL_FAILED_COUNT="
SELECT COUNT(*) FROM cron_schedule
WHERE job_code LIKE '%indexer%'
  AND status IN ('error', 'missed')
  AND scheduled_at >= '$CUTOFF'"

FAILED_COUNT=$(run_query "$SQL_FAILED_COUNT")

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  echo "⚠️  WARNING: $FAILED_COUNT failed/missed indexer jobs found"
  echo ""

  SQL_FAILED_SUMMARY="
SELECT
  job_code AS 'Job',
  status AS 'Status',
  COUNT(*) AS 'Count',
  MIN(scheduled_at) AS 'First Seen',
  MAX(scheduled_at) AS 'Last Seen'
FROM cron_schedule
WHERE job_code LIKE '%indexer%'
  AND status IN ('error', 'missed')
  AND scheduled_at >= '$CUTOFF'
GROUP BY job_code, status
ORDER BY COUNT(*) DESC, job_code"

  show_sql "$SQL_FAILED_SUMMARY"
  run_query_table "$SQL_FAILED_SUMMARY"

  echo ""
  echo "📝 Unique Error Messages:"
  echo "-----------------------------------------------------------"

  SQL_FAILED_MESSAGES="
SELECT DISTINCT
  job_code AS 'Job',
  status AS 'Status',
  COALESCE(messages, '(no message)') AS 'Full Message'
FROM cron_schedule
WHERE job_code LIKE '%indexer%'
  AND status IN ('error', 'missed')
  AND scheduled_at >= '$CUTOFF'
  AND messages IS NOT NULL
  AND messages != ''
ORDER BY job_code"

  show_sql "$SQL_FAILED_MESSAGES"

  # Use vertical format for full messages to avoid truncation
  mysql $MYSQL_OPTS -e "$SQL_FAILED_MESSAGES" "$DB_NAME" 2>/dev/null | while IFS=$'\t' read -r job status message; do
    if [[ "$job" != "Job" ]]; then
      echo ""
      echo "🔴 Job: $job"
      echo "   Status: $status"
      echo "   Message:"
      echo "$message" | fold -w 100 -s | sed 's/^/      /'
      echo ""
    fi
  done
else
  echo "✅ OK: No failed/missed indexer jobs in the last $HOURS hours"
fi

echo ""

# Last successful run
echo "3.4 Last Successful indexer_update_all_views:"
echo "-----------------------------------------------------------"

SQL_LAST_SUCCESS="
SELECT
  job_code AS 'Job',
  status AS 'Status',
  scheduled_at AS 'Scheduled',
  executed_at AS 'Executed',
  finished_at AS 'Finished'
FROM cron_schedule
WHERE job_code = 'indexer_update_all_views'
  AND status = 'success'
ORDER BY finished_at DESC
LIMIT 5"

show_sql "$SQL_LAST_SUCCESS"
run_query_table "$SQL_LAST_SUCCESS"

echo ""

# ============================================================
# SECTION 4: Indexer & Mview Status
# ============================================================
echo "============================================================"
echo "4️⃣  INDEXER & MVIEW STATUS"
echo "============================================================"
echo ""

echo "4.1 Indexer Status (bin/magento indexer:status):"
echo "-----------------------------------------------------------"
if [[ -x "bin/magento" ]]; then
  php bin/magento indexer:status 2>/dev/null || echo "  (Could not get indexer status)"
else
  echo "  bin/magento not available"
fi

echo ""
echo "4.2 Mview State (from mview_state table):"
echo "-----------------------------------------------------------"

SQL_MVIEW="
SELECT
  view_id AS 'View ID',
  mode AS 'Mode',
  status AS 'Status',
  version_id AS 'Version ID',
  updated AS 'Last Updated'
FROM mview_state
ORDER BY view_id"

show_sql "$SQL_MVIEW"
run_query_table "$SQL_MVIEW"

echo ""

# Check for indexers in 'Update by Schedule' mode
SCHEDULE_COUNT=$(run_query "SELECT COUNT(*) FROM mview_state WHERE mode = 'enabled'")
echo "📌 Indexers in 'Update by Schedule' mode: $SCHEDULE_COUNT"
echo ""

# ============================================================
# SECTION 5: Log Cleaner Configuration
# ============================================================
echo "============================================================"
echo "5️⃣  LOG CLEANER CONFIGURATION"
echo "============================================================"
echo ""

echo "5.1 System Log Cleaning Settings:"
echo "-----------------------------------------------------------"

if [[ -x "bin/magento" ]]; then
  # Get log cleaning config
  LOG_ENABLED=$(php bin/magento config:show system/log/enabled 2>/dev/null || echo "not set")
  LOG_DAYS=$(php bin/magento config:show system/log/clean_after_day 2>/dev/null || echo "not set")

  if [[ "$LOG_ENABLED" == "1" ]]; then
    echo "  ✅ Log Cleaning Enabled: $LOG_ENABLED"
  else
    echo "  ⚠️  Log Cleaning Enabled: $LOG_ENABLED"
  fi
  echo "  📅 Clean Logs After Days: $LOG_DAYS"

  if [[ "$LOG_ENABLED" != "1" ]]; then
    echo ""
    echo "  🔴 WARNING: Log cleaning is NOT enabled!"
    echo "  💡 Enable with: bin/magento config:set system/log/enabled 1"
  fi
else
  # Fallback to database query
  SQL_LOG_CONFIG="
SELECT
  path AS 'Config Path',
  value AS 'Value',
  scope AS 'Scope'
FROM core_config_data
WHERE path LIKE 'system/log/%'
ORDER BY path"

  show_sql "$SQL_LOG_CONFIG"
  run_query_table "$SQL_LOG_CONFIG"
fi

echo ""
echo "5.2 Report Statistics Cleaning Settings:"
echo "-----------------------------------------------------------"

if [[ -x "bin/magento" ]]; then
  VISITOR_DAYS=$(php bin/magento config:show system/statistics/visitor_log_clean_after_day 2>/dev/null || echo "not set")

  echo "  📅 Visitor Log Clean After Days: $VISITOR_DAYS"
else
  SQL_STATS_CONFIG="
SELECT
  path AS 'Config Path',
  value AS 'Value'
FROM core_config_data
WHERE path LIKE 'system/statistics/%'
ORDER BY path"

  show_sql "$SQL_STATS_CONFIG"
  run_query_table "$SQL_STATS_CONFIG"
fi

echo ""
echo "5.3 Cron Schedule Cleanup Settings:"
echo "-----------------------------------------------------------"

if [[ -x "bin/magento" ]]; then
  CRON_HISTORY_SUCCESS=$(php bin/magento config:show system/cron/default/history_success_lifetime 2>/dev/null || echo "not set (default: 60 min)")
  CRON_HISTORY_FAILURE=$(php bin/magento config:show system/cron/default/history_failure_lifetime 2>/dev/null || echo "not set (default: 600 min)")

  echo "  ✅ Success History Lifetime: $CRON_HISTORY_SUCCESS"
  echo "  ❌ Failure History Lifetime: $CRON_HISTORY_FAILURE"
fi

echo ""
echo "5.4 Related Log Cleaning Cron Jobs:"
echo "-----------------------------------------------------------"

SQL_LOG_CRON="
SELECT
  job_code AS 'Job',
  status AS 'Last Status',
  MAX(finished_at) AS 'Last Run'
FROM cron_schedule
WHERE job_code IN (
  'visitor_clean',
  'catalog_product_compare_clean',
  'customer_visitor_clean',
  'report_clean',
  'aggregate_sales_report_bestsellers_data',
  'aggregate_sales_report_order_data'
)
GROUP BY job_code, status
ORDER BY job_code"

show_sql "$SQL_LOG_CRON"
run_query_table "$SQL_LOG_CRON"

echo ""

# ============================================================
# SECTION 6: Summary & Recommendations
# ============================================================
echo "============================================================"
echo "6️⃣  SUMMARY & RECOMMENDATIONS"
echo "============================================================"
echo ""

# Check for issues and provide recommendations
ISSUES=0

# Check changelog tables
SQL_CL_HIGH="
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
  AND table_name LIKE '%_cl'
  AND table_rows > 100000"

CL_HIGH=$(run_query "$SQL_CL_HIGH")

if [[ "$CL_HIGH" -gt 0 ]]; then
  echo "🔴 $CL_HIGH changelog table(s) have >100K rows"
  echo "   └─ indexer_update_all_views may not be running properly"
  echo "   └─ 💡 Run: bin/magento indexer:reindex"
  echo ""
  ISSUES=$((ISSUES + 1))
fi

# Check for failed cron
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  echo "🔴 $FAILED_COUNT failed/missed indexer cron jobs"
  echo "   └─ Check cron is running: pgrep -f 'cron:run'"
  echo "   └─ 💡 Run: bin/magento cron:run --group=index"
  echo ""
  ISSUES=$((ISSUES + 1))
fi

# Check log cleaning
if [[ "${LOG_ENABLED:-0}" != "1" ]]; then
  echo "🔴 Log cleaning is NOT enabled"
  echo "   └─ 💡 Enable: bin/magento config:set system/log/enabled 1"
  echo "   └─ 💡 Set retention: bin/magento config:set system/log/clean_after_day 30"
  echo ""
  ISSUES=$((ISSUES + 1))
fi

# Check large log tables
SQL_LARGE_LOGS="
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
  AND table_name IN ($LOG_TABLE_LIST)
  AND table_rows > 1000000"

LARGE_LOGS=$(run_query "$SQL_LARGE_LOGS")

if [[ "$LARGE_LOGS" -gt 0 ]]; then
  echo "🔴 $LARGE_LOGS log table(s) have >1M rows"
  echo "   └─ Consider manual cleanup or reducing retention period"
  echo "   └─ 💡 Check log cleaner cron jobs are running"
  echo ""
  ISSUES=$((ISSUES + 1))
fi

if [[ "$ISSUES" -eq 0 ]]; then
  echo "✅ No major issues detected"
  echo ""
fi

echo "-----------------------------------------------------------"
echo "📋 General Recommendations:"
echo "-----------------------------------------------------------"
echo "  1. 🕐 Ensure cron is running every minute"
echo "  2. 🧹 Enable log cleaning: bin/magento config:set system/log/enabled 1"
echo "  3. 📅 Set reasonable retention: bin/magento config:set system/log/clean_after_day 30"
echo "  4. 📊 Monitor indexer status: bin/magento indexer:status"
echo "  5. 🔄 For large changelog tables, run: bin/magento indexer:reindex"
echo ""
echo "============================================================"
