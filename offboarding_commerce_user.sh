#!/usr/bin/env bash
set -Eeuo pipefail

#===============================================================================
# offboard_commerce_user.sh
# Scans all Adobe Commerce Cloud projects for a user's cloud platform access
# and admin panel accounts, then removes/disables them after confirmation.
#===============================================================================

# Colors for output (sent to stderr)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Default values
TARGET_EMAIL=""
SCAN_ONLY=false

# Temp directory (set up after validation)
TMP_DIR=""

# Tracking files for removal phase
CLOUD_RESULTS_FILE=""
ADMIN_RESULTS_FILE=""

# Tracking files for report table
PROJECT_ORDER_FILE=""
CLOUD_SCAN_FILE=""
ADMIN_SCAN_FILE=""

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

print_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --email EMAIL [OPTIONS]

Scans all Adobe Commerce Cloud projects for a user's cloud platform access
and admin panel accounts across production and staging environments, then
removes/disables them after confirmation.

Cloud platform access is removed entirely. Admin panel accounts are disabled
(is_active = 0) rather than deleted to preserve audit trails and avoid
foreign key issues.

Required:
  --email EMAIL       Email address of the user to offboard

Options:
  --scan-only         Scan and report only; do not make any changes
  -h, --help          Show this help message

Examples:
  # Full offboard (scan + remove/disable with confirmation)
  $(basename "$0") --email user@example.com

  # Audit only (no changes made)
  $(basename "$0") --email user@example.com --scan-only
EOF
}

# Truncate a string to max length, appending .. if truncated
truncate_str() {
  local str="$1"
  local max="$2"
  if [[ ${#str} -gt $max ]]; then
    echo "${str:0:$((max - 2))}.."
  else
    echo "$str"
  fi
}

# Print a colored string padded to a fixed visible width.
# ANSI escape codes have zero visible width but confuse printf's %-Ns padding,
# so we pad manually based on the stripped (visible) length.
print_col() {
  local text="$1"
  local width="$2"
  local plain
  plain=$(echo -e "$text" | sed $'s/\033\\[[0-9;]*m//g')
  local visible_len=${#plain}
  local padding=$((width - visible_len))
  if [[ $padding -lt 0 ]]; then padding=0; fi
  printf "%b%*s" "$text" "$padding" "" >&2
}

#-------------------------------------------------------------------------------
# Parse command line arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --email)
      TARGET_EMAIL="$2"
      shift 2
      ;;
    --scan-only)
      SCAN_ONLY=true
      shift
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
# Validation
#-------------------------------------------------------------------------------

if [[ -z "$TARGET_EMAIL" ]]; then
  print_error "Email address is required. Use --email EMAIL"
  echo "" >&2
  show_usage
  exit 1
fi

if ! [[ "$TARGET_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  print_error "Invalid email format: $TARGET_EMAIL"
  exit 1
fi

if ! command -v magento-cloud &>/dev/null; then
  print_error "magento-cloud CLI is not installed or not in PATH."
  print_error "Install it: curl -sS https://accounts.magento.cloud/cli/installer | php"
  exit 1
fi

# Verify auth by attempting to list projects (will fail if not logged in)
if ! magento-cloud project:list --format=plain --no-header --columns=id 2>/dev/null | head -n 1 &>/dev/null; then
  print_error "magento-cloud CLI authentication failed. Run: magento-cloud auth:login"
  exit 1
fi

#-------------------------------------------------------------------------------
# Temp directory setup
#-------------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
CLOUD_RESULTS_FILE="${TMP_DIR}/cloud_results.txt"
ADMIN_RESULTS_FILE="${TMP_DIR}/admin_results.txt"
PROJECT_ORDER_FILE="${TMP_DIR}/project_order.txt"
CLOUD_SCAN_FILE="${TMP_DIR}/cloud_scan.txt"
ADMIN_SCAN_FILE="${TMP_DIR}/admin_scan.txt"
touch "$CLOUD_RESULTS_FILE" "$ADMIN_RESULTS_FILE" \
      "$PROJECT_ORDER_FILE" "$CLOUD_SCAN_FILE" "$ADMIN_SCAN_FILE"

#-------------------------------------------------------------------------------
# PHP code templates
#-------------------------------------------------------------------------------

# Check if admin user exists. Returns "username|email|is_active" per row.
# Empty output = not found. Exit 1 on error.
read -r -d '' PHP_CHECK_ADMIN << 'PHPEOF' || true
<?php
$relationships = getenv('MAGENTO_CLOUD_RELATIONSHIPS');
if (!$relationships) {
    fwrite(STDERR, "ERROR: MAGENTO_CLOUD_RELATIONSHIPS not available\n");
    exit(1);
}
$rels = json_decode(base64_decode($relationships), true);
if (!isset($rels['database'][0])) {
    fwrite(STDERR, "ERROR: No database relationship found\n");
    exit(1);
}
$db = $rels['database'][0];
$dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', $db['host'], $db['port'], $db['path']);
try {
    $pdo = new PDO($dsn, $db['username'], $db['password'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);
    $stmt = $pdo->prepare('SELECT username, email, is_active FROM admin_user WHERE LOWER(email) = LOWER(?)');
    $stmt->execute(['__TARGET_EMAIL__']);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    foreach ($rows as $row) {
        echo $row['username'] . '|' . $row['email'] . '|' . $row['is_active'] . "\n";
    }
} catch (PDOException $e) {
    fwrite(STDERR, "ERROR: " . $e->getMessage() . "\n");
    exit(1);
}
PHPEOF

# Disable admin user. Sets is_active = 0 where email matches and currently active.
# Returns "DISABLED:N" where N is the number of rows affected.
read -r -d '' PHP_DISABLE_ADMIN << 'PHPEOF' || true
<?php
$relationships = getenv('MAGENTO_CLOUD_RELATIONSHIPS');
if (!$relationships) {
    fwrite(STDERR, "ERROR: MAGENTO_CLOUD_RELATIONSHIPS not available\n");
    exit(1);
}
$rels = json_decode(base64_decode($relationships), true);
if (!isset($rels['database'][0])) {
    fwrite(STDERR, "ERROR: No database relationship found\n");
    exit(1);
}
$db = $rels['database'][0];
$dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', $db['host'], $db['port'], $db['path']);
try {
    $pdo = new PDO($dsn, $db['username'], $db['password'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);
    $stmt = $pdo->prepare('UPDATE admin_user SET is_active = 0 WHERE LOWER(email) = LOWER(?) AND is_active = 1');
    $stmt->execute(['__TARGET_EMAIL__']);
    echo "DISABLED:" . $stmt->rowCount() . "\n";
} catch (PDOException $e) {
    fwrite(STDERR, "ERROR: " . $e->getMessage() . "\n");
    exit(1);
}
PHPEOF

#-------------------------------------------------------------------------------
# run_remote_php() - Execute PHP code on a remote environment via SSH
# Args: $1 = project_id, $2 = environment_id, $3 = php_code
# Returns: stdout from PHP execution, exit code from SSH
#-------------------------------------------------------------------------------

run_remote_php() {
  local project_id="$1"
  local env_id="$2"
  local php_code="$3"

  local encoded
  encoded=$(echo "$php_code" | base64)

  magento-cloud ssh -p "$project_id" -e "$env_id" --no-interaction -- \
    "echo '$encoded' | base64 --decode | php" 2>/dev/null
}

#-------------------------------------------------------------------------------
# Scan phase
#-------------------------------------------------------------------------------

print_header "Commerce Cloud User Offboarding"
echo "" >&2
print_info "Target email: $TARGET_EMAIL"
if [[ "$SCAN_ONLY" == true ]]; then
  print_warn "Scan-only mode: no changes will be made"
fi
echo "" >&2

print_header "Scanning Projects"
echo "" >&2

# Fetch all projects
PROJECT_LIST=$(magento-cloud project:list --format=plain --no-header --columns="id,title" 2>/dev/null) || {
  print_error "Failed to fetch project list"
  exit 1
}

if [[ -z "$PROJECT_LIST" ]]; then
  print_error "No projects found. Check your magento-cloud authentication and permissions."
  exit 1
fi

PROJECT_COUNT=$(echo "$PROJECT_LIST" | wc -l | tr -d ' ')
print_info "Found $PROJECT_COUNT project(s)"
echo "" >&2

CURRENT=0
while IFS= read -r line; do
  PROJECT_ID=$(echo "$line" | awk '{print $1}')
  PROJECT_TITLE=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
  CURRENT=$((CURRENT + 1))

  # Track project order and title
  echo "${PROJECT_ID}|${PROJECT_TITLE}" >> "$PROJECT_ORDER_FILE"

  echo -e "${BLUE}[$CURRENT/$PROJECT_COUNT]${NC} ${PROJECT_TITLE} (${PROJECT_ID})" >&2

  # -- Check cloud platform access --
  CLOUD_FETCH_OK=true
  USER_LIST=$(magento-cloud user:list -p "$PROJECT_ID" --format=plain --no-header --columns="email" 2>/dev/null) || {
    CLOUD_FETCH_OK=false
  }

  if [[ "$CLOUD_FETCH_OK" == false ]]; then
    echo -e "        Cloud access:       ${YELLOW}[failed to check]${NC}" >&2
    echo "${PROJECT_ID}|[failed]" >> "$CLOUD_SCAN_FILE"
  elif echo "$USER_LIST" | grep -Fix "$TARGET_EMAIL" &>/dev/null; then
    echo -e "        Cloud access:       ${RED}FOUND${NC}" >&2
    echo "${PROJECT_ID}|found" >> "$CLOUD_SCAN_FILE"
    echo "${PROJECT_ID}|${PROJECT_TITLE}|FOUND" >> "$CLOUD_RESULTS_FILE"
  else
    echo -e "        Cloud access:       ${DIM}not found${NC}" >&2
    echo "${PROJECT_ID}|not found" >> "$CLOUD_SCAN_FILE"
  fi

  # -- Discover production and staging environments --
  ENV_FETCH_OK=true
  ENV_LIST=$(magento-cloud environment:list -p "$PROJECT_ID" --type=production,staging --format=plain --no-header --columns="id" 2>/dev/null) || {
    ENV_FETCH_OK=false
  }

  if [[ "$ENV_FETCH_OK" == false ]]; then
    echo -e "        Admin panel:        ${YELLOW}[failed to list environments]${NC}" >&2
    echo "${PROJECT_ID}|--|[env list failed]" >> "$ADMIN_SCAN_FILE"
    echo "" >&2
    continue
  fi

  if [[ -z "$ENV_LIST" ]]; then
    echo -e "        Admin panel:        ${DIM}no environments found${NC}" >&2
    echo "${PROJECT_ID}|--|--" >> "$ADMIN_SCAN_FILE"
    echo "" >&2
    continue
  fi

  HAS_ENV=false
  while IFS= read -r env_id; do
    [[ -z "$env_id" ]] && continue
    env_id=$(echo "$env_id" | tr -d '[:space:]')
    HAS_ENV=true

    local_php="${PHP_CHECK_ADMIN//__TARGET_EMAIL__/$TARGET_EMAIL}"
    ADMIN_CHECK_OK=true
    ADMIN_OUTPUT=$(run_remote_php "$PROJECT_ID" "$env_id" "$local_php") || {
      ADMIN_CHECK_OK=false
    }

    if [[ "$ADMIN_CHECK_OK" == false ]]; then
      echo -e "        Admin (${env_id}):$(printf '%*s' $((14 - ${#env_id})) '')${YELLOW}[scan failed]${NC}" >&2
      echo "${PROJECT_ID}|${env_id}|[scan failed]" >> "$ADMIN_SCAN_FILE"
      continue
    fi

    if [[ -n "$ADMIN_OUTPUT" ]]; then
      while IFS= read -r admin_row; do
        [[ -z "$admin_row" ]] && continue
        ADMIN_USERNAME=$(echo "$admin_row" | cut -d'|' -f1)
        ADMIN_IS_ACTIVE=$(echo "$admin_row" | cut -d'|' -f3)
        if [[ "$ADMIN_IS_ACTIVE" == "1" ]]; then
          ADMIN_STATUS_LABEL="active"
          ADMIN_COLOR="$RED"
        else
          ADMIN_STATUS_LABEL="inactive"
          ADMIN_COLOR="$YELLOW"
        fi
        echo -e "        Admin (${env_id}):$(printf '%*s' $((14 - ${#env_id})) '')${ADMIN_COLOR}${ADMIN_USERNAME} [${ADMIN_STATUS_LABEL}]${NC}" >&2
        echo "${PROJECT_ID}|${env_id}|${ADMIN_USERNAME} [${ADMIN_STATUS_LABEL}]" >> "$ADMIN_SCAN_FILE"
        echo "${PROJECT_ID}|${PROJECT_TITLE}|${env_id}|${ADMIN_USERNAME}|${ADMIN_IS_ACTIVE}" >> "$ADMIN_RESULTS_FILE"
      done <<< "$ADMIN_OUTPUT"
    else
      echo -e "        Admin (${env_id}):$(printf '%*s' $((14 - ${#env_id})) '')${DIM}not found${NC}" >&2
      echo "${PROJECT_ID}|${env_id}|not found" >> "$ADMIN_SCAN_FILE"
    fi
  done <<< "$ENV_LIST"

  if [[ "$HAS_ENV" == false ]]; then
    echo -e "        Admin panel:        ${DIM}no environments found${NC}" >&2
    echo "${PROJECT_ID}|--|--" >> "$ADMIN_SCAN_FILE"
  fi

  echo "" >&2
done <<< "$PROJECT_LIST"

#-------------------------------------------------------------------------------
# Scan report (tabular)
#-------------------------------------------------------------------------------

print_header "Scan Report"
echo "" >&2
echo -e "  Target: ${YELLOW}${TARGET_EMAIL}${NC}" >&2
echo "" >&2

# Column widths
COL_PROJECT=35
COL_CLOUD=14
COL_ENV=14
COL_ADMIN=30

# Print table header
printf "  ${BLUE}%-${COL_PROJECT}s  %-${COL_CLOUD}s  %-${COL_ENV}s  %-${COL_ADMIN}s${NC}\n" \
  "Project" "Cloud Access" "Environment" "Admin Account" >&2
printf "  ${BLUE}%-${COL_PROJECT}s  %-${COL_CLOUD}s  %-${COL_ENV}s  %-${COL_ADMIN}s${NC}\n" \
  "$(printf '%0.s-' $(seq 1 $COL_PROJECT))" \
  "$(printf '%0.s-' $(seq 1 $COL_CLOUD))" \
  "$(printf '%0.s-' $(seq 1 $COL_ENV))" \
  "$(printf '%0.s-' $(seq 1 $COL_ADMIN))" >&2

FOUND_ANYTHING=false
HAS_SCAN_FAILURES=false

while IFS='|' read -r proj_id proj_title; do
  # Look up cloud status for this project
  CLOUD_STATUS=$(grep "^${proj_id}|" "$CLOUD_SCAN_FILE" | head -1 | cut -d'|' -f2)

  # Look up admin results for this project (may be multiple lines)
  ADMIN_LINES=$(grep "^${proj_id}|" "$ADMIN_SCAN_FILE" || true)

  # Determine display color for cloud status
  CLOUD_DISPLAY="$CLOUD_STATUS"
  case "$CLOUD_STATUS" in
    found)
      CLOUD_DISPLAY="${RED}found${NC}"
      FOUND_ANYTHING=true
      ;;
    "not found")
      CLOUD_DISPLAY="${DIM}not found${NC}"
      ;;
    *)
      CLOUD_DISPLAY="${YELLOW}${CLOUD_STATUS}${NC}"
      ;;
  esac

  DISPLAY_TITLE=$(truncate_str "$proj_title" $COL_PROJECT)

  # Render first row with project name + cloud status
  FIRST_ROW=true
  if [[ -n "$ADMIN_LINES" ]]; then
    while IFS='|' read -r _pid env_id admin_result; do
      # Determine color for admin result
      ADMIN_DISPLAY="$admin_result"
      if [[ "$admin_result" == *"[active]"* ]]; then
        ADMIN_DISPLAY="${RED}${admin_result}${NC}"
        FOUND_ANYTHING=true
      elif [[ "$admin_result" == *"[inactive]"* ]]; then
        ADMIN_DISPLAY="${YELLOW}${admin_result}${NC}"
        FOUND_ANYTHING=true
      elif [[ "$admin_result" == *"failed"* ]]; then
        ADMIN_DISPLAY="${YELLOW}${admin_result}${NC}"
        HAS_SCAN_FAILURES=true
      elif [[ "$admin_result" == "not found" || "$admin_result" == "--" ]]; then
        ADMIN_DISPLAY="${DIM}${admin_result}${NC}"
      fi

      ENV_DISPLAY="$env_id"
      if [[ "$env_id" == "--" ]]; then
        ENV_DISPLAY="${DIM}--${NC}"
      fi

      if [[ "$FIRST_ROW" == true ]]; then
        printf "  " >&2
        print_col "$DISPLAY_TITLE" "$COL_PROJECT"
        printf "  " >&2
        print_col "$CLOUD_DISPLAY" "$COL_CLOUD"
        printf "  " >&2
        print_col "$ENV_DISPLAY" "$COL_ENV"
        printf "  " >&2
        print_col "$ADMIN_DISPLAY" "$COL_ADMIN"
        echo "" >&2
        FIRST_ROW=false
      else
        printf "  " >&2
        print_col "" "$COL_PROJECT"
        printf "  " >&2
        print_col "" "$COL_CLOUD"
        printf "  " >&2
        print_col "$ENV_DISPLAY" "$COL_ENV"
        printf "  " >&2
        print_col "$ADMIN_DISPLAY" "$COL_ADMIN"
        echo "" >&2
      fi
    done <<< "$ADMIN_LINES"
  else
    printf "  " >&2
    print_col "$DISPLAY_TITLE" "$COL_PROJECT"
    printf "  " >&2
    print_col "$CLOUD_DISPLAY" "$COL_CLOUD"
    printf "  " >&2
    print_col "${DIM}--${NC}" "$COL_ENV"
    printf "  " >&2
    print_col "${DIM}--${NC}" "$COL_ADMIN"
    echo "" >&2
  fi

done < "$PROJECT_ORDER_FILE"

echo "" >&2

# Summary counts
CLOUD_FOUND_COUNT=$(grep -c "|found$" "$CLOUD_SCAN_FILE" 2>/dev/null || echo "0")
ADMIN_FOUND_COUNT=$(wc -l < "$ADMIN_RESULTS_FILE" | tr -d ' ')
ADMIN_ACTIVE_COUNT=$(grep -c '|1$' "$ADMIN_RESULTS_FILE" 2>/dev/null || echo "0")
ADMIN_INACTIVE_COUNT=$(grep -c '|0$' "$ADMIN_RESULTS_FILE" 2>/dev/null || echo "0")

echo -e "  ${BLUE}Summary:${NC} ${CLOUD_FOUND_COUNT} cloud access, ${ADMIN_ACTIVE_COUNT} active admin, ${ADMIN_INACTIVE_COUNT} inactive admin across ${PROJECT_COUNT} projects" >&2
echo "" >&2

if [[ "$HAS_SCAN_FAILURES" == true ]]; then
  echo -e "  ${YELLOW}[scan failed]${NC} = could not SSH into the environment to query the admin_user table." >&2
  echo -e "  Common causes: your SSH key is not added to the project, the environment is" >&2
  echo -e "  suspended/inactive, or the environment does not have a database relationship." >&2
  echo -e "  These environments were skipped -- check them manually if needed." >&2
  echo "" >&2
fi

if [[ "$FOUND_ANYTHING" == false ]]; then
  print_info "No cloud access or admin accounts found for $TARGET_EMAIL"
  print_info "Nothing to do."
  exit 0
fi

#-------------------------------------------------------------------------------
# Scan-only mode exits here
#-------------------------------------------------------------------------------

if [[ "$SCAN_ONLY" == true ]]; then
  print_info "Scan-only mode -- no changes made."
  echo "" >&2
  echo -e "  To proceed with removal, run:" >&2
  echo -e "  ${BLUE}./$(basename "$0") --email ${TARGET_EMAIL}${NC}" >&2
  echo "" >&2
  exit 0
fi

#-------------------------------------------------------------------------------
# Confirmation prompt
#-------------------------------------------------------------------------------

CLOUD_COUNT=$(wc -l < "$CLOUD_RESULTS_FILE" | tr -d ' ')
ADMIN_COUNT=$(wc -l < "$ADMIN_RESULTS_FILE" | tr -d ' ')

echo -e "${RED}The following actions will be performed:${NC}" >&2
if [[ "$CLOUD_COUNT" -gt 0 ]]; then
  echo "  - Remove cloud platform access from $CLOUD_COUNT project(s)" >&2
fi
if [[ "$ADMIN_COUNT" -gt 0 ]]; then
  echo "  - Disable admin account(s) in $ADMIN_COUNT environment(s)" >&2
fi
echo "" >&2

read -r -p "Proceed? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  print_info "Aborted."
  exit 0
fi

echo "" >&2

#-------------------------------------------------------------------------------
# Removal phase
#-------------------------------------------------------------------------------

print_header "Removing Access"
echo "" >&2

CLOUD_SUCCESS=0
CLOUD_FAILED=0
ADMIN_SUCCESS=0
ADMIN_FAILED=0
ADMIN_SKIPPED=0

CLOUD_FAILURES_FILE="${TMP_DIR}/cloud_failures.txt"
ADMIN_FAILURES_FILE="${TMP_DIR}/admin_failures.txt"
ADMIN_SKIPS_FILE="${TMP_DIR}/admin_skips.txt"
touch "$CLOUD_FAILURES_FILE" "$ADMIN_FAILURES_FILE" "$ADMIN_SKIPS_FILE"

# Remove cloud platform access
if [[ "$CLOUD_COUNT" -gt 0 ]]; then
  echo -e "${BLUE}Removing cloud platform access...${NC}" >&2
  while IFS='|' read -r proj_id proj_title _status; do
    if magento-cloud user:delete "$TARGET_EMAIL" -p "$proj_id" -y --no-interaction 2>/dev/null; then
      print_info "  Removed from ${proj_title} (${proj_id})"
      CLOUD_SUCCESS=$((CLOUD_SUCCESS + 1))
    else
      print_error "  Failed to remove from ${proj_title} (${proj_id})"
      echo "${proj_id}|${proj_title}" >> "$CLOUD_FAILURES_FILE"
      CLOUD_FAILED=$((CLOUD_FAILED + 1))
    fi
  done < "$CLOUD_RESULTS_FILE"
  echo "" >&2
fi

# Disable admin accounts
if [[ "$ADMIN_COUNT" -gt 0 ]]; then
  echo -e "${BLUE}Disabling admin accounts...${NC}" >&2
  while IFS='|' read -r proj_id proj_title env_id username is_active; do
    if [[ "$is_active" != "1" ]]; then
      print_warn "  Skipped ${username} on ${proj_title}/${env_id} (already inactive)"
      echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_SKIPS_FILE"
      ADMIN_SKIPPED=$((ADMIN_SKIPPED + 1))
      continue
    fi

    local_php="${PHP_DISABLE_ADMIN//__TARGET_EMAIL__/$TARGET_EMAIL}"
    DISABLE_OUTPUT=$(run_remote_php "$proj_id" "$env_id" "$local_php") || {
      print_error "  Failed to disable ${username} on ${proj_title}/${env_id}"
      echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_FAILURES_FILE"
      ADMIN_FAILED=$((ADMIN_FAILED + 1))
      continue
    }

    if echo "$DISABLE_OUTPUT" | grep -q "^DISABLED:"; then
      DISABLED_COUNT=$(echo "$DISABLE_OUTPUT" | grep -o "DISABLED:[0-9]*" | cut -d: -f2)
      if [[ "$DISABLED_COUNT" -gt 0 ]]; then
        print_info "  Disabled ${username} on ${proj_title}/${env_id}"
        ADMIN_SUCCESS=$((ADMIN_SUCCESS + 1))
      else
        print_warn "  Skipped ${username} on ${proj_title}/${env_id} (no active rows to update)"
        echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_SKIPS_FILE"
        ADMIN_SKIPPED=$((ADMIN_SKIPPED + 1))
      fi
    else
      print_error "  Unexpected response disabling ${username} on ${proj_title}/${env_id}"
      echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_FAILURES_FILE"
      ADMIN_FAILED=$((ADMIN_FAILED + 1))
    fi
  done < "$ADMIN_RESULTS_FILE"
  echo "" >&2
fi

#-------------------------------------------------------------------------------
# Final report
#-------------------------------------------------------------------------------

print_header "Final Report"
echo "" >&2
echo -e "  Target: ${YELLOW}${TARGET_EMAIL}${NC}" >&2
echo "" >&2

echo -e "  ${BLUE}Cloud platform access:${NC}" >&2
echo -e "    ${GREEN}Removed:${NC} $CLOUD_SUCCESS" >&2
if [[ "$CLOUD_FAILED" -gt 0 ]]; then
  echo -e "    ${RED}Failed:${NC}  $CLOUD_FAILED" >&2
fi
echo "" >&2

echo -e "  ${BLUE}Admin panel accounts:${NC}" >&2
echo -e "    ${GREEN}Disabled:${NC} $ADMIN_SUCCESS" >&2
if [[ "$ADMIN_SKIPPED" -gt 0 ]]; then
  echo -e "    ${YELLOW}Skipped:${NC}  $ADMIN_SKIPPED (already inactive)" >&2
fi
if [[ "$ADMIN_FAILED" -gt 0 ]]; then
  echo -e "    ${RED}Failed:${NC}   $ADMIN_FAILED" >&2
fi
echo "" >&2

# Show details for failures
if [[ "$CLOUD_FAILED" -gt 0 ]]; then
  echo -e "  ${RED}Failed cloud removals:${NC}" >&2
  while IFS='|' read -r proj_id proj_title; do
    echo "    - ${proj_title} (${proj_id})" >&2
  done < "$CLOUD_FAILURES_FILE"
  echo "" >&2
fi

if [[ "$ADMIN_FAILED" -gt 0 ]]; then
  echo -e "  ${RED}Failed admin disables:${NC}" >&2
  while IFS='|' read -r proj_id proj_title env_id username; do
    echo "    - ${proj_title} (${proj_id}) / ${env_id}: ${username}" >&2
  done < "$ADMIN_FAILURES_FILE"
  echo "" >&2
fi

if [[ "$CLOUD_FAILED" -gt 0 || "$ADMIN_FAILED" -gt 0 ]]; then
  print_warn "Some actions failed. Review the details above and retry manually if needed."
  exit 1
fi

print_info "All actions completed successfully."
