#!/bin/bash
# file: snoopy-restore.sh
# Root-only. Restore from /root/backups/<user>/...  Dry-run by default.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/config.sh"

check_root

LOG_BASENAME="restore.log"

# logging
if [[ -z "${LOG_DIR:-}" || "$LOG_DIR" == "NULL" ]]; then
  LOG_DIR="/var/log/snoopy"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$LOG_BASENAME"
exec > >(tee -a "$LOG_FILE") 2>&1
find "$LOG_DIR" -type f -mtime +7 -print -delete || true
echo "=== restore start: $(date) ==="

BACKUP_ROOT="/root/backups/${SNOOPY_HOME_USERNAME}"

usage() {
  cat <<EOF
Usage: $0 [--list] [--backup TS] [--target all|webroot|vhost] [--apply]
  --list           List available backups
  --backup TS      Timestamp folder to restore (default: latest)
  --target         all (default), webroot, vhost
  --apply          Perform changes (default is dry-run)
EOF
}

TARGET="all"
APPLY=0
TS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) ls -1 "$BACKUP_ROOT" | sort; exit 0 ;;
    --backup) TS="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown arg: $1"; shift ;;
  esac
done

if [[ -z "$TS" ]]; then
  TS="$(ls -1 "$BACKUP_ROOT" | sort | tail -n 1)"
  [[ -n "$TS" ]] || error_exit "No backups found in $BACKUP_ROOT"
fi

RUN_DIR="$BACKUP_ROOT/$TS"
[[ -d "$RUN_DIR" ]] || error_exit "Backup not found: $RUN_DIR"
echo "Restoring from: $RUN_DIR (target=$TARGET, dry-run=$((1-APPLY)))"

# restore webroot
restore_webroot() {
  verify SNOOPY_WEB_ROOT_DIR
  local src="$RUN_DIR/webroot"
  local dst="$SNOOPY_WEB_ROOT_DIR"
  [[ -d "$src" ]] || { warn "webroot not in backup, skipping"; return 0; }

  echo "Sync webroot -> $dst"
  if (( APPLY )); then
    rsync -a --delete "$src"/ "$dst"/
    chown -R "$SNOOPY_USER:$SNOOPY_GROUP" "$dst"
  else
    rsync -an --delete "$src"/ "$dst"/
  fi
}

# restore vhost
restore_vhost() {
  verify APACHE_CONF_DIR
  verify SNOOPY_DOMAIN
  local conf_src="$RUN_DIR/etc-apache/${SNOOPY_DOMAIN}.conf"
  local state_src="$RUN_DIR/etc-apache/${SNOOPY_DOMAIN}.state"
  [[ -f "$conf_src" ]] || { warn "vhost conf missing in backup"; return 0; }
  echo "Restore vhost conf -> $APACHE_CONF_DIR"
  if (( APPLY )); then
    cp -a "$conf_src" "$APACHE_CONF_DIR/"
    if [[ -f "$state_src" ]]; then
      state=$(cat "$state_src")
      a2ensite "${SNOOPY_DOMAIN}.conf" >/dev/null 2>&1 || true
      [[ "$state" == "enabled" ]] || a2dissite "${SNOOPY_DOMAIN}.conf" >/dev/null 2>&1 || true
      systemctl reload apache2 || true
    fi
  else
    echo "Would copy $conf_src to $APACHE_CONF_DIR/"
    [[ -f "$state_src" ]] && echo "Would set vhost state: $(cat "$state_src")"
  fi
}

case "$TARGET" in
  all)
    restore_webroot
    restore_vhost
    ;;
  webroot) restore_webroot ;;
  vhost) restore_vhost ;;
  *) error_exit "Unknown target: $TARGET" ;;
esac

echo "=== restore done: $(date) ==="
