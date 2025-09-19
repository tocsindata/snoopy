#!/usr/bin/env bash
# cert.sh — Non-interactive Let's Encrypt manager for Apache (webroot)
# Fixes staging/self-signed/mis-chained certs automatically

set -euo pipefail

#############################
# Hard-coded configuration  #
#############################
CERT_EMAIL="admin@tocsindata.io"                # change if needed
RENEW_DAYS=30                                   # renew when fewer days remain
STAGING=0                                       # 1 = LE staging (testing only)
CF_WAIT_SECS=60                                 # cloudflare settle probe
APACHE_RELOAD_CMD="systemctl reload apache2"    # or: systemctl reload httpd
FORCE_DISABLE_DEFAULT_SSL=1                     # disable default-ssl snakeoil if enabled
LE_PROD_DIR="https://acme-v02.api.letsencrypt.org/directory"

#############################
# Helpers / Logging         #
#############################
have(){ command -v "$1" >/dev/null 2>&1; }
log(){  printf '%s %s\n' "[$(date +'%F %T')]" "$*"; }
warn(){ printf '%s %s\n' "[$(date +'%F %T')] [WARN]" "$*" >&2; }
err(){  printf '%s %s\n' "[$(date +'%F %T')] [ERROR]" "$*" >&2; }

# Single-instance lock
LOCK_FILE="/var/run/certsh.lock"
exec 9>"$LOCK_FILE" || true
if ! flock -n 9; then log "Another cert.sh is running. Exiting."; exit 0; fi

# Pre-flight
[[ $EUID -eq 0 ]] || { err "Must run as root"; exit 1; }
have certbot || { err "certbot not found"; exit 1; }
APACHECTL=""
if have apache2ctl; then APACHECTL="apache2ctl"; elif have httpd; then APACHECTL="httpd"; else err "apache2ctl/httpd not found"; exit 1; fi

# --- Cert utils ---
days_until_expiry() {
  local pem="$1"
  [[ -f "$pem" ]] || { echo -1; return; }
  local end epoch_end epoch_now
  end="$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$end" ]] || { echo -1; return; }
  epoch_end="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  epoch_now="$(date -u +%s)"
  (( epoch_end>0 )) || { echo -1; return; }
  echo $(( (epoch_end - epoch_now) / 86400 ))
}

cert_sans() {
  local live_dir="$1" crt="${live_dir}/cert.pem"
  [[ -f "$crt" ]] || { echo ""; return; }
  openssl x509 -noout -text -in "$crt"      | awk '/X509v3 Subject Alternative Name/{flag=1; next} /X509v3/{flag=0} flag'      | tr ',' '\n' | sed -n 's/.*DNS:\s*\(.*\)$/\1/p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'      | sort -u | tr '\n' ' '
}

sets_equal() {
  local A B
  A="$(tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort -u | tr '\n' ' ')"
  B="$(tr ' ' '\n' <<<"$2" | sed '/^$/d' | sort -u | tr '\n' ' ')"
  [[ "$A" == "$B" ]]
}

# --- Apache parsing ---
collect_apache_confs() {
  local out="/tmp/certsh_vhosts.txt"
  if $APACHECTL -S >"$out" 2>/dev/null; then
    awk '/namevhost|port [0-9]+ namevhost/ {conf=$0; sub(/^.*\(/,"",conf); sub(/:[0-9]+\).*$/,"",conf); print conf}' "$out"        | sort -u
  else
    find /etc/apache2/sites-enabled /etc/apache2/sites-available /etc/httpd/conf.d -maxdepth 1 -type f -name "*.conf" 2>/dev/null || true
  fi
}

parse_conf_domains() {
  local conf="$1"
  awk -v CONF="$conf" '
    BEGIN{block=0; port=""; server=""; root=""; root80=""; root443=""; split("",aliases)}
    /^[[:space:]]*#/ {next}
    /<VirtualHost/ {
      block=1; port=""; server=""; root="";
      if ($0 ~ /:443/) port="443"; else if ($0 ~ /:80/) port="80"; else port="";
      delete aliases
    }
    block && /ServerName[[:space:]]+/   {server=$2}
    block && /ServerAlias[[:space:]]+/  {for (i=2;i<=NF;i++){a=$i;gsub(/;$/,"",a);if(a!="") aliases[a]=1}}
    block && /DocumentRoot[[:space:]]+/ {root=$2; gsub(/"/,"",root)}
    block && /<\/VirtualHost>/ {
      if (server!="") {
        alias_s=""; for (a in aliases) alias_s=alias_s a " "; gsub(/[[:space:]]+$/,"",alias_s);
        if (port=="80"  && root!="") root80=root;
        if (port=="443" && root!="") root443=root;
        print server "|" alias_s "|" root80 "|" root443 "|" CONF
      }
      block=0; port=""; server=""; root=""
    }
  ' "$conf" 2>/dev/null
}

# --- Vhost hardening ---
maybe_disable_default_ssl() {
  [[ "$FORCE_DISABLE_DEFAULT_SSL" -eq 1 ]] || return 0
  local f="/etc/apache2/sites-enabled/default-ssl.conf"
  [[ -f "$f" ]] || return 0
  if grep -q '/etc/ssl/certs/ssl-cert-snakeoil\.pem' "$f"; then
    log "Disabling default-ssl.conf (snakeoil)"
    a2dissite default-ssl.conf >/dev/null 2>&1 || true
    $APACHECTL configtest && eval "$APACHE_RELOAD_CMD"
  fi
}

patch_vhost_to_le() {
  local primary="$1"
  local le_dir="/etc/letsencrypt/live/${primary}"
  local full="${le_dir}/fullchain.pem" key="${le_dir}/privkey.pem"
  [[ -f "$full" && -f "$key" ]] || { warn "LE files missing for $primary"; return 1; }

  local changed=0
  mapfile -t confs < <(collect_apache_confs)
  for conf in "${confs[@]}"; do
    [[ -f "$conf" ]] || continue
    grep -Eq "Server(Name|Alias)[[:space:]]+${primary//./\\.}([[:space:]]|$)" "$conf" || continue

    # Ensure :443 exists; if not, clone from :80 docroot
    if ! awk "/<VirtualHost/ && /:443/ {f=1} END{exit !f}" "$conf" >/dev/null; then
      local doc80
      doc80="$(awk -v P="${primary}" '
        BEGIN{b=0;p="";r=""}
        /<VirtualHost/ {b = ($0 ~ /:80/); p=""; r=""}
        b && /ServerName[[:space:]]+/ {p=$2}
        b && /DocumentRoot[[:space:]]+/ {r=$2; gsub(/\"/,"",r)}
        b && /<\/VirtualHost>/ { if(p==P && r!=""){ print r; exit } b=0 }
      ' "$conf" 2>/dev/null || true)"
      [[ -z "$doc80" ]] && doc80="/var/www/html"
      {
        echo ""
        echo "<VirtualHost *:443>"
        echo "    ServerName $primary"
        echo "    DocumentRoot $doc80"
        echo "    SSLEngine on"
        echo "    SSLCertificateFile $full"
        echo "    SSLCertificateKeyFile $key"
        echo "</VirtualHost>"
      } >>"$conf"
      log "Added :443 vhost to $conf for $primary"
      changed=1
      continue
    fi

    # Normalize cert lines within :443 and remove deprecated ChainFile
    local tmp; tmp="$(mktemp)"
    awk -v FULL="$full" -v KEY="$key" '
      BEGIN{in443=0; hasFile=0; hasKey=0}
      /^[[:space:]]*<VirtualHost/ { in443 = ($0 ~ /:443/); hasFile=0; hasKey=0 }
      {
        if (in443 && $0 ~ /^[[:space:]]*SSLCertificateFile[[:space:]]+/)   { print "    SSLCertificateFile " FULL; hasFile=1; next }
        if (in443 && $0 ~ /^[[:space:]]*SSLCertificateKeyFile[[:space:]]+/){ print "    SSLCertificateKeyFile " KEY; hasKey=1; next }
        if (in443 && $0 ~ /^[[:space:]]*SSLCertificateChainFile[[:space:]]+/){ next }
        print $0
      }
      in443 && /<\/VirtualHost>/ {
        if (!hasFile) print "    SSLCertificateFile " FULL
        if (!hasKey)  print "    SSLCertificateKeyFile " KEY
      }
    ' "$conf" > "$tmp"
    if ! cmp -s "$conf" "$tmp"; then cp "$tmp" "$conf"; changed=1; log "Patched LE cert paths in $conf"; fi
    rm -f "$tmp"
  done

  if (( changed )); then $APACHECTL configtest && eval "$APACHE_RELOAD_CMD"; fi
  return 0
}

# --- Served vs local checks ---
served_issuer() {
  local host="$1"
  openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null      | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//'
}
serve_fingerprint() {
  local host="$1"
  openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null      | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g'
}
local_fingerprint() {
  local live_dir="$1"
  [[ -f "${live_dir}/cert.pem" ]] || { echo ""; return; }
  openssl x509 -in "${live_dir}/cert.pem" -noout -fingerprint -sha256 2>/dev/null      | sed 's/^.*=//; s/://g'
}
issuer_string() {
  local pem="$1"
  [[ -f "$pem" ]] || { echo ""; return; }
  openssl x509 -in "$pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//'
}
looks_like_staging_or_untrusted() {
  local pem="$1" iss
  iss="$(issuer_string "$pem")"
  [[ -z "$iss" ]] && return 0
  # treat any STAGING/Fake/Happy Hacker or non-LE issuer as untrusted
  if echo "$iss" | grep -qiE 'staging|fake|happy hacker'; then return 0; fi
  if ! echo "$iss" | grep -qi "Let's Encrypt"; then return 0; fi
  return 1
}
https_ok() {
  local d="$1"
  have curl || return 0
  local code; code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${d}/" || echo 000)"
  [[ "$code" =~ ^2|^3|^401|^403 ]]
}

########################################
# Discover domain groups from vhosts   #
########################################
declare -A GROUP_DOCROOT GROUP_ALIASES GROUP_PER_DOMAIN_WEBROOT

mapfile -t CONF_LIST < <(collect_apache_confs)
((${#CONF_LIST[@]})) || { err "No Apache vhost confs found."; exit 1; }

for conf in "${CONF_LIST[@]}"; do
  while IFS='|' read -r primary aliases doc80 doc443 _; do
    [[ -z "$primary" ]] && continue
    aliases="$(tr -s ' ' <<<"$aliases" | sed 's/^ *//;s/ *$//')"
    local_root="$doc80"; [[ -z "$local_root" ]] && local_root="$doc443"; [[ -z "$local_root" ]] && local_root="/var/www/html"
    prev="${GROUP_ALIASES[$primary]:-}"
    GROUP_ALIASES["$primary"]="$(printf "%s %s\n" "$prev" "$aliases" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
    [[ -z "${GROUP_DOCROOT[$primary]:-}" ]] && GROUP_DOCROOT["$primary"]="$local_root" || { [[ -n "$doc80" ]] && GROUP_DOCROOT["$primary"]="$doc80"; }
    GROUP_PER_DOMAIN_WEBROOT["$primary"]="$local_root"; for a in $aliases; do GROUP_PER_DOMAIN_WEBROOT["$a"]="$local_root"; done
  done < <(parse_conf_domains "$conf")
done

((${#GROUP_DOCROOT[@]})) || { err "Found no ServerName entries in vhost configs."; exit 1; }

########################################
# For each site, issue/renew as needed #
########################################
ANY_CHANGED=0

for primary in "${!GROUP_DOCROOT[@]}"; do
  docroot="${GROUP_DOCROOT[$primary]}"
  aliases="${GROUP_ALIASES[$primary]:-}"
  domains="$(printf "%s %s\n" "$primary" "$aliases" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
  live_dir="/etc/letsencrypt/live/${primary}"
  fullchain="${live_dir}/fullchain.pem"
  need_issue=0

  # Local validity checks
  if [[ ! -f "$fullchain" ]]; then
    log "[$primary] No existing certificate; will issue."
    need_issue=1
  else
    left="$(days_until_expiry "$fullchain")"
    (( left >= 0 && left < RENEW_DAYS )) && { log "[$primary] Expiring in ${left} day(s); will renew."; need_issue=1; }
    have_sans="$(cert_sans "$live_dir")"
    ! sets_equal "$have_sans" "$domains" && { log "[$primary] SAN set changed (have: $have_sans | want: $domains)"; need_issue=1; }
    looks_like_staging_or_untrusted "${live_dir}/cert.pem" && { log "[$primary] Local issuer is staging/untrusted; will replace with production."; need_issue=1; }
  fi

  # Force fix if SERVED cert is not **production** LE (e.g., staging/self-signed/mis-chained)
  srv_iss="$(served_issuer "$primary" || true)"
  log "[$primary] Served issuer: ${srv_iss:-unknown}"
  if [[ -z "$srv_iss" ]] || echo "$srv_iss" | grep -qiE 'staging|fake|happy hacker' || ! echo "$srv_iss" | grep -qi "Let's Encrypt"; then
    log "[$primary] Served issuer not production Let’s Encrypt; forcing production issuance."
    need_issue=1
  fi

  if (( need_issue == 0 )); then
    # still ensure vhost uses fullchain/privkey and snakeoil is off
    [[ -f "$fullchain" ]] && { patch_vhost_to_le "$primary" || true; maybe_disable_default_ssl || true; }
    # served vs local fingerprint sanity
    sfp="$(serve_fingerprint "$primary" || true)"; lfp="$(local_fingerprint "$live_dir" || true)"
    log "[$primary] Served fp: ${sfp:-?} | Local fp: ${lfp:-?}"
    if [[ -n "$sfp" && -n "$lfp" && "$sfp" != "$lfp" ]]; then
      warn "[$primary] Served fp differs from local; re-patching and reloading."
      patch_vhost_to_le "$primary" || true
      $APACHECTL configtest && eval "$APACHE_RELOAD_CMD"
    fi
    continue
  fi

  # Build certbot args (force production unless STAGING=1)
  args=( certonly --non-interactive --agree-tos --email "$CERT_EMAIL" --cert-name "$primary" -a webroot )
  (( STAGING == 1 )) && args+=( --staging ) || args+=( --server "$LE_PROD_DIR" )
  for d in $domains; do wr="${GROUP_PER_DOMAIN_WEBROOT[$d]:-$docroot}"; args+=( -w "$wr" -d "$d" ); done

  log "[$primary] Running certbot…"
  if ! certbot "${args[@]}" --expand --force-renewal; then
    err "[$primary] certbot failed. Will retry on next run."
    continue
  fi
  ANY_CHANGED=1

  # Make future renewals use production (fix any old staging lineage)
  if [[ -f "/etc/letsencrypt/renewal/${primary}.conf" ]]; then
    sed -i 's#acme-staging-v02\.api\.letsencrypt\.org/directory#acme-v02.api.letsencrypt.org/directory#g' "/etc/letsencrypt/renewal/${primary}.conf" || true
    sed -i 's#^server\s*=.*#server = https://acme-v02.api.letsencrypt.org/directory#' "/etc/letsencrypt/renewal/${primary}.conf" || true
  fi

  # Patch vhosts to LE fullchain/privkey and reload
  patch_vhost_to_le "$primary" || true
  maybe_disable_default_ssl || true

  # If served fp still not equal to local, **restart**
  sfp="$(serve_fingerprint "$primary" || true)"; lfp="$(local_fingerprint "$live_dir" || true)"
  log "[$primary] Served fp (post-issue): ${sfp:-?} | Local fp: ${lfp:-?}"
  if [[ -n "$sfp" && -n "$lfp" && "$sfp" != "$lfp" ]]; then
    warn "[$primary] Served fp still differs; forcing full restart."
    if have systemctl; then systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null || true; fi
  fi

  # Cloudflare settle probe (non-blocking)
  if have curl && curl -sSI --max-time 6 "http://${primary}/" 2>/dev/null | grep -qiE 'server:\s*cloudflare|^cf-ray:'; then
    warn "[$primary] Cloudflare proxy detected; waiting ${CF_WAIT_SECS}s, then probing."
    sleep "$CF_WAIT_SECS"
    https_ok "$primary" && log "[$primary] HTTPS OK after CF settle." || warn "[$primary] HTTPS check failed post-CF; may need more time."
  fi
done

if (( ANY_CHANGED == 0 )); then
  log "All certificates valid; no changes."
  for primary in "${!GROUP_DOCROOT[@]}"; do patch_vhost_to_le "$primary" || true; done
  maybe_disable_default_ssl || true
fi

exit 0

