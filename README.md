# magento-env-scripts

Utilities to validate, inspect, and compare Adobe Commerce (Magento 2.x) environments across dev/staging/production. All scripts are **read-only** by default and do NOT modify configuration.

## Quick Reference

| Script | Purpose |
|--------|---------|
| [`run-remote.sh`](#run-remotesh) | Wrapper for running scripts on Adobe Commerce Cloud via SSH |
| [`audit_magento_env.sh`](#audit_magento_envsh) | One-shot environment audit (system, PHP, services, Magento) |
| [`dump_magento_env.sh`](#dump_magento_envsh) | Diff-friendly key=value dump of environment settings |
| [`dump_database.sh`](#dump_databasesh) | Full database dump with n98/PII stripping support |
| [`verify_dump.sh`](#verify_dumpsh) | Verify database dump integrity (works on macOS/Linux) |
| [`check_log_tables.sh`](#check_log_tablessh) | Analyze log tables, changelog tables, and indexer cron jobs |
| [`review_email_sending.sh`](#review_email_sendingsh) | Comprehensive email sending configuration review |
| [`analyze_mail_logs.sh`](#analyze_mail_logssh) | Parse Postfix mail logs for delivery outcomes |
| [`magento_health_check.sh`](#magento_health_checksh) | Deep diagnostics over configurable time window |
| [`generate_oneview_dashboard.sh`](#generate_oneview_dashboardsh) | Generate New Relic OneView dashboard JSON files |

---

## Getting Started

### Requirements

- `bash`, `php`, access to system logs and CLIs (`mysql`, `valkey-cli`/`redis-cli`, `rabbitmqctl`, `curl`, `systemctl`)
- For remote execution: `magento-cloud` CLI installed and authenticated

### Running Scripts

**Option 1: Using the utility wrapper (recommended for Adobe Commerce Cloud)**

```bash
./run-remote.sh --project PROJECT_ID --environment ENV --script SCRIPT_NAME [-- SCRIPT_ARGS]
```

**Option 2: Direct SSH piping**

```bash
magento-cloud ssh --project PROJECT_ID --environment ENV -- \
  'bash -s -- [SCRIPT_ARGS]' < script_name.sh
```

**Option 3: Local execution (on the Magento server)**

```bash
cd /path/to/magento
bash /path/to/script.sh [SCRIPT_ARGS]
```

---

## Script Details

### run-remote.sh

Wrapper utility for running any script on Adobe Commerce Cloud environments. Handles SSH connection and argument passing.

**Usage:**

```bash
./run-remote.sh [OPTIONS] [-- SCRIPT_ARGS]
```

| Option | Description |
|--------|-------------|
| `--project, -p PROJECT` | Magento Cloud project ID (required) |
| `--environment, -e ENV` | Environment name (required) |
| `--script, -s SCRIPT` | Script to run (required) |
| `--output, -o FILE` | Save output to local file |
| `--verbose, -v` | Show verbose output |

**Examples:**

```bash
# Run email review script
./run-remote.sh -p abc123xyz -e staging -s review_email_sending.sh -- --hours 72

# Run database dump and save locally
./run-remote.sh -p abc123xyz -e staging -s dump_database.sh -o db_dump/staging.sql

# Compressed database dump
./run-remote.sh -p abc123xyz -e staging -s dump_database.sh | gzip > db_dump/staging.sql.gz
```

---

### audit_magento_env.sh

One-shot, human-friendly audit of the host and Magento install.

**What it reports:**

- **System:** hostname, timestamp, user, `/etc/os-release`
- **PHP:** version and loaded extensions
- **Magento:** CLI version, deploy mode
- **Services:** MySQL/MariaDB, Valkey/Redis, Elasticsearch/OpenSearch, RabbitMQ
- **Valkey hosts:** reads `app/etc/env.php` for host:port entries
- **Valkey ping:** attempts `PING` on common ports

**Usage:**

```bash
# Remote
./run-remote.sh -p PROJECT_ID -e staging -s audit_magento_env.sh

# Local (from Magento root)
bash audit_magento_env.sh
```

---

### dump_magento_env.sh

Diff-friendly dump of environment and Magento settings as sorted key=value pairs.

**Sections:**

- Magento Root, Meta, OS, PHP configuration
- Service versions (MySQL, Valkey/Redis, RabbitMQ)
- Magento core settings (indexers, caches, consumers, config)
- Magento modules with versions
- Full `env.php` and `config.php` as flattened keys
- Composer packages

**Flags:**

| Flag | Description |
|------|-------------|
| `--root /path/to/magento` | Run from anywhere, point to Magento root |
| `--flat` | Emit only key=value lines (no section headings) |

**Examples:**

```bash
# Sectioned dump
bash dump_magento_env.sh --root /var/www/html/current > staging.txt

# Flat key/value dump for diffing
bash dump_magento_env.sh --flat --root /var/www/html/current | sort > env.kv

# Environment diff
diff -u staging.txt production.txt
```

---

### dump_database.sh

Creates a full database dump from Adobe Commerce Cloud and streams it to your local machine. Dumps are saved to the `db_dump/` folder (gitignored).

**Features:**

- Streams dump directly (no temp files on remote)
- Auto-extracts database credentials
- Removes DEFINER clauses for portability
- n98-magerun2 integration for PII stripping

**Basic Flags:**

| Flag | Description |
|------|-------------|
| `--exclude-tables TABLES` | Comma-separated tables to exclude |
| `--structure-only TABLES` | Tables to dump structure only |
| `--no-data` | Dump structure only (no data) |
| `--with-definer` | Keep DEFINER clauses |
| `--no-drop` | Don't add DROP TABLE statements |
| `-v, --verbose` | Show progress info |

**Examples:**

```bash
# Basic compressed dump
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh | gzip > db_dump/staging.sql.gz

# Verbose mode with progress
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- -v' < dump_database.sh > db_dump/dump.sql

# Exclude tables
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh -- --exclude-tables "search_query,report_event" | gzip > db_dump/staging.sql.gz
```

**n98-magerun2 Integration:**

The script auto-detects n98-magerun2 in common locations (`bin/n98`, `bin/n98-magerun2`, `vendor/bin/n98-magerun2`, etc.).

| n98 Flag | Description |
|----------|-------------|
| `--use-n98` | Use n98-magerun2 instead of mysqldump |
| `--strip GROUPS` | Strip table groups (structure only, no data) |
| `--anonymize` | Anonymize PII data (requires GDPR module) |

**Strip Groups:** `@stripped`, `@development`, `@log`, `@sessions`, `@trade`, `@customers`, `@search`, `@idx`

```bash
# Strip PII tables
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --strip "@customers @trade" -v' < dump_database.sh | gzip > db_dump/stripped.sql.gz

# Strip for development
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --strip "@development @log @sessions" -v' < dump_database.sh | gzip > db_dump/dev.sql.gz

# Anonymize + strip (full dev-safe dump)
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --anonymize --strip "@log @sessions" -v' < dump_database.sh | gzip > db_dump/dev_safe.sql.gz
```

---

### verify_dump.sh

Verifies a database dump file for integrity and completeness. Works on both macOS and Linux.

**Checks:**

- Gzip integrity (compressed files)
- File size and metadata
- CREATE TABLE count
- INSERT statement count
- Header and footer presence
- Dump completion marker

**Usage:**

```bash
# Basic verification
./verify_dump.sh db_dump/staging.sql.gz

# With expected table count
./verify_dump.sh db_dump/staging.sql.gz --expected-tables 668

# Uncompressed file
./verify_dump.sh db_dump/dump.sql
```

---

### check_log_tables.sh

Analyzes log tables, indexer cron jobs, and log cleaner configuration. Useful for SWAT report recommendations about changelog table sizes.

**Sections:**

1. Log table sizes with status indicators
2. Changelog tables (`*_cl`) for "Update by Schedule" indexers
3. `indexer_update_all_views` cron status and history
4. Indexer & mview status
5. Log cleaner configuration
6. Summary & recommendations

**Flags:**

| Flag | Description |
|------|-------------|
| `--root PATH` | Magento root directory |
| `--hours N` | Hours of cron history (default: 72) |
| `--no-sql` | Hide SQL queries from output |
| `-v, --verbose` | Verbose output |

**Status Indicators:**

| Indicator | Meaning |
|-----------|---------|
| Red circle | Critical - needs immediate attention |
| Yellow circle | Elevated - monitor closely |
| Green circle | OK - healthy |
| Check mark | Success/enabled |
| Warning | Warning |
| Lightbulb | Recommendation/tip |

**Usage:**

```bash
# Basic check
./run-remote.sh -p PROJECT_ID -e staging -s check_log_tables.sh -- -v

# Check longer history
./run-remote.sh -p PROJECT_ID -e staging -s check_log_tables.sh -- --hours 168

# Hide SQL queries
./run-remote.sh -p PROJECT_ID -e staging -s check_log_tables.sh -- --no-sql
```

---

### review_email_sending.sh

Comprehensive email sending review for Magento environments.

**Report Sections:**

1. Email disable status and kill switches
2. Email transport configuration (SendGrid, SMTP modules)
3. Async email & queue status
4. Custom modules that send email
5. Magento log analysis
6. System mail logs
7. Email templates overview
8. Recent emails sent (orders, invoices, shipments, registrations)
9. Summary & recommendations

**Flags:**

| Flag | Description |
|------|-------------|
| `--root PATH` | Magento root directory |
| `--hours N` | Time window for log analysis (default: 24) |
| `--include-vendor` | Include `vendor/` in code scan |
| `--csv-only` | Output only CSV |

**Usage:**

```bash
# Using run-remote.sh
./run-remote.sh -p PROJECT_ID -e staging -s review_email_sending.sh -- --hours 72

# Save output to file
./run-remote.sh -p PROJECT_ID -e staging -s review_email_sending.sh -o report.txt -- --hours 72
```

**Note:** On Adobe Commerce Cloud, emails go through SendGrid and are NOT logged in `/var/log/mail.log`. Check email headers for `Received: from *.smtp.magentosite.cloud` or access SendGrid dashboard.

---

### analyze_mail_logs.sh

Parse Postfix-style mail logs for delivery outcomes.

**What it collects:**

- Sources: `/var/log/mail.log*` (supports rotated `.gz`)
- Filters: `status=sent|bounced|deferred`
- CSV columns: `timestamp,recipient,status,dsn,error`

**Output:**

- CSV: `/tmp/mail_logs_scan/email_report.csv`
- Summary: `/tmp/mail_logs_scan/summary_report.txt` including:
  - Timeframe, status counts
  - Top 20 recipients
  - Error breakdown
  - DSN breakdown
  - Top 20 recipient domains
  - Hourly volume

**Usage:**

```bash
bash analyze_mail_logs.sh

# If logs are protected
sudo bash analyze_mail_logs.sh
```

---

### magento_health_check.sh

Deep, duration-based diagnostic over a recent time window (default: 72 hours).

**Checks:**

- Magento indexers status
- PHP config (memory_limit, max_execution_time)
- Magento logs (system.log, exception.log)
- PHP-FPM and NGINX logs
- MySQL slow queries and deadlocks
- Cache status
- Long-running PHP processes
- Cron processes
- Redis/Valkey reachability

**Environment Variables:**

| Variable | Description |
|----------|-------------|
| `MAGENTO_DIR` | Magento root directory |
| `CUTOFF_HOURS` | Time window (default: 72) |
| `REDIS_SOCKET` | Redis socket path |
| `REDIS_HOST` | Redis host |
| `REDIS_PORT` | Redis port |
| `REDIS_AUTH` | Redis auth password |

**Usage:**

```bash
# Set Magento root
export MAGENTO_DIR=/path/to/magento
bash magento_health_check.sh
```

---

### generate_oneview_dashboard.sh

Generates New Relic OneView dashboard JSON files for Adobe Commerce Cloud. Creates separate dashboards for Production and Staging environments based on Adobe Commerce support's OneView template.

**Features:**

- Interactive prompts with auto-detection of Project ID
- Generates production and staging dashboards
- 50+ pre-configured widgets covering infrastructure, CDN, transactions, errors
- Can run from any environment (generates both dashboards from single SSH session)

**What the dashboard includes:**

| Section | Widgets |
|---------|---------|
| Server Health | CPU, Memory, Load Average, Throughput |
| New Relic Alerts | Open alerts count and details |
| Disk Usage | Shared/Media and MySQL disk usage with trends |
| Fastly CDN | Bandwidth, content types, bot detection, large images |
| Web Requests | Cache analysis (FPC, GraphQL), HTTP status, 404s |
| Transactions | Web and non-web transaction performance |
| Errors | Top errors and exceptions |
| Traffic | DDoS detection, client IP analysis |

**Flags:**

| Flag | Description |
|------|-------------|
| `--account-id ID` | New Relic Account ID (required) |
| `--project-id ID` | Adobe Commerce Cloud Project ID (auto-detected) |
| `--prefix NAME` | Dashboard name prefix (default: project ID) |
| `--output-dir DIR` | Output directory (default: current) |
| `--non-interactive` | Skip prompts, fail if required values missing |

**Usage:**

```bash
# Interactive mode (recommended) - run on any environment
magento-cloud ssh -p PROJECT_ID -e production -- 'bash -s' < generate_oneview_dashboard.sh

# Non-interactive with all parameters
./generate_oneview_dashboard.sh --account-id 1234567 --project-id abc123xyz --prefix "MyStore"

# Run locally if you know your project ID
./generate_oneview_dashboard.sh
```

**Output:**

Two JSON files ready to import into New Relic:
- `oneview_production.json`
- `oneview_staging.json`

**How to import:**

1. Log in to New Relic
2. Go to Dashboards
3. Click "Import dashboard" (top right)
4. Paste the contents of the JSON file
5. Click "Import dashboard"

**Finding your New Relic Account ID:**

- New Relic UI: User menu > Administration > Access Management > Accounts
- Or look in any existing dashboard JSON export for `accountIds`

---

## Development & QA

```bash
# Lint Bash
shellcheck *.sh

# Format Bash
shfmt -w *.sh
```

## Operational Notes

- **Production safety:** Review before running in production. Scripts are read-only but avoid commands like `app:config:dump` which write to `app/etc/config.php`.
- **Permissions:** Ensure PATH and permissions for `systemctl`, `php`, `mysql`, `valkey-cli`/`redis-cli`, `rabbitmqctl`, `curl`.

## License

MIT
