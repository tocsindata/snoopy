#!/usr/bin/env bash 
# fix-permissions.sh — diagnose 403/permissions/vhost issues for a domain
# Safe/read-only: prints RECOMMENDED COMMANDs, does not change system state.

set -euo pipefail

# ---------- UI ----------
if [[ -t 1 ]]; then G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[34m"; X="\033[0m"; else G="";Y="";R="";B="";X=""; fi
ok()   { echo -e "${G}✔ PASS${X}  $*"; }
warn() { echo -e "${Y}▲ WARN${X}  $*"; }
bad()  { echo -e "${R}✖ FAIL${X}  $*"; }
info() { echo -e "${B}i${X}      $*"; }
recommend() { echo "# RECOMMENDED COMMAND: $*"; }

FAILS=0; WARNS=0
note_fail(){ ((FAILS++))||true; }
note_warn(){ ((WARNS++))||true; }

have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- Input ----------
DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  read -rp "Domain/FQDN to check (e.g., snoopy.example.com): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*\.)+[a-z]{2,}$ ]]; then
  echo "Invalid domain: '$DOMAIN'"; exit 1
fi

# Same sanitizer used in your other scripts (dots -> underscores)
sanitize_username() {
  local s="${1,,}"
  s="${s//[^a-z0-9._-]/_}"
  s="${s//./_}"
  s="$(echo -n "$s" | tr -s '_')"
  echo "${s:0:32}"
}

USER_NAME="$(sanitize_username "$DOMAIN")"
DOCROOT="/home/${USER_NAME}/public_html"

echo
info "Checking domain: ${DOMAIN}"
info "Expected user : ${USER_NAME}"
info "Expected root : ${DOCROOT}"

# ---------- 1) Which vhost serves this domain? ----------
echo -e "\n------ VirtualHost Routing ------"
APACHECTL=""
if have apache2ctl; then APACHECTL="apache2ctl"; fi
if [[ -z "$APACHECTL" ]] && have httpd; then APACHECTL="httpd"; fi

VHOST_CONF=""
SITES_AVAILABLE_DIR="/etc/apache2/sites-available"
SITES_ENABLED_DIR="/etc/apache2/sites-enabled"

if [[ -n "$APACHECTL" ]]; then
  if $APACHECTL -S >/tmp/vh.txt 2>/dev/null; then
    # try to pull the conf path for our domain
    HIT_LINE="$(grep -iE "namevhost[[:space:]]+$DOMAIN[[:space:]]|\s$DOMAIN[[:space:]]\(" /tmp/vh.txt || true)"
    if [[ -n "$HIT_LINE" ]]; then
      # Extract path inside parentheses (...) if present
      VHOST_CONF="$(echo "$HIT_LINE" | sed -n 's/.*(\(.*\):[0-9][0-9]*).*/\1/p' | head -n1)"
      ok "Apache is routing ${DOMAIN} using: ${VHOST_CONF:-<unknown file>}"
    else
      warn "apache -S did not show a vhost explicitly matching ${DOMAIN}. Requests may be hitting the default site."
      note_warn
      recommend "$APACHECTL -S"
    fi
    rm -f /tmp/vh.txt
  else
    warn "Could not run '$APACHECTL -S' (permission?)."
    note_warn
  fi
else
  warn "Apache control tool not found (apache2ctl/httpd). Skipping vhost routing check."
  note_warn
fi

# If we didn’t get a conf path, try typical locations:
if [[ -z "$VHOST_CONF" ]]; then
  if [[ -f "$SITES_AVAILABLE_DIR/$DOMAIN.conf" ]]; then
    VHOST_CONF="$SITES_AVAILABLE_DIR/$DOMAIN.conf"
  else
    # Grep for ServerName match
    CANDIDATE="$(grep -Rils "ServerName[[:space:]]\+$DOMAIN" /etc/apache2 /etc/httpd 2>/dev/null | head -n1 || true)"
    [[ -n "$CANDIDATE" ]] && VHOST_CONF="$CANDIDATE"
  fi
fi

# Is the site enabled?
ENABLED_LINK="$SITES_ENABLED_DIR/$DOMAIN.conf"
if [[ -L "$ENABLED_LINK" || -f "$ENABLED_LINK" ]]; then
  ok "Site appears enabled: $ENABLED_LINK"
else
  warn "Site not enabled in sites-enabled."
  note_warn
  recommend "a2ensite '${DOMAIN}.conf' && apache2ctl configtest && systemctl reload apache2"
fi

# ---------- 2) DocumentRoot sanity ----------
echo -e "\n------ DocumentRoot ------"
FOUND_DOCROOT=""
if [[ -n "$VHOST_CONF" && -f "$VHOST_CONF" ]]; then
  FOUND_DOCROOT="$(awk '
    /^[[:space:]]*#/ {next}
    /<VirtualHost/ {invh=1}
    invh && /DocumentRoot[[:space:]]+/ {print $2}
  ' "$VHOST_CONF" 2>/dev/null | head -n1 || true)"
fi

if [[ -n "$FOUND_DOCROOT" ]]; then
  info "Vhost DocumentRoot: $FOUND_DOCROOT"
  if [[ "$FOUND_DOCROOT" == "$DOCROOT" ]]; then
    ok "DocumentRoot matches expected ${DOCROOT}"
  else
    warn "DocumentRoot mismatch. Expected ${DOCROOT} but vhost shows ${FOUND_DOCROOT}"
    note_warn
    recommend "sed -i 's#^\\s*DocumentRoot\\s\\+.*#    DocumentRoot ${DOCROOT}#' '$VHOST_CONF' && apache2ctl configtest && systemctl reload apache2"
  fi
else
  warn "Could not parse a DocumentRoot from the vhost file."
  note_warn
  recommend "grep -n 'DocumentRoot' '$VHOST_CONF'"
fi

# ---------- 3) <Directory> override present? ----------
echo -e "\n------ <Directory> Block ------"
DIR_BLOCK_OK=0
if [[ -n "$VHOST_CONF" && -f "$VHOST_CONF" ]]; then
  if awk '
      BEGIN{ok=0}
      /^[[:space:]]*#/ {next}
      tolower($0) ~ /<directory[[:space:]]+\/home\// {ind=1}
      ind && tolower($0) ~ /require[[:space:]]+all[[:space:]]+granted/ {ok=1}
      ind && /<\/Directory>/ {ind=0}
      END{exit(ok?0:1)}
    ' "$VHOST_CONF"; then
    ok "Found a <Directory ...> block with 'Require all granted'."
    DIR_BLOCK_OK=1
  else
    warn "Could not find a <Directory> block granting access to the docroot."
    note_warn
    cat <<'SNIP'
# RECOMMENDED SNIPPET (add inside the <VirtualHost> for this site):
#   <Directory /home/USER/public_html>
#       Options Indexes FollowSymLinks
#       AllowOverride All
#       Require all granted
#   </Directory>
SNIP
    [[ -n "$VHOST_CONF" ]] && recommend "nano '$VHOST_CONF'  # add the block above, then: apache2ctl configtest && systemctl reload apache2"
  fi
else
  warn "No vhost file available to inspect for <Directory>."
  note_warn
fi

# ---------- 4) Directory traversal permissions ----------
echo -e "\n------ Directory Traversal & Modes ------"
CHECK_PATHS=( "/home" "/home/${USER_NAME}" "$DOCROOT" )
for p in "${CHECK_PATHS[@]}"; do
  if [[ -d "$p" ]]; then
    owner="$(stat -c '%U:%G' "$p" 2>/dev/null || echo '?')"
    mode="$(stat -c '%a' "$p" 2>/dev/null || echo '000')"
    # check "others execute" bit on directories (or group execute for www-data)
    others="${mode: -1}"
    group="${mode: -2:1}"
    groupname="$(stat -c '%G' "$p" 2>/dev/null || echo '?')"
    msg="$p [dir] mode=$mode owner=$owner"
    # we consider OK if others>=5 OR (group==www-data AND group>=5)
    if [[ "$others" -ge 5 || ( "$groupname" == "www-data" && "$group" -ge 5 ) ]]; then
      ok "$msg (traversable)"
    else
      warn "$msg (NOT traversable to Apache)"
      note_warn
      recommend "chmod 755 '$p'   # ensure execute (x) on each parent directory"
    fi
  else
    bad "$p is missing."
    note_fail
    recommend "mkdir -p '$p' && chown -R ${USER_NAME}:${USER_NAME} '/home/${USER_NAME}' && chmod 755 '$p'"
  fi
done

# Check typical file/dir modes inside docroot
if [[ -d "$DOCROOT" ]]; then
  # presence of an index file?
  if compgen -G "$DOCROOT/index.*" >/dev/null; then
    ok "Found index.* in docroot."
  else
    warn "No index.* file found. If directory listings are disabled, this can yield 403."
    note_warn
    recommend "echo '<h1>${DOMAIN}</h1>' | tee '$DOCROOT/index.html' >/dev/null"
  fi

  # Suggest modes if clearly too restrictive
  TOO_RESTRICTIVE_DIRS="$(find "$DOCROOT" -type d -printf '%m %p\n' 2>/dev/null | awk '$1+0<755{print $2}' | head -n1 || true)"
  if [[ -n "$TOO_RESTRICTIVE_DIRS" ]]; then
    warn "Some directories under docroot have restrictive modes (<755)."
    note_warn
    recommend "find '$DOCROOT' -type d -exec chmod 755 {} \\;"
  else
    ok "Directory modes look reasonable (>=755)."
  fi
  TOO_RESTRICTIVE_FILES="$(find "$DOCROOT" -type f -printf '%m %p\n' 2>/dev/null | awk '$1+0<644{print $2}' | head -n1 || true)"
  if [[ -n "$TOO_RESTRICTIVE_FILES" ]]; then
    warn "Some files under docroot have restrictive modes (<644)."
    note_warn
    recommend "find '$DOCROOT' -type f -exec chmod 644 {} \\;"
  else
    ok "File modes look reasonable (>=644)."
  fi
else
  warn "Docroot not present, skipping deeper checks."
  note_warn
fi

# ---------- 5) Ownership ----------
echo -e "\n------ Ownership ------"
if [[ -d "/home/${USER_NAME}" ]]; then
  owner_root="$(stat -c '%U:%G' "/home/${USER_NAME}" 2>/dev/null || echo '?')"
  owner_doc="$(stat -c '%U:%G' "$DOCROOT" 2>/dev/null || echo '?')"
  if [[ "$owner_root" == "${USER_NAME}:${USER_NAME}" && "$owner_doc" == "${USER_NAME}:${USER_NAME}" ]]; then
    ok "Home/docroot owned by ${USER_NAME}:${USER_NAME}"
  else
    warn "Ownership differs. Home: $owner_root  Docroot: $owner_doc"
    note_warn
    recommend "chown -R '${USER_NAME}:${USER_NAME}' '/home/${USER_NAME}'"
  fi
fi

# ---------- 6) .htaccess denials ----------
echo -e "\n------ .htaccess Deny Rules ------"
if [[ -f "$DOCROOT/.htaccess" ]]; then
  if grep -Ei '^\s*(require\s+all\s+denied|deny\s+from\s+all|order\s+deny,allow\s*$)' "$DOCROOT/.htaccess" >/dev/null; then
    warn ".htaccess contains a deny rule that can cause 403."
    note_warn
    recommend "sed -n '1,120p' '$DOCROOT/.htaccess'   # review and remove/adjust deny rules"
  else
    ok ".htaccess present; no obvious global deny found."
  fi
else
  ok "No .htaccess in docroot (nothing here to deny access)."
fi

# ---------- 7) Apache module sanity ----------
echo -e "\n------ Apache Modules ------"
if [[ -n "$APACHECTL" ]]; then
  if $APACHECTL -M >/tmp/mods.txt 2>/dev/null; then
    if grep -q 'rewrite_module' /tmp/mods.txt; then ok "mod_rewrite enabled."; else warn "mod_rewrite not enabled (not typical cause of 403, but needed for many apps)."; note_warn; recommend "a2enmod rewrite && apache2ctl configtest && systemctl reload apache2"; fi
    if grep -q 'authz_core_module' /tmp/mods.txt; then ok "authz_core present."; else warn "authz_core missing; Apache authz may be broken."; note_warn; fi
    rm -f /tmp/mods.txt
  else
    warn "Cannot list Apache modules (permission?)."
    note_warn
  fi
fi

# ---------- 8) Global deny in apache2.conf vs vhost override ----------
echo -e "\n------ Global Deny vs VHost Override ------"
APACHE_MAIN_CONF=""
[[ -f /etc/apache2/apache2.conf ]] && APACHE_MAIN_CONF="/etc/apache2/apache2.conf"
[[ -z "$APACHE_MAIN_CONF" && -f /etc/httpd/conf/httpd.conf ]] && APACHE_MAIN_CONF="/etc/httpd/conf/httpd.conf"

if [[ -n "$APACHE_MAIN_CONF" ]]; then
  if awk '
      BEGIN{rootdeny=0}
      /^[[:space:]]*#/ {next}
      /<Directory[[:space:]]*\/[[:space:]]*>/ {inroot=1}
      inroot && /Require[[:space:]]+all[[:space:]]+denied/ {rootdeny=1}
      inroot && /<\/Directory>/ {inroot=0}
      END{exit(rootdeny?0:1)}
    ' "$APACHE_MAIN_CONF"; then
    info "apache main conf: <Directory /> has 'Require all denied' (normal hardening)."
    if (( DIR_BLOCK_OK == 0 )); then
      warn "Your vhost may not be overriding the global deny."
      note_warn
      [[ -n "$VHOST_CONF" ]] && recommend "Add a <Directory ${DOCROOT}> block with 'Require all granted' to '$VHOST_CONF'"
    fi
  else
    ok "No global <Directory /> deny detected."
  fi
fi

# ---------- 9) SELinux / AppArmor hints ----------
echo -e "\n------ SELinux / AppArmor ------"
if have getenforce; then
  mode="$(getenforce || true)"
  info "SELinux: ${mode}"
  if [[ "$mode" == "Enforcing" ]]; then
    # Check context of docroot
    if have ls; then
      ctx="$(ls -Zd "$DOCROOT" 2>/dev/null || true)"
      echo "Context: ${ctx:-unknown}"
    fi
    warn "If SELinux blocks Apache, set proper context on /home/*/public_html."
    note_warn
    cat <<'SEL'
# RECOMMENDED COMMANDS (RHEL/AlmaLinux/CentOS):
semanage fcontext -a -t httpd_sys_content_t "/home/[^/]*/public_html(/.*)?"
restorecon -Rv /home/*/public_html
# To test quickly (temporary):
# setenforce 0   # then retry, and set back with: setenforce 1
SEL
  fi
fi

if have aa-status; then
  info "AppArmor profiles:"
  aa-status || true
  warn "If apache2 is confined and denies /home access, allow it or move the site under /var/www."
  note_warn
  cat <<'AA'
# RECOMMENDED (Ubuntu AppArmor):
# echo "  /home/*/public_html/** r," | sudo tee -a /etc/apparmor.d/local/usr.sbin.apache2
# systemctl reload apparmor
AA
fi

# ---------- Summary ----------
echo
echo "----------------------------------------"
echo "Fix-permissions Summary for ${DOMAIN}"
echo "Failures : $FAILS"
echo "Warnings : $WARNS"
echo "----------------------------------------"

# Convenience next steps
echo
echo "Next steps (common fixes):"
echo " - Ensure site is enabled: a2ensite '${DOMAIN}.conf' && apache2ctl configtest && systemctl reload apache2"
echo " - Ensure traversal perms: chmod 755 /home '/home/${USER_NAME}' '${DOCROOT}'"
echo " - Ensure ownership:       chown -R '${USER_NAME}:${USER_NAME}' '/home/${USER_NAME}'"
echo " - Ensure modes:           find '${DOCROOT}' -type d -exec chmod 755 {} \\; ; find '${DOCROOT}' -type f -exec chmod 644 {} \\;"
echo " - Add <Directory> block granting access if missing."
