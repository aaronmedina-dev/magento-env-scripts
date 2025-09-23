#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Helpers
has() { command -v "$1" >/dev/null 2>&1; }
ps_running() {
  # $1: extended regexp
  local re="$1"
  if has pgrep; then
    pgrep -af "$re" >/dev/null 2>&1
  else
    ps aux 2>/dev/null | grep -E "$re" | grep -v grep >/dev/null 2>&1
  fi
}

echo "===== System Info for $(hostname) ====="
echo "Date: $(date)"
echo "User: $(whoami)"
echo

echo "=== OS Version ==="
cat /etc/os-release
echo

echo "=== PHP Version ==="
php -v | head -n 1
echo

echo "=== PHP Modules ==="
php -m | sort
echo

echo "=== Magento Version ==="
if [ -f bin/magento ]; then
  ./bin/magento --version
else
  echo "Magento CLI not found."
fi
echo

echo "=== MySQL/MariaDB Version ==="
mysql -V || echo "MySQL not installed or not in PATH"
echo

echo "=== Valkey (Redis-compatible) Version ==="
if command -v valkey-cli >/dev/null 2>&1; then
  valkey-cli --version
elif command -v redis-cli >/dev/null 2>&1; then
  echo "Fallback: redis-cli detected (Valkey compatible)"
  redis-cli --version
else
  echo "Valkey/Redis CLI not found"
fi
echo

echo "=== Valkey Service Detection ==="
valkey_units=""
if has systemctl; then
  valkey_units=$(systemctl list-units --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -i valkey || true)
fi
if [ -n "$valkey_units" ]; then
  echo "Found Valkey services (systemd):"
  echo "$valkey_units"
  echo
  echo "$valkey_units" | while read -r unit; do
    echo "$unit: $(systemctl is-active "$unit" 2>/dev/null || true)"
  done
else
  echo "No Valkey systemd units found. Falling back to process scan."
  if ps_running 'valkey(-server)?'; then
    echo "valkey process: running"
  elif ps_running 'redis(-server)?'; then
    echo "redis (valkey-compatible) process: running"
  else
    echo "No valkey/redis processes found"
  fi
fi
echo

echo "=== Detecting Valkey Host/Port from env.php ==="
ENV_FILE="app/etc/env.php"

if [ -f "$ENV_FILE" ]; then
  php -r "
    \$env = include '$ENV_FILE';
    if (isset(\$env['valkey'])) {
      foreach (\$env['valkey'] as \$entry) {
        echo 'Primary: ' . \$entry['host'] . ':' . \$entry['port'] . PHP_EOL;
      }
    }
    if (isset(\$env['valkey-slave'])) {
      foreach (\$env['valkey-slave'] as \$entry) {
        echo 'Replica: ' . \$entry['host'] . ':' . \$entry['port'] . PHP_EOL;
      }
    }
  "
else
  echo "env.php not found."
fi
echo

echo "=== Pinging Valkey Hosts ==="
for port in 6370 26370; do
  if command -v valkey-cli >/dev/null 2>&1; then
    echo -n "Valkey on port $port: "
    valkey-cli -p "$port" ping 2>/dev/null || echo "FAILED"
  elif command -v redis-cli >/dev/null 2>&1; then
    echo -n "Redis-compatible (valkey) on port $port: "
    redis-cli -p "$port" ping 2>/dev/null || echo "FAILED"
  else
    echo "No CLI found to ping Valkey on port $port"
  fi
done
echo

echo "=== Elasticsearch / OpenSearch Detection ==="
if command -v systemctl >/dev/null 2>&1; then
  es_services=$(systemctl list-units --type=service | grep -E 'opensearch|elasticsearch' | awk '{print $1}')
else
  es_services=""
fi

if [ -n "$es_services" ]; then
  echo "Found search engine services:"
  echo "$es_services"
  echo

  echo "$es_services" | while read -r es_svc; do
    status=$(systemctl is-active "$es_svc")
    echo "$es_svc: $status"
  done

  echo
  echo "Checking HTTP response on localhost:9200..."
  if command -v curl >/dev/null 2>&1 && curl -s http://localhost:9200 >/dev/null 2>&1; then
    curl -s http://localhost:9200 | grep -E '"number"|"version"|"tagline"' || true
  else
    echo "Port 9200 not responding. Search engine may be bound to another interface or not listening."
  fi
else
  echo "No Elasticsearch or OpenSearch service found via systemctl."
fi
echo

echo "=== RabbitMQ Version ==="
if command -v rabbitmqctl >/dev/null 2>&1; then
  rabbitmqctl status | grep -i rabbitmq_version
else
  echo "RabbitMQ not installed or not in PATH"
fi
echo

echo "=== Running Services (General Check) ==="
services=(
  "php-fpm|php-fpm"
  "mysql|(mysqld|mariadbd|mariadb)"
  "elasticsearch|elasticsearch"
  "opensearch|opensearch"
  "rabbitmq-server|(rabbitmq-server|beam.smp.*rabbit)"
  "valkey|(valkey(-server)?|redis(-server)?)"
  "valkey-server|(valkey(-server)?)"
  "redis|(redis(-server)?)"
  "redis-server|(redis(-server)?)"
)

for entry in "${services[@]}"; do
  IFS='|' read -r name regex <<<"$entry"
  status=""
  st=""
  if has systemctl; then
    st=$(systemctl is-active "$name" 2>/dev/null || true)
  fi
  if [ "$st" = "active" ]; then
    status="active"
  else
    if ps_running "$regex"; then
      status="active (process)"
    elif [ -n "$st" ] && [ "$st" != "unknown" ]; then
      status="$st"  # inactive/failed/etc
    else
      status="not installed"
    fi
  fi
  echo "$name: $status"
done
echo

echo "=== Magento Mode and Sample Config ==="
if [ -f bin/magento ]; then
  echo "Magento Mode:"
  ./bin/magento deploy:mode:show
  echo

  echo "Sample frontend config values:"
  if [ -f app/etc/config.php ]; then
    grep "'frontend'" -A 5 app/etc/config.php || echo "Frontend config not found in config.php"
  else
    echo "app/etc/config.php not present; skipping dump to avoid writes."
  fi
else
  echo "Magento CLI not found"
fi
