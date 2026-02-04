#!/bin/bash
# ==============================================================
# Adobe Commerce (Magento) Deep Diagnostic Script (Duration-based)
# ==============================================================

# CONFIGURATION
MAGENTO_DIR="${MAGENTO_DIR:-/var/www/html}"
PHP_FPM_LOG="/var/log/php*-fpm.log"
NGINX_LOG="/var/log/nginx/error.log"
MYSQL_SLOW_LOG="/var/log/mysql/mysql-slow.log"
MYSQL_ERR_LOG="/var/log/mysql/mysql-error.log"
CUTOFF_HOURS=72
CUTOFF=$(date -d "-$CUTOFF_HOURS hours" "+%Y-%m-%d %H:%M:%S")
TMP_OUTPUT=$(mktemp)
HAS_ISSUES=false

echo "========== Adobe Commerce (Magento) System Health Check =========="
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Time window: Last $CUTOFF_HOURS hours (since $CUTOFF)"
echo "Magento Directory: $MAGENTO_DIR"
echo ""

# --------------------------------------------------------------
# Helper function to compare log timestamps against cutoff
# --------------------------------------------------------------
is_recent_log() {
  local log_ts="$1"
  [[ -z "$log_ts" ]] && return 1
  local log_epoch cutoff_epoch
  log_epoch=$(date -d "$log_ts" +%s 2>/dev/null)
  cutoff_epoch=$(date -d "$CUTOFF" +%s)
  [[ $log_epoch -ge $cutoff_epoch ]]
}

# --------------------------------------------------------------
# 1. Magento Indexer Status
# --------------------------------------------------------------
echo "🔍 Checking Magento Indexer Status..."
cd "$MAGENTO_DIR" || { echo "❌ Magento directory not found."; exit 1; }
php bin/magento indexer:status | tee "$TMP_OUTPUT.indexer"
if grep -qv "Ready" "$TMP_OUTPUT.indexer"; then
  INDEXER_ISSUE=true; HAS_ISSUES=true
else
  INDEXER_ISSUE=false
fi
echo ""

# --------------------------------------------------------------
# 2. PHP Config Checks
# --------------------------------------------------------------
echo "🧠 PHP Configuration Summary:"
MEM_LIMIT=$(php -r 'echo ini_get("memory_limit");')
EXEC_TIME=$(php -r 'echo ini_get("max_execution_time");')
echo "memory_limit: $MEM_LIMIT"
echo "max_execution_time: ${EXEC_TIME}s"
[[ "$MEM_LIMIT" =~ ^[0-5]?[0-9][Mm]$ ]] && LOW_MEMORY=true && HAS_ISSUES=true || LOW_MEMORY=false
[[ "$EXEC_TIME" -lt 60 ]] && LOW_TIMEOUT=true && HAS_ISSUES=true || LOW_TIMEOUT=false
echo ""

# --------------------------------------------------------------
# 3. Magento Logs (filtered by cutoff)
# --------------------------------------------------------------
echo "📄 Checking Magento system.log and exception.log (since $CUTOFF)..."
LOG_ERRORS=false
for LOGFILE in "$MAGENTO_DIR/var/log/system.log" "$MAGENTO_DIR/var/log/exception.log"; do
  if [ -f "$LOGFILE" ]; then
    echo "Analyzing: $LOGFILE"
    awk -v cutoff="$CUTOFF" '
      function to_epoch(d) { gsub(/[-:]/, " ", d); return mktime(d) }
      $0 ~ /^\[/ {
        gsub(/\[|\]/, "", $1)
        logtime = $1
        if (to_epoch(logtime) >= to_epoch(cutoff)) {
          if ($0 ~ /(Exception|Error|Fatal)/) {
            count[$2]++
          }
        }
      }
      END {
        if (length(count) == 0) print "✅ No relevant errors found."
        else {
          printf "%-60s %s\n", "Error Message Summary", "Count"
          for (msg in count) printf "%-60s %d\n", msg, count[msg]
        }
      }
    ' "$LOGFILE" | sort -k2 -nr | head -n 7
    LOG_ERRORS=true; HAS_ISSUES=true
  else
    echo "⚠️ $LOGFILE not found."
  fi
  echo ""
done
echo ""

# --------------------------------------------------------------
# 4. PHP-FPM and NGINX Logs (filtered by cutoff)
# --------------------------------------------------------------
echo "⚙️ Checking PHP-FPM and NGINX logs (since $CUTOFF)..."
check_log_recent() {
  local LOG_FILE="$1"
  local PATTERN="$2"
  local LABEL="$3"
  echo "🔍 $LABEL log:"
  if [ -f "$LOG_FILE" ]; then
    awk -v cutoff="$CUTOFF" -v pattern="$PATTERN" '
      function to_epoch(d) { gsub(/[-:]/, " ", d); return mktime(d) }
      {
        match($0, /^[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}/, t)
        if (t[0] != "") {
          cmd = "date -d \"" t[0] " " strftime("%Y") "\" +%s"
          cmd | getline log_epoch
          close(cmd)
          cutoff_epoch = to_epoch(cutoff)
          if (log_epoch >= cutoff_epoch && tolower($0) ~ tolower(pattern)) {
            print $0
            found=1
          }
        }
      }
      END { if (!found) print "✅ No relevant entries found in " FILENAME }
    ' "$LOG_FILE"
  else
    echo "⚠️ $LOG_FILE not found."
  fi
  echo ""
}

check_log_recent "$PHP_FPM_LOG" "timeout|error|failed" "PHP-FPM"
check_log_recent "$NGINX_LOG" "error|timeout|upstream" "NGINX"

# --------------------------------------------------------------
# 4a. NGINX 503 Detection (filtered)
# --------------------------------------------------------------
echo "🌐 Checking NGINX logs for 503 responses (since $CUTOFF)..."
if [ -f "$NGINX_LOG" ]; then
  awk -v cutoff="$CUTOFF" '
    function to_epoch(d) { gsub(/[-:]/, " ", d); return mktime(d) }
    {
      match($0, /^[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}/, t)
      if (t[0] != "") {
        cmd = "date -d \"" t[0] " " strftime("%Y") "\" +%s"
        cmd | getline log_epoch
        close(cmd)
        cutoff_epoch = to_epoch(cutoff)
        if (log_epoch >= cutoff_epoch && $0 ~ / 503 /) {
          print $0
          found=1
        }
      }
    }
    END { if (!found) print "✅ No 503 responses found in NGINX logs." }
  ' "$NGINX_LOG"
else
  echo "⚠️ $NGINX_LOG not found."
fi
echo ""

# --------------------------------------------------------------
# 5. MySQL Slow Query Log
# --------------------------------------------------------------
echo "🐢 Checking MySQL Slow Query Log (since $CUTOFF)..."
if [ -f "$MYSQL_SLOW_LOG" ]; then
  CUTOFF_EPOCH=$(date -d "$CUTOFF" +%s)

  awk -v cutoff="$CUTOFF_EPOCH" '
    /^SET timestamp=/ {
      match($0, /([0-9]+)/, t)
      ts = t[1]
      capture = (ts >= cutoff) ? 1 : 0
      if (capture) {
        started = 0
        query = ""
      }
      next
    }

    /^#|^$/ { next }

    {
      if (capture) {
        if (!started++) {
          print "----------------------------------------"
          printf "📅 Time: %s (%s)\n", strftime("%Y-%m-%d %H:%M:%S", ts), ts
        }
        print "📄 " $0
      }
    }

    /^;$/ {
      if (capture) {
        capture = 0
        started = 0
        print ""
      }
    }
  ' "$MYSQL_SLOW_LOG"

  SLOW_QUERY_ISSUE=true; HAS_ISSUES=true
else
  echo "ℹ️ Slow query log not found or disabled."
  SLOW_QUERY_ISSUE=false
fi
echo ""


# --------------------------------------------------------------
# 5a. MySQL Deadlocks (filtered)
# --------------------------------------------------------------
echo "🧱 Checking MySQL error log for deadlocks (since $CUTOFF)..."
if [ -f "$MYSQL_ERR_LOG" ]; then
  awk -v cutoff="$CUTOFF" '
    function to_epoch(d) { gsub(/[-:T]/, " ", d); return mktime(d) }
    match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}/, ts)
    {
      if (ts[0] != "") {
        if (to_epoch(ts[0]) >= to_epoch(cutoff) && tolower($0) ~ /deadlock/) {
          print $0
          found=1
        }
      }
    }
    END { if (!found) print "✅ No deadlocks detected in MySQL logs." }
  ' "$MYSQL_ERR_LOG"
else
  echo "⚠️ MySQL error log not found."
fi
echo ""

# --------------------------------------------------------------
# 6. Cache Status
# --------------------------------------------------------------
echo "📦 Checking Magento Cache Status..."
php bin/magento cache:status > "$TMP_OUTPUT.cache"
if grep -q "disabled" "$TMP_OUTPUT.cache"; then
  CACHE_DISABLED=true; HAS_ISSUES=true
else
  CACHE_DISABLED=false
fi
cat "$TMP_OUTPUT.cache"
echo ""

# --------------------------------------------------------------
# 7. Long-running PHP Processes
# --------------------------------------------------------------
echo "🧪 Checking for long-running PHP processes (>60s)..."
ps -eo pid,etime,cmd | grep php | awk '
  $2 ~ /[1-9][0-9]:/ || $2 ~ /[1-9][0-9][0-9]/ {
    print $0
  }' | tee "$TMP_OUTPUT.php"
if [[ -s "$TMP_OUTPUT.php" ]]; then
  LONG_RUNNING_PHP=true; HAS_ISSUES=true
else
  LONG_RUNNING_PHP=false
  echo "✅ No long-running PHP processes."
fi
echo ""

# --------------------------------------------------------------
# 8. Cron Check
# --------------------------------------------------------------
echo "🕒 Checking if Magento cron is running..."
CRON_COUNT=$(pgrep -fc cron)
if [ "$CRON_COUNT" -eq 0 ]; then
  echo "⚠️ Cron not running."
  CRON_DISABLED=true; HAS_ISSUES=true
else
  echo "✅ Cron is active (process count: $CRON_COUNT)"
  CRON_DISABLED=false
fi
echo ""

# --------------------------------------------------------------
# 9. Redis/Valkey Availability
# --------------------------------------------------------------
echo "📡 Checking Redis/Valkey availability..."

REDIS_DOWN=false
REDIS_SOCKET="/var/run/redis/redis-server.sock"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_AUTH="${REDIS_AUTH:-}"

check_redis() {
  local cli="$1"
  if [ -S "$REDIS_SOCKET" ]; then
    timeout 2 "$cli" -s "$REDIS_SOCKET" PING &>/dev/null
  else
    if [ -n "$REDIS_AUTH" ]; then
      timeout 2 "$cli" -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_AUTH" PING &>/dev/null
    else
      timeout 2 "$cli" -h "$REDIS_HOST" -p "$REDIS_PORT" PING &>/dev/null
    fi
  fi
}

if command -v redis-cli >/dev/null 2>&1; then
  if check_redis redis-cli; then
    echo "✅ Redis is reachable (via redis-cli)."
  else
    echo "❌ Redis is not responding (via redis-cli)."
    REDIS_DOWN=true; HAS_ISSUES=true
  fi
elif command -v valkey-cli >/dev/null 2>&1; then
  if check_redis valkey-cli; then
    echo "✅ Valkey is reachable (via valkey-cli)."
  else
    echo "❌ Valkey is not responding (via valkey-cli)."
    REDIS_DOWN=true; HAS_ISSUES=true
  fi
else
  echo "⚠️ Neither redis-cli nor valkey-cli found. Skipping Redis/Valkey check."
fi

echo ""

# --------------------------------------------------------------
# SUMMARY / CONTEXT-AWARE RECOMMENDATIONS
# --------------------------------------------------------------
echo "=============================================="
echo "📌 Context-Aware Recommendations:"
echo "=============================================="

$INDEXER_ISSUE        && echo "🔧 Reindex Magento: php bin/magento indexer:reindex"
$LOW_MEMORY           && echo "🔧 Increase PHP memory_limit to 512M+."
$LOW_TIMEOUT          && echo "🔧 Increase max_execution_time to 180s or higher."
$LOG_ERRORS           && echo "🔧 Investigate errors in Magento logs (system.log/exception.log)."
$SLOW_QUERY_ISSUE     && echo "🔧 Optimize slow MySQL queries using EXPLAIN and proper indexing."
$CACHE_DISABLED       && echo "🔧 Re-enable Magento cache and warm it for better performance."
$LONG_RUNNING_PHP     && echo "🔧 Long-running PHP processes detected — investigate stuck or blocking code."
$CRON_DISABLED        && echo "🔧 Start cron: service cron start or enable scheduled tasks."
$REDIS_DOWN           && echo "🔧 Redis unreachable — verify Redis service or connection settings."
$PHP_FPM_ISSUE        && echo "🔧 Tune PHP-FPM pool (pm.max_children, timeouts)."
$MYSQL_DEADLOCK_ISSUE && echo "🔧 Resolve deadlocks — avoid concurrent writes to same catalog tables."
$NGINX_503_ISSUE      && echo "🔧 503s detected — verify Fastly/Varnish timeout or upstream latency."

if ! $HAS_ISSUES; then
  echo "✅ No major issues detected in the last $CUTOFF_HOURS hours. System is healthy."
fi

rm -f "$TMP_OUTPUT"* 2>/dev/null
echo ""
echo "👉 Run this script anytime to recheck system health. Adjust CUTOFF_HOURS as needed."
echo "==================================================================="
