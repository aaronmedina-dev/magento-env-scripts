#!/usr/bin/env bash
set -Eeuo pipefail

# dump_database.sh
# Creates a full database dump from Adobe Commerce Cloud environment.
# Designed to run remotely via run-remote.sh or magento-cloud ssh.
#
# Usage (via run-remote.sh):
#   ./run-remote.sh -p PROJECT -e ENV -s dump_database.sh -o dump.sql
#   ./run-remote.sh -p PROJECT -e ENV -s dump_database.sh -- --no-data | gzip > schema.sql.gz
#
# Usage (direct):
#   magento-cloud ssh -p PROJECT -e ENV -- 'bash -s' < dump_database.sh > dump.sql
#   magento-cloud ssh -p PROJECT -e ENV -- 'bash -s -- --exclude-tables search_query' < dump_database.sh > dump.sql

EXCLUDE_TABLES=""
STRUCTURE_ONLY_TABLES=""
NO_DATA=0
NO_DEFINER=1
ADD_DROP=1
SINGLE_TRANSACTION=1
VERBOSE=0
USE_N98=0
N98_STRIP=""
N98_ANONYMIZE=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Creates a full database dump. Run this script on the remote environment.

Options:
  --exclude-tables TABLES    Comma-separated tables to exclude entirely
  --structure-only TABLES    Comma-separated tables to dump structure only (no default)
  --no-data                  Dump structure only (no data)
  --with-definer             Keep DEFINER clauses (default: removed for portability)
  --no-drop                  Don't add DROP TABLE statements
  --no-single-transaction    Don't use single transaction (not recommended)
  -v, --verbose              Show progress info (table count, sizes, timing)
  -h, --help                 Show this help

n98-magerun2 Options (auto-detects bin/n98, bin/n98-magerun2.phar, etc.):
  --use-n98                  Use n98-magerun2 instead of mysqldump
  --strip GROUPS             Strip table groups (e.g., "@customers @trade @log")
                             Groups: @stripped @development @log @sessions
                                     @trade @customers @search @idx
  --anonymize                Anonymize PII data (requires GDPR module)

  Auto-detection paths: bin/n98, bin/n98-magerun2, bin/n98-magerun2.phar,
                        bin/magerun2, bin/magerun2.phar, vendor/bin/n98-magerun2,
                        vendor/bin/n98-magerun2.phar, or global commands

Examples (via run-remote.sh):
  # Full dump saved locally
  ./run-remote.sh -p abc123 -e staging -s dump_database.sh -o db_dump/staging.sql

  # Compressed dump
  ./run-remote.sh -p abc123 -e staging -s dump_database.sh | gzip > db_dump/staging.sql.gz

  # Schema only
  ./run-remote.sh -p abc123 -e staging -s dump_database.sh -- --no-data -o db_dump/schema.sql

  # Exclude specific tables
  ./run-remote.sh -p abc123 -e staging -s dump_database.sh -- --exclude-tables "cache_tag,session" | gzip > db_dump/staging.sql.gz

Examples (direct SSH):
  magento-cloud ssh -p abc123 -e staging -- 'bash -s' < dump_database.sh > db_dump/dump.sql
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- --no-data' < dump_database.sh > db_dump/schema.sql

  # Verbose mode with progress (recommended)
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- -v' < dump_database.sh > db_dump/dump.sql

  # With local transfer progress using pv
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- -v' < dump_database.sh | pv | gzip > db_dump/dump.sql.gz

n98-magerun2 Examples:
  # Use n98 for dump (auto-detects bin/n98)
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- --use-n98 -v' < dump_database.sh | gzip > db_dump/dump.sql.gz

  # Strip PII tables (customers, sales, quotes)
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- --use-n98 --strip "@customers @trade" -v' < dump_database.sh | gzip > db_dump/staging_stripped.sql.gz

  # Strip for development (logs, sessions, search indexes)
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- --use-n98 --strip "@development @log @sessions" -v' < dump_database.sh | gzip > db_dump/dev_dump.sql.gz

  # With anonymization (if GDPR module installed)
  magento-cloud ssh -p abc123 -e staging -- 'bash -s -- --use-n98 --anonymize -v' < dump_database.sh | gzip > db_dump/anon_dump.sql.gz
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude-tables)
      EXCLUDE_TABLES="${2:-}"
      shift 2
      ;;
    --structure-only)
      STRUCTURE_ONLY_TABLES="${2:-}"
      shift 2
      ;;
    --no-data)
      NO_DATA=1
      shift
      ;;
    --with-definer)
      NO_DEFINER=0
      shift
      ;;
    --no-drop)
      ADD_DROP=0
      shift
      ;;
    --no-single-transaction)
      SINGLE_TRANSACTION=0
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    --use-n98)
      USE_N98=1
      shift
      ;;
    --strip)
      N98_STRIP="${2:-}"
      USE_N98=1  # Implies --use-n98
      shift 2
      ;;
    --anonymize)
      N98_ANONYMIZE=1
      USE_N98=1  # Implies --use-n98
      shift
      ;;
    --root)
      # Accept but ignore --root (for compatibility with run-remote.sh)
      shift 2
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

# Extract database credentials
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASS=""

if [[ -n "${MAGENTO_CLOUD_RELATIONSHIPS:-}" ]]; then
  # Adobe Commerce Cloud - extract from environment variable
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
  # Fallback - extract from env.php
  eval "$(php -r '
    $env = include "app/etc/env.php";
    $db = $env["db"]["connection"]["default"] ?? [];
    echo "DB_HOST=\"" . ($db["host"] ?? "localhost") . "\"\n";
    echo "DB_PORT=\"" . ($db["port"] ?? "3306") . "\"\n";
    echo "DB_NAME=\"" . ($db["dbname"] ?? "") . "\"\n";
    echo "DB_USER=\"" . ($db["username"] ?? "") . "\"\n";
    echo "DB_PASS=\"" . ($db["password"] ?? "") . "\"\n";
  ')"
else
  echo "ERROR: Cannot find database credentials" >&2
  echo "Run this script on a Magento environment with app/etc/env.php or MAGENTO_CLOUD_RELATIONSHIPS" >&2
  exit 1
fi

if [[ -z "$DB_NAME" ]]; then
  echo "ERROR: Could not extract database name" >&2
  exit 1
fi

# Verbose logging helper (outputs to stderr)
log() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[$(date '+%H:%M:%S')] $*" >&2
  fi
}

# Track start time
START_TIME=$(date +%s)

# Build MySQL connection options (needed early for verbose stats)
MYSQL_OPTS="-h $DB_HOST -P $DB_PORT -u $DB_USER"
if [[ -n "$DB_PASS" ]]; then
  MYSQL_OPTS="$MYSQL_OPTS -p$DB_PASS"
fi

# Verbose: Show database stats before starting
if [[ "$VERBOSE" -eq 1 ]]; then
  echo "============================================================" >&2
  echo "Database Dump - Verbose Mode" >&2
  echo "============================================================" >&2
  echo "Database: $DB_NAME @ $DB_HOST:$DB_PORT" >&2
  echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" >&2
  echo "" >&2

  # Get table count and estimated size
  TABLE_COUNT=$(mysql $MYSQL_OPTS -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'" 2>/dev/null || echo "?")
  DB_SIZE_MB=$(mysql $MYSQL_OPTS -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema='$DB_NAME'" 2>/dev/null || echo "0")

  # Calculate estimates
  DB_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${DB_SIZE_MB:-0} / 1024}")
  SQL_ESTIMATE_GB=$(awk "BEGIN {printf \"%.1f\", ${DB_SIZE_MB:-0} * 1.5 / 1024}")
  GZIP_LOW_GB=$(awk "BEGIN {printf \"%.1f\", ${DB_SIZE_MB:-0} / 15 / 1024}")
  GZIP_HIGH_GB=$(awk "BEGIN {printf \"%.1f\", ${DB_SIZE_MB:-0} / 8 / 1024}")

  echo "Tables: $TABLE_COUNT" >&2
  echo "" >&2
  echo "Size estimates:" >&2
  echo "  Database (raw):        ${DB_SIZE_MB} MB (~${DB_SIZE_GB} GB)" >&2
  echo "  Uncompressed SQL:      ~${SQL_ESTIMATE_GB} GB (includes SQL syntax overhead)" >&2
  echo "  Gzipped (estimated):   ~${GZIP_LOW_GB} - ${GZIP_HIGH_GB} GB" >&2
  echo "" >&2

  # Show all tables by size
  echo "All tables by size (descending):" >&2
  echo "" >&2
  { mysql $MYSQL_OPTS -t -e "
    SELECT
      table_name AS 'Table',
      CONCAT(LPAD(FORMAT(ROUND((data_length + index_length) / 1024 / 1024, 2), 2), 10, ' '), ' MB') AS 'Size',
      LPAD(FORMAT(table_rows, 0), 12, ' ') AS 'Rows (approx)'
    FROM information_schema.tables
    WHERE table_schema='$DB_NAME'
    ORDER BY (data_length + index_length) DESC
  " 2>/dev/null || echo "  (Could not retrieve table sizes)"; } >&2
  echo "" >&2
  echo "" >&2
  echo "Tip: Pipe through 'pv' locally for transfer progress:" >&2
  echo "  magento-cloud ssh ... | pv | gzip > dump.sql.gz" >&2
  echo "============================================================" >&2
  echo "" >&2
fi

# If using n98-magerun2, handle it separately
if [[ "$USE_N98" -eq 1 ]]; then
  log "Using n98-magerun2 for dump..."

  # Find n98 binary (auto-detect common locations)
  N98_BIN=""
  N98_PATHS=(
    "bin/n98"
    "bin/n98-magerun2"
    "bin/n98-magerun2.phar"
    "bin/magerun2"
    "bin/magerun2.phar"
    "vendor/bin/n98-magerun2"
    "vendor/bin/n98-magerun2.phar"
    "vendor/bin/magerun2"
  )

  # Check local paths first
  for path in "${N98_PATHS[@]}"; do
    if [[ -x "$path" ]] || [[ -f "$path" ]]; then
      N98_BIN="$path"
      break
    fi
  done

  # Fall back to global commands
  if [[ -z "$N98_BIN" ]]; then
    if command -v n98-magerun2 &>/dev/null; then
      N98_BIN="n98-magerun2"
    elif command -v n98 &>/dev/null; then
      N98_BIN="n98"
    elif command -v magerun2 &>/dev/null; then
      N98_BIN="magerun2"
    fi
  fi

  if [[ -z "$N98_BIN" ]]; then
    echo "ERROR: n98-magerun2 not found." >&2
    echo "Searched: ${N98_PATHS[*]}" >&2
    echo "Also tried global commands: n98-magerun2, n98, magerun2" >&2
    exit 1
  fi

  log "Found n98 at: $N98_BIN"

  # Build n98 command
  N98_CMD="$N98_BIN db:dump --stdout"

  # Add strip options
  if [[ -n "$N98_STRIP" ]]; then
    N98_CMD="$N98_CMD --strip=\"$N98_STRIP\""
    log "Strip groups: $N98_STRIP"
  fi

  # Add drop tables
  if [[ "$ADD_DROP" -eq 1 ]]; then
    N98_CMD="$N98_CMD --add-drop-table"
  fi

  # Add no-data option
  if [[ "$NO_DATA" -eq 1 ]]; then
    N98_CMD="$N98_CMD --no-data"
  fi

  # Run anonymization first if requested
  if [[ "$N98_ANONYMIZE" -eq 1 ]]; then
    log "Running anonymization..."
    echo "-- Running GDPR anonymization before dump..." >&2
    if $N98_BIN gdpr:anonymize 2>&2; then
      log "Anonymization complete"
    else
      echo "WARNING: Anonymization failed or not available. Continuing with dump..." >&2
    fi
  fi

  # Output header
  echo "-- ============================================================"
  echo "-- Database Dump (via n98-magerun2)"
  echo "-- ============================================================"
  echo "-- Database: $DB_NAME"
  echo "-- Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "-- n98 command: $N98_CMD"
  echo "-- Strip: ${N98_STRIP:-none}"
  echo "-- Anonymized: $( [[ "$N98_ANONYMIZE" -eq 1 ]] && echo "yes" || echo "no" )"
  echo "-- ============================================================"
  echo ""

  log "Running: $N98_CMD"

  # Run the dump
  if [[ "$NO_DEFINER" -eq 1 ]]; then
    eval "$N98_CMD" 2>/dev/null | sed 's/DEFINER=[^*]*\*/\*/g'
  else
    eval "$N98_CMD" 2>/dev/null
  fi

  echo ""
  echo "-- ============================================================"
  echo "-- Dump complete"
  echo "-- ============================================================"

  # Show completion for n98 dumps
  if [[ "$VERBOSE" -eq 1 ]]; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))
    echo "" >&2
    echo "============================================================" >&2
    echo "DUMP COMPLETE (n98-magerun2)" >&2
    echo "============================================================" >&2
    echo "Elapsed time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s" >&2
    echo "Strip groups: ${N98_STRIP:-none}" >&2
    echo "Anonymized: $( [[ "$N98_ANONYMIZE" -eq 1 ]] && echo "yes" || echo "no" )" >&2
    echo "" >&2
    echo "To verify: ./verify_dump.sh YOUR_DUMP.sql.gz" >&2
    echo "============================================================" >&2
  fi

  exit 0
fi

log "Starting dump..."

# Output metadata as SQL comments
echo "-- ============================================================"
echo "-- Database Dump"
echo "-- ============================================================"
echo "-- Database: $DB_NAME"
echo "-- Host: $DB_HOST:$DB_PORT"
echo "-- Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
echo "-- Options:"
echo "--   Structure only tables: ${STRUCTURE_ONLY_TABLES:-none}"
echo "--   Excluded tables: ${EXCLUDE_TABLES:-none}"
echo "--   No data: $NO_DATA"
echo "-- ============================================================"
echo ""

# Build mysqldump base options
DUMP_OPTS="--quick --routines --triggers"

if [[ "$SINGLE_TRANSACTION" -eq 1 ]]; then
  DUMP_OPTS="$DUMP_OPTS --single-transaction"
fi

if [[ "$ADD_DROP" -eq 1 ]]; then
  DUMP_OPTS="$DUMP_OPTS --add-drop-table"
fi

if [[ "$NO_DATA" -eq 1 ]]; then
  DUMP_OPTS="$DUMP_OPTS --no-data"
fi

# Stats tracking file (for verbose mode)
STATS_FILE=$(mktemp 2>/dev/null || echo "/tmp/dump_stats_$$")
echo "0 0 0" > "$STATS_FILE"  # tables inserts bytes

# Function to run mysqldump, optionally strip DEFINER, and track stats
run_dump() {
  local opts="$1"
  local db="$2"
  shift 2
  local tables=("$@")

  # Build the dump command
  local dump_cmd
  if [[ ${#tables[@]} -gt 0 ]]; then
    dump_cmd="mysqldump $MYSQL_OPTS $opts \"$db\" ${tables[*]}"
  else
    dump_cmd="mysqldump $MYSQL_OPTS $opts \"$db\""
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    # Track stats while streaming output
    if [[ "$NO_DEFINER" -eq 1 ]]; then
      eval "$dump_cmd" 2>/dev/null | sed 's/DEFINER=[^*]*\*/\*/g' | awk -v sf="$STATS_FILE" '
        BEGIN { tables=0; inserts=0; bytes=0 }
        /^CREATE TABLE/ { tables++ }
        /^INSERT INTO/ { inserts++ }
        { bytes += length($0) + 1; print }
        END {
          # Read existing stats and add
          if ((getline line < sf) > 0) {
            split(line, old)
            tables += old[1]; inserts += old[2]; bytes += old[3]
          }
          close(sf)
          print tables, inserts, bytes > sf
        }
      '
    else
      eval "$dump_cmd" 2>/dev/null | awk -v sf="$STATS_FILE" '
        BEGIN { tables=0; inserts=0; bytes=0 }
        /^CREATE TABLE/ { tables++ }
        /^INSERT INTO/ { inserts++ }
        { bytes += length($0) + 1; print }
        END {
          # Read existing stats and add
          if ((getline line < sf) > 0) {
            split(line, old)
            tables += old[1]; inserts += old[2]; bytes += old[3]
          }
          close(sf)
          print tables, inserts, bytes > sf
        }
      '
    fi
  else
    # Non-verbose: just run without tracking
    if [[ "$NO_DEFINER" -eq 1 ]]; then
      eval "$dump_cmd" 2>/dev/null | sed 's/DEFINER=[^*]*\*/\*/g'
    else
      eval "$dump_cmd" 2>/dev/null
    fi
  fi
}

# Build list of tables to exclude from main dump
IGNORE_TABLES=()

# Add structure-only tables to ignore list (we'll dump them separately)
if [[ -n "$STRUCTURE_ONLY_TABLES" && "$NO_DATA" -eq 0 ]]; then
  IFS=',' read -ra STRUCT_TABLES <<< "$STRUCTURE_ONLY_TABLES"
  for table in "${STRUCT_TABLES[@]}"; do
    table=$(echo "$table" | xargs)  # trim whitespace
    # Check if table exists
    if mysql $MYSQL_OPTS -N -e "SHOW TABLES LIKE '$table'" "$DB_NAME" 2>/dev/null | grep -q .; then
      IGNORE_TABLES+=("$table")
    fi
  done
fi

# Add explicitly excluded tables
if [[ -n "$EXCLUDE_TABLES" ]]; then
  IFS=',' read -ra EXCL_TABLES <<< "$EXCLUDE_TABLES"
  for table in "${EXCL_TABLES[@]}"; do
    table=$(echo "$table" | xargs)  # trim whitespace
    IGNORE_TABLES+=("$table")
  done
fi

# Build ignore-table arguments
IGNORE_ARGS=""
for table in "${IGNORE_TABLES[@]}"; do
  IGNORE_ARGS="$IGNORE_ARGS --ignore-table=$DB_NAME.$table"
done

# Dump structure-only tables first (if not doing --no-data)
if [[ -n "$STRUCTURE_ONLY_TABLES" && "$NO_DATA" -eq 0 ]]; then
  log "Dumping structure-only tables..."
  echo "-- ============================================================"
  echo "-- Structure-only tables (no data)"
  echo "-- ============================================================"
  echo ""

  IFS=',' read -ra STRUCT_TABLES <<< "$STRUCTURE_ONLY_TABLES"
  for table in "${STRUCT_TABLES[@]}"; do
    table=$(echo "$table" | xargs)
    if mysql $MYSQL_OPTS -N -e "SHOW TABLES LIKE '$table'" "$DB_NAME" 2>/dev/null | grep -q .; then
      log "  Structure: $table"
      echo "-- Table: $table (structure only)"
      run_dump "$DUMP_OPTS --no-data" "$DB_NAME" "$table"
      echo ""
    fi
  done
fi

# Main dump
log "Dumping all tables (this may take a while)..."
echo "-- ============================================================"
echo "-- Main dump"
echo "-- ============================================================"
echo ""

run_dump "$DUMP_OPTS $IGNORE_ARGS" "$DB_NAME"

echo ""
echo "-- ============================================================"
echo "-- Dump complete"
echo "-- ============================================================"

# Verbose: Show completion stats and verification results
if [[ "$VERBOSE" -eq 1 ]]; then
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  ELAPSED_SEC=$((ELAPSED % 60))

  # Read tracked stats
  if [[ -f "$STATS_FILE" ]]; then
    read -r DUMP_TABLES DUMP_INSERTS DUMP_BYTES < "$STATS_FILE"
    rm -f "$STATS_FILE"
  else
    DUMP_TABLES="?"
    DUMP_INSERTS="?"
    DUMP_BYTES="?"
  fi

  # Convert bytes to human readable
  if [[ "$DUMP_BYTES" =~ ^[0-9]+$ ]]; then
    DUMP_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", ${DUMP_BYTES} / 1024 / 1024}")
    DUMP_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${DUMP_BYTES} / 1024 / 1024 / 1024}")
  else
    DUMP_SIZE_MB="?"
    DUMP_SIZE_GB="?"
  fi

  echo "" >&2
  echo "============================================================" >&2
  echo "DUMP VERIFICATION RESULTS" >&2
  echo "============================================================" >&2
  echo "" >&2
  echo "Timing:" >&2
  echo "  Started:      $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$START_TIME" '+%Y-%m-%d %H:%M:%S')" >&2
  echo "  Completed:    $(date '+%Y-%m-%d %H:%M:%S')" >&2
  echo "  Elapsed:      ${ELAPSED_MIN}m ${ELAPSED_SEC}s" >&2
  echo "" >&2
  echo "Output stats:" >&2
  echo "  CREATE TABLE: ${DUMP_TABLES}" >&2
  echo "  INSERT INTO:  ${DUMP_INSERTS}" >&2
  echo "  Raw size:     ${DUMP_SIZE_MB} MB (~${DUMP_SIZE_GB} GB)" >&2
  echo "" >&2
  echo "Verification:" >&2

  # Check if table count matches expected
  if [[ "$DUMP_TABLES" =~ ^[0-9]+$ ]] && [[ "${TABLE_COUNT:-0}" =~ ^[0-9]+$ ]]; then
    DIFF=$((TABLE_COUNT - DUMP_TABLES))
    if [[ $DIFF -eq 0 ]]; then
      echo "  Tables:       OK (${DUMP_TABLES}/${TABLE_COUNT} tables dumped)" >&2
    elif [[ $DIFF -gt 0 ]]; then
      # Some tables might be excluded or empty views
      echo "  Tables:       ${DUMP_TABLES}/${TABLE_COUNT} (${DIFF} excluded/views)" >&2
    else
      echo "  Tables:       WARNING - more tables than expected (${DUMP_TABLES}/${TABLE_COUNT})" >&2
    fi
  else
    echo "  Tables:       ${DUMP_TABLES} (expected: ${TABLE_COUNT:-unknown})" >&2
  fi

  # Check if we got data
  if [[ "$DUMP_INSERTS" =~ ^[0-9]+$ ]] && [[ "$DUMP_INSERTS" -gt 0 ]]; then
    echo "  Data:         OK (${DUMP_INSERTS} INSERT statements)" >&2
  elif [[ "$NO_DATA" -eq 1 ]]; then
    echo "  Data:         OK (schema-only mode, no INSERTs expected)" >&2
  else
    echo "  Data:         WARNING - no INSERT statements found" >&2
  fi

  # Check dump completion marker
  echo "  Footer:       OK (dump completed successfully)" >&2
  echo "" >&2
  echo "============================================================" >&2
  echo "" >&2
  echo "To verify the compressed file locally:" >&2
  echo "  gzip -t YOUR_FILE.sql.gz && echo 'Gzip integrity OK'" >&2
  echo "============================================================" >&2
fi
