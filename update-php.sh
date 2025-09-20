#!/usr/bin/env bash   
# file: update-php.sh
# date: 2025-09-20
# copyright: Daniel Foscarini (www.tocsindata.com) info@tocsindata.com


set -euo pipefail

# =========================================
# Config (can override via CLI flags)
# =========================================
TARGET_VERSION=""     # e.g., "8.3" or "8.3.12"; empty = auto-latest stable
SKIP_DOT_ZERO=1       # skip X.Y.0 minors (require at least .1)
APACHE_SERVICE="apache2"   # "apache2" on Debian/Ubuntu, "httpd" on RHEL/Alma/Rocky/AMZ
INSTALL_EXTS=(curl mbstring intl xml zip gd mysql ldap opcache bcmath readline)

usage() {
  cat <<EOF
Usage: $0 [--version 8.3|8.3.12] [--allow-dot-zero] [--fpm] [--mod-php] [--apache-service apache2|httpd]

Examples:
  $0                   # auto-detect latest stable from php.net (skip X.Y.0)
  $0 --version 8.3     # install latest 8.3.x
  $0 --version 8.4.5   # install exactly 8.4.5 if available
  $0 --fpm             # install php-fpm + keep Apache; no libapache2-mod-php
  $0 --mod-php         # install mod_php (Ubuntu/Debian)
EOF
}

WANT_MODE="auto"  # auto | fpm | modphp
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

have(){ command -v "$1" >/dev/null 2>&1; }
log(){  printf '%s %s\n' "[$(date +'%F %T')]" "$*"; }
warn(){ printf '%s %s\n' "[$(date +'%F %T')] [WARN]" "$*" >&2; }
err(){  printf '%s %s\n' "[$(date +'%F %T')] [ERROR]" "$*" >&2; }

need_root() { [[ $EUID -eq 0 ]] || { err "Run as root"; exit 1; }; }

# -----------------------------
# Detect distro
# -----------------------------
detect_os() {
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VER="${VERSION_ID:-}"
  case "$OS_ID" in
    ubuntu|debian) PM="apt";;
    amzn) PM="dnf"; APACHE_SERVICE="httpd";;
    rhel|rocky|almalinux|centos) PM="dnf"; APACHE_SERVICE="httpd";;
    *) if have apt; then PM="apt"; elif have dnf; then PM="dnf"; else err "Unsupported OS"; exit 1; fi;;
  esac
  log "Detected OS=$OS_ID $OS_VER (like: $OS_LIKE), PM=$PM, Apache=$APACHE_SERVICE"
}

# -----------------------------
# Figure out target PHP version
# -----------------------------
normalize_version() {
  # Input might be "8.3" or "8.3.12"; return "8.3" base + optional patch
  local v="$1"; v="${v#php-}"; echo "$v"
}

get_latest_php_from_phpnet() {
  # Query php.net releases JSON and pick latest stable (skip .0 if configured)
  local url="https://www.php.net/releases/index.php?json&version=8"
  have curl || { warn "curl not found; cannot auto-detect latest PHP. Provide --version."; echo ""; return; }
  local json; json="$(curl -fsSL "$url" || true)"
  [[ -z "$json" ]] && { warn "Failed to fetch php.net releases JSON"; echo ""; return; }

  # Extract all X.Y.Z keys; choose highest (lexicographically sorted as versions)
  # We avoid .0 if SKIP_DOT_ZERO=1.
  local list
  list="$(echo "$json" | grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"' | sort -V)"
  [[ -z "$list" ]] && { warn "No versions parsed from php.net JSON"; echo ""; return; }

  local latest=""
  while read -r v; do latest="$v"; done <<<"$(echo "$list" | tail -n +1)"  # last line is highest
  if (( SKIP_DOT_ZERO == 1 )); then
    # if highest is x.y.0, step down to next that >= .1
    local last_line; last_line="$latest"
    if [[ "$last_line" =~ ^([0-9]+)\.([0-9]+)\.0$ ]]; then
      # find highest with .>=1
      latest="$(echo "$list" | grep -E '^[0-9]+\.[0-9]+\.([1-9][0-9]*)$' | tail -n 1)"
      [[ -z "$latest" ]] && latest="$last_line"
    fi
  fi
  echo "$latest"
}

resolve_target_version() {
  if [[ -n "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(normalize_version "$TARGET_VERSION")"
    if [[ "$TARGET_VERSION" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      TARGET_MAJOR="${BASH_REMATCH[1]}"; TARGET_MINOR="${BASH_REMATCH[2]}"
      TARGET_PATCH=""  # will take distro latest of that minor
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
  # Debian gets Sury; Ubuntu gets Ondřej PPA
  if [[ "$OS_ID" == "debian" ]]; then
    if ! grep -q "packages.sury.org/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury.gpg
      echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
    fi
  else
    add-apt-repository -y ppa:ondrej/php
  fi
  apt-get update -y
}

apt_install_php() {
  local base="php${PHP_SERIES}"
  local pkgs=( "php${PHP_SERIES}-cli" "php${PHP_SERIES}-common" )
  if [[ "$WANT_MODE" == "modphp" || "$WANT_MODE" == "auto" ]]; then
    pkgs+=( "libapache2-mod-php${PHP_SERIES}" )
  fi
  if [[ "$WANT_MODE" == "fpm" || "$WANT_MODE" == "auto" ]]; then
    pkgs+=( "php${PHP_SERIES}-fpm" )
  fi
  for e in "${INSTALL_EXTS[@]}"; do
    pkgs+=( "php${PHP_SERIES}-${e}" )
  done
  apt-get install -y "${pkgs[@]}"
}

apt_switch_apache_php_module() {
  if [[ "$APACHE_SERVICE" != "apache2" ]]; then return 0; fi
  # Disable any other php modules and enable the target one
  local have_mod="/etc/apache2/mods-available"
  if [[ -d "$have_mod" ]]; then
    local current; current="$(ls /etc/apache2/mods-enabled | grep -E '^php[0-9.]+\.load$' || true)"
    if [[ -n "$current" ]]; then
      current="${current%.load}"
      a2dismod "$current" || true
    fi
    a2enmod "php${PHP_SERIES}" || true
    systemctl restart "$APACHE_SERVICE"
  fi
}

# -----------------------------
# DNF-based install (RHEL/Alma/Rocky/AMZ)
# -----------------------------
setup_dnf_repos() {
  dnf -y install dnf-plugins-core ca-certificates curl
  if [[ "$OS_ID" == "amzn" ]]; then
    # Amazon Linux 2023 uses modules "php:8.x"
    dnf -y module reset php || true
    # Try common modern series in descending order unless pinned
    :
  else
    # RHEL family: enable Remi repo for multiple PHP streams
    if ! rpm -q epel-release >/dev/null 2>&1; then dnf -y install epel-release; fi
    dnf -y install https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
    dnf -y module reset php || true
  fi
}

dnf_enable_php_stream() {
  local stream=""
  if [[ -n "${PHP_SERIES:-}" ]]; then
    # e.g. 8.3 -> "remi-8.3" on RHEL; "8.3" on Amazon
    if [[ "$OS_ID" == "amzn" ]]; then
      stream="$PHP_SERIES"
    else
      stream="remi-${PHP_SERIES}"
    fi
  fi

  if [[ "$OS_ID" == "amzn" ]]; then
    # pick the desired or highest available
    if [[ -n "$stream" ]]; then
      dnf -y module enable php:"$stream"
    else
      dnf -y module list php
      err "Specify --version for Amazon Linux (e.g., --version 8.3)"; exit 1
    fi
  else
    dnf -y module enable php:"$stream"
  fi
}

dnf_install_php() {
  local pkgs=( php-cli php-common )
  if [[ "$WANT_MODE" == "fpm" || "$WANT_MODE" == "auto" ]]; then
    pkgs+=( php-fpm )
  fi
  # RHEL family uses names like php-mbstring, php-intl, etc. (no version suffix)
  for e in "${INSTALL_EXTS[@]}"; do pkgs+=( "php-${e}" ); done
  dnf -y install "${pkgs[@]}"
  # Apache handler on RHEL is via php-fpm + proxy_fcgi (mod_php is uncommon there)
  if systemctl is-enabled "$APACHE_SERVICE" >/dev/null 2>&1; then
    systemctl enable --now php-fpm || true
    systemctl restart "$APACHE_SERVICE" || true
  fi
}

# -----------------------------
# Post-install sanity
# -----------------------------
post_install_summary() {
  log "PHP binary: $(command -v php || echo 'not found')"
  php -v || true
  if systemctl is-active "$APACHE_SERVICE" >/dev/null 2>&1; then
    log "Restarting $APACHE_SERVICE…"
    systemctl restart "$APACHE_SERVICE" || true
  fi
  if systemctl list-unit-files | grep -q '^php.*fpm\.service'; then
    systemctl enable --now "$(systemctl list-unit-files | awk '/^php.*fpm\.service/{print $1; exit}')" || true
    systemctl restart "$(systemctl list-unit-files | awk '/^php.*fpm\.service/{print $1; exit}')" || true
  fi
  log "Done."
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
  if [[ "$WANT_MODE" == "modphp" ]]; then
    apt_switch_apache_php_module
  fi
elif [[ "$PM" == "dnf" ]]; then
  setup_dnf_repos
  dnf_enable_php_stream
  dnf_install_php
else
  err "Unsupported package manager"; exit 1
fi

post_install_summary
