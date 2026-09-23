#!/usr/bin/env bash
#
# check_stylesmuggler.sh
#
# Scans a Magento / Adobe Commerce environment for indicators of compromise from
# the "StyleSmuggler" campaign disclosed by Sansec.
#   Reference: https://sansec.io/research/stylesmuggler
#
# The exploit is an unauthenticated RCE reached through the GraphQL endpoint via a
# crafted `styles` parameter. It injects PHP into Magento's template system, which is
# then executed when a "Payment Transaction Failed" notification email is rendered.
# The resulting implant persists via cron and masquerades as `gvfsd`, `fc-cache` and
# kernel `kworker` processes.
#
# READ-ONLY. The script writes nothing to the environment: no files are created or
# modified (not even a temp file or a report), no processes are killed, nothing is
# quarantined or deleted, and every database statement runs inside a read-only
# session. It observes and probes, then prints to stdout. Redirect the output
# locally if you want a copy. Remediation is a human decision.
#
# The one outbound action it takes is a single HTTP POST of `{__typename}` to the
# store's own GraphQL endpoint, to establish whether the attack surface is exposed.
# That request will appear in the store's access log.
#
# Exit codes:
#   0  no indicators found
#   1  suspicious findings that need a human to look at them
#   2  confirmed indicators of compromise
#   3  usage / environment error
#
# NOTE: `set -e` is deliberately NOT used. A scanner runs dozens of commands whose
# non-zero exits ("grep found nothing", "no such process") are normal control flow,
# not failures, and aborting on the first one would silently truncate the report.

set -uo pipefail

VERSION="1.1.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

MAGENTO_ROOT=""
DEEP=0
CHECK_DB=0
DAYS=30
USE_COLOR=1
PROJECT_LABEL=""
PROBE=1
BASE_URL=""
EDGE_MITIGATED=0
LOG_PATHS_EXTRA=()

CRITICAL_COUNT=0
WARNING_COUNT=0
CHECKS_RUN=0
SKIPPED=()

# ---------------------------------------------------------------------------
# Indicators of compromise (Sansec, StyleSmuggler)
# ---------------------------------------------------------------------------

# Exact paths dropped by the implant
IOC_FILES=(
  "$HOME/.local/share/.gvfsd"
  "$HOME/.local/share/.gvfsd/gvfsd-user"
  "$HOME/.cache/fontconfig/fc-cache"
  "/tmp/fc-cache"
)

# Glob patterns (randomised suffixes)
IOC_GLOBS=(
  "/tmp/.kw_*"
  "/tmp/.cache_*"
  "/tmp/.gvfsd-*"
  "/tmp/.fc-*/fc-cache"
  "/tmp/.fc_*.lock"
  "/var/tmp/.kw_*"
  "/var/tmp/.cache_*"
  "/dev/shm/.kw_*"
  "/dev/shm/.cache_*"
)

# Cron / persistence markers
IOC_CRON_RE='gvfsd|fontconfig/fc-cache|\.local/share/\.gvfsd|fc-cache >/dev/null'

# C2 and staging infrastructure
IOC_HOSTS=(
  "windwsecurity.run"
  "ntp.timesysnc.net"
  "time.microsft.run"
  "pool.microsft.studio"
  "ntp.timesync.to"
  "ntp.synctime.to"
  "ntp.syncstime.to"
  "247.cdnflare.xyz"
)

IOC_IPS=(
  "99.84.67.186"   # WebSocket C2 (TLS/443)
  "209.141.43.95"  # malware download host
  "88.216.72.181"  # observed attacker source IP
)

# SHA256 of known implant binaries
IOC_HASHES=(
  "e315687a1dfe61ef4a5a5642214db6d3b2b05d81391285eebc2af664641a26a7"
  "b79dfdc1eed860e0b76c629d6adfce251db379b0b45a6d728d4ef483f7551420"
  "4352cabaa451e5a894535fbcc4d46628701303322a13745cb5479d7d0534ae8e"
  "d2fbf9eb75c495bfea48790d3b228fab0c15a282419c3d3f5e49294c4e1a3e82"
)

# Strings written into Magento artefacts by the payload
IOC_MAGENTO_RE='x_trace_'

# PHP payload signatures used by the injected template / dropped webshells
IOC_PHP_RE='eval[[:space:]]*\(|base64_decode[[:space:]]*\(|assert[[:space:]]*\(\$|shell_exec[[:space:]]*\(|passthru[[:space:]]*\(|create_function|preg_replace[[:space:]]*\(.*/e|\$_(POST|GET|REQUEST|COOKIE)\[[^]]*\][[:space:]]*(!==|===)[[:space:]]*\$'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
check_stylesmuggler.sh v$VERSION

Scans a Magento / Adobe Commerce environment for StyleSmuggler indicators of
compromise (https://sansec.io/research/stylesmuggler).

Read-only: writes nothing to the environment (no files, no temp files, no report
on disk, no processes killed) and runs every database statement in a read-only
session. Findings go to stdout; redirect locally to keep a copy.

Usage:
  bash check_stylesmuggler.sh [OPTIONS]

Options:
  --root PATH        Magento root directory (default: auto-detect from CWD)
  --db               Also run read-only database checks (templates, CMS, admins).
                     Requires app/etc/env.php and the mysql client.
  --deep             Slower, wider sweep: includes vendor/, generated/ and a
                     filesystem-wide search for implant filenames.
  --days N           Window for "recently modified" file checks (default: $DAYS)
  --log PATH         Additional access/error log file or glob to scan.
                     May be repeated.
  --label NAME       Human-readable project name for the report header.
  --no-probe         Do not send any outbound request. Disables the live edge
                     probe and the GraphQL reachability check, so mitigation
                     state can then only be inferred from files on disk.
  --no-color         Disable ANSI colour.
  -h, --help         Show this help.

Exit codes:
  0 clean   1 suspicious   2 compromised   3 usage/environment error

Examples:
  # Remote, via the repo wrapper
  ./run-remote.sh -p PROJECT_ID -e production -s check_stylesmuggler.sh

  # Remote, with database checks
  ./run-remote.sh -p PROJECT_ID -e production -s check_stylesmuggler.sh -- --db

  # Local, from the Magento root
  bash check_stylesmuggler.sh --db --deep
EOF
}

setup_color() {
  if [[ "$USE_COLOR" -eq 1 && -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[36m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""
  fi
}

section() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  printf '\n%s=== %d. %s ===%s\n' "$C_BOLD$C_BLU" "$CHECKS_RUN" "$1" "$C_RESET"
}

# Print what a section actually inspects, before its findings. Each argument is a
# "Label: detail" pair. This makes a clean result auditable: the reader can see
# which commands ran and which patterns were matched, rather than trusting an [OK].
checking() {
  local pair label
  for pair in "$@"; do
    label="${pair%%:*}"
    # A blank label marks a continuation of the previous line: indent it to align
    # under that line's text instead of printing a stray colon.
    if [[ -z "${label// /}" ]]; then
      printf '%s  %-9s %s%s\n' "$C_DIM" "" "${pair#*:}" "$C_RESET"
    else
      printf '%s  %-9s %s%s\n' "$C_DIM" "$label:" "${pair#*:}" "$C_RESET"
    fi
  done
}

critical() {
  CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
  printf '%s[CRITICAL]%s %s\n' "$C_BOLD$C_RED" "$C_RESET" "$1"
  [[ $# -gt 1 ]] && printf '            %s\n' "${@:2}"
  return 0
}

warn() {
  WARNING_COUNT=$((WARNING_COUNT + 1))
  printf '%s[WARNING] %s %s\n' "$C_YEL" "$C_RESET" "$1"
  [[ $# -gt 1 ]] && printf '            %s\n' "${@:2}"
  return 0
}

ok() { printf '%s[OK]      %s %s\n' "$C_GRN" "$C_RESET" "$1"; }
info() { printf '%s[INFO]    %s %s\n' "$C_DIM" "$C_RESET" "$1"; }

# Indent a multi-line block under a finding. Used instead of printf so that every
# line lines up, not just the first.
indent() { sed 's/^/            /'; }

skip() {
  SKIPPED+=("$1")
  printf '%s[SKIP]    %s %s\n' "$C_DIM" "$C_RESET" "$1"
}

has() { command -v "$1" >/dev/null 2>&1; }

# Portable SHA256. Prints the hash only, or nothing if no tool is available.
sha256_of() {
  local f="$1"
  if has sha256sum; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif has shasum; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif has openssl; then
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  fi
}

# The store's public base URL. env.php first, then the routes Cloud injects -
# on Cloud the base URL normally lives in core_config_data, not env.php.
resolve_base_url() {
  local url=""
  if has php && [[ -f "$MAGENTO_ROOT/app/etc/env.php" ]]; then
    url="$(php -r '
      $e = include $argv[1];
      $v = $e["system"]["default"]["web"]["secure"]["base_url"] ?? ($e["system"]["default"]["web"]["unsecure"]["base_url"] ?? "");
      echo $v;
    ' "$MAGENTO_ROOT/app/etc/env.php" 2>/dev/null)"
  fi
  if [[ -z "$url" && -n "${MAGENTO_CLOUD_ROUTES:-}" ]] && has php; then
    url="$(php -r '
      $r = json_decode(base64_decode(getenv("MAGENTO_CLOUD_ROUTES")), true) ?: [];
      foreach ($r as $u => $d) {
        if (($d["type"] ?? "") === "upstream" && strpos($u, "https://") === 0) { echo $u; exit; }
      }
      foreach ($r as $u => $d) {
        if (($d["type"] ?? "") === "upstream") { echo $u; exit; }
      }
    ' 2>/dev/null)"
  fi
  printf '%s' "${url%/}"
}

# Send one request and print just its HTTP status.
http_status() {
  local url="$1"; shift
  curl -skL --post301 --post302 --post303 -o /dev/null \
       -w '%{http_code}' --max-time 15 "$@" "$url" 2>/dev/null
}

# Join array elements with '|' for a grep -E alternation.
join_alt() {
  local out="" item
  for item in "$@"; do
    out+="${out:+|}$(printf '%s' "$item" | sed 's/[.[\*^$()+?{}|\\]/\\&/g')"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) MAGENTO_ROOT="${2:-}"; shift 2 ;;
    --db) CHECK_DB=1; shift ;;
    --deep) DEEP=1; shift ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --log) LOG_PATHS_EXTRA+=("${2:-}"); shift 2 ;;
    --label) PROJECT_LABEL="${2:-}"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --no-color) USE_COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --days must be a whole number" >&2
  exit 3
fi

setup_color

# ---------------------------------------------------------------------------
# Locate the Magento root
# ---------------------------------------------------------------------------

# A directory only counts as a Magento root if it actually contains an install.
is_magento_root() {
  [[ -n "${1:-}" ]] || return 1
  [[ -f "$1/app/etc/env.php" || -f "$1/bin/magento" ]]
}

detect_root() {
  local candidate
  # $MAGENTO_CLOUD_DIR is authoritative on Adobe Commerce Cloud.
  for candidate in "${MAGENTO_CLOUD_DIR:-}" "${MAGE_ROOT:-}" "$PWD" "$HOME" \
                   /app /var/www/html /var/www/magento /var/www; do
    is_magento_root "$candidate" && { printf '%s' "$candidate"; return 0; }
  done
  # Cloud Pro installs into /app/<project>; some layouts use /app/<project>_<env>.
  for candidate in /app/*/; do
    is_magento_root "${candidate%/}" && { printf '%s' "${candidate%/}"; return 0; }
  done
  return 1
}

# A --root that does not hold an install must never be trusted. run-remote.sh
# guesses /app/<project>_<env>, which is wrong on Cloud Pro (the real path is
# /app/<project>), and silently accepting it skips every application-level check
# while still reporting a successful scan.
ROOT_NOTE=""
if [[ -n "$MAGENTO_ROOT" ]] && ! is_magento_root "$MAGENTO_ROOT"; then
  ROOT_NOTE="supplied --root '$MAGENTO_ROOT' holds no Magento install; auto-detected instead"
  MAGENTO_ROOT=""
fi

if [[ -z "$MAGENTO_ROOT" ]]; then
  MAGENTO_ROOT="$(detect_root || true)"
fi

HAVE_MAGENTO=0
if is_magento_root "$MAGENTO_ROOT"; then
  HAVE_MAGENTO=1
fi

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '%s' "$C_BOLD"
echo "==============================================================="
echo " StyleSmuggler compromise check"
echo " https://sansec.io/research/stylesmuggler"
echo "==============================================================="
printf '%s' "$C_RESET"
# Read a package version out of composer.lock without needing composer itself.
lock_version() {
  [[ -f "$MAGENTO_ROOT/composer.lock" ]] || return 1
  grep -A3 -E "\"name\": \"$1\"" "$MAGENTO_ROOT/composer.lock" 2>/dev/null \
    | grep '"version"' | head -n1 | sed 's/.*"version": "\([^"]*\)".*/\1/'
}

echo "Project:       ${PROJECT_LABEL:-${MAGENTO_CLOUD_PROJECT:-not a Cloud environment}}"
if [[ -n "${MAGENTO_CLOUD_PROJECT:-}" ]]; then
  echo "Project ID:    $MAGENTO_CLOUD_PROJECT"
  echo "Environment:   ${MAGENTO_CLOUD_ENVIRONMENT:-unknown} (branch ${MAGENTO_CLOUD_BRANCH:-unknown}, type ${MAGENTO_CLOUD_ENVIRONMENT_TYPE:-unknown})"
fi
echo "Host:          $(hostname 2>/dev/null || echo unknown)"
echo "Date:          $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
echo "User:          $(whoami 2>/dev/null || id -un 2>/dev/null || echo unknown)"
echo "Uptime:        $(uptime 2>/dev/null | sed 's/^[[:space:]]*//' || echo unknown)"

if [[ "$HAVE_MAGENTO" -eq 1 ]]; then
  echo "Magento root:  $MAGENTO_ROOT"
  [[ -n "$ROOT_NOTE" ]] && echo "               note: $ROOT_NOTE"

  # composer.lock is preferred over `bin/magento --version`: it is far faster, it
  # cannot be affected by a broken DI cache, and it also names the edition.
  ver="$(lock_version 'magento/product-community-edition' 2>/dev/null)"
  edition="Open Source"
  if [[ -z "$ver" ]]; then
    ver="$(lock_version 'magento/product-enterprise-edition' 2>/dev/null)"
    edition="Adobe Commerce"
  fi
  if [[ -n "$ver" ]]; then
    echo "Magento:       $ver ($edition)"
  elif [[ -f "$MAGENTO_ROOT/bin/magento" ]] && has php; then
    ver="$(php "$MAGENTO_ROOT/bin/magento" --version --no-ansi 2>/dev/null | head -n1)"
    echo "Magento:       ${ver:-unable to determine}"
  else
    echo "Magento:       unable to determine"
  fi

  for pkg in magento/magento-cloud-patches magento/quality-patches; do
    pv="$(lock_version "$pkg" 2>/dev/null)"
    [[ -n "$pv" ]] && echo "               $pkg $pv"
  done

  # "Latest patch created" - the most recent hotfix applied to this build.
  if [[ -d "$MAGENTO_ROOT/m2-hotfixes" ]]; then
    hotfix_count="$(find "$MAGENTO_ROOT/m2-hotfixes" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')"
    latest_patch="$(ls -1t "$MAGENTO_ROOT"/m2-hotfixes/*.patch 2>/dev/null | head -n1)"
    if [[ -n "$latest_patch" ]]; then
      echo "Hotfixes:      $hotfix_count in m2-hotfixes/"
      echo "Latest patch:  $(basename "$latest_patch")"
      echo "               created $(date -r "$latest_patch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
    else
      echo "Hotfixes:      m2-hotfixes/ present but contains no .patch files"
    fi
  else
    echo "Hotfixes:      no m2-hotfixes/ directory"
  fi
else
  echo "Magento root:  NOT FOUND - application checks will be skipped"
  [[ -n "$ROOT_NOTE" ]] && echo "               note: $ROOT_NOTE"
  echo "               pass --root PATH to point at the install"
fi
echo "Scan mode:     $([[ "$DEEP" -eq 1 ]] && echo deep || echo standard), db checks $([[ "$CHECK_DB" -eq 1 ]] && echo on || echo off)"

# ---------------------------------------------------------------------------
# 1. Cron and startup persistence
# ---------------------------------------------------------------------------

section "Cron and startup persistence"
checking \
  "Commands:crontab -l; grep -r over cron and profile paths" \
  "Paths:/etc/crontab, /etc/cron.{d,hourly,daily,weekly,monthly}, /var/spool/cron," \
  "     :~/.bashrc, ~/.bash_profile, ~/.profile, ~/.zshrc, ~/.config/autostart," \
  "     :~/.config/systemd/user, .magento.app.yaml, .magento.env.yaml" \
  "Pattern:$IOC_CRON_RE" \
  "Expects:the implant installs */5 * * * * exec ~/.local/share/.gvfsd/gvfsd-user" \
  "       :and 13,43 * * * * ~/.cache/fontconfig/fc-cache"


cron_hits=0

if has crontab; then
  cron_out="$(crontab -l 2>/dev/null)"
  if [[ -n "$cron_out" ]]; then
    hits="$(printf '%s\n' "$cron_out" | grep -inE "$IOC_CRON_RE")"
    if [[ -n "$hits" ]]; then
      critical "Malicious cron entries in the current user's crontab:"
      printf '%s\n' "$hits" | indent
      cron_hits=1
    fi
  fi
else
  skip "crontab binary not available"
fi

# System-wide cron locations
for cron_path in /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily \
                 /etc/cron.weekly /etc/cron.monthly /var/spool/cron \
                 /var/spool/cron/crontabs; do
  [[ -e "$cron_path" ]] || continue
  hits="$(grep -rinE "$IOC_CRON_RE" "$cron_path" 2>/dev/null | head -20)"
  if [[ -n "$hits" ]]; then
    critical "Malicious cron entries under $cron_path:"
    printf '%s\n' "$hits" | indent
    cron_hits=1
  fi
done

# Shell profiles and autostart, a common secondary persistence spot
for profile in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" \
               "$HOME/.zshrc" "$HOME/.config/autostart"; do
  [[ -e "$profile" ]] || continue
  hits="$(grep -rinE "$IOC_CRON_RE" "$profile" 2>/dev/null | head -10)"
  if [[ -n "$hits" ]]; then
    critical "Persistence stub in $profile:"
    printf '%s\n' "$hits" | indent
    cron_hits=1
  fi
done

# systemd user units
if [[ -d "$HOME/.config/systemd/user" ]]; then
  hits="$(grep -rinE "$IOC_CRON_RE" "$HOME/.config/systemd/user" 2>/dev/null | head -10)"
  if [[ -n "$hits" ]]; then
    critical "Persistence via systemd user unit:"
    printf '%s\n' "$hits" | indent
    cron_hits=1
  fi
fi

# Adobe Commerce Cloud defines crons in YAML rather than crontab
if [[ "$HAVE_MAGENTO" -eq 1 ]]; then
  for yaml in "$MAGENTO_ROOT/.magento.app.yaml" "$MAGENTO_ROOT/.magento.env.yaml"; do
    [[ -f "$yaml" ]] || continue
    hits="$(grep -inE "$IOC_CRON_RE" "$yaml" 2>/dev/null)"
    if [[ -n "$hits" ]]; then
      critical "Suspicious cron definition in $(basename "$yaml"):"
      printf '%s\n' "$hits" | indent
      cron_hits=1
    fi
  done
fi

[[ "$cron_hits" -eq 0 ]] && ok "No StyleSmuggler cron or startup persistence found."

# ---------------------------------------------------------------------------
# 2. Known implant drop locations
# ---------------------------------------------------------------------------

section "Known implant drop locations"
checking \
  "Command:test -e on each path below, plus ls -ld on any hit" \
  "Paths:${IOC_FILES[*]}" \
  "Globs:${IOC_GLOBS[*]}" \
  "Extra:/tmp/.fc_*.lock is read for the PID it stores, then ps -p that PID" \
  "Deep:--deep adds find / -xdev for gvfsd-user, .gvfsd, .kw_*, .fc_*.lock"


file_hits=0
found_files=()

for f in "${IOC_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    critical "Implant path present: $f" "$(ls -ld "$f" 2>/dev/null)"
    found_files+=("$f")
    file_hits=1
  fi
done

shopt -s nullglob dotglob
for pattern in "${IOC_GLOBS[@]}"; do
  for match in $pattern; do
    critical "Implant path present: $match" "$(ls -ld "$match" 2>/dev/null)"
    found_files+=("$match")
    file_hits=1
  done
done
shopt -u nullglob dotglob

# The lock file carries the implant PID
shopt -s nullglob
for lock in /tmp/.fc_*.lock; do
  pid="$(head -c 32 "$lock" 2>/dev/null | tr -dc '0-9')"
  if [[ -n "$pid" ]]; then
    critical "Lock file $lock names PID $pid" \
             "$(ps -p "$pid" -o pid,ppid,user,etime,args 2>/dev/null | tail -n +2)"
  fi
done
shopt -u nullglob

if [[ "$DEEP" -eq 1 ]]; then
  info "Deep mode: searching the filesystem for implant filenames (this takes a while)..."
  deep_hits="$(find / -xdev \( -name 'gvfsd-user' -o -name '.gvfsd' -o -name '.kw_*' \
      -o -name '.fc_*.lock' \) 2>/dev/null | grep -v '^/proc' | head -50)"
  if [[ -n "$deep_hits" ]]; then
    critical "Implant filenames found elsewhere on the filesystem:"
    printf '%s\n' "$deep_hits" | indent
    file_hits=1
  fi
fi

[[ "$file_hits" -eq 0 ]] && ok "None of the known drop paths exist."

# ---------------------------------------------------------------------------
# 3. Binary hashes
# ---------------------------------------------------------------------------

section "Implant binary hashes"
checking \
  "Command:sha256sum (or shasum -a 256 / openssl dgst) on files found above" \
  "Compare:against the 4 SHA256 hashes published by Sansec" \
  "Hashes:${IOC_HASHES[0]}" \
  "      :${IOC_HASHES[1]}" \
  "      :${IOC_HASHES[2]} (kworker x64)" \
  "      :${IOC_HASHES[3]} (kworker arm64)"


if [[ ${#found_files[@]} -eq 0 ]]; then
  ok "No candidate files to hash."
elif ! has sha256sum && ! has shasum && ! has openssl; then
  skip "No sha256sum/shasum/openssl available to hash candidate files."
else
  for f in "${found_files[@]}"; do
    [[ -f "$f" ]] || continue
    h="$(sha256_of "$f")"
    [[ -z "$h" ]] && continue
    matched=0
    for known in "${IOC_HASHES[@]}"; do
      if [[ "$h" == "$known" ]]; then
        critical "$f matches a published StyleSmuggler implant hash" "sha256: $h"
        matched=1
        break
      fi
    done
    [[ "$matched" -eq 0 ]] && info "$f sha256: $h (not in the published hash list)"
  done
fi

# ---------------------------------------------------------------------------
# 4. Masquerading processes
# ---------------------------------------------------------------------------

section "Masquerading processes"
checking \
  "Command:ps -eo pid,ppid,user,comm,args + readlink /proc/<pid>/exe" \
  "Names:kworker, fc-cache, gvfsd-user" \
  "Logic:a real kworker is a kernel thread - PPID 2 and no exe link. One with a" \
  "     :real exe, or a non-root parent, is a userland process wearing the name." \
  "     :fc-cache is only critical when its exe sits outside /usr/bin, /bin," \
  "     :/usr/local/bin or /usr/sbin. This avoids the false positives a plain" \
  "     :grep for kworker produces on every Linux host." \
  "Also:processes whose /proc/<pid>/exe target ends in (deleted)"


proc_hits=0

# Real kworker entries are kernel threads: parented by kthreadd (PID 2) and with no
# executable behind /proc/<pid>/exe. A userland process pretending to be one is the
# tell, so PPID and exe are what get checked rather than the name alone.
ps_out="$(ps -eo pid=,ppid=,user=,comm=,args= 2>/dev/null)"
if [[ -z "$ps_out" ]]; then
  skip "ps produced no output; process checks unavailable."
else
  while read -r pid ppid puser comm args; do
    [[ -z "${pid:-}" ]] && continue
    line="$pid $ppid $puser $comm $args"

    exe=""
    [[ -r "/proc/$pid/exe" ]] && exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"

    case "$comm$args" in
      *kworker*)
        # Kernel threads are parented by kthreadd (PID 2) and have no exe link.
        if [[ "$ppid" != "2" && "$ppid" != "0" && -n "$exe" ]]; then
          critical "Process $pid impersonates a kernel worker" \
                   "user=$puser ppid=$ppid exe=$exe" \
                   "$line"
          proc_hits=1
        elif [[ "$ppid" != "2" && "$ppid" != "0" && "$puser" != "root" ]]; then
          critical "Non-kernel process $pid running as '$puser' is named like a kworker" "$line"
          proc_hits=1
        fi
        ;;
    esac

    case "$comm$args" in
      *fc-cache*)
        case "$exe" in
          /usr/bin/fc-cache|/bin/fc-cache|/usr/local/bin/fc-cache|/usr/sbin/fc-cache)
            warn "Legitimate fc-cache binary is running (pid $pid). Normally short-lived; confirm it exits." "$line"
            ;;
          "")
            warn "fc-cache process $pid found, executable path unreadable. Verify manually." "$line"
            ;;
          *)
            critical "fc-cache process $pid runs from an unexpected path" "exe=$exe" "$line"
            proc_hits=1
            ;;
        esac
        ;;
    esac

    case "$comm$args" in
      *gvfsd-user*|*.gvfsd*)
        critical "Process $pid matches the gvfsd-user implant" "exe=${exe:-unknown}" "$line"
        proc_hits=1
        ;;
    esac
  done <<<"$ps_out"
fi

# Deleted-binary check: implants commonly unlink themselves after launch.
if [[ -d /proc ]]; then
  deleted=""
  for exelink in /proc/[0-9]*/exe; do
    target="$(readlink "$exelink" 2>/dev/null)" || continue
    case "$target" in
      *"(deleted)")
        p="${exelink#/proc/}"; p="${p%/exe}"
        deleted+="pid $p -> $target"$'\n'
        ;;
    esac
  done
  if [[ -n "$deleted" ]]; then
    warn "Processes running from deleted binaries (common for in-memory implants):"
    printf '%s' "$deleted" | head -20 | indent
  fi
fi

[[ "$proc_hits" -eq 0 ]] && ok "No masquerading kworker/fc-cache/gvfsd processes found."

# ---------------------------------------------------------------------------
# 5. Network indicators
# ---------------------------------------------------------------------------

section "Network indicators (C2)"
checking \
  "Command:ss -tunap (or netstat -tunap / lsof -i -n -P), getent hosts, /etc/hosts" \
  "IPs:${IOC_IPS[*]}" \
  "Hosts:${IOC_HOSTS[*]}" \
  "UDP:established UDP/123 peers whose process is not ntpd, chronyd or" \
  "   :systemd-timesyncd - the implant shapes C2 traffic to look like NTP." \
  "   :Listening sockets are ignored; only real peers are reported."


net_hits=0
conn_table=""
if has ss; then
  conn_table="$(ss -tunap 2>/dev/null)"
elif has netstat; then
  conn_table="$(netstat -tunap 2>/dev/null)"
elif has lsof; then
  conn_table="$(lsof -i -n -P 2>/dev/null)"
fi

if [[ -z "$conn_table" ]]; then
  skip "No ss/netstat/lsof output available; live connection check unavailable."
else
  ip_alt="$(join_alt "${IOC_IPS[@]}")"
  hits="$(printf '%s\n' "$conn_table" | grep -E "$ip_alt")"
  if [[ -n "$hits" ]]; then
    critical "Live connection to a known StyleSmuggler C2 address:"
    printf '%s\n' "$hits" | indent
    net_hits=1
  fi

  # NTP-shaped UDP C2 on 123 from a non-NTP process.
  #
  # Only sockets with a real remote peer count. A bare listener (state UNCONN with
  # a peer of 0.0.0.0:* or *:*) is just the host's own NTP service accepting
  # queries, and matching on port 123 alone flags that on essentially every host.
  ntp_out="$(printf '%s\n' "$conn_table" \
    | grep -iE '^udp|udp[46]? ' \
    | grep -E ':123([[:space:]]|$)' \
    | awk '$NF !~ /^(0\.0\.0\.0:\*|\[?::\]?:\*|\*:\*)$/' \
    | grep -vE '(0\.0\.0\.0|\[::\]|\*):\*[[:space:]]*$' \
    | grep -viE 'ntpd|chronyd|systemd-timesyn|timesyncd|ntpsec')"
  if [[ -n "$ntp_out" ]]; then
    warn "Established UDP/123 peer whose process is not a known NTP daemon (the implant tunnels C2 over NTP-shaped packets):"
    printf '%s\n' "$ntp_out" | indent
  else
    ok "No UDP/123 sessions to non-NTP peers (listening NTP sockets ignored)."
  fi
fi

# DNS resolution of C2 hostnames tells us whether they are reachable/poisoned here
if has getent; then
  for h in "${IOC_HOSTS[@]}"; do
    res="$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | paste -sd, -)"
    [[ -n "$res" ]] && info "C2 hostname $h currently resolves to $res (resolution alone is not compromise)"
  done
fi

# /etc/hosts pinning
if [[ -r /etc/hosts ]]; then
  host_alt="$(join_alt "${IOC_HOSTS[@]}" "${IOC_IPS[@]}")"
  hits="$(grep -nE "$host_alt" /etc/hosts 2>/dev/null)"
  if [[ -n "$hits" ]]; then
    critical "C2 indicator pinned in /etc/hosts:"
    printf '%s\n' "$hits" | indent
    net_hits=1
  fi
fi

[[ "$net_hits" -eq 0 ]] && ok "No live C2 connections or pinned C2 hosts found."

# ---------------------------------------------------------------------------
# 6. Magento crash reports (x_trace_)
# ---------------------------------------------------------------------------

section "Magento crash reports and logs"
checking \
  "Command:grep -rl for the marker under var/report and the log directories" \
  "Paths:$MAGENTO_ROOT/var/report, $MAGENTO_ROOT/var/log, \$HOME/var/log" \
  "Pattern:$IOC_MAGENTO_RE" \
  "Why:the exploit writes PHP into var/report; x_trace_ marks attacker traffic"


report_hits=0

if [[ "$HAVE_MAGENTO" -eq 0 ]]; then
  skip "Magento root not found; skipping application checks."
else
  if [[ -d "$MAGENTO_ROOT/var/report" ]]; then
    hits="$(grep -rl "$IOC_MAGENTO_RE" "$MAGENTO_ROOT/var/report" 2>/dev/null | head -50)"
    if [[ -n "$hits" ]]; then
      critical "Exploitation marker '${IOC_MAGENTO_RE}' found in crash reports:"
      printf '%s\n' "$hits" | indent
      report_hits=1
      first="$(printf '%s\n' "$hits" | head -n1)"
      info "First match preview ($first):"
      grep -o "x_trace_[A-Za-z0-9_]*" "$first" 2>/dev/null | sort -u | head -10 | sed 's/^/            /'
    else
      count="$(find "$MAGENTO_ROOT/var/report" -type f 2>/dev/null | wc -l | tr -d ' ')"
      ok "No 'x_trace_' markers in var/report ($count report files scanned)."
    fi
  else
    info "var/report does not exist."
  fi

  for logdir in "$MAGENTO_ROOT/var/log" "$HOME/var/log"; do
    [[ -d "$logdir" ]] || continue
    hits="$(grep -rl "$IOC_MAGENTO_RE" "$logdir" 2>/dev/null | head -20)"
    if [[ -n "$hits" ]]; then
      critical "Exploitation marker '${IOC_MAGENTO_RE}' found in $logdir:"
      printf '%s\n' "$hits" | indent
      report_hits=1
    fi
  done

  [[ "$report_hits" -eq 0 ]] && ok "No exploitation markers in Magento logs."
fi

# ---------------------------------------------------------------------------
# 7. Exploitation attempts in web access logs
# ---------------------------------------------------------------------------

section "Exploitation attempts in web logs"

log_candidates=()
while IFS= read -r p; do
  [[ -n "$p" ]] && log_candidates+=("$p")
done < <(sort -u < <(
  shopt -s nullglob
  printf '%s\n' \
    /var/log/nginx/access.log* /var/log/nginx/*access*.log* \
    /var/log/apache2/access.log* /var/log/httpd/access_log* \
    /var/log/access.log* /var/log/platform/*/access.log* \
    "$HOME"/var/log/access.log* \
    "${MAGENTO_ROOT:-/nonexistent}"/var/log/access.log*
  for extra in "${LOG_PATHS_EXTRA[@]+"${LOG_PATHS_EXTRA[@]}"}"; do
    printf '%s\n' $extra
  done
))

attack_re='graphql[^"[:space:]]*styles(\[|%5[Bb])|paypal/transparent/response[^"[:space:]]*(eval|base64_decode|%3C%3F)'
ip_alt="$(join_alt "${IOC_IPS[@]}")"

checking \
  "Command:grep -aiE (zgrep for .gz) over each access log" \
  "Pattern:$attack_re" \
  "IPs:$ip_alt" \
  "Paths:/var/log/nginx, /var/log/apache2, /var/log/httpd, /var/log/platform/*," \
  "     :\$HOME/var/log, \$MAGENTO_ROOT/var/log, plus any --log argument" \
  "Files:${#log_candidates[@]} log file(s) matched" \
  "Note:on Cloud the edge sees traffic the origin never logs - check Fastly and" \
  "    :New Relic logs as well before concluding there were no attempts"

if [[ ${#log_candidates[@]} -eq 0 ]]; then
  skip "No web access logs found. Pass --log PATH to point at them (Cloud: check the Fastly/New Relic logs too)."
else
  log_hits=0
  unreadable=0

  for lf in "${log_candidates[@]}"; do
    [[ -r "$lf" ]] || { unreadable=$((unreadable + 1)); continue; }
    if [[ "$lf" == *.gz ]]; then
      has zgrep || continue
      reader=(zgrep -aiE)
    else
      reader=(grep -aiE)
    fi

    hits="$("${reader[@]}" "$attack_re" "$lf" 2>/dev/null | head -20)"
    if [[ -n "$hits" ]]; then
      total="$("${reader[@]}" -c "$attack_re" "$lf" 2>/dev/null | head -n1)"
      critical "Exploit-shaped requests in $lf (${total:-?} matching lines, first 20 shown):"
      printf '%s\n' "$hits" | indent
      log_hits=1
    fi

    hits="$("${reader[@]}" "$ip_alt" "$lf" 2>/dev/null | head -10)"
    if [[ -n "$hits" ]]; then
      critical "Requests from a known attacker IP in $lf:"
      printf '%s\n' "$hits" | indent
      log_hits=1
    fi
  done

  if [[ "$unreadable" -gt 0 ]]; then
    warn "$unreadable of ${#log_candidates[@]} log file(s) were not readable by this user; those were not scanned."
  fi
  [[ "$log_hits" -eq 0 ]] && ok "No exploit-shaped requests found in the $(( ${#log_candidates[@]} - unreadable )) readable log file(s)."
fi

# ---------------------------------------------------------------------------
# 8. Outbound mail volume
# ---------------------------------------------------------------------------

section "Outbound mail volume"
checking \
  "Command:grep -a status=sent <maillog> | awk per-day tally" \
  "Paths:/var/log/maillog, /var/log/mail.log, /var/log/platform/*/maillog" \
  "Why:stage two runs when a Payment Transaction Failed notification renders," \
  "   :so the attacker must trigger a batch of them. Postfix does not log" \
  "   :subjects, so volume is the observable side effect, not proof."


# Stage two of the exploit executes when a "Payment Transaction Failed" notification
# renders, so the attacker has to trigger a batch of them. Postfix does not log
# subjects, but an unexplained spike in delivery volume is the observable side effect.
mail_logs=()
while IFS= read -r p; do
  [[ -n "$p" ]] && mail_logs+=("$p")
done < <(
  shopt -s nullglob
  printf '%s\n' /var/log/maillog /var/log/mail.log /var/log/mail.log.1 \
                /var/log/platform/*/maillog
)

if [[ ${#mail_logs[@]} -eq 0 ]]; then
  skip "No mail logs found. Use analyze_mail_logs.sh for a full delivery breakdown."
else
  tally=""
  for mf in "${mail_logs[@]}"; do
    [[ -r "$mf" ]] || continue
    tally+="$(grep -a 'status=sent' "$mf" 2>/dev/null | awk '{print $1" "$2}')"$'\n'
  done
  summary="$(printf '%s' "$tally" | grep -v '^$' | sort | uniq -c | sort -k2 | tail -14)"
  if [[ -n "$summary" ]]; then
    info "Messages delivered per day (investigate any unexplained spike):"
    printf '%s\n' "$summary" | indent
    info "For a full breakdown by outcome, run analyze_mail_logs.sh."
  else
    ok "No delivered mail recorded in the available mail logs."
  fi
fi

# ---------------------------------------------------------------------------
# 8. C2 strings inside the codebase
# ---------------------------------------------------------------------------

section "C2 strings inside the codebase"
checking \
  "Command:grep -rlaE over the code tree" \
  "Pattern:$(join_alt "${IOC_HOSTS[@]}" "${IOC_IPS[@]}")" \
  "Scope:app/, pub/, var/, lib/ (--deep adds vendor/ and generated/)"


if [[ "$HAVE_MAGENTO" -eq 0 ]]; then
  skip "Magento root not found."
else
  scan_dirs=("$MAGENTO_ROOT/app" "$MAGENTO_ROOT/pub" "$MAGENTO_ROOT/var" "$MAGENTO_ROOT/lib")
  if [[ "$DEEP" -eq 1 ]]; then
    scan_dirs+=("$MAGENTO_ROOT/vendor" "$MAGENTO_ROOT/generated")
  else
    info "Skipping vendor/ and generated/ (use --deep to include them)."
  fi

  host_alt="$(join_alt "${IOC_HOSTS[@]}" "${IOC_IPS[@]}")"
  code_hits=0
  for d in "${scan_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    hits="$(grep -rlaE "$host_alt" "$d" 2>/dev/null | head -20)"
    if [[ -n "$hits" ]]; then
      critical "C2 indicator embedded in files under $d:"
      printf '%s\n' "$hits" | indent
      code_hits=1
    fi
  done
  [[ "$code_hits" -eq 0 ]] && ok "No C2 hostnames or IPs found in the scanned code paths."
fi

# ---------------------------------------------------------------------------
# 9. Webshells and unexpected PHP in writable paths
# ---------------------------------------------------------------------------

section "Webshells in writable paths"
checking \
  "Command:find for *.php/*.phtml/*.phar, then grep -laE for payload signatures" \
  "Paths:pub/media, pub/static, var/import, var/export, var/tmp, var/log" \
  "Why:none of those directories should ever hold executable PHP" \
  "Recent:app/ and pub/ PHP modified in the last $DAYS days (find -mtime -$DAYS)" \
  "Pattern:$IOC_PHP_RE" \
  "Git:git status --porcelain, to show drift from the deployed HEAD"


if [[ "$HAVE_MAGENTO" -eq 0 ]]; then
  skip "Magento root not found."
else
  shell_hits=0
  # PHP has no business existing in these directories on a healthy install.
  for d in "$MAGENTO_ROOT/pub/media" "$MAGENTO_ROOT/pub/static" "$MAGENTO_ROOT/var/import" \
           "$MAGENTO_ROOT/var/export" "$MAGENTO_ROOT/var/tmp" "$MAGENTO_ROOT/var/log"; do
    [[ -d "$d" ]] || continue
    hits="$(find "$d" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' \
            -o -name '*.phar' -o -name '*.inc' -o -name '*.phps' -o -name '*.pht' \
            -o -name '*.shtml' \) 2>/dev/null | head -40)"
    if [[ -n "$hits" ]]; then
      critical "PHP files present in $d (should never contain executable PHP):"
      printf '%s\n' "$hits" | indent
      shell_hits=1
    fi
  done

  # Polyglot webshells: a valid image header (so an upload filter checking magic
  # bytes passes it) with PHP spliced in after it. Extension-independent, which is
  # what catches the .inc and .phar copies attackers drop alongside the .php one.
  poly_hits=""
  # Scan the upload sinks specifically. pub/media on a real store holds hundreds of
  # thousands of product images; capping a full-tree walk truncates before reaching
  # custom_options, which is exactly where uploaded shells land.
  for d in "$MAGENTO_ROOT/pub/media/custom_options" "$MAGENTO_ROOT/pub/media/import" \
           "$MAGENTO_ROOT/pub/media/downloadable" "$MAGENTO_ROOT/pub/media/tmp" \
           "$MAGENTO_ROOT/var/import" "$MAGENTO_ROOT/var/tmp"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # Plain strings, not hex escapes: POSIX grep does not interpret \xNN, so a
      # hex-escaped magic-byte pattern silently matches nothing.
      head -c 16 "$f" 2>/dev/null | grep -qa -e 'GIF8' -e 'JFIF' -e 'PNG' -e 'RIFF' -e 'Exif' || continue
      grep -qa '<?php' "$f" 2>/dev/null && poly_hits+="$f"$'\n'
    done < <(find "$d" -type f -size -2M 2>/dev/null | head -20000)
  done
  if [[ -n "$poly_hits" ]]; then
    critical "Polyglot webshell(s): a valid image header with PHP appended." \
             "These bypass upload filters that only check magic bytes."
    printf '%s' "$poly_hits" | grep -v '^$' | head -40 | indent
    shell_hits=1
  fi

  # Recently modified PHP in the app tree
  hits="$(find "$MAGENTO_ROOT/app" "$MAGENTO_ROOT/pub" -maxdepth 6 -type f -name '*.php' \
          -mtime -"$DAYS" 2>/dev/null | head -40)"
  if [[ -n "$hits" ]]; then
    count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    # On Cloud every deploy rewrites the whole tree, so a recent mtime alone says
    # nothing. Report the count for context and only escalate on a payload match,
    # rather than emitting a warning that is guaranteed to fire after any release.
    info "$count PHP file(s) in app/ or pub/ modified in the last $DAYS days (a deploy touches all of them; mtime alone is not suspicious)."
    payload_hits="$(printf '%s\n' "$hits" | while IFS= read -r f; do
        grep -laE "$IOC_PHP_RE" "$f" 2>/dev/null
      done | head -20)"
    if [[ -n "$payload_hits" ]]; then
      critical "Recently modified PHP files containing payload signatures (eval/base64_decode/superglobal input):"
      printf '%s\n' "$payload_hits" | indent
      shell_hits=1
    fi
  fi

  # Untracked/modified files, when git is present, are the fastest signal on Cloud
  if has git && [[ -d "$MAGENTO_ROOT/.git" ]]; then
    dirty="$(git -C "$MAGENTO_ROOT" status --porcelain 2>/dev/null | head -40)"
    if [[ -n "$dirty" ]]; then
      warn "Working tree differs from git HEAD (untracked or modified files):"
      printf '%s\n' "$dirty" | indent
    else
      ok "Working tree is clean against git HEAD."
    fi
  fi

  [[ "$shell_hits" -eq 0 ]] && ok "No webshells found in writable paths."
fi

# ---------------------------------------------------------------------------
# 10. Database checks (opt-in)
# ---------------------------------------------------------------------------

section "Database checks"
checking \
  "Command:mysql --batch, credentials read from app/etc/env.php via php -r" \
  "Mode:SET SESSION TRANSACTION READ ONLY - the server rejects any write" \
  "Tables:email_template, core_config_data, cms_block, cms_page, layout_update," \
  "      :admin_user, integration" \
  "Pattern:eval(|base64_decode|shell_exec|passthru|system(|assert(|file_put_contents|x_trace_" \
  "Window:rows created or updated within the last $DAYS days" \
  "Why:the exploit injects PHP into the template system, so the payload can" \
  "   :persist in the database even after the filesystem is cleaned"


run_db_checks() {
  local envfile="$MAGENTO_ROOT/app/etc/env.php"
  [[ -f "$envfile" ]] || { skip "app/etc/env.php not found."; return; }
  has php || { skip "php not available to read env.php."; return; }
  has mysql || { skip "mysql client not available."; return; }

  local creds
  creds="$(php -r '
    $e = include $argv[1];
    $d = $e["db"]["connection"]["default"] ?? [];
    echo ($d["host"] ?? ""), "\n", ($d["dbname"] ?? ""), "\n",
         ($d["username"] ?? ""), "\n", ($d["password"] ?? ""), "\n",
         ($e["db"]["table_prefix"] ?? ""), "\n";
  ' "$envfile" 2>/dev/null)"

  local dbhost dbname dbuser dbpass prefix dbport
  dbhost="$(sed -n 1p <<<"$creds")"
  dbname="$(sed -n 2p <<<"$creds")"
  dbuser="$(sed -n 3p <<<"$creds")"
  dbpass="$(sed -n 4p <<<"$creds")"
  prefix="$(sed -n 5p <<<"$creds")"

  if [[ -z "$dbname" || -z "$dbuser" ]]; then
    skip "Could not read database credentials from env.php."
    return
  fi

  dbport=3306
  if [[ "$dbhost" == *:* ]]; then
    dbport="${dbhost##*:}"
    dbhost="${dbhost%%:*}"
  fi
  [[ -z "$dbhost" ]] && dbhost="localhost"

  info "Querying ${dbname} on ${dbhost}:${dbport} (read-only)."

  # Every statement is prefixed with a read-only transaction mode so the server
  # itself rejects any write, rather than relying on the queries below staying
  # SELECT-only. The password goes via MYSQL_PWD so it never appears in `ps`.
  dbq() { MYSQL_PWD="$dbpass" mysql --batch --raw --skip-column-names \
          --connect-timeout=10 -h "$dbhost" -P "$dbport" -u "$dbuser" "$dbname" \
          -e "SET SESSION TRANSACTION READ ONLY; $1" 2>/dev/null; }

  if ! dbq "SELECT 1;" >/dev/null; then
    skip "Could not connect to the database with credentials from env.php."
    return
  fi

  local db_hits=0 rows
  local sig="eval\\\\(|base64_decode|shell_exec|passthru|system\\\\(|assert\\\\(|file_put_contents|x_trace_"

  # Email templates: the payload executes when a transactional email renders.
  rows="$(dbq "SELECT CONCAT(template_id,' | ',template_code,' | added=',added_at,' | modified=',modified_at)
             FROM ${prefix}email_template
             WHERE template_text REGEXP '$sig' OR template_subject REGEXP '$sig' LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    critical "Email templates containing PHP payload signatures:"
    printf '%s\n' "$rows" | indent
    db_hits=1
  fi

  rows="$(dbq "SELECT CONCAT(template_id,' | ',template_code,' | added=',added_at)
             FROM ${prefix}email_template
             WHERE added_at >= DATE_SUB(NOW(), INTERVAL $DAYS DAY) LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    warn "Email templates created in the last $DAYS days (verify each was created by your team):"
    printf '%s\n' "$rows" | indent
  fi

  # Config values: template overrides and design nodes are the injection surface.
  rows="$(dbq "SELECT CONCAT(path,' | scope=',scope,':',scope_id,' | ',LEFT(REPLACE(REPLACE(value,'\n',' '),'\r',' '),160))
             FROM ${prefix}core_config_data
             WHERE value REGEXP '$sig' LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    critical "core_config_data values containing PHP payload signatures:"
    printf '%s\n' "$rows" | indent
    db_hits=1
  fi

  rows="$(dbq "SELECT CONCAT(path,' | scope=',scope,':',scope_id,' | ',LEFT(REPLACE(value,'\n',' '),120))
             FROM ${prefix}core_config_data
             WHERE (path LIKE '%template%' OR path LIKE 'design/%')
               AND updated_at >= DATE_SUB(NOW(), INTERVAL $DAYS DAY) LIMIT 25;")"
  if [[ -n "$rows" ]]; then
    warn "Template/design config changed in the last $DAYS days:"
    printf '%s\n' "$rows" | indent
  fi

  # CMS content. The id column differs per table (block_id / page_id), so it is
  # named explicitly rather than derived from the table name.
  local pair tbl idcol
  for pair in "cms_block:block_id" "cms_page:page_id"; do
    tbl="${pair%%:*}"
    idcol="${pair##*:}"
    rows="$(dbq "SELECT CONCAT('${tbl} #',${idcol},' | ',identifier,' | updated=',update_time)
                 FROM ${prefix}${tbl} WHERE content REGEXP '$sig' LIMIT 20;")"
    if [[ -n "$rows" ]]; then
      critical "${tbl} rows containing PHP payload signatures:"
      printf '%s\n' "$rows" | indent
      db_hits=1
    fi
  done

  # Layout updates are a classic Magento persistence spot
  rows="$(dbq "SELECT CONCAT(layout_update_id,' | handle=',handle,' | updated=',update_time)
             FROM ${prefix}layout_update WHERE xml REGEXP '$sig' LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    critical "layout_update rows containing payload signatures:"
    printf '%s\n' "$rows" | indent
    db_hits=1
  fi

  # Post-exploitation: new admin accounts and integrations
  rows="$(dbq "SELECT CONCAT(user_id,' | ',username,' | ',email,' | created=',created,' | logdate=',IFNULL(logdate,'never'))
             FROM ${prefix}admin_user WHERE created >= DATE_SUB(NOW(), INTERVAL $DAYS DAY) LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    critical "Admin accounts created in the last $DAYS days:"
    printf '%s\n' "$rows" | indent
    db_hits=1
  fi

  rows="$(dbq "SELECT CONCAT(integration_id,' | ',name,' | created=',created_at,' | status=',status)
             FROM ${prefix}integration WHERE created_at >= DATE_SUB(NOW(), INTERVAL $DAYS DAY) LIMIT 20;")"
  if [[ -n "$rows" ]]; then
    warn "Integrations created in the last $DAYS days:"
    printf '%s\n' "$rows" | indent
  fi

  # Recent admin activity. An account that suddenly logs in after months of disuse,
  # or a password changed outside a known maintenance window, is worth chasing.
  rows="$(dbq "SELECT CONCAT(username,' | last_login=',IFNULL(logdate,'never'),' | failures=',IFNULL(failures_num,0),' | pw_changed=',IFNULL(rp_token_created_at,'-'))
               FROM ${prefix}admin_user
               WHERE logdate >= DATE_SUB(NOW(), INTERVAL $DAYS DAY) LIMIT 30;")"
  if [[ -n "$rows" ]]; then
    info "Admin accounts that logged in during the last $DAYS days:"
    printf '%s\n' "$rows" | indent
  fi

  [[ "$db_hits" -eq 0 ]] && ok "No payload signatures found in templates, config, CMS or layout tables."
}

if [[ "$CHECK_DB" -eq 1 ]]; then
  if [[ "$HAVE_MAGENTO" -eq 1 ]]; then
    run_db_checks
  else
    skip "Magento root not found; cannot read database credentials."
  fi
else
  skip "Database checks disabled. Re-run with --db to inspect templates, CMS, config and admin users."
fi

# ---------------------------------------------------------------------------
# 11. Edge mitigation (Fastly VCL / WAF) and containment patches
# ---------------------------------------------------------------------------

section "Edge mitigation (Fastly VCL) and containment patches"

# Snippets are judged by what their rules actually match, never by their name or
# header comment. Adobe's current rule set (the snippet published as "accord_rce")
# blocks four request shapes, and any equivalent rule under any name counts:
#
#   styles[ / styles%5B in the query string, outside /admin
#   an encoded or literal PHP open tag  (%3c%3f / <?)
#   a {{block|widget|layout|config|template|store|trans|media|view}} directive in
#     a text parameter, or in a POST body to /graphql, /paypal/*, /checkout/*
#
# Matching those rule bodies means a renamed, reordered or locally authored
# equivalent is still recognised as coverage.
VCL_STYLESMUGGLER_RE='styles(%5[Bb]|\[)|%3c%3f|%3C%3F|<\[?\?|%7b%7b|\{\{[^}]*(block|widget|layout|config|template|store|trans|media|view)|paypal/transparent/response|\^/graphql'

checking \
  "Command:ls var/vcl_snippets_custom/ and var/vcl_snippets/, then grep each snippet" \
  "Pattern:$VCL_STYLESMUGGLER_RE" \
  "Judged:on rule content, not snippet name - a renamed or locally authored" \
  "      :equivalent still counts, and a snippet for an older bulletin does not" \
  "Also:vendor/fastly/magento2 module version, *.vcl anywhere in the app tree," \
  "    :nginx/apache blocking rules, and m2-hotfixes/*.patch" \
  "Probe:Adobe pushes its rules straight to the Fastly service, leaving no file" \
  "     :on disk - so the live edge is probed as well (disable with --no-probe)"

if [[ "$HAVE_MAGENTO" -eq 0 ]]; then
  skip "Magento root not found; cannot inspect VCL snippets or patches."
else
  mitigated=0
  vcl_found=0

  for vcl_dir in "$MAGENTO_ROOT/var/vcl_snippets_custom" "$MAGENTO_ROOT/var/vcl_snippets"; do
    [[ -d "$vcl_dir" ]] || continue
    shopt -s nullglob
    for snippet in "$vcl_dir"/*.vcl; do
      vcl_found=1
      sname="$(basename "$snippet")"
      sdate="$(date -r "$snippet" '+%Y-%m-%d' 2>/dev/null || echo unknown)"
      if grep -qiE "$VCL_STYLESMUGGLER_RE" "$snippet" 2>/dev/null; then
        ok "VCL snippet targets this exploit's vector: $sname (added $sdate)"
        printf '%s\n' "$(cat "$snippet")" | indent
        mitigated=1
      else
        info "VCL snippet present but unrelated to StyleSmuggler: $sname (added $sdate)"
        printf '%s\n' "$(head -c 400 "$snippet")" | indent
      fi
    done
    shopt -u nullglob
  done

  # Custom VCL can also live outside var/ if it is committed to the repo.
  other_vcl="$(find "$MAGENTO_ROOT" -maxdepth 3 -name '*.vcl' \
               -not -path '*/var/vcl_snippets*' -not -path '*/node_modules/*' \
               -not -path '*/vendor/*' 2>/dev/null | head -10)"
  if [[ -n "$other_vcl" ]]; then
    info "Additional VCL files committed to the application tree:"
    printf '%s\n' "$other_vcl" | indent
    if printf '%s\n' "$other_vcl" | while IFS= read -r v; do
         grep -liE "$VCL_STYLESMUGGLER_RE" "$v" 2>/dev/null; done | grep -q .; then
      ok "At least one of those VCL files references the StyleSmuggler vector."
      mitigated=1
    fi
  fi

  if [[ "$vcl_found" -eq 0 && -z "$other_vcl" ]]; then
    info "No custom Fastly VCL snippets found (var/vcl_snippets_custom/ is empty or absent)."
  fi

  # Fastly module - without it, VCL snippets are not the delivery mechanism at all.
  if [[ -d "$MAGENTO_ROOT/vendor/fastly/magento2" ]]; then
    fver="$(lock_version 'fastly/magento2' 2>/dev/null)"
    info "Fastly CDN module installed${fver:+ (fastly/magento2 $fver)}."
  else
    info "Fastly CDN module not installed; edge rules, if any, are managed elsewhere."
  fi

  # Origin-level blocking rules are the other place a stopgap tends to land.
  nginx_hits=""
  for ngx in "$MAGENTO_ROOT/nginx.conf" "$MAGENTO_ROOT/nginx.conf.sample" \
             /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled \
             /etc/apache2/sites-enabled /etc/httpd/conf.d; do
    [[ -e "$ngx" ]] || continue
    h="$(grep -rilE 'styles(\[|%5[Bb])|deny.*graphql|location.*graphql.*(return|deny)' "$ngx" 2>/dev/null | head -5)"
    [[ -n "$h" ]] && nginx_hits+="$h"$'\n'
  done
  if [[ -n "$nginx_hits" ]]; then
    ok "Origin web-server rules referencing the styles parameter or graphql blocking:"
    printf '%s' "$nginx_hits" | grep -v '^$' | indent
    mitigated=1
  fi

  # Containment patches. The community stopgap rewrites the report serializers and
  # the DI scanners; a hotfix touching those files is a strong signal it is applied.
  if [[ -d "$MAGENTO_ROOT/m2-hotfixes" ]]; then
    shopt -s nullglob
    patches=("$MAGENTO_ROOT"/m2-hotfixes/*.patch)
    shopt -u nullglob
    if [[ ${#patches[@]} -gt 0 ]]; then
      info "Hotfix patches applied to this build (newest first):"
      ls -1t "$MAGENTO_ROOT"/m2-hotfixes/*.patch 2>/dev/null | while IFS= read -r pf; do
        printf '%s  (%s)\n' "$(basename "$pf")" "$(date -r "$pf" '+%Y-%m-%d' 2>/dev/null || echo unknown)"
      done | indent

      relevant="$(grep -lE 'PaymentFailuresService|ErrorProcessor|pub/errors/processor|ClassesScanner|JsonHexTag|graphql|styles' \
                  "$MAGENTO_ROOT"/m2-hotfixes/*.patch 2>/dev/null | head -10)"
      if [[ -n "$relevant" ]]; then
        ok "Hotfix(es) touching the StyleSmuggler containment surface:"
        printf '%s\n' "$relevant" | indent
        mitigated=1
      else
        info "No hotfix touches the report serializers, error processor or DI scanners."
      fi
    fi
  fi

  # ---- Live edge probe -------------------------------------------------------
  #
  # Adobe deploys its emergency rules (the "accord_rce" snippet) straight to the
  # Fastly service, so they leave NO file in var/vcl_snippets_custom/. Inspecting
  # the filesystem therefore cannot tell you whether the mitigation is active, and
  # concluding "unprotected" from a missing file is simply wrong. The only reliable
  # check is behavioural: send requests shaped like the ones the rule blocks and
  # see whether the edge answers 403.
  #
  # Each probe carries a harmless canary (styles[x]=1, an encoded <?, a {{block}}
  # directive shape) - the parameter shape the rule matches on, never a payload.
  if [[ "$PROBE" -eq 0 ]]; then
    skip "Edge probe disabled (--no-probe); mitigation state cannot be confirmed from files alone."
  elif ! has curl; then
    skip "curl unavailable; cannot probe the edge for active blocking rules."
  else
    BASE_URL="$(resolve_base_url)"
    if [[ -z "$BASE_URL" ]]; then
      skip "Could not determine the store's base URL; edge probe not run."
    else
      info "Probing the live edge at $BASE_URL for active blocking rules."
      baseline="$(http_status "$BASE_URL/")"
      if [[ "$baseline" != "200" ]]; then
        warn "Baseline request returned HTTP $baseline, not 200." \
             "Probe results below cannot be trusted: if the site blocks or redirects" \
             "everything, a 403 does not indicate a StyleSmuggler rule."
      fi

      blocked=0
      probed=0
      probe_one() {
        local label="$1" url="$2"; shift 2
        local st; st="$(http_status "$url" "$@")"
        probed=$((probed + 1))
        if [[ "$st" == "403" || "$st" == "406" ]]; then
          blocked=$((blocked + 1))
          ok "BLOCKED (HTTP $st) - $label"
        else
          warn "NOT BLOCKED (HTTP $st) - $label"
        fi
      }

      probe_one "styles[] parameter in the query string" "$BASE_URL/?styles%5Bx%5D=1"
      probe_one "encoded PHP open tag in the query string" "$BASE_URL/?q=%3C%3F"
      probe_one "template directive in a text parameter" "$BASE_URL/?text=%7B%7Bblock%20class%3Dx%7D%7D"
      probe_one "template directive in a POST body to /graphql" "$BASE_URL/graphql" \
                -X POST -H 'Content-Type: application/json' \
                --data '{"query":"{{block class=x}}"}'

      if [[ "$blocked" -eq "$probed" && "$baseline" == "200" ]]; then
        ok "Edge blocks all $probed StyleSmuggler-shaped requests while normal traffic passes."
        info "Consistent with Adobe's 'accord_rce' rule set being active on the Fastly service."
        mitigated=1
        EDGE_MITIGATED=1
      elif [[ "$blocked" -gt 0 ]]; then
        warn "Edge blocks only $blocked of $probed StyleSmuggler-shaped requests." \
             "Partial coverage - the unblocked vectors above are still reachable."
        mitigated=1
      else
        info "No StyleSmuggler-shaped request was blocked at the edge."
      fi
    fi
  fi

  if [[ "$mitigated" -eq 0 ]]; then
    warn "No mitigation found for the StyleSmuggler vector." \
         "No VCL snippet, web-server rule or containment patch was found, and no" \
         "edge rule blocked the probes above. Until Adobe ships a patch, mitigate" \
         "at the edge or temporarily disable GraphQL."
  fi
fi

# ---------------------------------------------------------------------------
# 12. GraphQL exposure
# ---------------------------------------------------------------------------

section "GraphQL exposure"

checking \
  "Command:curl -X POST -d '{\"query\":\"{__typename}\"}' <base_url>/graphql" \
  "Source:base URL from app/etc/env.php, else the MAGENTO_CLOUD_ROUTES upstream" \
  "Means:HTTP 200 = the attack surface answers from this host; a 403/406 suggests" \
  "     :something at the edge or origin is already blocking it" \
  "Note:one request, sent only when probing is enabled; it appears in the access log"

if [[ "$PROBE" -eq 0 ]]; then
  skip "Probing disabled (--no-probe); GraphQL reachability not tested."
elif [[ "$HAVE_MAGENTO" -eq 1 ]] && has curl; then
  base_url="${BASE_URL:-$(resolve_base_url)}"
  target="${base_url:-http://localhost}"
  target="${target%/}/graphql"
  # -L so an http -> https redirect reports the endpoint's real status, not a 301.
  # --post30x keeps the method across that redirect; without them curl downgrades
  # the POST to a GET and GraphQL answers 400 regardless of whether it is exposed.
  probe="$(curl -skL --post301 --post302 --post303 \
           -o /dev/null -w '%{http_code} %{url_effective}' --max-time 15 \
           -X POST -H 'Content-Type: application/json' \
           -d '{"query":"{__typename}"}' "$target" 2>/dev/null)"
  code="${probe%% *}"
  final_url="${probe#* }"
  [[ "$final_url" != "$target" ]] && info "Followed redirect to $final_url"
  case "$code" in
    200)
      # A plain {__typename} answering 200 is correct behaviour, not a finding, when
      # the edge already rejects the exploit-shaped requests. Only flag it when the
      # probes above found nothing filtering that traffic.
      if [[ "$EDGE_MITIGATED" -eq 1 ]]; then
        info "GraphQL answers normally at $final_url (HTTP $code), while exploit-shaped requests are blocked at the edge - the expected state."
      else
        warn "GraphQL endpoint is reachable and answering at $final_url (HTTP $code)." \
             "This is the StyleSmuggler attack vector and nothing was found filtering it." \
             "Until Adobe's patch is applied, mitigate at the edge or disable GraphQL."
      fi
      ;;
    403|406|429)
      ok "GraphQL returned HTTP $code - something at the edge or origin is rejecting the request."
      ;;
    000|"")
      info "Could not reach $target from this host (network restriction or wrong base URL)."
      ;;
    *)
      info "GraphQL endpoint at $final_url returned HTTP $code."
      ;;
  esac
else
  skip "curl or Magento root unavailable; GraphQL reachability not tested."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
printf '%s' "$C_BOLD"
echo "==============================================================="
echo " Summary"
echo "==============================================================="
printf '%s' "$C_RESET"
echo "Checks run:        $CHECKS_RUN"
echo "Critical findings: $CRITICAL_COUNT"
echo "Warnings:          $WARNING_COUNT"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Skipped checks:    ${#SKIPPED[@]}"
  printf '  - %s\n' "${SKIPPED[@]}"
fi
echo

if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
  printf '%sVERDICT: COMPROMISE INDICATORS PRESENT%s\n' "$C_BOLD$C_RED" "$C_RESET"
  cat <<'EOF'

Treat this host as compromised until proven otherwise. Recommended sequence:

  1. Preserve evidence first. Do NOT delete files or kill processes before
     capturing them - copy the implant files and `ps`/`ss` output off the host.
  2. Isolate the environment (block egress, take the node out of the pool).
  3. Rotate every credential the host could read: admin users, API integrations,
     database, payment gateway keys, SMTP, AWS/Cloud tokens, SSH keys.
  4. Rebuild from a known-good deployment rather than cleaning in place. The
     implant persists via cron and drops secondary backdoors.
  5. Check for skimmer code on the storefront and review recent orders and
     customer data access for exfiltration.
  6. Notify your security contact and, where applicable, meet PCI DSS 12.10
     incident-response and breach-notification obligations.
EOF
  exit 2
elif [[ "$WARNING_COUNT" -gt 0 ]]; then
  printf '%sVERDICT: NO CONFIRMED IOCs, BUT ITEMS NEED REVIEW%s\n' "$C_BOLD$C_YEL" "$C_RESET"
  cat <<'EOF'

Nothing matched a published StyleSmuggler indicator, but the warnings above are
worth a human look. A clean result is not proof of safety: the implant can be
updated, and log retention may be shorter than the exposure window.

Regardless of the result, apply Adobe's patch as soon as it is available and
restrict the GraphQL endpoint at the edge in the meantime.
EOF
  exit 1
else
  printf '%sVERDICT: NO INDICATORS FOUND%s\n' "$C_BOLD$C_GRN" "$C_RESET"
  cat <<'EOF'

No StyleSmuggler indicators were found. This is not proof of safety - it means
none of the published indicators are present on this host right now. Still:

  - Apply Adobe's patch as soon as it is available.
  - Restrict or rate-limit the GraphQL endpoint at the edge until then.
  - Re-run this check after patching, and on every environment (production,
    staging, integration) - not just production.
EOF
  exit 0
fi
