#!/usr/bin/env bash
set -Eeuo pipefail

# verify_dump.sh
# Verifies a database dump file (supports .sql and .sql.gz)
#
# Usage:
#   ./verify_dump.sh dump.sql.gz
#   ./verify_dump.sh dump.sql
#   ./verify_dump.sh dump.sql.gz --expected-tables 668

DUMP_FILE=""
EXPECTED_TABLES=""

usage() {
  cat <<EOF
Usage: $0 FILE [OPTIONS]

Verifies a database dump file for integrity and completeness.
Supports both .sql and .sql.gz files. Works on macOS and Linux.

Options:
  --expected-tables N    Expected number of tables (for validation)
  -h, --help             Show this help

Examples:
  $0 staging_dump.sql.gz
  $0 staging_dump.sql.gz --expected-tables 668
  $0 dump.sql
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-tables)
      EXPECTED_TABLES="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$DUMP_FILE" ]]; then
        DUMP_FILE="$1"
      else
        echo "Multiple files not supported" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$DUMP_FILE" ]]; then
  echo "ERROR: No dump file specified" >&2
  usage
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "ERROR: File not found: $DUMP_FILE" >&2
  exit 1
fi

echo "============================================================"
echo "DATABASE DUMP VERIFICATION"
echo "============================================================"
echo ""
echo "File: $DUMP_FILE"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Detect if gzipped
IS_GZIPPED=0
if [[ "$DUMP_FILE" == *.gz ]]; then
  IS_GZIPPED=1
fi

# Set up cat command (handles gzip on macOS vs Linux)
if [[ "$IS_GZIPPED" -eq 1 ]]; then
  if command -v gzcat &>/dev/null; then
    CAT_CMD="gzcat"
  elif command -v zcat &>/dev/null; then
    CAT_CMD="zcat"
  else
    echo "ERROR: No gzcat or zcat found to read gzipped file" >&2
    exit 1
  fi
else
  CAT_CMD="cat"
fi

echo "------------------------------------------------------------"
echo "1. FILE INFO"
echo "------------------------------------------------------------"

# File size
FILE_SIZE=$(ls -lh "$DUMP_FILE" | awk '{print $5}')
FILE_SIZE_BYTES=$(stat -f%z "$DUMP_FILE" 2>/dev/null || stat -c%s "$DUMP_FILE" 2>/dev/null)
echo "   Size: $FILE_SIZE ($FILE_SIZE_BYTES bytes)"

# Last modified
FILE_MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DUMP_FILE" 2>/dev/null || stat -c "%y" "$DUMP_FILE" 2>/dev/null | cut -d. -f1)
echo "   Modified: $FILE_MODIFIED"

# If gzipped, test integrity
if [[ "$IS_GZIPPED" -eq 1 ]]; then
  echo ""
  echo "------------------------------------------------------------"
  echo "2. GZIP INTEGRITY"
  echo "------------------------------------------------------------"
  if gzip -t "$DUMP_FILE" 2>/dev/null; then
    echo "   Status: OK"
  else
    echo "   Status: FAILED - File is corrupted!"
    exit 1
  fi
fi

echo ""
echo "------------------------------------------------------------"
echo "3. DUMP STRUCTURE"
echo "------------------------------------------------------------"

# Count various elements
echo "   Scanning dump file (this may take a moment)..."
echo ""

STATS=$($CAT_CMD "$DUMP_FILE" | awk '
  BEGIN {
    tables=0; inserts=0; drops=0; creates=0; bytes=0
    has_header=0; has_footer=0
  }
  /^-- Database Dump/ || /^-- MySQL dump/ { has_header=1 }
  /^-- Dump complete/ { has_footer=1 }
  /^DROP TABLE/ { drops++ }
  /^CREATE TABLE/ { tables++; creates++ }
  /^INSERT INTO/ { inserts++ }
  { bytes += length($0) + 1 }
  END {
    printf "%d %d %d %d %d %d %d\n", tables, inserts, drops, creates, bytes, has_header, has_footer
  }
')

read -r TABLES INSERTS DROPS CREATES BYTES HAS_HEADER HAS_FOOTER <<< "$STATS"

# Convert bytes to human readable
SIZE_MB=$(awk "BEGIN {printf \"%.2f\", ${BYTES} / 1024 / 1024}")
SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${BYTES} / 1024 / 1024 / 1024}")

echo "   CREATE TABLE statements: $TABLES"
echo "   DROP TABLE statements:   $DROPS"
echo "   INSERT INTO statements:  $INSERTS"
echo "   Uncompressed size:       ${SIZE_MB} MB (~${SIZE_GB} GB)"

echo ""
echo "------------------------------------------------------------"
echo "4. HEADER CHECK"
echo "------------------------------------------------------------"
echo ""
echo "   First 20 lines:"
echo "   ---------------"
$CAT_CMD "$DUMP_FILE" | head -20 | sed 's/^/   /'

echo ""
echo "------------------------------------------------------------"
echo "5. FOOTER CHECK"
echo "------------------------------------------------------------"
echo ""
echo "   Last 15 lines:"
echo "   --------------"
$CAT_CMD "$DUMP_FILE" | tail -15 | sed 's/^/   /'

echo ""
echo "------------------------------------------------------------"
echo "6. VERIFICATION SUMMARY"
echo "------------------------------------------------------------"
echo ""

ISSUES=0

# Check header
if [[ "$HAS_HEADER" -eq 1 ]]; then
  echo "   [OK] Header present"
else
  echo "   [--] No standard header found (may still be valid)"
fi

# Check footer
if [[ "$HAS_FOOTER" -eq 1 ]]; then
  echo "   [OK] Footer present (dump completed)"
else
  echo "   [!!] WARNING: No 'Dump complete' footer - dump may be incomplete!"
  ISSUES=$((ISSUES + 1))
fi

# Check tables
if [[ "$TABLES" -gt 0 ]]; then
  if [[ -n "$EXPECTED_TABLES" ]]; then
    DIFF=$((EXPECTED_TABLES - TABLES))
    if [[ $DIFF -eq 0 ]]; then
      echo "   [OK] Table count matches expected ($TABLES/$EXPECTED_TABLES)"
    elif [[ $DIFF -gt 0 ]] && [[ $DIFF -lt 20 ]]; then
      echo "   [OK] Table count close to expected ($TABLES/$EXPECTED_TABLES) - some may be views/excluded"
    else
      echo "   [!!] WARNING: Table count mismatch ($TABLES found, expected $EXPECTED_TABLES)"
      ISSUES=$((ISSUES + 1))
    fi
  else
    echo "   [OK] Tables found: $TABLES"
  fi
else
  echo "   [!!] WARNING: No CREATE TABLE statements found!"
  ISSUES=$((ISSUES + 1))
fi

# Check inserts
if [[ "$INSERTS" -gt 0 ]]; then
  echo "   [OK] Data found: $INSERTS INSERT statements"
else
  echo "   [!!] WARNING: No INSERT statements - dump may be schema-only or empty"
  ISSUES=$((ISSUES + 1))
fi

# Check size
if [[ "$BYTES" -gt 1000 ]]; then
  echo "   [OK] File has content ($SIZE_MB MB uncompressed)"
else
  echo "   [!!] WARNING: File seems too small ($BYTES bytes)"
  ISSUES=$((ISSUES + 1))
fi

echo ""
echo "============================================================"
if [[ "$ISSUES" -eq 0 ]]; then
  echo "RESULT: DUMP LOOKS GOOD"
else
  echo "RESULT: $ISSUES WARNING(S) FOUND - Review above"
fi
echo "============================================================"

exit $ISSUES
