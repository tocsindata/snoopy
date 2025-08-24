#!/bin/bash
# file: snoopy-backup.sh
# Root-only. Snapshot webroot, vhost, php INIs, crontabs, scripts. Keep 7.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/config.sh"

check_root

# -------- settings --------
LOCK_FILE="/var/lock/snoopy.backup.lock"
LOCK_TTL_SECS=$((12 * 60 * 60)) # 12h
LOG_BASENAME="backup.log"
RETENTION=7
BACKUP_ROOT="/root/backups/${SNOOPY_HOME_USERNAME}"

# -------- logging --------
if [[ -z "${LOG_DIR:-}" || "$LOG_DIR" == "NULL" ]]; then
  LOG_DIR="/var/log/snoopy"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$LOG_BASENAME"
exec > >(tee -a "$LOG_FILE") 2>&1
find "$LOG_DIR" -type f -mtime +7 -print -delete || true
echo "=== backup start: $(date) ==="

# -------- lock w/ TTL --------
acquire_lock() {
  local file="$1" ttl="$2"
  if [[ -e "$file" ]]; then
    local mtime now age
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    now=$(date +%s); age=$(( now - mtime ))
    if (( age > ttl )); then
      warn "Stale lock ($age s > $ttl s). Removing: $file"
      rm -f "$file"
    else
      warn "Another run in progress. Exiting."
      exit 0
    fi
  fi
  echo "$$" > "$file"
  trap 'rm -f "$file"' EXIT
}
acquire_lock "$LOCK_FILE" "$LOCK_TTL_SECS"

# -------- verifies --------
verify SNOOPY_WEB_ROOT_DIR
verify SNOOPY_DOMAIN
verify APACHE_CONF_DIR

# -------- paths --------
TS="$(date +'%Y%m%d-%H%M%S')"
RUN_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$RUN_DIR"
echo "Backup to: $RUN_DIR"

# -------- webroot snapshot (then purge contents of cache/logs) --------
echo "Snapshot webroot..."
rsync -a --delete "$SNOOPY_WEB_ROOT_DIR"/ "$RUN_DIR/webroot"/

# remove contents under cache/log/tmp/logs/security_log… keep dirs
echo "Pruning cache/log contents..."
while IFS= read -r -d '' d; do
  echo "  emptying: $d"
  find "$d" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
done < <(find "$RUN_DIR/webroot" -type d \( \
  -iname 'cache' -o -iname 'caches' -o -iname 'tmp' -o -iname 'log' -o -iname 'logs' -o -iname 'security_log' \) -print0)

# -------- apache vhost --------
echo "Saving vhost..."
mkdir -p "$RUN_DIR/etc-apache"
cp -a "$APACHE_CONF_DIR/${SNOOPY_DOMAIN}.conf" "$RUN_DIR/etc-apache/" 2>/dev/null || warn "vhost conf missing"
# record enablement state
if [[ -L "/etc/apache2/sites-enabled/${SNOOPY_DOMAIN}.conf" ]]; then
  echo "enabled" > "$RUN_DIR/etc-apache/${SNOOPY_DOMAIN}.state"
else
  echo "disabled" > "$RUN_DIR/etc-apache/${SNOOPY_DOMAIN}.state"
fi

# -------- php inis (light sweep) --------
echo "Saving PHP INIs..."
mkdir -p "$RUN_DIR/etc-php"
find /etc/php -type f -path '*/apache2/*.ini' -exec bash -c '
  dst="$0"; src="$1";
  mkdir -p "$(dirname "$dst")"; cp -a "$src" "$dst"
' "$RUN_DIR/etc-php" {} \; 2>/dev/null || true

# -------- crontabs --------
echo "Saving crontabs..."
mkdir -p "$RUN_DIR/crontabs"
crontab -l > "$RUN_DIR/crontabs/root.txt" 2>/dev/null || true
su - "$SNOOPY_USER" -s /bin/bash -c 'crontab -l' > "$RUN_DIR/crontabs/${SNOOPY_USER}.txt" 2>/dev/null || true

# -------- scripts/config --------
echo "Saving scripts/config..."
mkdir -p "$RUN_DIR/scripts"
cp -a "$SCRIPT_DIR/"*.sh "$RUN_DIR/scripts/" 2>/dev/null || true
cp -a "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/functions.sh" "$RUN_DIR/scripts/" 2>/dev/null || true

# -------- manifest & checksums --------
echo "Building manifest..."
{
  echo "{"
  echo "  \"timestamp\": \"$(date -Iseconds)\","
  echo "  \"host\": \"$(hostname)\","
  echo "  \"webroot\": \"${SNOOPY_WEB_ROOT_DIR}\","
  echo "  \"domain\": \"${SNOOPY_DOMAIN}\","
  echo "  \"ubuntu\": \"$(lsb_release -ds 2>/dev/null || echo unknown)\""
  echo "}"
} > "$RUN_DIR/manifest.json"

echo "Listing files..."
( cd "$RUN_DIR" && find . -type f -printf '%P\n' | sort ) > "$RUN_DIR/filelist.txt"

echo "Computing checksums (sha256)..."
( cd "$RUN_DIR" && find . -type f -print0 | xargs -0 sha256sum ) > "$RUN_DIR/checksums.sha256"

# -------- prune old backups --------
echo "Pruning to last $RETENTION backups..."
cd "$BACKUP_ROOT"
keep=($(ls -1 | sort -r | head -n "$RETENTION"))
for d in *; do
  [[ -d "$d" ]] || continue
  skip=0
  for k in "${keep[@]}"; do [[ "$d" == "$k" ]] && skip=1; done
  if (( ! skip )); then
    echo "  removing old backup: $d"
    rm -rf "$d"
  fi
done

# -------- notify --------
size_h=$(du -sh "$RUN_DIR" | awk '{print $1}')
msg="${SLACK_MESSAGE:-Snoopy} — backup: created $RUN_DIR ($size_h), kept last $RETENTION"
echo "$msg"

if parse_bool "$SEND_SLACK"; then
  curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$msg\"}" "$SLACK_WEBHOOK_URL" >/dev/null || true
fi

if parse_bool "$SEND_EMAIL"; then
  body="Backup created at $RUN_DIR on $(hostname)\nSize: $size_h"
  echo -e "$body" | mail -s "${EMAIL_SUBJECT:-Snoopy Backup}" "${EMAIL_TO:-root}" || true
fi

echo "=== backup done: $(date) ==="
