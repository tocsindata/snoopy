#!/usr/bin/env bash
# project: SERVER_AUTOMATION (https://github.com/tocsindata/SERVER_AUTOMATION)
# framework: UserSpice 5
# file: /usr/local/sbin/update-php.sh
# date: 2025-09-20
# copyright: Daniel Foscarini (www.tocsindata.com) info@tocsindata.com


set -euo pipefail

# =========================================
# Config (can override via CLI flags)
# =========================================
TARGET_VERSION=""     # e.g., "8.3" or "8.3.12"; empty = auto-latest stable
SKIP_DOT_ZERO=1       # skip X.Y.0 minors (require at least .1)
APACHE_SERVICE="apache2"   # "apache2" on Debian/Ubuntu, "httpd" on RHEL/Alma/Rocky/AMZ

# Extensions (Ubuntu/Debian use phpX.Y-<ext>; RHEL uses php-<ext>)
INSTALL_EXTS=(curl mbstring intl xml zip gd mysql ldap opcache bcmath readline)

# Default mode: prefer mod_php on Debian/Ubuntu; FPM on RHEL family
WANT_MODE="auto"  # auto | fpm | modphp

# Global override INI we manage (applied only to target series)
TOCSIN_INI_BODY=$(cat <<'EOF'
; 99-tocsin.ini — enforced for all sites on this server (managed by update-php.sh)
date.timezone = UTC
expose_php = Off
memory_limit = 512M
post_max_size = 64M
upload_max_filesize = 64M
max_execution_time = 120
max_input_vars = 5000
opcache.enable=1
opcache.enable_cli=1
opcache.jit=off
EOF
)

usage() {
  cat <<EOF
Usage: $0 [--version 8.3|8.3.12] [--allow-dot-zero] [--fpm] [--mod-php] [--apache-service apache2|httpd]

Examples:
  $0                        # auto-detect latest stable (skip X.Y.0)
  $0 --version 8.3          # install latest 8.3.x
  $0 --version 8.4.5        # install exactly 8.4.5 if available
  $0 --fpm                  # force php-fpm + Apache proxy_fcgi
  $0 --mod-php              # force libapache2-mod-php (Debian/Ubuntu)
EOF
}

have(){ command -v "$1" >/dev/null 2>&1; }
log(){  printf '%s %s\n' "[$(date +'%F %T')]" "$*"; }
warn(){ printf '%s %s\n' "[$(date +'%F %T')] [WARN]" "$*" >&2; }
err(){  printf '%s %s\n' "[$(date +'%F %T')] [ERROR]" "$*" >&2; }

need_root() { [[ $EUID -eq 0 ]] || { err "Run as root"; exit 1; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) TARGET_VERSION="${2:-}"; shift 2;;
    --allow-dot-zero) SKIP_DOT_ZERO=0; shift;;
    --fpm) WANT_MODE="fpm"; shift;;
    --mod-php) WANT_MODE="modphp"; shift;;
    --apache-service) APACHE_SERVICE="${2:-apache2}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# -----------------------------
# Detect distro
# -----------------------------
detect_os() {
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VER="${VERSION_ID:-}"
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    PM="apt"
  elif [[ "$OS_ID" == "amzn" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" || "$OS_ID" == "centos" ]]; then
    PM="dnf"; APACHE_SERVICE="httpd"
  else
    if have apt; then PM="apt"
    elif have dnf; then PM="dnf"
    else err "Unsupported OS"; exit 1
    fi
  fi
  log "Detected OS=$OS_ID $OS_VER (like: $OS_LIKE), PM=$PM, Apache=$APACHE_SERVICE"
}

# -----------------------------
# Figure out target PHP version
# -----------------------------
normalize_version(){ local v="$1"; v="${v#php-}"; echo "$v"; }

get_latest_php_from_phpnet() {
  local url="https://www.php.net/releases/index.php?json&version=8"
  have curl || { warn "curl not found; cannot auto-detect latest PHP. Provide --version."; echo ""; return; }
  local json; json="$(curl -fsSL "$url" || true)"
  [[ -z "$json" ]] && { warn "Failed to fetch php.net releases JSON"; echo ""; return; }
  local list
  list="$(echo "$json" | grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"' | sort -V)"
  [[ -z "$list" ]] && { warn "No versions parsed from php.net JSON"; echo ""; return; }
  local latest=""; while read -r v; do latest="$v"; done <<<"$(echo "$list")"
  if (( SKIP_DOT_ZERO == 1 )) && [[ "$latest" =~ ^([0-9]+)\.([0-9]+)\.0$ ]]; then
    latest="$(echo "$list" | grep -E '^[0-9]+\.[0-9]+\.([1-9][0-9]*)$' | tail -n 1 || true)"
    [[ -z "$latest" ]] && latest="$last_line"
  fi
  echo "$latest"
}

resolve_target_version() {
  if [[ -n "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(normalize_version "$TARGET_VERSION")"
    if [[ "$TARGET_VERSION" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      TARGET_MAJOR="${BASH_REMATCH[1]}"; TARGET_MINOR="${BASH_REMATCH[2]}"; TARGET_PATCH=""
    elif [[ "$TARGET_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      TARGET_MAJOR="${BASH_REMATCH[1]}"; TARGET_MINOR="${BASH_REMATCH[2]}"; TARGET_PATCH="${BASH_REMATCH[3]}"
    else
      err "Invalid version format: $TARGET_VERSION"; exit 1
    fi
  else
    local latest; latest="$(get_latest_php_from_phpnet)"
    [[ -z "$latest" ]] && { err "Could not determine latest PHP. Use --version."; exit 1; }
    TARGET_VERSION="$latest"
    TARGET_MAJOR="$(echo "$latest" | cut -d. -f1)"
    TARGET_MINOR="$(echo "$latest" | cut -d. -f2)"
    TARGET_PATCH="$(echo "$latest" | cut -d. -f3)"
  fi
  PHP_SERIES="${TARGET_MAJOR}.${TARGET_MINOR}"    # e.g., 8.3
  log "Target PHP: $TARGET_VERSION (series $PHP_SERIES)"
}

# -----------------------------
# APT-based install (Ubuntu/Debian)
# -----------------------------
setup_apt_repos() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl software-properties-common lsb-release gnupg
  if [[ "$OS_ID" == "debian" ]]; then
    if ! grep -q "packages.sury.org/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury.gpg
      echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
    fi
  else
    add-apt-repository -y ppa:ondrej/php
  fi
  apt-get update -y
}

apt_install_php() {
  local pkgs=( "php${PHP_SERIES}-cli" "php${PHP_SERIES}-common" )
  # Decide SAPI if auto
  if [[ "$WANT_MODE" == "auto" ]]; then
    WANT_MODE="modphp"  # Debian/Ubuntu default preference
  fi
  if [[ "$WANT_MODE" == "modphp" ]]; then
    pkgs+=( "libapache2-mod-php${PHP_SERIES}" )
  else
    pkgs+=( "php${PHP_SERIES}-fpm" )
  fi
  for e in "${INSTALL_EXTS[@]}"; do pkgs+=( "php${PHP_SERIES}-${e}" ); done
  apt-get install -y "${pkgs[@]}"
}

apt_switch_apache_php_sapi() {
  # Disable any existing php module/confs, enable only target series + required Apache bits
  if [[ "$APACHE_SERVICE" != "apache2" ]]; then return 0; fi

  # Disable all php modules
  local m; for m in /etc/apache2/mods-enabled/php*.load; do
    [[ -e "$m" ]] && a2dismod "$(basename "$m" .load)" || true
  done

  if [[ "$WANT_MODE" == "modphp" ]]; then
    a2enmod "php${PHP_SERIES}" || true
    # Disable any php*-fpm Apache confs
    local c; for c in /etc/apache2/conf-enabled/php*-fpm.conf; do
      [[ -e "$c" ]] && a2disconf "$(basename "$c")" || true
    done
    a2enmod mpm_prefork || true
    a2dismod mpm_event || true
  else
    # FPM route: ensure proxy_fcgi set and target php-fpm conf enabled; disable other versions
    a2enmod proxy proxy_fcgi setenvif || true
    a2enconf "php${PHP_SERIES}-fpm" || true
    local c; for c in /etc/apache2/conf-enabled/php*-fpm.conf; do
      [[ "$(basename "$c")" != "php${PHP_SERIES}-fpm.conf" ]] && a2disconf "$(basename "$c")" || true
    done
    a2dismod "php${PHP_SERIES}" || true
    a2enmod mpm_event || true
    a2dismod mpm_prefork || true
  fi

  systemctl reload "$APACHE_SERVICE" || true
}

apt_update_alternatives_cli() {
  # Point /usr/bin/php (and friends) to the series we installed
  local base="/usr/bin"
  local targets=(php phar phar.phar phpize php-config)
  for bin in "${targets[@]}"; do
    local ver_path="${base}/${bin}${PHP_SERIES}"
    if [[ -x "$ver_path" ]]; then
      update-alternatives --install "${base}/${bin}" "${bin}" "${ver_path}" 90 || true
      update-alternatives --set "${bin}" "${ver_path}" || true
    fi
  done
}

apt_write_ini_and_prune() {
  # Remove our override from old series; add to new series only
  local root="/etc/php"
  # prune old
  if [[ -d "$root" ]]; then
    find "$root" -maxdepth 2 -type d -name conf.d | while read -r d; do
      if [[ "$d" != "$root/${PHP_SERIES}/apache2/conf.d" && "$d" != "$root/${PHP_SERIES}/fpm/conf.d" && "$d" != "$root/${PHP_SERIES}/cli/conf.d" ]]; then
        rm -f "$d/99-tocsin.ini" || true
      fi
    done
  fi
  # write to target series SAPIs that exist
  for sapi in apache2 fpm cli; do
    local d="/etc/php/${PHP_SERIES}/${sapi}/conf.d"
    [[ -d "$d" ]] || continue
    printf "%s\n" "$TOCSIN_INI_BODY" > "${d}/99-tocsin.ini"
  done
}

apt_restart_services() {
  if systemctl list-unit-files | awk '{print $1}' | grep -q "^php${PHP_SERIES}-fpm.service$"; then
    systemctl enable --now "php${PHP_SERIES}-fpm" || true
    systemctl restart "php${PHP_SERIES}-fpm" || true
  fi
  systemctl restart "$APACHE_SERVICE" || true
}

# -----------------------------
# DNF-based install (RHEL/Alma/Rocky/AMZ)
# -----------------------------
setup_dnf_repos() {
  dnf -y install dnf-plugins-core ca-certificates curl
  if [[ "$OS_ID" == "amzn" ]]; then
    dnf -y module reset php || true
  else
    if ! rpm -q epel-release >/dev/null 2>&1; then dnf -y install epel-release; fi
    dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm"
    dnf -y module reset php || true
  fi
}

dnf_enable_php_stream() {
  local stream=""
  if [[ -n "${PHP_SERIES:-}" ]]; then
    if [[ "$OS_ID" == "amzn" ]]; then
      stream="$PHP_SERIES"
    else
      stream="remi-${PHP_SERIES}"
    fi
  fi
  if [[ "$OS_ID" == "amzn" ]]; then
    [[ -n "$stream" ]] || { err "Specify --version for Amazon Linux (e.g., --version 8.3)"; exit 1; }
    dnf -y module enable php:"$stream"
  else
    dnf -y module enable php:"$stream"
  fi
}

dnf_install_php() {
  # On RHEL family, we standardize on FPM behind Apache
  if [[ "$WANT_MODE" == "auto" ]]; then WANT_MODE="fpm"; fi
  local pkgs=( php-cli php-common )
  [[ "$WANT_MODE" == "fpm" ]] && pkgs+=( php-fpm )
  for e in "${INSTALL_EXTS[@]}"; do pkgs+=( "php-${e}" ); done
  dnf -y install "${pkgs[@]}"
  if systemctl is-enabled "$APACHE_SERVICE" >/dev/null 2>&1; then
    systemctl enable --now php-fpm || true
    # Ensure Apache is wired for FPM
    if [[ -d /etc/httpd/conf.modules.d ]]; then
      cat >/etc/httpd/conf.d/php-fpm-tocsin.conf <<'EOC'
# Managed by update-php.sh
<IfModule proxy_fcgi_module>
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost/"
    </FilesMatch>
</IfModule>
EOC
    fi
    systemctl restart "$APACHE_SERVICE" || true
  fi
}

dnf_write_ini() {
  # RHEL family: one tree under /etc/php.d for CLI & Apache SAPI; FPM has /etc/php-fpm.d
  printf "%s\n" "$TOCSIN_INI_BODY" > /etc/php.d/99-tocsin.ini
  if [[ -d /etc/php-fpm.d ]]; then
    # nothing to write there; php.ini is shared under /etc
    :
  fi
}

dnf_restart_services() {
  systemctl enable --now php-fpm || true
  systemctl restart php-fpm || true
  systemctl restart "$APACHE_SERVICE" || true
}

# -----------------------------
# Verification
# -----------------------------
verify_effective_ini() {
  log "PHP binary: $(command -v php || echo 'not found')"
  php -v || true
  log "Loaded INI (CLI):"
  php -i | awk -F'=> ' '/^Loaded Configuration File/ {print $2} /^Scan this dir for additional .ini files/ {print $2} /^Additional .ini files parsed/ {print $0}'
  if [[ "$APACHE_SERVICE" == "apache2" ]]; then
    log "Apache PHP SAPI check (modules/confs):"
    ls -1 /etc/apache2/mods-enabled/php*.load 2>/dev/null || true
    ls -1 /etc/apache2/conf-enabled/php*-fpm.conf 2>/dev/null || true
  else
    log "httpd conf.d grep (FPM wiring):"
    grep -Hn "proxy:unix:/run/php" /etc/httpd/conf.d/*.conf 2>/dev/null || true
  fi
}

# -----------------------------
# Main
# -----------------------------
need_root
detect_os
resolve_target_version

if [[ "$PM" == "apt" ]]; then
  setup_apt_repos
  apt_install_php
  apt_switch_apache_php_sapi
  apt_update_alternatives_cli
  apt_write_ini_and_prune
  apt_restart_services
elif [[ "$PM" == "dnf" ]]; then
  setup_dnf_repos
  dnf_enable_php_stream
  dnf_install_php
  dnf_write_ini
  dnf_restart_services
else
  err "Unsupported package manager"; exit 1
fi

verify_effective_ini
log "Done. All sites now use PHP ${PHP_SERIES} via $( [[ "$WANT_MODE" == "modphp" ]] && echo mod_php || echo php-fpm )."
