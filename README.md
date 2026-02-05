# magento-env-scripts

Utilities to validate, inspect, and compare Adobe Commerce (Magento 2.x) environments across dev/staging/production. Scripts report OS/PHP details, service health (Valkey/Redis, Elasticsearch/OpenSearch, RabbitMQ, MySQL/MariaDB), and Magento configuration without making changes by default.

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

### Safety

Scripts are read-only unless noted. They do NOT run `app:config:dump` or modify configuration.

## Utility Scripts

### run-remote.sh

Wrapper utility for running any script on Adobe Commerce Cloud environments. Handles SSH connection and argument passing.

Usage

```bash
./run-remote.sh [OPTIONS] [-- SCRIPT_ARGS]

Options:
  --project, -p PROJECT      Magento Cloud project ID (required)
  --environment, -e ENV      Environment name (required)
  --script, -s SCRIPT        Script to run (required)
  --output, -o FILE          Save output to local file
  --verbose, -v              Show verbose output
```

Examples

```bash
# Run email review script
./run-remote.sh -p abc123xyz -e staging -s review_email_sending.sh -- --hours 72

# Run database dump and save locally
./run-remote.sh -p abc123xyz -e staging -s dump_database.sh -o db_dump/staging.sql

# Run audit script with output to file
./run-remote.sh -p abc123xyz -e staging -s audit_magento_env.sh -o audit.txt

# Compressed database dump
./run-remote.sh -p abc123xyz -e staging -s dump_database.sh | gzip > db_dump/staging.sql.gz
```

## Scripts

### audit_magento_env.sh

One-shot, human-friendly audit of the host and Magento install.

What it reports

- System: hostname, timestamp, user, `/etc/os-release`.
- PHP: version line and loaded extensions (`php -m`).
- Magento: CLI version if `bin/magento` exists.
- MySQL/MariaDB: client version (`mysql -V`).
- Valkey/Redis: CLI version (`valkey-cli` or `redis-cli`), service detection via `systemctl` with fallback to process scan, and process status summary for common services.
- Valkey hosts: reads `app/etc/env.php` to print primary/replica host:port entries.
- Valkey ping: attempts `PING` on ports 6370 and 26370 using `valkey-cli`/`redis-cli` if present.
- Search engine: detects `elasticsearch`/`opensearch` services via `systemctl`, prints state, and probes `http://localhost:9200` (if accessible) for version metadata.
- RabbitMQ: prints version from `rabbitmqctl status` if available.
- Magento basics: deploy mode and a small sample of `app/etc/config.php` for quick visibility (read-only).

Usage

- From Magento root: `bash audit_magento_env.sh`

Notes

- Service checks use `systemctl` when available and fall back to process matching (`pgrep`/`ps`) to avoid false negatives.
- If Magento paths are missing, the script still prints system/service info and clearly notes missing files/CLI.

### dump_magento_env.sh

Diff-friendly dump of environment and Magento settings as sorted key=value pairs. Emits either sectioned blocks or a flat stream.

Sections and keys

- Magento Root: `magento.root`, and presence markers for `app/etc/env.php`, `app/etc/config.php`, `composer.lock`.
- Meta: `meta.hostname`, `meta.date` (UTC ISO-8601), `meta.user`.
- OS: `os.id`, `os.version_id`, `os.name`, `os.uname`.
- PHP: `php.version`, `php.sapi`, selected `php.ini.*` keys (memory_limit, max_execution_time, upload_max_filesize, post_max_size, opcache.*) and `php.ext.*` for loaded extensions.
- Service Versions: `service.mysql.version`, `service.valkey.version` (from `valkey-cli`/`redis-cli`), `service.rabbitmq.version`.
- Magento Core: `magento.version`, `magento.mode`, plus prefixed lines for indexers (`magento.indexer.*`), cache status (`magento.cache.*`), consumers (`magento.consumer.*`), and `magento.config.*` from `bin/magento config:show`.
- Magento Modules: detects edition (`magento.edition`, `magento.edition.version`), B2B package if installed, and prints `magento.module_enabled.<Module>=<version-if-known>` by mapping to `composer.lock`.
- env.php/config.php: full flattening to `envphp.*` and `configphp.*` keys; nested arrays are JSON-encoded for values.
- Composer: `composer.<package>=<version>` from `composer.lock` (both normal and dev packages).

Flags

- `--root /path/to/magento` run from anywhere and point to a Magento root.
- `--flat` emit only key=value lines (no `### Section` headings) for easy diffing or ingestion.

Usage examples

- Sectioned dump: `bash dump_magento_env.sh --root /var/www/html/current > staging.txt`
- Flat key/value dump: `bash dump_magento_env.sh --flat --root /var/www/html/current | sort > env.kv`
- Environment diff: `diff -u staging.txt production.txt`

Notes and behavior

- Missing inputs are explicit: e.g., `envphp.missing=true`, `configphp.missing=true`, `composer.lock.missing=true`, or `.read_error=true` markers.
- `bin/magento config:show` is read-only; this script does not write to Magento configuration.

### analyze_mail_logs.sh

Parse Postfix-style mail logs for delivery outcomes and produce a CSV plus a human-readable summary.

What it collects

- Sources: all files matching `/var/log/mail.log*` (supports rotated `.gz`).
- Filters lines with `status=sent|status=bounced|status=deferred` and merges them.
- CSV columns: `timestamp,recipient,status,dsn,error`.

Outputs

- CSV: `/tmp/mail_logs_scan/email_report.csv` (append-only for this run).
- Summary: `/tmp/mail_logs_scan/summary_report.txt` including:
  - Timeframe (first/last timestamps from the CSV)
  - Status counts
  - Top 20 recipients
  - Error message breakdown with first-seen timestamp
  - DSN breakdown
  - Top 20 recipient domains
  - Hourly volume

Usage

- Run: `bash analyze_mail_logs.sh`
- If logs are protected: `sudo bash analyze_mail_logs.sh`

Configuration

- Tweak at top of script: `LOG_DIR` (default `/var/log`), `MAIL_LOG_PATTERN` (default `mail.log*`), `TMP_DIR` (default `/tmp/mail_logs_scan`).
- Script is read-only; it only reads logs and writes to `/tmp`.

### magento_health_check.sh

Deep, duration-based diagnostic for Magento and its surrounding stack over a recent time window (default last 72 hours).

Checks performed

- Magento indexers: `bin/magento indexer:status`; flags non-ready states.
- PHP config: prints `memory_limit` and `max_execution_time`, flags low values (<60M memory; <60s execution time).
- Magento logs: scans `var/log/system.log` and `var/log/exception.log` since cutoff for Errors/Exceptions/Fatal and summarizes frequent messages.
- PHP-FPM and NGINX logs: scans since cutoff for common error/timeout patterns and surfaces 503s from NGINX error logs.
- MySQL slow queries: extracts queries from the slow log since cutoff and prints them with timestamps.
- MySQL deadlocks: surfaces deadlock entries from MySQL error logs since cutoff.
- Cache status: `bin/magento cache:status`; flags disabled caches.
- Long-running PHP: lists PHP processes running >60s.
- Cron: checks that `cron` has running processes.
- Redis/Valkey: checks reachability via socket or host/port with optional `REDIS_AUTH` using `redis-cli` or `valkey-cli`.

Usage

- Set `MAGENTO_DIR` at the top of the script to your Magento root, or export before running: `export MAGENTO_DIR=/path/to/magento`.
- Optional env vars: `REDIS_SOCKET`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH`.
- Run: `bash magento_health_check.sh`

Notes

- Time window controlled by `CUTOFF_HOURS` (default 72). Adjust for broader/narrower scans.
- Requires sufficient permissions to read system logs (PHP-FPM, NGINX, MySQL). Use least privilege; escalate only if needed.
- Ends with context-aware recommendations based on observed issues.

### review_email_sending.sh

Comprehensive email sending review for Magento environments. Analyzes configuration, transport, code call-sites, logs, and recent email activity.

Report Sections

1. **Email Disable Status** - Global email kill switch and individual email type settings (order, invoice, shipment, etc.)
2. **Email Transport Configuration** - Cloud platform detection (Adobe Commerce Cloud/Platform.sh), SendGrid relay, SMTP modules
3. **Async Email & Queue Status** - Async sending config, queue consumers, recent email cron jobs
4. **Custom Modules That Send Email** - Scans `app/code` for `TransportBuilder`, `->sendMessage()`, `->getTransport()` patterns
5. **Magento Log Analysis** - Email-related entries in `system.log`, `exception.log`, `debug.log`
6. **System Mail Logs** - Postfix delivery status (sent/bounced/deferred/expired), top recipients, failures
7. **Email Templates Overview** - Custom email templates stored in database
8. **Recent Emails Sent** - Orders, invoices, shipments, customer registrations, B2B company assignments with send status
9. **Summary & Recommendations** - Consolidated findings and actionable next steps

Cloud Platform Detection

On Adobe Commerce Cloud / Platform.sh, the script automatically detects:
- Platform environment variables (`PLATFORM_PROJECT`, `MAGENTO_CLOUD_*`)
- Infrastructure-level SendGrid relay (emails routed through `*.smtp.magentosite.cloud`)
- Explains that `/var/log/mail.log` only shows local Postfix activity, not SendGrid delivery
- Provides guidance on accessing SendGrid dashboard for actual delivery status

Data Sources & Status Meanings

| Source | Table/Column | Status Values |
|--------|--------------|---------------|
| Sales Emails | `sales_order.email_sent` | 1=sent to transport, 0=not sent |
| Customer Registration | `customer_entity.confirmation` | NULL=confirmed, has value=pending |
| B2B Company Users | `company_advanced_customer_entity.status` | 0=Inactive, 1=Active |

Usage

```bash
# Using run-remote.sh (recommended)
./run-remote.sh -p PROJECT_ID -e staging -s review_email_sending.sh -- --hours 72

# Save output to file
./run-remote.sh -p PROJECT_ID -e staging -s review_email_sending.sh -o report.txt -- --hours 72

# Direct SSH
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --root /app/PROJECT_stg --hours 24' < review_email_sending.sh

# Local execution
bash review_email_sending.sh --root /path/to/magento --hours 24
```

Flags

- `--root PATH` - Magento root directory (required for remote execution)
- `--hours N` - Time window for log analysis (default: 24)
- `--include-vendor` - Include `vendor/` in code scan (default: `app/code` only)
- `--csv-only` - Output only CSV (report suppressed) for clean piping

Output

- Human-readable report to stdout with 9 sections
- CSV at `/tmp/magento_email_review/email_senders.csv` with columns: `module,file,class,method,line,pattern`

Notes

- On Adobe Commerce Cloud, customer emails go through SendGrid and are NOT logged in `/var/log/mail.log`. Only local system emails (to `root@localhost`) appear there and will show as SOFTBOUNCE (expected behavior).
- To verify actual email delivery on cloud: check email headers for `Received: from *.smtp.magentosite.cloud` or access SendGrid dashboard via Adobe Commerce Cloud Console.
- Email debugging can be enabled via: `bin/magento config:set dev/debug/debug_logging 1`
- Each run starts fresh (removes and recreates output directory).

### dump_database.sh

Creates a full database dump from Adobe Commerce Cloud and streams it to your local machine.

Features

- Streams dump directly to local (no temp files on remote)
- Auto-extracts database credentials from environment
- Removes DEFINER clauses for portability (default)
- Support for excluding tables or dumping structure-only
- Pipe-friendly output (works with gzip, pv, etc.)
- n98-magerun2 integration for PII stripping and anonymization

Usage

Dumps are saved to the `db_dump/` folder (gitignored by default).

```bash
# Using run-remote.sh (recommended)
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh -o db_dump/staging.sql

# Compressed dump
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh | gzip > db_dump/staging.sql.gz

# With progress indicator (using pv)
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh | pv > db_dump/staging.sql

# Exclude tables
./run-remote.sh -p PROJECT_ID -e staging -s dump_database.sh -- --exclude-tables "search_query,report_event" | gzip > db_dump/staging.sql.gz

# Direct SSH
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s' < dump_database.sh > db_dump/dump.sql

# Direct SSH compressed
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s' < dump_database.sh | gzip > db_dump/dump.sql.gz

# Verbose mode with progress info
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- -v' < dump_database.sh > db_dump/dump.sql

# With local transfer progress using pv
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- -v' < dump_database.sh | pv | gzip > db_dump/dump.sql.gz
```

Flags

- `--exclude-tables TABLES` - Comma-separated tables to exclude entirely
- `--structure-only TABLES` - Tables to dump structure only (no default - all data included)
- `--no-data` - Dump structure only (no data)
- `--with-definer` - Keep DEFINER clauses (default: removed)
- `--no-drop` - Don't add DROP TABLE statements
- `-v, --verbose` - Show progress info (table count, sizes, elapsed time)

n98-magerun2 Integration

The script can use n98-magerun2 for advanced features like PII stripping and anonymization.

**Auto-detection:** The script automatically searches for n98-magerun2 in these locations (in order):

| Priority | Path |
|----------|------|
| 1 | `bin/n98` |
| 2 | `bin/n98-magerun2` |
| 3 | `bin/n98-magerun2.phar` |
| 4 | `bin/magerun2` |
| 5 | `bin/magerun2.phar` |
| 6 | `vendor/bin/n98-magerun2` |
| 7 | `vendor/bin/n98-magerun2.phar` |
| 8 | `vendor/bin/magerun2` |
| 9 | Global: `n98-magerun2` |
| 10 | Global: `n98` |
| 11 | Global: `magerun2` |

**n98 Flags:**

- `--use-n98` - Use n98-magerun2 instead of mysqldump
- `--strip GROUPS` - Strip table groups (structure only, no data)
- `--anonymize` - Anonymize PII data before dump (requires GDPR module)

**Available Strip Groups:**

| Group | Description |
|-------|-------------|
| `@stripped` | Common tables to strip |
| `@development` | Development-related tables |
| `@log` | Log tables (report_event, search_query, etc.) |
| `@sessions` | Session data |
| `@trade` | Sales/quote/order data |
| `@customers` | Customer data |
| `@search` | Search indexes |
| `@idx` | Index tables |

**n98 Examples:**

```bash
# Use n98 for dump
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --use-n98 -v' < dump_database.sh | gzip > db_dump/staging.sql.gz

# Strip PII tables (customers, sales, quotes) - structure only, no data
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --strip "@customers @trade" -v' < dump_database.sh | gzip > db_dump/staging_stripped.sql.gz

# Strip for development environment
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --strip "@development @log @sessions" -v' < dump_database.sh | gzip > db_dump/dev_dump.sql.gz

# Anonymize PII data (requires GDPR module)
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --anonymize -v' < dump_database.sh | gzip > db_dump/anon_dump.sql.gz

# Anonymize + strip logs (full dev-safe dump)
magento-cloud ssh -p PROJECT_ID -e staging -- 'bash -s -- --anonymize --strip "@log @sessions" -v' < dump_database.sh | gzip > db_dump/dev_safe_dump.sql.gz
```

**Anonymization Requirements:**

The `--anonymize` flag requires a GDPR module installed with n98-magerun2:
- `netz98/magerun2-password-normalizer`
- `elgentos/masquerade`
- `iMi/magerun2-gdpr-dump`

Check available modules: `bin/n98 list | grep -i gdpr`

Notes

- Requires `magento-cloud` CLI installed and authenticated
- Large databases may take significant time; consider `--strip` or `--structure-only` for big tables
- By default, ALL data is included. Use `--strip` or `--structure-only` to reduce dump size
- Use `verify_dump.sh` to validate the dump after completion

### verify_dump.sh

Verifies a database dump file for integrity and completeness. Works on both macOS and Linux with `.sql` and `.sql.gz` files.

Checks performed

- Gzip integrity (for compressed files)
- File size and metadata
- CREATE TABLE count
- INSERT statement count
- Header and footer presence
- Dump completion marker

Usage

```bash
# Basic verification
./verify_dump.sh db_dump/staging.sql.gz

# With expected table count
./verify_dump.sh db_dump/staging.sql.gz --expected-tables 668

# Uncompressed file
./verify_dump.sh db_dump/dump.sql
```

Output

```
============================================================
DATABASE DUMP VERIFICATION
============================================================

File: db_dump/staging.sql.gz
Date: 2026-02-05 12:30:45

------------------------------------------------------------
6. VERIFICATION SUMMARY
------------------------------------------------------------

   [OK] Header present
   [OK] Footer present (dump completed)
   [OK] Table count matches expected (668/668)
   [OK] Data found: 125432 INSERT statements
   [OK] File has content (1542.50 MB uncompressed)

============================================================
RESULT: DUMP LOOKS GOOD
============================================================
```

## Development & QA

- Lint Bash: `shellcheck <script>.sh` (fix all errors; justify warnings inline if needed).
- Format Bash: `shfmt -w <script>.sh` (2 spaces, no tabs).
- Manual smoke test: in a dev environment run from Magento root, e.g. `cd /path/to/magento && bash /path/to/repo/audit_magento_env.sh`.

## Operational Notes

- Production safety: Review before running in production. Magento CLI operations used here are read-only (e.g., `config:show`), but avoid commands like `app:config:dump` in production as they write to `app/etc/config.php`.
- Services and permissions: Ensure PATH and permissions for `systemctl`, `php`, `mysql`, `valkey-cli`/`redis-cli`, `rabbitmqctl`, `curl`. Some checks may not report without appropriate access.

## License

MIT — see `LICENSE`.
