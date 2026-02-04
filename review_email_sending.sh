#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# review_email_sending.sh
# Comprehensive review of email sending configuration and activity in Magento.
#
# What it checks:
# - Global email disable setting (multiple detection methods)
# - Email transport configuration (SMTP, SendGrid, etc.)
# - Async email queue status
# - Custom modules that send email (app/code only by default)
# - Email-related log entries from Magento logs
# - System mail logs if available
#
# Usage:
#   bash review_email_sending.sh --root /path/to/magento --hours 24
#
# Remote usage (from local machine):
#   magento-cloud ssh --project PROJECT --environment ENV -- 'bash -s' < review_email_sending.sh --root /app/PROJECT_ENV --hours 24

MAGENTO_ROOT=""
HOURS=24
INCLUDE_VENDOR=0
OUT_DIR="/tmp/magento_email_review"
CSV_ONLY=0

has() { command -v "$1" >/dev/null 2>&1; }

report() {
  [[ "$CSV_ONLY" -eq 1 ]] && return 0
  echo "$@"
}

print_header() {
  [[ "$CSV_ONLY" -eq 1 ]] && return 0
  printf "\n%s\n%s\n" "============================================================" "$1"
  printf "%s\n" "============================================================"
}

print_subheader() {
  [[ "$CSV_ONLY" -eq 1 ]] && return 0
  printf "\n--- %s ---\n" "$1"
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --root PATH        Magento root directory (required for remote execution)
  --hours N          Time window for log analysis (default: 24)
  --include-vendor   Include vendor directory in code scan (default: app/code only)
  --csv-only         Output only CSV summary (suppresses report)
  -h, --help         Show this help

Remote execution:
  magento-cloud ssh --project PROJECT --environment ENV -- \\
    'bash -s -- --root /app/PROJECT_ENV --hours 24' < review_email_sending.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) MAGENTO_ROOT="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-}"; shift 2 ;;
    --include-vendor) INCLUDE_VENDOR=1; shift ;;
    --csv-only) CSV_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

if [[ -n "$MAGENTO_ROOT" ]]; then
  cd "$MAGENTO_ROOT" || { echo "ERROR: cannot cd to $MAGENTO_ROOT"; exit 1; }
fi

# Setup output directory
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
cutoff_epoch() { date -u -d "-$HOURS hours" +%s 2>/dev/null || date -v -${HOURS}H +%s; }

print_header "MAGENTO EMAIL SENDING REVIEW"
report "Timestamp: $(now_utc)"
report "Magento Root: $(pwd)"
report "Time Window: Last $HOURS hours"

# =============================================================================
# 1) EMAIL DISABLE STATUS - Multiple detection methods
# =============================================================================
print_header "1. EMAIL DISABLE STATUS"
report "Shows whether Magento's global email kill switch is enabled."
report ""
report "Where to find:"
report "  Admin:    Stores > Configuration > Advanced > System > Mail Sending Settings"
report "  CLI:      bin/magento config:show system/smtp/disable"
report "  Database: SELECT * FROM core_config_data WHERE path = 'system/smtp/disable'"
report "  File:     app/etc/env.php (system.default.system.smtp.disable)"
report ""

global_disabled="unknown"
disable_source=""

# Method 1: Magento CLI
if [[ -f bin/magento ]]; then
  report "Checking via Magento CLI..."
  set +e
  cli_val=$(php bin/magento config:show system/smtp/disable 2>/dev/null | grep -v "^$" | tail -n1)
  set -e
  if [[ -n "$cli_val" ]]; then
    if [[ "$cli_val" == "1" ]]; then
      global_disabled="YES"
      disable_source="CLI config:show"
    else
      global_disabled="NO"
      disable_source="CLI config:show"
    fi
    report "  system/smtp/disable = $cli_val (from CLI)"
  else
    report "  CLI returned no value for system/smtp/disable"
  fi
fi

# Method 2: Check env.php for SMTP configuration
if [[ -f app/etc/env.php ]]; then
  report ""
  report "Checking app/etc/env.php..."

  # Extract SMTP/mail settings from env.php
  php -r '
    $env = include "app/etc/env.php";

    // Check for disable setting in system config
    $disable = $env["system"]["default"]["system"]["smtp"]["disable"] ?? null;
    if ($disable !== null) {
      echo "  system.default.system.smtp.disable = " . ($disable ? "1 (DISABLED)" : "0 (enabled)") . "\n";
    }

    // Check for SMTP transport settings
    $transport = $env["system"]["default"]["system"]["smtp"]["transport"] ?? null;
    if ($transport) {
      echo "  system.default.system.smtp.transport = $transport\n";
    }

    $host = $env["system"]["default"]["system"]["smtp"]["host"] ?? null;
    if ($host) {
      echo "  system.default.system.smtp.host = $host\n";
    }

    $port = $env["system"]["default"]["system"]["smtp"]["port"] ?? null;
    if ($port) {
      echo "  system.default.system.smtp.port = $port\n";
    }

    // Check for async email
    $asyncEmail = $env["system"]["default"]["sales_email"]["general"]["async_sending"] ?? null;
    if ($asyncEmail !== null) {
      echo "  Async email sending = " . ($asyncEmail ? "ENABLED" : "disabled") . "\n";
    }
  ' 2>/dev/null || report "  Could not parse env.php"
fi

# Method 3: Check database directly
if [[ -f bin/magento ]] && has php; then
  report ""
  report "Checking database config..."
  set +e
  db_val=$(php -r '
    require "app/bootstrap.php";
    $bootstrap = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER);
    $obj = $bootstrap->getObjectManager();
    $resource = $obj->get("\Magento\Framework\App\ResourceConnection");
    $conn = $resource->getConnection();
    $result = $conn->fetchOne("SELECT value FROM core_config_data WHERE path = \"system/smtp/disable\" AND scope = \"default\"");
    echo $result ?? "not_set";
  ' 2>/dev/null)
  set -e
  if [[ -n "$db_val" && "$db_val" != "not_set" ]]; then
    report "  Database core_config_data: system/smtp/disable = $db_val"
    if [[ "$db_val" == "1" && "$global_disabled" == "unknown" ]]; then
      global_disabled="YES"
      disable_source="database"
    elif [[ "$db_val" == "0" && "$global_disabled" == "unknown" ]]; then
      global_disabled="NO"
      disable_source="database"
    fi
  else
    report "  No explicit setting in database (uses default)"
  fi
fi

report ""
if [[ "$global_disabled" == "YES" ]]; then
  report ">>> GLOBAL EMAIL SENDING: DISABLED <<<"
  report "    Source: $disable_source"
elif [[ "$global_disabled" == "NO" ]]; then
  report ">>> GLOBAL EMAIL SENDING: ENABLED <<<"
  report "    Source: $disable_source"
else
  report ">>> GLOBAL EMAIL SENDING: UNKNOWN (could not determine) <<<"
  report "    This typically means email is ENABLED (default behavior)"
fi

# Check granular email type settings
if [[ -f bin/magento ]] && has php; then
  report ""
  print_subheader "Individual Email Type Settings"
  report "Each email type can be enabled/disabled independently of the global setting."
  report ""
  report "Where to find:"
  report "  Sales Emails: Stores > Configuration > Sales > Sales Emails"
  report "  Customer:     Stores > Configuration > Customers > Customer Configuration"
  report "  Contact:      Stores > Configuration > General > Contacts"
  report "  Newsletter:   Stores > Configuration > Customers > Newsletter"
  report "  Database:     SELECT * FROM core_config_data WHERE path LIKE '%email%enabled%'"
  report ""

  php -r '
    require "app/bootstrap.php";
    $bootstrap = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER);
    $obj = $bootstrap->getObjectManager();
    $resource = $obj->get("\Magento\Framework\App\ResourceConnection");
    $conn = $resource->getConnection();

    // Email types to check (path => [label, default_value])
    $emailTypes = [
      // Sales emails
      "sales_email/order/enabled" => ["Order Confirmation", "1"],
      "sales_email/order_comment/enabled" => ["Order Comment", "1"],
      "sales_email/invoice/enabled" => ["Invoice", "1"],
      "sales_email/invoice_comment/enabled" => ["Invoice Comment", "1"],
      "sales_email/shipment/enabled" => ["Shipment", "1"],
      "sales_email/shipment_comment/enabled" => ["Shipment Comment", "1"],
      "sales_email/creditmemo/enabled" => ["Credit Memo", "1"],
      "sales_email/creditmemo_comment/enabled" => ["Credit Memo Comment", "1"],
      // Customer emails
      "customer/create_account/confirm" => ["Registration Confirmation Required", "0"],
      // Contact
      "contact/contact/enabled" => ["Contact Form", "1"],
      // Newsletter
      "newsletter/general/active" => ["Newsletter", "1"],
      // Wishlist
      "wishlist/email/email_enabled" => ["Wishlist Sharing", "1"],
      // Product alerts
      "catalog/productalert/allow_price" => ["Price Alert", "0"],
      "catalog/productalert/allow_stock" => ["Stock Alert", "0"],
      // Send to friend
      "sendfriend/email/enabled" => ["Send to Friend", "1"],
    ];

    // Fetch all relevant settings in one query
    $paths = array_keys($emailTypes);
    $placeholders = implode(",", array_fill(0, count($paths), "?"));
    $results = $conn->fetchAll(
      "SELECT path, value, scope, scope_id FROM core_config_data WHERE path IN ($placeholders) ORDER BY path, scope",
      $paths
    );

    // Build lookup
    $settings = [];
    foreach ($results as $row) {
      $key = $row["path"] . "_" . $row["scope"] . "_" . $row["scope_id"];
      $settings[$key] = $row["value"];
    }

    $enabled = [];
    $disabled = [];
    $nonDefault = [];

    foreach ($emailTypes as $path => list($label, $default)) {
      // Check default scope first
      $defaultKey = $path . "_default_0";
      $value = $settings[$defaultKey] ?? $default;

      if ($value === "1" || $value === 1) {
        $enabled[] = $label;
      } else {
        $disabled[] = $label;
      }

      // Check for non-default scope overrides
      foreach ($results as $row) {
        if ($row["path"] === $path && $row["scope"] !== "default") {
          $scopeLabel = $row["scope"] . " #" . $row["scope_id"];
          $scopeValue = $row["value"] ? "enabled" : "disabled";
          $nonDefault[] = "  $label: $scopeValue (scope: $scopeLabel)";
        }
      }
    }

    echo "ENABLED email types (" . count($enabled) . "):\n";
    foreach ($enabled as $e) {
      echo "  [x] $e\n";
    }

    echo "\nDISABLED email types (" . count($disabled) . "):\n";
    if (empty($disabled)) {
      echo "  (none)\n";
    } else {
      foreach ($disabled as $d) {
        echo "  [ ] $d\n";
      }
    }

    if (!empty($nonDefault)) {
      echo "\nPer-scope overrides (website/store level):\n";
      foreach ($nonDefault as $nd) {
        echo "$nd\n";
      }
    }
  ' 2>/dev/null || report "  Could not query email type settings"
fi

# =============================================================================
# 2) EMAIL TRANSPORT CONFIGURATION
# =============================================================================
print_header "2. EMAIL TRANSPORT CONFIGURATION"
report "Shows how emails are sent: default PHP mail(), SMTP module, or external service."
report ""
report "Where to find:"
report "  Composer:   composer.lock (search for smtp, sendgrid, mailgun, etc.)"
report "  env.php:    app/etc/env.php (system.default.system.smtp.* keys)"
report "  Admin:      Depends on installed module (e.g., Stores > Configuration > Advanced > System > SMTP)"
report ""

# Detect Platform.sh / Adobe Commerce Cloud environment
IS_PLATFORM_SH=0
PLATFORM_TYPE=""

print_subheader "Cloud Platform Detection"

# Check for Platform.sh environment variables
if [[ -n "${PLATFORM_PROJECT:-}" ]] || [[ -n "${MAGENTO_CLOUD_PROJECT:-}" ]]; then
  IS_PLATFORM_SH=1
  PLATFORM_TYPE="Adobe Commerce Cloud / Platform.sh"
  report "[DETECTED] $PLATFORM_TYPE environment"
  report ""
  report "  Project ID: ${PLATFORM_PROJECT:-${MAGENTO_CLOUD_PROJECT:-unknown}}"
  report "  Branch:     ${PLATFORM_BRANCH:-${MAGENTO_CLOUD_BRANCH:-unknown}}"
  report "  Environment:${PLATFORM_ENVIRONMENT:-${MAGENTO_CLOUD_ENVIRONMENT:-unknown}}"
# Check for .platform.app.yaml or .magento.app.yaml
elif [[ -f .platform.app.yaml ]] || [[ -f .magento.app.yaml ]] || [[ -f ../.platform.app.yaml ]] || [[ -f ../.magento.app.yaml ]]; then
  IS_PLATFORM_SH=1
  PLATFORM_TYPE="Adobe Commerce Cloud / Platform.sh (detected via config file)"
  report "[DETECTED] $PLATFORM_TYPE"
# Check for typical Platform.sh directory structure
elif [[ "$(pwd)" =~ ^/app/ ]] || [[ -d /app/.magento ]]; then
  IS_PLATFORM_SH=1
  PLATFORM_TYPE="Adobe Commerce Cloud / Platform.sh (detected via directory structure)"
  report "[DETECTED] $PLATFORM_TYPE"
else
  report "Not running on Adobe Commerce Cloud / Platform.sh"
fi

if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
  report ""
  report ">>> IMPORTANT: Platform-Level SendGrid Relay <<<"
  report ""
  report "  Adobe Commerce Cloud automatically routes outgoing emails through SendGrid"
  report "  at the INFRASTRUCTURE level. This means:"
  report ""
  report "  - NO Magento SMTP module is required"
  report "  - NO explicit configuration in env.php is needed"
  report "  - Emails sent via PHP mail() are intercepted by Platform.sh"
  report "  - External emails are relayed through SendGrid (*.smtp.magentosite.cloud)"
  report "  - Local emails (to root@localhost) are NOT relayed and will SOFTBOUNCE"
  report ""
  report "  To view actual email delivery status:"
  report "    1. Adobe Commerce Cloud Console > Environment > SendGrid"
  report "    2. Or contact Adobe Support for SendGrid dashboard access"
  report "    3. Email headers will show: Received: from *.smtp.magentosite.cloud"
  report ""

  # Check for SendGrid-specific environment variables
  if [[ -n "${SENDGRID_API_KEY:-}" ]] || [[ -n "${MAGENTO_CLOUD_SMTP_HOST:-}" ]]; then
    report "  SendGrid environment variables detected:"
    [[ -n "${MAGENTO_CLOUD_SMTP_HOST:-}" ]] && report "    MAGENTO_CLOUD_SMTP_HOST = ${MAGENTO_CLOUD_SMTP_HOST}"
    [[ -n "${SENDGRID_API_KEY:-}" ]] && report "    SENDGRID_API_KEY = ****" # Don't expose the key
  fi
fi

report ""

# Check for SMTP/mail modules in composer
report "Installed email/SMTP packages:"
if [[ -f composer.lock ]]; then
  php -r '
    $j = json_decode(file_get_contents("composer.lock"), true);
    $pkgs = array_merge($j["packages"] ?? [], $j["packages-dev"] ?? []);
    $found = [];
    $patterns = [
      "/\bsmtp\b/i",
      "/sendgrid/i",
      "/mailgun/i",
      "/amazon.*ses|aws.*ses/i",
      "/postmark/i",
      "/mailjet/i",
      "/sparkpost/i",
      "/mandrill/i",
      "/mailchimp.*transactional/i",
      "/ebizmarts.*mailchimp/i",
      "/dotdigital|dotmailer/i",
      "/magemail/i",
      "/swiftmailer/i",
    ];
    foreach ($pkgs as $p) {
      $n = $p["name"] ?? "";
      $v = $p["version"] ?? "";
      foreach ($patterns as $pat) {
        if (preg_match($pat, $n)) {
          $found[$n] = $v;
          break;
        }
      }
    }
    if (empty($found)) {
      echo "  None detected - using default Magento mail transport\n";
    } else {
      foreach ($found as $n => $v) {
        echo "  $n ($v)\n";
      }
    }
  ' 2>/dev/null || report "  Could not check composer.lock"
else
  report "  composer.lock not found"
fi

# Check for SendGrid or other API configurations in env.php
report ""
report "Transport settings in env.php:"
if [[ -f app/etc/env.php ]]; then
  php -r '
    $env = include "app/etc/env.php";
    $found = false;

    // Recursively search for email-related keys
    function searchKeys($arr, $prefix = "") {
      global $found;
      foreach ($arr as $k => $v) {
        $key = $prefix ? "$prefix.$k" : $k;
        if (is_array($v)) {
          searchKeys($v, $key);
        } else {
          $lk = strtolower($k);
          $lkey = strtolower($key);
          if (preg_match("/(smtp|sendgrid|mailgun|mail_|email_|ses_|postmark|transport)/i", $lkey)) {
            // Mask potential API keys/passwords
            $display = $v;
            if (preg_match("/(key|password|secret|token|api)/i", $lk) && strlen($v) > 8) {
              $display = substr($v, 0, 4) . "****" . substr($v, -4);
            }
            echo "  $key = $display\n";
            $found = true;
          }
        }
      }
    }
    searchKeys($env);
    if (!$found) {
      echo "  No explicit email transport configuration found\n";
    }
  ' 2>/dev/null || report "  Could not parse env.php"
fi

# =============================================================================
# 3) ASYNC EMAIL / QUEUE STATUS
# =============================================================================
print_header "3. ASYNC EMAIL & QUEUE STATUS"
report "Shows whether emails are sent immediately or queued for async processing via cron."
report ""
report "Where to find:"
report "  Admin:    Stores > Configuration > Sales > Sales Emails > General Settings > Asynchronous sending"
report "  CLI:      bin/magento config:show sales_email/general/async_sending"
report "  Cron:     bin/magento cron:run --group=default (processes email queue)"
report "  Queue:    SELECT * FROM cron_schedule WHERE job_code LIKE '%email%'"
report ""

if [[ -f bin/magento ]]; then
  # Check async email setting
  set +e
  async_val=$(php bin/magento config:show sales_email/general/async_sending 2>/dev/null | grep -v "^$" | tail -n1)
  set -e
  if [[ "$async_val" == "1" ]]; then
    report "Async email sending: ENABLED"
    report "  Emails are queued and sent via cron job"
  else
    report "Async email sending: DISABLED (immediate send)"
  fi

  # Check email queue consumers
  report ""
  report "Email-related queue consumers:"
  set +e
  php bin/magento queue:consumers:list 2>/dev/null | grep -i email || report "  No email queue consumers found"
  set -e

  # Check cron status for email
  report ""
  report "Recent email cron jobs (last 10):"
  set +e
  php -r '
    require "app/bootstrap.php";
    $bootstrap = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER);
    $obj = $bootstrap->getObjectManager();
    $resource = $obj->get("\Magento\Framework\App\ResourceConnection");
    $conn = $resource->getConnection();
    $results = $conn->fetchAll("
      SELECT job_code, status, created_at, executed_at, messages
      FROM cron_schedule
      WHERE job_code LIKE \"%email%\" OR job_code LIKE \"%mail%\"
      ORDER BY created_at DESC
      LIMIT 10
    ");
    if (empty($results)) {
      echo "  No email cron jobs found in schedule\n";
    } else {
      foreach ($results as $r) {
        $msg = $r["messages"] ? " - " . substr($r["messages"], 0, 50) : "";
        echo "  [{$r["status"]}] {$r["job_code"]} @ {$r["created_at"]}$msg\n";
      }
    }
  ' 2>/dev/null || report "  Could not query cron_schedule"
  set -e
fi

# =============================================================================
# 4) CUSTOM MODULES THAT SEND EMAIL
# =============================================================================
print_header "4. CUSTOM MODULES THAT SEND EMAIL (app/code)"
report "Scans custom code for email sending patterns to identify which modules send emails."
report ""
report "What it searches for:"
report "  - TransportBuilder (Magento's email builder class)"
report "  - ->sendMessage() (sends the constructed email)"
report "  - ->getTransport() (gets mail transport for sending)"
report ""
report "Where to find:"
report "  Code:   app/code/<Vendor>/<Module>/ (custom modules)"
report "  Vendor: vendor/ (use --include-vendor flag to scan)"
report ""

CSV_FILE="$OUT_DIR/email_senders.csv"
echo "module,file,class,method,line,pattern" > "$CSV_FILE"

if [[ -d app/code ]]; then
  report "Scanning app/code for email sending code..."

  # Find files that use TransportBuilder or send methods
  patterns=(
    "TransportBuilder"
    "->sendMessage("
    "->getTransport("
  )

  for pattern in "${patterns[@]}"; do
    if has rg; then
      rg -l -F "$pattern" -g '*.php' app/code 2>/dev/null | while read -r file; do
        module=$(echo "$file" | sed -E 's|app/code/([^/]+/[^/]+)/.*|\1|' | tr '/' '_')
        rg -n -F "$pattern" "$file" 2>/dev/null | while IFS=: read -r line content; do
          class=$(grep -E "^class\s+" "$file" 2>/dev/null | head -1 | sed -E 's/class\s+([A-Za-z0-9_]+).*/\1/' || echo "")
          method=$(awk -v n="$line" 'NR<=n{if($0 ~ /function\s+[A-Za-z0-9_]+/){m=$0}} END{print m}' "$file" 2>/dev/null | sed -E 's/.*function\s+([A-Za-z0-9_]+).*/\1/' || echo "")
          echo "$module,$file,$class,$method,$line,$pattern" >> "$CSV_FILE"
        done
      done || true
    else
      grep -rl -F "$pattern" app/code --include="*.php" 2>/dev/null | while read -r file; do
        module=$(echo "$file" | sed -E 's|app/code/([^/]+/[^/]+)/.*|\1|' | tr '/' '_')
        grep -n -F "$pattern" "$file" 2>/dev/null | while IFS=: read -r line content; do
          class=$(grep -E "^class\s+" "$file" 2>/dev/null | head -1 | sed -E 's/class\s+([A-Za-z0-9_]+).*/\1/' || echo "")
          echo "$module,$file,$class,,$line,$pattern" >> "$CSV_FILE"
        done
      done || true
    fi
  done

  module_count=$(tail -n +2 "$CSV_FILE" 2>/dev/null | cut -d, -f1 | sort -u | wc -l | tr -d ' ')
  file_count=$(tail -n +2 "$CSV_FILE" 2>/dev/null | wc -l | tr -d ' ')
  [[ -z "$module_count" ]] && module_count=0
  [[ -z "$file_count" ]] && file_count=0

  report ""
  report "Found $file_count email send locations in $module_count custom modules"

  # Show modules summary
  if [[ "$file_count" -gt 0 && "$CSV_ONLY" -eq 0 ]]; then
    report ""
    report "Modules with email sending capability:"
    tail -n +2 "$CSV_FILE" | cut -d, -f1 | sort -u | while read -r mod; do
      mod_count=$(grep -c "^$mod," "$CSV_FILE" || echo "0")
      report "  - $mod ($mod_count locations)"
    done

    report ""
    report "Files sending email:"
    tail -n +2 "$CSV_FILE" | cut -d, -f2 | sort -u | while read -r f; do
      report "  $f"
    done
  fi

  report ""
  report "Full details: $CSV_FILE"
else
  report "app/code directory not found"
fi

# =============================================================================
# 5) MAGENTO LOG ANALYSIS - Email Related
# =============================================================================
print_header "5. MAGENTO LOG ANALYSIS (Last $HOURS hours)"
report "Searches Magento application logs for email-related entries, errors, and exceptions."
report ""
report "What it searches for:"
report "  - Email, Mail, SMTP, Transport keywords"
report "  - sendMessage, queue-related entries"
report "  - Errors, failures, exceptions related to email"
report ""
report "Where to find:"
report "  Logs:  var/log/system.log, var/log/exception.log, var/log/debug.log"
report "  CLI:   tail -f var/log/system.log | grep -i email"
report ""

cutoff=$(cutoff_epoch)

# Broader search patterns for email activity
EMAIL_LOG_PATTERNS='[Ee]mail|[Mm]ail[^a-z]|SMTP|[Tt]ransport|[Ss]end.*[Mm]essage|[Mm]essage.*[Ss]ent|[Qq]ueue.*[Mm]ail|[Mm]ail.*[Qq]ueue'
ERROR_PATTERNS='[Ee]rror|[Ff]ail|[Ee]xception|[Uu]nable|[Cc]ould not|[Rr]eject'

for logfile in var/log/system.log var/log/exception.log var/log/debug.log; do
  if [[ -f "$logfile" ]]; then
    print_subheader "$logfile"

    # Count email-related entries (grep -c returns 1 when no matches, so capture separately)
    email_entries=$(grep -c -E "$EMAIL_LOG_PATTERNS" "$logfile" 2>/dev/null) || email_entries=0
    email_entries=${email_entries//[[:space:]]/}
    [[ -z "$email_entries" ]] && email_entries=0
    report "Total email-related entries: $email_entries"

    if [[ "$email_entries" -gt 0 ]]; then
      # Get recent entries in time window
      report ""
      report "Recent email-related log entries:"

      # Extract entries with timestamps in window
      awk -v cutoff="$cutoff" -v pat="$EMAIL_LOG_PATTERNS" '
        function to_epoch(d) { gsub(/[-:]/, " ", d); return mktime(d); }
        /^\[/ {
          t=$0; gsub(/^\[|\].*$/, "", t);
          te=to_epoch(t);
          if (te >= cutoff) { in_window=1 } else { in_window=0 }
        }
        in_window && tolower($0) ~ tolower(pat) {
          # Truncate long lines
          if (length($0) > 300) {
            print substr($0, 1, 300) "..."
          } else {
            print
          }
          count++
          if (count >= 30) exit
        }
      ' "$logfile" 2>/dev/null | while read -r line; do
        echo "  $line"
      done

      # Look for errors specifically
      report ""
      report "Email-related ERRORS in time window:"
      awk -v cutoff="$cutoff" -v emailpat="$EMAIL_LOG_PATTERNS" -v errpat="$ERROR_PATTERNS" '
        function to_epoch(d) { gsub(/[-:]/, " ", d); return mktime(d); }
        /^\[/ {
          t=$0; gsub(/^\[|\].*$/, "", t);
          te=to_epoch(t);
          if (te >= cutoff) { in_window=1 } else { in_window=0 }
        }
        in_window && tolower($0) ~ tolower(emailpat) && tolower($0) ~ tolower(errpat) {
          if (length($0) > 300) {
            print substr($0, 1, 300) "..."
          } else {
            print
          }
          count++
          if (count >= 20) exit
        }
      ' "$logfile" 2>/dev/null | while read -r line; do
        echo "  $line"
      done || report "  None found"
    fi
  fi
done

# Check for mail.log if it exists
if [[ -f var/log/mail.log ]]; then
  print_subheader "var/log/mail.log (Magento mail log)"
  report "Last 20 entries:"
  tail -20 var/log/mail.log 2>/dev/null | while read -r line; do
    echo "  $line"
  done
fi

# =============================================================================
# 6) SYSTEM MAIL LOGS (if accessible)
# =============================================================================
print_header "6. SYSTEM MAIL LOGS"
report "Shows Postfix/sendmail delivery status from system mail logs."
report ""

# Add cloud platform warning
if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
  report ">>> WARNING: Limited Reliability on Cloud Platforms <<<"
  report ""
  report "  On Adobe Commerce Cloud, this log only shows LOCAL Postfix activity."
  report "  External emails routed through SendGrid are NOT logged here."
  report ""
  report "  What you'll see here:"
  report "    - System emails to root@localhost (cron notifications, etc.)"
  report "    - These will show SOFTBOUNCE because local delivery is disabled"
  report ""
  report "  What you WON'T see here:"
  report "    - Customer emails (order confirmations, password resets, etc.)"
  report "    - These go directly through SendGrid and bypass local Postfix"
  report ""
  report "  To see actual customer email delivery:"
  report "    - Check email headers for 'Received: from *.smtp.magentosite.cloud'"
  report "    - Use Adobe Commerce Cloud Console > SendGrid"
  report "    - Contact Adobe Support for SendGrid dashboard access"
  report ""
fi

report "Status meanings:"
report "  sent     - Email successfully delivered to recipient's mail server"
report "  bounced  - Permanent failure (invalid address, rejected)"
report "  deferred - Temporary failure (will retry)"
report "  expired  - Gave up after too many retries"
report ""
report "Where to find:"
report "  Logs:    /var/log/mail.log, /var/log/maillog"
report "  Queue:   mailq (shows pending emails)"
report "  CLI:     postqueue -p (Postfix queue)"
report ""

MAIL_LOG_FOUND=0
MAIL_SENT_COUNT=0
MAIL_BOUNCED_COUNT=0
MAIL_DEFERRED_COUNT=0
MAIL_EXPIRED_COUNT=0
SOFTBOUNCE_REASON=""

for maillog in /var/log/mail.log /var/log/maillog /var/log/mail.info; do
  if [[ -f "$maillog" && -r "$maillog" ]]; then
    MAIL_LOG_FOUND=1
    print_subheader "$maillog"

    # Count by status and capture for summary
    report "Delivery status counts (all time):"
    status_output=$(grep -Eo 'status=(sent|bounced|deferred|expired)' "$maillog" 2>/dev/null | sort | uniq -c | sort -rn || true)
    if [[ -n "$status_output" ]]; then
      echo "$status_output"
      MAIL_SENT_COUNT=$(echo "$status_output" | grep "status=sent" | awk '{print $1}' | tr -d '[:space:]' || echo "0")
      MAIL_BOUNCED_COUNT=$(echo "$status_output" | grep "status=bounced" | awk '{print $1}' | tr -d '[:space:]' || echo "0")
      MAIL_DEFERRED_COUNT=$(echo "$status_output" | grep "status=deferred" | awk '{print $1}' | tr -d '[:space:]' || echo "0")
      MAIL_EXPIRED_COUNT=$(echo "$status_output" | grep "status=expired" | awk '{print $1}' | tr -d '[:space:]' || echo "0")
    else
      report "  No postfix-style status entries found"
    fi

    # Check for SOFTBOUNCE reason
    softbounce_msg=$(grep -o 'SOFTBOUNCE ([^)]*)' "$maillog" 2>/dev/null | head -1 || true)
    if [[ -n "$softbounce_msg" ]]; then
      SOFTBOUNCE_REASON="$softbounce_msg"
    fi

    # Top recipients
    report ""
    report "Top 10 recipients:"
    { grep -oE 'to=<[^>]+>' "$maillog" 2>/dev/null | sed 's/to=<//;s/>//' | sort | uniq -c | sort -rn | head -10; } || report "  Could not extract recipients"

    # Recent failures
    report ""
    report "Recent failures/bounces (last 10):"
    { grep -E 'status=(bounced|deferred|expired)|SOFTBOUNCE|error|failed' "$maillog" 2>/dev/null | tail -10; } || report "  None found"

    break
  fi
done

if [[ "$MAIL_LOG_FOUND" -eq 0 ]]; then
  report "No system mail logs found or accessible at:"
  report "  /var/log/mail.log, /var/log/maillog, /var/log/mail.info"
  report ""
  report "This is normal for cloud environments that use external SMTP services."
  report "Email delivery logs would be in your SMTP provider's dashboard (SendGrid, Mailgun, etc.)"
fi

# =============================================================================
# 7) EMAIL TEMPLATES STATUS
# =============================================================================
print_header "7. EMAIL TEMPLATES OVERVIEW"
report "Shows custom email templates created via Admin (stored in database)."
report ""
report "Where to find:"
report "  Admin:    Marketing > Communications > Email Templates"
report "  Database: SELECT * FROM email_template"
report "  Files:    vendor/magento/module-*/view/frontend/email/*.html (default templates)"
report "            app/design/frontend/<theme>/Magento_*/email/*.html (theme overrides)"
report ""

if [[ -f bin/magento ]]; then
  report "Checking for custom email templates..."
  set +e
  php -r '
    require "app/bootstrap.php";
    $bootstrap = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER);
    $obj = $bootstrap->getObjectManager();
    $resource = $obj->get("\Magento\Framework\App\ResourceConnection");
    $conn = $resource->getConnection();

    // Count custom templates
    $count = $conn->fetchOne("SELECT COUNT(*) FROM email_template");
    echo "Custom email templates in database: $count\n";

    if ($count > 0) {
      echo "\nCustom templates:\n";
      $templates = $conn->fetchAll("SELECT template_id, template_code, orig_template_code, added_at FROM email_template ORDER BY added_at DESC LIMIT 20");
      foreach ($templates as $t) {
        echo "  [{$t["template_id"]}] {$t["template_code"]}";
        if ($t["orig_template_code"]) echo " (based on: {$t["orig_template_code"]})";
        echo " - {$t["added_at"]}\n";
      }
    }
  ' 2>/dev/null || report "  Could not query email templates"
  set -e
fi

# =============================================================================
# 8) RECENT EMAILS SENT (Magento's Perspective)
# =============================================================================
print_header "8. RECENT EMAILS SENT (Magento's Perspective)"
report "Shows recent transactional emails that Magento has sent or attempted to send."
report "This is Magento's internal record - actual delivery depends on transport (SendGrid, etc.)"
report ""
report "Data sources & status meanings:"
report ""
report "  SALES EMAILS (orders, invoices, shipments, credit memos):"
report "    Table:    sales_order, sales_invoice, sales_shipment, sales_creditmemo"
report "    Column:   email_sent (1 = sent to transport, 0 = not sent)"
report "    Admin:    Sales > Orders > View Order"
report ""
report "  CUSTOMER REGISTRATION:"
report "    Table:    customer_entity"
report "    Column:   confirmation (NULL = confirmed/no confirm needed, has value = pending)"
report "    Meaning:  'CONFIRMED/NO CONFIRM NEEDED' = customer can login"
report "              'PENDING CONFIRMATION' = waiting for email verification click"
report ""
report "  B2B COMPANY USERS:"
report "    Table:    company_advanced_customer_entity"
report "    Column:   status (0 = Inactive, 1 = Active)"
report "    Meaning:  Status 0 = user cannot access company features"
report "              Status 1 = user is active in the company"
report "    Note:     Assignment emails are sent when user is linked to a company"
report ""

if [[ -f bin/magento ]] && has php; then
  set +e
  HOURS="$HOURS" php -r '
    require "app/bootstrap.php";
    $bootstrap = \Magento\Framework\App\Bootstrap::create(BP, $_SERVER);
    $obj = $bootstrap->getObjectManager();
    $resource = $obj->get("\Magento\Framework\App\ResourceConnection");
    $conn = $resource->getConnection();

    $hours = getenv("HOURS") ?: 24;
    $cutoff = date("Y-m-d H:i:s", strtotime("-{$hours} hours"));

    // Check email debugging settings
    echo "--- Email Debugging Status ---\n";
    $debugLog = $conn->fetchOne("SELECT value FROM core_config_data WHERE path = \"dev/debug/debug_logging\" AND scope = \"default\"");
    $templateHints = $conn->fetchOne("SELECT value FROM core_config_data WHERE path = \"dev/debug/template_hints_storefront\" AND scope = \"default\"");

    if ($debugLog == "1") {
      echo "  Debug logging: ENABLED (check var/log/debug.log for email details)\n";
    } else {
      echo "  Debug logging: DISABLED\n";
      echo "    To enable: bin/magento config:set dev/debug/debug_logging 1\n";
      echo "    Or Admin: Stores > Configuration > Advanced > Developer > Debug > Log to File\n";
    }

    // Check for any email-specific logging settings
    $smtpLog = $conn->fetchOne("SELECT value FROM core_config_data WHERE path LIKE \"%smtp%log%\" AND scope = \"default\" LIMIT 1");
    if ($smtpLog) {
      echo "  SMTP module logging: Found (check module-specific log files)\n";
    }
    echo "\n";

    echo "--- Sales Order Emails (Last $hours hours) ---\n";
    echo "  Source: SELECT increment_id, customer_email, email_sent, created_at FROM sales_order\n\n";
    $orders = $conn->fetchAll("
      SELECT increment_id, customer_email, email_sent, created_at, status
      FROM sales_order
      WHERE created_at >= ?
      ORDER BY created_at DESC
      LIMIT 20
    ", [$cutoff]);

    if (empty($orders)) {
      echo "  No orders in time window\n";
    } else {
      $sentCount = 0;
      $notSentCount = 0;
      foreach ($orders as $o) {
        $emailStatus = $o["email_sent"] ? "SENT" : "NOT SENT";
        if ($o["email_sent"]) $sentCount++; else $notSentCount++;
        echo "  #{$o["increment_id"]} -> {$o["customer_email"]} [$emailStatus] ({$o["created_at"]})\n";
      }
      echo "  Summary: $sentCount sent, $notSentCount not sent\n";
    }

    echo "\n--- Invoice Emails (Last $hours hours) ---\n";
    echo "  Source: sales_invoice.email_sent (1=sent, 0=not sent)\n\n";
    $invoices = $conn->fetchAll("
      SELECT i.increment_id, o.customer_email, i.email_sent, i.created_at
      FROM sales_invoice i
      JOIN sales_order o ON i.order_id = o.entity_id
      WHERE i.created_at >= ?
      ORDER BY i.created_at DESC
      LIMIT 10
    ", [$cutoff]);

    if (empty($invoices)) {
      echo "  No invoices in time window\n";
    } else {
      foreach ($invoices as $inv) {
        $emailStatus = $inv["email_sent"] ? "SENT" : "NOT SENT";
        echo "  #{$inv["increment_id"]} -> {$inv["customer_email"]} [$emailStatus] ({$inv["created_at"]})\n";
      }
    }

    echo "\n--- Shipment Emails (Last $hours hours) ---\n";
    echo "  Source: sales_shipment.email_sent (1=sent, 0=not sent)\n\n";
    $shipments = $conn->fetchAll("
      SELECT s.increment_id, o.customer_email, s.email_sent, s.created_at
      FROM sales_shipment s
      JOIN sales_order o ON s.order_id = o.entity_id
      WHERE s.created_at >= ?
      ORDER BY s.created_at DESC
      LIMIT 10
    ", [$cutoff]);

    if (empty($shipments)) {
      echo "  No shipments in time window\n";
    } else {
      foreach ($shipments as $ship) {
        $emailStatus = $ship["email_sent"] ? "SENT" : "NOT SENT";
        echo "  #{$ship["increment_id"]} -> {$ship["customer_email"]} [$emailStatus] ({$ship["created_at"]})\n";
      }
    }

    echo "\n--- Customer Registration Emails (Last $hours hours) ---\n";
    echo "  Source: customer_entity.confirmation\n";
    echo "    - NULL/empty = account confirmed OR confirmation not required\n";
    echo "    - Has value  = pending confirmation (token stored)\n\n";
    $customers = $conn->fetchAll("
      SELECT email, created_at, confirmation
      FROM customer_entity
      WHERE created_at >= ?
      ORDER BY created_at DESC
      LIMIT 10
    ", [$cutoff]);

    if (empty($customers)) {
      echo "  No new customer registrations in time window\n";
    } else {
      foreach ($customers as $c) {
        $needsConfirm = $c["confirmation"] ? "PENDING CONFIRMATION (token: ".substr($c["confirmation"],0,8)."...)" : "CONFIRMED/NO CONFIRM REQUIRED";
        echo "  {$c["email"]} ({$c["created_at"]}) - $needsConfirm\n";
      }
    }

    echo "\n--- B2B Company Assignment Emails (if B2B installed) ---\n";
    echo "  Source: company_advanced_customer_entity\n";
    echo "    - status 0 = Inactive (user cannot access company features)\n";
    echo "    - status 1 = Active (user is active company member)\n";
    echo "    - company_id 0 = Not assigned to any company yet\n\n";
    // Check if company tables exist
    $tables = $conn->fetchCol("SHOW TABLES LIKE \"company%\"");
    if (!empty($tables)) {
      // Check for recent company user assignments
      $companyUsers = $conn->fetchAll("
        SELECT ce.email, cu.company_id, cu.status, ce.created_at, ce.updated_at
        FROM company_advanced_customer_entity cu
        JOIN customer_entity ce ON cu.customer_id = ce.entity_id
        WHERE ce.updated_at >= ?
        ORDER BY ce.updated_at DESC
        LIMIT 10
      ", [$cutoff]);

      if (empty($companyUsers)) {
        echo "  No company user changes in time window\n";
      } else {
        foreach ($companyUsers as $cu) {
          echo "  {$cu["email"]} -> Company #{$cu["company_id"]} (status: {$cu["status"]})\n";
        }
      }

      // Check for sales rep assignments
      $salesReps = $conn->fetchAll("
        SELECT c.company_name, c.sales_representative_id, ae.email as rep_email, c.updated_at
        FROM company c
        LEFT JOIN admin_user ae ON c.sales_representative_id = ae.user_id
        WHERE c.updated_at >= ?
        ORDER BY c.updated_at DESC
        LIMIT 10
      ", [$cutoff]);

      if (!empty($salesReps)) {
        echo "\n  Recent Sales Rep Assignments:\n";
        foreach ($salesReps as $sr) {
          $rep = $sr["rep_email"] ?: "None";
          echo "    {$sr["company_name"]} -> Rep: $rep ({$sr["updated_at"]})\n";
        }
      }
    } else {
      echo "  B2B module not installed\n";
    }

    // Check email queue if async email is enabled
    echo "\n--- Email Queue (async_sending) ---\n";
    $asyncEnabled = $conn->fetchOne("SELECT value FROM core_config_data WHERE path = \"sales_email/general/async_sending\" AND scope = \"default\"");
    if ($asyncEnabled == "1") {
      echo "  Async email is ENABLED\n";
      // Check queue_message table for email-related messages
      $queueMsgs = $conn->fetchAll("
        SELECT topic_name, COUNT(*) as count
        FROM queue_message
        WHERE topic_name LIKE \"%email%\"
        GROUP BY topic_name
      ");
      if (!empty($queueMsgs)) {
        echo "  Queued email messages:\n";
        foreach ($queueMsgs as $q) {
          echo "    {$q["topic_name"]}: {$q["count"]} messages\n";
        }
      } else {
        echo "  No email messages in queue\n";
      }
    } else {
      echo "  Async email is DISABLED (emails sent immediately)\n";
    }

  ' 2>/dev/null || report "  Could not query email records"
  set -e
fi

# =============================================================================
# 9) SUMMARY & RECOMMENDATIONS
# =============================================================================
print_header "9. SUMMARY & RECOMMENDATIONS"
report "Consolidated findings and actionable next steps based on the analysis above."
report ""

report "CONFIGURATION STATUS:"
report "  Global Email Disable: $global_disabled"
if [[ "$global_disabled" == "YES" ]]; then
  report "  >>> All transactional emails are BLOCKED <<<"
elif [[ "$global_disabled" == "NO" ]]; then
  report "  >>> Emails can be sent (check transport config) <<<"
else
  report "  >>> Could not determine - likely ENABLED (default) <<<"
fi

report ""
report "MAIL DELIVERY STATUS:"
[[ -z "$MAIL_SENT_COUNT" ]] && MAIL_SENT_COUNT=0
[[ -z "$MAIL_BOUNCED_COUNT" ]] && MAIL_BOUNCED_COUNT=0
[[ -z "$MAIL_DEFERRED_COUNT" ]] && MAIL_DEFERRED_COUNT=0
[[ -z "$MAIL_EXPIRED_COUNT" ]] && MAIL_EXPIRED_COUNT=0

report "  Sent: $MAIL_SENT_COUNT"
report "  Bounced: $MAIL_BOUNCED_COUNT"
report "  Deferred: $MAIL_DEFERRED_COUNT"
report "  Expired: $MAIL_EXPIRED_COUNT"

# Add cloud platform status to summary
if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
  report ""
  report "CLOUD PLATFORM:"
  report "  Platform: $PLATFORM_TYPE"
  report "  SendGrid Relay: ACTIVE (infrastructure-level)"
  report "  >>> Customer emails ARE being sent via SendGrid <<<"
fi

# Determine overall email health
report ""
report "DIAGNOSIS:"

if [[ -n "$SOFTBOUNCE_REASON" ]]; then
  if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
    # On cloud platforms, SOFTBOUNCE is expected for local system emails
    report "  [INFO] Local system emails are SOFTBOUNCING (expected on cloud)"
    report "  Reason: $SOFTBOUNCE_REASON"
    report ""
    report "  This is NORMAL on Adobe Commerce Cloud:"
    report "  - Local delivery (to root@localhost) is disabled by design"
    report "  - These are system/cron notifications, not customer emails"
    report "  - Customer emails (orders, password resets, etc.) go through SendGrid"
    report "  - SendGrid delivery is NOT shown in local mail.log"
  else
    report "  [CRITICAL] Emails are SOFTBOUNCING!"
    report "  Reason: $SOFTBOUNCE_REASON"
    report ""
    report "  This typically means:"
    report "  - Local mail delivery is disabled on this server"
    report "  - No external SMTP is configured"
    report "  - Emails are being queued but cannot be delivered"
  fi
fi

if [[ "$MAIL_EXPIRED_COUNT" -gt 0 ]]; then
  report ""
  if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
    report "  [INFO] $MAIL_EXPIRED_COUNT local system emails have EXPIRED"
    report "  These are system notifications (cron, etc.) - not customer emails"
    report "  Customer emails are delivered via SendGrid (check their dashboard)"
  else
    report "  [WARNING] $MAIL_EXPIRED_COUNT emails have EXPIRED in the mail queue"
    report "  These emails were never delivered and have been abandoned"
  fi
fi

if [[ "$MAIL_SENT_COUNT" -eq 0 && "$MAIL_LOG_FOUND" -eq 1 && "$IS_PLATFORM_SH" -eq 0 ]]; then
  report ""
  report "  [WARNING] No emails have been successfully sent via local mail"
  report "  If you expect emails to be sent, check your SMTP configuration"
fi

if [[ "$global_disabled" != "YES" && "$MAIL_SENT_COUNT" -eq 0 && -z "$SOFTBOUNCE_REASON" && "$MAIL_LOG_FOUND" -eq 0 ]]; then
  report ""
  report "  [INFO] No local mail logs found"
  report "  This is normal if using external SMTP (SendGrid, Mailgun, etc.)"
  report "  Check your SMTP provider dashboard for delivery status"
fi

report ""
report "RECOMMENDATIONS:"

if [[ "$IS_PLATFORM_SH" -eq 1 ]]; then
  report ""
  report "  You are on Adobe Commerce Cloud with SendGrid relay:"
  report ""
  report "  To verify email delivery:"
  report "  1. Check email headers for 'Received: from *.smtp.magentosite.cloud'"
  report "  2. Access Adobe Commerce Cloud Console > Environment > SendGrid"
  report "  3. Contact Adobe Support for full SendGrid dashboard access"
  report ""
  report "  To test email sending:"
  report "     bin/magento setup:email:send --to=your@email.com"
  report ""
  report "  If customer reports duplicate emails:"
  report "  - Check for duplicate observers/plugins on email events"
  report "  - Review cron_schedule for duplicate email job executions"
  report "  - Check if async email is enabled (could cause timing issues)"
elif [[ -n "$SOFTBOUNCE_REASON" || "$MAIL_EXPIRED_COUNT" -gt 0 ]]; then
  report ""
  report "  To fix email delivery on this environment:"
  report "  1. Install and configure an SMTP module:"
  report "     - mageplaza/module-smtp"
  report "     - magepal/magento2-gmail-smtp-app"
  report "  2. Or configure Platform.sh/Adobe Commerce Cloud SMTP relay"
  report "  3. Or use a transactional email service (SendGrid, Mailgun, etc.)"
  report ""
  report "  Quick test after configuration:"
  report "     bin/magento setup:email:send --to=test@example.com"
fi

if [[ "$global_disabled" == "YES" ]]; then
  report ""
  report "  To enable email sending:"
  report "  1. Admin: Stores > Configuration > Advanced > System > Mail Sending Settings"
  report "  2. Set 'Disable Email Communications' to 'No'"
  report "  3. Or via CLI: bin/magento config:set system/smtp/disable 0"
fi

report ""
report "FILES GENERATED:"
report "  $CSV_FILE - List of custom modules sending email"

# Output CSV if requested
if [[ "$CSV_ONLY" -eq 1 ]]; then
  cat "$CSV_FILE"
fi

report ""
report "Done."
