#!/usr/bin/env bash
set -Eeuo pipefail

# run-remote.sh
# Utility wrapper for running scripts on Adobe Commerce Cloud environments.
#
# Usage:
#   ./run-remote.sh --project PROJECT --environment ENV --script SCRIPT [-- SCRIPT_ARGS]
#
# Examples:
#   ./run-remote.sh -p abc123xyz -e staging -s review_email_sending.sh -- --hours 72
#   ./run-remote.sh -p abc123xyz -e staging -s dump_database.sh -- --output /tmp/dump.sql
#   ./run-remote.sh -p abc123xyz -e production -s audit_magento_env.sh

PROJECT=""
ENVIRONMENT=""
SCRIPT=""
SCRIPT_ARGS=()
MAGENTO_ROOT=""
OUTPUT_FILE=""
VERBOSE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [-- SCRIPT_ARGS]

Runs a script on Adobe Commerce Cloud environment via SSH.

Options:
  --project, -p PROJECT      Magento Cloud project ID (required)
  --environment, -e ENV      Environment name (required, e.g., staging, production)
  --script, -s SCRIPT        Script to run (required, e.g., review_email_sending.sh)
  --root, -r PATH            Magento root path on remote (default: auto-detect)
  --output, -o FILE          Save output to local file
  --verbose, -v              Show verbose output
  -h, --help                 Show this help

Script Arguments:
  Any arguments after -- are passed directly to the script.

Examples:
  # Run email review with 72 hour window
  $0 -p abc123xyz -e staging -s review_email_sending.sh -- --hours 72

  # Run database dump and save locally
  $0 -p abc123xyz -e staging -s dump_database.sh -o dump.sql

  # Run audit script
  $0 -p abc123xyz -e staging -s audit_magento_env.sh

  # Run with verbose output
  $0 -p abc123xyz -e staging -s review_email_sending.sh -v -- --hours 24

Available Scripts:
EOF
  # List available scripts
  for script in "$SCRIPT_DIR"/*.sh; do
    script_name=$(basename "$script")
    [[ "$script_name" == "run-remote.sh" ]] && continue
    echo "  - $script_name"
  done
}

log() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[run-remote] $*" >&2
  fi
}

error() {
  echo "ERROR: $*" >&2
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|-p)
      PROJECT="${2:-}"
      shift 2
      ;;
    --environment|-e)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --script|-s)
      SCRIPT="${2:-}"
      shift 2
      ;;
    --root|-r)
      MAGENTO_ROOT="${2:-}"
      shift 2
      ;;
    --output|-o)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      SCRIPT_ARGS=("$@")
      break
      ;;
    *)
      error "Unknown option: $1. Use -- to pass arguments to the script."
      ;;
  esac
done

# Validate required arguments
[[ -z "$PROJECT" ]] && error "Project ID is required. Use --project or -p"
[[ -z "$ENVIRONMENT" ]] && error "Environment is required. Use --environment or -e"
[[ -z "$SCRIPT" ]] && error "Script is required. Use --script or -s"

# Find the script
if [[ -f "$SCRIPT" ]]; then
  SCRIPT_PATH="$SCRIPT"
elif [[ -f "$SCRIPT_DIR/$SCRIPT" ]]; then
  SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT"
else
  error "Script not found: $SCRIPT"
fi

# Check for magento-cloud CLI
if ! command -v magento-cloud &>/dev/null; then
  error "magento-cloud CLI not found. Install it first: curl -sS https://accounts.magento.cloud/cli/installer | php"
fi

log "Project: $PROJECT"
log "Environment: $ENVIRONMENT"
log "Script: $SCRIPT_PATH"
log "Script args: ${SCRIPT_ARGS[*]:-none}"

# Auto-detect Magento root if not provided
if [[ -z "$MAGENTO_ROOT" ]]; then
  MAGENTO_ROOT="/app/${PROJECT}_${ENVIRONMENT:0:3}"
  log "Auto-detected Magento root: $MAGENTO_ROOT (may need adjustment)"
fi

# Build the script arguments string
ARGS_STRING=""
if [[ ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
  # Add --root if the script supports it and it's not already specified
  if grep -q "\-\-root" "$SCRIPT_PATH" 2>/dev/null; then
    HAS_ROOT=0
    for arg in "${SCRIPT_ARGS[@]}"; do
      [[ "$arg" == "--root" ]] && HAS_ROOT=1
    done
    if [[ "$HAS_ROOT" -eq 0 ]]; then
      ARGS_STRING="--root $MAGENTO_ROOT"
    fi
  fi

  for arg in "${SCRIPT_ARGS[@]}"; do
    # Quote arguments with spaces
    if [[ "$arg" =~ [[:space:]] ]]; then
      ARGS_STRING="$ARGS_STRING \"$arg\""
    else
      ARGS_STRING="$ARGS_STRING $arg"
    fi
  done
fi

log "Running script on remote environment..."

# Execute the script remotely
if [[ -n "$OUTPUT_FILE" ]]; then
  log "Output will be saved to: $OUTPUT_FILE"
  magento-cloud ssh --project "$PROJECT" --environment "$ENVIRONMENT" -- \
    "bash -s -- $ARGS_STRING" < "$SCRIPT_PATH" > "$OUTPUT_FILE" 2>&1
  log "Done. Output saved to: $OUTPUT_FILE"
  log "Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
else
  magento-cloud ssh --project "$PROJECT" --environment "$ENVIRONMENT" -- \
    "bash -s -- $ARGS_STRING" < "$SCRIPT_PATH"
fi
