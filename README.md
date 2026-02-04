# magento-env-scripts

Utilities to validate, inspect, and compare Adobe Commerce (Magento 2.x) environments across dev/staging/production. Scripts report OS/PHP details, service health (Valkey/Redis, Elasticsearch/OpenSearch, RabbitMQ, MySQL/MariaDB), and Magento configuration without making changes by default.

## Getting Started

- Run from a Magento project root so `bin/magento` and `app/etc/env.php` resolve. For dumps, you can also pass `--root`.
- Requirements vary by script: `bash`, `php`, access to system logs and CLIs (`mysql`, `valkey-cli`/`redis-cli`, `rabbitmqctl`, `curl`, `systemctl`).
- Safety: Scripts are read-only unless noted. They do NOT run `app:config:dump`.

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

Usage (local)

```bash
bash review_email_sending.sh --root /path/to/magento --hours 24
```

Usage (remote via magento-cloud SSH)

Run from your local machine and stream output directly:

```bash
# Full report to terminal
magento-cloud ssh --project PROJECT_ID --environment ENV -- \
  'bash -s -- --root /app/PROJECT_ENV --hours 24' < review_email_sending.sh

# Full report saved to file
magento-cloud ssh --project PROJECT_ID --environment ENV -- \
  'bash -s -- --root /app/PROJECT_ENV --hours 72' < review_email_sending.sh > report.txt 2>&1

# CSV only (report suppressed)
magento-cloud ssh --project PROJECT_ID --environment ENV -- \
  'bash -s -- --root /app/PROJECT_ENV --hours 24 --csv-only' < review_email_sending.sh > email_senders.csv
```

Replace `PROJECT_ID` with your project ID, `ENV` with environment (e.g., `staging`, `production`), and `PROJECT_ENV` with the Magento root path (typically `PROJECT_ID_ENV`, e.g., `abc123xyz_stg`).

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

## Development & QA

- Lint Bash: `shellcheck <script>.sh` (fix all errors; justify warnings inline if needed).
- Format Bash: `shfmt -w <script>.sh` (2 spaces, no tabs).
- Manual smoke test: in a dev environment run from Magento root, e.g. `cd /path/to/magento && bash /path/to/repo/audit_magento_env.sh`.

## Operational Notes

- Production safety: Review before running in production. Magento CLI operations used here are read-only (e.g., `config:show`), but avoid commands like `app:config:dump` in production as they write to `app/etc/config.php`.
- Services and permissions: Ensure PATH and permissions for `systemctl`, `php`, `mysql`, `valkey-cli`/`redis-cli`, `rabbitmqctl`, `curl`. Some checks may not report without appropriate access.

## License

MIT — see `LICENSE`.
