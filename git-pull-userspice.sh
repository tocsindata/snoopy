#!/usr/bin/env bash 
# file: git-pull-userspice.sh
# purpose: Clone tocsindata/UserSpice5 into /home/<USER>/public_html and apply canonical UserSpice perms
# behavior:
#   - prompt for target account under /home
#   - ensure public_html exists (ask before wiping if not empty)
#   - clone repo (your fork)
#   - set ownership <USER>:www-data
#   - lock down all files/dirs; writable exceptions: users/init.php (664), usersc/plugins (2775), usersc/widgets (2775)

set -euo pipefail

REPO_URL="https://github.com/tocsindata/UserSpice5.git"
WEB_GROUP="www-data"

abort() { echo "ERROR: $*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N]: " _ans; [[ "${_ans:-N}" =~ ^[Yy]$ ]]; }
need() { command -v "$1" >/dev/null 2>&1 || abort "Missing dependency: $1"; }

echo "==> Locating candidate user homes under /home ..."
mapfile -t CANDIDATES < <(find /home -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)
((${#CANDIDATES[@]})) || abort "No user homes found under /home."

echo
echo "Select the target account to install into:"
for i in "${!CANDIDATES[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${CANDIDATES[$i]}"
done
echo
read -r -p "Enter number: " SEL
[[ "$SEL" =~ ^[0-9]+$ ]] || abort "Invalid selection."
IDX=$((SEL-1))
(( IDX >= 0 && IDX < ${#CANDIDATES[@]} )) || abort "Selection out of range."

TARGET_USER="${CANDIDATES[$IDX]}"
TARGET_HOME="/home/${TARGET_USER}"
TARGET_DIR="${TARGET_HOME}/public_html"

echo "==> Target user: ${TARGET_USER}"
echo "==> Target path: ${TARGET_DIR}"

# prerequisites
need git

# ensure public_html state
if [[ -d "$TARGET_DIR" ]]; then
  # check if non-empty (including dotfiles)
  shopt -s nullglob dotglob
  contents=( "${TARGET_DIR}"/* )
  shopt -u nullglob dotglob
  if (( ${#contents[@]} )); then
    echo "WARNING: ${TARGET_DIR} is not empty."
    if confirm "Delete ALL contents of ${TARGET_DIR}?"; then
      rm -rf "${TARGET_DIR:?}/"* "${TARGET_DIR}"/.[!.]* "${TARGET_DIR}"/..?* 2>/dev/null || true
    else
      abort "Aborted by user."
    fi
  fi
else
  echo "==> Creating ${TARGET_DIR} ..."
  mkdir -p "$TARGET_DIR"
fi

echo "==> Cloning ${REPO_URL} into ${TARGET_DIR} ..."
git clone "$REPO_URL" "$TARGET_DIR"

echo "==> Setting ownership to ${TARGET_USER}:${WEB_GROUP} ..."
chown -R "${TARGET_USER}:${WEB_GROUP}" "$TARGET_DIR"

echo "==> Locking down all files and directories (dirs 755, files 644) ..."
find "$TARGET_DIR" -type d -exec chmod 755 {} \;
find "$TARGET_DIR" -type f -exec chmod 644 {} \;

echo "==> Applying writable exceptions ..."
# users/init.php must be writable during install
if [[ -f "$TARGET_DIR/users/init.php" ]]; then
  chmod 664 "$TARGET_DIR/users/init.php"
else
  echo "NOTE: ${TARGET_DIR}/users/init.php not found (repo layout changed?)."
fi

# usersc/plugins and usersc/widgets should allow admin-managed uploads/edits
install -d -m 2775 -o "$TARGET_USER" -g "$WEB_GROUP" "$TARGET_DIR/usersc/plugins"
install -d -m 2775 -o "$TARGET_USER" -g "$WEB_GROUP" "$TARGET_DIR/usersc/widgets"

echo
echo "==> Completed."
echo "Summary:"
echo "  - Repo:        ${REPO_URL}"
echo "  - Installed:   ${TARGET_DIR}"
echo "  - Owner:Group: ${TARGET_USER}:${WEB_GROUP}"
echo "  - Default perms: dirs 755, files 644"
echo "  - Writable:    users/init.php (664), usersc/plugins (2775), usersc/widgets (2775)"
echo
echo "Post-install tip: after the UserSpice installer finishes, you may tighten:"
echo "  chmod 644 ${TARGET_DIR}/users/init.php"
