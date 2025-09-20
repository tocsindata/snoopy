#!/usr/bin/env bash 
set -euo pipefail

# This script sets up an Apache vhost for a single domain and a matching (sanitized) system user.
# DocumentRoot: /home/<sanitized-username>/public_html
#
# Username policy:
# - Domain is lowercased, dots and any non [a-z0-9_-] are replaced with underscores.
# - Many distros/tools reject '.' in usernames; sanitizing is safer and portable.

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# --- Ask for domain (or take from --domain flag)
DOMAIN="${1:-}"
if [[ -z "${DOMAIN}" ]]; then
  read -rp "Enter the FQDN to set up (e.g., snoopy.example.com): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"  # lowercase

# Basic FQDN validation (lenient)
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*\.)+[a-z]{2,}$ ]]; then
  echo "Invalid domain: '$DOMAIN'. Example: snoopy.example.com" >&2
  exit 1
fi

# Sanitize to a safe Linux username (no dots)
sanitize_username() {
  local s="${1,,}"
  s="${s//[^a-z0-9._-]/_}"   # map any weird chars to _
  s="${s//./_}"              # map dots to underscores
  # collapse multiple underscores
  s="$(echo -n "$s" | tr -s '_')"
  # trim to 32 chars (typical limit)
  echo "${s:0:32}"
}

USER_NAME="$(sanitize_username "$DOMAIN")"
HOME_DIR="/home/${USER_NAME}"
WEB_ROOT="${HOME_DIR}/public_html"
VHOST_CONF="/etc/apache2/sites-available/${DOMAIN}.conf"
PASS_FILE="/root/${USER_NAME}-password.txt"

echo "Domain     : ${DOMAIN}"
echo "User       : ${USER_NAME}  (sanitized from domain)"
echo "Home       : ${HOME_DIR}"
echo "DocumentRoot: ${WEB_ROOT}"
echo

# --- Pre-flight: require Apache (Debian/Ubuntu flavor)
if ! command -v apache2ctl >/dev/null 2>&1; then
  echo "apache2ctl not found. This script targets Debian/Ubuntu Apache2 layouts." >&2
  exit 1
fi

# --- Ensure group/user exist
if ! getent group "${USER_NAME}" >/dev/null; then
  groupadd "${USER_NAME}"
fi

if ! id "${USER_NAME}" >/dev/null 2>&1; then
  useradd -m -d "${HOME_DIR}" -s /bin/bash -g "${USER_NAME}" "${USER_NAME}"
  # Generate and set random password, store it securely
  PASS="$(openssl rand -base64 16 | tr -d '\n')"
  echo "${USER_NAME}:${PASS}" | chpasswd
  umask 077
  printf '%s\n' "${PASS}" > "${PASS_FILE}"
  chmod 600 "${PASS_FILE}"
  echo "Created user '${USER_NAME}'. Password saved to ${PASS_FILE}"
else
  echo "User '${USER_NAME}' already exists; skipping user creation."
fi

# --- Create web root and set ownership/permissions
mkdir -p "${WEB_ROOT}"
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}"
chmod 755 "${HOME_DIR}" "${WEB_ROOT}"

# --- Optional: drop a simple index page if none exists
if [[ ! -e "${WEB_ROOT}/index.html" && ! -e "${WEB_ROOT}/index.php" ]]; then
  cat > "${WEB_ROOT}/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${DOMAIN}</title>
<h1>${DOMAIN}</h1>
<p>It works! DocumentRoot: ${WEB_ROOT}</p>
HTML
  chown "${USER_NAME}:${USER_NAME}" "${WEB_ROOT}/index.html"
fi

# --- Enable required Apache modules (idempotent)
if command -v a2enmod >/dev/null 2>&1; then
  a2enmod rewrite >/dev/null || true
  a2enmod ssl >/dev/null || true
else
  echo "a2enmod not found; ensure mod_rewrite and mod_ssl are enabled." >&2
fi

# --- Create vhost config (80 and 443 with snakeoil certs)
if [[ -f "${VHOST_CONF}" ]]; then
  echo "VHost config already exists: ${VHOST_CONF}"
else
  cat > "${VHOST_CONF}" <<EOF
# ${DOMAIN}
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_ssl_access.log combined
</VirtualHost>
EOF
  echo "Wrote vhost: ${VHOST_CONF}"
fi

# --- Enable the site (idempotent) and reload Apache
if command -v a2ensite >/dev/null 2>&1; then
  a2ensite "${DOMAIN}.conf" >/dev/null || true
else
  echo "a2ensite not found; manually link ${VHOST_CONF} into sites-enabled." >&2
fi

echo "Running apache2ctl configtest..."
apache2ctl configtest

echo "Reloading Apache..."
systemctl reload apache2

echo
echo "✅ Setup complete."
echo "• Domain:        ${DOMAIN}"
echo "• User:          ${USER_NAME}"
echo "• Web root:      ${WEB_ROOT}"
[[ -f "${PASS_FILE}" ]] && echo "• Password file:  ${PASS_FILE} (chmod 600)"
echo
echo "Note: For a real TLS cert, consider Let's Encrypt (certbot) for ${DOMAIN}. Or run cert.sh after DNS is set up."
