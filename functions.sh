#!/bin/bash
# file: functions.sh
# Common functions for all snoopy scripts

# Prevent multiple sourcing
if [[ -n "${FUNCTIONS_SH_INCLUDED}" ]]; then
  return
fi
FUNCTIONS_SH_INCLUDED=1

# =======================
# Logging
# =======================
err()  { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n'  "$*" >&2; }

# =======================
# Root check
# =======================
error_exit() {
  echo "❌ $1" >&2
  exit 1
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
  fi
}

# =======================
# Small helpers
# =======================
__is_null_or_empty() { [[ -z "$1" || "$1" == "NULL" ]]; }

# Boolean parsing (case-insensitive)
# Returns 0 for true-ish, 1 for false-ish
parse_bool() {
  local v="$1"
  local was_nc=0
  shopt -q nocasematch && was_nc=1
  shopt -s nocasematch

  local out=1
  case "$v" in
    1|true|yes|y|on)     out=0 ;;
    0|false|no|n|off|"") out=1 ;;
    *)                   out=1 ;;
  esac

  # restore previous nocasematch state
  if (( was_nc )); then shopt -s nocasematch; else shopt -u nocasematch; fi
  return $out
}

# Indirect expansion helper
_getval() {
  local name="$1"
  printf '%s' "${!name}"
}

# =======================
# Verifiers
# =======================
# Fatal if unset/empty/"NULL"
verify() {
  local var="$1"
  local val
  val="$(_getval "$var")"
  if [[ -z "$val" || "$val" == "NULL" ]]; then
    err "$var is NOT set in config.sh — please update your config!"
    exit 1
  fi
}

# Warn-only if unset/empty/"NULL"
# IMPORTANT: Always return 0 so 'set -e' in callers won't kill the script.
verify_optional() {
  local var="$1"
  local val
  val="$(_getval "$var")"
  if [[ -z "$val" || "$val" == "NULL" ]]; then
    warn "$var is not set; proceeding with defaults/feature disabled."
  fi
  return 0
}

# Conditionally require a var when a boolean flag is true
# Usage: require_when FLAG_VAR REQUIRED_VAR [reason]
require_when() {
  local flag_var="$1" req_var="$2" reason="${3:-}"
  local flag_val
  flag_val="$(_getval "$flag_var")"

  if parse_bool "$flag_val"; then
    # feature enabled => required
    local val="$(_getval "$req_var")"
    if [[ -z "$val" || "$val" == "NULL" ]]; then
      if [[ -n "$reason" ]]; then
        err "$req_var is required when $flag_var is enabled: $reason"
      else
        err "$req_var is required when $flag_var is enabled."
      fi
      exit 1
    fi
  else
    # feature disabled => warn if someone partially configured it
    verify_optional "$req_var"
  fi
}

# =======================
# Utilities
# =======================
list_domains() {
  verify APACHE_CONF_DIR
  echo "Available Apache Virtual Hosts:"
  for conf in "$APACHE_CONF_DIR"/*.conf; do
    [[ -f "$conf" ]] || continue
    local domain
    domain=$(basename "${conf%.conf}")
    echo "  - $domain"
  done
  exit 0
}

# Ensure web root exists and is owned correctly
ensure_web_root() {
  verify SNOOPY_WEB_ROOT_DIR
  verify SNOOPY_USER
  verify SNOOPY_GROUP

  mkdir -p "$SNOOPY_WEB_ROOT_DIR"
  chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$SNOOPY_WEB_ROOT_DIR"
}

describe_web_root() {
  echo "➡️  Web root mode: $SNOOPY_WEB_ROOT_MODE"
  echo "➡️  Web root dir : $SNOOPY_WEB_ROOT_DIR"
}

create_apache_vhost() {
  verify APACHE_CONF_DIR
  verify SNOOPY_DOMAIN
  verify SNOOPY_WEB_ROOT_DIR

  local site_file="$APACHE_CONF_DIR/${SNOOPY_DOMAIN}.conf"

  cat > "$site_file" <<EOF
<VirtualHost *:80>
    ServerName ${SNOOPY_DOMAIN}
    DocumentRoot ${SNOOPY_WEB_ROOT_DIR}

    <Directory ${SNOOPY_WEB_ROOT_DIR}>
        AllowOverride All
        Require all granted
        Options -Indexes +FollowSymLinks
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${SNOOPY_DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SNOOPY_DOMAIN}-access.log combined
</VirtualHost>
EOF

  a2dissite 000-default.conf >/dev/null 2>&1 || true
  a2ensite "${SNOOPY_DOMAIN}.conf"
  systemctl reload apache2
  echo "✅ Apache vhost enabled for ${SNOOPY_DOMAIN} → ${SNOOPY_WEB_ROOT_DIR}"
}

# =======================
# Package installs / updates
# =======================
maybe_install_basics() {
  # Tools you almost certainly need
  DEBIAN_FRONTEND=noninteractive apt -y install \
    curl git rsync unzip ca-certificates lsb-release software-properties-common
}

apt_update_upgrade() {
  echo "Updating package list..."
  apt update

  echo "Upgrading installed packages..."
  DEBIAN_FRONTEND=noninteractive apt -y upgrade

  echo "Performing distribution upgrade..."
  DEBIAN_FRONTEND=noninteractive apt -y dist-upgrade

  echo "Removing unnecessary packages..."
  apt -y autoremove

  echo "Cleaning up package cache..."
  apt clean
}

install_apache() {
  echo "Installing Apache..."
  DEBIAN_FRONTEND=noninteractive apt -y install apache2
  a2enmod rewrite
  systemctl enable --now apache2
}

install_php_stack() {
  # Requires: PHP_VERSION; optional: PHP_EXTRA_MODULES
  verify PHP_VERSION
  local v="$PHP_VERSION"

  echo "Installing PHP $v..."
  DEBIAN_FRONTEND=noninteractive apt -y install \
    "php$v" "libapache2-mod-php$v" \
    "php$v-cli" "php$v-common" "php$v-mbstring" "php$v-xml" \
    "php$v-zip" "php$v-curl" "php$v-gd" "php$v-mysql" || {
      echo "If this fails on your Ubuntu release, you may need the Ondřej PPA:"
      echo "  add-apt-repository ppa:ondrej/php && apt update"
      exit 1
    }

  # Optional extras (space-separated string)
  if [[ -n "${PHP_EXTRA_MODULES:-}" && "$PHP_EXTRA_MODULES" != "NULL" ]]; then
    local mods=()
    for m in $PHP_EXTRA_MODULES; do
      mods+=("php${v}-${m}")
    done
    if ((${#mods[@]})); then
      DEBIAN_FRONTEND=noninteractive apt -y install "${mods[@]}"
    fi
  fi

  systemctl reload apache2 || true
}

# =======================
# Notifications / Reboot
# =======================

# helper to send a Slack message without fragile line continuations
_slack_post_text() {
  local text="$1"
  curl -s -X POST -H 'Content-type: application/json' \
       --data "{\"text\":\"${text}\"}" \
       "$SLACK_WEBHOOK_URL" >/dev/null
  return $?
}

handle_reboot_and_notify() {
  if [[ -f /var/run/reboot-required ]]; then
    echo "Reboot required (kernel or critical libraries updated)."

    # Email (only if enabled) — no pipe: use heredoc to mail(1)
    if parse_bool "$SEND_EMAIL"; then
      # Ensure mailutils is present (best-effort)
      DEBIAN_FRONTEND=noninteractive apt -y install mailutils >/dev/null 2>&1 || true
      local _subject _to _body
      _subject="${EMAIL_SUBJECT:-Reboot required}"
      _to="${EMAIL_TO:-root}"
      _body="${EMAIL_BODY:-System reboot required on $(hostname) at $(date).}"

      if mail -s "$(_getval _subject)" "$(_getval _to)" <<MAIL_BODY
$(_getval _body)
MAIL_BODY
      then
        echo "Email notification sent to $(_getval _to)"
      else
        echo "⚠️  Failed to send email notification."
      fi
    fi

    # Slack (only if enabled) — no &&/|| chain; check exit code instead
    if parse_bool "$SEND_SLACK"; then
      if [[ -n "${SLACK_WEBHOOK_URL:-}" && "$SLACK_WEBHOOK_URL" != "NULL" ]]; then
        local _msg
        _msg="${SLACK_MESSAGE:-"$(hostname) will reboot to apply updates at $(date)"}"
        if _slack_post_text "$_msg"; then
          echo "Slack notification sent."
        else
          echo "⚠️  Failed to send Slack notification."
        fi
      else
        echo "⚠️  SLACK_WEBHOOK_URL not set; skipping Slack notification."
      fi
    fi

    echo "System will reboot in 1 minute..."
    shutdown -r +1 "Rebooting to apply updates"
  else
    echo "No reboot required."
  fi
}

# =======================
# GitHub clone/update
# =======================
clone_or_update_repo() {
  verify GITHUB_REPO_URL
  verify GITHUB_BRANCH
  verify GITHUB_CLONE_DIR
  verify_optional GITHUB_REPO_PUBLIC  # may be NULL => treated falsey

  mkdir -p "$GITHUB_CLONE_DIR"
  if [[ -d "$GITHUB_CLONE_DIR/.git" ]]; then
    echo "Updating repo in $GITHUB_CLONE_DIR (branch $GITHUB_BRANCH)..."
    git -C "$GITHUB_CLONE_DIR" fetch --all --prune
    git -C "$GITHUB_CLONE_DIR" checkout "$GITHUB_BRANCH"
    git -C "$GITHUB_CLONE_DIR" pull --ff-only origin "$GITHUB_BRANCH"
  else
    local url="$GITHUB_REPO_URL"
    if ! parse_bool "$GITHUB_REPO_PUBLIC"; then
      verify GITHUB_ACCESS_TOKEN
      # inject token into https:// URL but don't echo it
      url="${GITHUB_REPO_URL/https:\/\//https://${GITHUB_ACCESS_TOKEN}@}"
    fi
    echo "Cloning repo to $GITHUB_CLONE_DIR (branch $GITHUB_BRANCH)..."
    GIT_ASKPASS=/bin/true git clone --branch "$GITHUB_BRANCH" "$url" "$GITHUB_CLONE_DIR"
    # scrub token from remote
    git -C "$GITHUB_CLONE_DIR" remote set-url origin "$GITHUB_REPO_URL"
  fi

  chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$GITHUB_CLONE_DIR" || true
}
