#!/bin/bash

# --- Configuration ---
LOG_DIR="/var/log"
MAIL_LOG_PATTERN="mail.log*"   # matches mail.log, mail.log.1, mail.log.2.gz, etc.
TMP_DIR="/tmp/mail_logs_scan"

MERGED_LOG="$TMP_DIR/merged_logs.txt"
OUTPUT_CSV="$TMP_DIR/email_report.csv"
SUMMARY_REPORT="$TMP_DIR/summary_report.txt"

mkdir -p "$TMP_DIR"

# --- Init files ---
> "$MERGED_LOG"
> "$OUTPUT_CSV"
> "$SUMMARY_REPORT"

echo "timestamp,recipient,status,dsn,error" >> "$OUTPUT_CSV"

# --- Collect all relevant mail logs ---
find "$LOG_DIR" -type f -name "$MAIL_LOG_PATTERN" | while read -r LOGFILE; do
  echo "Processing $LOGFILE..."
  case "$LOGFILE" in
    *.gz) zgrep -E 'status=sent|status=bounced|status=deferred' "$LOGFILE" >> "$MERGED_LOG" ;;
    *)    grep  -E 'status=sent|status=bounced|status=deferred' "$LOGFILE" >> "$MERGED_LOG" ;;
  esac
done

# --- Check ---
if [ ! -s "$MERGED_LOG" ]; then
  echo "⚠️ No matching mail log entries found under $LOG_DIR"
  exit 0
fi

# --- Parse into CSV ---
awk '
  {
    timestamp = $1 " " $2 " " $3
    recipient = "-"
    status = "-"
    dsn = "-"
    error = "-"

    match($0, /to=<[^>]+>/, t)
    if (t[0] != "") {
      gsub(/^to=</, "", t[0])
      gsub(/>$/, "", t[0])
      recipient = t[0]
    }

    match($0, /status=[a-z]+/, s)
    if (s[0] != "") {
      split(s[0], arr, "=")
      status = arr[2]
    }

    match($0, /dsn=[0-9.]+/, d)
    if (d[0] != "") {
      split(d[0], arr, "=")
      dsn = arr[2]
    }

    match($0, /\(.*\)$/, e)
    if (e[0] != "") {
      gsub(/^\(|\)$/, "", e[0])
      error = e[0]
    }

    print timestamp "," recipient "," status "," dsn ",\"" error "\""
  }
' "$MERGED_LOG" >> "$OUTPUT_CSV"

echo "✅ CSV report generated at: $OUTPUT_CSV"

# --- Determine log timeframe ---
START_TIME=$(tail -n +2 "$OUTPUT_CSV" | head -1 | cut -d, -f1)
END_TIME=$(tail -n +2 "$OUTPUT_CSV" | tail -1 | cut -d, -f1)

# --- Summaries ---
{
  echo "📊 EMAIL LOG SUMMARY"
  echo "===================="
  echo ""
  echo "Log timeframe:"
  echo "  Start: $START_TIME"
  echo "  End:   $END_TIME"
  echo ""
  echo "1) Status counts (sent, deferred, bounced):"
  cut -d, -f3 "$OUTPUT_CSV" | tail -n +2 | sort | uniq -c | sort -nr
  echo ""
  echo "2) Top 20 recipients:"
  cut -d, -f2 "$OUTPUT_CSV" | tail -n +2 | sort | uniq -c | sort -nr | head -20
  echo ""
  echo "3) Error message breakdown (top 20 with first occurrence):"
  awk -F, 'NR>1 {
      err=$5
      if (!(err in first)) {
          first[err]=$1
      }
      count[err]++
  }
  END {
      for (e in count) {
          printf "%7d  %-70s  (first seen: %s)\n", count[e], e, first[e]
      }
  }' "$OUTPUT_CSV" | sort -nr | head -20
  echo ""
  echo "4) DSN breakdown:"
  cut -d, -f4 "$OUTPUT_CSV" | tail -n +2 | sort | uniq -c | sort -nr
  echo ""
  echo "5) Domain breakdown (top 20):"
  cut -d, -f2 "$OUTPUT_CSV" | tail -n +2 | cut -d@ -f2 | sort | uniq -c | sort -nr | head -20
  echo ""
  echo "6) Hourly volume:"
  cut -d, -f1 "$OUTPUT_CSV" | cut -d: -f1 | sort | uniq -c | sort -nr
} >> "$SUMMARY_REPORT"

echo "✅ Summary report generated at: $SUMMARY_REPORT"
