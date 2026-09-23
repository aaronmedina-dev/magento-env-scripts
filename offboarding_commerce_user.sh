#!/usr/bin/env bash
set -Eeuo pipefail

#===============================================================================
# offboard_commerce_user.sh
# Scans all Adobe Commerce Cloud projects for a user's cloud platform access
# and admin panel accounts, then removes/disables them after confirmation.
#
# --scope selects which surfaces are touched (both, admin panel only, or cloud
# platform only) and --admin-action selects what happens to admin accounts
# (disable, delete, or rotate the password).
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
TARGET_PROJECT=""
SCOPE="all"            # all | admin | cloud
ADMIN_ACTION="disable" # disable | delete | password

# Temp directory (set up after validation)
TMP_DIR=""

# Tracking files for removal phase
CLOUD_RESULTS_FILE=""
ADMIN_RESULTS_FILE=""

# Tracking files for report table
PROJECT_ORDER_FILE=""
CLOUD_SCAN_FILE=""
ADMIN_SCAN_FILE=""

# Audit log
AUDIT_LOG=""

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

# Write to audit log (no-op if AUDIT_LOG is not set)
audit_write() {
  if [[ -n "${AUDIT_LOG:-}" ]]; then
    printf '%s\n' "$@" >> "$AUDIT_LOG"
  fi
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

Removing cloud platform access (magento-cloud user:delete) is what revokes
SSH and Git access to a project. Use --scope to keep that untouched and act
on the admin panel alone.

Required:
  --email EMAIL       Email address of the user to offboard

Options:
  --scope SCOPE       Which access to act on (default: all)
                        all    - cloud platform access + admin panel
                        admin  - admin panel only; cloud/SSH access untouched
                        cloud  - cloud platform access only; admin untouched
  --admin-action ACT  What to do with admin panel accounts (default: disable)
                        disable  - set is_active = 0, keep the account
                        delete   - remove the admin_user row entirely
                        password - rotate to a random password, account stays
                                   active (printed once, never logged)
  --scan-only         Scan and report only; do not make any changes
  --project ID        Limit scan to a single project by its ID
  -h, --help          Show this help message

Admin actions also purge the user's admin_user_session rows so any live
admin session is terminated, not just future logins blocked.

Examples:
  # Full offboard (scan + remove/disable with confirmation)
  $(basename "$0") --email user@example.com

  # Audit only (no changes made)
  $(basename "$0") --email user@example.com --scan-only

  # Disable the admin account only, leaving SSH/cloud access alone
  $(basename "$0") --email user@example.com --scope admin

  # Delete the admin account only
  $(basename "$0") --email user@example.com --scope admin --admin-action delete

  # Rotate the admin password only (e.g. a shared account)
  $(basename "$0") --email user@example.com --scope admin --admin-action password

  # Revoke SSH/cloud access only, leaving the admin account alone
  $(basename "$0") --email user@example.com --scope cloud

  # Target a specific project
  $(basename "$0") --email user@example.com --project abc123xyz
EOF
}

# Count lines matching a pattern. grep -c already prints 0 when there are no
# matches but exits 1, so swallow the status instead of echoing a second value.
count_matching() {
  local count
  count=$(grep -c "$1" "$2" 2>/dev/null || true)
  echo "${count:-0}"
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

# Fail with a readable message when a value-taking flag is last on the command
# line. Without this, set -u aborts with a bare "$2: unbound variable".
require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    print_error "Option $1 requires a value."
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --email)
      require_value "$@"
      TARGET_EMAIL="$2"
      shift 2
      ;;
    --scan-only)
      SCAN_ONLY=true
      shift
      ;;
    --project)
      require_value "$@"
      TARGET_PROJECT="$2"
      shift 2
      ;;
    --scope)
      require_value "$@"
      SCOPE="$2"
      shift 2
      ;;
    --admin-action)
      require_value "$@"
      ADMIN_ACTION="$2"
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

# Reject characters that could be used for shell or PHP injection
if [[ "$TARGET_EMAIL" =~ [\'\"\;\|\$\`\\] ]]; then
  print_error "Email contains disallowed characters: $TARGET_EMAIL"
  exit 1
fi

# The project filter is used as a grep pattern below, so keep it to literal
# characters -- a pattern like '.*' would silently widen the run to all projects.
if [[ -n "$TARGET_PROJECT" && ! "$TARGET_PROJECT" =~ ^[A-Za-z0-9_-]+$ ]]; then
  print_error "Invalid project ID: $TARGET_PROJECT"
  exit 1
fi

case "$SCOPE" in
  all|admin|cloud) ;;
  *)
    print_error "Invalid --scope '$SCOPE'. Expected one of: all, admin, cloud"
    exit 1
    ;;
esac

case "$ADMIN_ACTION" in
  disable|delete|password) ;;
  *)
    print_error "Invalid --admin-action '$ADMIN_ACTION'. Expected one of: disable, delete, password"
    exit 1
    ;;
esac

if [[ "$SCOPE" == "cloud" && "$ADMIN_ACTION" != "disable" ]]; then
  print_warn "--admin-action is ignored with --scope cloud (admin accounts are not touched)."
fi

# Derived flags used throughout the scan and action phases
DO_CLOUD=false
DO_ADMIN=false
[[ "$SCOPE" == "all" || "$SCOPE" == "cloud" ]] && DO_CLOUD=true
[[ "$SCOPE" == "all" || "$SCOPE" == "admin" ]] && DO_ADMIN=true

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
# Audit log setup
#-------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/offboarding_logs"
if mkdir -p "$LOG_DIR" 2>/dev/null; then
  SANITIZED_EMAIL=$(echo "$TARGET_EMAIL" | sed 's/@/_/g; s/[^a-zA-Z0-9._-]//g')
  LOG_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
  AUDIT_LOG="${LOG_DIR}/offboard_${SANITIZED_EMAIL}_${LOG_TIMESTAMP}.log"
  {
    echo "Offboarding Audit Log"
    echo "====================="
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Target email: $TARGET_EMAIL"
    echo "Operator: $(whoami)"
    echo "Mode: $(if [[ "$SCAN_ONLY" == true ]]; then echo 'scan-only'; else echo 'full'; fi)"
    echo "Scope: $SCOPE"
    if [[ "$DO_ADMIN" == true ]]; then
      echo "Admin action: $ADMIN_ACTION"
    fi
    if [[ -n "$TARGET_PROJECT" ]]; then
      echo "Project filter: $TARGET_PROJECT"
    fi
    echo ""
  } > "$AUDIT_LOG"
else
  print_warn "Could not create audit log directory: $LOG_DIR"
fi

#-------------------------------------------------------------------------------
# PHP code templates
#
# The target email is passed via the OFFBOARD_EMAIL environment variable
# (base64-encoded) rather than embedded in the PHP source, to prevent
# injection if the email contains characters like ' or ;.
#-------------------------------------------------------------------------------

# Shared preamble: defines offboard_pdo() and $email. Every snippet below is
# concatenated onto this, so only the preamble carries the <?php tag.
read -r -d '' PHP_PREAMBLE << 'PHPEOF' || true
<?php
function offboard_pdo() {
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
    return new PDO($dsn, $db['username'], $db['password'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
    ]);
}

// Terminate any live admin session for the user. Best-effort: a missing
// admin_user_session table must not fail the action that called this.
function offboard_purge_sessions(PDO $pdo, $email) {
    try {
        $stmt = $pdo->prepare(
            'DELETE s FROM admin_user_session s'
            . ' INNER JOIN admin_user u ON u.user_id = s.user_id'
            . ' WHERE LOWER(u.email) = LOWER(?)'
        );
        $stmt->execute([$email]);
        echo "SESSIONS:" . $stmt->rowCount() . "\n";
    } catch (PDOException $e) {
        echo "SESSIONS:skipped\n";
    }
}

$email = base64_decode(getenv('OFFBOARD_EMAIL'));
PHPEOF

# Check if admin user exists. Returns "username|email|is_active" per row.
# Empty output = not found. Exit 1 on error.
read -r -d '' PHP_CHECK_ADMIN_BODY << 'PHPEOF' || true
try {
    $pdo = offboard_pdo();
    $stmt = $pdo->prepare('SELECT username, email, is_active FROM admin_user WHERE LOWER(email) = LOWER(?)');
    $stmt->execute([$email]);
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
read -r -d '' PHP_DISABLE_ADMIN_BODY << 'PHPEOF' || true
try {
    $pdo = offboard_pdo();
    $stmt = $pdo->prepare('UPDATE admin_user SET is_active = 0 WHERE LOWER(email) = LOWER(?) AND is_active = 1');
    $stmt->execute([$email]);
    $affected = $stmt->rowCount();
    if ($affected > 0) {
        offboard_purge_sessions($pdo, $email);
    }
    echo "DISABLED:" . $affected . "\n";
} catch (PDOException $e) {
    fwrite(STDERR, "ERROR: " . $e->getMessage() . "\n");
    exit(1);
}
PHPEOF

# Delete admin user. Sessions are purged first; admin_passwords and other
# child rows are removed by their ON DELETE CASCADE constraints.
# Returns "DELETED:N" where N is the number of rows removed.
read -r -d '' PHP_DELETE_ADMIN_BODY << 'PHPEOF' || true
try {
    $pdo = offboard_pdo();
    offboard_purge_sessions($pdo, $email);
    $stmt = $pdo->prepare('DELETE FROM admin_user WHERE LOWER(email) = LOWER(?)');
    $stmt->execute([$email]);
    echo "DELETED:" . $stmt->rowCount() . "\n";
} catch (PDOException $e) {
    fwrite(STDERR, "ERROR: " . $e->getMessage() . "\n");
    exit(1);
}
PHPEOF

# Rotate the admin user's password to the value in OFFBOARD_NEW_PASSWORD.
#
# Magento bootstraps here so the hash is produced by the installed
# EncryptorInterface -- that keeps the hash format (salt and version, e.g.
# argon2id vs sha256) exactly as this release expects instead of guessing it.
# Reset tokens are cleared so a pending "forgot password" email cannot be used
# to set a new password, and live sessions are terminated.
# Returns "PASSWORD:N" where N is the number of rows updated.
read -r -d '' PHP_PASSWORD_ADMIN_BODY << 'PHPEOF' || true
try {
    $newPassword = base64_decode(getenv('OFFBOARD_NEW_PASSWORD'));
    if ($newPassword === '' || $newPassword === false) {
        fwrite(STDERR, "ERROR: OFFBOARD_NEW_PASSWORD not available\n");
        exit(1);
    }

    $appDir = getenv('MAGENTO_CLOUD_APP_DIR') ?: '/app';
    if (!is_file($appDir . '/app/bootstrap.php')) {
        fwrite(STDERR, "ERROR: Magento bootstrap not found at " . $appDir . "/app/bootstrap.php\n");
        exit(1);
    }
    require $appDir . '/app/bootstrap.php';
    $bootstrap = \Magento\Framework\App\Bootstrap::create($appDir, []);
    $encryptor = $bootstrap->getObjectManager()
        ->get(\Magento\Framework\Encryption\EncryptorInterface::class);
    $hash = $encryptor->getHash($newPassword, true);

    $pdo = offboard_pdo();
    $stmt = $pdo->prepare(
        'UPDATE admin_user SET password = ?, rp_token = NULL, rp_token_created_at = NULL'
        . ' WHERE LOWER(email) = LOWER(?)'
    );
    $stmt->execute([$hash, $email]);
    $affected = $stmt->rowCount();
    if ($affected > 0) {
        offboard_purge_sessions($pdo, $email);
    }
    echo "PASSWORD:" . $affected . "\n";
} catch (Throwable $e) {
    fwrite(STDERR, "ERROR: " . $e->getMessage() . "\n");
    exit(1);
}
PHPEOF

PHP_CHECK_ADMIN="${PHP_PREAMBLE}
${PHP_CHECK_ADMIN_BODY}"
PHP_DISABLE_ADMIN="${PHP_PREAMBLE}
${PHP_DISABLE_ADMIN_BODY}"
PHP_DELETE_ADMIN="${PHP_PREAMBLE}
${PHP_DELETE_ADMIN_BODY}"
PHP_PASSWORD_ADMIN="${PHP_PREAMBLE}
${PHP_PASSWORD_ADMIN_BODY}"

#-------------------------------------------------------------------------------
# generate_password() - Generate a random password that satisfies Magento's
# admin password rules (length plus multiple character classes).
#-------------------------------------------------------------------------------

generate_password() {
  # Read a fixed 96 bytes rather than piping /dev/urandom into `head -c`: with
  # pipefail, the truncating head kills the upstream reader with SIGPIPE and the
  # non-zero pipeline status would abort the script under errexit.
  local pool
  pool=$(head -c 96 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9')
  # Prefix guarantees one of each required character class regardless of what
  # the random draw produced. Only shell-safe punctuation is used.
  printf 'Aa1%s#' "${pool:0:24}"
}

#-------------------------------------------------------------------------------
# run_remote_php() - Execute PHP code on a remote environment via SSH
# Args: $1 = project_id, $2 = environment_id, $3 = php_code,
#       $4 = optional new password (for the password rotation action)
# Returns: stdout from PHP execution, exit code from SSH
#
# The target email and the new password are passed as base64-encoded
# OFFBOARD_EMAIL / OFFBOARD_NEW_PASSWORD environment variables rather than
# being injected into the PHP source or the remote command line.
#-------------------------------------------------------------------------------

run_remote_php() {
  local project_id="$1"
  local env_id="$2"
  local php_code="$3"
  local new_password="${4:-}"

  local encoded_php encoded_email encoded_password
  encoded_php=$(echo "$php_code" | base64)
  encoded_email=$(printf '%s' "$TARGET_EMAIL" | base64)
  encoded_password=$(printf '%s' "$new_password" | base64)

  # stderr goes to a file named after the target so the caller can report why a
  # remote call failed. run_remote_php is normally invoked inside a command
  # substitution (a subshell), so a variable could not carry it back.
  local err_file
  err_file="$(remote_err_file "$project_id" "$env_id")"

  # </dev/null is essential: ssh reads and forwards stdin, and every caller
  # invokes this from inside a `while read` loop. Without it, ssh swallows the
  # remaining environments or admin accounts and they are silently skipped.
  magento-cloud ssh -p "$project_id" -e "$env_id" --no-interaction -- \
    "export OFFBOARD_EMAIL='${encoded_email}' OFFBOARD_NEW_PASSWORD='${encoded_password}'; echo '${encoded_php}' | base64 --decode | php" \
    2>"$err_file" </dev/null
}

# Path of the stderr capture file for a project/environment pair. Unique per
# pair so parallel scans do not clobber each other.
remote_err_file() {
  local key
  key=$(printf '%s_%s' "$1" "$2" | tr -c '[:alnum:]._-' '_')
  echo "${TMP_DIR}/remote_err_${key}.txt"
}

# First line of the captured remote error, for one-line failure reporting.
remote_err_summary() {
  local err_file
  err_file="$(remote_err_file "$1" "$2")"
  if [[ -s "$err_file" ]]; then
    head -1 "$err_file" | cut -c1-160
  fi
}

#-------------------------------------------------------------------------------
# scan_project() - Scan a single project for cloud access and admin accounts
# Args: $1 = project_id, $2 = project_title
# Writes results to per-project temp files in $TMP_DIR.
# Designed to run as a background job for parallel scanning.
#-------------------------------------------------------------------------------

scan_project() {
  trap - EXIT  # Don't inherit parent's cleanup trap in subshell

  local project_id="$1"
  local project_title="$2"

  local proj_cloud_scan="${TMP_DIR}/${project_id}_cloud_scan.txt"
  local proj_admin_scan="${TMP_DIR}/${project_id}_admin_scan.txt"
  local proj_cloud_results="${TMP_DIR}/${project_id}_cloud_results.txt"
  local proj_admin_results="${TMP_DIR}/${project_id}_admin_results.txt"

  # -- Check cloud platform access --
  if [[ "$DO_CLOUD" == false ]]; then
    echo "${project_id}|skipped" > "$proj_cloud_scan"
  else
    local cloud_fetch_ok=true
    local user_list
    user_list=$(magento-cloud user:list -p "$project_id" --format=plain --no-header --columns="email" 2>/dev/null) || {
      cloud_fetch_ok=false
    }

    if [[ "$cloud_fetch_ok" == false ]]; then
      echo "${project_id}|[failed]" > "$proj_cloud_scan"
    elif echo "$user_list" | grep -Fix "$TARGET_EMAIL" &>/dev/null; then
      echo "${project_id}|found" > "$proj_cloud_scan"
      echo "${project_id}|${project_title}|FOUND" > "$proj_cloud_results"
    else
      echo "${project_id}|not found" > "$proj_cloud_scan"
    fi
  fi

  # Admin scan is the expensive part (one SSH round trip per environment), so
  # skip it entirely when only cloud access is in scope.
  if [[ "$DO_ADMIN" == false ]]; then
    echo "${project_id}|--|skipped" > "$proj_admin_scan"
    return 0
  fi

  # -- Discover production and staging environments --
  local env_fetch_ok=true
  local env_list
  env_list=$(magento-cloud environment:list -p "$project_id" --type=production,staging --format=plain --no-header --columns="id" 2>/dev/null) || {
    env_fetch_ok=false
  }

  if [[ "$env_fetch_ok" == false ]]; then
    echo "${project_id}|--|[env list failed]" > "$proj_admin_scan"
    return 0
  fi

  if [[ -z "$env_list" ]]; then
    echo "${project_id}|--|--" > "$proj_admin_scan"
    return 0
  fi

  local has_env=false
  while IFS= read -r env_id; do
    [[ -z "$env_id" ]] && continue
    env_id=$(echo "$env_id" | tr -d '[:space:]')
    has_env=true

    local admin_check_ok=true
    local admin_output
    admin_output=$(run_remote_php "$project_id" "$env_id" "$PHP_CHECK_ADMIN") || {
      admin_check_ok=false
    }

    if [[ "$admin_check_ok" == false ]]; then
      echo "${project_id}|${env_id}|[scan failed]" >> "$proj_admin_scan"
      continue
    fi

    if [[ -n "$admin_output" ]]; then
      while IFS= read -r admin_row; do
        [[ -z "$admin_row" ]] && continue
        local admin_username admin_is_active admin_status_label
        admin_username=$(echo "$admin_row" | cut -d'|' -f1)
        admin_is_active=$(echo "$admin_row" | cut -d'|' -f3)
        if [[ "$admin_is_active" == "1" ]]; then
          admin_status_label="active"
        else
          admin_status_label="inactive"
        fi
        echo "${project_id}|${env_id}|${admin_username} [${admin_status_label}]" >> "$proj_admin_scan"
        echo "${project_id}|${project_title}|${env_id}|${admin_username}|${admin_is_active}" >> "$proj_admin_results"
      done <<< "$admin_output"
    else
      echo "${project_id}|${env_id}|not found" >> "$proj_admin_scan"
    fi
  done <<< "$env_list"

  if [[ "$has_env" == false ]]; then
    echo "${project_id}|--|--" >> "$proj_admin_scan"
  fi

  return 0
}

#-------------------------------------------------------------------------------
# Scan phase
#-------------------------------------------------------------------------------

print_header "Commerce Cloud User Offboarding"
echo "" >&2
print_info "Target email: $TARGET_EMAIL"
case "$SCOPE" in
  all)   print_info "Scope: cloud platform access + admin panel" ;;
  admin) print_info "Scope: admin panel only (cloud/SSH access will not be touched)" ;;
  cloud) print_info "Scope: cloud platform access only (admin panel will not be touched)" ;;
esac
if [[ "$DO_ADMIN" == true ]]; then
  print_info "Admin action: $ADMIN_ACTION"
fi
if [[ "$SCAN_ONLY" == true ]]; then
  print_warn "Scan-only mode: no changes will be made"
fi
if [[ -n "$TARGET_PROJECT" ]]; then
  print_info "Project filter: $TARGET_PROJECT"
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

# Filter to a single project if --project was specified
if [[ -n "$TARGET_PROJECT" ]]; then
  FILTERED=$(echo "$PROJECT_LIST" | grep "^${TARGET_PROJECT} " || true)
  if [[ -z "$FILTERED" ]]; then
    print_error "Project '${TARGET_PROJECT}' not found in project list."
    print_info "Available projects:"
    echo "$PROJECT_LIST" | awk '{print "  " $1}' >&2
    exit 1
  fi
  PROJECT_LIST="$FILTERED"
fi

PROJECT_COUNT=$(echo "$PROJECT_LIST" | wc -l | tr -d ' ')
print_info "Found $PROJECT_COUNT project(s)"
echo "" >&2

# Launch parallel scans with concurrency limit
MAX_PARALLEL=5
batch_pids=()
completed=0

printf "  Scanning: 0/%d projects completed" "$PROJECT_COUNT" >&2

while IFS= read -r line; do
  PROJECT_ID=$(echo "$line" | awk '{print $1}')
  PROJECT_TITLE=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')

  # Track project order and title
  echo "${PROJECT_ID}|${PROJECT_TITLE}" >> "$PROJECT_ORDER_FILE"

  scan_project "$PROJECT_ID" "$PROJECT_TITLE" &
  batch_pids+=($!)

  if [[ ${#batch_pids[@]} -ge $MAX_PARALLEL ]]; then
    for pid in "${batch_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    completed=$((completed + ${#batch_pids[@]}))
    printf "\r  Scanning: %d/%d projects completed" "$completed" "$PROJECT_COUNT" >&2
    batch_pids=()
  fi
done <<< "$PROJECT_LIST"

# Wait for remaining jobs in the last (possibly partial) batch
if [[ ${#batch_pids[@]} -gt 0 ]]; then
  for pid in "${batch_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  completed=$((completed + ${#batch_pids[@]}))
fi

printf "\r  Scanning: %d/%d projects completed\n" "$completed" "$PROJECT_COUNT" >&2
echo "" >&2

# Merge per-project results in original project order
while IFS='|' read -r proj_id _; do
  [[ -f "${TMP_DIR}/${proj_id}_cloud_scan.txt" ]] && cat "${TMP_DIR}/${proj_id}_cloud_scan.txt" >> "$CLOUD_SCAN_FILE"
  [[ -f "${TMP_DIR}/${proj_id}_admin_scan.txt" ]] && cat "${TMP_DIR}/${proj_id}_admin_scan.txt" >> "$ADMIN_SCAN_FILE"
  [[ -f "${TMP_DIR}/${proj_id}_cloud_results.txt" ]] && cat "${TMP_DIR}/${proj_id}_cloud_results.txt" >> "$CLOUD_RESULTS_FILE"
  [[ -f "${TMP_DIR}/${proj_id}_admin_results.txt" ]] && cat "${TMP_DIR}/${proj_id}_admin_results.txt" >> "$ADMIN_RESULTS_FILE"
done < "$PROJECT_ORDER_FILE"

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
  # Look up cloud status for this project. The || true matters under pipefail:
  # a project whose scan file never appeared would otherwise abort the script.
  CLOUD_STATUS=$(grep "^${proj_id}|" "$CLOUD_SCAN_FILE" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
  CLOUD_STATUS="${CLOUD_STATUS:-[no result]}"

  # Look up admin results for this project (may be multiple lines)
  ADMIN_LINES=$(grep "^${proj_id}|" "$ADMIN_SCAN_FILE" || true)

  # Determine display color for cloud status
  CLOUD_DISPLAY="$CLOUD_STATUS"
  case "$CLOUD_STATUS" in
    found)
      CLOUD_DISPLAY="${RED}found${NC}"
      FOUND_ANYTHING=true
      ;;
    "not found"|skipped)
      CLOUD_DISPLAY="${DIM}${CLOUD_STATUS}${NC}"
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
      elif [[ "$admin_result" == "not found" || "$admin_result" == "--" || "$admin_result" == "skipped" ]]; then
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
CLOUD_FOUND_COUNT=$(count_matching "|found$" "$CLOUD_SCAN_FILE")
ADMIN_ACTIVE_COUNT=$(count_matching '|1$' "$ADMIN_RESULTS_FILE")
ADMIN_INACTIVE_COUNT=$(count_matching '|0$' "$ADMIN_RESULTS_FILE")

SUMMARY_TEXT="${CLOUD_FOUND_COUNT} cloud access, ${ADMIN_ACTIVE_COUNT} active admin, ${ADMIN_INACTIVE_COUNT} inactive admin across ${PROJECT_COUNT} projects"
if [[ "$DO_CLOUD" == false ]]; then
  SUMMARY_TEXT="${ADMIN_ACTIVE_COUNT} active admin, ${ADMIN_INACTIVE_COUNT} inactive admin across ${PROJECT_COUNT} projects (cloud access not scanned)"
elif [[ "$DO_ADMIN" == false ]]; then
  SUMMARY_TEXT="${CLOUD_FOUND_COUNT} cloud access across ${PROJECT_COUNT} projects (admin panel not scanned)"
fi

echo -e "  ${BLUE}Summary:${NC} ${SUMMARY_TEXT}" >&2
echo "" >&2

if [[ "$HAS_SCAN_FAILURES" == true ]]; then
  echo -e "  ${YELLOW}[scan failed]${NC} = could not SSH into the environment to query the admin_user table." >&2
  echo -e "  Common causes: your SSH key is not added to the project, the environment is" >&2
  echo -e "  suspended/inactive, or the environment does not have a database relationship." >&2
  echo -e "  These environments were skipped -- check them manually if needed." >&2
  echo "" >&2
fi

# Write scan results to audit log
if [[ -n "${AUDIT_LOG:-}" ]]; then
  {
    echo "Scan Results"
    echo "============"
    echo ""
    printf "  %-35s  %-14s  %-14s  %-30s\n" "Project" "Cloud Access" "Environment" "Admin Account"
    printf "  %-35s  %-14s  %-14s  %-30s\n" \
      "-----------------------------------" "--------------" "--------------" "------------------------------"

    while IFS='|' read -r pid ptitle; do
      cstatus=$(grep "^${pid}|" "$CLOUD_SCAN_FILE" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
      cstatus="${cstatus:-[no result]}"
      alines=$(grep "^${pid}|" "$ADMIN_SCAN_FILE" || true)
      dtitle=$(truncate_str "$ptitle" 35)

      first=true
      if [[ -n "$alines" ]]; then
        while IFS='|' read -r _ eid aresult; do
          if [[ "$first" == true ]]; then
            printf "  %-35s  %-14s  %-14s  %-30s\n" "$dtitle" "$cstatus" "$eid" "$aresult"
            first=false
          else
            printf "  %-35s  %-14s  %-14s  %-30s\n" "" "" "$eid" "$aresult"
          fi
        done <<< "$alines"
      else
        printf "  %-35s  %-14s  %-14s  %-30s\n" "$dtitle" "$cstatus" "--" "--"
      fi
    done < "$PROJECT_ORDER_FILE"

    echo ""
    echo "Summary: ${SUMMARY_TEXT}"
    echo ""
  } >> "$AUDIT_LOG"
fi

if [[ "$FOUND_ANYTHING" == false ]]; then
  case "$SCOPE" in
    all)   NOTHING_FOUND_TEXT="No cloud access or admin accounts found" ;;
    admin) NOTHING_FOUND_TEXT="No admin accounts found" ;;
    cloud) NOTHING_FOUND_TEXT="No cloud access found" ;;
  esac
  print_info "${NOTHING_FOUND_TEXT} for $TARGET_EMAIL"
  print_info "Nothing to do."
  if [[ -n "${AUDIT_LOG:-}" ]]; then
    audit_write "${NOTHING_FOUND_TEXT}. Nothing to do."
    echo "" >&2
    print_info "Audit log written to: $AUDIT_LOG"
  fi
  exit 0
fi

#-------------------------------------------------------------------------------
# Scan-only mode exits here
#-------------------------------------------------------------------------------

if [[ "$SCAN_ONLY" == true ]]; then
  RERUN_FLAGS="--email ${TARGET_EMAIL}"
  [[ "$SCOPE" != "all" ]] && RERUN_FLAGS="${RERUN_FLAGS} --scope ${SCOPE}"
  [[ "$ADMIN_ACTION" != "disable" ]] && RERUN_FLAGS="${RERUN_FLAGS} --admin-action ${ADMIN_ACTION}"
  [[ -n "$TARGET_PROJECT" ]] && RERUN_FLAGS="${RERUN_FLAGS} --project ${TARGET_PROJECT}"

  print_info "Scan-only mode -- no changes made."
  echo "" >&2
  echo -e "  To proceed with removal, run:" >&2
  echo -e "  ${BLUE}./$(basename "$0") ${RERUN_FLAGS}${NC}" >&2
  echo "" >&2
  if [[ -n "${AUDIT_LOG:-}" ]]; then
    audit_write "Scan-only mode -- no changes made."
    print_info "Audit log written to: $AUDIT_LOG"
  fi
  exit 0
fi

#-------------------------------------------------------------------------------
# Confirmation prompt
#-------------------------------------------------------------------------------

CLOUD_COUNT=$(wc -l < "$CLOUD_RESULTS_FILE" | tr -d ' ')
ADMIN_COUNT=$(wc -l < "$ADMIN_RESULTS_FILE" | tr -d ' ')

case "$ADMIN_ACTION" in
  disable)  ADMIN_ACTION_DESC="Disable admin account(s)" ;;
  delete)   ADMIN_ACTION_DESC="DELETE admin account(s)" ;;
  password) ADMIN_ACTION_DESC="Rotate the password of admin account(s)" ;;
esac

echo -e "${RED}The following actions will be performed:${NC}" >&2
if [[ "$CLOUD_COUNT" -gt 0 ]]; then
  echo "  - Remove cloud platform access (SSH + Git) from $CLOUD_COUNT project(s)" >&2
fi
if [[ "$ADMIN_COUNT" -gt 0 ]]; then
  echo "  - ${ADMIN_ACTION_DESC} in $ADMIN_COUNT environment(s)" >&2
fi
if [[ "$DO_CLOUD" == false ]]; then
  echo -e "  ${DIM}Cloud platform access (SSH + Git) will NOT be changed.${NC}" >&2
fi
if [[ "$DO_ADMIN" == false ]]; then
  echo -e "  ${DIM}Admin panel accounts will NOT be changed.${NC}" >&2
fi
if [[ "$ADMIN_ACTION" == "delete" && "$ADMIN_COUNT" -gt 0 ]]; then
  echo "" >&2
  print_warn "Deleting admin_user rows is irreversible and loses the account's audit trail."
fi
echo "" >&2

read -r -p "Proceed? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  print_info "Aborted."
  if [[ -n "${AUDIT_LOG:-}" ]]; then
    audit_write "User aborted at confirmation prompt."
    print_info "Audit log written to: $AUDIT_LOG"
  fi
  exit 0
fi

echo "" >&2
audit_write "Actions" "=======" ""

#-------------------------------------------------------------------------------
# Removal phase
#-------------------------------------------------------------------------------

print_header "Applying Changes"
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
    # </dev/null so the CLI cannot consume the remaining lines of this loop.
    if magento-cloud user:delete "$TARGET_EMAIL" -p "$proj_id" -y --no-interaction 2>/dev/null </dev/null; then
      print_info "  Removed from ${proj_title} (${proj_id})"
      audit_write "  [cloud] REMOVED: ${proj_title} (${proj_id})"
      CLOUD_SUCCESS=$((CLOUD_SUCCESS + 1))
    else
      print_error "  Failed to remove from ${proj_title} (${proj_id})"
      audit_write "  [cloud] FAILED: ${proj_title} (${proj_id})"
      echo "${proj_id}|${proj_title}" >> "$CLOUD_FAILURES_FILE"
      CLOUD_FAILED=$((CLOUD_FAILED + 1))
    fi
  done < "$CLOUD_RESULTS_FILE"
  echo "" >&2
fi

# Act on admin accounts. The PHP snippet, its success marker and the past-tense
# verb used in output all follow from --admin-action.
if [[ "$ADMIN_COUNT" -gt 0 ]]; then
  case "$ADMIN_ACTION" in
    disable)
      ADMIN_PHP="$PHP_DISABLE_ADMIN"
      ADMIN_MARKER="DISABLED"
      ADMIN_VERB="Disabled"
      echo -e "${BLUE}Disabling admin accounts...${NC}" >&2
      ;;
    delete)
      ADMIN_PHP="$PHP_DELETE_ADMIN"
      ADMIN_MARKER="DELETED"
      ADMIN_VERB="Deleted"
      echo -e "${BLUE}Deleting admin accounts...${NC}" >&2
      ;;
    password)
      ADMIN_PHP="$PHP_PASSWORD_ADMIN"
      ADMIN_MARKER="PASSWORD"
      ADMIN_VERB="Rotated password for"
      echo -e "${BLUE}Rotating admin passwords...${NC}" >&2
      ;;
  esac

  ADMIN_PASSWORDS_FILE="${TMP_DIR}/admin_passwords.txt"
  touch "$ADMIN_PASSWORDS_FILE"

  while IFS='|' read -r proj_id proj_title env_id username is_active; do
    # Only 'disable' is a no-op on an already-inactive account. Deleting or
    # rotating the password of an inactive account is still meaningful.
    if [[ "$ADMIN_ACTION" == "disable" && "$is_active" != "1" ]]; then
      print_warn "  Skipped ${username} on ${proj_title}/${env_id} (already inactive)"
      audit_write "  [admin] SKIPPED: ${username} on ${proj_title}/${env_id} (already inactive)"
      echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_SKIPS_FILE"
      ADMIN_SKIPPED=$((ADMIN_SKIPPED + 1))
      continue
    fi

    # A distinct password per environment, so one leaked value does not unlock
    # the account everywhere.
    NEW_PASSWORD=""
    if [[ "$ADMIN_ACTION" == "password" ]]; then
      NEW_PASSWORD=$(generate_password)
    fi

    ADMIN_OUTPUT=$(run_remote_php "$proj_id" "$env_id" "$ADMIN_PHP" "$NEW_PASSWORD") || {
      REMOTE_ERROR=$(remote_err_summary "$proj_id" "$env_id")
      print_error "  Failed to apply ${ADMIN_ACTION} to ${username} on ${proj_title}/${env_id}"
      if [[ -n "$REMOTE_ERROR" ]]; then
        print_error "    ${REMOTE_ERROR}"
      fi
      audit_write "  [admin] FAILED: ${username} on ${proj_title}/${env_id}${REMOTE_ERROR:+ -- ${REMOTE_ERROR}}"
      echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_FAILURES_FILE"
      ADMIN_FAILED=$((ADMIN_FAILED + 1))
      continue
    }

    if echo "$ADMIN_OUTPUT" | grep -q "^${ADMIN_MARKER}:"; then
      AFFECTED_COUNT=$(echo "$ADMIN_OUTPUT" | grep -o "${ADMIN_MARKER}:[0-9]*" | cut -d: -f2)
      if [[ "$AFFECTED_COUNT" -gt 0 ]]; then
        print_info "  ${ADMIN_VERB} ${username} on ${proj_title}/${env_id}"
        audit_write "  [admin] ${ADMIN_MARKER}: ${username} on ${proj_title}/${env_id}"
        if [[ "$ADMIN_ACTION" == "password" ]]; then
          # Printed at the end and never written to the audit log.
          echo "${proj_title}|${env_id}|${username}|${NEW_PASSWORD}" >> "$ADMIN_PASSWORDS_FILE"
        fi
        ADMIN_SUCCESS=$((ADMIN_SUCCESS + 1))
      else
        print_warn "  Skipped ${username} on ${proj_title}/${env_id} (no rows affected)"
        audit_write "  [admin] SKIPPED: ${username} on ${proj_title}/${env_id} (no rows affected)"
        echo "${proj_id}|${proj_title}|${env_id}|${username}" >> "$ADMIN_SKIPS_FILE"
        ADMIN_SKIPPED=$((ADMIN_SKIPPED + 1))
      fi
    else
      print_error "  Unexpected response for ${username} on ${proj_title}/${env_id}"
      audit_write "  [admin] FAILED: ${username} on ${proj_title}/${env_id} (unexpected response)"
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
if [[ "$DO_CLOUD" == false ]]; then
  echo -e "    ${DIM}Not in scope -- unchanged (SSH and Git access retained)${NC}" >&2
else
  echo -e "    ${GREEN}Removed:${NC} $CLOUD_SUCCESS" >&2
  if [[ "$CLOUD_FAILED" -gt 0 ]]; then
    echo -e "    ${RED}Failed:${NC}  $CLOUD_FAILED" >&2
  fi
fi
echo "" >&2

echo -e "  ${BLUE}Admin panel accounts:${NC}" >&2
if [[ "$DO_ADMIN" == false ]]; then
  echo -e "    ${DIM}Not in scope -- unchanged${NC}" >&2
else
  case "$ADMIN_ACTION" in
    disable)  ADMIN_RESULT_LABEL="Disabled:" ;;
    delete)   ADMIN_RESULT_LABEL="Deleted: " ;;
    password) ADMIN_RESULT_LABEL="Rotated: " ;;
  esac
  echo -e "    ${GREEN}${ADMIN_RESULT_LABEL}${NC} $ADMIN_SUCCESS" >&2
  if [[ "$ADMIN_SKIPPED" -gt 0 ]]; then
    echo -e "    ${YELLOW}Skipped:${NC}  $ADMIN_SKIPPED" >&2
  fi
  if [[ "$ADMIN_FAILED" -gt 0 ]]; then
    echo -e "    ${RED}Failed:${NC}   $ADMIN_FAILED" >&2
  fi
fi
echo "" >&2

# Show rotated passwords once, on the terminal only.
if [[ "$ADMIN_ACTION" == "password" && -s "${ADMIN_PASSWORDS_FILE:-/dev/null}" ]]; then
  echo -e "  ${BLUE}New passwords${NC} ${DIM}(shown once, not written to the audit log)${NC}" >&2
  while IFS='|' read -r proj_title env_id username new_password; do
    echo -e "    ${proj_title} / ${env_id} / ${username}: ${YELLOW}${new_password}${NC}" >&2
  done < "$ADMIN_PASSWORDS_FILE"
  echo "" >&2
  print_warn "The account remains active. Use --admin-action disable to lock it out instead."
  echo "" >&2
fi

# Show details for failures
if [[ "$CLOUD_FAILED" -gt 0 ]]; then
  echo -e "  ${RED}Failed cloud removals:${NC}" >&2
  while IFS='|' read -r proj_id proj_title; do
    echo "    - ${proj_title} (${proj_id})" >&2
  done < "$CLOUD_FAILURES_FILE"
  echo "" >&2
fi

if [[ "$ADMIN_FAILED" -gt 0 ]]; then
  echo -e "  ${RED}Failed admin actions (${ADMIN_ACTION}):${NC}" >&2
  while IFS='|' read -r proj_id proj_title env_id username; do
    echo "    - ${proj_title} (${proj_id}) / ${env_id}: ${username}" >&2
  done < "$ADMIN_FAILURES_FILE"
  echo "" >&2
fi

# Write final report to audit log
if [[ -n "${AUDIT_LOG:-}" ]]; then
  {
    echo ""
    echo "Final Report"
    echo "============"
    echo ""
    echo "Cloud platform access:"
    if [[ "$DO_CLOUD" == false ]]; then
      echo "  Not in scope -- unchanged (SSH and Git access retained)"
    else
      echo "  Removed: $CLOUD_SUCCESS"
      [[ "$CLOUD_FAILED" -gt 0 ]] && echo "  Failed:  $CLOUD_FAILED"
    fi
    echo ""
    echo "Admin panel accounts (action: ${ADMIN_ACTION}):"
    if [[ "$DO_ADMIN" == false ]]; then
      echo "  Not in scope -- unchanged"
    else
      echo "  Succeeded: $ADMIN_SUCCESS"
      [[ "$ADMIN_SKIPPED" -gt 0 ]] && echo "  Skipped:   $ADMIN_SKIPPED"
      [[ "$ADMIN_FAILED" -gt 0 ]] && echo "  Failed:    $ADMIN_FAILED"
    fi
    echo ""
    if [[ "$CLOUD_FAILED" -gt 0 || "$ADMIN_FAILED" -gt 0 ]]; then
      echo "Status: COMPLETED WITH ERRORS"
    else
      echo "Status: COMPLETED SUCCESSFULLY"
    fi
  } >> "$AUDIT_LOG"
fi

if [[ "$CLOUD_FAILED" -gt 0 || "$ADMIN_FAILED" -gt 0 ]]; then
  print_warn "Some actions failed. Review the details above and retry manually if needed."
  if [[ -n "${AUDIT_LOG:-}" ]]; then
    echo "" >&2
    print_info "Audit log written to: $AUDIT_LOG"
  fi
  exit 1
fi

print_info "All actions completed successfully."
if [[ -n "${AUDIT_LOG:-}" ]]; then
  echo "" >&2
  print_info "Audit log written to: $AUDIT_LOG"
fi
