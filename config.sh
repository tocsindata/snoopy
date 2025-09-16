#!/bin/bash
# file: config.sh
# Configuration file for all snoopy scripts
# NOTE: Do NOT `set -e` here. This file is sourced.

# Prevent multiple sourcing
if [[ -n "${CONFIG_SH_INCLUDED}" ]]; then
  return
fi
CONFIG_SH_INCLUDED=1

# ======================
# GENERAL SETTINGS
# ======================
SNOOPY_HOME_USERNAME=NULL    # e.g., "ubuntu" (Linux account that owns deployment)
SNOOPY_USER=NULL             # e.g., "ubuntu" (owner user for files)
SNOOPY_GROUP=NULL            # e.g., "www-data" (group for web files)
SNOOPY_HOME=NULL             # e.g., "/home/ubuntu"

SNOOPY_BIN_DIR=NULL          # e.g., "$SNOOPY_HOME/bin"
SNOOPY_SCRIPTS_DIR=NULL      # e.g., "$SNOOPY_HOME/snoopy"
SNOOPY_TMP_DIR=NULL          # e.g., "$SNOOPY_HOME/tmp"
SNOOPY_REPO_URL=NULL         # (legacy/optional; not used by install.sh for cloning)

# Optional SSH conveniences (warn-only)
SNOOPY_SSH_DIR=NULL          # e.g., "$SNOOPY_HOME/.ssh"
SNOOPY_SSH_KEY=NULL          # e.g., "$SNOOPY_SSH_DIR/id_rsa"
SNOOPY_SSH_PUB_KEY=NULL      # e.g., "$SNOOPY_SSH_KEY.pub"
SNOOPY_SSH_AUTH_KEYS=NULL    # e.g., "$SNOOPY_SSH_DIR/authorized_keys"

# ======================
# WEB ROOT / VHOST
# ======================
# One of: home | public_html | public
SNOOPY_WEB_ROOT_MODE=NULL          # e.g., "public_html"
SNOOPY_WEB_ROOT_DIR=NULL           # e.g., "$SNOOPY_HOME/public_html" (derived if NULL and MODE set)
SNOOPY_DOMAIN=NULL                 # e.g., "example.com"
APACHE_CONF_DIR=NULL               # e.g., "/etc/apache2/sites-available"
ADMINER_PASS_FILE_NAME=NULL        # e.g., ".adminer.pass" (kept for parity with your env)

# ======================
# LOGGING
# ======================
LOG_DIR=NULL                       # e.g., "/var/log/snoopy"
LOG_LEVEL=NULL                     # e.g., "info"
LOG_RETENTION_DAYS=NULL            # e.g., "7"
# Optional (not used by install.sh)
LOG_FILE=NULL                      # e.g., "$LOG_DIR/snoopy.log"

# ======================
# GIT / REPO DEPLOY
# ======================
GITHUB_REPO_URL=NULL               # e.g., "https://github.com/your/repo.git"
GITHUB_BRANCH=NULL                 # e.g., "main"
GITHUB_CLONE_DIR=NULL              # e.g., "$SNOOPY_HOME/repo"
GITHUB_REPO_PUBLIC=NULL            # "true" or "false"
GITHUB_ACCESS_TOKEN=NULL           # required if repo is private

# ======================
# PHP / LAMP TOGGLES
# ======================
INSTALL_PHP=NULL                   # "true" or "false"
PHP_VERSION=NULL                   # e.g., "8.2"
PHP_EXTRA_MODULES=NULL             # optional space-separated list e.g., "imagick intl"

# Install a MySQL client (for remote RDS usage)
INSTALL_MYSQL_CLIENT=NULL          # "true" or "false"

# ======================
# EMAIL (optional)
# ======================
SEND_EMAIL=NULL                    # "true" or "false"
EMAIL_TO=NULL                      # e.g., "admin@example.com"
EMAIL_SUBJECT=NULL                 # e.g., "Reboot required"
EMAIL_BODY=NULL                    # e.g., "System reboot required on $(hostname) at $(date)."

# ======================
# SLACK (optional)
# ======================
SEND_SLACK=NULL                    # "true" or "false"
SLACK_WEBHOOK_URL=NULL             # e.g., "https://hooks.slack.com/services/XXX/YYY/ZZZ"
SLACK_MESSAGE=NULL                 # e.g., "$(hostname) will reboot to apply updates at $(date)"

# ======================
# ADMINER (optional)
# ======================
ADMINER_INSTALL=NULL               # "true" or "false"
ADMINER_DIR=NULL                   # e.g., "$SNOOPY_HOME/adminer"
ADMINER_URL=NULL                   # e.g., "https://www.adminer.org/latest.php"
ADMINER_USER=NULL                  # e.g., "dbuser"
ADMINER_PASS=NULL                  # e.g., "strongpassword"
ADMINER_DB=NULL                    # e.g., "mysql"
ADMINER_PORT=NULL                  # e.g., "8080"
ADMINER_HTACCESS=NULL              # path to .htaccess (or "true"/"false" in your prior model)
ADMINER_INSTALL_PATH=NULL          # e.g., "$SNOOPY_HOME/public_html/adminer/index.php"
ADMINER_HTPASSWD_USER=NULL         # e.g., "adminer_user"
ADMINER_HTPASSWD_PASSWORD=NULL     # e.g., "change-me"

# ======================
# AWS RDS (optional; not used by install.sh directly)
# ======================
AWS_RDS_INSTANCE_ID=NULL
AWS_REGION=NULL
AWS_ACCESS_KEY_ID=NULL
AWS_SECRET_ACCESS_KEY=NULL
AWS_DB_USER=NULL
AWS_DB_NAME=NULL
AWS_DB_PORT=NULL                   # e.g., 3306
AWS_RDS_SECURITY_GROUP_ID=NULL

# ======================
# EC2 (optional; not used by install.sh directly)
# ======================
EC2_INSTANCE_ID=NULL
EC2_REGION=NULL
EC2_ACCESS_KEY_ID=NULL
EC2_SECRET_ACCESS_KEY=NULL
EC2_SECURITY_GROUP_ID=NULL
EC2_TAG_KEY=NULL
EC2_TAG_VALUE=NULL
EC2_SSH_USER=NULL                  # e.g., "ubuntu"
EC2_SSH_KEY_PATH=NULL              # e.g., "/path/to/key.pem"
EC2_SSH_PORT=NULL                  # e.g., 22
