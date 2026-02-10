#!/usr/bin/env bash
set -Eeuo pipefail

#===============================================================================
# generate_oneview_dashboard.sh
# Generates New Relic OneView dashboard JSON files for Adobe Commerce Cloud
# Creates separate dashboards for Production and Staging environments
#===============================================================================

# Colors for output (sent to stderr so JSON can be piped)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
OUTPUT_DIR=""  # Will be set based on environment
ACCOUNT_ID=""
PROJECT_ID=""
DASHBOARD_PREFIX=""
TARGET_ENV=""  # If set, output single dashboard to stdout

#-------------------------------------------------------------------------------
# Helper functions
#-------------------------------------------------------------------------------

print_header() {
  echo -e "${BLUE}============================================================${NC}" >&2
  echo -e "${BLUE}$1${NC}" >&2
  echo -e "${BLUE}============================================================${NC}" >&2
}

print_info() {
  echo -e "${GREEN}[INFO]${NC} $1" >&2
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --account-id ID [OPTIONS]

Generates New Relic OneView dashboard JSON files for Adobe Commerce Cloud.
Creates separate dashboards for Production and Staging environments.

Required:
  --account-id ID       New Relic Account ID (find in New Relic > Administration > Access Management)

Options:
  --project-id ID       Adobe Commerce Cloud Project ID (auto-detected on cloud environments)
  --prefix NAME         Dashboard name prefix (default: project ID)
  --env ENV             Generate single dashboard (production|staging) and output JSON to stdout
  --output-dir DIR      Output directory for JSON files (default: /tmp on cloud, . locally)
  -h, --help            Show this help message

Examples:
  # Generate production dashboard via SSH (auto-detects project ID)
  magento-cloud ssh -p PROJECT_ID -e production -- 'bash -s -- --account-id 1234567 --env production' < $(basename "$0") > oneview_PROJECT_ID_production.json

  # Generate staging dashboard via SSH (auto-detects project ID)
  magento-cloud ssh -p PROJECT_ID -e production -- 'bash -s -- --account-id 1234567 --env staging' < $(basename "$0") > oneview_PROJECT_ID_staging.json

  # Generate both dashboards locally (outputs oneview_<project-id>_production.json and oneview_<project-id>_staging.json)
  $(basename "$0") --account-id 1234567 --project-id abc123xyz

Finding your New Relic Account ID:
  1. Log in to New Relic
  2. Click your name (bottom-left) > Administration > Access Management
  3. Account ID is shown in the Accounts list
  Or: Look in any existing dashboard JSON export for 'accountIds'
EOF
}

#-------------------------------------------------------------------------------
# Parse command line arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --account-id)
      ACCOUNT_ID="$2"
      shift 2
      ;;
    --project-id)
      PROJECT_ID="$2"
      shift 2
      ;;
    --prefix)
      DASHBOARD_PREFIX="$2"
      shift 2
      ;;
    --env)
      TARGET_ENV="$2"
      if [[ "$TARGET_ENV" != "production" && "$TARGET_ENV" != "staging" ]]; then
        print_error "--env must be 'production' or 'staging'"
        exit 1
      fi
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
  esac
done

#-------------------------------------------------------------------------------
# Main script
#-------------------------------------------------------------------------------

print_header "New Relic OneView Dashboard Generator"
echo "" >&2
echo "This script generates New Relic dashboard JSON files for:" >&2
echo "  - Production environment" >&2
echo "  - Staging environment" >&2
echo "" >&2

# Step 1: Validate Account ID (required)
if [[ -z "$ACCOUNT_ID" ]]; then
  print_error "New Relic Account ID is required. Use --account-id ID"
  echo "" >&2
  show_usage
  exit 1
fi

if ! [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  print_error "Account ID must be a number. Got: $ACCOUNT_ID"
  exit 1
fi

print_info "Using Account ID: $ACCOUNT_ID"

# Step 2: Get Project ID (auto-detect or from argument)
if [[ -z "$PROJECT_ID" ]]; then
  if [[ -n "${MAGENTO_CLOUD_PROJECT:-}" ]]; then
    PROJECT_ID="$MAGENTO_CLOUD_PROJECT"
    print_info "Auto-detected Project ID: $PROJECT_ID"
  else
    print_error "Project ID is required. Use --project-id ID or run on Adobe Commerce Cloud environment."
    exit 1
  fi
else
  print_info "Using Project ID: $PROJECT_ID"
fi

# Step 3: Dashboard name prefix (defaults to project ID)
if [[ -z "$DASHBOARD_PREFIX" ]]; then
  DASHBOARD_PREFIX="$PROJECT_ID"
fi

print_info "Using Dashboard Prefix: $DASHBOARD_PREFIX"

# Step 4: Set output directory (default to /tmp on cloud, current dir locally)
if [[ -z "$OUTPUT_DIR" ]]; then
  if [[ -n "${MAGENTO_CLOUD_PROJECT:-}" ]]; then
    OUTPUT_DIR="/tmp"
    print_info "Using output directory: $OUTPUT_DIR (cloud environment)"
  else
    OUTPUT_DIR="."
  fi
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  print_info "Created output directory: $OUTPUT_DIR"
fi

#-------------------------------------------------------------------------------
# Generate dashboard JSON
#-------------------------------------------------------------------------------

generate_dashboard() {
  local env_type="$1"  # "production" or "staging"
  local output_file="$2"

  # Set environment-specific values
  local env_display=""
  local env_tag=""
  local apm_filter=""
  local app_filter=""
  local project_filter=""

  if [[ "$env_type" == "production" ]]; then
    env_display="Production"
    env_tag="production"
    apm_filter="apmApplicationNames NOT LIKE '%_stg%'"
    app_filter="appName NOT LIKE '%_stg%'"
    project_filter="project_id NOT LIKE '%_stg%'"
  else
    env_display="Staging"
    env_tag="staging"
    apm_filter="apmApplicationNames LIKE '%_stg%'"
    app_filter="appName LIKE '%_stg%'"
    project_filter="project_id LIKE '%_stg%'"
  fi

  # Write template with placeholders (using quoted heredoc to prevent expansion)
  cat > "$output_file" <<'DASHBOARD_TEMPLATE'
{
  "name": "OneView 1.9 - __DASHBOARD_PREFIX__ (__ENV_DISPLAY__)",
  "description": "Adobe Commerce Cloud OneView Dashboard for __ENV_DISPLAY__ environment. Generated for project: __PROJECT_ID__",
  "permissions": "PUBLIC_READ_WRITE",
  "pages": [
    {
      "name": "OneView",
      "description": null,
      "widgets": [
        {
          "title": "",
          "layout": { "column": 1, "row": 1, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Server health\n---\n# Infrastructure Performance - __ENV_DISPLAY__"
          }
        },
        {
          "title": "Open New Relic Alerts",
          "layout": { "column": 1, "row": 2, "width": 2, "height": 2 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.billboard" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(conditionName) as 'Open NR Alerts' FROM NrAiIncident where event ='open' and tags.ADBE_Environment = '__ENV_TAG__' since 24 hours ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": true },
            "thresholds": [{ "alertSeverity": "CRITICAL", "value": 1 }]
          }
        },
        {
          "title": "[NR Alerts] Currently Open Alert Conditions and Issues",
          "layout": { "column": 3, "row": 2, "width": 10, "height": 2 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT conditionName, event, timestamp, priority FROM NrAiIncident where event ='open' and tags.ADBE_Environment = '__ENV_TAG__' since 24 hours ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": true }
          }
        },
        {
          "title": "CPU Usage (%)",
          "layout": { "column": 1, "row": 4, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(cpuPercent) FROM SystemSample TIMESERIES FACET hostname WHERE (__APM_FILTER__ AND apmApplicationNames IS NOT NULL) limit 100 since 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "Load Average (Number)",
          "layout": { "column": 5, "row": 4, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(loadAverageFiveMinute) FROM SystemSample TIMESERIES FACET hostname WHERE (__APM_FILTER__ AND apmApplicationNames IS NOT NULL) limit 100 since 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "Memory Usage (%)",
          "layout": { "column": 9, "row": 4, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(memoryUsedPercent OR memoryUsedBytes/memoryTotalBytes*100) FROM SystemSample TIMESERIES FACET hostname WHERE (__APM_FILTER__ AND apmApplicationNames IS NOT NULL) limit 100 since 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "Throughput (RPM)",
          "layout": { "column": 1, "row": 7, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.transaction.duration), 1 minute) as 'Web throughput' FROM Metric WHERE (__APP_FILTER__ and appName NOT LIKE '%mymagento%') AND (transactionType = 'Web') SINCE 1 week AGO TIMESERIES max"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "Web transactions time (Milliseconds)",
          "layout": { "column": 5, "row": 7, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.area" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.overview.web) * 1000 FROM Metric WHERE (__APP_FILTER__) FACET `segmentName` SINCE 604800 seconds AGO TIMESERIES"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Memory Usage (GB)",
          "layout": { "column": 9, "row": 7, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.bar" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(memoryResidentSizeBytes) FROM ProcessSample FACET processDisplayName WHERE (__APM_FILTER__ AND apmApplicationNames IS NOT NULL) limit 10 since 60 minutes ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 10, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "# Disk Usage (Approximate)\n## We recommend maintaining the disk usage at least below 70%"
          }
        },
        {
          "title": "Shared/Media Disk Usage",
          "layout": { "column": 1, "row": 11, "width": 2, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.billboard" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT string(latest(diskTotalBytes)/1024/1024/1024,1) as 'Size (GB)', string(latest(diskUsedBytes)/1024/1024/1024,1) as 'Used (GB)', string(latest(diskFreeBytes)/1024/1024/1024,1) as 'Available (GB)', latest(diskUsedPercent) as 'Used %' FROM StorageSample WHERE (entityAndMountPoint like '%/mnt/shared%') AND __APM_FILTER__ AND apmApplicationNames IS NOT NULL LIMIT 100 SINCE 5 minutes ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "DB Disk Usage",
          "layout": { "column": 3, "row": 11, "width": 2, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.billboard" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT string(latest(diskTotalBytes)/1024/1024/1024,1) as 'Size (GB)', string(latest(diskUsedBytes)/1024/1024/1024,1) as 'Used (GB)', string(latest(diskFreeBytes)/1024/1024/1024,1) as 'Available (GB)', latest(diskUsedPercent) as 'Used %' FROM StorageSample WHERE entityAndMountPoint like '%/data/mysql' and __APM_FILTER__ LIMIT 100 SINCE 5 minutes ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Shared Files Disk Usage Past Year (%)",
          "layout": { "column": 5, "row": 11, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(diskUsedPercent) as 'Percentage %' FROM StorageSample WHERE (entityAndMountPoint like '%/mnt/shared%') AND __APM_FILTER__ LIMIT 100 timeseries since 365 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "MYSQL Disk Usage Past Year (%)",
          "layout": { "column": 9, "row": 11, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(diskUsedPercent) FROM StorageSample WHERE entityAndMountPoint like '%/data/mysql' and __APM_FILTER__ LIMIT 100 SINCE 365 days ago TIMESERIES"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true },
            "yAxisRight": { "zero": true }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 14, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "\n# Content Delivery Network (Fastly CDN) Stats\n### VALID only for the Last **30 DAYS**"
          }
        },
        {
          "title": "Total CDN Usage for Time Period",
          "layout": { "column": 1, "row": 15, "width": 2, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.billboard" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) as 'CDN usage' FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL SINCE 30 day ago UNTIL today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "CDN Bandwidth Usage By Content Type",
          "layout": { "column": 3, "row": 15, "width": 4, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL TIMESERIES FACET content_type SINCE 30 day ago UNTIL today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "CDN Bandwidth Usage Summary",
          "layout": { "column": 7, "row": 15, "width": 4, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) as 'CDN usage by Content Type' FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET content_type SINCE 30 day ago UNTIL today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Number of Requests By Type",
          "layout": { "column": 11, "row": 15, "width": 2, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) as `Request Count` FROM Log WHERE __PROJECT_FILTER__ AND `cache_status` IS NOT NULL and content_type is not null and content_type != '' FACET content_type SINCE 30 day ago UNTIL today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "CDN Usage by Request User Agent",
          "layout": { "column": 1, "row": 19, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET request_user_agent SINCE 30 day ago limit 15 until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Possible Bot/Crawler Presence",
          "layout": { "column": 5, "row": 19, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) as 'Possible Bot/Crawler Activity' FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET cases( where request_user_agent like '%bot%' as 'Has word *BOT*', where request_user_agent like '%crawl%' as 'Has word *CRAWL*') SINCE 30 day ago until today limit 15"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Largest Images Served (MB) - top 200",
          "layout": { "column": 9, "row": 19, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT max(numeric(resp_body_size))/1000/1000 as 'Image Size (MB)' FROM Log WHERE cache_status IS NOT NULL and __PROJECT_FILTER__ and `content_type` LIKE '%image%' and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET url SINCE 30 day ago UNTIL today limit 200"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 22, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Web Requests (Document HTML/GraphQL/REST API)\n---\n# Cache and Usage Analysis"
          }
        },
        {
          "title": "Web Requests By Type (Other = text/html pages)",
          "layout": { "column": 1, "row": 23, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%' or url LIKE '%graphql%' or url like '%rest%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' facet cases (where url like '%rest%', where url like '%graphql%') SINCE 30 days ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Full-Page Cache (only for Default Theming Approach)",
          "layout": { "column": 5, "row": 23, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' FACET cache_status SINCE 30 days ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "GraphQL Caching (PWA/Headless only)",
          "layout": { "column": 9, "row": 23, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (url LIKE '%graphql%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' FACET cache_status SINCE 30 days ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Web Requests - By Response HTTP Status",
          "layout": { "column": 1, "row": 26, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%' or url LIKE '%graphql%' or url like '%rest%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' FACET status SINCE 30 days ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Full-Page Cache Trend (only for Default Theming approach)",
          "layout": { "column": 5, "row": 26, "width": 4, "height": 2 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.area" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' TIMESERIES FACET cache_status SINCE 30 day ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "GraphQL Caching Trend (PWA/Headless only)",
          "layout": { "column": 9, "row": 26, "width": 4, "height": 2 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (url LIKE '%graphql%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' FACET cache_status SINCE 30 days ago until today TIMESERIES"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Latest 404 (Not Found) Requests - top 200",
          "layout": { "column": 5, "row": 28, "width": 4, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT latest(url), latest(status), latest(geo_country_code), latest(request_user_agent) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%' or url LIKE '%graphql%' or url like '%rest%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' and status = '404' facet url SINCE 30 days ago until today order by timestamp desc limit 200"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Largest Response Body Size (MB) - top 200",
          "layout": { "column": 9, "row": 28, "width": 4, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT max(numeric(resp_body_size))/1000/1000 as 'Response Size (MB)' FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%' or url LIKE '%graphql%' or url like '%rest%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' and url not like '%admin%' facet url SINCE 30 days ago until today limit 200"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Web Requests - By Country",
          "layout": { "column": 1, "row": 29, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Log WHERE cache_status IS NOT NULL AND __PROJECT_FILTER__ AND (content_type LIKE 'text/html;%' or url LIKE '%graphql%' or url like '%rest%') AND url not like '%static/version%' AND url not like '%magento_version%' AND url not like '%fastlyCdn%' AND url NOT LIKE '%.css%' AND url NOT LIKE '%.js%' AND url not like '%jpg%' AND url not like '%png%' AND url not like '%otf%' AND url not like '%ico%' FACET geo_country_code SINCE 30 days ago until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 32, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Web and Non-Web\n---\n# Transactions (Requests) Analysis"
          }
        },
        {
          "title": "Important Pages (Average Page Load Time) in Seconds",
          "layout": { "column": 1, "row": 33, "width": 4, "height": 8 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.billboard" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "FROM Transaction SELECT average(duration) as `Average Time (s)` FACET name WHERE transactionType = 'Web' AND __APP_FILTER__ and (name like '%catalog/category/view%' or name like '%catalog/product/view%' or name like '%catalogsearch/result/index%' or name like '%cms/index/index%') and name not like '%REST%' LIMIT 50"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Web Transactions (Most Requested)",
          "layout": { "column": 5, "row": 33, "width": 8, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT name, `Total (s)`, `Count`, `Average (s)`, `Median (s)`, `Min (s)`, `Max (s)`, timestamp FROM (FROM Transaction SELECT count(duration) as `Count`, sum(duration) as `Total (s)`, average(duration) as `Average (s)`, percentile(duration, 50) as `Median (s)`, min(duration) as `Min (s)`, max(duration) as `Max (s)` WHERE transactionType = 'Web' AND __APP_FILTER__ FACET name, request_uri LIMIT 50) Order by 'Total (s)' desc since 7 days ago limit 20"
              }
            ]
          }
        },
        {
          "title": "Non-Web Transactions",
          "layout": { "column": 5, "row": 37, "width": 8, "height": 4 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT name, `Total (s)`, `Count`, `Average (s)`, `Median (s)`, `Min (s)`, `Max (s)`, timestamp FROM (FROM Transaction SELECT count(duration) as `Count`, sum(duration) as `Total (s)`, average(duration) as `Average (s)`, percentile(duration, 50) as `Median (s)`, min(duration) as `Min (s)`, max(duration) as `Max (s)` WHERE transactionType = 'Other' AND __APP_FILTER__ FACET name, request_uri LIMIT 50) Order by 'Total (s)' desc since 7 days ago limit 20"
              }
            ]
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 41, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Application\n---\n# Errors and Exceptions"
          }
        },
        {
          "title": "Top Errors Last Month",
          "layout": { "column": 1, "row": 42, "width": 12, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) as counter FROM TransactionError WHERE (__APP_FILTER__) AND (`error.expected` IS FALSE OR `error.expected` IS NULL) FACET `error.class`, `error.message`, `transactionUiName` LIMIT 10 SINCE 30 days ago"
              }
            ]
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 45, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "# Other Handy Reports and Charts"
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 46, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Traffic Monitoring\n---\nHTTP Status, Traffic and DDoS Detection"
          }
        },
        {
          "title": "Top requests by URL and Client IP",
          "layout": { "column": 1, "row": 47, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) AS 'Top URL requests by URL and Client IP' FROM Log where __PROJECT_FILTER__ facet url, client_ip, geo_country_code since 30 days ago until now timeseries limit 20"
              }
            ],
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Requests by HTTP status and Client IP",
          "layout": { "column": 7, "row": 47, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) AS 'Top HTTP status by Client IP' FROM Log where __PROJECT_FILTER__ facet status, client_ip, geo_country_code since 30 days ago until now timeseries limit 20"
              }
            ],
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 50, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "# Other Charts\n## Some other useful charts that might be useful to you"
          }
        },
        {
          "title": "STATIC Content By Response Body Size",
          "layout": { "column": 1, "row": 51, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) FROM Log WHERE __PROJECT_FILTER__ AND `cache_status` IS NOT NULL AND cache_status != 'PASS' and `content_type` NOT LIKE 'text/html;%' and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET content_type SINCE 30 day ago UNTIL today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "All assets breakdown by Request User Agent",
          "layout": { "column": 5, "row": 51, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET request_user_agent SINCE 30 day ago limit 15 until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "All assets breakdown by Country Code",
          "layout": { "column": 9, "row": 51, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' and resp_body_size IS NOT NULL FACET geo_country_code SINCE 30 day ago limit 15 until today"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Bot Presence Breakdown by Request User Agent",
          "layout": { "column": 1, "row": 54, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT sum(numeric(resp_body_size)) + sum(numeric(resp_header_size)) as 'CDN Usage by possible bots' FROM Log WHERE `cache_status` IS NOT NULL and __PROJECT_FILTER__ and content_type is not null and content_type != '' AND (content_type LIKE 'text/html;%') and resp_body_size IS NOT NULL and request_user_agent like '%bot%' facet request_user_agent limit 200 since 30 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Cluster Size History",
          "layout": { "column": 5, "row": 54, "width": 8, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.stacked-bar" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(numeric(processorCount)) FROM SystemSample where __APM_FILTER__ and apmApplicationNames is NOT NULL facet entityName timeseries 1 day limit 20 SINCE 365 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 57, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Database Performance\n---\n# MySQL/MariaDB Metrics"
          }
        },
        {
          "title": "Database Query Time (ms)",
          "layout": { "column": 1, "row": 58, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'Query Time (ms)' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'MySQL' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Slow Queries (>1s)",
          "layout": { "column": 5, "row": 58, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) as 'Slow Queries' FROM Transaction WHERE __APP_FILTER__ AND databaseDuration > 1 TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Database Operations by Time",
          "layout": { "column": 9, "row": 58, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'Avg (ms)', count(*) as 'Count' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'MySQL' FACET operation, table LIMIT 20 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Database Call Count",
          "layout": { "column": 1, "row": 61, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.datastore.operation.duration), 1 minute) as 'Calls/min' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'MySQL' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Database Time % of Transaction",
          "layout": { "column": 5, "row": 61, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(databaseDuration/duration) * 100 as 'DB Time %' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Transactions with High DB Time",
          "layout": { "column": 9, "row": 61, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(databaseDuration) * 1000 as 'Avg DB Time (ms)', average(databaseCallCount) as 'Avg Calls', count(*) as 'Count' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' FACET name LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 64, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Redis/Valkey Cache\n---\n# Cache Performance Metrics"
          }
        },
        {
          "title": "Redis Operation Time (ms)",
          "layout": { "column": 1, "row": 65, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'Redis Time (ms)' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'Redis' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Redis Call Rate",
          "layout": { "column": 5, "row": 65, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.datastore.operation.duration), 1 minute) as 'Calls/min' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'Redis' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Redis Operations",
          "layout": { "column": 9, "row": 65, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'Avg (ms)', count(*) as 'Count' FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'Redis' FACET operation LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Redis Time % of Transaction",
          "layout": { "column": 1, "row": 68, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(totalTime) * 1000 as 'Total Redis Time (ms)' FROM Metric WHERE __APP_FILTER__ AND metricTimesliceName LIKE '%Redis%' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Redis Throughput by Operation Type",
          "layout": { "column": 7, "row": 68, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.area" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.datastore.operation.duration), 1 minute) FROM Metric WHERE __APP_FILTER__ AND datastoreType = 'Redis' FACET operation TIMESERIES SINCE 7 days ago LIMIT 10"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 71, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Elasticsearch/OpenSearch\n---\n# Search Engine Performance"
          }
        },
        {
          "title": "Elasticsearch Query Time (ms)",
          "layout": { "column": 1, "row": 72, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'ES Time (ms)' FROM Metric WHERE __APP_FILTER__ AND (datastoreType = 'Elasticsearch' OR datastoreType = 'OpenSearch') TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Elasticsearch Call Rate",
          "layout": { "column": 5, "row": 72, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.datastore.operation.duration), 1 minute) as 'Calls/min' FROM Metric WHERE __APP_FILTER__ AND (datastoreType = 'Elasticsearch' OR datastoreType = 'OpenSearch') TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Elasticsearch Operations",
          "layout": { "column": 9, "row": 72, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.datastore.operation.duration) * 1000 as 'Avg (ms)', count(*) as 'Count' FROM Metric WHERE __APP_FILTER__ AND (datastoreType = 'Elasticsearch' OR datastoreType = 'OpenSearch') FACET operation LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Search Latency Distribution",
          "layout": { "column": 1, "row": 75, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.histogram" },
          "rawConfiguration": {
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT histogram(apm.service.datastore.operation.duration * 1000, 50, 10) FROM Metric WHERE __APP_FILTER__ AND (datastoreType = 'Elasticsearch' OR datastoreType = 'OpenSearch') SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Elasticsearch Throughput by Operation",
          "layout": { "column": 7, "row": 75, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.area" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(apm.service.datastore.operation.duration), 1 minute) FROM Metric WHERE __APP_FILTER__ AND (datastoreType = 'Elasticsearch' OR datastoreType = 'OpenSearch') FACET operation TIMESERIES SINCE 7 days ago LIMIT 10"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 78, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "PHP-FPM\n---\n# PHP Process and Performance Metrics"
          }
        },
        {
          "title": "PHP Memory Usage by Process",
          "layout": { "column": 1, "row": 79, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(memoryResidentSizeBytes)/1024/1024 as 'Memory (MB)' FROM ProcessSample WHERE processDisplayName LIKE 'php%' AND __APM_FILTER__ AND apmApplicationNames IS NOT NULL TIMESERIES FACET hostname SINCE 7 days ago LIMIT 10"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "PHP CPU Usage",
          "layout": { "column": 5, "row": 79, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(cpuPercent) as 'CPU %' FROM ProcessSample WHERE processDisplayName LIKE 'php%' AND __APM_FILTER__ AND apmApplicationNames IS NOT NULL TIMESERIES FACET hostname SINCE 7 days ago LIMIT 10"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "PHP Process Count",
          "layout": { "column": 9, "row": 79, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT uniqueCount(processId) as 'PHP Processes' FROM ProcessSample WHERE processDisplayName LIKE 'php%' AND __APM_FILTER__ AND apmApplicationNames IS NOT NULL TIMESERIES FACET hostname SINCE 7 days ago LIMIT 10"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "PHP Transaction Duration Distribution",
          "layout": { "column": 1, "row": 82, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.histogram" },
          "rawConfiguration": {
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT histogram(duration, 60, 20) FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Long Running Requests (>5s)",
          "layout": { "column": 7, "row": 82, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) as 'Count', average(duration) as 'Avg Duration (s)', max(duration) as 'Max (s)' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' AND duration > 5 FACET name LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 85, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Cron & Message Queues\n---\n# Background Job Performance"
          }
        },
        {
          "title": "Cron Job Duration",
          "layout": { "column": 1, "row": 86, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(duration) as 'Duration (s)' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%cron%' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Cron Job Throughput",
          "layout": { "column": 5, "row": 86, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(*), 1 hour) as 'Jobs/hour' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%cron%' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Cron Jobs by Duration",
          "layout": { "column": 9, "row": 86, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(duration) as 'Avg (s)', max(duration) as 'Max (s)', count(*) as 'Count' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%cron%' FACET name LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Message Consumer Duration",
          "layout": { "column": 1, "row": 89, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(duration) as 'Duration (s)' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%consumer%' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Message Consumer Throughput",
          "layout": { "column": 5, "row": 89, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT rate(count(*), 1 minute) as 'Messages/min' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%consumer%' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top Message Consumers",
          "layout": { "column": 9, "row": 89, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(duration) as 'Avg (s)', count(*) as 'Count', sum(duration) as 'Total Time (s)' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Other' AND name LIKE '%consumer%' FACET name LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "",
          "layout": { "column": 1, "row": 92, "width": 12, "height": 1 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.markdown" },
          "rawConfiguration": {
            "text": "Application Performance\n---\n# Apdex, Response Times & External Services"
          }
        },
        {
          "title": "Apdex Score",
          "layout": { "column": 1, "row": 93, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT apdex(duration, t: 0.5) as 'Apdex' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": false }
          }
        },
        {
          "title": "Response Time Percentiles",
          "layout": { "column": 5, "row": 93, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT percentile(duration, 50, 90, 95, 99) FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Error Rate",
          "layout": { "column": 9, "row": 93, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT percentage(count(*), WHERE error IS true) as 'Error Rate %' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "External Service Call Time",
          "layout": { "column": 1, "row": 96, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(externalDuration) * 1000 as 'External Time (ms)' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' AND externalDuration > 0 TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "External Service Calls",
          "layout": { "column": 5, "row": 96, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.line" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(externalCallCount) as 'External Calls' FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false },
            "yAxisLeft": { "zero": true }
          }
        },
        {
          "title": "Top External Services by Time",
          "layout": { "column": 9, "row": 96, "width": 4, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.table" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.external.host.duration) * 1000 as 'Avg (ms)', count(*) as 'Count' FROM Metric WHERE __APP_FILTER__ FACET external.host LIMIT 15 SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Time Breakdown by Category",
          "layout": { "column": 1, "row": 99, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.area" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": false },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT average(apm.service.overview.web) * 1000 FROM Metric WHERE __APP_FILTER__ FACET segmentName TIMESERIES SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        },
        {
          "title": "Transactions by Response Time Bucket",
          "layout": { "column": 7, "row": 99, "width": 6, "height": 3 },
          "linkedEntityGuids": null,
          "visualization": { "id": "viz.pie" },
          "rawConfiguration": {
            "facet": { "showOtherSeries": true },
            "legend": { "enabled": true },
            "nrqlQueries": [
              {
                "accountIds": [__ACCOUNT_ID__],
                "query": "SELECT count(*) FROM Transaction WHERE __APP_FILTER__ AND transactionType = 'Web' FACET cases(WHERE duration < 0.5 as 'Fast (<0.5s)', WHERE duration >= 0.5 AND duration < 2 as 'Normal (0.5-2s)', WHERE duration >= 2 AND duration < 5 as 'Slow (2-5s)', WHERE duration >= 5 as 'Very Slow (>5s)') SINCE 7 days ago"
              }
            ],
            "platformOptions": { "ignoreTimeRange": false }
          }
        }
      ]
    }
  ],
  "variables": []
}
DASHBOARD_TEMPLATE

  # Replace placeholders with actual values
  sed -i.bak \
    -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
    -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__DASHBOARD_PREFIX__|${DASHBOARD_PREFIX}|g" \
    -e "s|__ENV_DISPLAY__|${env_display}|g" \
    -e "s|__ENV_TAG__|${env_tag}|g" \
    -e "s|__APM_FILTER__|${apm_filter}|g" \
    -e "s|__APP_FILTER__|${app_filter}|g" \
    -e "s|__PROJECT_FILTER__|${project_filter}|g" \
    "$output_file"

  # Remove backup file
  rm -f "${output_file}.bak"

  # Only show message if not in single-env mode (temp file)
  if [[ -z "$TARGET_ENV" ]]; then
    print_info "Generated: $output_file"
  fi
}

# Generate dashboards
if [[ -n "$TARGET_ENV" ]]; then
  # Single dashboard mode - output JSON to stdout
  print_info "Generating ${TARGET_ENV} dashboard to stdout..." >&2

  # Create temp file, generate, output to stdout, cleanup
  TEMP_FILE=$(mktemp)
  generate_dashboard "$TARGET_ENV" "$TEMP_FILE"
  cat "$TEMP_FILE"
  rm -f "$TEMP_FILE"

  print_info "Done. Redirect output to save: > oneview_${PROJECT_ID}_${TARGET_ENV}.json" >&2
else
  # Dual dashboard mode - write to files
  echo "" >&2
  print_header "Generating Dashboards"

  PROD_FILE="${OUTPUT_DIR}/oneview_${PROJECT_ID}_production.json"
  STG_FILE="${OUTPUT_DIR}/oneview_${PROJECT_ID}_staging.json"

  generate_dashboard "production" "$PROD_FILE"
  generate_dashboard "staging" "$STG_FILE"

  # Summary
  echo "" >&2
  print_header "Generation Complete"
  echo "" >&2
  echo -e "${GREEN}Successfully generated 2 dashboard files:${NC}" >&2
  echo "" >&2
  echo "  Production: $PROD_FILE" >&2
  echo "  Staging:    $STG_FILE" >&2
  echo "" >&2

  # Show download instructions if on cloud
  if [[ -n "${MAGENTO_CLOUD_PROJECT:-}" ]]; then
    echo -e "${BLUE}To download files from cloud:${NC}" >&2
    echo "  magento-cloud ssh -p ${MAGENTO_CLOUD_PROJECT} -e \${ENV} -- 'cat $PROD_FILE' > oneview_${PROJECT_ID}_production.json" >&2
    echo "  magento-cloud ssh -p ${MAGENTO_CLOUD_PROJECT} -e \${ENV} -- 'cat $STG_FILE' > oneview_${PROJECT_ID}_staging.json" >&2
    echo "" >&2
  fi

  echo -e "${BLUE}To import into New Relic:${NC}" >&2
  echo "  1. Log in to New Relic" >&2
  echo "  2. Go to Dashboards" >&2
  echo "  3. Click 'Import dashboard' (top right)" >&2
  echo "  4. Paste the contents of the JSON file" >&2
  echo "  5. Click 'Import dashboard'" >&2
  echo "" >&2
fi
