#!/bin/bash
# file install.sh
# Initial setup for LAMP + repo deploy (variables-only config.sh)

set -e

# Figure out script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers
if [[ ! -f "$SCRIPT_DIR/functions.sh" ]]; then
  echo "ERROR: functions.sh not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/functions.sh"

# Source config (variables only)
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
  echo "ERROR: config.sh not found in $SCRIPT_DIR"
  exit 1
fi
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
if __is_null_or_empty "$SNOOPY_WEB_ROOT_DIR"; then
  case "$SNOOPY_WEB_ROOT_MODE" in
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
# (do not verify LOG_FILE; it's generated above)
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
if parse_bool "$GITHUB_REPO_PUBLIC"; then
  verify_optional GITHUB_ACCESS_TOKEN
else
  verify GITHUB_ACCESS_TOKEN
fi

# PHP requirement (only if enabled)
require_when INSTALL_PHP PHP_VERSION "Specify which PHP to install (e.g., 8.2)"

# --- Basics & upgrades ---
maybe_install_basics
apt_update_upgrade

# --- Apache & PHP ---
install_apache
if parse_bool "$INSTALL_PHP"; then
  install_php_stack
else
  echo "INSTALL_PHP is disabled; skipping PHP."
fi

# --- Web root + vhost ---
describe_web_root
ensure_web_root
create_apache_vhost

# --- Repo: clone/update then deploy to web root ---
clone_or_update_repo
rsync -a --delete --exclude='.git' "$GITHUB_CLONE_DIR"/ "$SNOOPY_WEB_ROOT_DIR"/
chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$SNOOPY_WEB_ROOT_DIR"

# --- Reboot handling LAST so deploy isn't interrupted ---
handle_reboot_and_notify

echo "=== First Install Done: $(date) ==="
