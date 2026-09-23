#!/usr/bin/env bash
# scan_all_production.sh
#
# Runs check_stylesmuggler.sh against the production environment of every Commerce
# Cloud project the authenticated user can see, saving one report per project and
# printing a verdict table.
#
# Read-only: reports are written locally only. Nothing is written to any instance.
#
# Usage:
#   ./scan_all_production.sh [-- EXTRA_ARGS_FOR_THE_SCANNER]
#
# Examples:
#   ./scan_all_production.sh
#   ./scan_all_production.sh -- --db
#   ./scan_all_production.sh -- --no-probe

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/scan_results}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; EXTRA_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (use -- to pass arguments to the scanner)" >&2; exit 2 ;;
  esac
done

command -v magento-cloud >/dev/null 2>&1 || {
  echo "ERROR: magento-cloud CLI not found." >&2; exit 2; }

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: > "$SUMMARY"

printf '%-16s %-32s %-12s %s\n' "PROJECT" "TITLE" "VERDICT" "REPORT" | tee -a "$SUMMARY"
printf '%-16s %-32s %-12s %s\n' "----------------" "--------------------------------" "------------" "------" | tee -a "$SUMMARY"

worst=0

while IFS=$'\t' read -r proj title; do
  [[ -n "$proj" ]] || continue

  env="$(magento-cloud environment:list -p "$proj" --type=production \
         --format=plain --no-header --columns=id 2>/dev/null | head -n1)"
  if [[ -z "$env" ]]; then
    printf '%-16s %-32s %-12s %s\n' "$proj" "${title:0:32}" "SKIP" "no production environment" | tee -a "$SUMMARY"
    continue
  fi

  report="$OUT_DIR/stylesmuggler_${proj}_${env}.txt"
  "$SCRIPT_DIR/run-remote.sh" -p "$proj" -e "$env" -s check_stylesmuggler.sh \
    -o "$report" -- --no-color --label "$title" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" >/dev/null 2>&1
  rc=$?

  case "$rc" in
    0) verdict="CLEAN" ;;
    1) verdict="REVIEW" ;;
    2) verdict="COMPROMISED" ;;
    *) verdict="ERROR($rc)" ;;
  esac
  [[ "$rc" -gt "$worst" && "$rc" -le 2 ]] && worst="$rc"

  printf '%-16s %-32s %-12s %s\n' "$proj" "${title:0:32}" "$verdict" "$(basename "$report")" | tee -a "$SUMMARY"
done < <(magento-cloud project:list --format=plain --no-header --columns=id,title 2>/dev/null)

echo | tee -a "$SUMMARY"
echo "Reports in $OUT_DIR" | tee -a "$SUMMARY"
echo "Grep the mitigation status across all of them with:" | tee -a "$SUMMARY"
echo "  grep -H 'Edge blocks\|No mitigation found' $OUT_DIR/*.txt" | tee -a "$SUMMARY"

exit "$worst"
