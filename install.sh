#!/bin/bash
# project: Snoopy/Peanut
# file: install.sh
# date: 2025-09-16
# description: One-shot, idempotent LAMP bootstrap + repo deploy driven by config.sh
# note: Requires functions.sh + config.sh in the same directory.

set -euo pipefail

# Figure out script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers
if [[ ! -f "$SCRIPT_DIR/functions.sh" ]]; then
  echo "ERROR: functions.sh not found in $SCRIPT_DIR" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/functions.sh"

# Source config (variables only)
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
  echo "ERROR: config.sh not found in $SCRIPT_DIR" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

check_root   # die if not root

# --- Start logging ASAP (with safe fallback if LOG_DIR unset) ---
if [[ -z "${LOG_DIR:-}" || "$LOG_DIR" == "NULL" ]]; then
  LOG_DIR="/var/log/snoopy"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/first-install-$(date +'%Y-%m-%d_%H-%M-%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== First Install Started: $(date) ==="
echo "Host: $(hostname) | User: $(whoami)"

# ---- Derive SNOOPY_WEB_ROOT_DIR here (config has no logic) ----
if __is_null_or_empty "${SNOOPY_WEB_ROOT_DIR:-}"; then
  case "${SNOOPY_WEB_ROOT_MODE:-}" in
    home)         SNOOPY_WEB_ROOT_DIR="$SNOOPY_HOME" ;;
    public_html)  SNOOPY_WEB_ROOT_DIR="$SNOOPY_HOME/public_html" ;;
    public)       SNOOPY_WEB_ROOT_DIR="$SNOOPY_HOME/public" ;;
    ""|NULL)      : ;;  # verify() will catch it later
    *)            err "Invalid SNOOPY_WEB_ROOT_MODE: $SNOOPY_WEB_ROOT_MODE"; exit 1 ;;
  esac
fi

# =======================
# REQUIRED (always)
# =======================
verify SNOOPY_HOME_USERNAME
verify SNOOPY_USER
verify SNOOPY_GROUP
verify SNOOPY_HOME
verify SNOOPY_BIN_DIR
verify SNOOPY_SCRIPTS_DIR
verify SNOOPY_TMP_DIR
verify SNOOPY_REPO_URL

verify SNOOPY_WEB_ROOT_MODE
verify SNOOPY_WEB_ROOT_DIR
verify SNOOPY_DOMAIN

verify APACHE_CONF_DIR
verify ADMINER_PASS_FILE_NAME

verify LOG_DIR
verify LOG_LEVEL
verify LOG_RETENTION_DAYS

verify GITHUB_REPO_URL
verify GITHUB_BRANCH
verify GITHUB_CLONE_DIR
# GITHUB_ACCESS_TOKEN handled conditionally below

# =======================
# OPTIONAL (warn-only baseline)
# =======================
verify_optional SNOOPY_SSH_DIR
verify_optional SNOOPY_SSH_KEY
verify_optional SNOOPY_SSH_PUB_KEY
verify_optional SNOOPY_SSH_AUTH_KEYS

verify_optional SEND_EMAIL
verify_optional SEND_SLACK
verify_optional ADMINER_INSTALL
verify_optional GITHUB_REPO_PUBLIC
verify_optional INSTALL_PHP
verify_optional PHP_VERSION
verify_optional PHP_EXTRA_MODULES
verify_optional INSTALL_MYSQL_CLIENT

# =======================
# CONDITIONAL REQUIREMENTS
# =======================
require_when SEND_EMAIL EMAIL_TO   "Email enabled requires recipient"
require_when SEND_EMAIL EMAIL_SUBJECT
require_when SEND_EMAIL EMAIL_BODY

require_when SEND_SLACK SLACK_WEBHOOK_URL "Slack enabled requires webhook"
require_when SEND_SLACK SLACK_MESSAGE

require_when ADMINER_INSTALL ADMINER_DIR
require_when ADMINER_INSTALL ADMINER_URL
require_when ADMINER_INSTALL ADMINER_USER
require_when ADMINER_INSTALL ADMINER_PASS
require_when ADMINER_INSTALL ADMINER_DB
require_when ADMINER_INSTALL ADMINER_PORT
require_when ADMINER_INSTALL ADMINER_HTACCESS
require_when ADMINER_INSTALL ADMINER_INSTALL_PATH
require_when ADMINER_INSTALL ADMINER_HTPASSWD_PASSWORD
require_when ADMINER_INSTALL ADMINER_HTPASSWD_USER

# GitHub token requirement: private repo => token required
if parse_bool "${GITHUB_REPO_PUBLIC:-false}"; then
  verify_optional GITHUB_ACCESS_TOKEN
else
  verify GITHUB_ACCESS_TOKEN
fi

# PHP requirement (only if enabled)
if parse_bool "${INSTALL_PHP:-true}"; then
  verify PHP_VERSION "Specify which PHP to install (e.g., 8.2)"
fi

# --- Basics & upgrades (curl, git, rsync, unzip, etc.) ---
echo "Ensuring base tools are present..."
maybe_install_basics

echo "Refreshing apt metadata & upgrading packages (idempotent)..."
apt_update_upgrade

# --- Ensure UNIX home + skeleton (idempotent) ---
echo "Ensuring home directory exists: $SNOOPY_HOME"
if [[ ! -d "$SNOOPY_HOME" ]]; then
  mkdir -p "$SNOOPY_HOME"
fi
chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$SNOOPY_HOME"

# --- Apache (install if missing) ---
if ! command -v apache2ctl >/dev/null 2>&1 && ! systemctl is-enabled apache2 >/dev/null 2>&1; then
  echo "Apache not found; installing..."
  install_apache
else
  echo "Apache already present; enabling rewrite and ensuring service is active..."
  a2enmod rewrite >/dev/null 2>&1 || true
  systemctl enable --now apache2
fi

# --- PHP (install if missing) ---
if parse_bool "${INSTALL_PHP:-true}"; then
  if ! command -v "php$PHP_VERSION" >/dev/null 2>&1; then
    echo "PHP $PHP_VERSION not found; installing..."
    install_php_stack
  else
    echo "PHP $(php -r 'echo PHP_VERSION;') already present; ensuring common modules..."
    # Try to ensure common modules exist (best-effort)
    DEBIAN_FRONTEND=noninteractive apt -y install "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
      "php${PHP_VERSION}-zip" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mysql" || true
    systemctl reload apache2 || true
  fi
else
  echo "INSTALL_PHP is disabled; skipping PHP."
fi

# --- MySQL client (for remote RDS; install if missing and enabled) ---
if parse_bool "${INSTALL_MYSQL_CLIENT:-true}"; then
  if ! command -v mysql >/dev/null 2>&1; then
    echo "MySQL client not found; installing mariadb-client..."
    DEBIAN_FRONTEND=noninteractive apt -y install mariadb-client || \
    DEBIAN_FRONTEND=noninteractive apt -y install default-mysql-client || true
  else
    echo "MySQL client already present."
  fi
fi

# --- Mail (install if missing) ---
if parse_bool "${SEND_EMAIL:-false}"; then
  if ! command -v mail >/dev/null 2>&1; then
    echo "mail(1) not found; installing mailutils..."
    DEBIAN_FRONTEND=noninteractive apt -y install mailutils || true
  else
    echo "mail(1) already present."
  fi
fi

# --- Web root + vhost (create if missing) ---
describe_web_root
ensure_web_root

VHOST_FILE="$APACHE_CONF_DIR/${SNOOPY_DOMAIN}.conf"
if [[ -f "$VHOST_FILE" ]]; then
  echo "Apache vhost already exists: $VHOST_FILE"
  systemctl reload apache2 || true
else
  echo "Creating Apache vhost for ${SNOOPY_DOMAIN}..."
  create_apache_vhost
fi

# --- Repo: clone/update then deploy to web root ---
clone_or_update_repo
echo "Deploying repo files to web root..."
rsync -a --delete --exclude='.git' "$GITHUB_CLONE_DIR"/ "$SNOOPY_WEB_ROOT_DIR"/
chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$SNOOPY_WEB_ROOT_DIR"

# --- Reboot handling LAST so deploy isn't interrupted ---
handle_reboot_and_notify

echo "=== First Install Done: $(date) ==="
