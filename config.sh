#!/bin/bash
# file config.sh
# Configuration file for all snoopy scripts

# Do NOT set -e here. This file is sourced.

# Prevent multiple sourcing
if [[ -n "${CONFIG_SH_INCLUDED}" ]]; then
  return
fi
CONFIG_SH_INCLUDED=1

# === GENERAL SETTINGS ===
SNOOPY_HOME_USERNAME=NULL # "snoopy"      # System user to run the scripts
SNOOPY_USER=NULL # "www-data"      # User to run the scripts
SNOOPY_GROUP=NULL # "www-data"     # Group for the user
SNOOPY_HOME=NULL # "/home/snoopy" # Home directory for the user $SNOOPY_HOME_USERNAME
SNOOPY_SSH_DIR=NULL # "$SNOOPY_HOME/.ssh"
SNOOPY_SSH_KEY=NULL # "$SNOOPY_SSH_DIR/id_rsa"
SNOOPY_SSH_PUB_KEY=NULL # "$SNOOPY_SSH_KEY.pub"
SNOOPY_SSH_AUTH_KEYS=NULL # "$SNOOPY_SSH_DIR/authorized_keys"
SNOOPY_BIN_DIR=NULL # "/usr/local/bin"
SNOOPY_SCRIPTS_DIR=NULL # "$SNOOPY_HOME/scripts"
SNOOPY_TMP_DIR=NULL # "/tmp/snoopy"
SNOOPY_REPO_URL=NULL # "
# === WEB ROOT SETTINGS ===
# One of: home | public_html | public
SNOOPY_WEB_ROOT_MODE=NULL   # "public_html"
SNOOPY_WEB_ROOT_DIR=NULL    # "/home/${SNOOPY_HOME_USERNAME}/public_html"
SNOOPY_DOMAIN=NULL          # "example.com"


# == AWS RDS SETTINGS ===
AWS_RDS_INSTANCE_ID=NULL # "your-rds-instance-id"
AWS_REGION=NULL # "us-east-1"
AWS_ACCESS_KEY_ID=NULL # "your-access-key-id"
AWS_SECRET_ACCESS_KEY=NULL # "your-secret-access-key"
AWS_DB_USER=NULL # "your-db-username"
AWS_DB_NAME=NULL # "your-db-name"
AWS_DB_PORT=NULL # 3306         # Default MySQL port        
AWS_RDS_SECURITY_GROUP_ID=NULL # "your-security-group-id"

# === EC2 SETTINGS ===
EC2_INSTANCE_ID=NULL # "your-ec2-instance-id"
EC2_REGION=NULL # "us-east-1"
EC2_ACCESS_KEY_ID=NULL
EC2_SECRET_ACCESS_KEY=NULL
EC2_SECURITY_GROUP_ID=NULL # "your-security-group-id"
EC2_TAG_KEY=NULL # "Name"
EC2_TAG_VALUE=NULL # "your-ec2-instance-name"
EC2_SSH_USER=NULL # "ubuntu"     # Default user for Ubuntu AMIs
EC2_SSH_KEY_PATH=NULL # "/path/to/your/private/key.pem"
EC2_SSH_PORT=NULL # 22           # Default SSH port


# === Apache2 Config ===
APACHE_CONF_DIR=NULL # "/etc/apache2/sites-available"
ADMINER_PASS_FILE_NAME=NULL # ".htpasswd-adminer"

# === EMAIL SETTINGS ===
SEND_EMAIL=NULL # true          # Set to true to enable email notification
EMAIL_TO=NULL # "admin@example.com"
EMAIL_SUBJECT=NULL # "Ubuntu Reboot Notification"
EMAIL_BODY=NULL # "System rebooting after kernel update on $(hostname) at $(date)."

# === SLACK SETTINGS ===
SEND_SLACK=NULL # true          # Set to true to enable Slack notification
SLACK_WEBHOOK_URL=NULL # "https://hooks.slack.com/services/your/webhook/url"
SLACK_MESSAGE=NULL #"⚠️ *$(hostname)* will reboot in 1 minute due to a kernel update. $(date)"

# === LOG SETTINGS ===
LOG_DIR=NULL # "/var/log/snoopy"
LOG_FILE=NULL #"$LOG_DIR/snoopy.log"
LOG_LEVEL=NULL # "INFO"        # Options: DEBUG, INFO, WARNING, ERROR
LOG_RETENTION_DAYS=NULL # 30            # Number of days to retain logs

# === GITHUB SETTINGS ===
GITHUB_REPO_URL=NULL # "
GITHUB_BRANCH=NULL # "main"       # Branch to pull from
GITHUB_CLONE_DIR=NULL # "$SNOOPY_HOME/snoopy-scripts"
GITHUB_REPO_PUBLIC=NULL # true         # Set to true if the repo is public, false if private
GITHUB_ACCESS_TOKEN=NULL # "your_github_access_token"  # Required if the repo is private


# === ADMINER SETTINGS ===
ADMINER_INSTALL=NULL # true         # Set to true to enable Adminer installation
ADMINER_DIR=NULL # "/var/www/html/adminer"
ADMINER_URL=NULL # "https://www.adminer.org/latest.php"
ADMINER_USER=NULL # "adminer"
ADMINER_PASS=NULL # "securepassword"  # Change this to a strong password        
ADMINER_DB=NULL # "mysql"        # Default database type (e.g., mysql, pgsql)
ADMINER_PORT=NULL # 8080          # Port for accessing Adminer
ADMINER_HTACCESS=NULL # true         # Set to true to enable .htaccess protection
ADMINER_INSTALL_PATH=NULL # "/home/snoopy/public_html/adminer/index.php"  # Path where Adminer will be installed
ADMINER_HTPASSWD_PASSWORD=NULL # "abc123"      # Password for .htaccess authentication
ADMINER_HTPASSWD_USER=NULL # "adminer_user"    # Username for .htaccess authentication (change if needed)


# === WEB ROOT SETTINGS ===
# One of: home | public_html | public
SNOOPY_WEB_ROOT_MODE=NULL   # "public_html"
SNOOPY_WEB_ROOT_DIR=NULL    # "/home/${SNOOPY_HOME_USERNAME}/public_html"
SNOOPY_DOMAIN=NULL          # "example.com"

# === PHP SETTINGS ===
INSTALL_PHP=NULL        # true/false
PHP_VERSION=NULL        # "8.2"
PHP_EXTRA_MODULES=NULL  # "bcmath intl ldap redis"
