#!/usr/bin/env bash 
# project: USERSPICE-5-ENV-AUDIT (https://github.com/tocsindata/userspice-5-env-audit)
# framework: Server readiness auditor for UserSpice 5 (audit-only; no mutations)
# file: scripts/userspice5-audit.sh
# date: 2025-09-17

set -euo pipefail

clear 

echo "##########################################################"

echo "##########################################################"

echo "##########################################################"

echo "##########################################################"

echo "##########################################################"

# -------------------------------#
# Defaults (override via env/CLI)
# -------------------------------#
PHP_BIN="${PHP_BIN:-php}"
MIN_PHP_MAJOR="${MIN_PHP_MAJOR:-8}"
MIN_PHP_MINOR="${MIN_PHP_MINOR:-1}"       # US v5 widely deployed on 8.1–8.3
WARN_NEWER_MINOR="${WARN_NEWER_MINOR:-4}" # warn on 8.4+
WEB_USER_GUESS="${WEB_USER_GUESS:-www-data}"

# Resource floors (warnings if below)
MIN_CPU_CORES="${MIN_CPU_CORES:-1}"
MIN_RAM_MB="${MIN_RAM_MB:-1024}"          # 1 GiB comfortable baseline
MIN_DISK_MB="${MIN_DISK_MB:-1024}"        # 1 GiB free where the app lives
MIN_INODES_PCT_FREE="${MIN_INODES_PCT_FREE:-5}"  # warn if <5% free inodes
MIN_ULIMIT_NOFILE="${MIN_ULIMIT_NOFILE:-1024}"

# PHP size thresholds (warn if below; not hard requirements)
MIN_PHP_MEMORY_MB="${MIN_PHP_MEMORY_MB:-128}"
MIN_PHP_POST_MB="${MIN_PHP_POST_MB:-8}"
MIN_PHP_UPLOAD_MB="${MIN_PHP_UPLOAD_MB:-8}"

APP_PATH=""
RDS_TARGET=""     # host:port for TCP-only reachability check
JSON_OUT="no"

# -------------------------------#
# CLI
# -------------------------------#
usage() {
  cat <<EOF
UserSpice 5 Environment Audit (audit-only)

Usage:
  $0 [--app-path /var/www/html] [--rds host:port] [--json]

Options:
  --app-path PATH     Check .htaccess, index.php, and common writable dirs under PATH
  --rds HOST:PORT     TCP reachability test to RDS/MySQL endpoint (no SQL login)
  --json              Emit JSON in addition to human-readable output
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path) APP_PATH="${2:-}"; shift 2 ;;
    --rds)      RDS_TARGET="${2:-}"; shift 2 ;;
    --json)     JSON_OUT="yes"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# -------------------------------#
# Pretty output + JSON collector
# -------------------------------#
if [[ -t 1 ]]; then
  G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[34m"; X="\033[0m"
else
  G=""; R=""; Y=""; B=""; X=""
fi

declare -a JSON_ITEMS
add_json() {
  # Robust to missing args under set -u
  local section="${1-}" status="${2-}" title="${3-}" detail="${4-}" suggestion="${5-}"
  section="${section:-}"; status="${status:-}"; title="${title:-}"
  detail="${detail:-}"; suggestion="${suggestion:-}"
  # Escape quotes/newlines for JSON-ish output
  detail=${detail//\"/\\\"}; detail=${detail//$'\n'/\\n}
  suggestion=${suggestion//\"/\\\"}; suggestion=${suggestion//$'\n'/\\n}
  JSON_ITEMS+=("{\"section\":\"$section\",\"status\":\"$status\",\"title\":\"$title\",\"detail\":\"$detail\",\"suggestion\":\"$suggestion\"}")
}

PASSES=0; FAILS=0; WARNS=0
ok () { echo -e "${G}✔ PASS${X}  $*"; ((PASSES++))||true; }
warn() { echo -e "${Y}▲ WARN${X}  $*"; }
bad () { echo -e "${R}✖ FAIL${X}  $*"; }
info(){ echo -e "${B}i${X}      $*"; }

note_fail(){ ((FAILS++))||true; }
note_warn(){ ((WARNS++))||true; }

# -------------------------------#
# Package manager (for suggestions only)
# -------------------------------#
PKG=""; PKG_ID=""
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  PKG_ID="${ID:-}"
  case "$PKG_ID" in
    ubuntu|debian) PKG="apt" ;;
    amzn|rhel|rocky|almalinux|centos|fedora) PKG="yum" ;;
    *) PKG="" ;;
  esac
fi

recommend_pkg() {
  local what="$1"
  case "$PKG" in
    apt)  echo "# RECOMMENDED COMMAND: sudo apt-get update && sudo apt-get install -y $what" ;;
    yum)  echo "# RECOMMENDED COMMAND: sudo yum install -y $what" ;;
    *)    echo "# RECOMMENDED COMMAND: Install '$what' via your server's package manager" ;;
  esac
}

# Map PHP extensions -> package names per family
map_ext_to_pkg() {
  local ext="$1"
  case "$PKG" in
    apt)
      case "$ext" in
        mysqli|pdo_mysql) echo "php-mysql" ;;
        xml)              echo "php-xml" ;;
        mbstring)         echo "php-mbstring" ;;
        curl)             echo "php-curl" ;;
        zip)              echo "php-zip" ;;
        gd)               echo "php-gd" ;;
        intl)             echo "php-intl" ;;
        json)             echo "php-json" ;;
        openssl)          echo "php-openssl" ;;
        fileinfo)         echo "php-common" ;;
        exif)             echo "php-exif" ;;
        *)                echo "php-$ext" ;;
      esac
      ;;
    yum)
      case "$ext" in
        mysqli|pdo_mysql) echo "php-mysqlnd" ;;
        xml)              echo "php-xml" ;;
        mbstring)         echo "php-mbstring" ;;
        curl)             echo "php-cli php-common" ;;
        zip)              echo "php-pecl-zip || php-zip" ;;
        gd)               echo "php-gd" ;;
        intl)             echo "php-intl" ;;
        json)             echo "php-json" ;;
        openssl)          echo "php-common" ;;
        fileinfo)         echo "php-common" ;;
        exif)             echo "php-exif" ;;
        *)                echo "php-$ext" ;;
      esac
      ;;
    *)
      echo "php-$ext"
      ;;
  esac
}

# -------------------------------#
# Helpers
# -------------------------------#
have(){ command -v "$1" >/dev/null 2>&1; }

to_bytes() {
  local v="${1,,}"
  [[ -z "$v" || "$v" == "0" ]] && { echo 0; return; }
  if [[ "$v" =~ ^([0-9]+)([kmg])$ ]]; then
    local n=${BASH_REMATCH[1]} s=${BASH_REMATCH[2]}
    case "$s" in k) echo $((n*1024));; m) echo $((n*1024*1024));; g) echo $((n*1024*1024*1024));; esac
  elif [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo 0
  fi
}

bytes_to_mb() {
  local b="$1"
  echo $(( (b + 1024*1024 - 1) / (1024*1024) ))
}

test_tcp() {
  local host="$1" port="$2"
  if have nc; then
    nc -z -w3 "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1
}

php_ini_path_cmd='$(php --ini | grep "Loaded Configuration" | awk "{print \$4}")'

recommend_php_restart() {
  if command -v systemctl >/dev/null 2>&1; then
    local hints=()
    systemctl list-units --type=service --all 2>/dev/null | grep -Eiq 'php.*fpm' && hints+=("sudo systemctl restart php-fpm || sudo systemctl restart php8.1-fpm || sudo systemctl restart php8.2-fpm || sudo systemctl restart php8.3-fpm")
    systemctl list-units --type=service --all 2>/dev/null | grep -qi apache2 && hints+=("sudo systemctl restart apache2")
    systemctl list-units --type=service --all 2>/dev/null | grep -qi httpd   && hints+=("sudo systemctl restart httpd")
    systemctl list-units --type=service --all 2>/dev/null | grep -qi nginx   && hints+=("sudo systemctl reload nginx")
    if ((${#hints[@]})); then
      for h in "${hints[@]}"; do
        echo "# RECOMMENDED COMMAND: $h"
      done
      return
    fi
  fi
  echo "# RECOMMENDED COMMAND: restart your web/PHP service (apache2/httpd or php-fpm) after changing php.ini"
}

section() { echo -e "\n------ $1 ------"; }

# -------------------------------#
# 1) PHP: version + extensions
# -------------------------------#
section "PHP"
if ! have "$PHP_BIN"; then
  bad "PHP CLI not found (searched for '$PHP_BIN')."
  add_json "PHP" "FAIL" "PHP binary" "Not found on PATH." "Install PHP 8.1–8.3 (CLI + FPM/Apache module)."
  note_fail
  case "$PKG" in
    apt) recommend_pkg "php php-cli php-fpm" ;;
    yum) recommend_pkg "php php-cli php-fpm" ;;
    *)   echo "# RECOMMENDED COMMAND: Install PHP (CLI + FPM or Apache module) appropriate for your OS" ;;
  esac
else
  ver="$($PHP_BIN -r 'echo PHP_VERSION;')" || ver=""
  info "Detected PHP: $ver"
  if [[ -z "$ver" ]]; then
    bad "Unable to determine PHP version."
    add_json "PHP" "FAIL" "PHP version" "php -r 'echo PHP_VERSION' returned empty." "Check PHP installation."
    note_fail
  else
    IFS='.' read -r maj min patch <<<"$ver"
    if (( maj < MIN_PHP_MAJOR || (maj == MIN_PHP_MAJOR && min < MIN_PHP_MINOR) )); then
      bad "PHP ${ver} is below recommended ${MIN_PHP_MAJOR}.${MIN_PHP_MINOR}."
      add_json "PHP" "FAIL" "Version ${ver}" "Below ${MIN_PHP_MAJOR}.${MIN_PHP_MINOR}." "Upgrade PHP."
      note_fail
      case "$PKG" in
        apt|yum) recommend_pkg "php" ;;
        *) echo "# RECOMMENDED COMMAND: Upgrade PHP via your package manager" ;;
      esac
    else
      ok "Version ${ver} (>= ${MIN_PHP_MAJOR}.${MIN_PHP_MINOR})."
      add_json "PHP" "PASS" "Version ${ver}" "Meets minimum." ""
    fi
    if (( maj == 8 && min >= WARN_NEWER_MINOR )); then
      warn "PHP ${ver} is newer than the most-tested range (8.1–8.3). Verify plugins/custom code."
      add_json "PHP" "WARN" "Newer branch ${ver}" ">= 8.${WARN_NEWER_MINOR}" "Smoke-test UserSpice + your customizations."
      note_warn
    fi
  fi

  # Extensions
  mapfile -t loaded < <($PHP_BIN -m | tr '[:upper:]' '[:lower:]' | sort)
  need=( mysqli pdo_mysql mbstring curl zip xml gd openssl json fileinfo exif )
  recommend=( intl )
  missing=()
  for e in "${need[@]}"; do
    printf '%s\n' "${loaded[@]}" | grep -qx "$e" || missing+=("$e")
  done
  if ((${#missing[@]})); then
    bad "Missing required PHP extensions: ${missing[*]}"
    add_json "PHP" "FAIL" "Extensions" "Missing: ${missing[*]}" "Install/enable these extensions."
    note_fail
    for ext in "${missing[@]}"; do
      pkgname="$(map_ext_to_pkg "$ext")"
      recommend_pkg "$pkgname"
    done
  else
    ok "All required PHP extensions present: ${need[*]}"
    add_json "PHP" "PASS" "Extensions" "All required present." ""
  fi

  rec_miss=()
  for e in "${recommend[@]}"; do
    printf '%s\n' "${loaded[@]}" | grep -qx "$e" || rec_miss+=("$e")
  done
  if ((${#rec_miss[@]})); then
    warn "Recommended extension(s) missing: ${rec_miss[*]} (needed for some locales/features)."
    add_json "PHP" "WARN" "Recommended extensions" "Missing: ${rec_miss[*]}" "Install if you need i18n and advanced formatting."
    note_warn
    for ext in "${rec_miss[@]}"; do
      pkgname="$(map_ext_to_pkg "$ext")"
      recommend_pkg "$pkgname"
    done
  else
    ok "Recommended extensions present: ${recommend[*]}"
    add_json "PHP" "PASS" "Recommended extensions" "Present." ""
  fi

  # php.ini sanity
  getini(){ $PHP_BIN -r "echo ini_get('$1');" 2>/dev/null || true; }
  mem_limit="$(getini memory_limit)"; post_max="$(getini post_max_size)"; upload_max="$(getini upload_max_filesize)"; max_exec="$(getini max_execution_time)"; tz="$(getini date.timezone)"
  info "php.ini: memory_limit=${mem_limit:-0}, post_max_size=${post_max:-0}, upload_max_filesize=${upload_max:-0}, max_execution_time=${max_exec:-0}, date.timezone=${tz:-<unset>}"

  mem_ok=$(( $(to_bytes "$mem_limit") >= MIN_PHP_MEMORY_MB*1024*1024 ? 1 : 0 ))
  post_ok=$(( $(to_bytes "$post_max") >= MIN_PHP_POST_MB*1024*1024 ? 1 : 0 ))
  upld_ok=$(( $(to_bytes "$upload_max") >= MIN_PHP_UPLOAD_MB*1024*1024 ? 1 : 0 ))

  if (( !mem_ok )); then
    warn "memory_limit seems low (${mem_limit}); ${MIN_PHP_MEMORY_MB}M+ recommended."
    add_json "PHP" "WARN" "memory_limit" "$mem_limit" "Increase to ${MIN_PHP_MEMORY_MB}M or higher."
    note_warn
    echo "# RECOMMENDED COMMAND: sudo sed -i 's/^memory_limit.*/memory_limit = ${MIN_PHP_MEMORY_MB}M/' ${php_ini_path_cmd}"
    recommend_php_restart
  fi
  if (( !post_ok )); then
    warn "post_max_size seems low (${post_max}); ${MIN_PHP_POST_MB}M+ recommended."
    add_json "PHP" "WARN" "post_max_size" "$post_max" "Increase to ${MIN_PHP_POST_MB}M or higher."
    note_warn
    echo "# RECOMMENDED COMMAND: sudo sed -i 's/^post_max_size.*/post_max_size = ${MIN_PHP_POST_MB}M/' ${php_ini_path_cmd}"
    recommend_php_restart
  fi
  if (( !upld_ok )); then
    warn "upload_max_filesize seems low (${upload_max}); ${MIN_PHP_UPLOAD_MB}M+ recommended."
    add_json "PHP" "WARN" "upload_max_filesize" "$upload_max" "Increase to ${MIN_PHP_UPLOAD_MB}M or higher."
    note_warn
    echo "# RECOMMENDED COMMAND: sudo sed -i 's/^upload_max_filesize.*/upload_max_filesize = ${MIN_PHP_UPLOAD_MB}M/' ${php_ini_path_cmd}"
    recommend_php_restart
  fi

  if [[ -z "$tz" ]]; then
    warn "date.timezone not set; set it in php.ini for predictable logs/time."
    add_json "PHP" "WARN" "date.timezone" "unset" "Set your preferred timezone (e.g., America/Vancouver)."
    note_warn
    echo "# RECOMMENDED COMMAND: sudo sed -i 's~^;\\?date.timezone.*~date.timezone = America/Vancouver~' ${php_ini_path_cmd}"
    recommend_php_restart
  fi

  # Sessions
  sess_path="$($PHP_BIN -r 'echo session_save_path();' 2>/dev/null || true)"
  if [[ -z "$sess_path" ]]; then
    warn "session_save_path not set; using system default. Ensure web SAPI can write its session dir."
    add_json "PHP" "WARN" "session_save_path" "unset" "Verify permissions on system session directory."
    note_warn
    echo "# RECOMMENDED COMMAND: php -i | grep -i 'session.save_path'"
  else
    if [[ -d "$sess_path" && -w "$sess_path" ]]; then
      ok "Session save path writable: ${sess_path}"
      add_json "PHP" "PASS" "session_save_path" "$sess_path" ""
    else
      bad "Session save path not writable/missing: ${sess_path}"
      add_json "PHP" "FAIL" "session_save_path" "$sess_path" "Fix directory ownership/permissions for web user."
      note_fail
      echo "# RECOMMENDED COMMAND: sudo mkdir -p '${sess_path}' && sudo chown -R ${WEB_USER_GUESS}:${WEB_USER_GUESS} '${sess_path}' && sudo chmod 770 '${sess_path}'"
    fi
  fi

  # Show which php.ini files are loaded
  if have "$PHP_BIN"; then
    ini_out="$($PHP_BIN --ini 2>/dev/null || true)"
    [[ -n "$ini_out" ]] && info "php --ini:\n$ini_out"
  fi
fi

# -------------------------------#
# 2) Web server rewrite readiness
# -------------------------------#
section "Web Server"
APACHE=0; NGINX=0
if have apache2ctl || have httpd; then APACHE=1; fi
if have nginx; then NGINX=1; fi

if (( APACHE==0 && NGINX==0 )); then
  warn "No Apache/Nginx command detected. On managed hosts/panels this can be normal."
  add_json "Web" "WARN" "Server binary" "Not detected on PATH." "Ensure your webserver supports rewrite/front-controller."
  note_warn
  case "$PKG" in
    apt) recommend_pkg "apache2"; recommend_pkg "nginx" ;;
    yum) recommend_pkg "httpd";   recommend_pkg "nginx" ;;
    *)   echo "# RECOMMENDED COMMAND: Install Apache (apache2/httpd) or Nginx" ;;
  esac
fi

if (( APACHE==1 )); then
  if have apache2ctl; then mods="$(apache2ctl -M 2>/dev/null || true)"; else mods="$(httpd -M 2>/dev/null || true)"; fi
  if echo "$mods" | grep -q 'rewrite_module'; then
    ok "Apache mod_rewrite enabled."
    add_json "Web" "PASS" "Apache mod_rewrite" "Enabled." ""
  else
    bad "Apache mod_rewrite is NOT enabled."
    add_json "Web" "FAIL" "Apache mod_rewrite" "Disabled." "Enable rewrite_module and AllowOverride."
    note_fail
    if have apache2ctl; then
      echo "# RECOMMENDED COMMAND: sudo a2enmod rewrite && sudo systemctl restart apache2"
      echo "# RECOMMENDED COMMAND: sudo sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf && sudo systemctl restart apache2"
    else
      echo "# RECOMMENDED COMMAND: Ensure 'LoadModule rewrite_module modules/mod_rewrite.so' is present, then: sudo systemctl restart httpd"
      echo "# RECOMMENDED COMMAND: In your vhost <Directory>, set: AllowOverride All"
    fi
  fi
fi

if (( NGINX==1 )); then
  info "Detected Nginx. Verify your server/location uses: try_files \$uri /index.php?\$query_string;"
  add_json "Web" "WARN" "Nginx try_files" "Cannot auto-inspect config." "Ensure front-controller routing is configured."
  note_warn
  cat <<'NGX'
# RECOMMENDED SNIPPET (nginx server/location):
# location / {
#   try_files $uri /index.php?$query_string;
# }
# location ~ \.php$ {
#   include fastcgi_params;
#   fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
#   fastcgi_pass unix:/run/php/php-fpm.sock;  # or host:port
# }
NGX
fi

# -------------------------------#
# 3) System resources
# -------------------------------#
section "System Resources"

# CPU cores
if have nproc; then cores="$(nproc)"; else cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"; fi
if (( cores < MIN_CPU_CORES )); then
  warn "CPU cores: $cores (recommended >= ${MIN_CPU_CORES})."
  add_json "System" "WARN" "CPU cores" "$cores" "Consider larger instance/vCPU count."
  note_warn
else
  ok "CPU cores: $cores"
  add_json "System" "PASS" "CPU cores" "$cores" ""
fi

# RAM
mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_mb=$(( mem_kb/1024 ))
if (( mem_mb < MIN_RAM_MB )); then
  warn "RAM: ${mem_mb} MB (recommended >= ${MIN_RAM_MB} MB)."
  add_json "System" "WARN" "RAM MB" "$mem_mb" "Consider increasing memory."
  note_warn
  echo "# RECOMMENDED ACTION: Resize the instance or add swap if necessary."
else
  ok "RAM: ${mem_mb} MB"
  add_json "System" "PASS" "RAM MB" "$mem_mb" ""
fi

# Disk & inodes
check_fs() {
  local path="$1"
  local df_out di_out
  df_out="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
  di_out="$(df -Pi "$path" | awk 'NR==2 {print $5}' | tr -d '%')"
  local free_mb="${df_out:-0}" used_pct_inodes="${di_out:-0}"
  local free_pct_inodes=$((100 - used_pct_inodes))
  if (( free_mb < MIN_DISK_MB )); then
    warn "Disk free at $path: ${free_mb} MB (< ${MIN_DISK_MB} MB)."
    add_json "System" "WARN" "Disk MB free ($path)" "$free_mb" "Free up space or resize volume."
    note_warn
    echo "# RECOMMENDED ACTION: Clean logs/cache or expand the filesystem at $path."
  else
    ok "Disk free at $path: ${free_mb} MB"
    add_json "System" "PASS" "Disk MB free ($path)" "$free_mb" ""
  fi
  if (( free_pct_inodes < MIN_INODES_PCT_FREE )); then
    warn "Inodes low at $path: ${free_pct_inodes}% free (< ${MIN_INODES_PCT_FREE}%)."
    add_json "System" "WARN" "Inodes % free ($path)" "$free_pct_inodes" "Delete excess tiny files or rebuild FS."
    note_warn
    echo "# RECOMMENDED ACTION: Remove many small files or migrate to a FS with more inodes."
  else
    ok "Inodes at $path: ${free_pct_inodes}% free"
    add_json "System" "PASS" "Inodes % free ($path)" "$free_pct_inodes" ""
  fi
}

check_fs "/"
[[ -n "$APP_PATH" ]] && check_fs "$APP_PATH"

# ulimit -n
nofile="$(ulimit -n 2>/dev/null || echo 0)"
if [[ "$nofile" == "unlimited" ]]; then nofile=1048576; fi
if (( nofile < MIN_ULIMIT_NOFILE )); then
  warn "Open files ulimit: $nofile (< ${MIN_ULIMIT_NOFILE})."
  add_json "System" "WARN" "ulimit -n" "$nofile" "Raise nofile in systemd unit or limits.conf."
  note_warn
  echo "# RECOMMENDED COMMAND: (systemd) sudo mkdir -p /etc/systemd/system/php-fpm.service.d"
  echo "# RECOMMENDED COMMAND: echo -e '[Service]\nLimitNOFILE=${MIN_ULIMIT_NOFILE}' | sudo tee /etc/systemd/system/php-fpm.service.d/limits.conf >/dev/null"
  echo "# RECOMMENDED COMMAND: sudo systemctl daemon-reload && sudo systemctl restart php-fpm || sudo systemctl restart apache2 || sudo systemctl restart httpd"
else
  ok "Open files ulimit: $nofile"
  add_json "System" "PASS" "ulimit -n" "$nofile" ""
fi

# -------------------------------#
# 4) Application path (.htaccess/dirs)
# -------------------------------#
if [[ -n "$APP_PATH" ]]; then
  section "Application Path"
  if [[ ! -d "$APP_PATH" ]]; then
    bad "APP_PATH does not exist: $APP_PATH"
    add_json "App" "FAIL" "APP_PATH" "$APP_PATH" "Provide a valid UserSpice root."
    note_fail
  else
    info "App path: $APP_PATH"
    add_json "App" "PASS" "APP_PATH" "$APP_PATH" ""

    if [[ -f "$APP_PATH/.htaccess" ]]; then
      ok ".htaccess present at app root."
      add_json "App" "PASS" ".htaccess" "present" ""
    else
      warn "No .htaccess at app root (for Apache environments)."
      add_json "App" "WARN" ".htaccess" "missing" "Add UserSpice .htaccess if using Apache/AllowOverride."
      note_warn
      echo "# RECOMMENDED COMMAND: printf '%s\n' \"<IfModule mod_rewrite.c>\" \"RewriteEngine On\" \"RewriteBase /\" \"RewriteCond %{REQUEST_FILENAME} !-f\" \"RewriteCond %{REQUEST_FILENAME} !-d\" \"RewriteRule . index.php [L]\" \"</IfModule>\" | sudo tee '$APP_PATH/.htaccess'"
    fi

    if [[ -f "$APP_PATH/index.php" ]]; then
      ok "index.php present at root."
      add_json "App" "PASS" "index.php" "present" ""
    else
      warn "index.php missing at app root."
      add_json "App" "WARN" "index.php" "missing" "Ensure your document root points to the UserSpice public entry."
      note_warn
    fi

    dirs=( "$APP_PATH/users" "$APP_PATH/usersc" "$APP_PATH/images" "$APP_PATH/uploads" "$APP_PATH/cache" )
    for d in "${dirs[@]}"; do
      if [[ -d "$d" ]]; then
        if [[ -w "$d" ]]; then
          ok "Writable directory: $d"
          add_json "App" "PASS" "Writable" "$d" ""
        else
          warn "Directory not writable by current user: $d (ensure web user can write if needed)."
          add_json "App" "WARN" "Writable" "$d" "Adjust owner/group to web user (e.g., ${WEB_USER_GUESS})."
          note_warn
          echo "# RECOMMENDED COMMAND: sudo chown -R ${WEB_USER_GUESS}:${WEB_USER_GUESS} '$d' && sudo find '$d' -type d -exec chmod 775 {} \\; && sudo find '$d' -type f -exec chmod 664 {} \\;"
        fi
      else
        warn "Expected directory not found (may be install-specific): $d"
        add_json "App" "WARN" "Missing dir" "$d" "Create if your install requires it."
        note_warn
        echo "# RECOMMENDED COMMAND: sudo mkdir -p '$d' && sudo chown -R ${WEB_USER_GUESS}:${WEB_USER_GUESS} '$d' && sudo chmod 775 '$d'"
      fi
    done

    owner="$(stat -c '%U:%G' "$APP_PATH" 2>/dev/null || echo '?')"
    info "APP_PATH ownership: $owner (web user often ${WEB_USER_GUESS})"
    add_json "App" "INFO" "Ownership" "$owner" "Ensure web user/group has needed access."
  fi
fi

# -------------------------------#
# 5) RDS/MySQL reachability (TCP only)
# -------------------------------#
if [[ -n "$RDS_TARGET" ]]; then
  section "RDS Connectivity (TCP only)"
  host="${RDS_TARGET%%:*}"; port="${RDS_TARGET##*:}"
  if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
    warn "Invalid --rds value '${RDS_TARGET}'. Use host:port (e.g., mydb.x.rds.amazonaws.com:3306)."
    add_json "RDS" "WARN" "Target parse" "$RDS_TARGET" "Use host:port."
    note_warn
  else
    if ! have nc; then
      warn "'nc' (netcat) not found; falling back to /dev/tcp for reachability test."
      if [[ "$PKG" == "apt" ]]; then
        echo "# RECOMMENDED COMMAND: sudo apt-get update && sudo apt-get install -y netcat"
      elif [[ "$PKG" == "yum" ]]; then
        echo "# RECOMMENDED COMMAND: sudo yum install -y nmap-ncat"
      else
        echo "# RECOMMENDED COMMAND: Install netcat (nc) via your package manager"
      fi
    fi
    if test_tcp "$host" "$port"; then
      ok "TCP reachable: $host:$port"
      add_json "RDS" "PASS" "Reachable" "$host:$port" ""
    else
      bad "TCP NOT reachable: $host:$port (firewall/security group/NACL/VPC route?)"
      add_json "RDS" "FAIL" "Reachable" "$host:$port" "Open SGs/NACLs; allow outbound from this host."
      note_fail
      echo "# RECOMMENDED ACTION: In AWS, allow inbound TCP ${port} from your server's IP in the RDS Security Group and ensure outbound from this host is allowed."
    fi
  fi
fi

# -------------------------------#
# 6) Virtual Hosts: list document roots (Apache & Nginx)
# -------------------------------#
section "Virtual Hosts"

print_path_status() {
  local p="$1"
  local tag=""
  [[ "$p" =~ (public|public_html|www|html|htdocs)($|/) ]] && tag=" (likely docroot)"
  if [[ -d "$p" ]]; then
    local ow="$(stat -c '%U:%G' "$p" 2>/dev/null || echo '?')"
    if [[ -w "$p" ]]; then
      echo " - $p [dir][writable] owner=$ow$tag"
    else
      echo " - $p [dir][not-writable] owner=$ow$tag"
    fi
  else
    echo " - $p [missing]$tag"
  fi
}

add_vhost_json() { # server path kind
  add_json "VHosts" "INFO" "$3: $1" "$2" "Verify this is the intended document root."
}

found_any=0
declare -A SEEN # key = "$kind|$server|$path"

# --- Apache
if (( APACHE == 1 )); then
  echo "Apache vhost roots:"
  if apache2ctl -S >/tmp/apache_vhosts.txt 2>/dev/null || httpd -S >/tmp/apache_vhosts.txt 2>/dev/null; then
    # Collect conf paths
    readarray -t A_CONFS < <(awk '/namevhost|port [0-9]+ namevhost/ {conf=$0; sub(/^.*\(/,"",conf); sub(/:[0-9]+\).*$/,"",conf); print conf}' /tmp/apache_vhosts.txt | sort -u)
    for conf in "${A_CONFS[@]}"; do
      [[ -f "$conf" ]] || continue
      while IFS='|' read -r srv p; do
        [[ -z "$p" ]] && continue
        key="Apache|$srv|$p"
        [[ -n "${SEEN[$key]:-}" ]] && continue
        SEEN[$key]=1
        found_any=1
        echo "• ${srv:-(unknown)}"
        print_path_status "$p"
        add_vhost_json "${srv:-(unknown)}" "$p" "Apache"
      done < <(awk '
        BEGIN{ server=""; }
        /^[[:space:]]*#/ {next}
        /<VirtualHost/ { server=""; }
        /ServerName[[:space:]]+/ { server=$2; }
        /ServerAlias[[:space:]]+/ { if(server==""){server=$2}else{server=server","$2} }
        /DocumentRoot[[:space:]]+/ {
          path=$2; gsub(/"/,"",path);
          if(server==""){server="(unknown)";}
          print server "|" path;
        }' "$conf" 2>/dev/null)
    done
    rm -f /tmp/apache_vhosts.txt
  else
    # Fallback: scan common dirs
    declare -a A_CONF_DIRS=(/etc/apache2/sites-enabled /etc/apache2/sites-available /etc/httpd/conf.d /etc/httpd/sites-enabled)
    declare -a A_FILES=()
    for d in "${A_CONF_DIRS[@]}"; do
      [[ -d "$d" ]] && readarray -t tmp < <(find "$d" -maxdepth 1 -type f -name "*.conf" 2>/dev/null || true) && A_FILES+=("${tmp[@]}")
    done
    if (( ${#A_FILES[@]} == 0 )); then
      echo " (no readable vhost confs found; try running as a user with permission)"
      echo "# RECOMMENDED COMMAND: apache2ctl -S  # Debian/Ubuntu  OR  httpd -S  # RHEL/Amazon"
    else
      for f in "${A_FILES[@]}"; do
        while IFS='|' read -r srv p; do
          [[ -z "$p" ]] && continue
          key="Apache|$srv|$p"
          [[ -n "${SEEN[$key]:-}" ]] && continue
          SEEN[$key]=1
          found_any=1
          echo "• ${srv:-(unknown)}"
          print_path_status "$p"
          add_vhost_json "${srv:-(unknown)}" "$p" "Apache"
        done < <(awk '
          BEGIN{ server=""; }
          /^[[:space:]]*#/ {next}
          /<VirtualHost/ { server=""; }
          /ServerName[[:space:]]+/ { server=$2; }
          /ServerAlias[[:space:]]+/ { if(server==""){server=$2}else{server=server","$2} }
          /DocumentRoot[[:space:]]+/ {
            path=$2; gsub(/"/,"",path);
            if(server==""){server="(unknown)";}
            print server "|" path;
          }' "$f" 2>/dev/null)
      done
    fi
  fi
fi

# --- Nginx
if have nginx; then
  echo "Nginx server roots:"
  if nginx -T >/tmp/nginx_all.conf 2>/dev/null; then
    while IFS='|' read -r srv p; do
      [[ -z "$p" ]] && continue
      key="Nginx|$srv|$p"
      [[ -n "${SEEN[$key]:-}" ]] && continue
      SEEN[$key]=1
      found_any=1
      [[ -z "$srv" ]] && srv="(unknown)"
      echo "• $srv"
      print_path_status "$p"
      add_vhost_json "$srv" "$p" "Nginx"
    done < <(awk '
      BEGIN{ inserver=0; server=""; root=""; }
      /^[[:space:]]*#/ {next}
      /server[[:space:]]*\{/ { inserver=1; server=""; root=""; next }
      inserver && /\}/ { if(root!="") { print server "|" root; } inserver=0; server=""; root=""; next }
      inserver && /server_name[[:space:]]+/ { sub(/^[[:space:]]*server_name[[:space:]]+/,""); sub(/;[[:space:]]*$/,""); server=$0 }
      inserver && /^[[:space:]]*root[[:space:]]+/ { sub(/^[[:space:]]*root[[:space:]]+/,""); sub(/;[[:space:]]*$/,""); root=$0 }
    ' /tmp/nginx_all.conf)
    rm -f /tmp/nginx_all.conf
  else
    echo " (cannot dump Nginx config; permission?)"
    echo "# RECOMMENDED COMMAND: sudo nginx -T  # print full resolved config"
  fi
fi

if (( APACHE == 0 && NGINX == 0 )); then
  echo "(no webserver detected; skipping vhost scan)"
fi


if (( found_any == 0 )); then
  if (( APACHE == 1 || NGINX == 1 )); then
    warn "No document roots found in scanned vhost files. You may need elevated privileges or custom paths."
    add_json "VHosts" "WARN" "No docroots found" "Check permissions or non-standard config paths. Run apache2ctl -S (or httpd -S) and/or nginx -T as applicable."
    note_warn
    (( APACHE == 1 )) && echo "# RECOMMENDED COMMAND: apache2ctl -S   # or: httpd -S"
    (( NGINX == 1 )) && echo "# RECOMMENDED COMMAND: sudo nginx -T"
  fi
fi


# -------------------------------#
# 7) HTTPS / SSL Audit (Apache + firewall + cert paths)
# -------------------------------#
section "HTTPS / SSL"

have(){ command -v "$1" >/dev/null 2>&1; }  # in case this file section is moved

sanitize_username_ssl() {
  local s="${1,,}"
  s="${s//[^a-z0-9._-]/_}"
  s="${s//./_}"
  s="$(echo -n "$s" | tr -s '_')"
  echo "${s:0:32}"
}

# Helpers
recommend(){ echo "# RECOMMENDED COMMAND: $*"; }
listen_on_443=0
ssl_mod_enabled=0

# 7.1 Apache SSL module + :443 listener
if have apache2ctl || have httpd; then
  if apache2ctl -M 2>/dev/null | grep -q 'ssl_module' || httpd -M 2>/dev/null | grep -q 'ssl_module'; then
    ok "Apache mod_ssl enabled."
    add_json "HTTPS" "PASS" "mod_ssl" "Enabled" ""
    ssl_mod_enabled=1
  else
    warn "Apache mod_ssl is NOT enabled."
    add_json "HTTPS" "WARN" "mod_ssl" "Disabled" "Enable SSL module for HTTPS."
    note_warn
    recommend "a2enmod ssl && apache2ctl configtest && systemctl reload apache2"
  fi

  if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ':443 '; then
    ok "Apache is listening on TCP 443."
    add_json "HTTPS" "PASS" "Listener 443" "Present" ""
    listen_on_443=1
  else
    warn "No listener on TCP 443 detected."
    add_json "HTTPS" "WARN" "Listener 443" "Missing" "Ensure Listen 443 and mod_ssl are configured."
    note_warn
    echo "# RECOMMENDED COMMAND: grep -n 'Listen 443' /etc/apache2/ports.conf /etc/httpd/conf.d/ssl.conf 2>/dev/null"
  fi
else
  warn "No Apache binary found; skipping HTTPS/SSL audit."
  add_json "HTTPS" "WARN" "Apache" "Not detected" "Install/enable Apache for HTTPS."
  note_warn
fi

# 7.2 Firewall openings (UFW / firewalld)
if have ufw; then
  if ufw status | grep -q -i 'Status: active'; then
    if ufw status | grep -Eq '443/tcp|Apache Full'; then
      ok "UFW allows HTTPS (443)."
      add_json "HTTPS" "PASS" "Firewall (ufw)" "443 allowed" ""
    else
      warn "UFW is active but 443 is not allowed."
      add_json "HTTPS" "WARN" "Firewall (ufw)" "443 blocked" "Allow HTTPS in UFW."
      note_warn
      recommend "ufw allow 'Apache Full'"
      recommend "ufw status"
    fi
  else
    info "UFW inactive."
  fi
fi
if have firewall-cmd; then
  if systemctl is-active --quiet firewalld; then
    if firewall-cmd --list-services | grep -qw https; then
      ok "firewalld allows HTTPS (service=https)."
      add_json "HTTPS" "PASS" "Firewall (firewalld)" "https allowed" ""
    else
      warn "firewalld active but HTTPS not open."
      add_json "HTTPS" "WARN" "Firewall (firewalld)" "https not open" "Add https service."
      note_warn
      recommend "firewall-cmd --permanent --add-service=https && firewall-cmd --reload"
    fi
  fi
fi

# 7.3 Discover :443 vhosts + cert paths + docroots (Apache)
declare -A SSL_VHOSTS
declare -A SSL_CERT
declare -A SSL_KEY
declare -A SSL_DOCROOT
declare -i found_ssl_vhosts=0

APACHECTL=""
if have apache2ctl; then APACHECTL="apache2ctl"; elif have httpd; then APACHECTL="httpd"; fi

if [[ -n "$APACHECTL" ]]; then
  if $APACHECTL -S >/tmp/_ssl_vh.txt 2>/dev/null; then
    readarray -t SSL_CONF_PATHS < <(awk '/port 443 namevhost/ {conf=$0; sub(/^.*\(/,"",conf); sub(/:[0-9]+\).*$/,"",conf); print conf}' /tmp/_ssl_vh.txt | sort -u)
    for conf in "${SSL_CONF_PATHS[@]}"; do
      [[ -f "$conf" ]] || continue
      while IFS='|' read -r srv root crt key; do
        SSL_VHOSTS["$srv"]="$conf"
        SSL_CERT["$srv"]="$crt"
        SSL_KEY["$srv"]="$key"
        SSL_DOCROOT["$srv"]="$root"
        found_ssl_vhosts=1
        echo "• $srv"
        echo " - conf: $conf"
        echo " - docroot: ${root:-<unset>}"
        echo " - cert: ${crt:-<unset>}"
        echo " - key : ${key:-<unset>}"
      done < <(awk '
        BEGIN{in443=0; server=""; root=""; crt=""; key="";}
        /^[[:space:]]*#/ {next}
        /<VirtualHost/ {in443 = ($0 ~ /:443/); server=""; root=""; crt=""; key="";}
        in443 && /ServerName[[:space:]]+/ {server=$2}
        in443 && /DocumentRoot[[:space:]]+/ {root=$2}
        in443 && /SSLCertificateFile[[:space:]]+/ {crt=$2}
        in443 && /SSLCertificateKeyFile[[:space:]]+/ {key=$2}
        in443 && /<\/VirtualHost>/ { if (server!="") printf("%s|%s|%s|%s\n", server, root, crt, key) }
      ' "$conf")
    done
    rm -f /tmp/_ssl_vh.txt
  else
    warn "Could not run '$APACHECTL -S' to enumerate vhosts."
    note_warn
  fi

  if (( found_ssl_vhosts == 0 )); then
    warn "No :443 <VirtualHost> blocks found in Apache vhosts."
    add_json "HTTPS" "WARN" "443 vhosts" "None" "Add a :443 vhost for each site."
    note_warn
    recommend "a2enmod ssl && a2ensite default-ssl.conf  # or create a proper <domain>.conf:443"
  fi
fi

# 7.4 For each 443 vhost, evaluate snakeoil vs LE, cert presence, expiry, probes
cloudflare_ranges_hint_shown=0
for srv in "${!SSL_VHOSTS[@]}"; do
  conf="${SSL_VHOSTS[$srv]}"
  root="${SSL_DOCROOT[$srv]}"
  crt="${SSL_CERT[$srv]}"
  key="${SSL_KEY[$srv]}"

  if [[ "$crt" =~ /etc/ssl/certs/ssl-cert-snakeoil\.pem ]]; then
    warn "[$srv] Using snakeoil certificate."
    add_json "HTTPS" "WARN" "$srv uses snakeoil" "$crt" "Switch to Let's Encrypt fullchain/privkey."
    note_warn
    recommend "sed -i \"s#^\\s*SSLCertificateFile\\s\\+.*#    SSLCertificateFile /etc/letsencrypt/live/${srv}/fullchain.pem#\" '$conf'"
    recommend "sed -i \"s#^\\s*SSLCertificateKeyFile\\s\\+.*#    SSLCertificateKeyFile /etc/letsencrypt/live/${srv}/privkey.pem#\" '$conf'"
    recommend "apache2ctl configtest && systemctl reload apache2"
  elif [[ -z "${crt:-}" || -z "${key:-}" ]]; then
    warn "[$srv] No SSLCertificateFile/Key configured in :443 vhost."
    add_json "HTTPS" "WARN" "$srv missing cert paths" "No SSLCertificateFile/KeyFile" "Point to LE files or issue a cert."
    note_warn
  else
    ok "[$srv] Cert/key paths configured."
    add_json "HTTPS" "PASS" "$srv cert paths" "$crt | $key" ""
  fi

  if [[ -d "/etc/letsencrypt/live/${srv}" ]]; then
    pem="/etc/letsencrypt/live/${srv}/fullchain.pem"
    if [[ -f "$pem" ]]; then
      end="$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | cut -d= -f2- || true)"
      if [[ -n "$end" ]]; then
        epoch_end="$(date -d "$end" +%s 2>/dev/null || echo 0)"
        epoch_now="$(date -u +%s)"
        days_left=$(( (epoch_end - epoch_now) / 86400 ))
        if (( days_left < 0 )); then
          bad "[$srv] Let's Encrypt cert EXPIRED ${days_left#-} day(s) ago."
          add_json "HTTPS" "FAIL" "$srv cert expiry" "expired" "Renew with certbot."
          note_fail
          echo "# RECOMMENDED COMMAND: certbot certonly -a webroot --email admin@${srv#*.} -w '/home/$(sanitize_username_ssl "$srv")/public_html' -d '$srv' --agree-tos"
        elif (( days_left < 30 )); then
          warn "[$srv] Let's Encrypt cert expires in ${days_left} day(s)."
          add_json "HTTPS" "WARN" "$srv cert expiry" "${days_left} days" "Renew soon."
          note_warn
        else
          ok "[$srv] Let's Encrypt cert valid for ${days_left} day(s)."
          add_json "HTTPS" "PASS" "$srv cert expiry" "${days_left} days" ""
        fi
      fi
    else
      warn "[$srv] No fullchain.pem at /etc/letsencrypt/live/${srv}/"
      add_json "HTTPS" "WARN" "$srv LE files" "missing fullchain.pem" "Issue cert with certbot."
      note_warn
      echo "# RECOMMENDED COMMAND: certbot certonly -a webroot --email admin@${srv#*.} -w '/home/$(sanitize_username_ssl "$srv")/public_html' -d '$srv' --agree-tos"
    fi
  else
    warn "[$srv] No /etc/letsencrypt/live/${srv} directory found."
    add_json "HTTPS" "WARN" "$srv LE directory" "missing" "Run certbot to issue a cert."
    note_warn
  fi

  if have curl; then
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://$srv/" || echo "000")"
    https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "https://$srv/" || echo "000")"
    info "[$srv] Probe: http=$http_code  https=$https_code"
    add_json "HTTPS" "INFO" "$srv probes" "http=$http_code https=$https_code" ""

    if [[ "$http_code" =~ ^2|^3|^401|^403 ]] && [[ ! "$https_code" =~ ^2|^3|^401|^403 ]]; then
      warn "[$srv] HTTP works but HTTPS does not."
      add_json "HTTPS" "WARN" "$srv https probe" "HTTP ok, HTTPS bad" "Check mod_ssl, 443 vhost, cert paths, firewall."
      note_warn
      recommend "a2enmod ssl && a2ensite '${srv}.conf' && apache2ctl configtest && systemctl reload apache2"
      recommend "ss -ltn | grep ':443' || netstat -ltn | grep ':443'"
      recommend "tail -n 100 /var/log/apache2/error.log"
    fi

    if curl -sSI --max-time 6 "https://$srv/" 2>/dev/null | grep -iqE 'server:\s*cloudflare|cf-ray:'; then
      warn "[$srv] Cloudflare proxy detected."
      add_json "HTTPS" "WARN" "$srv Cloudflare" "Proxy detected" "For first issuance, disable orange cloud (DNS only), then re-enable."
      note_warn
      if [[ ! -f "/etc/letsencrypt/live/${srv}/fullchain.pem" ]]; then
        echo "# RECOMMENDED ACTION: Temporarily set DNS to gray cloud for $srv in Cloudflare, issue cert, then re-enable proxy."
      fi
      if (( cloudflare_ranges_hint_shown == 0 )); then
        cloudflare_ranges_hint_shown=1
        echo "# NOTE: After re-enabling proxy, give ~60s for propagation; then verify: curl -I https://$srv"
      fi
    fi
  else
    warn "curl not found; skipping live HTTP/HTTPS probes."
    add_json "HTTPS" "WARN" "curl" "missing" "Install curl to enable probes."
    note_warn
    case "$PKG" in
      apt) recommend "apt-get update && apt-get install -y curl" ;;
      yum) recommend "yum install -y curl" ;;
    esac
  fi

  if [[ -f "$conf" && -n "$root" && -n "$crt" ]]; then
    if have grep; then
      if ! grep -Eq 'RewriteCond\s+%{HTTPS}\s+!=on|Redirect\s+301\s+/' "$conf"; then
        info "[$srv] Consider adding HTTP→HTTPS redirect in the :80 vhost."
        add_json "HTTPS" "INFO" "$srv redirect" "Not detected" "Add RewriteRule redirect to HTTPS."
        cat <<'REDIR'
# RECOMMENDED SNIPPET (inside the :80 VirtualHost):
#   RewriteEngine On
#   RewriteCond %{HTTPS} !=on
#   RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
REDIR
      fi
    fi
  fi

done

if (( found_ssl_vhosts == 0 )) && (( ssl_mod_enabled == 1 )); then
  echo "# HINT: Create a :443 vhost for your domain (e.g., /etc/apache2/sites-available/<domain>.conf) with SSLCertificateFile/KeyFile set to LE paths."
  echo "# Then: a2ensite <domain>.conf && apache2ctl configtest && systemctl reload apache2"
fi

# -------------------------------#
# Summary + exit code
# -------------------------------#
section "Summary"
echo "Total PASS: $PASSES"
echo "Total WARN: $WARNS"
echo "Total FAIL: $FAILS"

if [[ "$JSON_OUT" == "yes" ]]; then
  echo
  echo "# JSON OUTPUT"
  if ((${#JSON_ITEMS[@]})); then
    printf '[\n  %s\n]\n' "$(IFS=,; echo "${JSON_ITEMS[*]}")"
  else
    echo "[]"
  fi
else
  echo "(JSON disabled — run with --json to emit machine-readable results.)"
fi

if (( FAILS > 0 )); then exit 1; else exit 0; fi
