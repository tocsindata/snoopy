#!/bin/bash
# file: snoopy-import.sh
# Root-only. Import specific files from other repos based on a manifest.
# Supports: --list | --dry-run <name|all> | --apply <name> | --apply-all

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/config.sh"

check_root

# -------- settings --------
LOCK_FILE="/var/lock/snoopy.import.lock"
LOCK_TTL_SECS=$((60 * 60))  # 1h
LOG_BASENAME="import.log"

MANIFEST="${SNOOPY_HOME}/imports/manifest.psv"
STATE_DIR="$SNOOPY_TMP_DIR/imports/state"
SCRATCH_BASE="$SNOOPY_TMP_DIR/imports/repos"
SINGLEFILE_BACKUP_ROOT="/root/backups/${SNOOPY_HOME_USERNAME}/singlefile"

mkdir -p "$STATE_DIR" "$SCRATCH_BASE" "$SINGLEFILE_BACKUP_ROOT" "$SNOOPY_HOME/imports"

# -------- logging --------
if [[ -z "${LOG_DIR:-}" || "$LOG_DIR" == "NULL" ]]; then
  LOG_DIR="/var/log/snoopy"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$LOG_BASENAME"
exec > >(tee -a "$LOG_FILE") 2>&1
find "$LOG_DIR" -type f -mtime +7 -print -delete || true
echo "=== import start: $(date) ==="

# -------- helpers --------
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

hash_key() { echo -n "$1" | sha1sum | awk '{print $1}'; }

real_ok_under_home() {
  local p rp
  p="$1"; rp="$(readlink -f "$p" 2>/dev/null || true)"
  [[ -n "$rp" ]] && [[ "$rp" == "$SNOOPY_HOME"* ]]
}

backup_single_file() {
  local dest="$1"
  local key="$(hash_key "$(readlink -f "$dest" 2>/dev/null || echo "$dest")")"
  local dir="$SINGLEFILE_BACKUP_ROOT/$key"
  local ts="$(date +'%Y%m%d-%H%M%S')"
  mkdir -p "$dir"
  if [[ -f "$dest" ]]; then
    cp -a "$dest" "$dir/${ts}-$(basename "$dest")"
    # prune to last 12
    local keep=($(ls -1 "$dir" 2>/dev/null | sort -r | head -n 12))
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      skip=0; for k in "${keep[@]}"; do [[ "$(basename "$f")" == "$k" ]] && skip=1; done
      (( skip )) || rm -f "$f"
    done
  fi
}

# -------- args --------
MODE=""
TARGET=""
NO_LOCK=0

usage() {
  cat <<EOF
Usage:
  $0 --list
  $0 --dry-run <name|all>
  $0 --apply <name>
  $0 --apply-all
Options:
  --no-lock   Run without taking the cron lock
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --dry-run) MODE="dry"; TARGET="${2:-}"; shift 2 ;;
    --apply) MODE="one"; TARGET="${2:-}"; shift 2 ;;
    --apply-all) MODE="all"; shift ;;
    --no-lock) NO_LOCK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown arg: $1"; shift ;;
  esac
done

[[ -n "$MODE" ]] || { usage; exit 1; }

(( NO_LOCK )) || acquire_lock "$LOCK_FILE" "$LOCK_TTL_SECS"

# -------- read manifest --------
[[ -f "$MANIFEST" ]] || error_exit "Manifest not found: $MANIFEST"

# columns:
# name | repo_url | ref | src_path | dest_path | owner | group | mode | post_cmd | repo_public | repo_token
parse_line() {
  IFS='|' read -r name repo ref src dest owner group mode post repo_public repo_token <<<"$1"
  # trim spaces
  name="${name//[$'\t\r\n ']}"
  repo_public="${repo_public//[$'\t\r\n ']}"
  echo "$name" "$repo" "$ref" "$src" "$dest" "$owner" "$group" "$mode" "$post" "$repo_public" "$repo_token"
}

list_entries() {
  awk 'NF && $1 !~ /^#/' "$MANIFEST" | nl -ba
}

if [[ "$MODE" == "list" ]]; then
  echo "Entries in $MANIFEST:"
  list_entries
  echo "==="; exit 0
fi

# load all lines into array
mapfile -t LINES < <(awk 'NF && $1 !~ /^#/' "$MANIFEST")

process_entry() {
  local line="$1" apply="$2"
  read -r name repo ref src dest owner group mode post repo_public repo_token < <(parse_line "$line")

  [[ -n "$name" && -n "$repo" && -n "$ref" && -n "$src" && -n "$dest" ]] || { warn "Skipping invalid entry: $line"; return 0; }

  # dest allow-list: must be under /home/(user)
  real_ok_under_home "$dest" || { warn "Dest not under $SNOOPY_HOME: $dest (skip)"; return 0; }

  # build auth URL
  local url="$repo"
  if [[ "$repo_public" =~ ^([Tt]rue|1|yes|on)$ ]]; then
    : # no token
  else
    # either literal token, or "true" to reuse config
    local tok=""
    if [[ "$repo_token" =~ ^([Tt]rue|1|yes|on)$ ]]; then
      verify GITHUB_ACCESS_TOKEN
      tok="$GITHUB_ACCESS_TOKEN"
    elif [[ "$repo_token" == "false" || "$repo_token" == "NULL" || -z "$repo_token" ]]; then
      tok=""
    else
      tok="$repo_token"
    fi
    if [[ -n "$tok" ]]; then
      url="${repo/https:\/\//https://${tok}@}"
    fi
  fi

  # scratch repo dir
  local key="$(hash_key "$repo")"
  local scratch="$SCRATCH_BASE/$key"
  mkdir -p "$scratch"

  # sparse checkout just the file
  echo "Fetching $name: $repo [$ref] :: $src"
  if [[ ! -d "$scratch/.git" ]]; then
    ( cd "$scratch"
      git init -q
      git remote add origin "$url"
      git config core.sparseCheckout true
      mkdir -p .git/info
      echo "$src" > .git/info/sparse-checkout
      GIT_ASKPASS=/bin/true git fetch -q --depth=1 origin "$ref"
      git checkout -q FETCH_HEAD
    )
  else
    ( cd "$scratch"
      git remote set-url origin "$url"
      echo "$src" > .git/info/sparse-checkout
      GIT_ASKPASS=/bin/true git fetch -q --depth=1 origin "$ref"
      git checkout -q FETCH_HEAD
    )
  fi

  local src_abs="$scratch/$src"
  [[ -f "$src_abs" ]] || { warn "Source file not found after fetch: $src_abs"; return 0; }

  # compare with dest
  dest_real="$(readlink -f "$dest" 2>/dev/null || echo "$dest")"
  mkdir -p "$(dirname "$dest_real")"

  local diff=1
  if [[ -f "$dest_real" ]]; then
    if cmp -s "$src_abs" "$dest_real"; then diff=0; fi
  fi

  if (( ! apply )); then
    if (( diff )); then
      echo "[DRY] Would update: $dest_real  (from $repo:$ref:$src)"
    else
      echo "[DRY] No change: $dest_real"
    fi
    return 0
  fi

  # backup dest (keep 12)
  backup_single_file "$dest_real"

  # install atomically
  tmpfile="$(mktemp)"
  cp -a "$src_abs" "$tmpfile"
  mv -f "$tmpfile" "$dest_real"

  # set owner/group/mode if provided
  [[ -n "$owner" && -n "$group" ]] && chown "$owner:$group" "$dest_real" || true
  [[ -n "$mode"  ]] && chmod "$mode" "$dest_real" || true

  echo "Updated: $dest_real"

  # run post-cmd
  if [[ -n "$post" && "$post" != "NULL" ]]; then
    bash -lc "$post" || warn "post_cmd failed for $name"
  fi

  # notify
  if parse_bool "$SEND_SLACK"; then
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${SLACK_MESSAGE:-Snoopy} — import: updated *$name* → $(basename "$dest_real")\"}" \
      "$SLACK_WEBHOOK_URL" >/dev/null || true
  fi
}

case "$MODE" in
  dry)
    [[ "$TARGET" == "all" || -n "$TARGET" ]] || { usage; exit 1; }
    for line in "${LINES[@]}"; do
      read -r name _ < <(parse_line "$line")
      if [[ "$TARGET" == "all" || "$TARGET" == "$name" ]]; then
        process_entry "$line" 0
      fi
    done
    ;;
  one)
    [[ -n "$TARGET" ]] || { usage; exit 1; }
    for line in "${LINES[@]}"; do
      read -r name _ < <(parse_line "$line")
      [[ "$name" == "$TARGET" ]] || continue
      process_entry "$line" 1
    done
    ;;
  all)
    for line in "${LINES[@]}"; do
      process_entry "$line" 1
    done
    ;;
  *)
    usage; exit 1 ;;
esac

echo "=== import done: $(date) ==="
