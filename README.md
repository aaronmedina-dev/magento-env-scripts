# magento-env-scripts
Tools to validate, inspect, and compare Adobe Commerce (Magento 2.x) environments (staging, production). Includes checks for OS/PHP, Valkey/Redis, Elasticsearch/OpenSearch, RabbitMQ, MySQL/MariaDB, and Magento configuration.

## Scripts

- audit_magento_env.sh
  - One-shot readable audit of the host and Magento install.
  - Detects versions, service status (systemd + process fallback), Magento mode, indexers/cache/consumers, and selected config samples.
  - Read-only: does NOT run `app:config:dump`.

- dump_magento_env.sh
  - Diff-friendly, sectioned or flat key=value dump of environment and Magento settings.
  - Sections: Meta, OS, PHP (ini/ext), Service Versions, Magento Core, Magento Modules, env.php, config.php, Composer.
  - Flags:
    - `--root /path/to/magento` run from anywhere (points to Magento root)
    - `--flat` emit only key=value lines (best for diffs)

## Usage

- Audit (run from Magento root for full output):
  - `bash audit_magento_env.sh`

- Dump and compare Staging vs Production:
  - `bash dump_magento_env.sh --root /var/www/html/current > staging.txt`
  - `bash dump_magento_env.sh --root /var/www/html/current > production.txt`
  - `diff -u staging.txt production.txt`
  - Flat mode: `bash dump_magento_env.sh --flat --root /var/www/html/current | sort > env.kv`

## Notes

- Valkey/Redis: script lists systemd units when available and falls back to process detection (pgrep/ps) to avoid false “inactive”.
- Elasticsearch/OpenSearch: guarded checks; HTTP probe on `localhost:9200` if accessible.
- Magento Modules: reads enabled modules from `app/etc/config.php` and versions from `composer.lock`; third‑party modules may not map 1:1 to package names.
- Missing sections print explicit markers (e.g., `envphp.missing=true`, `configphp.read_error=true`, `composer.lock.missing=true`). Use `--root` if running outside the Magento directory.

## Contributing

See `AGENTS.md` for style, testing, and PR guidelines.
