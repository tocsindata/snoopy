#!/usr/bin/env bash
# file: domain-remove.sh
# Reverse of setup.sh: remove a domain's vhost and (optionally) the related system user & home.
# Assumes Debian/Ubuntu Apache layout (apache2ctl, a2ensite/a2dissite).
# DocumentRoot (from setup): /home/<sanitized-username>/public_html

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# --- Get domain
DOMAIN="${1:-}"
if [[ -z "${DOMAIN}" ]]; then
  read -rp "Enter the FQDN to remove (e.g., snoopy.example.com): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"

# Lenient FQDN check
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*\.)+[a-z]{2,}$ ]]; then
  echo "Invalid domain: '$DOMAIN'. Example: snoopy.example.com" >&2
  exit 1
fi

# --- Same sanitizer as setup.sh (dots not allowed in many username policies)
sanitize_username() {
  local s="${1,,}"
  s="${s//[^a-z0-9._-]/_}"  # map any weird chars to _
  s="${s//./_}"             # map dots to underscores
  s="$(echo -n "$s" | tr -s '_')"   # collapse multiple underscores
  echo "${s:0:32}"                  # keep it portable
}

USER_NAME="$(sanitize_username "$DOMAIN")"
HOME_DIR="/home/${USER_NAME}"
WEB_ROOT="${HOME_DIR}/public_html"
VHOST_CONF="/etc/apache2/sites-available/${DOMAIN}.conf"
SITE_LINK="/etc/apache2/sites-enabled/${DOMAIN}.conf"
PASS_FILE="/root/${USER_NAME}-password.txt"
BACKUP_DIR="/root/vhost-backups"
LOG_GLOB="/var/log/apache2/${DOMAIN}_*.log"

echo
echo "Domain       : ${DOMAIN}"
echo "User (sanit.): ${USER_NAME}"
echo "Home         : ${HOME_DIR}"
echo "DocumentRoot : ${WEB_ROOT}"
echo "VHost file   : ${VHOST_CONF}"
echo "Sites-enabled: ${SITE_LINK}"
echo

# --- Require Apache tooling
if ! command -v apache2ctl >/dev/null 2>&1; then
  echo "apache2ctl not found. This script targets Debian/Ubuntu Apache2." >&2
  exit 1
fi

# --- Confirm vhost removal
read -rp "Disable and remove Apache vhost for ${DOMAIN}? [y/N]: " CONF_VHOST
CONF_VHOST="${CONF_VHOST,,}"
if [[ "$CONF_VHOST" == "y" || "$CONF_VHOST" == "yes" ]]; then
  # Disable site if it looks enabled (ignore errors)
  if [[ -L "$SITE_LINK" || -f "$SITE_LINK" ]]; then
    echo "Disabling site ${DOMAIN}..."
    a2dissite "${DOMAIN}.conf" >/dev/null || true
  else
    echo "Site ${DOMAIN} does not appear enabled (no ${SITE_LINK})."
  fi

  # Backup and remove vhost file if present
  if [[ -f "$VHOST_CONF" ]]; then
    echo "Backing up vhost to ${BACKUP_DIR} and removing..."
    mkdir -p "$BACKUP_DIR"
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$VHOST_CONF" "${BACKUP_DIR}/${DOMAIN}.conf.${ts}"
    rm -f -- "$VHOST_CONF"
    echo "Backed up to: ${BACKUP_DIR}/${DOMAIN}.conf.${ts}"
  else
    echo "No vhost file at ${VHOST_CONF}; skipping removal."
  fi

  echo "apache2ctl configtest..."
  apache2ctl configtest

  echo "Reloading Apache..."
  systemctl reload apache2
else
  echo "Skipping vhost removal."
fi

# --- Ask about deleting the system user + home (DANGEROUS)
echo
echo "User account options for '${USER_NAME}':"
echo "  Home dir: ${HOME_DIR}"
echo "  This will remove the user, their home, and web root if you confirm."
read -rp "Delete system user '${USER_NAME}' and their home directory? [y/N]: " CONF_USER
CONF_USER="${CONF_USER,,}"
if [[ "$CONF_USER" == "y" || "$CONF_USER" == "yes" ]]; then
  # Sanity checks before deletion
  if [[ -z "$USER_NAME" || "$USER_NAME" == "root" || "$HOME_DIR" != "/home/${USER_NAME}" ]]; then
    echo "Refusing to delete: sanity check failed (username/home mismatch)." >&2
    exit 1
  fi
  if id "$USER_NAME" >/dev/null 2>&1; then
    echo "Deleting user '${USER_NAME}' and home..."
    # userdel -r removes home directory and mail spool
    # If user has running processes, this may fail; handle gracefully.
    if ! userdel -r "$USER_NAME"; then
      echo "userdel reported an error (user may have running processes)."
      echo "Try: pkill -u '$USER_NAME' and re-run, or remove ${HOME_DIR} manually."
      exit 1
    fi
  else
    echo "User '${USER_NAME}' does not exist; skipping userdel."
    # If home still exists, remove it cautiously
    if [[ -d "$HOME_DIR" ]]; then
      echo "Home directory still exists; removing: ${HOME_DIR}"
      rm -rf -- "${HOME_DIR}"
    fi
  fi
else
  echo "Keeping system user and home."
fi

# --- Remove saved password file, if any
if [[ -f "$PASS_FILE" ]]; then
  read -rp "Remove saved password file ${PASS_FILE}? [y/N]: " CONF_PASS
  CONF_PASS="${CONF_PASS,,}"
  if [[ "$CONF_PASS" == "y" || "$CONF_PASS" == "yes" ]]; then
    rm -f -- "$PASS_FILE"
    echo "Removed ${PASS_FILE}"
  else
    echo "Keeping ${PASS_FILE}"
  fi
fi

# --- Optionally remove Apache logs for this domain
shopt -s nullglob
LOGS=( $LOG_GLOB )
if (( ${#LOGS[@]} )); then
  echo
  echo "Found Apache logs for ${DOMAIN}:"
  for f in "${LOGS[@]}"; do echo "  - $f"; done
  read -rp "Delete these log files? [y/N]: " CONF_LOGS
  CONF_LOGS="${CONF_LOGS,,}"
  if [[ "$CONF_LOGS" == "y" || "$CONF_LOGS" == "yes" ]]; then
    rm -f -- "${LOGS[@]}"
    echo "Deleted logs."
  else
    echo "Keeping logs."
  fi
fi
shopt -u nullglob

echo
echo "✅ Removal workflow completed."
echo "Summary:"
echo " - Domain: ${DOMAIN}"
echo " - User:   ${USER_NAME}"
echo " - VHost:  ${VHOST_CONF} (removed if confirmed)"
echo " - Site:   ${DOMAIN}.conf (disabled if confirmed)"
echo " - Home:   ${HOME_DIR} (removed only if confirmed)"
