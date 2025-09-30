#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Dump environment and Magento configuration as sorted key=value lines.
# Run from a Magento project root for full output.

SECTIONED=1
MAGENTO_ROOT=""

# Simple arg parsing: --flat and --root PATH
while [ $# -gt 0 ]; do
  case "$1" in
    --flat) SECTIONED=0; shift ;;
    --root) MAGENTO_ROOT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# Optional chdir to Magento root
if [ -n "$MAGENTO_ROOT" ]; then
  set +e; cd "$MAGENTO_ROOT"; rc=$?; set -e
  if [ $rc -ne 0 ]; then
    echo "### Magento Root"
    echo "magento.root.error=cannot change directory to $MAGENTO_ROOT"
  fi
fi

# Always print current root and file presence
echo "### Magento Root"
echo "magento.root=$(pwd)"
for f in app/etc/env.php app/etc/config.php composer.lock; do
  if [ -f "$f" ]; then
    echo "magento.root.has[$f]=true"
  else
    echo "magento.root.has[$f]=false"
  fi
done

print_kv() {
  # Usage: print_kv section.key value
  local k="$1" v="${2:-}"
  printf "%s=%s\n" "$k" "$v"
}

has() { command -v "$1" >/dev/null 2>&1; }

begin_section() {
  if [ "$SECTIONED" -eq 1 ]; then
    echo "### $1"
  fi
}

section_meta() {
  begin_section "Meta"
  {
    print_kv meta.hostname "$(hostname 2>/dev/null || true)"
    print_kv meta.date "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print_kv meta.user "$(whoami 2>/dev/null || true)"
  } | LC_ALL=C sort
}

section_os() {
  begin_section "OS"
  {
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      print_kv os.id "${ID:-}"
      print_kv os.version_id "${VERSION_ID:-}"
      print_kv os.name "${PRETTY_NAME:-}"
    else
      print_kv os.name "unknown"
    fi
    print_kv os.uname "$(uname -a 2>/dev/null || true)"
  } | LC_ALL=C sort
}

section_php() {
  begin_section "PHP"
  {
    if has php; then
      print_kv php.version "$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"
      print_kv php.sapi "$(php -r 'echo PHP_SAPI;' 2>/dev/null || true)"
      php -r 'foreach(["memory_limit","max_execution_time","upload_max_filesize","post_max_size","opcache.enable","opcache.enable_cli","opcache.memory_consumption"] as $k){$v=ini_get($k);echo $k,"=",($v===false?"":$v),"\n";}' 2>/dev/null \
        | sed 's/^/php.ini./'
      if php -m >/dev/null 2>&1; then
        php -m 2>/dev/null | LC_ALL=C sort | sed 's/^/php.ext./'
      fi
    else
      print_kv php.version "not_found"
    fi
  } | LC_ALL=C sort
}

section_services() {
  begin_section "Service Versions"
  {
    has mysql && print_kv service.mysql.version "$(mysql -V 2>/dev/null || true)"
    if has valkey-cli; then
      print_kv service.valkey.version "$(valkey-cli --version 2>/dev/null || true)"
    elif has redis-cli; then
      print_kv service.valkey.version "$(redis-cli --version 2>/dev/null || true)"
    fi
    has rabbitmqctl && print_kv service.rabbitmq.version "$(rabbitmqctl status 2>/dev/null | grep -i rabbitmq_version | tr -s ' ' | sed 's/^ *//')"
  } | LC_ALL=C sort
}

flatten_php_array_file() {
  # $1: php file returning array (e.g., app/etc/env.php)
  # $2: prefix (e.g., envphp.)
  local file="$1" prefix="$2"
  [ -f "$file" ] || return 0
  # Capture stdout+stderr so we can report parse errors
  local raw
  raw=$(FILE="$file" php -r '
    $path = getenv("FILE");
    if (!$path || !file_exists($path)) {
      fwrite(STDERR, "missing:".$path."\n");
      exit(2);
    }
    $arr = @include $path;
    if (!is_array($arr)) {
      fwrite(STDERR, "not_array:".$path."\n");
      exit(3);
    }
    $walk = function($a, $p) use (&$walk) {
      foreach ($a as $k => $v) {
        $key = ($p === '' ? $k : $p.'.'.$k);
        if (is_array($v)) { $walk($v, $key); }
        else {
          $val = is_bool($v) ? ($v?"true":"false") : ($v===null?"null":$v);
          echo $key,'=',json_encode($val, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE),"\n";
        }
      }
    };
    $walk($arr, '');
  ' 2>&1)
  if [ -z "$raw" ]; then
    return 1
  fi
  printf "%s\n" "$raw" | LC_ALL=C sort | sed "s/^/${prefix}/"
}

section_magento_basic() {
  begin_section "Magento Core"
  {
    if [ -x bin/magento ]; then
      print_kv magento.version "$(./bin/magento --version 2>/dev/null | awk '{print $3}')"
      print_kv magento.mode "$(./bin/magento deploy:mode:show 2>/dev/null | awk -F': ' 'NR==1{print $2}')"
      ./bin/magento indexer:status 2>/dev/null | sed 's/^/magento.indexer./'
      ./bin/magento cache:status 2>/dev/null | sed 's/^/magento.cache./'
      ./bin/magento queue:consumers:list 2>/dev/null | sed 's/^/magento.consumer./'
      ./bin/magento config:show 2>/dev/null | sed -E 's/[[:space:]]*=>[[:space:]]*/=/' | sed 's/^/magento.config./' | LC_ALL=C sort
    else
      print_kv magento.info "bin/magento not found"
    fi
  } | LC_ALL=C sort
}

section_envphp() {
  begin_section "env.php"
  if [ -f app/etc/env.php ]; then
    out=$(flatten_php_array_file "app/etc/env.php" "envphp." || true)
    if [ -n "$out" ]; then
      printf "%s\n" "$out" | LC_ALL=C sort
    else
      print_kv envphp.read_error true
    fi
  else
    print_kv envphp.missing true
  fi
}

section_configphp() {
  begin_section "config.php"
  if [ -f app/etc/config.php ]; then
    out=$(flatten_php_array_file "app/etc/config.php" "configphp." || true)
    if [ -n "$out" ]; then
      printf "%s\n" "$out" | LC_ALL=C sort
    else
      print_kv configphp.read_error true
    fi
  else
    print_kv configphp.missing true
  fi
}

section_composer() {
  begin_section "Composer"
  if [ -f composer.lock ]; then
    out=$(php -r '\n      \$j = json_decode(file_get_contents("composer.lock"), true);\n      if (!is_array(\$j)) exit;\n      \$pkgs = array_merge(\$j["packages"] ?? [], \$j["packages-dev"] ?? []);\n      usort(\$pkgs, function($a,$b){return strcmp($a["name"], $b["name"]);});\n      foreach (\$pkgs as \$p) {\n        echo \$p["name"],"=",(\$p["version"]??""),"\n";\n      }\n    ' 2>/dev/null | sed 's/^/composer./')
    if [ -n "$out" ]; then
      printf "%s\n" "$out" | LC_ALL=C sort
    else
      print_kv composer.packages.count 0
    fi
  else
    print_kv composer.lock.missing true
  fi
}

section_adobe_modules() {
  begin_section "Magento Modules"
  if [ ! -f app/etc/config.php ] && [ ! -f composer.lock ]; then
    print_kv magento.modules.info "skipped (no config.php or composer.lock)"
    return 0
  fi
  php -r '
    $mods = [];
    if (file_exists("app/etc/config.php")) {
      $cfg = include "app/etc/config.php";
      foreach (($cfg["modules"] ?? []) as $name => $state) {
        if ($state) $mods[$name] = true;
      }
    }
    $pkgs = [];
    if (file_exists("composer.lock")) {
      $j = json_decode(file_get_contents("composer.lock"), true);
      foreach (["packages","packages-dev"] as $k) {
        foreach (($j[$k] ?? []) as $p) { $pkgs[$p["name"]] = $p["version"] ?? ""; }
      }
    }
    $edition = null; $editionVer = null;
    foreach ([
      "magento/product-enterprise-edition" => "commerce",
      "magento/product-community-edition" => "opensource",
    ] as $pkg => $ed) {
      if (isset($pkgs[$pkg])) { $edition=$ed; $editionVer=$pkgs[$pkg]; break; }
    }
    if ($edition) {
      echo "magento.edition=", $edition, "\n";
      if ($editionVer) echo "magento.edition.version=", $editionVer, "\n";
    }
    foreach (["magento/extension-b2b","magento/product-commerce-b2b"] as $b2b) {
      if (isset($pkgs[$b2b])) echo "magento.b2b.version=", $pkgs[$b2b], "\n";
    }
    ksort($mods, SORT_STRING);
    foreach (array_keys($mods) as $mod) {
      $ver = "";
      if (strpos($mod, "Magento_") === 0) {
        $suffix = strtolower(str_replace("_", "-", substr($mod, 8)));
        $pkg = "magento/module-".$suffix;
        if (isset($pkgs[$pkg])) $ver = $pkgs[$pkg];
      }
      echo "magento.module_enabled.", $mod, "=", $ver, "\n";
    }
  ' 2>/dev/null | sed 's/[[:space:]]\+$//' | LC_ALL=C sort
}

main() {
  section_meta || true
  section_os || true
  section_php || true
  section_services || true
  section_magento_basic || true
  section_adobe_modules || true
  section_envphp || true
  section_configphp || true
  section_composer || true
}

main
