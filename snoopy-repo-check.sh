#!/bin/bash
# file: snoopy-repo-check.sh
# Compare remote HEAD to last seen; notify if changed or quiet too long.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers + config (variables only)
source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/config.sh"

# -------- settings (defaults) --------
LOCK_FILE="/var/lock/snoopy.repo-check.lock"
LOCK_TTL_SECS=$((2 * 60 * 60))   # 2h
QUIET_DEFAULT_DAYS=30            # default quiet threshold
LOG_BASENAME="repo-check.log"

# -------- logging early --------
if [[ -z "${LOG_DIR:-}" || "$LOG_DIR" == "NULL" ]]; then
  LOG_DIR="/var/log/snoopy"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$LOG_BASENAME"
exec > >(tee -a "$LOG_FILE") 2>&1

# prune old logs (7 days)
find "$LOG_DIR" -type f -mtime +7 -print -delete || true

echo "=== repo-check start: $(date) ==="

# -------- lock with TTL auto-unlock --------
acquire_lock() {
  local file="$1" ttl="$2"
  if [[ -e "$file" ]]; then
    local mtime epoch now age
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    if (( age > ttl )); then
      warn "Stale lock ($age s > $ttl s). Removing: $file"
      rm -f "$file"
    else
      warn "Another run is in progress (lock age ${age}s <= ${ttl}s). Exiting."
      exit 0
    fi
  fi
  echo "$$" > "$file"
  trap 'rm -f "$file"' EXIT
}

acquire_lock "$LOCK_FILE" "$LOCK_TTL_SECS"

# -------- args --------
QUIET_DAYS="$QUIET_DEFAULT_DAYS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notify-if-quiet)
      QUIET_DAYS="${2:-$QUIET_DEFAULT_DAYS}"; shift 2;;
    *) warn "Unknown arg: $1"; shift;;
  esac
done

# -------- verifies --------
verify GITHUB_REPO_URL
verify GITHUB_BRANCH
verify_optional GITHUB_REPO_PUBLIC

# -------- compute state key --------
hash_key() {
  local s="$1"
  echo -n "$s" | sha1sum | awk '{print $1}'
}
KEY="$(hash_key "${GITHUB_REPO_URL}::${GITHUB_BRANCH}")"
STATE_DIR="$SNOOPY_TMP_DIR/state/repo/$KEY"
mkdir -p "$STATE_DIR"
LAST_SHA_FILE="$STATE_DIR/last.sha"
LAST_QUIET_FILE="$STATE_DIR/last_activity.ts"

# -------- get remote sha (no echo of token) --------
URL="$GITHUB_REPO_URL"
if ! parse_bool "$GITHUB_REPO_PUBLIC"; then
  verify GITHUB_ACCESS_TOKEN
  URL="${GITHUB_REPO_URL/https:\/\//https://${GITHUB_ACCESS_TOKEN}@}"
fi

set +e
REMOTE_SHA=$(GIT_ASKPASS=/bin/true git ls-remote --heads "$URL" "$GITHUB_BRANCH" 2>/dev/null | awk '{print $1}')
set -e
if [[ -z "$REMOTE_SHA" ]]; then
  err "Failed to read remote SHA for $GITHUB_BRANCH"
  # notify error
  if parse_bool "$SEND_SLACK"; then
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${SLACK_MESSAGE:-Snoopy} — repo-check: FAILED to read $GITHUB_BRANCH on repo.\"}" \
      "$SLACK_WEBHOOK_URL" >/dev/null || true
  fi
  exit 1
fi

echo "Remote SHA: $REMOTE_SHA"

# -------- compare & notify --------
if [[ -f "$LAST_SHA_FILE" ]]; then
  LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || true)
else
  LAST_SHA=""
fi

if [[ "$REMOTE_SHA" != "$LAST_SHA" ]]; then
  echo "$REMOTE_SHA" > "$LAST_SHA_FILE"
  date +%s > "$LAST_QUIET_FILE"
  echo "New commits detected on $GITHUB_BRANCH."
  # notify
  if parse_bool "$SEND_SLACK"; then
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"${SLACK_MESSAGE:-Snoopy} — repo-check: new commits on *$GITHUB_BRANCH* (${REMOTE_SHA:0:7}).\"}" \
      "$SLACK_WEBHOOK_URL" >/dev/null || true
  fi
else
  echo "No new commits on $GITHUB_BRANCH."
  # quiet check
  now=$(date +%s)
  last_activity=$(cat "$LAST_QUIET_FILE" 2>/dev/null || echo "$now")
  days=$(( (now - last_activity) / (60*60*24) ))
  if (( days >= QUIET_DAYS )); then
    echo "Repo quiet for ${days}d (>= ${QUIET_DAYS}d). Notifying."
    if parse_bool "$SEND_SLACK"; then
      curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"${SLACK_MESSAGE:-Snoopy} — repo-check: quiet for ${days} days on *$GITHUB_BRANCH*.\"}" \
        "$SLACK_WEBHOOK_URL" >/dev/null || true
    fi
    # bump last_activity so we don't spam daily
    date +%s > "$LAST_QUIET_FILE"
  fi
fi

echo "=== repo-check done: $(date) ==="
