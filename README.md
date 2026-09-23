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
| [`offboarding_commerce_user.sh`](#offboarding_commerce_usersh) | Offboard a user from all Commerce Cloud projects and admin panels |
| [`check_stylesmuggler.sh`](#check_stylesmugglersh) | Check an environment for StyleSmuggler (Sansec) compromise indicators |

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

- Auto-detects Project ID on Adobe Commerce Cloud environments
- Outputs JSON to stdout for easy local file saving
- 50+ pre-configured widgets covering infrastructure, CDN, transactions, errors

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
| Database | Query time, slow queries, DB call counts, high-DB transactions |
| Redis/Valkey | Operation time, call rate, throughput by operation |
| Elasticsearch | Query time, call rate, latency distribution |
| PHP-FPM | Memory usage, CPU, process count, duration distribution |
| Cron & Queues | Job duration, throughput, top cron jobs, message consumers |
| Application | Apdex score, response percentiles, error rate, external services |

**Flags:**

| Flag | Description |
|------|-------------|
| `--account-id ID` | New Relic Account ID (required) |
| `--project-id ID` | Adobe Commerce Cloud Project ID (auto-detected on cloud) |
| `--env ENV` | Generate single dashboard (`production` or `staging`) to stdout |
| `--prefix NAME` | Dashboard name prefix (default: project ID) |
| `--output-dir DIR` | Output directory when not using `--env` (default: /tmp on cloud) |

**Usage:**

```bash
# Generate production dashboard via SSH (auto-detects project ID)
magento-cloud ssh -p PROJECT_ID -e production -- 'bash -s -- --account-id 1234567 --env production' < generate_oneview_dashboard.sh > oneview_PROJECT_ID_production.json

# Generate staging dashboard via SSH (auto-detects project ID)
magento-cloud ssh -p PROJECT_ID -e production -- 'bash -s -- --account-id 1234567 --env staging' < generate_oneview_dashboard.sh > oneview_PROJECT_ID_staging.json

# Generate both dashboards locally (outputs oneview_<project-id>_production.json and oneview_<project-id>_staging.json)
./generate_oneview_dashboard.sh --account-id 1234567 --project-id abc123xyz
```

**How to import into New Relic:**

1. Log in to New Relic
2. Go to Dashboards
3. Click "Import dashboard" (top right)
4. Paste the contents of the JSON file
5. Click "Import dashboard"

**Finding your New Relic Account ID:**

- New Relic UI: User menu > Administration > Access Management > Accounts
- Or look in any existing dashboard JSON export for `accountIds`

---

### offboarding_commerce_user.sh

Scans all Adobe Commerce Cloud projects for a user's cloud platform access and admin panel accounts across production and staging environments, then removes/disables them after confirmation.

Two independent axes control what happens: `--scope` picks which access is touched, `--admin-action` picks what happens to admin panel accounts.

Cloud platform access is removed entirely via `magento-cloud user:delete`. **That call is what revokes SSH and Git access** to a project — Cloud SSH access is derived from project user membership, so removing the admin panel account alone leaves SSH intact. Use `--scope admin` when that is deliberate, and `--scope cloud` to revoke SSH/Git without touching the admin panel.

By default admin accounts are disabled (`is_active = 0`) rather than deleted, to preserve audit trails and avoid foreign key issues.

**What it does:**

1. Fetches all projects from `magento-cloud project:list`
2. Scans projects in parallel (up to 5 concurrent) for cloud platform access and admin accounts (surfaces excluded by `--scope` are not scanned)
3. SSHs into each production/staging environment and queries `admin_user` table for the target email
4. Displays a tabular scan report with results across all projects
5. Prompts for confirmation before making any changes
6. Applies the requested changes
7. Displays a final report with success/failure counts
8. Writes a persistent audit log to `offboarding_logs/`

**Flags:**

| Flag | Description |
|------|-------------|
| `--email EMAIL` | Email address of the user to offboard (required) |
| `--scope SCOPE` | `all` (default), `admin` (admin panel only, SSH/cloud untouched), or `cloud` (SSH/cloud only, admin untouched) |
| `--admin-action ACT` | `disable` (default), `delete`, or `password` |
| `--scan-only` | Scan and report only; do not make any changes |
| `--project ID` | Limit scan to a single project by its ID |

**Admin actions:**

| Action | Effect |
|--------|--------|
| `disable` | Sets `is_active = 0`. Account and audit trail are kept. Skipped if already inactive. |
| `delete` | Removes the `admin_user` row. Irreversible; child rows go with it via `ON DELETE CASCADE`. Runs regardless of `is_active`. |
| `password` | Rotates to a random 28-character password, **leaving the account active**. A distinct password per environment is printed once at the end and never written to the audit log. Useful for shared or service accounts, not for locking someone out. |

All three actions also delete the user's `admin_user_session` rows, so a live admin session is terminated rather than just future logins blocked. `password` additionally clears `rp_token` / `rp_token_created_at` so a pending password-reset email cannot be used.

The `password` action bootstraps Magento on the remote environment to hash via the installed `EncryptorInterface`, which keeps the hash format (salt and version, e.g. argon2id vs sha256) correct for that release.

**Usage:**

```bash
# Full offboard (scan + remove/disable with confirmation)
./offboarding_commerce_user.sh --email user@example.com

# Audit only (no changes made)
./offboarding_commerce_user.sh --email user@example.com --scan-only

# Admin panel only -- SSH/cloud access left alone
./offboarding_commerce_user.sh --email user@example.com --scope admin

# Delete the admin account only
./offboarding_commerce_user.sh --email user@example.com --scope admin --admin-action delete

# Rotate the admin password only (account stays active)
./offboarding_commerce_user.sh --email user@example.com --scope admin --admin-action password

# Revoke SSH/cloud access only -- admin account left alone
./offboarding_commerce_user.sh --email user@example.com --scope cloud

# Target a specific project
./offboarding_commerce_user.sh --email user@example.com --project abc123xyz

# Scan a specific project only (no changes)
./offboarding_commerce_user.sh --email user@example.com --scan-only --project abc123xyz
```

**Not covered:** only `production` and `staging` environments are scanned for admin accounts, so admin accounts on integration branches are untouched (cloud access removal is project-wide and unaffected). API integration tokens and `oauth_token` rows are not revoked, and access outside the Cloud project — Adobe IMS / Admin Console, New Relic, Fastly — is out of scope.

**Requirements:**

- `magento-cloud` CLI installed and authenticated (`magento-cloud auth:login`)
- SSH access to the project environments being scanned
- Sufficient permissions to list users and delete access on each project

**Audit Log:**

Each run creates a timestamped log file in `offboarding_logs/` (gitignored) with:

- Timestamp, target email, operator, mode, scope, and admin action
- Full scan report table (plain text, no ANSI colors)
- Actions taken with success/failure status
- Final summary

Log filename format: `offboard_<email>_<YYYYMMDD_HHMMSS>.log`

**Scan Report Example:**

The script outputs a table showing cloud access and admin account status per project:

```
  Project                              Cloud Access    Environment     Admin Account
  -----------------------------------  --------------  --------------  ------------------------------
  My Store Production                  found           production      admin.user [active]
                                                       staging         admin.user [active]
  Another Project                      not found       production      not found
                                                       staging         not found
```

---

### check_stylesmuggler.sh

Checks whether an environment shows indicators of compromise from the **StyleSmuggler** campaign disclosed by Sansec ([research writeup](https://sansec.io/research/stylesmuggler)).

StyleSmuggler is an unauthenticated RCE reached through the GraphQL endpoint via a crafted `styles` parameter. It injects PHP into Magento's template system, which executes when a "Payment Transaction Failed" notification email renders. The resulting implant persists via cron and masquerades as `gvfsd`, `fc-cache` and kernel `kworker` processes. All current versions were affected at disclosure, including 2.4.9, 2.4.8, 2.4.7 and 2.4.6-p15.

**Read-only.** The script writes nothing to the environment: no files, no temp files, no report on disk, no processes killed, and every database statement runs inside a read-only session. Findings go to stdout — redirect locally to keep a copy. The only outbound action is a single `{__typename}` POST to the store's own GraphQL endpoint to test whether the attack surface is exposed; that request appears in the store's access log.

Every section prints the commands, paths and patterns it uses *before* its result, so a clean report is auditable rather than a bare `[OK]`. The header records the project, environment, Magento version and edition, patch package versions, and the newest hotfix in `m2-hotfixes/` with its date.

**What it checks:**

- **Edge mitigation:** whether the StyleSmuggler vector is actually blocked. Adobe pushes its emergency rules (published as the `accord_rce` snippet) **straight to the Fastly service, leaving no file on disk**, so a filesystem check alone will wrongly report an protected store as unprotected. The scanner therefore probes the live edge with four harmless canary requests — `styles[]` in the query string, an encoded `<?`, a `{{block}}` directive in a text parameter, and the same directive in a POST body to `/graphql` — and confirms the mitigation only if they are rejected while normal traffic still returns 200. Local `var/vcl_snippets_custom/` snippets, nginx/Apache rules and `m2-hotfixes/` patches are judged **on rule content, not snippet name**, so a renamed or locally authored equivalent still counts and a snippet for an older bulletin does not
- **Persistence:** user and system crontabs, `/etc/cron.*`, shell profiles, systemd user units, and `.magento.app.yaml` cron definitions
- **Drop locations:** `~/.local/share/.gvfsd/`, `~/.cache/fontconfig/fc-cache`, `/tmp/.kw_*`, `/tmp/.cache_*`, `/tmp/.fc-*/fc-cache`, `/tmp/.fc_*.lock` and variants under `/var/tmp` and `/dev/shm`
- **Binary hashes:** SHA256 of any candidate file against the four published implant hashes
- **Processes:** kworker impersonation (verified via PPID and `/proc/<pid>/exe`, so real kernel threads are not flagged), `fc-cache` running from an unexpected path, `gvfsd-user`, and processes running from deleted binaries
- **Network:** live connections to the published C2 addresses, NTP-shaped UDP/123 traffic from non-NTP processes, and C2 hosts pinned in `/etc/hosts`
- **Magento artefacts:** the `x_trace_` exploitation marker in `var/report/` and `var/log/`
- **Web logs:** exploit-shaped `graphql?styles[...]` and `paypal/transparent/response` requests, plus requests from the known attacker IP
- **Mail volume:** delivered-message counts per day, since stage two requires a burst of failed-payment notifications
- **Codebase:** C2 hostnames or IPs embedded in `app/`, `pub/`, `var/`, `lib/` (and `vendor/`, `generated/` with `--deep`)
- **Webshells:** executable PHP under `pub/media`, `pub/static`, `var/*`, recently modified PHP carrying payload signatures, and drift against git HEAD
- **Database** (`--db`): payload signatures in email templates, `core_config_data`, CMS blocks and pages, and layout updates; admin accounts and integrations created recently

**Usage:**

```bash
bash check_stylesmuggler.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `--root PATH` | Magento root directory (default: auto-detect) |
| `--db` | Also run read-only database checks (templates, CMS, config, admins) |
| `--deep` | Wider sweep: includes `vendor/`, `generated/` and a filesystem-wide filename search |
| `--days N` | Window for "recently modified" and "recently created" checks (default: 30) |
| `--log PATH` | Additional access log file or glob to scan (repeatable) |
| `--label NAME` | Human-readable project name for the report header |
| `--no-probe` | Send no outbound requests; disables the edge probe and GraphQL check |
| `--no-color` | Disable ANSI colour |

> **Note on `--root`:** `run-remote.sh` guesses `/app/<project>_<env>`, which does not exist on Cloud Pro — the real root is `/app/<project>`. The scanner validates any supplied `--root` and falls back to auto-detection (via `$MAGENTO_CLOUD_DIR`, `$HOME`, then `/app/*`) when it holds no install, reporting the substitution in the header. Without that guard every application-level check silently skips while the scan still reports success.

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | No indicators found |
| `1` | No confirmed IOCs, but warnings need review |
| `2` | Compromise indicators present |
| `3` | Usage or environment error |

**Examples:**

```bash
# Check production
./run-remote.sh -p PROJECT_ID -e production -s check_stylesmuggler.sh

# Include database checks and keep a local copy
./run-remote.sh -p PROJECT_ID -e production -s check_stylesmuggler.sh -o stylesmuggler_prod.txt -- --db

# Local, from the Magento root, with the widest sweep
bash check_stylesmuggler.sh --db --deep --days 60

# Point at access logs the script cannot auto-discover
bash check_stylesmuggler.sh --log '/var/log/platform/*/access.log*'
```

**Scanning every project's production environment:**

```bash
magento-cloud project:list --format=plain --no-header --columns=id,title | while IFS=$'\t' read -r proj title; do
  env=$(magento-cloud environment:list -p "$proj" --type=production \
        --format=plain --no-header --columns=id 2>/dev/null | head -n1)
  [ -n "$env" ] || { echo "SKIP  $proj (no production environment)"; continue; }

  ./run-remote.sh -p "$proj" -e "$env" -s check_stylesmuggler.sh \
    -o "stylesmuggler_${proj}_${env}.txt" -- --db --label "$title"
  case $? in
    0) echo "CLEAN       $proj / $env" ;;
    1) echo "REVIEW      $proj / $env  -> stylesmuggler_${proj}_${env}.txt" ;;
    2) echo "COMPROMISED $proj / $env  -> stylesmuggler_${proj}_${env}.txt" ;;
    *) echo "ERROR       $proj / $env" ;;
  esac
done
```

Run serially as written: each scan takes a minute or two, and `--db` opens a connection to the production database. `--label` puts the human-readable project name in each report header.

The scanner deliberately does not call `ece-patches status` or `magento-patches status` — both prompt for a patch provider and category, so they hang when driven over a non-interactive SSH pipe. Patch state is read from `m2-hotfixes/` and `composer.lock` instead.

Run it on every environment, not just production — integration and staging share the same exposure. A clean result means none of the published indicators are present right now; it is not proof of safety, since log retention may be shorter than the exposure window and the implant can be updated. Apply Adobe's patch and restrict the GraphQL endpoint at the edge regardless of the outcome.

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
